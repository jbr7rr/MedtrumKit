import Foundation

public extension MedtrumPumpManager {
    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        // Need neither the link nor a patch
        reportBolusFromLastRun()
        resendUnacknowledgedFinalsIfDue()

        let age = Date.now.timeIntervalSince(state.lastSync)

        // Fresh or not, a bolus past its deadline is settled by a full status
        guard let activatedAt = state.patchActivatedAt,
              age > Self.loopSyncFreshnessInterval ||
              Date.now.timeIntervalSince(activatedAt) < .minutes(4) ||
              isRunningBolusOverdue
        else {
            log.info("Skipping status update -> data is fresh or not active: \(Int(age)) sec")
            completion?(nil)
            return
        }

        guard !state.pumpState.isSetup else {
            log.error("(ensureCurrentPumpData) patch not in active state yet")
            completion?(nil)
            return
        }

        // Nothing to sync until the next session starts - the setup screens connect on their own
        guard !state.stoppedWithNoSession else {
            log.info("(ensureCurrentPumpData) patch session ended, nothing to sync: \(state.pumpState.description)")
            completion?(nil)
            return
        }

        syncPumpData { syncedAt in
            // The patch out of reach: the doses waiting on its records must not wait for good
            if syncedAt == nil {
                RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self)
            }
            completion?(syncedAt)
        }
    }

    func syncPumpData(completion: ((Date?) -> Void)?) {
        log.info("Sync pump data")

        #if targetEnvironment(simulator)
            pumpDelegate.notify { delegate in
                self.state.reservoir = Double(Int.random(in: 10 ..< 200))
                if self.state.initialReservoir == nil {
                    self.state.initialReservoir = self.state.reservoir
                }

                delegate?.pumpManager(self, didReadReservoirValue: self.state.reservoir, at: Date.now) { _ in }

                self.state.lastSync = Date.now
                self.notifyStateDidChange()

                completion?(nil)
            }
            return
        #endif

        // Not counted as a command: the record sync below runs inside it, and would otherwise yield to it. Waiting all
        // the same, until it hears back: a temp basal's records read meanwhile take no longer than as with a command
        let waiting = loopBeginsWaiting()
        ensureConnectedAndActive(isCommand: false) { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                self.loopHearsBack(waiting, nil, completion)
                return
            }

            // Between commands: not ahead of the records a command reads, a temp basal's it ended
            guard let syncResult = self.betweenCommands({ self.link.write(SynchronizePacket()) }) else {
                self.loopHearsBack(waiting, nil, completion)
                return
            }
            StateSyncer.fetchPatchTimeIfStale(pumpManager: self)

            switch syncResult {
            case let .failure(error):
                self.log.error("Failed to write: \(error.localizedDescription)")
                self.loopHearsBack(waiting, nil, completion)
                return

            case let .success(data):
                guard let syncResponse = data as? SynchronizePacketResponse else {
                    self.log.error("Invalid response data...")
                    self.loopHearsBack(waiting, nil, completion)
                    return
                }

                do {
                    self.log.info("Manual sync: \(String(data: try JSONEncoder().encode(syncResponse), encoding: .utf8) ?? "")")
                } catch {
                    self.log.warning("State update: Failed to encode JSON")
                }

                StateSyncer.sync(
                    syncResponse: syncResponse,
                    state: self.state,
                    pumpManager: self,
                    duringReconnect: false,
                    fullSync: true
                )

                // A few records before the loop hears back, so it sees the doses they finalize; the rest after
                RecordSyncer.syncRecords(pumpManager: self, trigger: .loopSync)

                self.loopHearsBack(waiting, Date.now, completion)

                if self.state.syncedSequenceNumber < self.state.currentSequenceNumber {
                    RecordSyncer.syncRecords(pumpManager: self, trigger: .fullSync)
                }
            }
        }
    }

    internal enum HeartbeatSync {
        /// A full status, then the records
        case full
        /// The records doses are waiting on only
        case records
    }

    /// What a heartbeat syncs, if anything: a full status when the last one is stale, or when a running bolus is past
    /// its deadline - only a full status settles it, and dosing is refused until then, so it does not wait for the
    /// loop. Otherwise the records doses wait on, once the patch has written them - not while a bolus runs.
    internal func heartbeatSync() -> HeartbeatSync? {
        // Its records are being read, on the link: a full status's Synchronize would go out ahead of them, eating into
        // their budget. The next heartbeat syncs instead.
        if let ending = pendingTempBasalEnd {
            // Ended by a halt whose status named no record: a full status names it - asked for now, not left to the
            // freshness interval, its records read as it comes in (`namesRecordOfTempBasalEnd`). Not with a bolus
            // running: its end comes first.
            guard ending.awaitsRecord, state.bolusState == .noBolus else {
                log.debug("Skipping sync, the records of the temp basal of \(ending.dose.startDate) are being read")
                return nil
            }
            log.info("Asking for a full status: it names the record of the temp basal of \(ending.dose.startDate) that ended")
            return .full
        }

        // A full status of the previous patch, not taken, is as fresh a sync as any: the next one would be ignored too
        let age = Date.now.timeIntervalSince(max(state.lastSync, previousPatchsFullStatusAt.value))
        let isBolusOverdue = isRunningBolusOverdue
        let isFullSyncDue = age > Self.heartbeatSyncFreshnessInterval ||
            (isBolusOverdue && age > Self.overdueBolusSyncInterval)

        guard isFullSyncDue || hasPendingRecordWork else {
            return nil
        }

        guard state.bolusState == .noBolus || (isBolusOverdue && isFullSyncDue) else {
            log.debug("Skipping sync, pump is currently bolusing")
            return nil
        }

        return isFullSyncDue ? .full : .records
    }

    /// A full status of the previous patch came in at `receivedAt`, not taken - see `previousPatchsFullStatusAt`
    internal func noteStatusOfThePreviousPatch(at receivedAt: Date) {
        previousPatchsFullStatusAt.value = receivedAt
    }

    /// A running bolus past its deadline - a full status settles it
    internal var isRunningBolusOverdue: Bool {
        guard let doseEntry = state.bolusDose else {
            return false
        }
        let running = doseEntry.snapshot
        return !running.isFinished && now() >= doseEntry.deliveryDeadline(of: running)
    }
}

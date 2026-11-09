import LoopKit

public extension MedtrumPumpManager {
    func primePatch(_ completion: @escaping (MedtrumPrimePatchResult) -> Void) {
        log.info("Start priming patch...")

        if state.pumpSN.isEmpty {
            // Need to scan for pump base first
            log.warning("No pump base known yet...")
            completion(.failure(error: .noKnownPumpBase))
            return
        }

        if state.sessionToken.isEmpty {
            log.debug("Refreshing session token...")

            // Patch has been disabled and thus a new session token is needed
            state.sessionToken = Crypto.genSessionToken()
            notifyStateDidChange()
        }

        link.ensureConnected { error in
            // Reported at once, not once the operation holding the lock is over
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure(reason: error.errorDescription ?? "EMPTY")))
                return
            }

            guard self.lockCommandLock() else {
                completion(.failure(error: .connectionFailure(reason: "another operation held the patch")))
                return
            }
            defer { self.commandLock.unlock() }

            guard !self.state.pumpState.isTerminated else {
                self.log.error("Cannot prime, patch session is over: \(self.state.pumpState.description)")
                completion(.failure(error: .patchNotPrimeable(state: self.state.pumpState)))
                return
            }

            guard self.state.pumpState.isBeforePriming else {
                self.log.info("Patch is already priming or primed!")
                completion(.success)
                return
            }

            guard self.state.pumpState == .filled else {
                self.log.warning("Patch is not filled yet, refusing to prime. State: \(self.state.pumpState)")
                completion(.failure(error: .patchNotFilled(state: self.state.pumpState)))
                return
            }

            // A next patch set up: an activation sent before, its answer lost, went to another one - or never activated
            // this one, filled since. Nothing of a status is to start a session for it (`startSessionOfActivatedPatchSoon`).
            let markerCleared = self.doseReportLock.withLock { () -> Bool in
                guard self.state.activationSentAt != nil else {
                    return false
                }
                self.state.activationSentAt = nil
                return true
            }
            if markerCleared {
                self.log.info("Priming a patch: the activation sent before is done with")
                self.notifyStateDidChange()
            }

            let primeResult = self.link.write(PrimePacket())
            if case let .failure(error) = primeResult {
                self.log.error("Failed to start priming pump: \(error)")
                completion(.failure(error: .unknownError(reason: error)))
                return
            }

            self.log.info("Priming has started!")
            completion(.success)
        }
    }

    func activatePatch(_ completion: @escaping (MedtrumActivatePatchResult) -> Void) {
        log.info("Activate patch pump...")

        link.ensureConnected { error in
            // Reported at once, not once the operation holding the lock is over
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure(reason: error.errorDescription ?? "EMPTY")))
                return
            }

            guard self.lockCommandLock() else {
                completion(.failure(error: .connectionFailure(reason: "another operation held the patch")))
                return
            }
            defer { self.commandLock.unlock() }

            guard !self.state.pumpState.isTerminated else {
                self.log.error("Cannot activate, patch session is over: \(self.state.pumpState.description)")
                completion(.failure(error: .patchNotActivatable(state: self.state.pumpState)))
                return
            }

            guard !self.state.pumpState.isRunning else {
                // The patch activated, but its answer was lost: the session it starts is not started yet
                if self.state.patchSessionEnded {
                    self.log.warning("Patch already activated, but its session was not started - starting it")
                    self.startSessionOfActivatedPatch()
                }

                self.log.info("Patch already activated!")
                completion(.success)
                return
            }

            StateSyncer.syncTime(pumpManager: self)

            let packet = ActivatePacket(
                expirationTimer: self.state.expiryMode.timer,
                alarmSetting: self.state.alarmSetting,
                hourlyMaxInsulin: self.state.maxHourlyInsulin,
                dailyMaxInsulin: self.state.maxDailyInsulin,
                currentTDD: 0,
                basalProfile: self.state.basalSchedule.toData()
            )
            // On disk before it goes out: its answer lost - the sheet dismissed after, or the app killed - the patch may
            // have activated, and the first status showing it running starts its session (`startSessionOfActivatedPatchSoon`).
            // Handed to the host and waited for, as a dose's write-ahead is - best effort, a stalled host not waited out.
            self.doseReportLock.withLock {
                self.state.activationSentAt = Date.now
            }
            self.handOverState(before: "activating the patch")
            let result = self.link.write(packet)
            switch result {
            case let .failure(error):
                self.log.error("Failed to activate pump: \(error)")
                // Turned down, or never sent: the patch did not activate on it - no status is to start a session for it.
                // Unanswered, it may have: kept.
                if MedtrumCommandOutcome(error) != .unknown {
                    self.doseReportLock.withLock {
                        self.state.activationSentAt = nil
                    }
                    self.notifyStateDidChange()
                }
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return

            case let .success(data):
                guard let data = data as? ActivatePacketResponse else {
                    self.log.error("Failed to parse response...")
                    completion(.failure(error: .unknownError(reason: "Failed to parse response...")))
                    return
                }

                let start = Date.now
                self.startPatchSession(patchId: data.patchId, at: start, activatedAt: start, isDelivering: true)

                self.log.info("Patch activated!")
                completion(.success)
                return
            }
        }
    }

    /// The patch activated, its activation's answer lost: the session it starts starts now - for a retried activation,
    /// or the first status that shows it running after the activation went out (`startSessionOfActivatedPatchSoon`).
    /// Holding `commandLock`.
    private func startSessionOfActivatedPatch() {
        // Its id is not taken from what the connect synced, which can be stale with no session - only from a status that
        // named it (below); otherwise the first status after this sets it, and payloads are not checked against an id
        // until then. It may have suspended since - the connect synced its status, and notifications keep it current
        // while connected.
        let start = Date.now
        // It activated before now: at the start time the connect synced, if that is the new patch's. The previous
        // patch's - kept since, or synced before it disconnected - is from before its deactivation.
        var syncedStart: Date?
        if let syncedActivation = state.patchActivatedAt,
           let deactivatedAt = state.previousPatch?.deactivatedAt,
           syncedActivation > deactivatedAt, syncedActivation <= start
        {
            syncedStart = syncedActivation
        }
        let activatedAt = syncedStart ?? start
        // The id a status of it named, not the previous patch's: kept, with its records as that status took them up -
        // started with none, the next status naming it would take them up again, past the record of a dose sent before
        // it, and the dose's answer, naming that id, would be another patch's (`noteBolusAnswer`)
        let previousId = state.previousPatch.flatMap { $0.patchId.isEmpty ? nil : $0.patchId.toUInt64() & 0xFFFF }
        let namedId = state.patchId.isEmpty || state.patchId.toUInt64() & 0xFFFF == previousId ? Data() : state.patchId
        // Delivering since then, as far as we know: no status resumed over the session's suspend meanwhile - only an
        // activation does (`StateSyncer.resumeSchedule`) - so the resume, and the replacement, are dated at the patch's
        // start, what it delivered from there counted. Its start unknown, at the retry: the time between not counted.
        startPatchSession(
            patchId: namedId,
            at: start,
            activatedAt: activatedAt,
            isDelivering: state.pumpState.isDelivering,
            deliveringSince: syncedStart
        )
    }

    /// A status, taken, showed a patch running under an id other than the previous patch's, with an activation sent
    /// and no session started since (`MedtrumPumpState.activationSentAt`): the new patch activated, its answer lost - the
    /// sheet dismissed since, say, or the app killed. Its session starts as a retried activation would start it, with no
    /// retry: nothing else would reach the activation - the settings screen shows a running patch - and until it starts
    /// every command is refused, the session's suspend standing over what the patch delivers. Off the queue statuses
    /// arrive on, once the operation holding the patch is over: the activation itself, whose answer starts the session
    /// if it comes - and with it the marker gone, nothing to start here.
    internal func startSessionOfActivatedPatchSoon() {
        tempBasalEndQueue.async { [weak self] in
            guard let self, !self.backgroundReadsStopped.value else {
                return
            }
            // Not counted as waiting: nothing of the loop waits on it. It holds up this queue all the same - the reads of
            // temp basal ends queued behind it - until the operation holding the patch is over, `commandActivityTimeout`
            // at most: then it gives up, and the session is not started here. The next running status naming an id
            // other than the previous patch's queues it again; one naming none does not - the manual retry stays.
            self.withCommandLock(waits: false) {
                self.doseReportLock.withLock {
                    guard self.state.activationSentAt != nil, self.state.isActivatedWithNoSession else {
                        return
                    }
                    self.log.warning(
                        "The patch shows itself running since the activation went out, its answer lost: starting its session"
                    )
                    self.startSessionOfActivatedPatch()
                }
            }
        }
    }

    func deactivatePatch(_ completion: @escaping (MedtrumDeactivatePatchResult) -> Void) {
        log.info("Deactivate patch pump...")

        // The sync that runs as part of connecting can find that the base has reset, and end the
        // session before we get to stop it - see `handleBaseReset`. It also drops the link, which
        // usually fails the connect. Either way the patch is no longer active.
        let hadActivePatch = !state.pumpState.isSetup
        let sessionEndedWhileConnecting = { hadActivePatch && self.state.pumpState.isSetup }

        link.ensureConnected { error in
            if sessionEndedWhileConnecting() {
                self.log.info("Patch session already ended while connecting, nothing left to deactivate")
                completion(.success)
                return
            }

            // Reported at once, not once the operation holding the lock is over
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }

            guard self.lockCommandLock() else {
                completion(.failure(error: .connectionFailure))
                return
            }
            defer { self.commandLock.unlock() }

            // Or while it waited for the operation ahead of it
            if sessionEndedWhileConnecting() {
                self.log.info("Patch session ended while waiting to deactivate, nothing left to deactivate")
                completion(.success)
                return
            }

            // The temp basal a halt ended, naming no record, has it named first - read with the rest, not taken out from
            // our estimate as the session ends. Before the deactivation is under way: the status may tell of a base reset
            // instead, which ends the session as any status's would (`handleBaseReset`) - nothing left to deactivate then.
            self.askForTheRecordOfTheWaitingEnd()
            if sessionEndedWhileConnecting() {
                self.log.info("Patch session ended with the status asked for, nothing left to deactivate")
                completion(.success)
                return
            }

            self.isDeactivatingPatch = true
            defer { self.isDeactivatingPatch = false }

            // The last chance to read this session's records: what is not read now is finalized from our estimate
            RecordSyncer.syncRecords(pumpManager: self, trigger: .beforeStop)

            let result = self.link.write(StopPatchPacket())
            if case let .failure(error) = result {
                self.log.error("Failed to deactivate pump: \(error)")
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return
            }

            // Connected: the connect synced the patch's status, and its notifications have kept it current since
            self.endPatchSession(deliveryStoppedAt: Date.now, statusIsCurrent: true, disconnect: false)

            self.log.info("Patch deactivated")
            completion(.success)

            self.link.disconnect(force: true)
        }
    }

    func forceDeactivatePatch() {
        log.info("Force deactivating patch...")
        endPatchSession(deliveryStoppedAt: Date.now, statusIsCurrent: false, forced: true)
    }

    /// The base rebooted underneath an activated patch: it came back as a blank, never activated
    /// patch and is not delivering anything. The session cannot be resumed, so it ends here.
    func handleBaseReset(deliveryStoppedAt: Date) {
        log.error("Pump base has reset, patch session is lost - delivery stopped at \(deliveryStoppedAt)")

        // A terminated patch has already raised its own alert, and was not delivering anyway
        let wasRunning = state.pumpState.isRunning

        // What the patch did last is as of the last status of it, before the base went down
        endPatchSession(deliveryStoppedAt: deliveryStoppedAt, statusIsCurrent: false)

        if wasRunning {
            emitAlert(alertType: .baseResetNotification)
        }
    }

    /// The new patch delivers on its schedule from `start` - unless it is not delivering: then the suspend reported stays
    /// outstanding, for the first status that shows it delivering to resume. Its expiry counts from `activatedAt`. A
    /// retried activation: the patch has delivered since `deliveringSince`, on its clock - the resume dated there, on
    /// ours, after the suspend and no later than `start`. The patch replaced there too: a host starts the patch's session
    /// from it.
    private func startPatchSession(patchId: Data, at start: Date, activatedAt: Date, isDelivering: Bool, deliveringSince: Date? = nil) {
        if state.expiryMode == .default {
            // Issued now, due a set time after the activation
            let delay = max(0, state.notificationAfterActivation - start.timeIntervalSince(activatedAt))
            emitAlert(alertType: .patchExpiredNotification(after: delay))
        }

        // From the finals until they are handed over - see `doseReportLock`
        doseReportLock.withLock {
            let sessionWasEnded = state.patchSessionEnded
            var events: [NewPumpEvent] = []
            if !sessionWasEnded {
                // The previous patch was replaced without deactivating it - it fell off, or was swapped outside the app.
                // When it stopped is unknown, so it is taken to have delivered until `start`: a temp basal or a bolus in
                // flight ends there - the bolus warned of as uncertain - and the schedule runs from there. No suspend: a
                // host can take one with a resume at the same time as never ending. Ended, the session finalized all of
                // this then.
                log.warning("Previous patch session was not ended, ending its delivery at activation")
                releaseHeldForTheSessionEnd()
                events.append(contentsOf: finalizedTempBasal(endedAt: start))
                events.append(contentsOf: finalizeInterruptedBolus())
                retractBolusStallAlerts(because: "a new patch was activated")
                events.append(contentsOf: finalizeAllAwaitingDoses(because: "a new patch was activated"))
            } else {
                // Ended, the session finalized every dose of it then, and the state taken up with none any left: a
                // backstop. Its record number would be the old patch's, nothing to tell from the new one's
                // (`isNumberedOnThisPatch`), and kept, it would refuse the new patch's boluses until it ends: final in
                // full, as one out at the end is.
                events.append(contentsOf: finalizeBolusesLeftByTheEndedSession())
            }
            // A temp basal whose command went unanswered, or is pending, is the previous patch's either way: no command
            // goes out while no session runs (`ensureConnectedAndActive`), so one kept since the session ended went out
            // as it ended - a forced deactivation - to the old patch (`keepUnconfirmedTempBasal`, `takeOverPendingTempBasal`
            // drop those too). The new patch runs none of it: kept, it would cancel first, and be warned of as uncertain.
            dropUnconfirmedTempBasal(because: "a new patch was activated")
            if let pending = state.pendingTempBasal {
                log.warning("The temp basal of \(pending.unitsPerHour) U/h sent at \(pending.sentAt) was pending: the previous patch's, dropped")
                state.pendingTempBasal = nil
            }

            // Where the patch activated, its answer lost: minutes before the session starts - the operation holding the patch
            // waited out - or hours, at a retry. Dated at `start`, a host would split the patch in two at it. On our clock,
            // never before the previous session's end: its deactivation, nor the suspend it reported - and never after the
            // resume: a suspend begun before the deactivation (a base reset dates its end at the delivery stop) can put the
            // end past where the resume lands.
            // A resume in a later second than the suspend - see `earliestResume`
            var resumeStart = start
            if isDelivering, state.basalDose.type == .suspend {
                let floor = Self.earliestResume(after: state.basalDose.startDate)
                resumeStart = max(deliveringSince.map { patchTimeOnOurClock($0, notBefore: floor, notAfter: start) } ?? start, floor)
            }
            var replacedAt = start
            if let deliveringSince {
                let ended = max(
                    state.previousPatch?.deactivatedAt ?? .distantPast,
                    state.basalDose.type == .suspend ? state.basalDose.startDate : .distantPast
                )
                replacedAt = patchTimeOnOurClock(deliveringSince, notBefore: min(ended, start), notAfter: start)
            }
            if isDelivering { replacedAt = min(replacedAt, resumeStart) }
            events.append(NewPumpEvent.replacedPump(date: replacedAt))
            if isDelivering {
                let resumeDose = UnfinalizedDose(resumeStartTime: resumeStart, insulinType: state.insulinType)
                if state.basalDose.type == .suspend {
                    // Only a suspend that was reported gets a resume: a host can take one without it as suspended before it
                    events.append(NewPumpEvent.resume(dose: resumeDose.toDoseEntry()))
                    state.basalDose = resumeDose
                    keepUntilStored(resumeDose)
                } else if !sessionWasEnded {
                    let basalDose = UnfinalizedDose(
                        basalRate: state.currentBaseBasalRate,
                        insulinType: state.insulinType,
                        startDate: start
                    )
                    events.append(NewPumpEvent.basal(dose: basalDose.toDoseEntry()))
                    state.basalDose = basalDose
                } else if state.basalDose.type != .tempBasal {
                    // Nothing to report: the first activation, or a status of the new patch showed it delivering already
                    state.basalDose = resumeDose
                    state.basalDoseIsPlaceholder = true
                }

                // What commands check: the old patch may have left it suspended or running a temp basal, and it would
                // stay so until the first status that shows the new patch's basal. A temp basal a status of the new patch
                // showed running, its activation's answer lost, stays.
                state.basalState = state.basalDose.type == .tempBasal ? .tempBasal : .active
            } else {
                // A resume now would count the time until the patch resumes as delivered. The suspend outstanding - the
                // old session's, or one the status that showed it suspended recorded - stays, for the first status that
                // shows it delivering to resume.
                state.basalState = .suspended
            }

            state.patchSessionEnded = false
            state.activationSentAt = nil
            state.initialReservoir = nil
            // A status of this patch named its id since the session ended, its records taken up there (`StateSyncer.sync`):
            // not again - the cursor and the session's start as it set them, the numbers answers claimed since kept. Its
            // id as the status had it: the next status naming it is no new patch's, its records not taken up again.
            let recordsTakenUp = sessionWasEnded && !patchId.isEmpty && !state.patchId.isEmpty &&
                patchId.toUInt64() & 0xFFFF == state.patchId.toUInt64() & 0xFFFF
            if !recordsTakenUp {
                state.patchId = patchId
                // Record numbers restart with the patch
                state.resetRecordSequence()
                state.lastSegmentStart = nil
                recordStore.clear()
            }
            state.patchActivatedAt = activatedAt
            state.lastSync = Date.now
            if !sessionWasEnded {
                // Every dose of the previous session is final: none left to settle what is not
                state.settleOrphanedUncertainDeliveries(at: now())
            }
            notifyStateDidChange()

            emitPumpEvents(events)
            // Final in full as the state was taken up, no status since to tell of them on (`reportBolusFromLastRun`):
            // their finals in this batch, told of now
            for dose in bolusesCountedAtSessionEndUntold {
                warnOfBolusCountedAtSessionEnd(dose)
            }
        }
    }

    /// Every bolus not final with no session running - running, or waiting on its record: one an earlier build left so,
    /// taken over after a kill as its session ended, or kept running. As the state is taken up with none (`init`), and as
    /// the next session starts (`startPatchSession`), a backstop. Its record numbers are the old patch's, nothing to tell
    /// from the next one's (`isNumberedOnThisPatch`), and kept, it would refuse the next patch's boluses until it ends:
    /// final in full, as one out as the session ended is, noted as uncertain - the host warned and the user told, or, with
    /// no host yet, as soon as there is one (`reportBolusFromLastRun`). Only under `doseReportLock`; the caller emits
    /// them - or, as the state is taken up, they go out with the first batch.
    internal func finalizeBolusesLeftByTheEndedSession() -> [NewPumpEvent] {
        let left = ([state.bolusDose].compactMap { $0 } + state.awaitingRecord).filter { $0.type == .bolus && !$0.isFinalized }
        if let running = state.bolusDose {
            endBolusStallWatch(
                running,
                delivered: running.deliveredUnits,
                receivedAt: now(),
                receivedUptime: uptime(),
                "its patch session ended",
                endSeen: false
            )
        }
        state.bolusDose = nil
        var events: [NewPumpEvent] = []
        for dose in left {
            log.warning(
                "The bolus of \(dose.value) U sent at \(dose.sentAt.map { "\($0)" } ?? "-") is not final, its session ended: " +
                    "the old patch's - final in full"
            )
            guard let event = finalizeInFullAtSessionEnd(dose) else {
                continue
            }
            warnOfBolusCountedAtSessionEnd(dose)
            events.append(event)
        }
        return events
    }

    /// The one place a patch session ends: deactivation, a forced deactivation, and a base reset. Its records are out
    /// of reach from here on, so everything still running or waiting on a record is finalized now, from our estimate.
    /// Delivery stopped at `deliveryStoppedAt`, unless it is known to have stopped already - `statusIsCurrent`: the
    /// patch's state as last reported is its state now. `forced`: nothing tells delivery stopped - a forced deactivation,
    /// the old patch maybe on the body still - so a bolus running counts in full (`finalizeInterruptedBolus`).
    private func endPatchSession(deliveryStoppedAt: Date, statusIsCurrent: Bool, forced: Bool = false, disconnect: Bool = true) {
        // From the finals until they are handed over - see `doseReportLock`
        doseReportLock.lock()
        defer { doseReportLock.unlock() }

        // Delivery cannot have stopped before the running dose began - nor at a resume's instant, see `earliestAfter`
        let stoppedAt = max(deliveryStoppedAt, Self.earliestAfter(state.basalDose))

        // Suspended already - by the patch halting, or by a suspend - its suspend was reported then, and stands while the
        // patch can't have resumed: in a state it never leaves, one it never delivered in or no longer does, or a current
        // one that shows it not delivering. Nothing more is reported then. Otherwise it may have resumed unseen - a
        // suspend ends on its own, out of range too - and the suspend is reported now.
        // Or no session runs: the suspend is the one it ended with, nothing resumed since - only an activation does - so
        // nothing of ours can have resumed. A force after a deactivation, the patch shown running: the old one, or the
        // new one whose activation's answer was lost - neither delivering for us.
        let hasStopped = state.basalDose.type == .suspend && (state.patchSessionEnded ||
            state.pumpState.isTerminated || state.pumpState.isSetup || (statusIsCurrent && !state.pumpState.isDelivering))

        // A suspend held back for the records of the temp basal whose command went unanswered - out of reach now - goes
        // out with this batch, ahead of what it reports: never behind a suspend or a resume after it
        releaseHeldForTheSessionEnd()

        var events = finalizedTempBasal(endedAt: stoppedAt)
        events.append(contentsOf: finalizeInterruptedBolus(countsInFull: forced))
        // Over with their patch: deactivated, forced off, or its base reset
        retractBolusStallAlerts(because: "the patch session ended")
        events.append(contentsOf: finalizeAllAwaitingDoses(because: "the patch session ended"))
        if !hasStopped {
            var suspendStart = stoppedAt
            if state.basalDose.type == .suspend {
                // Never over the open suspend: oref0 pairs each suspend with the first resume after it - the next
                // patch's for both - and zeroes the time from this one to it twice: IOB too low. That one is resumed
                // first, where the patch was last known suspended - its last status showing it so, else just after it
                // began - in a later second than it (`earliestResume`); what it delivered from there to this suspend
                // counted as scheduled, IOB overstated at most. Not at `lastSync`: a command's answer since - a basal
                // profile's - would date it past a resume unseen, and zero what the patch delivered from there. This
                // one in a later second still.
                let suspended = state.basalDose.startDate
                let knownSuspendedUntil = state.pumpState.isDelivering ? suspended :
                    min(state.lastShownNotDeliveringAt ?? suspended, stoppedAt)
                let resumeDose = UnfinalizedDose(
                    resumeStartTime: max(knownSuspendedUntil, Self.earliestResume(after: suspended)),
                    insulinType: state.insulinType
                )
                events.append(NewPumpEvent.resume(dose: resumeDose.toDoseEntry()))
                state.basalDose = resumeDose
                keepUntilStored(resumeDose)
                suspendStart = max(stoppedAt, Self.earliestResume(after: resumeDose.startDate))
            }
            let suspendDose = UnfinalizedDose(suspendStartTime: suspendStart)
            events.append(NewPumpEvent.suspend(dose: suspendDose.toDoseEntry()))
            state.basalDose = suspendDose
            keepUntilStored(suspendDose)
        }
        dropUnconfirmedTempBasal(because: "the patch session ended")

        // Ended already - a force after a deactivation, or no session started since: the previous patch is recorded - unless
        // a patch's statuses named another id since, a new patch's whose activation's answer was lost, now forced out
        // itself: that one is the previous patch, whose statuses are not taken from here on (`isEndedSessionsPatchRunning`)
        if !state.patchSessionEnded || (!state.patchId.isEmpty && state.patchId != state.previousPatch?.patchId) {
            state.previousPatch = PreviousPatch(
                patchId: state.patchId,
                lastStateRaw: state.pumpState.rawValue,
                lastSyncAt: state.lastSync,
                battery: state.battery,
                activatedAt: state.patchActivatedAt ?? Date.distantPast,
                deactivatedAt: stoppedAt,
                initialReservoirLevel: state.initialReservoir,
                reservoirLevel: state.reservoir
            )
        }

        state.patchId = Data()
        state.resetRecordSequence()
        state.lastSegmentStart = nil
        recordStore.clear()
        state.pumpState = .none
        state.backupSessionToken = state.sessionToken
        state.sessionToken = Data()
        state.initialReservoir = nil
        state.patchSessionEnded = true
        // An activation sent to the patch that ends here - its session not started, its answer lost - is done with
        state.activationSentAt = nil
        state.lastSync = Date.now
        // What commands check, until the next patch's session starts
        state.basalState = .suspended
        // Every dose of the session is final: none left to settle what is not
        state.settleOrphanedUncertainDeliveries(at: now())
        notifyStateDidChange()

        emitPumpEvents(events)

        if disconnect {
            link.disconnect(force: true)
        }
    }

    func clearAlert(alertType: AlertType, completion: @escaping (Bool) -> Void) {
        log.info("Clearing alert - alertType: \(alertType.rawValue)")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(false)
                return
            }

            let clearAlertResult = self.link.write(ClearAlertPacket(alertType: alertType))
            if case let .failure(error) = clearAlertResult {
                self.log.error("Failed to clear alert: \(error)")
                completion(false)
                return
            }

            let resumeResult = self.link.write(ResumePumpPacket())
            if case let .failure(error) = resumeResult {
                self.log.error("Failed to resume patch: \(error)")
                completion(false)
                return
            }

            self.syncPumpData { _ in
                self.log.info("Alert cleared!")
                completion(true)
            }
        }
    }

    func updatePatchSettings(completion: @escaping (MedtrumUpdatePatchResult) -> Void) {
        log.info("Update patch settings...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }

            let package = SetPatchPacket(
                alarmSettings: self.state.alarmSetting,
                hourlyMaxInsulin: self.state.maxHourlyInsulin,
                dailyMaxInsulin: self.state.maxDailyInsulin,
                expirationTimer: self.state.expiryMode.timer
            )
            let result = self.link.write(package)
            if case let .failure(error) = result {
                self.log.error("Failed to update settings: \(error)")
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return
            }

            self.log.info("Patch settings updated!")
            completion(.success)
        }
    }
}

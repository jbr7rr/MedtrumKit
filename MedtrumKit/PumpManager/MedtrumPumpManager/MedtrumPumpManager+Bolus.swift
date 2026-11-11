import LoopKit

public extension MedtrumPumpManager {
    func createBolusProgressReporter(reportingOn: DispatchQueue) -> (any LoopKit.DoseProgressReporter)? {
        guard let doseEntry = state.bolusDose else {
            return nil
        }

        let reporter = MedtrumDoseProgressReporter(dose: doseEntry, reportingQueue: reportingOn)
        bolusProgressReporters.mutate { reporters in
            reporters.cleanupDeallocatedElements()
            _ = reporters.insert(reporter)
        }

        // An update pushed between creating it and registering it would not reach it until the next one
        reporter.update()
        return reporter
    }

    func estimatedDuration(toBolus units: Double) -> TimeInterval {
        // At the rate the patch was seen delivering
        units / UnfinalizedDose.observedBolusUnitsPerMinute * TimeInterval(minutes: 1)
    }

    func enactBolus(
        units: Double,
        activationType: LoopKit.BolusActivationType,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        // Floored onto the patch's steps, once: sent as it is, an amount between two steps would go out as the nearest -
        // more than asked for, maybe. This one amount is the bolus from here on - the packet, the write-ahead, the dose
        // and its identity, every match against what the patch shows.
        let requested = units
        let units = roundToSupportedBolusVolume(units: requested)
        guard units > 0 else {
            log.error("Bolus of \(requested) U is below the patch's minimum of 0.05 U: refused, nothing sent")
            completion(.deviceState(MedtrumConnectError.isBelowMinimumBolus))
            return
        }
        if requested > (supportedBolusVolumes.last ?? 0) + Self.stepNoise {
            log.warning("Bolus of \(requested) U is above the patch's maximum: sending \(units) U")
        } else if units != requested {
            log.info("Bolus of \(requested) U is not on the patch's steps: sending \(units) U")
        }

        guard state.bolusState == .noBolus else {
            log.error("Pump is in bolus state...")
            completion(.deviceState(MedtrumConnectError.isBolussing))
            return
        }

        guard state.basalState != .suspended else {
            log.error("Pump is suspended...")
            completion(.deviceState(MedtrumConnectError.isSuspended))
            return
        }

        let duration = estimatedDuration(toBolus: units)
        log.info("Enact bolus - \(units)U, \(duration)sec")

        // Until the SetBolus is answered nothing of this bolus is in the state but `pendingBolus`: its error paths leave
        // the rest alone - what is there is another operation's, a bolus running or a cancel waiting to go out
        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error.pumpManagerError)
                return
            }

            // Again holding the command lock: a bolus or a suspend may have gone out while this one waited for it
            guard self.state.bolusState == .noBolus else {
                self.log.error("Pump is in bolus state...")
                completion(.deviceState(MedtrumConnectError.isBolussing))
                return
            }

            // A halt shown from here on - as the command waits for the host, say - and the bolus is not written
            let haltsBefore = self.haltsSeen.value

            guard self.state.basalState != .suspended else {
                self.log.error("Pump is suspended...")
                completion(.deviceState(MedtrumConnectError.isSuspended))
                return
            }

            // A temp basal whose records are read as it ended, its read not begun - the one restored after a restart,
            // the connect's status leaving it to the queue, which waits on this command: read first, as a command that
            // ends one reads it, within the same budget. The bolus's batch would take it out from our estimate.
            if self.pendingTempBasalEnd != nil {
                // One a halt ended, naming no record: named first
                self.askForTheRecordOfTheWaitingEnd()
                RecordSyncer.finishTempBasalEnd(
                    pumpManager: self,
                    inCommandUntil: self.now().addingTimeInterval(Self.tempBasalEndReadBudget)
                )
            }

            let sentAt = Date.now
            let sentUptime = self.uptime()
            // The newest record known, or claimed: every number an answer gave is an earlier bolus's, below this one's
            // own - see `MedtrumPumpState.answeredBolusRecords`. The known one lags a claimed one whose completion was lost.
            let sequenceAtSend = max(self.state.currentSequenceNumber, self.state.answeredBolusRecords.max() ?? 0)
            // The patch those numbers are of: a number of another patch says nothing of this one's records
            let sequencePatchId = self.state.recordNumbersPatchId

            // On disk before it goes out: killed before its answer, the app comes back with it - see `pendingBolus`
            self.doseReportLock.withLock {
                self.earlyBolusCompletion = nil
                self.state.pendingBolus = PendingBolus(
                    units: units,
                    sentAt: sentAt,
                    sequenceAtSend: sequenceAtSend,
                    sequencePatchId: sequencePatchId,
                    automatic: activationType.isAutomatic
                )
                self.pendingDoseHandedOut = false
            }
            // Not written unless the host has it: killed after the write, the app would come back without it
            guard self.handOverPendingDose(
                "the bolus of \(units) U",
                until: .now() + self.dosingHandOverTimeout,
                orElse: {
                    self.state.pendingBolus = nil
                    if let early = self.earlyBolusCompletion {
                        self.log.error(
                            "A completion of \(early.delivered) U, record \(early.record.map { "#\($0)" } ?? "-"), came " +
                                "while the bolus that is not written waited for the host: dropped"
                        )
                    }
                    self.earlyBolusCompletion = nil
                }
            ) else {
                self.log.warning(
                    "The host did not take the state within \(Int(self.dosingHandOverTimeout)) s, nor read it: the bolus of " +
                        "\(units) U is not written, it fails - not delivered"
                )
                self.notifyStateDidChange()
                completion(.deviceState(MedtrumConnectError.stateNotSaved(tempBasalCancelled: false)))
                return
            }

            // The patch showed itself halted as the command waited: not written - off the state the host has, which has it
            // pending, before the command fails
            let halted = self.doseReportLock.withLock { () -> (halted: Bool, early: EarlyBolusCompletion?) in
                guard self.haltedSince(haltsBefore) else {
                    return (false, nil)
                }
                self.state.pendingBolus = nil
                defer { self.earlyBolusCompletion = nil }
                return (true, self.earlyBolusCompletion)
            }
            if halted.halted {
                self.log.error("The patch showed a halt as the bolus of \(units) U waited for the host: not written, it fails")
                if let early = halted.early {
                    self.log.error(
                        "A completion of \(early.delivered) U, record \(early.record.map { "#\($0)" } ?? "-"), came " +
                            "while the bolus that is not written waited for the host: dropped"
                    )
                }
                self.handOverState(before: "failing the bolus")
                // Or the session ended meanwhile - a forced deactivation - which leaves it suspended
                let sessionEnded = self.doseReportLock.withLock { self.state.patchSessionEnded }
                completion(.deviceState(sessionEnded ? MedtrumConnectError.noActivePatch : MedtrumConnectError.isSuspended))
                return
            }

            // When it is written - after the wait for the host, which `sentAt`, its identity, is from before: a status
            // received before then says nothing of it (`statusPredatesCommand`)
            let writtenAt = Date.now
            let writtenUptime = self.uptime()
            let writeResult = self.link.write(SetBolusPacket(bolusAmount: units))
            let outcome = MedtrumCommandOutcome(writeResult)
            // Where an answered bolus's progress is judged from (`checkBolusStall`)
            let answeredUptime = self.uptime()

            var writeError: MedtrumWriteError?
            if case let .failure(error) = writeResult {
                writeError = error
            }

            // Never left the phone, or turned down: nothing to report
            guard outcome == .accepted || outcome == .unknown else {
                self.log.error("Failed to write (\(outcome)): \(writeError?.localizedDescription ?? "-")")
                // On disk before the command fails: killed after it, the app must not come back with a bolus that never
                // ran
                if let early = self.doseReportLock.withLock({ () -> EarlyBolusCompletion? in
                    self.state.pendingBolus = nil
                    defer { self.earlyBolusCompletion = nil }
                    return self.earlyBolusCompletion
                }) {
                    self.log.error(
                        "A completion of \(early.delivered) U, record \(early.record.map { "#\($0)" } ?? "-"), came " +
                            "while the bolus that failed was sent: dropped"
                    )
                }
                self.handOverState(before: "failing the bolus")
                completion(.communication(writeError))
                return
            }

            // Unanswered, the patch may be delivering it: running and counted in full until a notification shows it
            // delivering or its deadline passes, and never sent again. Dated from when it went out, as one taken over
            // after a kill is (`takeOverPendingBolus`): one identity, whichever run reports it.
            let doseEntry = UnfinalizedDose(
                units: units,
                duration: duration,
                activationType: activationType,
                insulinType: self.state.insulinType,
                confirmation: outcome == .unknown ? .uncertain : .confirmed,
                startDate: sentAt
            )
            doseEntry.noteCommand(sentAt: sentAt, uptime: sentUptime, sequence: sequenceAtSend, patchId: sequencePatchId)
            doseEntry.noteWritten(at: writtenAt, uptime: writtenUptime)

            // Running and reported in one step - see `doseReportLock` - and no longer pending: the state the host saves
            // as it takes the report has the one, not the other. A completion that came before the answer is taken now.
            // Unless the session ended while it was out - checked in the same step, a forced deactivation's end under it.
            let registered = self.doseReportLock.withLock { () -> (registered: Bool, early: EarlyBolusCompletion?) in
                guard !self.state.patchSessionEnded else {
                    if let final = self.finalizeBolusOfEndedSession(doseEntry, unanswered: outcome != .accepted) {
                        self.emitPumpEvents([final])
                    }
                    return (false, nil)
                }
                // The record named is the patch's whose session runs
                if case let .success(data) = writeResult, let response = data as? SetBolusResponse {
                    self.noteBolusAnswer(response, of: doseEntry)
                }
                self.state.bolusDose = doseEntry
                self.state.pendingBolus = nil
                // Known to run: watched for a stall from its answer on. One unanswered is once a step confirms it.
                if outcome == .accepted {
                    self.startBolusStallWatch(doseEntry, answeredUptime: answeredUptime)
                }
                self.emitPumpEvents([NewPumpEvent.bolus(unfinalizedDose: doseEntry)], replacePendingEvents: false)
                defer { self.earlyBolusCompletion = nil }
                return (true, self.earlyBolusCompletion)
            }
            self.notifyStateDidChange()

            guard registered.registered else {
                // Delivered by the old patch, answered - or, unanswered, it may be: counted in full either way, nothing of
                // it heard from after, as one running as the session ended is - warned of, the user told so
                self.warnOfBolusCountedAtSessionEnd(doseEntry)
                completion(outcome == .accepted ? nil : .uncertainDelivery)
                return
            }
            let early = registered.early

            // Over before its answer came. Unanswered, it stays uncertain - counted in full, and warned of - whatever
            // came meanwhile: its record settles it.
            if let early {
                if outcome == .accepted {
                    self.completeBolusEarly(doseEntry, early)
                } else {
                    self.log.warning(
                        "A completion of \(early.delivered) U, record \(early.record.map { "#\($0)" } ?? "-"), came " +
                            "before the bolus went unanswered: counted in full until its record"
                    )
                }
            }

            guard outcome == .accepted else {
                self.log.error(
                    "Bolus of \(units) U went out unanswered (\(writeError?.localizedDescription ?? "-")): it may be " +
                        "delivering. Counted in full until the patch shows it, or its record says otherwise - not sent again"
                )
                self.doseReportLock.withLock {
                    self.noteUncertainDelivery(.bolus, .unanswered, of: doseEntry)
                }
                self.warnOfUncertainBolus(doseEntry)
                completion(.uncertainDelivery)
                return
            }

            completion(nil)
        }
    }

    /// The answer to SetBolus names the record the patch allocated for the bolus, and when it started it - unless it
    /// is another patch's answer, which says nothing of ours: its record is then looked for near when it went out
    private func noteBolusAnswer(_ response: SetBolusResponse, of dose: UnfinalizedDose) {
        guard let recordSequence = response.recordSequence, let patchId = response.patchId,
              let startTime = response.startTime
        else {
            log.warning("Set bolus answer carries no record, its record is looked for near when it went out")
            return
        }

        guard patchId == state.patchId.toUInt64() & 0xFFFF else {
            log.error(
                "Set bolus answered for patch \(patchId), this is \(state.patchId.toUInt64()) - " +
                    "its record is looked for near when it went out"
            )
            return
        }

        dose.noteAnswer(recordSequence: recordSequence, pumpStartTime: startTime)
        noteAnsweredBolusRecord(recordSequence)
        log.info("Bolus is record #\(recordSequence), patch start \(startTime)")
    }

    /// `dose`, its SetBolus out as the session ended under it - a deactivation forced meanwhile, from the main queue -
    /// the answer in now, or the command gone unanswered (`unanswered`). It went to the old patch, still on the body:
    /// answered, the patch delivers it. Nothing of that patch is taken from here on (`StateSyncer.isEndedSessionsPatchRunning`)
    /// - no progress, no completion, no record - so it is final at once, at the amount programmed: never less than it
    /// delivered - noted as uncertain, as one running as the session ended is: what it delivered is never heard. Never
    /// running: the next patch takes boluses from its activation on. Unanswered, it may not have run: counted in full
    /// all the same. The caller warns of it (`warnOfBolusCountedAtSessionEnd`). Returns its final, for the caller to
    /// hand over - nil if it had one. Only under `doseReportLock`.
    internal func finalizeBolusOfEndedSession(_ dose: UnfinalizedDose, unanswered: Bool) -> NewPumpEvent? {
        state.pendingBolus = nil
        if let early = earlyBolusCompletion {
            log.info(
                "A completion of \(early.delivered) U, record \(early.record.map { "#\($0)" } ?? "-"), came before the " +
                    "answer: the bolus is final at its full amount all the same"
            )
        }
        earlyBolusCompletion = nil

        log.warning(
            "The patch session ended while the bolus of \(dose.value) U was out\(unanswered ? ", unanswered" : ""): sent to " +
                "the old patch, it is final at once at the full amount - nothing of that patch is heard from here on"
        )
        return finalizeInFullAtSessionEnd(dose)
    }

    /// `dose`, a bolus of the session that ended - or ends now - final at once at the amount programmed, never less than
    /// it delivered: its patch may deliver it still, and nothing of that patch is taken from here on
    /// (`StateSyncer.isEndedSessionsPatchRunning`) - no progress, no completion, no record. Noted as uncertain, and as
    /// one the user is to be told of, saved with it: the caller tells (`warnOfBolusCountedAtSessionEnd`) - or, with no
    /// host yet, `reportBolusFromLastRun` does. Returns its final, nil if it had one. Only under `doseReportLock`.
    internal func finalizeInFullAtSessionEnd(_ dose: UnfinalizedDose) -> NewPumpEvent? {
        dose.finish(.interrupted, deliveredUnits: dose.value, endedAt: nil, at: now())
        noteUncertainDelivery(.bolus, .patchDeactivated, of: dose)
        guard let event = finalize(dose, deliveredUnits: dose.value, .byEstimate, atSessionEnd: true) else {
            return nil
        }
        dose.noteSessionEndAlertPending()
        // Told of here, not once more as one from the last run
        if bolusFromLastRun === dose {
            bolusFromLastRun = nil
        }
        return event
    }

    /// Tells the host of `dose`, a bolus final in full as its session ended, nothing heard of what it delivered
    /// (`finalizeInFullAtSessionEnd`): warned of as uncertain - one whose command went unanswered once, as ever - and
    /// the user told it was counted in full. Once: with no host to tell, it waits for `reportBolusFromLastRun` - or the
    /// first batch to carry its final out (`emitPumpEvents`) - the note saved with the dose - killed before the host saved
    /// the state with it gone, the next run tells again. Holding
    /// `doseReportLock` or not: it only posts.
    internal func warnOfBolusCountedAtSessionEnd(_ dose: UnfinalizedDose) {
        guard pumpDelegate.delegate != nil else {
            log.warning("No pump delegate: the bolus of \(dose.value) U counted in full at the session end is told of later")
            return
        }
        guard dose.takeSessionEndAlert() else {
            return
        }
        if dose.confirmation == .uncertain {
            warnOfUncertainBolus(dose)
        } else {
            pumpDelegate.notify { delegate in
                delegate?.pumpManager(self, didError: .uncertainDelivery)
            }
        }
        emitAlert(alertType: .bolusCountedAsDeliveredAtSessionEnd(units: dose.value, sentAt: dose.sentAt ?? dose.startDate))
        notifyStateDidChange()
    }

    /// See `MedtrumPumpState.answeredBolusRecords`. Kept while its record may still be read: past the cursor, or within
    /// a run behind it - a restart reads again from the cursor as saved.
    internal func noteAnsweredBolusRecord(_ sequence: Int) {
        doseReportLock.withLock {
            let oldest = state.syncedSequenceNumber - RecordSyncer.Trigger.beforeStop.maxRecords
            state.answeredBolusRecords = Array(
                (state.answeredBolusRecords.filter { $0 > oldest } + [sequence]).suffix(Self.answeredBolusRecordsKept)
            )
        }
    }

    /// Records that cannot be read for long pile them up: past this many, the oldest go
    private static let answeredBolusRecordsKept = 50

    /// Cancels the bolus running now - the one whose SetBolus is out, if none runs yet - and that one only: the cancel
    /// waits for the command lock, as long as a command may take, and that bolus may be over by then, a new one running
    /// - the loop's, once the old one's end showed no bolus. Written then, the cancel would stop the new one. So once it
    /// has the link it cancels only if the bolus it was asked for still runs (`MedtrumPumpState.isOfTheRunningBolus`);
    /// otherwise there is nothing to cancel, and it succeeds writing nothing. A second cancel of the same bolus - a retry
    /// the host offers - finds it ended by the first, whichever runs first. Asked for with no bolus known - none running
    /// nor out - it is written as before only if none is by then.
    func cancelBolus(completion: @escaping (LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) -> Void) {
        log.info("Cancelling bolus...")

        let cancel = doseReportLock.withLock { state.beginBolusCancel() }
        notifyStateDidChange()

        let finish = { (result: LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) in
            self.doseReportLock.withLock { self.state.endBolusCancel(cancel) }
            self.notifyStateDidChange()
            completion(result)
        }

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                finish(.failure(error.pumpManagerError))
                return
            }

            // Holding the command lock: no bolus starts from here on until this is over
            guard self.doseReportLock.withLock({ self.state.isOfTheRunningBolus(cancel) }) else {
                let target = cancel.dose.map { "of \($0.startDate)" } ??
                    cancel.pendingSentAt.map { "sent at \($0)" } ?? "none known"
                self.log.info("The bolus this cancel was asked for (\(target)) is over, or another runs: nothing to cancel, not writing it")
                finish(.success(nil))
                return
            }

            let result = self.link.write(CancelBolusPacket())
            if case let .failure(error) = result {
                self.log.error("Failed to cancel bolus: \(error.localizedDescription)")
                finish(.failure(.communication(error)))
                return
            }

            self.log.info("Bolus cancelled!")

            // Ended at the last amount the patch reported, and off the running bolus in one step - only if it still is
            // the running one: a completion seen meanwhile ended it already. The completion the patch sends after the
            // cancel raises the amount (`raiseCancelledBolus`), its record fixes it.
            self.doseReportLock.withLock {
                guard let doseEntry = self.state.bolusDose, !doseEntry.isFinished,
                      cancel.dose.map({ $0 === doseEntry }) ?? true,
                      cancel.pendingSentAt.map({ $0 == doseEntry.sentAt }) ?? true
                else {
                    return
                }

                var events = self.runningTempBasal()
                events.append(contentsOf: self.awaitRecord(doseEntry, .cancelled, endedAt: Date.now))
                self.endBolusStallWatch(
                    doseEntry,
                    delivered: doseEntry.deliveredUnits,
                    receivedAt: self.now(),
                    receivedUptime: self.uptime(),
                    "cancelled"
                )
                self.state.bolusDose = nil
                self.state.lastSync = Date.now
                self.emitBolusEvents(events)
            }

            finish(.success(nil))
        }
    }
}

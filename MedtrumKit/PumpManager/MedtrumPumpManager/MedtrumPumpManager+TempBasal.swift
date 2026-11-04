import LoopKit

public extension MedtrumPumpManager {
    func enactTempBasal(
        unitsPerHour: Double,
        for duration: TimeInterval,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        enactTempBasal(unitsPerHour: unitsPerHour, duration: duration, automatic: true, completion: completion)
    }

    func enactTempBasal(
        unitsPerHour: Double,
        duration: TimeInterval,
        automatic: Bool,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        log.info("Setting temp basal at \(unitsPerHour)U/hr for \(duration)s")

        guard state.bolusState == .noBolus else {
            log.error("Pump is in bolus state...")
            completion(.deviceState(MedtrumConnectError.isBolussing))
            return
        }

        // A suspended patch runs no temp basal
        guard state.basalState != .suspended else {
            log.error("Pump is suspended...")
            completion(.deviceState(MedtrumConnectError.isSuspended))
            return
        }

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error.pumpManagerError)
                return
            }

            // Again holding the command lock: a bolus may have gone out while this waited for it, and the patch is not
            // sent a temp basal while one runs
            guard self.state.bolusState == .noBolus else {
                self.log.error("Pump is in bolus state...")
                completion(.deviceState(MedtrumConnectError.isBolussing))
                return
            }

            // A halt shown from here on leaves the patch's basal in doubt - see `requestStatusAfterHalt`
            let haltsBefore = self.haltsSeen.value

            // The status of the reconnect may have found it suspended
            guard self.state.basalState != .suspended else {
                self.log.error("Pump is suspended...")
                completion(.deviceState(MedtrumConnectError.isSuspended))
                return
            }

            // When the temp basal so far ended, if a cancel ended it - and the answer, which names the record the patch
            // wrote for it
            var cancelledAt: Date?
            var cancelSentAt: Date?
            var cancelAnswer: CancelTempBasalPacketResponse?

            defer {
                self.doseReportLock.withLock {
                    self.tempBasalCancelInFlight = nil
                    self.scheduleSetAsideForTheCancel = nil
                }
            }

            // The set is not written unless the host takes the state with it pending (`handOverPendingDose`): one that
            // can't take it now is not sent the cancel either - the command fails with nothing sent, the temp basal
            // running runs on, not the schedule till the next loop (and the loop's bolus after it, which the failed set
            // stops). One wait for the command: the set's counts from here, but never less than a hand-over takes.
            var handOverDeadline: DispatchTime?
            if self.state.basalState == .tempBasal, duration >= .ulpOfOne {
                let deadline = DispatchTime.now() + self.dosingHandOverTimeout
                guard self.handOverState(until: deadline) else {
                    self.log.warning(
                        "The host did not take the state within \(Int(self.dosingHandOverTimeout)) s: the temp basal of " +
                            "\(unitsPerHour) U/h is not set, it fails - nothing sent, the temp basal running runs on"
                    )
                    completion(.deviceState(MedtrumConnectError.stateNotSaved(tempBasalCancelled: false)))
                    return
                }
                handOverDeadline = deadline

                // Halted meanwhile: the status that showed it ended the temp basal running - nothing to cancel, nor set
                guard !self.doseReportLock.withLock({ self.haltedSince(haltsBefore) }) else {
                    self.log.error(
                        "The patch showed a halt as the command waited for the host: the temp basal of \(unitsPerHour) " +
                            "U/h is not set, it fails - nothing sent"
                    )
                    completion(.deviceState(MedtrumConnectError.isSuspended))
                    return
                }
            }

            // The temp basal the cancel ends, if one goes out
            var cancelling: UnfinalizedDose?

            if self.state.basalState == .tempBasal {
                // From here on this command reports what follows the temp basal running, whatever its outcome: the scheduled
                // basal a status shows meanwhile is the cancel's own - see `isCancelInFlight`
                cancelling = self.state.basalDose
                self.doseReportLock.withLock { self.tempBasalCancelInFlight = cancelling }

                // Need to cancel temp basal first before setting temp basal - dated on the manager's clock, as everything this
                // command dates: the same as ours, but for tests that move it
                let sentAt = self.now()
                cancelSentAt = sentAt
                let cancelResult = self.link.write(CancelTempBasalPacket())
                if case let .failure(error) = cancelResult {
                    // Unanswered, the patch may have stopped it: it stays running, counted, until a status says
                    let outcome = MedtrumCommandOutcome(error)
                    self.log.error("Failed to cancel temp basal (\(outcome)): \(error.localizedDescription)")
                    if outcome == .unknown {
                        self.noteUnansweredCancel(sentAt: sentAt)
                    }
                    // The schedule a status showed meanwhile is not the command's to report after all
                    self.takeScheduleSetAsideForTheCancel()
                    completion(outcome == .unknown ? .uncertainDelivery : .communication(error))
                    return
                }
                // On the manager's clock, as the schedule after it: the same as ours, but for tests that move it
                cancelledAt = self.now()

                // Cancelling ends the temp basal, which is exactly when the patch writes its record -
                // so this response carries the number of the record it just wrote for it
                if case let .success(data) = cancelResult, let response = data as? CancelTempBasalPacketResponse {
                    self.adoptRecordSequence(response.basalSequence, from: "Cancel temp basal")
                    self.noteAnsweredSegment(startingAt: response.basalStartTime)
                    cancelAnswer = response
                    // Had the temp basal whose command went unanswered run, this is its record: read it early, ahead of
                    // the finals of the ones after it - see `lastRecordOfOpenTempBasalEnds`
                    self.doseReportLock.withLock {
                        self.state.unconfirmedTempBasal?.noteEndRecord(Int(response.basalSequence))
                    }
                }

                // Not if a status ended it meanwhile - showing the patch halted, between the answer and here
                self.doseReportLock.withLock {
                    if self.state.basalDose === cancelling {
                        self.state.basalState = .active
                    }
                }
                self.log.info("Cancelled temp basal!")
            }

            if duration < .ulpOfOne {
                // Need to cancel temp basal, but is already cancelled
                // Only need to report back to algorithm - unless a status showed the patch halted meanwhile: it tells
                let reported = self.reportScheduleUnlessHalted(
                    endedAt: nil,
                    endedBy: cancelAnswer,
                    sentAt: cancelSentAt,
                    cancelled: cancelling,
                    haltsBefore: haltsBefore,
                    before: "completing the cancel"
                )
                // The session ended while it was out - forced: the old patch's, nothing of it is reported
                if !reported, self.doseReportLock.withLock({ self.state.patchSessionEnded }) {
                    completion(.deviceState(MedtrumConnectError.noActivePatch))
                    return
                }
                guard reported || cancelledAt != nil else {
                    completion(.deviceState(MedtrumConnectError.isSuspended))
                    return
                }

                completion(nil)
                return
            }

            // The temp basal whose command went unanswered, kept: had it run, the cancel's answer names its record. Read
            // now, before the set: final from it ahead of the new one's first report, which takes Loop's watermark past it
            if let cancelAnswer {
                self.readUnconfirmedTempBasalsRecords(through: Int(cancelAnswer.basalSequence))
            } else if cancelledAt == nil {
                // No cancel went out - a status showed a segment begun after its command, or the run before was killed
                // during this read: its record, if written, is no later than the newest the patch has
                self.readUnconfirmedTempBasalsRecords(through: self.state.currentSequenceNumber)
            }
            // A suspend held back for those records goes out ahead of anything this command reports
            self.releaseHeldForUnconfirmedRead()

            let sentAt = self.now()
            let sentUptime = self.uptime()
            let sequenceAtSend = self.state.currentSequenceNumber

            // On disk before it goes out: killed before its answer, the app comes back with it - see `pendingTempBasal`
            let priorSegmentStart = self.doseReportLock.withLock { () -> Date? in
                let priorSegmentStart = self.state.lastSegmentStart
                self.state.pendingTempBasal = PendingTempBasal(
                    unitsPerHour: unitsPerHour,
                    duration: duration,
                    automatic: automatic,
                    sentAt: sentAt,
                    sequenceAtSend: sequenceAtSend,
                    priorSegmentStart: priorSegmentStart,
                    cancelledAt: cancelledAt,
                    cancelSegmentStart: cancelledAt.flatMap { at in
                        cancelAnswer.flatMap {
                            self.cancelSegmentOnPatch(at: at, cancel: $0, cancelSentAt: cancelSentAt, tempBasal: self.state.basalDose)
                        }
                    }
                )
                self.pendingDoseHandedOut = false
                return priorSegmentStart
            }
            // Not written unless the host has it, as a bolus: killed after the write, the app would come back with the patch
            // running a temp basal it has no dose of, uncounted. The cancel that went out first stands: the scheduled basal
            // from it, reported as when the set fails.
            let deadline = max(handOverDeadline ?? .now() + self.dosingHandOverTimeout, .now() + Self.stateHandOverTimeout)
            guard self.handOverPendingDose("the temp basal of \(unitsPerHour) U/h", until: deadline, orElse: {
                self.state.pendingTempBasal = nil
            }) else {
                self.log.warning(
                    "The host did not take the state in time, nor read it: the temp basal of \(unitsPerHour) U/h is not " +
                        "written, it fails" + (cancelledAt != nil ? " - the temp basal before was cancelled" : "")
                )
                if let cancelledAt {
                    self.failSetAfterCancel(
                        cancelledAt: cancelledAt,
                        cancelAnswer: cancelAnswer,
                        cancelSentAt: cancelSentAt,
                        cancelled: cancelling,
                        haltsBefore: haltsBefore
                    )
                } else {
                    self.notifyStateDidChange()
                }
                completion(.deviceState(MedtrumConnectError.stateNotSaved(tempBasalCancelled: cancelledAt != nil)))
                return
            }

            // A status showed the patch halted since the command began - during the cancel, the reads, the wait for the
            // host: not written, off the state the host has, which has it pending. What follows the cancel, if one went
            // out, the status tells.
            let haltedMeanwhile = self.doseReportLock.withLock { () -> Bool in
                guard self.haltedSince(haltsBefore, cancelling: cancelling) else {
                    return false
                }
                self.state.pendingTempBasal = nil
                return true
            }
            if haltedMeanwhile {
                self.log.error(
                    "The patch showed a halt as the command ran: the temp basal of \(unitsPerHour) U/h is not written, it " +
                        "fails" + (cancelledAt != nil ? " - the temp basal before was cancelled" : "")
                )
                if let cancelledAt {
                    self.failSetAfterCancel(
                        cancelledAt: cancelledAt,
                        cancelAnswer: cancelAnswer,
                        cancelSentAt: cancelSentAt,
                        cancelled: cancelling,
                        haltsBefore: haltsBefore
                    )
                } else {
                    self.handOverState(before: "failing the temp basal")
                }
                // Or the session ended meanwhile - a forced deactivation - which leaves it suspended
                let sessionEnded = self.doseReportLock.withLock { self.state.patchSessionEnded }
                completion(.deviceState(sessionEnded ? MedtrumConnectError.noActivePatch : MedtrumConnectError.isSuspended))
                return
            }

            // When it is written, after the wait for the host - see `enactBolus`
            let writtenAt = self.now()
            let writtenUptime = self.uptime()
            let packet = SetTempBasalPacket(rate: unitsPerHour, duration: duration)
            let tempBasalResult = self.link.write(packet)
            // Held back meanwhile - the patch halted as the set went out: out ahead of what the answer reports
            self.releaseHeldForUnconfirmedRead()
            let outcome = MedtrumCommandOutcome(tempBasalResult)

            if case let .failure(error) = tempBasalResult, outcome != .unknown {
                self.log.error("Failed to set temp basal (\(outcome)): \(error.localizedDescription)")

                // Never sent, or turned down: the patch runs what it did before the set. The scheduled basal, if the
                // cancel ended a temp basal - reported, nothing pending in the state saved with it. With no cancel nothing
                // changed: a temp basal still running runs on. Off the saved state before the command fails either way:
                // killed after it, the app must not come back with a temp basal that never ran.
                if let cancelledAt {
                    self.failSetAfterCancel(
                        cancelledAt: cancelledAt,
                        cancelAnswer: cancelAnswer,
                        cancelSentAt: cancelSentAt,
                        cancelled: cancelling,
                        haltsBefore: haltsBefore
                    )
                } else {
                    self.doseReportLock.withLock { self.state.pendingTempBasal = nil }
                    self.handOverState(before: "failing the temp basal")
                }

                completion(.communication(error))
                return
            }

            // The response describes the segment that just started. The sequence in it belongs to the segment this
            // one replaced, not to this one.
            var response: SetTempBasalResponse?
            if case let .success(data) = tempBasalResult {
                response = data as? SetTempBasalResponse
            }
            if let response {
                self.adoptRecordSequence(response.basalSequence, from: "Set temp basal")
                self.noteAnsweredSegment(startingAt: response.basalStartTime)
            }

            // Only the segment we asked for is ours: anything else, or no answer at all, and the patch may or may not
            // be running it
            guard let response, RecordSyncer.isCommandedTempBasal(response, rate: unitsPerHour) else {
                if let response {
                    self.log.error(
                        "Set temp basal answered with a \(response.basalType) segment at \(response.basalValue) U/h " +
                            "from \(response.basalStartTime), not the temp basal of \(unitsPerHour) U/h we set"
                    )
                }

                // Kept before the batch below goes out, so the state saved with it has it
                let unconfirmed = UnfinalizedDose(
                    tempRate: unitsPerHour,
                    duration: duration,
                    insulinType: self.state.insulinType,
                    automatic: automatic,
                    confirmation: .uncertain,
                    startDate: sentAt
                )
                unconfirmed.noteWritten(at: writtenAt, uptime: writtenUptime)
                let kept = self.keepUnconfirmedTempBasal(
                    unconfirmed,
                    sentAt: sentAt,
                    sentUptime: sentUptime,
                    sequenceAtSend: sequenceAtSend,
                    priorSegmentStart: priorSegmentStart,
                    // The schedule from the cancel, reported right after: else what ran as it went out - with where it began
                    // on the patch clock, if known
                    basalBefore: cancelledAt ?? self.reportedBasalStart,
                    basalBeforeOnPatch: cancelledAt.map { at in
                        cancelAnswer.flatMap {
                            self.cancelSegmentOnPatch(at: at, cancel: $0, cancelSentAt: cancelSentAt, tempBasal: self.state.basalDose)
                        }
                    } ?? self.reportedBasalPatchStart
                )

                // The session ended while it was out - forced: what it went to is the old patch, nothing of it ours
                guard kept else {
                    completion(.deviceState(MedtrumConnectError.noActivePatch))
                    return
                }
                // What the host was told stands: the temp basal before ended at the cancel, then the schedule. With
                // the set unanswered the link may be gone: its record is not read now - our estimate stands in, and a
                // sync reads the record later, changing nothing.
                if let cancelledAt, self.state.basalDose.type == .tempBasal {
                    self.reportScheduledBasal(
                        tempBasalEndedAt: cancelledAt,
                        endedBy: cancelAnswer,
                        sentAt: cancelSentAt,
                        readsRecords: outcome != .unknown
                    )
                }

                completion(.uncertainDelivery)
                return
            }

            self.log.info("Set temp basal!")

            // Never before a resume dated up to a second ahead - see `earliestAfter`
            let tempBasalDose = UnfinalizedDose(
                tempRate: unitsPerHour,
                duration: duration,
                insulinType: self.state.insulinType,
                automatic: automatic,
                startDate: max(self.now(), Self.earliestAfter(self.state.basalDose))
            )
            tempBasalDose.noteCommand(sentAt: sentAt, uptime: sentUptime, sequence: sequenceAtSend)
            tempBasalDose.noteWritten(at: writtenAt, uptime: writtenUptime)

            // The patch's own clock, where its records start
            tempBasalDose.setPumpStartTime(response.basalStartTime)
            let skew = response.basalStartTime.timeIntervalSince(tempBasalDose.startDate)
            self.log.info("Temp basal patch start \(response.basalStartTime) (skew \(String(format: "%+.1f", skew))s)")

            // The old one ends where the new one starts, and both go out in one batch: the old one mutable until its
            // records - the one the cancel named - are read, after this command
            let replaced = self.replaceRunningBasal(endedBy: cancelAnswer, sentAt: cancelSentAt) {
                self.state.basalState = .tempBasal
                self.state.lastSync = Date.now
                return (tempBasalDose, NewPumpEvent.tempBasal(dose: tempBasalDose.toDoseEntry(isMutable: true)))
            }
            self.notifyStateDidChange()
            // The session ended while it was out - forced: the old patch runs it, not ours to count
            guard replaced else {
                completion(.deviceState(MedtrumConnectError.noActivePatch))
                return
            }
            self.requestStatusAfterHalt(seenSince: haltsBefore)

            completion(nil)
        }
    }

    /// A status showed the patch halted while the command ran - `haltsBefore` counted as it began - and the command
    /// leaves a temp basal reported running: the set's answer said it started, the halt that the patch may not run it.
    /// The status after shows which, and ends it if halted - dated when it is received, a halt telling no time of its
    /// own: a full status is asked for right after the command, once, not left to the next heartbeat's - unless another
    /// status arrives first, which tells the same. Off the command's thread, once it is over, holding the command lock.
    private func requestStatusAfterHalt(seenSince haltsBefore: Int) {
        guard haltsSeen.value != haltsBefore else {
            return
        }
        let running = state.basalDose
        guard running.type == .tempBasal, !running.isFinished else {
            return
        }
        let statusesBefore = statusesHandled.value
        log.info("The patch showed a halt during the command, the temp basal of \(running.startDate) reported running: asking for its status")

        tempBasalEndQueue.async { [weak self] in
            guard let self else {
                return
            }

            let deadline = Date.now.addingTimeInterval(Self.commandActivityTimeout)
            while self.isCommandActive, Date.now < deadline, !self.backgroundReadsStopped.value {
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard !self.backgroundReadsStopped.value else {
                return
            }
            guard self.statusesHandled.value == statusesBefore else {
                self.log.info("A status arrived since the halt: not asking for another")
                return
            }

            guard let result = self.betweenCommands({ self.link.write(SynchronizePacket()) }) else {
                return
            }
            guard case let .success(data) = result, let response = data as? SynchronizePacketResponse else {
                self.log.warning("The status asked for after the halt did not come: the next one tells")
                return
            }
            self.handleStatus(response, duringReconnect: false, fullSync: true)
            self.notifyStateDidChange()
        }
    }

    /// Whether a status showed the patch halted since the command began - `haltsBefore` counted then - or it is taken to
    /// be suspended, or `cancelling`, the temp basal the command cancelled, is no longer the basal running: a status
    /// ended it. What the command was to write next is not written then, nor the schedule from its cancel reported - the
    /// suspend that status reported would be left open, no resume after it (`requestStatusAfterHalt`). Only under
    /// `doseReportLock`.
    internal func haltedSince(_ haltsBefore: Int, cancelling: UnfinalizedDose? = nil) -> Bool {
        haltsSeen.value != haltsBefore || state.basalState == .suspended || state.basalDose.type == .suspend ||
            cancelling.map { state.basalDose !== $0 } == true
    }

    /// A status is handled - showing the patch halted, `halted`
    internal func noteStatusHandled(halted: Bool) {
        statusesHandled.mutate { $0 += 1 }
        if halted {
            haltsSeen.mutate { $0 += 1 }
        }
    }

    /// `tempBasalEndedAt`: when the temp basal running so far stopped. `endedBy`: the answer to the cancel that stopped
    /// it, which names its record.
    /// `sentAt`: when that cancel went out. `readsRecords`: records may be read on the way - the one the cancel named, and
    /// those of temp basals ended open before - not after a command that went unanswered: the link may be gone. The
    /// cancel's answer still tells where the patch ended it. `unless`: checked in the step that reports it, under
    /// `doseReportLock` - true, nothing is reported, nothing pending. Returns whether it was reported.
    @discardableResult private func reportScheduledBasal(
        tempBasalEndedAt: Date? = nil,
        endedBy cancel: CancelTempBasalPacketResponse? = nil,
        sentAt cancelSentAt: Date? = nil,
        readsRecords: Bool = true,
        unless notReported: (() -> Bool)? = nil
    ) -> Bool {
        let tempBasalEndedAt = tempBasalEndedAt ?? now()
        var reported = false
        replaceRunningBasal(endedBy: cancel, sentAt: cancelSentAt, readsRecords: readsRecords) {
            if let notReported, notReported() {
                state.pendingTempBasal = nil
                return nil
            }
            reported = true
            let basalDose = UnfinalizedDose(
                basalRate: state.currentBaseBasalRate,
                insulinType: state.insulinType,
                startDate: tempBasalEndedAt
            )
            // Its start on the patch clock - what this one is told from, skew-free - the same instant on both clocks: the
            // temp basal it ends still the running one
            if let cancel,
               let onPatch = cancelSegmentOnPatch(
                   at: basalDose.startDate,
                   cancel: cancel,
                   cancelSentAt: cancelSentAt,
                   tempBasal: state.basalDose
               )
            {
                basalDose.setPumpStartTime(onPatch)
            }
            state.lastSync = Date.now
            return (basalDose, NewPumpEvent.basal(dose: basalDose.toDoseEntry()))
        }
        notifyStateDidChange()
        return reported
    }

    /// The set of a command that cancelled `cancelled`, the temp basal running, at `cancelledAt` failed - not written, or
    /// never sent: the patch runs its schedule from the cancel, reported - unless a status showed it halted meanwhile
    /// (`haltsBefore` counted as the command began), or ended `cancelled` otherwise: see `reportScheduleUnlessHalted`.
    /// Nothing pending either way.
    private func failSetAfterCancel(
        cancelledAt: Date,
        cancelAnswer: CancelTempBasalPacketResponse?,
        cancelSentAt: Date?,
        cancelled: UnfinalizedDose?,
        haltsBefore: Int
    ) {
        reportScheduleUnlessHalted(
            endedAt: cancelledAt,
            endedBy: cancelAnswer,
            sentAt: cancelSentAt,
            cancelled: cancelled,
            haltsBefore: haltsBefore,
            before: "failing the temp basal"
        )
    }

    /// The schedule from the cancel of `cancelled`, if one went out, at `endedAt` (now, if nil): reported - unless a status
    /// showed the patch halted since the command began (`haltsBefore` counted then), or ended `cancelled` otherwise
    /// (`haltedSince`), checked in the step that would report it: its end is then that status's, what the patch runs the
    /// status after it tells, asked for if `cancelled` still runs (`requestStatusAfterHalt`) - a schedule from the cancel
    /// would come dated behind the suspend that status reported, leaving it open. Nothing pending either way, the state
    /// handed over before `action`. Returns whether it was reported.
    @discardableResult private func reportScheduleUnlessHalted(
        endedAt: Date?,
        endedBy cancelAnswer: CancelTempBasalPacketResponse?,
        sentAt cancelSentAt: Date?,
        cancelled: UnfinalizedDose?,
        haltsBefore: Int,
        before action: String
    ) -> Bool {
        let halted = { self.haltedSince(haltsBefore, cancelling: cancelled) }
        if !doseReportLock.withLock(halted),
           reportScheduledBasal(tempBasalEndedAt: endedAt, endedBy: cancelAnswer, sentAt: cancelSentAt, unless: halted)
        {
            return true
        }
        log.warning(
            "A status showed the patch halted, or ended the temp basal cancelled, while the command ran: the scheduled " +
                "basal is not reported from the cancel - the status tells"
        )
        doseReportLock.withLock { state.pendingTempBasal = nil }
        handOverState(before: action)
        requestStatusAfterHalt(seenSince: haltsBefore)
        return false
    }

    /// The basal `change` returns takes over from the running one, and both go out in one batch. `change` runs under
    /// `doseReportLock`, sets the rest of the state the batch is saved with, and returns the new basal and its report -
    /// nil to change nothing. The temp basal whose set is pending, if any, is settled by the change: no longer pending
    /// once the new basal is in place.
    ///
    /// A temp basal running till then that the new one replaces back to back - the new one starting before the old one
    /// was to end - ends open where the new one starts: reported ended, and mutable, its records read after this command
    /// (`readOpenTempBasalEndsSoon`). Nothing comes between the two for the host to fill.
    ///
    /// Any other end of a temp basal - a cancel to the schedule, a suspend, a resume, one that ran its course before the
    /// next - leaves a gap after it, or a dose of another kind: it ends final, and every temp basal ended open before it
    /// with it - from their records, read right here up to the one the cancel that ended it named (`endedBy`), else from
    /// our estimate. A command's path, holding `commandLock`: no other command comes between its answer and these reads,
    /// which block on the link for `tempBasalEndReadBudget` at most. The host has the state before they start - handed
    /// over first, outside that budget (`stateHandOverTimeout`): killed during them, the app comes back with the new
    /// basal running and the temp basal ended, its records read on the first link (`takeOverTempBasalEndFromLastRun`).
    /// So too before the full status asked for a temp basal a halt ended naming no record (`askForTheRecordOfTheWaitingEnd`),
    /// whose status may have its records read right away: the app comes back waiting on it, the new basal running.
    /// With no cancel, `lastRecord` is the record the patch wrote as the command ended it, where known: a suspend's, a
    /// resume's - read in the same way.
    /// Returns false, changing nothing, if the session ended while the command was out: the command fails then.
    @discardableResult internal func replaceRunningBasal(
        endedBy cancel: CancelTempBasalPacketResponse? = nil,
        sentAt cancelSentAt: Date? = nil,
        lastRecord: Int? = nil,
        readsRecords: Bool = true,
        _ change: () -> (dose: UnfinalizedDose, event: NewPumpEvent)?
    ) -> Bool {
        var sessionEnded = false
        let endedOpen = doseReportLock.withLock { () -> Bool in
            // The session ended while the command was out - forced from the main queue: what it ended was finalized with
            // it, and nothing goes out over its suspend, a resume least of all. Only the activation resumes delivery. Nor
            // is a temp basal it set pending any more: it went to the old patch - after a restart it would be taken for
            // one the patch may run, unconfirmed, carried into the next session.
            guard !state.patchSessionEnded else {
                log.warning("The patch session ended while the command was out: its change of the basal is not reported")
                state.pendingTempBasal = nil
                sessionEnded = true
                return false
            }
            guard let next = change() else {
                return false
            }

            // A temp basal a status ended meanwhile - the suspend the patch announced, say - goes out final from the
            // records it names, and the new basal after it, in the same batch: the state handed over before they are
            // read has the new basal running
            let running = state.basalDose
            if let pending = pendingTempBasalEndStorage, running.type != .tempBasal || running.isFinished {
                hold(next, after: pending)
                state.basalDose = next.dose
                state.pendingTempBasal = nil
                return false
            }

            // A resume behind a suspend held back since the reads before it
            if running.type != .tempBasal || running.isFinished, holdWithHeldSuspend(next.dose) {
                state.basalDose = next.dose
                state.pendingTempBasal = nil
                return false
            }

            // The patch ran the old one for less time than we did up to the cancel: it had stopped it before, unseen, and
            // ran the schedule since - that gap is the host's to fill. Told on each clock alone, skew-free.
            let stoppedAt = running.type == .tempBasal ? cancel.flatMap { cancel in
                cancelSentAt.flatMap { stopBeforeCancel(of: running, patchEnd: cancel.basalStartTime, cancelSentAt: $0) }
            } : nil
            let stoppedBefore = stoppedAt != nil

            if next.dose.type == .tempBasal, running.type == .tempBasal, !running.isFinished,
               next.dose.startDate <= running.estimatedEndDate, !stoppedBefore
            {
                endOpen(running, at: next.dose.startDate, patchEnd: cancel?.basalStartTime, lastRecord: cancel.map { Int($0.basalSequence) })
                state.basalDose = next.dose
                state.pendingTempBasal = nil
                // Those that can be settled without their records go final now, the oldest first - the rest mutable,
                // ended where the next one starts
                let finals = settleOpenTempBasalEnds()
                let open = openTempBasalEnds.compactMap { NewPumpEvent.finishedDose($0, entry: $0.toDoseEntry(isMutable: true)) }
                emitPumpEvents(finals + open + [next.event])
                return true
            }

            let ending = beginTempBasalEnd(
                endedAt: stoppedAt ?? next.dose.startDate,
                patchEnd: cancel?.basalStartTime,
                lastRecord: readsRecords ? cancel.map { Int($0.basalSequence) } ?? lastRecord : nil,
                readsOpenEnds: readsRecords,
                then: next
            )
            state.basalDose = next.dose
            state.pendingTempBasal = nil
            if !ending {
                keepUntilStored(next.dose)
                emitPumpEvents([next.event])
            }
            return false
        }

        if sessionEnded {
            // Off the saved state before the command fails: killed after it, the app must not come back with it pending
            handOverState(before: "failing the command")
            return false
        }

        if endedOpen {
            readOpenTempBasalEndsSoon()
            return true
        }

        guard let ending = pendingTempBasalEnd else {
            // The record a cancel named for the temp basal whose command went unanswered, read after the command
            if let record = lastRecordOfOpenTempBasalEnds, record > state.syncedSequenceNumber {
                readOpenTempBasalEndsSoon()
            }
            return true
        }

        // Ended by a halt whose status named no record: named here, not with what this command did held behind it - the
        // state handed over first, its status may have the records read at once. Not after a command that went
        // unanswered: the link may be gone, and the ask would only wait out its timeout.
        var handedOver = false
        if readsRecords, ending.awaitsRecord {
            handOverState(before: "asking for the status that names the records")
            handedOver = true
            askForTheRecordOfTheWaitingEnd()
        }

        // Nothing to hand over for when nothing will be read: the batch settling it saves the state with it
        if !handedOver, RecordSyncer.wouldRead(ending, pumpManager: self) {
            handOverState(before: "reading the records")
        }
        RecordSyncer.finishTempBasalEnd(
            pumpManager: self,
            inCommandUntil: now().addingTimeInterval(Self.tempBasalEndReadBudget)
        )
        return true
    }

    func syncBasalRateSchedule(
        items: [LoopKit.RepeatingScheduleValue<Double>],
        completion: @escaping (Result<LoopKit.BasalRateSchedule, any Error>) -> Void
    ) {
        log.info("Sync-ing basal schedule...")
        guard let basalSchedule = DailyValueSchedule<Double>(dailyItems: items) else {
            completion(.failure(NSError(domain: "Basal schedule is empty...", code: -1)))
            return
        }

        // No session runs: kept for the next patch, which its activation writes it to (`activatePatch`) - as the patch
        // settings screen keeps its settings with no patch active. Refused, the host would keep the profile it had: none
        // could be changed between patches. Holding the command lock - an activation reads it under it, its session
        // started before it lets go - off the caller's queue, which it may hold up as long as a command.
        // Not with a patch shown running, nor with an activation sent - before any status shows it running, the patch
        // still shown primed: activated, its answer lost, its session starting on the next status - or by the retry -
        // with the profile it was activated with, which this would never be written to. Refused: the host keeps the
        // profile it had, the user tries again once the session runs.
        if state.patchSessionEnded {
            guard !mayRunWithNoSession else {
                log.warning("No patch session runs, but a patch is running or was activated: the basal schedule is not kept")
                completion(.failure(MedtrumConnectError.noActivePatch))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var stored = false
                var running = false
                let locked = self.withCommandLock(waits: false) {
                    guard self.state.patchSessionEnded else {
                        return
                    }
                    guard !self.mayRunWithNoSession else {
                        running = true
                        return
                    }
                    self.state.basalSchedule = BasalSchedule(entries: items)
                    stored = true
                }
                guard locked else {
                    completion(.failure(MedtrumConnectError.failedToConnectToDevice))
                    return
                }
                guard !running else {
                    self.log.warning("No patch session runs, but a patch is running or was activated: the basal schedule is not kept")
                    completion(.failure(MedtrumConnectError.noActivePatch))
                    return
                }
                guard stored else {
                    // A session started meanwhile: written to its patch
                    self.syncBasalRateSchedule(items: items, completion: completion)
                    return
                }
                self.log.info("No patch session runs: the basal schedule is kept for the next patch's activation")
                self.notifyStateDidChange()
                completion(.success(basalSchedule))
            }
            return
        }

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            let schedule = BasalSchedule(entries: items)
            let packet = SetBasalProfilePacket(basalProfile: schedule.toData())
            let result = self.link.write(packet)

            if case let .failure(error) = result {
                self.log.error("Failed to sync basal schedule: \(error.localizedDescription)")
                // Unanswered, the patch may have set it all the same - and split the temp basal running
                if MedtrumCommandOutcome(error) == .unknown, self.disableRecordMatchOfRunningTempBasal(unanswered: true) {
                    self.notifyStateDidChange()
                }
                completion(.failure(error))
                return
            }

            self.disableRecordMatchOfRunningTempBasal()

            self.state.basalSchedule = schedule
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.log.info("Basal schedule sync complete!")

            completion(.success(basalSchedule))
        }
    }

    /// With no session, a patch may deliver on the profile it was activated with: shown running, or an activation sent
    /// whose answer was lost (`MedtrumPumpState.activationSentAt`) - the patch still shown primed, no status since
    private var mayRunWithNoSession: Bool {
        state.pumpState.isRunning || doseReportLock.withLock { state.activationSentAt != nil }
    }

    /// The patch restarts a running temp basal in a new segment on a profile change, so it ends up with a record per
    /// segment, and the amount its statuses show restarts: it is finalized from our estimate, its rate × duration. The
    /// same for the unconfirmed temp basal, which the patch may be running - a record of a part of it would finalize it
    /// with that part. `unanswered`: the profile command went out and no answer came back. Returns whether it applied.
    @discardableResult private func disableRecordMatchOfRunningTempBasal(unanswered: Bool = false) -> Bool {
        doseReportLock.withLock { () -> Bool in
            let candidates = [state.basalDose, state.unconfirmedTempBasal].compactMap { $0 }
            var applied = false

            for tempBasal in candidates where tempBasal.type == .tempBasal && tempBasal.disableRecordMatch() {
                applied = true
                log.warning(
                    "Basal profile \(unanswered ? "sent unanswered" : "set") during the temp basal of " +
                        "\(tempBasal.startDate)\(tempBasal === state.unconfirmedTempBasal ? ", whose command went unanswered" : ""), " +
                        "the patch \(unanswered ? "may have split" : "split") it into segments: it will be finalized " +
                        "from our estimate, its rate × duration, not from its records"
                )
            }

            return applied
        }
    }

    func syncDeliveryLimits(
        limits: LoopKit.DeliveryLimits,
        completion: @escaping (Result<LoopKit.DeliveryLimits, any Error>) -> Void
    ) {
        log.warning("Skipping sync delivery limits (not supported by Medtrum)")
        completion(.success(limits))
    }
}

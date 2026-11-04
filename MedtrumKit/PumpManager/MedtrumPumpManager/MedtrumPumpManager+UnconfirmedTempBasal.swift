import LoopKit

public extension MedtrumPumpManager {
    /// How much earlier than when its command went out an unanswered temp basal is dated from the start its segment or
    /// record shows: the skew is known to a few seconds only
    internal static let unansweredStartSlack: TimeInterval = 5

    /// A suspend `dose` a status shows, following the running basal - not a temp basal of ours - while the temp basal
    /// whose command went unanswered is kept and the patch has records past the cursor: its own, if it ran. Reported
    /// now, the suspend has Loop fill up to its start - its watermark past the unanswered one, whose final after it Loop
    /// would not count. Held instead: saved with the state (`heldBasalDoses`) - a restart reports it after all - and left
    /// out of every batch until those records are read, off the queue statuses arrive on once no command is in flight
    /// (a suspend or a resume command reads them itself), then reported - or at once ahead of a set that comes first, or
    /// of anything else a status reports (`releaseHeldForUnconfirmedRead`). A resume after it is held with it
    /// (`holdWithHeldSuspend`), and so is another suspend: neither goes out ahead of it. Unread, it is reported all the
    /// same. The host has no suspend meanwhile - IOB only ever overstated: up to `commandActivityTimeout` waiting for a
    /// command in flight, the wait for the command lock after it, and `tempBasalEndReadBudget` for the reads - some 6 min
    /// at worst, behind a stuck command. Returns false, nothing held: the caller reports it. Only under `doseReportLock`.
    internal func holdForUnconfirmedRead(_ dose: UnfinalizedDose) -> Bool {
        // Behind one held already: released with it, by what releases that one
        if !heldForUnconfirmedRead.isEmpty {
            holdWithTheHeld(dose)
            return true
        }
        guard state.unconfirmedTempBasal != nil, state.currentSequenceNumber > state.syncedSequenceNumber,
              pendingTempBasalEndStorage == nil, state.bolusDose == nil
        else {
            return false
        }
        log.info("Holding the suspend of \(dose.startDate) back until the records of the temp basal whose command went unanswered are read")
        state.heldBasalDoses.append(HeldBasalDose(dose: dose, heldAt: now()))
        heldForUnconfirmedRead.append(dose)

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
            let held = self.doseReportLock.withLock { !self.heldForUnconfirmedRead.isEmpty }
            guard held else {
                return
            }
            self.withCommandLock {
                RecordSyncer.readInCommand(
                    pumpManager: self,
                    through: self.state.currentSequenceNumber,
                    until: self.now().addingTimeInterval(Self.tempBasalEndReadBudget),
                    of: "the temp basal whose command went unanswered, a suspend held back"
                )
            }
            self.releaseHeldForUnconfirmedRead()
        }
        return true
    }

    /// A resume `dose` - a status's, or a command's - while a suspend is held back by `holdForUnconfirmedRead`: held with
    /// it, reported after it in the batch that releases them. Out ahead of it, iAPS would take the patch to have been
    /// suspended since before its history (oref0 `iob/history`: the earliest resume before the earliest suspend) - and
    /// with `suspend_zeros_iob` zero every temp basal before the resume, and the scheduled basal from 8 h back: IOB far
    /// too low. Loop makes nothing of a resume alone, then pairs it with the suspend - but has neither meanwhile, as iAPS:
    /// IOB only ever overstated. Returns false, nothing held: the caller reports it. Only under `doseReportLock`.
    internal func holdWithHeldSuspend(_ dose: UnfinalizedDose) -> Bool {
        guard dose.type == .resume, !heldForUnconfirmedRead.isEmpty else {
            return false
        }
        holdWithTheHeld(dose)
        return true
    }

    /// `dose` held back after those `holdForUnconfirmedRead` holds, released with them - from when the first was held: it
    /// goes for good no earlier than they do (`dropExpiredFinals`). Only under `doseReportLock`.
    private func holdWithTheHeld(_ dose: UnfinalizedDose) {
        log.info("Holding the \(dose.type.rawValue) of \(dose.startDate) back with the suspend held for the records of the temp basal whose command went unanswered")
        let first = heldForUnconfirmedRead.first
        let heldAt = state.heldBasalDoses.first { $0.dose === first }?.heldAt ?? now()
        state.heldBasalDoses.append(HeldBasalDose(dose: dose, heldAt: heldAt))
        heldForUnconfirmedRead.append(dose)
    }

    /// The suspend held back by `holdForUnconfirmedRead`, if any - in a command - reported once the records of the temp
    /// basal whose command went unanswered are read, as a suspend command reads them, or not to be. Read whether held
    /// back or not - a suspend reported, the hold refused (a bolus running at the halt, say): the unanswered one final
    /// from its own ahead of the resume, not left to a sync after it. Nothing to read - none kept, or read up - nothing is.
    internal func releaseHeldAfterUnconfirmedRead() {
        readUnconfirmedTempBasalsRecords(through: state.currentSequenceNumber)
        releaseHeldForUnconfirmedRead()
    }

    /// The suspend held back by `holdForUnconfirmedRead`, if any, reported - with what was held with it, in order - its
    /// records read, or not to be: before a set, a resume command, or anything else a status reports goes out
    internal func releaseHeldForUnconfirmedRead() {
        let released = doseReportLock.withLock { () -> Bool in
            guard !heldForUnconfirmedRead.isEmpty else {
                return false
            }
            heldForUnconfirmedRead = []
            return true
        }
        guard released else {
            return
        }
        emitPumpEvents([])
        notifyStateDidChange()
    }

    /// The patch session ends: the records the suspend held back by `holdForUnconfirmedRead` waits on are out of reach.
    /// It is no longer held back - nor what was held with it: the batch the session's end hands over carries them, ahead
    /// of the suspend or the resume it reports. Only under `doseReportLock`.
    internal func releaseHeldForTheSessionEnd() {
        guard !heldForUnconfirmedRead.isEmpty else {
            return
        }
        log.info("The patch session ends: what was held back for the records of the temp basal whose command went unanswered goes out now")
        heldForUnconfirmedRead = []
    }

    /// The records up to `last` - the one the cancel ahead of a set named, else the newest the patch has - read in the
    /// command, in order from the cursor, before the set, the suspend or the resume is reported: the temp basal whose
    /// command went unanswered, kept, goes final from its own - or is dropped, or split - in a batch ahead of that
    /// report. A temp basal reported running, or a suspend - Loop fills up to its start - has Loop's watermark past the
    /// unanswered one: final behind it, Loop would not count it (`warnIfBehindWhatIsFinal`). Only with no other basal of
    /// ours waiting on its end - nothing else the reads would settle out of turn - and no bolus running. The host has the
    /// state first: killed during the reads, the app comes back with the cancel's outcome and the unanswered one kept, no
    /// set pending. Unread - the link slow, the budget spent - the set goes out all the same, and the record is read
    /// after the command, as before.
    internal func readUnconfirmedTempBasalsRecords(through last: Int) {
        let due = doseReportLock.withLock { () -> Bool in
            let running = state.basalDose
            return state.unconfirmedTempBasal != nil && pendingTempBasalEndStorage == nil
                && (running.type != .tempBasal || running.isFinished) && state.bolusDose == nil
                && last > state.syncedSequenceNumber
        }
        guard due else {
            return
        }

        handOverState(before: "reading the records of the temp basal whose command went unanswered")
        RecordSyncer.readInCommand(
            pumpManager: self,
            through: last,
            until: now().addingTimeInterval(Self.tempBasalEndReadBudget),
            of: "the temp basal whose command went unanswered"
        )
    }

    // MARK: - Temp basal whose command went unanswered

    /// A temp basal whose command went out unanswered - or was answered with another segment - is kept here, unreported:
    /// the patch may or may not run it, and nothing reported may be taken back. A status showing it settles it as
    /// running (`followTempBasalSegment`), its record as a final (`finalizeUnconfirmedTempBasal`) - a record of a part
    /// of it, split at midnight or by a profile change, as running or ended, finalized from our estimate. With neither,
    /// it is dropped as never run once every record the patch told of 15 min past when it ended at the latest was read
    /// (`unconfirmedTempBasalEnd`, `isCaughtUp`, `finalizeOverdueAwaitingDoses`), none that could be its skipped - and
    /// with the patch session. There is no time limit beyond that: while the records cannot be read, or one that could
    /// be its was skipped, it stays and delivery stays uncertain.
    /// Returns false, keeping nothing, if the session ended while the command was out - forced: it went to the old patch,
    /// whatever that runs is not ours to count, and the next patch's session starts clear of it.
    internal func keepUnconfirmedTempBasal(
        _ dose: UnfinalizedDose,
        sentAt: Date,
        sentUptime: TimeInterval?,
        sequenceAtSend: Int,
        priorSegmentStart: Date?,
        basalBefore: Date?,
        basalBeforeOnPatch: Date?
    ) -> Bool {
        dose.noteCommand(
            sentAt: sentAt,
            uptime: sentUptime,
            sequence: sequenceAtSend,
            priorSegmentStart: priorSegmentStart,
            basalBefore: basalBefore,
            basalBeforeOnPatch: basalBeforeOnPatch
        )

        let kept = doseReportLock.withLock { () -> Bool in
            guard !state.patchSessionEnded else {
                state.pendingTempBasal = nil
                return false
            }
            keepUnconfirmed(dose, .unanswered)
            return true
        }

        guard kept else {
            log.warning(
                "Temp basal of \(dose.value) U/h went out unanswered as the patch session ended: sent to the old patch, not kept"
            )
            handOverState(before: "failing the temp basal")
            return false
        }

        log.error(
            "Temp basal of \(dose.value) U/h went out unanswered: kept unreported until a status shows it running, or its " +
                "record turns up"
        )
        notifyStateDidChange()
        return true
    }

    /// `dose`, its command noted, is the unconfirmed temp basal from now on - uncertain for `cause` - and no longer
    /// pending: after it is kept, as `rawValue` reads them. Only under `doseReportLock`.
    private func keepUnconfirmed(_ dose: UnfinalizedDose, _ cause: UncertainDelivery.Cause) {
        if let superseded = state.unconfirmedTempBasal {
            log.warning("The unconfirmed temp basal of \(superseded.value) U/h sent \(superseded.sentAt.map { "\($0)" } ?? "-") is superseded")
            settleUncertainDeliveries(of: superseded, .notConfirmed)
        }
        state.unconfirmedTempBasal = dose
        state.pendingTempBasal = nil
        noteUncertainDelivery(.tempBasal, cause, of: dose)
        // Those skipped before were written before it went out
        state.skippedRecordSequences = []
        // The patch may be running it: the next temp basal cancels first
        state.basalState = .tempBasal
    }

    /// In a new run's state, a SetTempBasal still pending went out and the app was gone before its answer: the patch may
    /// be running it. Kept from here on as one whose command went unanswered is (`keepUnconfirmedTempBasal`) - unreported
    /// until a status or its record shows it ran, dropped if every record shows it never did - dated from when it went
    /// out. The temp basal the cancel before it ended, still running in the state, ends at that cancel, final from our
    /// estimate as with any set gone unanswered - the scheduled basal after it held back for the first batch
    /// (`heldBasalDoses`). Not if its dose was registered: the state was saved as it was, read in part before. Nor with no
    /// session running: no command goes out then, so it went out as the session ended under it - a forced deactivation -
    /// to the old patch, whose runs are not ours to count. Dropped: kept, it would be carried into the next session.
    internal func takeOverPendingTempBasal() {
        doseReportLock.withLock {
            guard let pending = state.pendingTempBasal else {
                return
            }

            guard !state.patchSessionEnded else {
                log.warning(
                    "The temp basal of \(pending.unitsPerHour) U/h sent at \(pending.sentAt) was pending as the patch session " +
                        "ended: sent to the old patch, not ours - dropped"
                )
                state.pendingTempBasal = nil
                return
            }

            let registered = ([state.basalDose, state.unconfirmedTempBasal].compactMap { $0 } + state.awaitingRecord).contains { dose in
                dose.type == .tempBasal && dose.sentAt == pending.sentAt
            }
            guard !registered else {
                log.info("The temp basal of \(pending.unitsPerHour) U/h sent at \(pending.sentAt) was registered already")
                state.pendingTempBasal = nil
                return
            }

            let running = state.basalDose
            if let cancelledAt = pending.cancelledAt, running.type == .tempBasal, !running.isFinished,
               running.startDate < pending.sentAt
            {
                // Kept with its final until the host confirms it: the first batch carries it
                _ = endTempBasalFromEstimate(
                    endedAt: cancelledAt,
                    because: "the app stopped while the temp basal set after its cancel awaited its answer"
                )
                let scheduled = UnfinalizedDose(
                    basalRate: state.currentBaseBasalRate,
                    insulinType: state.insulinType,
                    startDate: cancelledAt
                )
                state.heldBasalDoses.append(HeldBasalDose(dose: scheduled, heldAt: now()))
                state.basalDose = scheduled
            }

            let dose = UnfinalizedDose(
                tempRate: pending.unitsPerHour,
                duration: pending.duration,
                insulinType: state.insulinType,
                automatic: pending.automatic,
                confirmation: .uncertain,
                startDate: pending.sentAt
            )
            dose.noteCommand(
                sentAt: pending.sentAt,
                uptime: nil,
                sequence: pending.sequenceAtSend,
                priorSegmentStart: pending.priorSegmentStart,
                basalBefore: pending.cancelledAt ?? reportedBasalStart,
                // The cancel's segment, as its answer said - else the running basal's own
                basalBeforeOnPatch: pending.cancelledAt != nil ? pending.cancelSegmentStart : reportedBasalPatchStart
            )
            keepUnconfirmed(dose, .appRestarted)
            log.error(
                "The app stopped while the temp basal of \(pending.unitsPerHour) U/h sent at \(pending.sentAt) awaited its " +
                    "answer: it may be running. Kept unreported until a status shows it running, or its record turns up"
            )
        }
    }

    /// The patch answered a later command - a cancel, a set, a resume - with the segment it started then: a segment of
    /// the unconfirmed temp basal started before it, and ended by then
    internal func noteAnsweredSegment(startingAt start: Date) {
        doseReportLock.withLock {
            noteSegmentStart(start)
            state.unconfirmedTempBasal?.noteLaterSegment(startingAt: start)
        }
    }

    /// When the unconfirmed temp basal ended at the latest, if it ran at all: its planned end, or the start of a segment
    /// known to have begun after its command went out (`laterSegmentStart`), on our clock. Its record is written then,
    /// so the wait for it counts from there.
    internal func unconfirmedTempBasalEnd(_ pending: UnfinalizedDose) -> Date {
        let unconfirmed = pending.snapshot
        guard let later = unconfirmed.laterSegmentStart else {
            return pending.estimatedEndDate
        }
        // From the basal before it, on each clock alone - see `unansweredStartOffset` - else through the skew
        guard let basalBefore = unconfirmed.basalBefore, let onPatch = unconfirmed.basalBeforeOnPatch else {
            return patchTimeOnOurClock(later, notBefore: pending.startDate, notAfter: pending.estimatedEndDate)
        }
        let end = basalBefore.addingTimeInterval(later.timeIntervalSince(onPatch))
        return max(min(end, pending.estimatedEndDate), pending.startDate)
    }

    /// A status received at `receivedAt` shows a segment - or a suspend - that started at `start` on the patch clock, and
    /// is not the unconfirmed temp basal's. Started after its command went out, on the patch clock (through the skew,
    /// with `unansweredStartSlack` for it), it began after that command: the temp basal, if it ran at all, ended by
    /// then. Started later than the last segment known when the command went out is not enough: that one can be
    /// stale - a midnight restart we never heard of starts between the two. Returns whether no unconfirmed temp basal
    /// may still run past this segment's start - none is kept, or this one ended it.
    @discardableResult internal func noteSegmentAfterUnconfirmedTempBasal(
        startingAt start: Date,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard let pending = state.unconfirmedTempBasal else {
                return true
            }

            let unconfirmed = pending.snapshot
            // Begun after its command went out - was written, past the wait for the host - by more than the slack, told
            // skew-free where it can be
            let writtenAt = unconfirmed.writtenAt ?? unconfirmed.sentAt ?? pending.startDate
            let afterTheCommand = unansweredStartOffset(of: unconfirmed, sentAt: writtenAt, patchTime: start) > Self.unansweredStartSlack
            guard let prior = unconfirmed.priorSegmentStart, start > prior, afterTheCommand,
                  !Self.statusPredatesCommand(of: unconfirmed, receivedAt: receivedAt, receivedUptime: receivedUptime)
            else {
                return false
            }

            if unconfirmed.laterSegmentStart.map({ start < $0 }) ?? true {
                log.info("A segment from \(start) began after the unconfirmed temp basal's command: it ended by then, if it ran")
            }
            pending.noteLaterSegment(startingAt: start)
            return true
        }
    }

    /// A command is cancelling `dose`, the temp basal running: from the cancel on it reports what follows it - the
    /// temp basal it sets after it, back to back, or the scheduled basal, whatever the outcome - so the scheduled basal a
    /// status shows meanwhile, the second or so between the cancel and the set, is not taken as its end. Only under
    /// `doseReportLock`.
    internal func isCancelInFlight(of dose: UnfinalizedDose) -> Bool {
        tempBasalCancelInFlight === dose
    }

    /// A status received at `receivedAt` showed the schedule from `basal`'s start while the cancel was in flight: set
    /// aside, the latest only, should the cancel fail - see `takeScheduleSetAsideForTheCancel`. Only under `doseReportLock`.
    internal func setAsideForTheCancel(_ basal: BasalData, receivedAt: Date, receivedUptime: TimeInterval) {
        scheduleSetAsideForTheCancel = (basal, receivedAt, receivedUptime)
    }

    /// The cancel failed: no longer in flight, and the schedule a status showed meanwhile, if any, is taken as any status's
    /// - it may have been the patch's own, or the cancel's with its answer lost. On the command's thread.
    internal func takeScheduleSetAsideForTheCancel() {
        let setAside = doseReportLock.withLock { () -> (basal: BasalData, receivedAt: Date, receivedUptime: TimeInterval)? in
            tempBasalCancelInFlight = nil
            defer { scheduleSetAsideForTheCancel = nil }
            return scheduleSetAsideForTheCancel
        }
        guard let setAside else {
            return
        }
        StateSyncer.replayScheduleSetAside(
            setAside.basal,
            receivedAt: setAside.receivedAt,
            receivedUptime: setAside.receivedUptime,
            pumpManager: self
        )
    }

    /// A segment the patch reported, from a status or an answer - see `MedtrumPumpState.lastSegmentStart`. Only under
    /// `doseReportLock`, which orders it against the command that reads it.
    internal func noteSegmentStart(_ start: Date) {
        state.lastSegmentStart = max(state.lastSegmentStart ?? start, start)
    }

    /// Drops the unconfirmed temp basal, never reported. Only under `doseReportLock`.
    internal func dropUnconfirmedTempBasal(because reason: String, neverRan: Bool = false) {
        guard let dose = state.unconfirmedTempBasal else {
            return
        }

        log.warning("Dropping the temp basal of \(dose.value) U/h whose command went unanswered, \(reason)")
        settleUncertainDeliveries(of: dose, neverRan ? .neverRan : .notConfirmed)
        state.unconfirmedTempBasal = nil
    }

    /// `pending`, the unconfirmed temp basal, a status showed running from `shownFrom` - late, over by then - and every
    /// record since it ended was read, none its: it ran, how long and what it delivered unknown. Not dropped as never
    /// run, silently: the host is warned of uncertain delivery, and the settings show it not counted. Not reported from
    /// our estimate either: its record, authoritative, matched nothing - an estimate, dated over a span the status and
    /// what ended it bound at best, would go out behind what the host has after it, a suspend say: Loop would not count
    /// it, and iAPS would count it over what the host already has there. Only under `doseReportLock`.
    internal func dropUnconfirmedTempBasalShownRunning(_ pending: UnfinalizedDose, from shownFrom: Date) {
        log.error(
            "The temp basal of \(pending.value) U/h whose command went unanswered ran - a status showed it from \(shownFrom) " +
                "- and no record read since it ended is its: what it delivered is not counted"
        )
        let key = UncertainDelivery.DoseKey(pending)
        state.mutateUncertainDeliveries { deliveries in
            for index in deliveries.indices where deliveries[index].kind == .tempBasal && deliveries[index].isOf(key) &&
                !deliveries[index].isSettled
            {
                deliveries[index].outcome = .notCounted
                deliveries[index].settledAt = now()
            }
        }
        state.unconfirmedTempBasal = nil
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(self, didError: .uncertainDelivery)
        }
    }

    /// A status received at `receivedAt` shows a temp basal segment, `basal`: one of ours whose cancel went unanswered
    /// still runs; one whose command went unanswered, started since the last segment known before it, runs - reported
    /// from its start on. Any other temp segment is not ours: it changes nothing, but may end the unconfirmed one.
    internal func followTempBasalSegment(_ basal: BasalData, fullSync: Bool, receivedAt: Date, receivedUptime: TimeInterval) {
        doseReportLock.withLock {
            // No session: no temp basal of ours runs - the session's end finalized it, and no command goes out until the
            // next starts - and nothing of either patch is ours to count or start from
            guard !state.patchSessionEnded else {
                log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime), no session runs: not followed")
                return
            }
            let dose = state.basalDose
            let running = dose.snapshot

            // A temp basal runs: the next one cancels first. In one step with the dose a command set - not over the
            // suspend one just recorded, as a status from before it lands: commands would go to a suspended patch.
            if dose.type != .suspend {
                state.basalState = .tempBasal
            }
            let isOurRate = basal.type == .ABSOLUTE_TEMP && abs(basal.rate - dose.value) <= 0.01

            if dose.type == .tempBasal, !running.isFinished {
                if let pumpStartTime = running.pumpStartTime {
                    if isOurRate, abs(basal.startTime.timeIntervalSince(pumpStartTime)) <= RecordSyncer.tempBasalStartTolerance {
                        // What it delivered so far: our estimate of it goes from here, should its records not be read
                        dose.noteStatusDelivery(basal.delivery, receivedAt: receivedAt)

                        if fullSync, let stopUnansweredAt = running.stopUnansweredAt, receivedAt > stopUnansweredAt,
                           dose.clearStopUnanswered()
                        {
                            noteCancelDidNotStop(dose)
                            log.info("A full status shows the temp basal of \(dose.startDate) still running after its unanswered cancel")
                        }
                        return
                    }
                } else if isOurRate, dose.setPumpStartTime(basal.startTime) {
                    // Saved by a build that did not keep the answer's: a later segment's, maybe
                    dose.markFirstSegmentUncertain()
                    log.info("Adopted patch start \(basal.startTime) for the running temp basal")
                    dose.noteStatusDelivery(basal.delivery, receivedAt: receivedAt)
                    return
                }
            }

            guard let pending = state.unconfirmedTempBasal else {
                let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
                if dose.type == .tempBasal, isOurRate, !running.isFinished, let pumpStartTime = running.pumpStartTime,
                   basal.startTime > pumpStartTime,
                   Self.isPatchMidnight(basal.startTime, utcOffset: utcOffset) || running.recordMatchDisabled
                {
                    // The patch restarts the running segment at patch-local midnight, and on a basal profile change
                    log.info(
                        "Status shows the temp basal of \(dose.startDate) restarted by the patch at \(basal.startTime) " +
                            "(patch-local midnight or a profile change), still running"
                    )
                } else if dose.type == .tempBasal, isOurRate, !running.isFinished {
                    log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime), not our temp basal")
                } else {
                    noteSegmentOfNoTempBasalOfOurs(basal, receivedAt: receivedAt, receivedUptime: receivedUptime)
                }
                return
            }

            if !confirmUnconfirmedTempBasal(pending, shownBy: basal, receivedAt: receivedAt) {
                noteSegmentAfterUnconfirmedTempBasal(startingAt: basal.startTime, receivedAt: receivedAt, receivedUptime: receivedUptime)
            }
        }
    }

    /// A status received at `receivedAt` shows a temp basal segment, `basal`, with no unconfirmed temp basal kept, that is
    /// not the one of ours running: unless it is the one whose set is out (`pendingTempBasal`), one of ours that ended
    /// (`awaitingRecord`), or older than a segment known since - stale - the patch runs a temp basal the driver has no dose
    /// of. One set as the app was gone before it was saved, say. What it delivers is counted nowhere: the host is warned
    /// of uncertain delivery, once per segment, and the settings say so. Only under `doseReportLock`.
    private func noteSegmentOfNoTempBasalOfOurs(_ basal: BasalData, receivedAt: Date, receivedUptime: TimeInterval) {
        let tolerance = RecordSyncer.tempBasalStartTolerance
        let running = state.basalDose.snapshot

        // The old patch's, heard from after its session ended - or a patch whose session has not started: none of its
        // temp basals are this session's to count
        guard !state.patchSessionEnded, !state.patchId.isEmpty,
              UInt64(basal.patchId) & 0xFFFF == state.patchId.toUInt64() & 0xFFFF
        else {
            log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime) of patch \(basal.patchId), no session's of ours")
            return
        }
        if let pending = state.pendingTempBasal, RecordSyncer.steps(basal.rate) == RecordSyncer.steps(pending.unitsPerHour) {
            log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime): the temp basal being set")
            return
        }
        // Received before the running basal was put in place - a suspend or a schedule one a command just set has no
        // command time of its own - on the monotonic clock, which a change of the wall clock does not move: one put in
        // place in an earlier run, no status of this run is before. Or older than a segment known since: stale.
        let predatesRunningBasal = running.sentAt == nil && state.basalDoseSince.map { receivedUptime < $0 } == true
        if Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime) ||
            predatesRunningBasal || state.lastSegmentStart.map({ basal.startTime < $0 }) == true
        {
            log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime), from before the latest one known")
            return
        }
        if state.awaitingRecord.contains(where: { dose in
            dose.type == .tempBasal && dose.pumpStartTime.map { abs(basal.startTime.timeIntervalSince($0)) <= tolerance } == true
        }) {
            log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime): a temp basal of ours that ended")
            return
        }

        log.error(
            "Status shows the patch running a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime) that is none " +
                "of ours: what it delivers is not counted"
        )
        guard !unknownTempBasalSegments.contains(basal.startTime) else {
            return
        }
        unknownTempBasalSegments.insert(basal.startTime)

        let start = patchTimeOnOurClock(basal.startTime, notBefore: .distantPast, notAfter: receivedAt)
        var delivery = UncertainDelivery(
            kind: .tempBasal,
            cause: .unknownSegment,
            sentAt: start,
            amount: basal.rate,
            notedAt: now()
        )
        // Nothing of ours settles it
        delivery.outcome = .notCounted
        delivery.settledAt = now()
        state.mutateUncertainDeliveries { deliveries in
            guard !deliveries.contains(where: { $0.cause == .unknownSegment && abs($0.sentAt.timeIntervalSince(start)) < 60 }) else {
                return
            }
            deliveries.append(delivery)
            while deliveries.count > Self.uncertainDeliveriesKept {
                deliveries.remove(at: deliveries.firstIndex(where: \.isSettled) ?? 0)
            }
        }

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
        }
    }

    /// The segment a status shows is the unconfirmed temp basal's: at its rate, started no earlier than the last segment
    /// known before its command went out (and before one a later command started) - on the patch clock, exactly. It
    /// runs: reported from its start on - or, the segment a restart of it, from its command on, and finalized from our
    /// estimate. Only under `doseReportLock`.
    /// The same second counts: the patch can start the temp basal in the second the cancel's STANDARD began, and a
    /// segment of another type starting then can only be the one that replaced it. A late status of it - a later
    /// segment known since, a later command's - changes nothing: its record settles it. Returns whether it was the one.
    private func confirmUnconfirmedTempBasal(
        _ pending: UnfinalizedDose,
        shownBy basal: BasalData,
        receivedAt: Date
    ) -> Bool {
        let unconfirmed = pending.snapshot
        // A segment known to have begun since it - a later command's - and this status says nothing of what runs now: it
        // is late, a notification of before, and running from here the temp basal would end the one running now
        let isStale = state.lastSegmentStart.map { basal.startTime < $0 } == true
        guard basal.type == .ABSOLUTE_TEMP, abs(basal.rate - pending.value) <= 0.01,
              let prior = unconfirmed.priorSegmentStart, basal.startTime >= prior,
              unconfirmed.laterSegmentStart.map({ basal.startTime < $0 }) ?? true
        else {
            log.info(
                "Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime): not the temp basal " +
                    "whose command went unanswered"
            )
            return false
        }

        // Its segment, but late: it ran, and ended by the segment known since - its record settles it, kept as it is.
        // Shown so: should no record turn out to be its, it is not dropped as never run (`finalizeOverdueAwaitingDoses`).
        guard !isStale else {
            log.warning(
                "Status shows the segment of the temp basal of \(pending.value) U/h whose command went unanswered, from " +
                    "\(basal.startTime) - late, a later segment is known: it ran, its record settles it"
            )
            pending.noteShownRunning(from: basal.startTime)
            return true
        }
        // The same over a suspend: a halted patch runs no temp basal - the segment began before the halt, which ended it.
        // Taken to run from here, it would be dated over the suspension, its record clamped to its start. And the same
        // with a segment known to have begun after it (`laterSegmentStart`), its own start before that one: ended by
        // then - a halt's, say, the patch resumed since by a command whose answer told no segment of its own.
        guard state.basalDose.type != .suspend, unconfirmed.laterSegmentStart == nil else {
            log.warning(
                "Status shows the segment of the temp basal of \(pending.value) U/h whose command went unanswered, from " +
                    "\(basal.startTime) - late, " +
                    (state.basalDose.type == .suspend ? "the patch suspended since" : "a segment begun after it is known") +
                    ": it ran, its record settles it"
            )
            pending.noteShownRunning(from: basal.startTime)
            return true
        }

        let sentAt = unconfirmed.sentAt ?? pending.startDate
        // Started well after the command, the segment is a restart of it - at patch-local midnight, on a profile
        // change - not its first: it ran from the command on, and its first record ends at the restart
        let restarted = unansweredStartOffset(of: unconfirmed, sentAt: sentAt, patchTime: basal.startTime) > Self.recordMatchWindow
        let start = restarted ? sentAt : unansweredStart(of: unconfirmed, sentAt: sentAt, patchTime: basal.startTime, notAfter: receivedAt)
        let tempBasalDose = UnfinalizedDose(
            tempRate: pending.value,
            duration: pending.estimatedEndDate.timeIntervalSince(pending.startDate),
            insulinType: pending.insulinType,
            automatic: pending.automatic,
            startDate: start
        )
        tempBasalDose.noteCommand(sentAt: sentAt, uptime: unconfirmed.sentUptime, sequence: unconfirmed.sequenceAtSend ?? 0)
        if let writtenAt = unconfirmed.writtenAt {
            tempBasalDose.noteWritten(at: writtenAt, uptime: unconfirmed.writtenUptime)
        }
        tempBasalDose.setPumpStartTime(basal.startTime)
        // Dated from a status, its start within the match window of its command: nothing to time a stop from
        tempBasalDose.markFirstSegmentUncertain()

        if restarted || unconfirmed.recordMatchDisabled {
            // A record of a part would finalize it with that part
            tempBasalDose.disableRecordMatch()
            log.warning(
                "Status shows the temp basal of \(pending.value) U/h whose command went unanswered running since " +
                    "\(basal.startTime), \(restarted ? "a restart of it" : "split by a profile change"): reported from " +
                    "\(start) on, finalized from our estimate, not from its records"
            )
        } else {
            log.info(
                "Status shows the temp basal of \(pending.value) U/h whose command went unanswered running since " +
                    "\(basal.startTime): reported from \(start) on"
            )
        }

        var events = endTempBasalFromEstimate(endedAt: start, because: "the temp basal whose command went unanswered replaced it")
        events.append(NewPumpEvent.tempBasal(dose: tempBasalDose.toDoseEntry(isMutable: true)))

        state.unconfirmedTempBasal = nil
        state.basalDose = tempBasalDose
        state.basalState = .tempBasal
        state.lastSync = Date.now
        emitPumpEvents(events)
        return true
    }

    /// `record` is the unconfirmed temp basal's: at its rate, started near when its command went out, between the
    /// segments known before (the same second counts, as for a status) and after it. It ran: reported once, final from
    /// its record - unless the record is only a part of it (`runSplitUnconfirmedTempBasal`). Only under
    /// `doseReportLock`.
    /// `ending`: in the read of a temp basal's end that leaves a gap - see `settleTempBasalEnd` - the basal after it in
    /// place: it ended by now, if it ran - it is never put back as running.
    internal func finalizeUnconfirmedTempBasal(
        from record: BasalRecord,
        sequence: Int,
        ending: Bool = false
    ) -> (outcome: String, events: [NewPumpEvent])? {
        guard let pending = state.unconfirmedTempBasal else {
            return nil
        }

        let unconfirmed = pending.snapshot
        let sentAt = unconfirmed.sentAt ?? pending.startDate
        guard RecordSyncer.steps(record.rate) == RecordSyncer.steps(pending.value),
              abs(unansweredStartOffset(of: unconfirmed, sentAt: sentAt, patchTime: record.startTime)) <= Self.recordMatchWindow,
              unconfirmed.priorSegmentStart.map({ record.startTime >= $0 }) ?? true,
              unconfirmed.laterSegmentStart.map({ record.startTime < $0 }) ?? true
        else {
            return nil
        }

        let span = unansweredSpan(of: unconfirmed, sentAt: sentAt, patchTime: record.startTime, notAfter: now(), lasting: record.duration)
        let start = span.start
        let tempBasalDose = UnfinalizedDose(
            tempRate: pending.value,
            duration: pending.estimatedEndDate.timeIntervalSince(pending.startDate),
            insulinType: pending.insulinType,
            automatic: pending.automatic,
            startDate: start
        )
        tempBasalDose.noteCommand(sentAt: sentAt, uptime: nil, sequence: unconfirmed.sequenceAtSend ?? 0)
        // On the wall clock alone, as its command's
        if let writtenAt = unconfirmed.writtenAt {
            tempBasalDose.noteWritten(at: writtenAt, uptime: nil)
        }
        tempBasalDose.setPumpStartTime(record.startTime)

        let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
        if unconfirmed.recordMatchDisabled || Self.isPatchMidnight(record.endTime, utcOffset: utcOffset) {
            return runSplitUnconfirmedTempBasal(pending, as: tempBasalDose, shownBy: record, sequence: sequence, endedBy: ending ? now() : nil)
        }

        let endDate = span.end
        tempBasalDose.finish(endDate >= tempBasalDose.estimatedEndDate ? .completed : .cancelled, endedAt: endDate, at: now())
        state.unconfirmedTempBasal = nil

        log.info(
            "Record \(sequence) is the temp basal of \(pending.value) U/h whose command went unanswered: it ran " +
                "\(String(format: "%.1f", record.duration / 60)) min from \(record.startTime), delivered \(record.delivered) U"
        )
        let events = finalize(tempBasalDose, deliveredUnits: record.delivered, endDate: endDate, .byRecord).map { [$0] } ?? []
        if span.compressed {
            // All of its amount in less time than it ran: counted so by iAPS, maybe not by Loop
            warnNotCounted(
                tempBasalDose,
                because: "fitted into \(Int(endDate.timeIntervalSince(start))) s before a basal dose the host has, after running " +
                    "\(Int(record.duration)) s"
            )
        } else {
            warnIfBehindWhatIsFinal(tempBasalDose)
        }
        return ("finalized unconfirmed temp basal \(start)", events)
    }

    /// `dose`, the temp basal whose command went unanswered, is reported only now, starting before Loop's watermark - a
    /// later temp basal reported meanwhile, say, its gap since the one before filled final up to its start (see
    /// `LoopWatermark`). Loop stores no basal dose starting before it: it may never count this one. iAPS does. The host
    /// is warned of uncertain delivery, and the settings show it not counted. Only under `doseReportLock`.
    private func warnIfBehindWhatIsFinal(_ dose: UnfinalizedDose) {
        guard let watermark = state.loopWatermark, dose.startDate < watermark else {
            return
        }
        warnNotCounted(dose, because: "starting before Loop's watermark, \(watermark)")
    }

    /// The host is warned that `dose`, the temp basal whose command went unanswered, may not be counted, `reason` - and the
    /// settings show it not counted. Only under `doseReportLock`.
    private func warnNotCounted(_ dose: UnfinalizedDose, because reason: String) {
        log.error(
            "The temp basal of \(dose.value) U/h whose command went unanswered, from \(dose.startDate), is reported only now, " +
                "\(reason): the host may not count it"
        )
        let key = UncertainDelivery.DoseKey(dose)
        state.mutateUncertainDeliveries { deliveries in
            for index in deliveries.indices where deliveries[index].kind == .tempBasal && deliveries[index].isOf(key) {
                deliveries[index].outcome = .notCounted
            }
        }
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(self, didError: .uncertainDelivery)
        }
    }

    /// `record`, the unconfirmed temp basal's, ends where the patch split it - at patch-local midnight, or on a profile
    /// change: only a part of it, but proof it ran. It is reported from the record's start on, and no record finalizes
    /// it: it runs until it ended at the latest (`unconfirmedTempBasalEnd`) - final at once from our estimate if that
    /// has passed. Only under `doseReportLock`.
    private func runSplitUnconfirmedTempBasal(
        _ pending: UnfinalizedDose,
        as tempBasalDose: UnfinalizedDose,
        shownBy record: BasalRecord,
        sequence: Int,
        endedBy latest: Date? = nil
    ) -> (outcome: String, events: [NewPumpEvent]) {
        tempBasalDose.disableRecordMatch()
        tempBasalDose.markFirstSegmentUncertain()
        // Ended by `latest`, and never past the start of a basal dose the host has after it
        let nextStart = reportedBasalDoses.filter { $0.startDate > tempBasalDose.startDate }.map(\.startDate).min()
        let end = [unconfirmedTempBasalEnd(pending), latest, nextStart].compactMap { $0 }.min() ?? unconfirmedTempBasalEnd(pending)
        state.unconfirmedTempBasal = nil

        log.warning(
            "Record \(sequence) is a part of the temp basal of \(pending.value) U/h whose command went unanswered, from " +
                "\(record.startTime) to \(record.endTime) where the patch split it: it ran - reported from " +
                "\(tempBasalDose.startDate) on, finalized from our estimate, not from its records"
        )

        var events: [NewPumpEvent]
        if end <= now() {
            tempBasalDose.finish(end >= tempBasalDose.estimatedEndDate ? .completed : .cancelled, endedAt: end, at: now())
            events = estimateFinal(tempBasalDose, because: "only a part of it has a record").map { [$0] } ?? []
            warnIfBehindWhatIsFinal(tempBasalDose)
        } else {
            events = endTempBasalFromEstimate(
                endedAt: tempBasalDose.startDate,
                because: "the temp basal whose command went unanswered replaced it"
            )
            events.append(NewPumpEvent.tempBasal(dose: tempBasalDose.toDoseEntry(isMutable: true)))
            state.basalDose = tempBasalDose
            state.basalState = .tempBasal
        }

        state.lastSync = Date.now
        return ("part of split unconfirmed temp basal \(tempBasalDose.startDate)", events)
    }

    /// How much later than its command went out `patchTime` is, of the temp basal of `unconfirmed` whose command went
    /// unanswered - told on each clock alone where the basal before it is known on both (`basalBefore`,
    /// `basalBeforeOnPatch`): from there to `patchTime` on the patch clock, less from there to its command on ours.
    /// Through the skew otherwise.
    private func unansweredStartOffset(of unconfirmed: UnfinalizedDose.State, sentAt: Date, patchTime: Date) -> TimeInterval {
        guard let basalBefore = unconfirmed.basalBefore, let onPatch = unconfirmed.basalBeforeOnPatch else {
            return patchTime.timeIntervalSince(sentAt.addingTimeInterval(state.patchClockSkew))
        }
        return patchTime.timeIntervalSince(onPatch) - sentAt.timeIntervalSince(basalBefore)
    }

    /// When the temp basal of `unconfirmed` whose command went unanswered started, on our clock, its segment or record
    /// starting at `patchTime`: from the basal before it as `unansweredStartOffset` tells it, else through the skew -
    /// within `unansweredStartFloor` and `notAfter`, and before anything the host has after it
    private func unansweredStart(of unconfirmed: UnfinalizedDose.State, sentAt: Date, patchTime: Date, notAfter: Date) -> Date {
        unansweredSpan(of: unconfirmed, sentAt: sentAt, patchTime: patchTime, notAfter: notAfter, lasting: 0).start
    }

    /// Where the temp basal of `unconfirmed` whose command went unanswered ran, `duration` long from `patchTime` on the
    /// patch clock, on ours: `unansweredStart`, and its end - never over a basal dose the host has that came after its
    /// command: the host would trim that one to its start, and move its watermark past it - Loop then loses the running
    /// temp basal. Dated into one, it is moved earlier to end where that one starts; with no room for all of it since
    /// `unansweredStartFloor`, it is fitted into what there is, its amount kept - `compressed`. A status shows it running
    /// now (`duration` 0): just before such a dose, if at all after it.
    private func unansweredSpan(
        of unconfirmed: UnfinalizedDose.State,
        sentAt: Date,
        patchTime: Date,
        notAfter: Date,
        lasting duration: TimeInterval
    ) -> (start: Date, end: Date, compressed: Bool) {
        let floor = unansweredStartFloor(of: unconfirmed, sentAt: sentAt)
        var start: Date
        if let basalBefore = unconfirmed.basalBefore, let onPatch = unconfirmed.basalBeforeOnPatch {
            start = max(min(basalBefore.addingTimeInterval(patchTime.timeIntervalSince(onPatch)), notAfter), floor)
        } else {
            start = patchTimeOnOurClock(patchTime, notBefore: floor, notAfter: notAfter)
        }

        // The first thing the host has that came after its command
        guard let later = reportedBasalDoses.filter({ $0.startDate > floor }).map(\.startDate).min(),
              start.addingTimeInterval(duration) > later
        else {
            return (start, start.addingTimeInterval(duration), false)
        }

        guard duration >= Self.shortestComputedDuration else {
            start = max(floor, min(start, later.addingTimeInterval(-Self.afterFinal)))
            return (start, start, false)
        }
        let room = later.timeIntervalSince(floor)
        guard room < duration else {
            return (later.addingTimeInterval(-duration), later, false)
        }
        // Short by no more than the two clocks tell apart: fitted, its amount kept, nothing the host would miss
        guard duration - room > Self.patchEndTolerance else {
            return (floor, later, false)
        }
        return (floor, later, true)
    }

    /// How early a temp basal whose command went out at `sentAt` unanswered may be dated: `unansweredStartSlack` before
    /// then - but after the basal the host was told ran when it went out (`UnfinalizedDose.State.basalBefore`), the
    /// scheduled basal from the cancel before it, say, final: the host would take the temp basal as starting before something final, and pass it by - or, starting
    /// at the same instant, order the two either way. Only under `doseReportLock`.
    private func unansweredStartFloor(of unconfirmed: UnfinalizedDose.State, sentAt: Date) -> Date {
        let floor = sentAt.addingTimeInterval(-Self.unansweredStartSlack)
        if let basalBefore = unconfirmed.basalBefore {
            return max(floor, basalBefore.addingTimeInterval(Self.afterFinal))
        }
        // Saved by a build that did not keep it: the basal running now, if it is the one from then, reported
        let running = state.basalDose
        guard running.type != .tempBasal, !state.basalDoseIsPlaceholder, running.startDate <= sentAt else {
            return floor
        }
        return max(floor, running.startDate.addingTimeInterval(Self.afterFinal))
    }
}

import LoopKit

public extension MedtrumPumpManager {
    /// Finalizes, from our own estimate, the doses whose record is overdue - see `RecordSyncer.fallbackRule` - and drops
    /// a temp basal whose command went unanswered that nothing showed ran. Returns how many.
    @discardableResult internal func finalizeOverdueAwaitingDoses() -> Int {
        let checkedAt = now()

        return doseReportLock.withLock { () -> Int in
            var settled = 0

            // Only with every record read, counted from when it ended at the latest: a temp basal the patch may still
            // run has no record yet, and records that cannot be read - or were skipped - say nothing: it stays,
            // delivery uncertain
            if let pending = state.unconfirmedTempBasal, !mayHaveSkippedRecord(of: pending) {
                let end = unconfirmedTempBasalEnd(pending)
                if RecordSyncer.fallbackRule(since: end, caughtUp: isCaughtUp(after: end), now: checkedAt) == .noRecord {
                    if let shownFrom = pending.snapshot.shownRunningFrom {
                        dropUnconfirmedTempBasalShownRunning(pending, from: shownFrom)
                    } else {
                        dropUnconfirmedTempBasal(
                            because: "no status showed it running and \(RecordSyncer.FallbackRule.noRecord.description) at the latest",
                            neverRan: true
                        )
                    }
                    settled += 1
                }
            }

            // Ended open: the oldest first, as their own rules say
            let open = settleOpenTempBasalEnds()

            // Not the temp basal whose records are read as it ended: its read is bounded on its own - see `TempBasalEnd`
            let reading = pendingTempBasalEndStorage?.dose
            let overdue = state.awaitingRecord.compactMap { dose -> (dose: UnfinalizedDose, rule: RecordSyncer.FallbackRule)? in
                let snapshot = dose.snapshot
                guard !snapshot.isFinalized, !snapshot.endedOpen, dose !== reading, let finishedAt = snapshot.finishedAt,
                      let rule = RecordSyncer.fallbackRule(since: finishedAt, caughtUp: isCaughtUp(after: finishedAt), now: checkedAt)
                else {
                    return nil
                }
                return (dose, rule)
            }

            guard !overdue.isEmpty || !open.isEmpty else {
                return settled
            }

            let events = open + finalizeFromEstimate(overdue.map(\.dose)) { dose in
                overdue.first { $0.dose === dose }?.rule.description ?? "-"
            }
            emitPumpEvents(events)
            return settled + open.count + overdue.count
        }
    }

    /// Final reports, from our own estimate, of every dose still waiting on its record - the records are out of reach.
    /// Only under `doseReportLock`; the caller emits them.
    internal func finalizeAllAwaitingDoses(because reason: String) -> [NewPumpEvent] {
        finalizeFromEstimate(state.awaitingRecord.filter { !$0.isFinalized }) { _ in reason }
    }

    /// Final reports from our own estimate. Only under `doseReportLock`; the caller emits them. A bolus whose command
    /// went unanswered, counted in full without its record, is one the host is told was counted as delivered.
    private func finalizeFromEstimate(_ doses: [UnfinalizedDose], because reason: (UnfinalizedDose) -> String) -> [NewPumpEvent] {
        var events: [NewPumpEvent] = []

        for dose in doses {
            if dose.type == .tempBasal {
                events.append(contentsOf: estimateFinal(dose, because: reason(dose)).map { [$0] } ?? [])
                continue
            }

            let neverRan = unansweredBolusNeverRan(dose)
            // The released driver's, ended unseen: warned of only now, its record not found - see `checkBolusDone`
            let endedUnseen = Self.isReleasedDriversBolus(dose) && dose.snapshot.finishReason == .completionNotSeen &&
                dose.snapshot.confirmation == .confirmed
            if endedUnseen {
                noteUncertainDelivery(.bolus, .endNotSeen, of: dose)
            }
            guard let event = finalize(dose, deliveredUnits: neverRan ? 0 : nil, neverRan ? .neverRan : .byEstimate) else {
                continue
            }
            if endedUnseen {
                pumpDelegate.notify { delegate in
                    delegate?.pumpManager(self, didError: .uncertainDelivery)
                }
            }

            let final = dose.snapshot
            log.warning(
                "Finalized the \(dose.type.rawValue) of \(dose.startDate) (\(final.finishReason?.rawValue ?? "-")) " +
                    "without its record, \(reason(dose)): \(final.finalDeliveredUnits ?? 0) U delivered, by our estimate"
            )

            if dose.type == .bolus, final.confirmation == .uncertain, dose.countsInFull(final), !neverRan {
                emitAlert(alertType: .bolusCountedAsDelivered(units: dose.value))
            }

            events.append(event)
        }

        return events
    }

    /// Doses wait on records the patch has written already, or past their timeout - or finals are due to go out again -
    /// or the patch told of records past the cursor, no dose waiting on them. Not a temp basal ended back to back moments
    /// ago (`awaitsItsReadAfterTheCommand`), nor records a command told of moments ago (`isRightAfterACommand`): the
    /// heartbeat naming them comes a second or two after the command, and its sync would take the link from the loop's
    /// bolus right behind it.
    internal var hasPendingRecordWork: Bool {
        if doseReportLock.withLock({ isUnconfirmedFinalsResendDue }) {
            return true
        }

        let checkedAt = now()
        // Records no dose waits on - those a temp basal's read left to the sync, say: read with a heartbeat, within the
        // sync's cooldown, not with the next full sync only, which every command's answer puts off making the status
        // fresh (device 2026-10-20 13:35-13:41: 679 left to the sync by one suspend still unread at the next, whose
        // read took 5 records rather than 2 - the kill came during it)
        if state.syncedSequenceNumber < state.currentSequenceNumber, !isRightAfterACommand(at: checkedAt) {
            return true
        }

        let waitingSince = recordWaits(at: checkedAt)
        guard !waitingSince.isEmpty else {
            return false
        }

        return state.syncedSequenceNumber < state.currentSequenceNumber || waitingSince.contains {
            RecordSyncer.fallbackRule(since: $0, caughtUp: isCaughtUp(after: $0), now: checkedAt) != nil
        }
    }

    /// The newest record the answer of a dose waiting on it named - a bolus's - nil, none
    internal var newestRecordNamedForAwaitingDose: Int? {
        doseReportLock.withLock {
            state.awaitingRecord.filter { !$0.isFinalized }.compactMap(\.recordSequence).max()
        }
    }

    /// Doses wait on records the patch has written already - see `hasPendingRecordWork`
    internal var awaitsRecordsWritten: Bool {
        state.syncedSequenceNumber < state.currentSequenceNumber && !recordWaits(at: now()).isEmpty
    }

    /// When each dose waiting on its record ended - that temp basals ended back to back moments ago wait on no sync
    private func recordWaits(at checkedAt: Date) -> [Date] {
        var waitingSince = state.awaitingRecord.compactMap { dose -> Date? in
            let snapshot = dose.snapshot
            return snapshot.isFinalized || awaitsItsReadAfterTheCommand(snapshot, at: checkedAt) ? nil : snapshot.finishedAt
        }
        if let pending = state.unconfirmedTempBasal {
            waitingSince.append(unconfirmedTempBasalEnd(pending))
        }
        return waitingSince
    }

    /// Every record the patch has written by `end` has been read: the cursor is at the newest record it told us of, and
    /// it told us so after `end` - when a dose ended, and its record was written. A number told before says nothing of
    /// that record: the cursor at it, with the link lost since, is not caught up.
    /// `readThrough`: the records read through, if not the cursor - one read just now, before the cursor moves past it.
    internal func isCaughtUp(after end: Date, readThrough: Int? = nil) -> Bool {
        guard let confirmedAt = state.sequenceConfirmedAt else {
            return false
        }
        return (readThrough ?? state.syncedSequenceNumber) >= state.currentSequenceNumber && confirmedAt > end
    }

    /// The boluses whose answer was lost - or named no record of this patch - not final: running, or waiting on their
    /// record, which is looked for by when they went out. Seen delivering since or not. Only under `doseReportLock`.
    internal var bolusesWithoutTheirAnsweredRecord: [UnfinalizedDose] {
        ([state.bolusDose].compactMap { $0 } + state.awaitingRecord).filter { dose in
            let snapshot = dose.snapshot
            return dose.type == .bolus && snapshot.recordSequence == nil && !snapshot.isFinalized
        }
    }

    /// The boluses whose command went unanswered, never seen delivering - running, or waiting on their record. Only
    /// under `doseReportLock`.
    internal var unansweredBoluses: [UnfinalizedDose] {
        ([state.bolusDose].compactMap { $0 } + state.awaitingRecord).filter { dose in
            let snapshot = dose.snapshot
            return dose.type == .bolus && snapshot.confirmation == .uncertain && snapshot.recordSequence == nil &&
                !snapshot.isFinalized
        }
    }

    /// Record `sequence` was read off the patch - asked for as `requested`, of this patch (`isOurs`) - and applied: see
    /// `UnfinalizedDose.State.recordsReadThrough`
    internal func noteRecordRead(_ sequence: Int, requested: Int, isOurs: Bool) {
        guard isOurs, sequence == requested else {
            return
        }
        doseReportLock.withLock {
            for dose in unansweredBoluses where isNumberedOnThisPatch(dose.snapshot) {
                dose.noteRecordRead(sequence)
            }
        }
    }

    /// Whether `dose`, a bolus whose command went unanswered that ran its course unseen, never ran: past its deadline its
    /// record was written, had it run - and the patch told its newest record since, every one numbered past the newest
    /// known when the command went out was read up to there, and none could be its. A bolus is left without a record
    /// only if cancelled before it was written: one cancelled, or cut off, may have run. Why it may have is logged. Only
    /// under `doseReportLock`. A number an answer gave is never this one's - see `MedtrumPumpState.answeredBolusRecords`.
    /// Never against another patch's counter (`isNumberedOnThisPatch`): one sent to it is final as its session ends, as
    /// the app comes back with no session, or as the next one starts - and if one were left, it may have run.
    private func unansweredBolusNeverRan(_ dose: UnfinalizedDose) -> Bool {
        let snapshot = dose.snapshot
        guard dose.type == .bolus, snapshot.confirmation == .uncertain, snapshot.recordSequence == nil else {
            return false
        }

        let deadline = dose.deliveryDeadline(of: snapshot)
        let mayHaveRun: String
        if snapshot.finishReason != .completionNotSeen {
            mayHaveRun = "it was \(snapshot.finishReason?.rawValue ?? "not ended")"
        } else if snapshot.sequenceAtSend == nil {
            mayHaveRun = "the record known when it went out was not kept"
        } else if !isNumberedOnThisPatch(snapshot) {
            mayHaveRun = "the record known when it went out, #\(snapshot.sequenceAtSend ?? 0), is " +
                (snapshot.sequencePatchId.map { "patch \($0)'s, not this one's" } ?? "of no patch known, and no session runs")
        } else if now() < deadline {
            mayHaveRun = "it is not past its deadline"
        } else if !sequenceConfirmed(after: deadline, of: snapshot) {
            mayHaveRun = "the patch has not told its newest record since its deadline"
        } else if let sequenceAtSend = snapshot.sequenceAtSend, sequenceAtSend > state.currentSequenceNumber {
            // Past the newest the patch told since its deadline: another patch's number all the same - one saved with no
            // patch noted (`isNumberedOnThisPatch`). Nothing to tell from this patch's records.
            mayHaveRun = "the record known when it went out, #\(sequenceAtSend), is past the patch's newest - another patch's"
        } else if let through = snapshot.recordsReadThrough ?? snapshot.sequenceAtSend, through < state.currentSequenceNumber {
            mayHaveRun = "records \(through + 1)...\(state.currentSequenceNumber) were not all read in order, it may be one of them"
        } else if let possible = snapshot.possibleRecord {
            mayHaveRun = "record \(possible) could be its"
        } else {
            log.warning(
                "The bolus of \(dose.startDate) whose command went unanswered never ran: no record past " +
                    "\(snapshot.sequenceAtSend.map(String.init) ?? "-") up to \(state.currentSequenceNumber) is its - 0 U"
            )
            return true
        }

        log.warning("The bolus of \(dose.startDate) whose command went unanswered may have run, \(mayHaveRun): counted in full")
        return false
    }

    /// The patch told its newest record after `deadline`, for the bolus `snapshot` is of. Sent in this run, by the
    /// monotonic clock: a change of the wall clock can't put a telling from before it went out past its deadline. Sent
    /// in an earlier run - another boot, maybe, whose monotonic clock is not ours - only a telling of this run counts, all
    /// of it after the bolus went out.
    private func sequenceConfirmed(after deadline: Date, of snapshot: UnfinalizedDose.State) -> Bool {
        guard let confirmed = state.sequenceConfirmedInThisRun else {
            return false
        }
        if let sentUptime = snapshot.sentUptime, let sentAt = snapshot.sentAt {
            return confirmed.uptime > sentUptime + deadline.timeIntervalSince(sentAt)
        }
        return confirmed.at > deadline
    }

    /// Whether the record numbers of the bolus `snapshot` is of - the newest known when its command went out, and any
    /// told of it since - are those of the patch whose records are read now. Record numbers restart with every patch:
    /// one of another is neither past nor before any of this one's, and says nothing of its records - the bolus may have
    /// run, and none of them is its own. Noted with no patch known - by a build before it was kept, or sent before a status
    /// named the id: this patch's while a session runs, as before; not while none does. Only under `doseReportLock`.
    internal func isNumberedOnThisPatch(_ snapshot: UnfinalizedDose.State) -> Bool {
        guard !state.patchSessionEnded else {
            return false
        }
        guard let patchId = snapshot.sequencePatchId else {
            return true
        }
        return state.recordNumbersPatchId == patchId
    }

    /// The record sync gave up on record `sequence`, unreadable: kept if it could be the unconfirmed temp basal's
    internal func noteSkippedRecord(_ sequence: Int) {
        doseReportLock.withLock {
            guard let pending = state.unconfirmedTempBasal, sequence > pending.snapshot.sequenceAtSend ?? 0 else {
                return
            }
            log.warning("Record \(sequence) was skipped, and could be that of the temp basal whose command went unanswered")
            state.skippedRecordSequences.append(sequence)
        }
    }

    /// A record numbered past the newest one known when its command went out was skipped: it could be its record
    private func mayHaveSkippedRecord(of pending: UnfinalizedDose) -> Bool {
        let sequenceAtSend = pending.snapshot.sequenceAtSend ?? 0
        return state.skippedRecordSequences.contains { $0 > sequenceAtSend }
    }
}

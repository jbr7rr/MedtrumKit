import LoopKit

public extension MedtrumPumpManager {
    // MARK: - Temp basals ended back to back

    /// A temp basal of ours that a new one replaced back to back ends open: the host is told it ended where the new one
    /// started - exactly there, the same instant, so it has nothing to fill between the two - mutable until its records
    /// are read. Loop takes basal doses as final in order, and moves past a temp basal still mutable once anything
    /// immutable after it is stored - a temp basal's final, the scheduled basal it fills a gap with, a suspend: so these
    /// go final in order, the oldest first, in the batch that carries the next or an earlier one - never one before an
    /// older one (`finalize`). Every replacing batch carries those not final yet, mutable (`emitPumpEvents`).
    ///
    /// Their records are read once the command is over (`readOpenTempBasalEndsSoon`), or by any record sync: each one
    /// read is kept on the temp basal it is a part of, which goes final from them once they add up to where it ended -
    /// in its end where the next one started, the amount the patch's (`settleOpenTempBasalEnds`). From our estimate once
    /// its last record is read past without that, once it cannot be told by its records at all, after
    /// `openTempBasalEndMaximumWait` - or before anything that leaves a gap or a dose of another kind after them goes out:
    /// a temp basal that ends with one reads their records with its own, and they go final with it
    /// (`settleTempBasalEnd`). The patch session ending finalizes them with everything else.
    ///
    /// Saved with the doses: a restart reads them as ever. Only under `doseReportLock`.
    internal var openTempBasalEnds: [UnfinalizedDose] {
        state.awaitingRecord.filter { dose in
            let ended = dose.snapshot
            return dose.type == .tempBasal && ended.endedOpen && !ended.isFinalized
        }.sorted { $0.startDate < $1.startDate }
    }

    /// Whether any temp basal ended open is waiting on its records
    internal var hasOpenTempBasalEnds: Bool {
        doseReportLock.withLock { !openTempBasalEnds.isEmpty }
    }

    /// Whether `ended`, a temp basal ended open within `openTempBasalEndReadDelay` of `checkedAt`, has its first read
    /// still to come from the command that ended it (`readOpenTempBasalEndsSoon`) - the loop's bolus right behind it
    /// first. Past that, any sync reads it, its other bounds as ever.
    internal func awaitsItsReadAfterTheCommand(_ ended: UnfinalizedDose.State, at checkedAt: Date) -> Bool {
        guard ended.endedOpen, !ended.isFinalized, let finishedAt = ended.finishedAt else {
            return false
        }
        // The read it waits for goes by the monotonic clock: a wall clock set back since - the age negative - excludes
        // nothing
        let age = checkedAt.timeIntervalSince(finishedAt)
        return age >= 0 && age < openTempBasalEndReadDelay
    }

    /// How long a temp basal ended open waits for its records at most, read or not: its final is not put off further
    internal static let openTempBasalEndMaximumWait: TimeInterval = awaitingRecordTimeout

    /// `dose`, the running temp basal, ended open at `endedAt` - see `openTempBasalEnds` - its last record `lastRecord`,
    /// ending at `patchEnd` on the patch clock, where known. The caller replaces `state.basalDose`. Only under
    /// `doseReportLock`.
    internal func endOpen(_ dose: UnfinalizedDose, at endedAt: Date, patchEnd: Date?, lastRecord: Int?) {
        guard dose.endOpen(at: endedAt, patchEnd: patchEnd, endRecord: lastRecord, at: now()) else {
            return
        }
        state.mutateAwaitingRecord { doses in
            guard !doses.contains(where: { $0 === dose }) else {
                return
            }
            doses.append(dose)
        }

        log.info(
            "Temp basal of \(dose.startDate) ended at \(endedAt), where the next one started: reported ended and mutable until " +
                "its records up to \(lastRecord.map { "#\($0)" } ?? "-") are read"
        )
    }

    /// Whether `dose`, ended open, can be told by its records at all: a patch start to begin at, where it ended on the
    /// patch clock, its last record named
    private static func isReadable(_ ended: UnfinalizedDose.State) -> Bool {
        !ended.recordMatchDisabled && ended.pumpStartTime != nil && ended.patchEndTime != nil && ended.endRecord != nil
    }

    /// What the records of `dose`, ended open - the parts kept on it, and `records` - show it delivered: nil if they do
    /// not add up to where it ended, or it can't be told by its records - see `tempBasalParts`
    internal func openTempBasalParts(
        of dose: UnfinalizedDose,
        in records: [GetRecordResponse] = [],
        logging: Bool = false
    ) -> (delivered: Double, duration: TimeInterval, sequences: [Int], end: Date)? {
        let ended = dose.snapshot
        guard Self.isReadable(ended), let patchEnd = ended.patchEndTime else {
            return nil
        }
        guard let parts = tempBasalParts(of: dose, in: records, endingAt: patchEnd, through: ended.endRecord, logging: logging),
              abs(parts.end.timeIntervalSince(patchEnd)) <= RecordSyncer.tempBasalStartTolerance
        else {
            return nil
        }
        return parts
    }

    /// Fixes the final of `dose`, ended open, from `parts` of its records: what they delivered, its end where the next one
    /// started. Only under `doseReportLock`; the caller hands the final over.
    internal func finalizeOpen(
        _ dose: UnfinalizedDose,
        from parts: (delivered: Double, duration: TimeInterval, sequences: [Int], end: Date)
    ) -> NewPumpEvent? {
        let ended = dose.snapshot
        log.info(
            "Record(s) \(parts.sequences.map(String.init).joined(separator: ", ")) finalize the temp basal of " +
                "\(dose.startDate) that ended back to back: \(String(format: "%.1f", parts.duration / 60)) min on the patch, " +
                "delivered \(parts.delivered) U by its records - ended at \(ended.observedEndDate.map { "\($0)" } ?? "-"), " +
                "where the next one started"
        )

        // Its records end well before the next one started - more than a cancel, the hand-over and a set take: the patch
        // had stopped it before, which the cancel's answer did not tell. It ends where they do: the host fills the
        // schedule up to the next one's start, exactly - which still starts past everything final.
        let recorded = dose.startDate.addingTimeInterval(parts.duration)
        if let next = ended.observedEndDate, parts.duration >= Self.shortestComputedDuration, !ended.firstSegmentUncertain,
           next.timeIntervalSince(recorded) > Self.openRecordShortfallTolerance
        {
            log.warning(
                "The records of the temp basal of \(dose.startDate) end \(Int(next.timeIntervalSince(recorded))) s before the " +
                    "next one started: the patch had stopped it - it ends at \(recorded), the schedule after it"
            )
            return finalize(dose, deliveredUnits: parts.delivered, endDate: recorded, .byRecord)
        }
        return finalize(dose, deliveredUnits: parts.delivered, .byRecord)
    }

    /// How much sooner than the next one's start the records of a temp basal ended back to back may end, and it still
    /// have run up to the cancel: the cancel's answer (2 to 4 s on a slow link), the hand-over of the state before the set
    /// (3 s at most as a rule), the set's round trip (4 to 9 s, one record's worth), and a second of each clock's
    /// rounding. A host slower to take the state (up to `dosingHandOverTimeout`) can take it past: the temp basal then
    /// ends where its records do, the schedule after it - as the patch ran it, waiting for the set.
    internal static let openRecordShortfallTolerance: TimeInterval = 20

    /// Finalizes the temp basals ended open that can be, the oldest first, up to the first that has to wait - see
    /// `openTempBasalEnds` - every record up to `readThrough` read, or the cursor's. Returns their finals. Only under
    /// `doseReportLock`; the caller hands them over.
    internal func settleOpenTempBasalEnds(readThrough: Int? = nil) -> [NewPumpEvent] {
        let readUpTo = max(state.syncedSequenceNumber, readThrough ?? 0)
        let checkedAt = now()
        var events: [NewPumpEvent] = []

        for dose in openTempBasalEnds {
            if let parts = openTempBasalParts(of: dose) {
                if let final = finalizeOpen(dose, from: parts) {
                    events.append(final)
                }
                continue
            }

            let ended = dose.snapshot
            let reason: String
            if !Self.isReadable(ended) {
                if ended.recordMatchDisabled {
                    reason = "its records do not start where its patch start says"
                } else if ended.pumpStartTime == nil {
                    reason = "its patch start is not known, its records can't be told"
                } else {
                    reason = "no record of its end is known"
                }
            } else if let endRecord = ended.endRecord, endRecord <= readUpTo {
                // Logged, why not
                _ = openTempBasalParts(of: dose, logging: true)
                reason = "its records up to \(endRecord) were read, and do not add up to it"
            } else if let finishedAt = ended.finishedAt,
                      checkedAt.timeIntervalSince(finishedAt) >= Self.openTempBasalEndMaximumWait
            {
                reason = "its records were not read within \(Int(Self.openTempBasalEndMaximumWait / 60)) min of its end"
            } else {
                break
            }

            // A temp basal whose command went unanswered, started before it, still unsettled: its final - from a record
            // read later - would go out behind this one's, which the host may then drop. This one waits for it, up to
            // `awaitingRecordMaximumWait`.
            if let pending = state.unconfirmedTempBasal, pending.startDate < dose.startDate, let finishedAt = ended.finishedAt,
               checkedAt.timeIntervalSince(finishedAt) < Self.awaitingRecordMaximumWait
            {
                log.info(
                    "The temp basal of \(dose.startDate) would go final from our estimate, \(reason) - it waits for the one of " +
                        "\(pending.value) U/h whose command went unanswered before it"
                )
                break
            }

            if let final = estimateFinal(dose, because: reason) {
                events.append(final)
            }
        }

        return events
    }

    /// The finals of every temp basal ended open, from our estimate, the oldest first - for a temp basal after them that
    /// goes final so, its records not read on the way. Only under `doseReportLock`; the caller hands them over.
    internal func openTempBasalEndsFromEstimate(because reason: String) -> [NewPumpEvent] {
        openTempBasalEnds.compactMap { estimateFinal($0, because: reason) }
    }

    /// Record sync: every record up to `sequence` was read, or given up on - the temp basals ended open that this settles
    /// go final, and out. Before the cursor moves past it.
    internal func settleOpenTempBasalEndsRead(through sequence: Int) {
        doseReportLock.withLock {
            let events = settleOpenTempBasalEnds(readThrough: sequence)
            if !events.isEmpty {
                emitPumpEvents(events)
            }
        }
    }

    /// `record` is of a part of a temp basal of ours that ended open: of this patch, at its rate, starting on its patch
    /// start or where the part kept before it ended. Kept on it - and the temp basals ended open settled, it among them
    /// if its parts now add up to where it ended. Only under `doseReportLock`.
    internal func keepPartOfOpenTempBasal(_ record: BasalRecord, response: GetRecordResponse) -> String? {
        guard RecordSyncer.isSamePatch(response.patchId, state.patchId.toUInt64()) else {
            return nil
        }

        let tolerance = RecordSyncer.tempBasalStartTolerance
        for dose in openTempBasalEnds {
            let ended = dose.snapshot
            // Its own records only: numbered up to its last, and none once they reach where it ended - the next one's, at
            // the same rate, may start right there
            guard !ended.recordMatchDisabled, let pumpStartTime = ended.pumpStartTime,
                  RecordSyncer.steps(record.rate) == RecordSyncer.steps(dose.value),
                  ended.endRecord.map({ response.sequence <= $0 }) ?? true
            else {
                continue
            }

            if ended.recordedParts.contains(where: { $0.sequence == response.sequence }) {
                log.info("Record \(response.sequence) is a part of the ended temp basal of \(dose.startDate), kept already")
                return "part of ended temp basal \(dose.startDate)"
            }

            let partStart = ended.recordedParts.last?.end ?? pumpStartTime
            let complete = ended.patchEndTime.map { abs(partStart.timeIntervalSince($0)) <= tolerance && !ended.recordedParts.isEmpty } ?? false
            guard !complete, abs(record.startTime.timeIntervalSince(partStart)) <= tolerance, record.endTime > record.startTime else {
                continue
            }

            let part = UnfinalizedDose.RecordedPart(
                sequence: response.sequence,
                patchId: response.patchId & 0xFFFF,
                start: record.startTime,
                end: record.endTime,
                delivered: record.delivered
            )
            guard dose.keepRecordedPart(part) else {
                continue
            }

            log.info(
                "Record \(response.sequence) is a part of the temp basal of \(dose.startDate) that ended back to back, from " +
                    "\(record.startTime) to \(record.endTime), delivered \(record.delivered) U: kept"
            )

            let events = settleOpenTempBasalEnds(readThrough: response.sequence)
            if !events.isEmpty {
                emitPumpEvents(events)
            }
            return dose.isFinalized ? "finalized temp basal \(dose.startDate)" : "part of ended temp basal \(dose.startDate)"
        }

        return nil
    }

    /// The newest record the temp basals ended open wait on: the last one of the latest. Nil, none waits.
    internal var lastRecordOfOpenTempBasalEnds: Int? {
        doseReportLock.withLock {
            (openTempBasalEnds + [state.unconfirmedTempBasal].compactMap { $0 }).compactMap { $0.snapshot.endRecord }.max()
        }
    }

    /// Reads the records of the temp basals ended open (`openTempBasalEnds`), up to the newest one they wait on, off the
    /// command's thread: `openTempBasalEndReadDelay` from now, once no command is in flight - the loop's bolus, right behind
    /// the temp basal that ended the last of them, has the link first, and is held up by no record. As a record sync
    /// does: not while a bolus runs, and yielding to a command between two records - what is not read now, a later sync
    /// reads.
    internal func readOpenTempBasalEndsSoon(after delay: TimeInterval? = nil) {
        let delay = delay ?? openTempBasalEndReadDelay
        let read = { [weak self] in
            guard let self else {
                return
            }

            let deadline = Date.now.addingTimeInterval(Self.commandActivityTimeout)
            while self.isCommandActive, Date.now < deadline, !self.backgroundReadsStopped.value {
                Thread.sleep(forTimeInterval: 0.2)
            }

            guard !self.backgroundReadsStopped.value, let through = self.lastRecordOfOpenTempBasalEnds else {
                return
            }
            // No record is read while a bolus runs: once it is over (`notifyStateDidChange`)
            let bolusRuns = self.doseReportLock.withLock { () -> Bool in
                guard self.state.bolusDose != nil else {
                    return false
                }
                self.openTempBasalEndReadAwaitsBolus = true
                return true
            }
            guard !bolusRuns else {
                self.log.info("A bolus is running: the records of the temp basals ended back to back are read once it is over")
                return
            }
            RecordSyncer.syncRecords(pumpManager: self, trigger: .tempBasalEnds, through: through)
        }

        if delay > 0 {
            tempBasalEndQueue.asyncAfter(deadline: .now() + delay, execute: read)
        } else {
            tempBasalEndQueue.async(execute: read)
        }
    }

    /// For tests: the reads queued on `tempBasalEndQueue` - after a delay, behind a command or a bolus - give up, and none
    /// starts from here on: none outlives the scenario that queued it, into the record sync's run state of the next
    internal func stopBackgroundReads() {
        backgroundReadsStopped.value = true
        tempBasalEndQueue.sync {}
    }

    /// The bolus a read of the temp basals ended open waited for is over: read them now, once
    internal func readOpenTempBasalEndsAfterBolus() {
        let due = doseReportLock.withLock { () -> Bool in
            // A temp basal's records read as it ended - a halt with the bolus's completion: theirs read with them
            guard openTempBasalEndReadAwaitsBolus, state.bolusDose == nil, pendingTempBasalEndStorage == nil else {
                return false
            }
            openTempBasalEndReadAwaitsBolus = false
            return lastRecordOfOpenTempBasalEnds.map { $0 > state.syncedSequenceNumber } ?? false
        }
        if due {
            readOpenTempBasalEndsSoon(after: 0)
        }
    }
}

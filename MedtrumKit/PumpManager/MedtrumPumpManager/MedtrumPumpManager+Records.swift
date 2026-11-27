import Foundation

public extension MedtrumPumpManager {
    /// Takes the record number out of a command response.
    ///
    /// Every command that ends a basal segment answers with the record the patch wrote for it. Adopting
    /// it keeps the counter current between syncs - otherwise it only moves when a status notification
    /// happens to arrive, and the record view sits behind the patch until then.
    internal func adoptRecordSequence(_ sequence: Double, from command: String) {
        let sequence = Int(sequence)

        // Not while the session start is unknown - the released driver's state, no status naming the newest record since:
        // the records it let the sync read would never be told of (`warnOfBolusNotCounted`)
        guard sequence >= state.currentSequenceNumber, state.sessionStartSequence != nil else {
            return
        }

        if sequence > state.currentSequenceNumber {
            log.debug("\(command) wrote record #\(sequence)")
            state.currentSequenceNumber = sequence
        }

        // Written just now, as the command ended a segment: the newest record the patch has
        state.sequenceConfirmedAt = now()
        noteRecordSequenceConfirmedInThisRun(at: now(), uptime: uptime())
    }

    /// A status received at `receivedAt` (`receivedUptime`) says `currentSequenceNumber` is the newest record the patch
    /// has written
    internal func noteRecordSequenceConfirmed(receivedAt: Date, receivedUptime: TimeInterval) {
        let confirmedAt = now().addingTimeInterval(receivedAt.timeIntervalSinceNow)
        state.sequenceConfirmedAt = max(state.sequenceConfirmedAt ?? confirmedAt, confirmedAt)
        noteRecordSequenceConfirmedInThisRun(at: confirmedAt, uptime: receivedUptime)
    }

    private func noteRecordSequenceConfirmedInThisRun(at confirmedAt: Date, uptime confirmedUptime: TimeInterval) {
        guard (state.sequenceConfirmedInThisRun?.uptime ?? -.infinity) < confirmedUptime else {
            return
        }
        state.sequenceConfirmedInThisRun = (at: confirmedAt, uptime: confirmedUptime)
    }

    // MARK: - Doses awaiting their record

    /// How long a finished dose waits for its record, once every record the patch has written has been read
    internal static let awaitingRecordTimeout: TimeInterval = .minutes(15)

    /// How long a finished dose waits for its record at most, read up or not
    internal static let awaitingRecordMaximumWait: TimeInterval = .minutes(60)

    /// How far from when its command went out, on the patch clock, the record of a dose whose answer was lost may start
    internal static let recordMatchWindow: TimeInterval = 60

    /// How long before when its answer came - its `sentAt` (`UnfinalizedDose.init(rawValue:)`) - on the patch clock, a
    /// record in the backlog may start to be that of the bolus the released driver had in flight
    /// (`releasedBolusBacklogRecordWindow`). The patch starts delivering before it answers, a second or so (device
    /// 2026-10-14); the rest is an answer late on a slow link.
    internal static let releasedBolusBacklogRecordLead: TimeInterval = 10

    /// How long before when its command went out, on the patch clock, a bolus of ours whose answer was lost may have its
    /// record start - the skew is known to a few seconds (protocol fact C1): a record starting later is never taken for
    /// the bolus the released driver had in flight, which ran before it (`releasedBolusRecordBounds`)
    internal static let lostAnswerBolusRecordLead: TimeInterval = 5

    /// `dose` is a bolus the released driver had in flight, saved without `sequenceAtSend` - every bolus since is sent
    /// with it - and dated as its answer came. At most one: that driver ran one bolus at a time. Matched to its record by
    /// `matchReleasedBolusRecord`.
    internal static func isReleasedDriversBolus(_ dose: UnfinalizedDose, _ snapshot: UnfinalizedDose.State? = nil) -> Bool {
        dose.type == .bolus && (snapshot ?? dose.snapshot).sequenceAtSend == nil
    }

    /// Whether a bolus record starting at `start` on the patch clock can be that of `dose`, whose answer was lost, by
    /// when it went out: within `recordMatchWindow` of then, `nearItsCommand` - or anywhere, not. The bolus the released
    /// driver had in flight is never matched near its command - only by `matchReleasedBolusRecord` - and may be any
    /// other's, but for one whose end this build never saw (`isBacklogBolus`): its own record is at or before the session
    /// start, by definition - one past it is never its own, and one at or before it is history, never told of. Only
    /// under `doseReportLock`.
    private func recordStart(_ start: Date, mayBeOf dose: UnfinalizedDose, nearItsCommand: Bool) -> Bool {
        let snapshot = dose.snapshot
        if Self.isReleasedDriversBolus(dose, snapshot) {
            return !nearItsCommand && !Self.isBacklogBolus(snapshot)
        }
        guard let sentAt = snapshot.sentAt else {
            return !nearItsCommand
        }
        let offset = start.timeIntervalSince(sentAt.addingTimeInterval(state.patchClockSkew))
        return !nearItsCommand || abs(offset) <= Self.recordMatchWindow
    }

    /// Applies one record read off the patch: finalizes the bolus waiting on it, if any - by the number its command's
    /// answer gave it, or one whose answer was lost by when its command went out - or the temp basal whose command went
    /// unanswered it shows ran. A temp basal of ours that ended back to back is finalized by its records
    /// (`openTempBasalEnds`); any other was finalized as it ended (`TempBasalEnd`). Only finalizes: the identity of a dose
    /// never moves. Returns what it did, for the record screen.
    internal func reconcile(_ response: GetRecordResponse) -> String? {
        switch response.record {
        case let .bolus(record):
            guard record.type == .NORMAL else {
                log.warning("Record \(response.sequence): \(record.type) bolus, we only deliver normal boluses")
                return "not a normal bolus"
            }

            return doseReportLock.withLock { () -> String in
                let waiting = state.awaitingRecord.filter { $0.type == .bolus && !$0.isFinalized }
                // A number a SetBolus answer gave is that bolus's record - see `MedtrumPumpState.answeredBolusRecords`:
                // never that of one whose answer was lost
                let claimed = state.answeredBolusRecords.contains(response.sequence)
                // Whether this record can be that of `dose`, whose answer was lost: unclaimed, at its amount, numbered
                // past the newest known when its command went out, starting near then - the released driver's never
                // near its command, matched on its own (`matchReleasedBolusRecord`)
                let couldBeOf = { (dose: UnfinalizedDose, nearItsCommand: Bool) -> Bool in
                    let snapshot = dose.snapshot
                    guard !claimed, snapshot.recordSequence == nil, snapshot.sentAt != nil, self.isNumberedOnThisPatch(snapshot)
                    else {
                        return false
                    }
                    return response.sequence > snapshot.sequenceAtSend ?? 0 &&
                        RecordSyncer.steps(record.normalAmount) == RecordSyncer.steps(dose.value) &&
                        self.recordStart(record.startTime, mayBeOf: dose, nearItsCommand: nearItsCommand)
                }
                // Whatever it finalizes, a bolus whose command went unanswered this record could be of may have run -
                // see `unansweredBolusNeverRan`
                for dose in unansweredBoluses where couldBeOf(dose, true) {
                    dose.notePossibleRecord(response.sequence)
                }

                let dose: UnfinalizedDose
                // The number another patch's answer gave is not this one's record
                if let numbered = waiting.first(where: {
                    $0.recordSequence == response.sequence && isNumberedOnThisPatch($0.snapshot)
                }) {
                    // Its record by the number alone: a start or amount other than ours is only worth a look
                    let answeredStart = numbered.snapshot.pumpStartTime
                    let startDiffers = answeredStart.map {
                        abs(record.startTime.timeIntervalSince($0)) > RecordSyncer.bolusStartTolerance
                    } ?? false
                    if startDiffers || RecordSyncer.steps(record.normalAmount) != RecordSyncer.steps(numbered.value) {
                        log.warning(
                            "Record \(response.sequence) of the bolus of \(numbered.startDate) is of \(record.normalAmount) U " +
                                "from \(record.startTime), where we asked for \(numbered.value) U and its answer said " +
                                "\(answeredStart.map { "\($0)" } ?? "-") - finalizing it with it, by its number"
                        )
                    }
                    dose = numbered
                } else if claimed {
                    // Final from our estimate, its record unread till now: what it delivered may not be what the host has
                    if let index = state.bolusesFinalWithoutRecord.firstIndex(where: { $0.recordSequence == response.sequence }) {
                        let final = state.bolusesFinalWithoutRecord.remove(at: index)
                        log.info(
                            "Record \(response.sequence) is that of the bolus of \(final.units) U sent at \(final.sentAt), final " +
                                "from our estimate already"
                        )
                        explain(response.sequence, delivered: record.normalDelivered, from: record.startTime, by: final)
                    } else {
                        log.info("Record \(response.sequence) is that of a bolus of ours finalized already, matching nothing")
                    }
                    return "answered bolus finalized already"
                } else if let shifted = waiting.first(where: {
                    isNumberedOnThisPatch($0.snapshot) && isRecordPastItsTakenNumber(record, response.sequence, of: $0)
                }) {
                    // Its answered start to the second: no other bolus starts there. One whose answer was lost that it
                    // could be the record of has it noted as a possible one (above) - counted in full until its own.
                    if let other = waiting.first(where: { $0 !== shifted && couldBeOf($0, true) }) {
                        log.warning(
                            "Record \(response.sequence) could also be that of the bolus of \(other.startDate) whose answer " +
                                "was lost: taken for the bolus of \(shifted.startDate), whose answered start it has"
                        )
                    }
                    log.info(
                        "Record \(response.sequence) is that of the bolus of \(shifted.startDate), the record its answer named " +
                            "#\(shifted.recordSequence ?? 0) one of another kind: at its answered start, of its amount"
                    )
                    // Claimed as an answered number is: never taken for another bolus, read again
                    noteAnsweredBolusRecord(response.sequence)
                    dose = shifted
                } else if let released = waiting.first(where: { Self.isReleasedDriversBolus($0) }),
                          let outcome = matchReleasedBolusRecord(PossibleBolusRecord(record, response.sequence), of: released)
                {
                    return outcome
                } else if let unanswered = waiting.first(where: { couldBeOf($0, true) }) {
                    // Claimed as an answered number is: read again, it is no other bolus's, nor one the host is missing
                    noteAnsweredBolusRecord(response.sequence)
                    dose = unanswered
                } else {
                    log.info(
                        "Record \(response.sequence): bolus of \(record.normalAmount) U at \(record.startTime) " +
                            "matches no dose of ours, not imported"
                    )
                    // Ours by its amount, should the patch clock be further off than we think - one whose answer was
                    // lost, its progress or completion seen since included: its record is looked for all the same. The
                    // released driver's too, still running - read before the patch is stopped - at any start: a safety
                    // net for a patch clock set again from the settings, which shifts its own record's start out of
                    // its bounds (`releasedBolusRecordBounds`) - taken for it as it goes final by estimate, a wrong one
                    // tells of a miscount at worst (`settlePossibleBolusRecords`). Never for one whose end this build
                    // never saw: its record is in the backlog (`recordStart(_:mayBeOf:nearItsCommand:)`).
                    var possiblyOurs = false
                    for dose in bolusesWithoutTheirAnsweredRecord where couldBeOf(dose, false) {
                        if dose.snapshot.confirmation == .uncertain {
                            dose.notePossibleRecord(response.sequence)
                        }
                        possiblyOurs = true
                    }
                    warnOfBolusNotCounted(PossibleBolusRecord(record, response.sequence), possiblyOurs: possiblyOurs)
                    return "unmatched"
                }

                // Kept as possibly that of a bolus whose answer was lost, read again now that it is near enough to be its:
                // settled here - not told of as no bolus of ours as the bolus goes final
                state.possibleBolusRecords.removeAll { $0.sequence == response.sequence }

                let matched = dose.snapshot
                log.info(
                    "Record \(response.sequence) finalizes the bolus of \(dose.startDate) " +
                        "(\(matched.finishReason?.rawValue ?? "-")): delivered \(record.normalDelivered) U of \(dose.value) U, " +
                        "last reported \(matched.deliveredUnits) U"
                )

                emitFinal(dose, deliveredUnits: record.normalDelivered)
                return "finalized bolus \(dose.startDate)"
            }

        case let .basal(record):
            if record.endReason?.isSuspendedByPump() == true {
                log.info("Record \(response.sequence): \(record.type) segment ended by \(record.endReason.map { "\($0)" } ?? "-")")
            }

            // The scheduled basal between a cancel and a set, and the like: nothing of ours waits on it
            guard record.type.isTempBasal() else {
                return nil
            }

            guard record.type == .ABSOLUTE_TEMP else {
                log.info("Record \(response.sequence): \(record.type) segment, we only set absolute temp basals - not ours")
                return "not an absolute temp basal"
            }

            return doseReportLock.withLock { () -> String in
                // A part of a temp basal of ours that ended back to back, mutable until its records are read
                if let outcome = keepPartOfOpenTempBasal(record, response: response) {
                    return outcome
                }

                // Any other temp basal of ours is final from its end on - from its records, read as it ended, or our
                // estimate: read again, or later, its record changes nothing
                if let dose = state.awaitingRecord.first(where: { dose in
                    guard dose.type == .tempBasal, let pumpStartTime = dose.pumpStartTime else {
                        return false
                    }
                    return abs(record.startTime.timeIntervalSince(pumpStartTime)) <= RecordSyncer.tempBasalStartTolerance
                }) {
                    log.info("Record \(response.sequence) is that of the temp basal of \(dose.startDate), final already")
                    return "temp basal finalized already"
                }

                if let outcome = keepPartOfRunningTempBasal(record, response: response) {
                    return outcome
                }

                if let finalized = finalizeUnconfirmedTempBasal(from: record, sequence: response.sequence) {
                    emitPumpEvents(finalized.events)
                    return finalized.outcome
                }

                log.info(
                    "Record \(response.sequence): temp basal of \(record.rate) U/h at \(record.startTime) matches no " +
                        "dose of ours, not imported"
                )
                return "unmatched"
            }

        case .event,
             .invalid,
             .tdd,
             .truncated,
             .unhandled:
            return nil
        }
    }

    /// Bolus `record`, numbered `sequence`, of this patch, matches no dose of ours: not imported - it may be one the host
    /// has after all, which would count twice - but what it delivered may be missing at the host for good. A bolus
    /// written as the app was killed before the host saved it pending, say, or another app's. Looked at once per record
    /// (`MedtrumPumpState.unmatchedBolusRecords`) - not if written before this state took up the patch
    /// (`sessionStartSequence`). One a bolus of ours whose answer was lost could be (`possiblyOurs`), waiting on its
    /// record, is kept until that one settles (`settlePossibleBolusRecords`); any other is told of now
    /// (`tellOfBolusRecord`). Only under `doseReportLock`.
    private func warnOfBolusNotCounted(_ unmatched: PossibleBolusRecord, possiblyOurs: Bool) {
        let sequence = unmatched.sequence
        guard !state.unmatchedBolusRecords.contains(sequence) else {
            return
        }
        guard let sessionStart = state.sessionStartSequence else {
            log.info("Record \(sequence): the patch is not taken up yet, no status has named its newest record - not told of")
            return
        }
        guard sequence > sessionStart else {
            log.info("Record \(sequence) was written before the patch was taken up, at #\(sessionStart): not told of")
            return
        }
        state.unmatchedBolusRecords = Array((state.unmatchedBolusRecords + [sequence]).suffix(Self.unmatchedBolusRecordsKept))

        guard !possiblyOurs else {
            log.info(
                "Record \(sequence) could be that of a bolus of ours whose answer was lost, waiting on its record: " +
                    "looked at again as it settles"
            )
            state.possibleBolusRecords = Array((state.possibleBolusRecords + [unmatched]).suffix(Self.unmatchedBolusRecordsKept))
            return
        }
        tellOfBolusRecord(unmatched)
    }

    /// What bolus record `read` - claimed by no answer, of a normal bolus - is to `dose`, the bolus the released driver
    /// had in flight, waiting on its record: for the record screen, nil if it cannot be its own.
    ///
    /// - Numbered past the session start (`MedtrumPumpState.sessionStartSequence`), at its amount, for one this build saw
    ///   delivering or completing: its own, the first such record (rule A). Nothing else could have written it: the
    ///   patch runs one bolus at a time, refusing another while one runs (protocol fact 11); every bolus of ours since is
    ///   claimed by its answer's number; and a bolus before it wrote its record before this one started. Bounded all the
    ///   same (`releasedBolusRecordBounds`), wide on either side - the skew is off by more than its usual few seconds at
    ///   times (protocol fact C1), the patch clock may have been set again from the settings: a record starting well
    ///   before it went out is a bolus's before it, numbered past the session start by a first status that lagged; one
    ///   starting past its deadline, or after a bolus of ours whose answer was lost went out, is a later one's. Such a
    ///   record goes on to the matches below it in `reconcile` - that bolus's, or no dose of ours.
    /// - At or before the session start, written while the app was down: looked at only for one whose end this build
    ///   never saw - neither delivering nor completing (`isBacklogBolus`) - and only that one's (rule B): its record is
    ///   in the backlog by definition, so a record past the session start is never its own. One seen either way wrote
    ///   its record as the app ran: past the session start - or at it, its completion the status that took the patch up,
    ///   when it goes final from what that completion said, once its record is overdue (`finalizeOverdueAwaitingDoses`).
    ///   Of the records at its amount starting in its window (`releasedBolusBacklogRecordWindow`), the newest is its
    ///   own: one before it was written first. It is kept (`MedtrumPumpState.releasedBolusBacklogRecord`) until every
    ///   record written since the bolus ended is read (`mayTakeReleasedBolusBacklogRecord`), and finalizes it then. A
    ///   wrong pick tells of nothing - every record up to the session start is history - but it sets the amount.
    ///
    /// Final from our estimate instead, its record not found: a record read later that no dose waits on is its own - not
    /// told of as a bolus the host is missing - only at its amount and starting within `releasedBolusRecordBounds` of it
    /// (`tellOfBolusRecord`).
    ///
    /// Only under `doseReportLock`.
    private func matchReleasedBolusRecord(_ read: PossibleBolusRecord, of dose: UnfinalizedDose) -> String? {
        guard let sessionStart = state.sessionStartSequence,
              RecordSyncer.steps(read.amount) == RecordSyncer.steps(dose.value)
        else {
            return nil
        }

        let snapshot = dose.snapshot
        if read.sequence > sessionStart {
            // Rule B's: its own record is in the backlog
            guard !Self.isBacklogBolus(snapshot) else {
                return nil
            }
            guard releasedBolusRecordBounds(units: dose.value, sentAt: snapshot.sentAt ?? dose.startDate).contains(read.startTime)
            else {
                log.info(
                    "Record \(read.sequence), past the session start #\(sessionStart) and of its amount, starts too far from " +
                        "when the bolus of \(dose.startDate) the released driver had in flight went out to be its own"
                )
                return nil
            }
            let skew = state.patchClockSkew
            let othersWaiting = ([state.bolusDose].compactMap { $0 } + state.awaitingRecord).filter { other in
                other !== dose && other.type == .bolus && !other.isFinalized
            }
            if let later = othersWaiting.first(where: { other in
                let snapshot = other.snapshot
                guard snapshot.recordSequence == nil, !Self.isReleasedDriversBolus(other, snapshot),
                      let sentAt = snapshot.sentAt
                else {
                    return false
                }
                return read.startTime >= sentAt.addingTimeInterval(skew - Self.lostAnswerBolusRecordLead)
            }) {
                log.info(
                    "Record \(read.sequence) starts after the bolus of \(later.startDate), whose answer was lost, went out: " +
                        "not that of the bolus of \(dose.startDate) the released driver had in flight, which ran before it"
                )
                return nil
            }
            if !othersWaiting.isEmpty {
                log.info(
                    "Record \(read.sequence) is taken for the bolus of \(dose.startDate) the released driver had in flight " +
                        "while the bolus(es) of \(othersWaiting.map { "\($0.startDate)" }.joined(separator: ", ")) of this build " +
                        "wait on theirs"
                )
            }
            log.info(
                "Record \(read.sequence), past the session start #\(sessionStart) and of its amount, is that of the bolus of " +
                    "\(dose.startDate) the released driver had in flight: nothing else ran"
            )
            takeReleasedBolusRecord(read, for: dose)
            return "finalized bolus \(dose.startDate)"
        }

        guard Self.isBacklogBolus(snapshot),
              releasedBolusBacklogRecordWindow(of: dose, snapshot).contains(read.startTime),
              read.sequence >= state.releasedBolusBacklogRecord?.sequence ?? read.sequence
        else {
            return nil
        }
        if let kept = state.releasedBolusBacklogRecord, kept.sequence != read.sequence {
            log.info("Record \(read.sequence), newer than record \(kept.sequence), is kept for the bolus of \(dose.startDate) instead")
        }
        state.releasedBolusBacklogRecord = read

        guard mayTakeReleasedBolusBacklogRecord(of: dose, readThrough: max(state.syncedSequenceNumber, read.sequence)) else {
            log.info(
                "Record \(read.sequence) could be that of the bolus of \(dose.startDate) the released driver had in flight: " +
                    "kept until every record written since it ended is read, a newer one may follow"
            )
            return "kept for bolus \(dose.startDate)"
        }
        takeReleasedBolusRecord(read, for: dose)
        return "finalized bolus \(dose.startDate)"
    }

    /// Where, on the patch clock, the record of the bolus the released driver had in flight - of `units`, its answer come
    /// at `sentAt` - may start, read past the session start, or once it went final from our estimate: from
    /// `recordMatchWindow` before then - as for any bolus whose command's answer is not its record's number - up to its
    /// deadline (`UnfinalizedDose.deliveryDeadline`), as it ran.
    private func releasedBolusRecordBounds(units: Double, sentAt: Date) -> ClosedRange<Date> {
        let skew = state.patchClockSkew
        return sentAt.addingTimeInterval(skew - Self.recordMatchWindow) ...
            UnfinalizedDose.deliveryDeadline(of: units, sentAt: sentAt).addingTimeInterval(skew)
    }

    /// The bolus the released driver had in flight, `snapshot`, ended unseen - never seen delivering by this build, nor
    /// completing: it may have ended before the app was back, its record in the backlog. Decided by what this build saw
    /// of it, not by the status that took the patch up alone: one whose progress it saw
    /// (`UnfinalizedDose.State.lastProgressAt`, never saved by that driver) - that status showing it delivering, or any
    /// since - or whose completion it saw (`.completed`, or cancelled) ended as the app ran, its record written then.
    private static func isBacklogBolus(_ snapshot: UnfinalizedDose.State) -> Bool {
        snapshot.finishReason == .completionNotSeen && snapshot.lastProgressAt == nil
    }

    /// Where, on the patch clock, the record of `dose`, the bolus the released driver had in flight, may start in the
    /// backlog: from `releasedBolusBacklogRecordLead` before its answer came, up to its deadline - its amount at the
    /// slowest rate, and some (`UnfinalizedDose.deliveryDeadline`). Wide after: the newest record in it is taken.
    private func releasedBolusBacklogRecordWindow(of dose: UnfinalizedDose, _ snapshot: UnfinalizedDose.State) -> ClosedRange<Date> {
        let skew = state.patchClockSkew
        let answeredAt = (snapshot.sentAt ?? dose.startDate).addingTimeInterval(skew)
        return answeredAt.addingTimeInterval(-Self.releasedBolusBacklogRecordLead) ...
            dose.deliveryDeadline(of: snapshot).addingTimeInterval(skew)
    }

    /// Whether the record kept from the backlog for `dose`, the bolus the released driver had in flight, is its own:
    /// every record is read - through `readThrough` - that a status named after its deadline. Its end unseen, it ended
    /// by then, its record written: `checkBolusDone` ends it only at a status at or past its deadline, so the deadline is
    /// never later than when it ended - nor, its record named after it, than that record's. Read through the cursor,
    /// the session start is read through: the cursor never names a record before it.
    private func mayTakeReleasedBolusBacklogRecord(of dose: UnfinalizedDose, readThrough: Int) -> Bool {
        isCaughtUp(after: dose.deliveryDeadline(of: dose.snapshot), readThrough: readThrough)
    }

    /// Finalizes `dose`, the bolus the released driver had in flight, from `record`, its own - see
    /// `matchReleasedBolusRecord` - and hands the final to the host. Only under `doseReportLock`.
    private func takeReleasedBolusRecord(_ record: PossibleBolusRecord, for dose: UnfinalizedDose) {
        // Claimed as an answered number is: read again, it is no other bolus's, nor one the host is missing
        noteAnsweredBolusRecord(record.sequence)
        state.possibleBolusRecords.removeAll { $0.sequence == record.sequence }

        let matched = dose.snapshot
        log.info(
            "Record \(record.sequence) finalizes the bolus of \(dose.startDate) the released driver had in flight " +
                "(\(matched.finishReason?.rawValue ?? "-")): delivered \(record.delivered) U of \(dose.value) U, last " +
                "reported \(matched.deliveredUnits) U"
        )
        emitFinal(dose, deliveredUnits: record.delivered)
    }

    /// The record kept from the backlog for the bolus the released driver had in flight finalizes it, once every record
    /// written since it ended is read - see `matchReleasedBolusRecord`. After each record a sync applies, and as it ends.
    internal func settleReleasedBolusBacklogRecord() {
        doseReportLock.withLock {
            // Kept only while the bolus waits: its final - any way - lets go of it (`finalize`), as does a patch change
            guard let kept = state.releasedBolusBacklogRecord,
                  let dose = state.awaitingRecord.first(where: { !$0.isFinalized && Self.isReleasedDriversBolus($0) }),
                  mayTakeReleasedBolusBacklogRecord(of: dose, readThrough: state.syncedSequenceNumber)
            else {
                return
            }
            takeReleasedBolusRecord(kept, for: dose)
        }
    }

    /// `unmatched`, a bolus record no dose of ours waits on, nor could: the record of a bolus of ours that went final
    /// from our estimate (`bolusesFinalWithoutRecord`) - by the number its answer named; else at its amount, delivering
    /// no more, starting where its answer said, or near when it went out, its answer lost (`recordMatchWindow`, as for
    /// any) - what it delivered compared with what the host has (`explain`), each entry explaining one record. Any
    /// other is a bolus the host is missing: the user is told to add it, unless it delivered nothing
    /// (`tellOfBolusNotCounted`). Only under `doseReportLock`.
    private func tellOfBolusRecord(_ unmatched: PossibleBolusRecord) {
        let skew = state.patchClockSkew
        if let index = state.bolusesFinalWithoutRecord.firstIndex(where: { final in
            if let recordSequence = final.recordSequence, recordSequence == unmatched.sequence {
                return true
            }
            guard RecordSyncer.steps(unmatched.amount) == RecordSyncer.steps(final.units),
                  RecordSyncer.steps(unmatched.delivered) <= RecordSyncer.steps(final.units)
            else {
                return false
            }
            if let pumpStartTime = final.pumpStartTime {
                return abs(unmatched.startTime.timeIntervalSince(pumpStartTime)) <= RecordSyncer.bolusStartTolerance
            }
            // The released driver's: a record of its amount starting from a while before its answer came up to its
            // deadline - see `matchReleasedBolusRecord`
            guard !final.datedByItsAnswer else {
                return releasedBolusRecordBounds(units: final.units, sentAt: final.sentAt).contains(unmatched.startTime)
            }
            return abs(unmatched.startTime.timeIntervalSince(final.sentAt.addingTimeInterval(skew))) <= Self.recordMatchWindow
        }) {
            let final = state.bolusesFinalWithoutRecord.remove(at: index)
            log.info(
                "Record \(unmatched.sequence) is that of the bolus of \(final.units) U sent at \(final.sentAt), final from our " +
                    "estimate already"
            )
            explain(unmatched.sequence, delivered: unmatched.delivered, from: unmatched.startTime, by: final)
            return
        }

        tellOfBolusNotCounted(unmatched)
    }

    /// Record `sequence`, starting at `startTime` on the patch clock, delivered `delivered`, is that of the bolus of
    /// `final`, final from our estimate: compared with what the host has (`compare`). A possible record taken for its own
    /// as it went final (`BolusFinalWithoutRecord.taken`) was another bolus's, then - one the host is missing: told of,
    /// not looked up against these again (`tellOfBolusNotCounted`), once - the entry explains one record. Its own
    /// delivering what the taken one did, it was compared as that one was taken: nothing more. Only under
    /// `doseReportLock`.
    private func explain(_ sequence: Int, delivered: Double, from startTime: Date, by final: BolusFinalWithoutRecord) {
        if let taken = final.taken, RecordSyncer.steps(taken.delivered) == RecordSyncer.steps(delivered) {
            log.info(
                "Record \(sequence): \(delivered) U delivered, as record \(taken.sequence) taken for it - compared as that one " +
                    "was taken"
            )
        } else {
            compare(final.delivered, withItsRecord: delivered, from: startTime, sequence)
        }
        guard let taken = final.taken else {
            return
        }
        log.warning(
            "Record \(taken.sequence), taken for that of the bolus sent at \(final.sentAt) as it went final, is another " +
                "bolus's: its own is \(sequence)"
        )
        tellOfBolusNotCounted(taken)
    }

    /// `unmatched`, a bolus record, is a bolus the host is missing: the user is told to add it, unless it delivered
    /// nothing. Only under `doseReportLock`.
    private func tellOfBolusNotCounted(_ unmatched: PossibleBolusRecord) {
        let skew = state.patchClockSkew
        guard RecordSyncer.steps(unmatched.delivered) > 0 else {
            log.info("Record \(unmatched.sequence) delivered nothing: not told of")
            return
        }
        let startedAt = unmatched.startTime.addingTimeInterval(-skew)
        log.warning(
            "Record \(unmatched.sequence): a bolus of \(unmatched.delivered) U delivered from \(startedAt) that the host has " +
                "no dose of - the user is told to add it"
        )
        emitAlert(alertType: .bolusNotCounted(units: unmatched.delivered, at: startedAt))
    }

    /// A bolus of ours final from our estimate, `counted` - what the host has - and its record, numbered `sequence`,
    /// starting at `startTime` on the patch clock, read after all: delivered `delivered`. Further apart than a step -
    /// the progress last reported rounds - the host has it wrong for good, its final fixed: the user is told - to add
    /// what is missing, or that insulin on board is overstated. Only under `doseReportLock`.
    private func compare(_ counted: Double, withItsRecord delivered: Double, from startTime: Date, _ sequence: Int) {
        let apart = RecordSyncer.steps(delivered) - RecordSyncer.steps(counted)
        guard abs(apart) > 1 else {
            log.info("Record \(sequence): \(delivered) U delivered, \(counted) U counted - not told of")
            return
        }
        let startedAt = startTime.addingTimeInterval(-state.patchClockSkew)
        log.warning(
            "Record \(sequence): the bolus of \(startedAt) delivered \(delivered) U, the host has \(counted) U from our " +
                "estimate - " + (apart > 0 ? "the user is told to add the rest" : "insulin on board overstated, the user is told")
        )
        emitAlert(alertType: .bolusMiscounted(counted: counted, delivered: delivered, at: startedAt))
    }

    /// `dose`, a bolus, went final - `outcome`. The bolus records kept as possibly those of one whose answer was lost
    /// (`MedtrumPumpState.possibleBolusRecords`): one that could be `dose`'s, final from our estimate, is taken for its
    /// record, what it delivered compared with what the host has (`compare`) - read again, nothing more is done - and
    /// returned, kept with `dose`'s entry (`BolusFinalWithoutRecord.taken`). Any other that no bolus still waiting on its
    /// record could be is told of now (`tellOfBolusRecord`) - `dose` final from its own record, or never run. Only under
    /// `doseReportLock`.
    internal func settlePossibleBolusRecords(
        after dose: UnfinalizedDose,
        _ outcome: UncertainDelivery.Outcome
    ) -> PossibleBolusRecord? {
        guard !state.possibleBolusRecords.isEmpty else {
            return nil
        }
        // Its answer lost - unanswered, or confirmed since by its progress or completion: no record named
        let couldBe = { (possible: PossibleBolusRecord, dose: UnfinalizedDose) -> Bool in
            let snapshot = dose.snapshot
            return dose.type == .bolus && snapshot.recordSequence == nil && self.isNumberedOnThisPatch(snapshot) &&
                possible.sequence > snapshot.sequenceAtSend ?? 0 &&
                RecordSyncer.steps(possible.amount) == RecordSyncer.steps(dose.value) &&
                self.recordStart(possible.startTime, mayBeOf: dose, nearItsCommand: false)
        }

        let final = dose.snapshot
        var taken: PossibleBolusRecord?
        var kept: [PossibleBolusRecord] = []
        for possible in state.possibleBolusRecords {
            if taken == nil, outcome == .byEstimate, couldBe(possible, dose) {
                taken = possible
                log.info(
                    "Record \(possible.sequence), possibly that of the bolus of \(dose.startDate) whose answer was lost, " +
                        "final from our estimate: taken for its record"
                )
                compare(final.finalDeliveredUnits ?? dose.value, withItsRecord: possible.delivered, from: possible.startTime, possible.sequence)
            } else if bolusesWithoutTheirAnsweredRecord.contains(where: { $0 !== dose && couldBe(possible, $0) }) {
                kept.append(possible)
            } else {
                log.info("Record \(possible.sequence) is no bolus of ours that waits on its record after all")
                tellOfBolusRecord(possible)
            }
        }
        state.possibleBolusRecords = kept
        return taken
    }

    /// The latest boluses final from our estimate kept for their record, and the unmatched bolus records looked at: a
    /// patch session's worth, and some
    internal static let bolusesFinalWithoutRecordKept = 50
    private static let unmatchedBolusRecordsKept = 50

    /// Record `response`, of another kind than a bolus's, came back at the number the answer to a bolus of ours named:
    /// the patch wrote it as the bolus ran - an alarm, say (device 2026-10-22 13:52, #1606 a low-reservoir alarm, the
    /// bolus #1607) - and the bolus's own comes after it. Kept with the bolus - see `UnfinalizedDose.State
    /// .answeredRecordTaken` - the two may be read in different runs. For every record read, whatever takes it - the
    /// temp basal it settles, as it ends, takes it before `reconcile` would (`RecordSyncer.apply`). Unreadable records
    /// never get here (`RecordSyncer.readOnce`): one that is the bolus's own, unparsed, does not make it taken.
    internal func noteAnsweredBolusRecordTaken(by response: GetRecordResponse) {
        switch response.record {
        case .basal,
             .event,
             .tdd,
             .unhandled:
            break
        case .bolus,
             .invalid,
             .truncated:
            return
        }
        doseReportLock.withLock {
            for dose in state.awaitingRecord + [state.bolusDose].compactMap({ $0 })
                where dose.type == .bolus && dose.recordSequence == response.sequence
            {
                guard dose.noteAnsweredRecordTaken() else {
                    continue
                }
                log.warning(
                    "Record \(response.sequence), the one the answer to the bolus of \(dose.startDate) named, is no bolus " +
                        "record: the bolus's own is numbered after it, matched by its answered start"
                )
            }
        }
    }

    /// Whether bolus `record`, numbered `sequence`, is that of `dose`, whose answered number came back as a record of
    /// another kind (`noteAnsweredBolusRecordTaken`): numbered past it, starting on its answered patch start, for its
    /// amount, delivering no more. Unclaimed - the caller checks. Only under `doseReportLock`.
    private func isRecordPastItsTakenNumber(_ record: BolusRecord, _ sequence: Int, of dose: UnfinalizedDose) -> Bool {
        let snapshot = dose.snapshot
        guard snapshot.answeredRecordTaken, let answered = snapshot.recordSequence, sequence > answered,
              let answeredStart = snapshot.pumpStartTime
        else {
            return false
        }
        return abs(record.startTime.timeIntervalSince(answeredStart)) <= RecordSyncer.bolusStartTolerance &&
            RecordSyncer.steps(record.normalAmount) == RecordSyncer.steps(dose.value) &&
            RecordSyncer.steps(record.normalDelivered) <= RecordSyncer.steps(dose.value)
    }
}

extension PossibleBolusRecord {
    /// Bolus `record`, read as numbered `sequence`
    init(_ record: BolusRecord, _ sequence: Int) {
        self.init(sequence: sequence, amount: record.normalAmount, delivered: record.normalDelivered, startTime: record.startTime)
    }
}

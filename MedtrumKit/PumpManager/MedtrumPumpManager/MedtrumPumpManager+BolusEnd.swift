import LoopKit

public extension MedtrumPumpManager {
    /// `completed: false` in a status received at `receivedAt`: the running bolus has delivered this much so far.
    /// Never from a status received before its command went out, nor from a full status for one whose command went
    /// unanswered - a full status never confirms that one. A notification's does: the patch is delivering it.
    internal func updateBolusProgress(delivered: Double, fullSync: Bool, receivedAt: Date, receivedUptime: TimeInterval) {
        let outcome = doseReportLock.withLock { () -> (dose: UnfinalizedDose, confirmed: Bool)? in
            guard let doseEntry = state.bolusDose else {
                return nil
            }

            let running = doseEntry.snapshot
            guard !running.isFinished,
                  !Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime),
                  !(fullSync && running.confirmation == .uncertain)
            else {
                return nil
            }

            let progress = doseEntry.updateProgress(delivered: delivered, at: receivedAt, uptime: receivedUptime)
            return progress.taken ? (doseEntry, progress.confirmed) : nil
        }

        if let outcome, outcome.confirmed {
            log.info("The patch reports delivering the bolus of \(outcome.dose.startDate) whose command went unanswered: confirmed")
        }
    }

    /// A completion notification received at `receivedAt`: a notification carries the field only while a bolus runs,
    /// so it is the running bolus's own, with what it delivered - a tiny one included, which completes before any
    /// progress. A full status's completion is not this: it repeats the last bolus's for hours. Returns whether the
    /// running bolus took it.
    @discardableResult internal func completeBolus(
        delivered: Double,
        receivedAt: Date,
        receivedUptime: TimeInterval,
        endedAt: Date? = nil
    ) -> Bool {
        let completed = doseReportLock.withLock { () -> Bool in
            guard let doseEntry = state.bolusDose else {
                return false
            }

            let running = doseEntry.snapshot
            guard !running.isFinished,
                  !Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime)
            else {
                return false
            }

            if running.confirmation == .uncertain {
                log.info("The patch reports completing the bolus of \(doseEntry.startDate) whose command went unanswered")
            }

            var events = runningTempBasal()
            events.append(contentsOf: awaitRecord(doseEntry, .completed, deliveredUnits: delivered, endedAt: endedAt ?? Date.now))
            endBolusStallWatch(
                doseEntry,
                delivered: doseEntry.deliveredUnits,
                receivedAt: receivedAt,
                receivedUptime: receivedUptime,
                "completed"
            )
            state.bolusDose = nil
            state.lastSync = Date.now
            emitBolusEvents(events)
            return true
        }

        guard completed else {
            return false
        }

        notifyStateDidChange()

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                return
            }

            delegate.pumpManager(
                self,
                didReadReservoirValue: self.state.reservoir.rounded(toPlaces: 1),
                at: self.state.lastSync
            ) { result in
                switch result {
                case let .failure(error):
                    self.handlePumpDelegateError(method: "didReadReservoirValue", error)
                case .success:
                    break
                }
            }
        }

        return true
    }

    internal struct EarlyBolusCompletion {
        let delivered: Double
        /// The newest record the notification names, if it does: the bolus's own, written as it completed
        let record: Int?
        let receivedAt: Date
        let receivedUptime: TimeInterval
    }

    /// A completion notification with no bolus running to take it, received at `receivedAt`, naming `record` as the
    /// newest if it does. The bolus sent and not yet answered's - the patch delivers a small one before it answers -
    /// if the record is past every one known when it went out, or no cancelled bolus is there to take it: kept for it,
    /// taken once it runs (`completeBolusEarly`). Otherwise the completion of the bolus a cancel just ended
    /// (`raiseCancelledBolus`).
    internal func noteCompletionWithNoBolusRunning(delivered: Double, record: Int?, receivedAt: Date, receivedUptime: TimeInterval) {
        let registeredSince = doseReportLock.withLock { () -> Bool in
            // Registered since `completeBolus` looked: its answer, handled on this queue, woke the command meanwhile
            guard state.bolusDose == nil else {
                return true
            }

            if let pending = state.pendingBolus, isCompletion(record: record, of: pending) {
                log.info(
                    "Completion of \(delivered) U, record \(record.map { "#\($0)" } ?? "-"), before the answer to the " +
                        "bolus of \(pending.units) U sent at \(pending.sentAt): kept for it"
                )
                earlyBolusCompletion = EarlyBolusCompletion(
                    delivered: delivered,
                    record: record,
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                )
                return false
            }

            raiseCancelledBolus(delivered: delivered, record: record)
            return false
        }

        if registeredSince, !completeBolus(delivered: delivered, receivedAt: receivedAt, receivedUptime: receivedUptime) {
            raiseCancelledBolus(delivered: delivered, record: record)
        }
    }

    /// Whether a completion naming `record`, if it does, is that of the bolus `pending` - sent, not yet answered: past
    /// every record known when it went out, no earlier bolus's. Unless one a cancel ended moments ago went unanswered,
    /// its number unknown; with no record, unless one a cancel ended moments ago is there to take it.
    private func isCompletion(record: Int?, of pending: PendingBolus) -> Bool {
        let cancelled = recentlyCancelledBolus()
        guard let record else {
            return cancelled == nil
        }
        return record > pending.sequenceAtSend && (cancelled.map { $0.snapshot.recordSequence != nil } ?? true)
    }

    /// `dose`, just registered, completed before its answer came - as `early` says, unless it is not its completion: it
    /// names another record than the answer gave, says more was delivered than it was for, or came before it went out.
    /// Then it is a cancelled bolus's, if any. Returns whether it ended `dose`.
    @discardableResult internal func completeBolusEarly(_ dose: UnfinalizedDose, _ early: EarlyBolusCompletion) -> Bool {
        // Its completion came again since, and ended it
        guard !dose.snapshot.isFinished else {
            return true
        }

        var notIts: String?
        if let record = early.record, let answered = dose.snapshot.recordSequence, record != answered {
            notIts = "it names record #\(record), the bolus is #\(answered)"
        } else if RecordSyncer.steps(early.delivered) > RecordSyncer.steps(dose.value) {
            notIts = "the bolus was for \(dose.value) U"
        } else if !completeBolus(
            delivered: early.delivered,
            receivedAt: early.receivedAt,
            receivedUptime: early.receivedUptime,
            endedAt: early.receivedAt
        ) {
            notIts = "it came before the bolus went out"
        }

        guard let notIts else {
            log.info("The bolus of \(dose.startDate) completed before its answer came: \(early.delivered) U")
            return true
        }

        log.warning("The completion of \(early.delivered) U before the answer is not the bolus of \(dose.startDate)'s: \(notIts)")
        raiseCancelledBolus(delivered: early.delivered, record: early.record)
        return false
    }

    /// The bolus a cancel ended moments ago, still waiting on its record - its completion is yet to come
    private func recentlyCancelledBolus() -> UnfinalizedDose? {
        let cutoff = Date.now.addingTimeInterval(-Self.cancelledBolusCompletionWindow)
        return state.awaitingRecord.last(where: { dose in
            let snapshot = dose.snapshot
            return dose.type == .bolus && snapshot.finishReason == .cancelled && !snapshot.isFinalized &&
                (snapshot.finishedAt ?? .distantPast) > cutoff
        })
    }

    /// A completion notification with no bolus running to take it, naming `record` as the newest if it does: the
    /// patch's completion of the bolus a cancel just ended, with what it really delivered. Raises the amount the cancel
    /// kept, never lowers it. One whose command went unanswered is confirmed by it - counted as that, no longer in full -
    /// only if it is provably its: it names a record past every one known or claimed when it went out, no earlier bolus's
    /// answer claimed, and no other bolus is out to be its (`isCompletion`, for one not yet answered). Its warning of
    /// uncertain delivery stands; its record settles it.
    internal func raiseCancelledBolus(delivered: Double, record: Int? = nil) {
        doseReportLock.withLock {
            guard let cancelled = recentlyCancelledBolus() else {
                return
            }

            // Logged whatever it says, 0 U included: what the patch itself says the cancelled bolus delivered
            let ended = cancelled.snapshot
            let kept = ended.deliveredUnits
            let isItsOwn = ended.confirmation == .uncertain && state.pendingBolus == nil && isNumberedOnThisPatch(ended) &&
                record.map { record in
                    record > ended.sequenceAtSend ?? .max && !state.answeredBolusRecords.contains(record)
                } == true
            let changed = isItsOwn ? cancelled.confirmAfterEnd(delivered: delivered) : cancelled.raiseAfterEnd(to: delivered)
            log.info(
                "Completion of \(delivered) U after the cancel of the bolus of \(cancelled.startDate), record " +
                    "\(ended.recordSequence.map { "#\($0)" } ?? "-"): " +
                    (cancelled.deliveredUnits > kept ? "raising its amount from \(kept) U" : "keeping its \(kept) U") +
                    (isItsOwn ? " - it names #\(record ?? 0), its own: its command unanswered, counted as that, not in " +
                        "full, until its record" : "")
            )
            guard changed else {
                return
            }
            // A temp basal's records being read: their batch carries it, waiting on its record
            emitPumpEvents([], unlessTempBasalEndPending: true)
        }
    }

    /// The completion the patch sends after a cancel comes within a second or so
    private static let cancelledBolusCompletionWindow: TimeInterval = .minutes(2)

    /// A full status received at `receivedAt` that shows no bolus delivering - its bolus field the last one's, completed,
    /// having delivered `delivered` - and names `newestRecord` the newest record written. Past the record the answer to
    /// the running bolus gave it, the patch wrote that record: the bolus is over, and the last one completed is it. Its
    /// completion notification was lost - the link dropped: it ends here, at that amount, how it ended unseen, rather
    /// than at its deadline, refusing commands until then. Its record, read by the sync, finalizes it. Only for a bolus
    /// with that number: the bolus field carries none of its own, and repeats the last bolus's for hours. Returns whether
    /// it ended it.
    @discardableResult internal func completeBolusByItsRecord(
        delivered: Double,
        newestRecord: Int,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> Bool {
        let completed = doseReportLock.withLock { () -> Bool in
            guard let doseEntry = state.bolusDose else {
                return false
            }

            let running = doseEntry.snapshot
            guard !running.isFinished, let recordSequence = running.recordSequence, newestRecord >= recordSequence,
                  !Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime)
            else {
                return false
            }

            guard RecordSyncer.steps(delivered) <= RecordSyncer.steps(doseEntry.value) else {
                log.warning(
                    "A full status names record #\(newestRecord), past the bolus of \(doseEntry.startDate)'s #\(recordSequence), " +
                        "and a bolus of \(delivered) U completed - more than it was for: left to its deadline"
                )
                return false
            }

            log.warning(
                "A full status names record #\(newestRecord): the bolus of \(doseEntry.startDate), #\(recordSequence), is " +
                    "over, its completion not seen - \(delivered) U, as the status says, until its record"
            )
            var events = runningTempBasal()
            events.append(contentsOf: awaitRecord(doseEntry, .completed, deliveredUnits: delivered, endedAt: nil))
            endBolusStallWatch(
                doseEntry,
                delivered: doseEntry.deliveredUnits,
                receivedAt: receivedAt,
                receivedUptime: receivedUptime,
                "its completion not seen, its record written"
            )
            state.bolusDose = nil
            state.lastSync = Date.now
            emitBolusEvents(events)
            return true
        }

        if completed {
            notifyStateDidChange()
        }
        return completed
    }

    /// A full status received at `receivedAt`, past the running bolus's deadline: it is over, and we never saw how it
    /// ended - the link was lost. Counted in full until its record says otherwise.
    internal func checkBolusDone(receivedAt: Date, receivedUptime: TimeInterval) {
        let ended = doseReportLock.withLock { () -> UnfinalizedDose.State? in
            guard let doseEntry = state.bolusDose else {
                return nil
            }

            let running = doseEntry.snapshot
            guard !running.isFinished, now() >= doseEntry.deliveryDeadline(of: running),
                  !Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime)
            else {
                return nil
            }

            var events = runningTempBasal()
            events.append(contentsOf: awaitRecord(doseEntry, .completionNotSeen, endedAt: nil))
            // How it ended is not known: a stall's warning stands
            endBolusStallWatch(
                doseEntry,
                delivered: doseEntry.deliveredUnits,
                receivedAt: receivedAt,
                receivedUptime: receivedUptime,
                "past its deadline",
                endSeen: false
            )
            // The released driver's, in flight as the app was upgraded: its record is among those it wrote before, read
            // next - uncertain only if it is not found (`finalizeFromEstimate`)
            if !Self.isReleasedDriversBolus(doseEntry, running) {
                noteUncertainDelivery(.bolus, .endNotSeen, of: doseEntry)
            }
            state.bolusDose = nil
            state.lastSync = Date.now
            emitBolusEvents(events)
            return running
        }

        guard let ended else {
            return
        }

        if ended.sequenceAtSend == nil {
            log.warning(
                "The bolus the released driver had in flight ended unseen, last reported \(ended.deliveredUnits) U: counted " +
                    "in full until its record says otherwise - uncertain only if it is not found"
            )
            notifyStateDidChange()
            return
        } else if ended.confirmation == .uncertain {
            log.warning(
                "The bolus whose command went unanswered is past its deadline, last reported \(ended.deliveredUnits) U: " +
                    "counted in full until its record says otherwise"
            )
        } else {
            log.warning("Bolus ended unseen... last reported \(ended.deliveredUnits) U, counted in full until its record")
        }

        notifyStateDidChange()

        // One whose command went unanswered was warned of then
        guard ended.confirmation == .confirmed else {
            return
        }

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
        }
    }

    /// Tells the host that `dose` may or may not have been delivered - once, and saved with the state
    internal func warnOfUncertainBolus(_ dose: UnfinalizedDose) {
        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            guard dose.noteUncertaintyReported() else {
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
            self.notifyStateDidChange()
        }
    }

    /// In a new run's state, a SetBolus still pending went out and the app was gone before its answer: the patch may be
    /// delivering it. It runs from here on as a bolus whose command went unanswered does (`enactBolus`), dated from when
    /// it went out - its deadline and the window its record is looked for in count from then. Or it never went out: the
    /// host took the state too late for it to be written, and the app was gone before it took the next (`handOverState`)
    /// - the same state on disk. Its records tell: none its, it is final at 0 U (`unansweredBolusNeverRan`); if they
    /// can't, counted in full - never less than may have been delivered. Not if its dose was
    /// registered: the state was saved as it was, read in part before. The host is told of it, and warned, as soon as it
    /// can be - and so of one whose command went unanswered in the last run that it was never warned of
    /// (`reportBolusFromLastRun`).
    /// With no session running it went out as the session ended under it - a forced deactivation, from the main queue -
    /// to the old patch, still on the body: no command goes out with none (`ensureConnectedAndActive`). Nothing of that
    /// patch is taken from here on, and its record numbers are not the next patch's (`isNumberedOnThisPatch`): final at
    /// once in full, as one whose answer came after the end is (`finalizeBolusOfEndedSession`) - never running, holding
    /// up the next patch's boluses, or carried into its session. So is any bolus not final an earlier build left with no
    /// session (`finalizeBolusesLeftByTheEndedSession`). The host is warned, and the user told, as soon as there is a host
    /// (`reportBolusFromLastRun`).
    internal func takeOverPendingBolus() {
        doseReportLock.withLock {
            if let pending = state.pendingBolus {
                state.pendingBolus = nil

                let registered = ([state.bolusDose].compactMap { $0 } + state.awaitingRecord).contains { dose in
                    dose.type == .bolus && dose.sentAt == pending.sentAt
                }
                if registered {
                    log.info("The bolus of \(pending.units) U sent at \(pending.sentAt) was registered already")
                } else if let running = state.bolusDose {
                    log.error(
                        "The bolus of \(pending.units) U sent at \(pending.sentAt) is pending, with the bolus of " +
                            "\(running.startDate) running - keeping that one"
                    )
                } else {
                    let dose = UnfinalizedDose(
                        units: pending.units,
                        duration: estimatedDuration(toBolus: pending.units),
                        activationType: pending.automatic ? .automatic : .manualNoRecommendation,
                        insulinType: state.insulinType,
                        confirmation: .uncertain,
                        startDate: pending.sentAt
                    )
                    dose.noteCommand(
                        sentAt: pending.sentAt,
                        uptime: nil,
                        sequence: pending.sequenceAtSend,
                        patchId: pending.sequencePatchId
                    )

                    if state.patchSessionEnded {
                        log.error(
                            "The app stopped while the bolus of \(pending.units) U sent at \(pending.sentAt) awaited its " +
                                "answer, as the patch session ended: sent to the old patch, it is final in full"
                        )
                        // Its final goes out with every batch until the host has it; told and warned once there is a host
                        _ = finalizeBolusOfEndedSession(dose, unanswered: true)
                    } else {
                        // Answered, the state saved before its dose was registered: its answer, kept for its record, is
                        // the one past `sequenceAtSend` - every number claimed before it went out is at or below that,
                        // and commands go one at a time. The latest, should there be more.
                        if let answered = state.answeredBolusRecords.last(where: { $0 > pending.sequenceAtSend }) {
                            dose.noteAnswer(recordSequence: answered)
                            log.info("The bolus of \(pending.units) U sent at \(pending.sentAt) was answered as record #\(answered)")
                        }

                        state.bolusDose = dose
                        noteUncertainDelivery(.bolus, .appRestarted, of: dose)
                        log.error(
                            "The app stopped while the bolus of \(pending.units) U sent at \(pending.sentAt) awaited its " +
                                "answer, or before the host took the state for it to be written: it may be delivering. " +
                                "Counted in full until the patch shows it, or its record says otherwise - not sent again"
                        )
                    }
                }
            }

            // With no session, one an earlier build left: nothing of its patch is taken any more
            if state.patchSessionEnded {
                _ = finalizeBolusesLeftByTheEndedSession()
            }

            if let bolus = state.bolusDose {
                let running = bolus.snapshot
                if running.confirmation == .uncertain, !running.isFinished, !running.uncertaintyReported {
                    bolusFromLastRun = bolus
                }
            }
        }
    }

    /// Reports `bolusFromLastRun` running, counted in full, and warns the host of it - once there is a host to tell:
    /// on the loop's first sync or the first status of this run, whichever comes first. From then on it is the running
    /// bolus, reported as any.
    internal func reportBolusFromLastRun() {
        guard pumpDelegate.delegate != nil else {
            return
        }

        // Final in full as its session ended, the user not told yet - taken over as this run started, or a run killed
        // before it told: its final out now - with no session no batch may come for long - the host warned, the user
        // told. Saved with each (`UnfinalizedDose.State.sessionEndAlertPending`), it is here until the host has the final.
        doseReportLock.withLock {
            let counted = bolusesCountedAtSessionEndUntold
            guard !counted.isEmpty else {
                return
            }
            emitPumpEvents([], replacePendingEvents: false, unlessTempBasalEndPending: true)
            for dose in counted {
                warnOfBolusCountedAtSessionEnd(dose)
            }
        }

        let dose = doseReportLock.withLock { () -> UnfinalizedDose? in
            guard let dose = bolusFromLastRun else {
                return nil
            }
            bolusFromLastRun = nil

            let running = dose.snapshot
            // A temp basal restored waiting on its read (`takeOverTempBasalEndFromLastRun`) goes out with it from our
            // estimate, unread: with this bolus running, its records are not read before it is over (`RecordSyncer
            // .wouldRead`) - and the host is to be warned of the bolus now, needing no link
            if state.bolusDose === dose, !running.isFinished {
                emitPumpEvents([NewPumpEvent.bolus(dose: dose.doseEntry(of: running, isMutable: true))], replacePendingEvents: false)
            }
            // The app gone before it was noted, or by a build that did not note it
            noteUncertainDelivery(.bolus, .unanswered, of: dose)
            return dose
        }

        guard let dose else {
            return
        }

        notifyStateDidChange()
        warnOfUncertainBolus(dose)
    }

    /// The boluses final in full as their session ended that the user is yet to be told of - see
    /// `UnfinalizedDose.State.sessionEndAlertPending`. Only under `doseReportLock`.
    internal var bolusesCountedAtSessionEndUntold: [UnfinalizedDose] {
        state.awaitingRecord.filter { $0.type == .bolus && $0.isFinalized && $0.snapshot.sessionEndAlertPending }
    }

    /// The running bolus, as its session ends: final at once, its record out of reach from here on. `countsInFull`: the
    /// patch may deliver it still - a forced end, the old patch on the body, nothing of it taken from here on - so at the
    /// amount programmed, never less than it delivered: uncertain, the host warned and the user told
    /// (`finalizeInFullAtSessionEnd`). Otherwise delivery stopped with the session - the StopPatch answered, or the base
    /// reset under it - at the last amount reported. Only under `doseReportLock`.
    internal func finalizeInterruptedBolus(countsInFull: Bool = false) -> [NewPumpEvent] {
        guard let doseEntry = state.bolusDose else {
            return []
        }

        log.warning(
            "Patch session ended during a bolus... \(doseEntry.deliveredUnits) U of the \(doseEntry.value) U" +
                (countsInFull ? " - forced: its patch may deliver it still, it is final in full" : "")
        )

        // The session's end retracts a stall's warning (`endPatchSession`, `startPatchSession`)
        endBolusStallWatch(
            doseEntry,
            delivered: doseEntry.deliveredUnits,
            receivedAt: now(),
            receivedUptime: uptime(),
            "its patch session ended",
            endSeen: false
        )
        state.bolusDose = nil

        if countsInFull {
            guard let event = finalizeInFullAtSessionEnd(doseEntry) else {
                return []
            }
            warnOfBolusCountedAtSessionEnd(doseEntry)
            return [event]
        }

        // Final at once: its record can no longer be read. At the last amount reported - one the patch never
        // confirmed counts in full.
        guard doseEntry.finish(.interrupted, endedAt: nil, at: now()) else {
            return []
        }
        noteUncertainDelivery(.bolus, .patchDeactivated, of: doseEntry)
        guard let event = finalize(doseEntry, deliveredUnits: nil, .byEstimate) else {
            return []
        }

        // One whose command went unanswered was warned of then
        if doseEntry.confirmation == .confirmed {
            pumpDelegate.notify { delegate in
                guard let delegate = delegate else {
                    self.log.warning("No pump delegate, not notifying...")
                    return
                }

                delegate.pumpManager(self, didError: .uncertainDelivery)
            }
        }

        return [event]
    }
}

import LoopKit

public extension MedtrumPumpManager {
    func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    func notifyStateDidChange() {
        refreshLogDeviceIdentifier()
        readTempBasalEndAfterBolus()
        readOpenTempBasalEndsAfterBolus()

        // synchronously, on the path that mutated the bolus dose
        for reporter in bolusProgressReporters.value {
            reporter.update()
        }

        DispatchQueue.main.async {
            let status = self.status(self.state)
            let oldStatus = self.status(self.oldState)

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManagerDidUpdateState(self)
                delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            self.statusObservers.forEach { observer in
                observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            // Not `rawState`: that is the host's read
            self.oldState = MedtrumPumpState(rawValue: self.doseReportLock.withLock { self.state.rawValue })
        }
    }

    internal func emitAlert(alertType: MedtrumAlert) {
        pumpDelegate.notify { delegate in
            delegate?.issueAlert(alertType.alert)

            if let pumpEvent = NewPumpEvent.alert(type: alertType) {
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: [pumpEvent],
                    lastReconciliation: self.state.lastSync,
                    replacePendingEvents: false,
                    completion: { error in
                        if let error = error {
                            self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                        }
                    }
                )
            }
        }
    }

    /// The current temp basal (if any), reported as still running
    internal func runningTempBasal() -> [NewPumpEvent] {
        let dose = state.basalDose
        let running = dose.snapshot
        guard dose.type == .tempBasal, !running.isFinished else {
            return []
        }

        return [NewPumpEvent.tempBasal(dose: dose.doseEntry(of: running, isMutable: true))]
    }

    /// The current temp basal (if any), finalized at once from our estimate as having stopped at `endedAt` - for the end
    /// of a patch session, when its records can no longer be read. Only under `doseReportLock`; the caller emits it.
    internal func finalizedTempBasal(endedAt: Date) -> [NewPumpEvent] {
        let dose = state.basalDose
        guard dose.type == .tempBasal, dose.finish(.interrupted, endedAt: endedAt, at: now()) else {
            return []
        }

        return openTempBasalEndsFromEstimate(because: "the patch session ended") +
            (estimateFinal(dose, because: "the patch session ended").map { [$0] } ?? [])
    }

    /// The current temp basal (if any) stopped at `endedAt`, finalized at once from our estimate - where its records
    /// cannot be read on the way: a status showing the temp basal whose command went unanswered ran. The caller
    /// replaces `state.basalDose` and emits. Only under `doseReportLock`.
    internal func endTempBasalFromEstimate(endedAt: Date, because reason: String) -> [NewPumpEvent] {
        let dose = state.basalDose
        guard dose.type == .tempBasal,
              dose.finish(endedAt >= dose.estimatedEndDate ? .completed : .cancelled, endedAt: endedAt, at: now())
        else {
            return []
        }

        return openTempBasalEndsFromEstimate(because: reason) + (estimateFinal(dose, because: reason).map { [$0] } ?? [])
    }

    func emitReservoirLevel() {
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(
                self,
                didReadReservoirValue: self.state.reservoir.rounded(toPlaces: 1),
                at: Date.now
            ) { result in
                switch result {
                case let .failure(error):
                    self.handlePumpDelegateError(method: "didReadReservoirValue", error)
                case .success:
                    break
                }
            }
        }
    }

    /// `events`, a bolus's end - with the temp basal running, if any - handed to the host: with a temp basal's records
    /// read as it ended (`TempBasalEnd`), in the batch that read ends with, after what followed it, rather than taking
    /// it out from our estimate now. Its records are read once no bolus runs (`RecordSyncer.wouldRead`): this one over,
    /// nothing holds them up any longer - the halt and the completion in one status (device 2026-10-22 20:18:59), a
    /// cancel of the bolus, a full status that ends it. Loop's watermark goes by basal doses only (`LoopWatermark`):
    /// the bolus waits no longer than the read, and nothing is lost meanwhile - it waits on its record, and every
    /// replacing batch carries it. Only under `doseReportLock`.
    internal func emitBolusEvents(_ events: [NewPumpEvent]) {
        guard let ending = pendingTempBasalEndStorage else {
            emitPumpEvents(events)
            return
        }
        log.info("Reporting the bolus with the temp basal of \(ending.dose.startDate), once its records are read")
        // Finals only, the same every time. A mutable report held would be stale by then - the patch's completion after
        // a cancel raises the bolus meanwhile - and win over the dose as it is: the batch the read ends with replaces
        // pending events, every dose still in flight in it from what it is then.
        ending.bolusReports += events.filter { $0.dose?.isMutable == false }
    }

    /// Hands `events` to the host, with every final it has yet to confirm and - with `replacePendingEvents` - every dose
    /// still mutable: the host drops every mutable dose it holds that a replacing batch leaves out.
    ///
    /// Every batch has the state saved first, in the same delegate call: otherwise the host could store it and the app
    /// be killed before the state is saved - a final would come back unfinalized, and a dose the host holds mutable
    /// would be unknown to the restored state and purged by its next replacing batch.
    ///
    /// A temp basal goes out mutable once it ended only as one ended open, the next one starting where it ended (see
    /// `openTempBasalEnds`): the host moves past one as soon as anything immutable after it is stored, and its final would
    /// be lost. One whose records are being read as it ends goes out final from our estimate, with what followed it, and
    /// every one ended open before it - see `TempBasalEnd`. So does one waiting on its record in state saved as such a
    /// read went on that is not read again (`takeOverTempBasalEndFromLastRun`), or by an earlier build, with those ended
    /// open before it.
    ///
    /// `unlessTempBasalEndPending`: a batch with no events of its own - a full status's, a resend of finals, a raised
    /// cancelled bolus - is not handed over at all while such records are read. The batch the read ends with replaces
    /// pending events, carrying every final and every dose still in flight, and the temp basal final from its records
    /// rather than from our estimate. Temp basals ended open hold up nothing: a batch carries them mutable. Nor does a
    /// bolus's end go out ahead of that read - see `emitBolusEvents`.
    func emitPumpEvents(_ events: [NewPumpEvent], replacePendingEvents: Bool = true, unlessTempBasalEndPending: Bool = false) {
        // The batch is built off `awaitingRecord` and handed to the delegate queue in one go - see `doseReportLock`
        doseReportLock.lock()
        defer { doseReportLock.unlock() }

        if unlessTempBasalEndPending, events.isEmpty, let ending = pendingTempBasalEndStorage {
            log.debug("Not reporting a refresh while the records of the temp basal of \(ending.dose.startDate) are read")
            return
        }

        // Temp basals ended open that their rules settle now - read past, past `openTempBasalEndMaximumWait` - go final
        // with any batch, not only a record sync's
        var events = settleOpenTempBasalEnds() + events
        if let ending = pendingTempBasalEndStorage {
            pendingTempBasalEndStorage = nil
            // Those ended open before it first - see `finalize`
            let reason = "a batch went out before its records were read"
            let finals = openTempBasalEndsFromEstimate(because: reason) + [estimateFinal(ending.dose, because: reason)].compactMap { $0 }
            events = finals + ending.then + ending.bolusReports + events
        }
        // Waiting on its record, none of the above, nor ended open: saved as its records were read and not to be read
        // again - see `takeOverTempBasalEndFromLastRun` - or by an earlier build
        var fromLastRun: [NewPumpEvent] = []
        let unread = state.awaitingRecord.filter { dose in
            let snapshot = dose.snapshot
            return dose.type == .tempBasal && !snapshot.isFinalized && !snapshot.endedOpen
        }.sorted { $0.startDate < $1.startDate }
        for dose in unread {
            if let final = estimateFinal(dose, because: "it was saved waiting on its record") {
                fromLastRun.append(final)
            }
        }
        // What followed a temp basal whose records were being read, the host yet to confirm storing it - in this batch
        // with that temp basal's final, if it carried it out just now; else held back as the run before ended, or by a
        // batch the host could not store: after that final - which goes out again with it, until the host confirms
        // both. Its final went out first: no batch goes out while those records are read without carrying it. So too
        // every suspend and resume reported, until the host confirms storing it (`keepUntilStored`): ahead of what this
        // batch reports, in the order they came.
        dropExpiredFinals()
        // Not the suspend held back until the records of the temp basal whose command went unanswered are read
        let held = keptBasalDoses
        let inThisBatch = Set(events.map(\.raw))
        let heldBefore = held.compactMap { dose in Self.heldEvent(of: dose).map { (dose: dose, event: $0) } }
            .filter { !inThisBatch.contains($0.event.raw) }
        // Again as the batch that carried it awaits its answer, as a matter of course; again after one the host could not
        // store, or from the run before - worth a warning
        let resent = heldBefore.filter { held in !heldInFlight.contains { $0 === held.dose } }
        let describe = { (held: [(dose: UnfinalizedDose, event: NewPumpEvent)]) in
            held.map { "\($0.event.title) at \($0.event.date)" }.joined(separator: ", ")
        }
        if !resent.isEmpty {
            log.warning("Reporting again what the host has yet to confirm storing: \(describe(resent))")
        } else if !heldBefore.isEmpty {
            log.debug("Reporting with this batch what the host has yet to confirm storing: \(describe(heldBefore))")
        }
        heldInFlight += held.filter { dose in !heldInFlight.contains { $0 === dose } }
        events = fromLastRun + heldBefore.map(\.event) + events
        // Each dose read once, and with it whether it has a final - which can't appear meanwhile, see `finalize`
        let snapshots = state.awaitingRecord.map { (dose: $0, snapshot: $0.snapshot) }
        let finals = snapshots.filter(\.snapshot.isFinalized).map(\.dose)
        let finalEvents = snapshots.compactMap { $0.dose.fixedFinalEvent(of: $0.snapshot) }
        let finalized = Set(finalEvents.map(\.raw)).union(finalizedIdentities.keys)

        // A mutable report of a dose finalized since the caller built it: it would change a finalized dose after all
        events = events.filter { event in
            guard event.dose?.isMutable == true, finalized.contains(event.raw) else {
                return true
            }

            log.warning("Dropping a mutable report of the \(event.title) of \(event.date), it is finalized already")
            return false
        }

        var identities = Set(events.map(\.raw))
        func appendIfMissing(_ event: NewPumpEvent) {
            guard identities.insert(event.raw).inserted else {
                return
            }
            events.append(event)
        }

        // Finals the host has yet to confirm go out with every batch until it does, the same final every time
        finalEvents.forEach(appendIfMissing)

        // With `replacePendingEvents` the host drops every mutable dose it holds. Anything still in flight has to be in
        // here: the running bolus and temp basal, and every dose still waiting on its record.
        if replacePendingEvents {
            if let bolusDose = state.bolusDose {
                let bolus = bolusDose.snapshot
                if !bolus.isFinished {
                    appendIfMissing(NewPumpEvent.bolus(dose: bolusDose.doseEntry(of: bolus, isMutable: true)))
                }
            }

            runningTempBasal().forEach(appendIfMissing)

            for (dose, snapshot) in snapshots where !snapshot.isFinalized {
                if let event = NewPumpEvent.finishedDose(dose, entry: dose.doseEntry(of: snapshot, isMutable: true)) {
                    appendIfMissing(event)
                }
            }
        }

        if !finals.isEmpty || !held.isEmpty {
            lastFinalsSentAt = Date.now
        }

        recordStore.store(emitted: events.compactMap(EmittedDose.init))

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                // The finals stay, and go out with the next batch
                self.log.warning("No pump delegate, not notifying...")
                self.notInFlight(held)
                return
            }

            delegate.pumpManagerDidUpdateState(self)

            // A final in full as its session ended, the user yet to be told of it - with no host as it was fixed - is told
            // of as it goes out: once the host stores it, the dose is gone, and the note with it
            for dose in finals {
                self.warnOfBolusCountedAtSessionEnd(dose)
            }

            delegate.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: replacePendingEvents
            ) { error in
                if let error = error {
                    // The finals stay, and go out with the next batch
                    self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                    self.notInFlight(held)
                    return
                }

                // Stored: what the host does with it moves Loop's watermark
                self.doseReportLock.withLock {
                    self.loopWatermarkModel.store(events, replacePendingEvents: replacePendingEvents)
                    self.state.loopWatermark = self.loopWatermarkModel.date
                }
                self.acknowledgeHeld(held)
                self.acknowledgeFinals(finals)
            }
        }
    }

    /// For a change of the running basal that goes with ending a temp basal - see `beginTempBasalEnd`
    internal func withDoseReportLock<T>(_ body: () -> T) -> T {
        doseReportLock.withLock(body)
    }

    /// A bolus stopped running: from now on it waits for its record, and is reported as mutable until then. Returns
    /// that interim report - nothing, if the dose has been finalized already. The dose object itself moves over, so a
    /// progress reporter holding it sees it finished.
    internal func awaitRecord(
        _ dose: UnfinalizedDose,
        _ reason: UnfinalizedDose.FinishReason,
        deliveredUnits: Double? = nil,
        endedAt: Date?
    ) -> [NewPumpEvent] {
        doseReportLock.withLock { () -> [NewPumpEvent] in
            let endedNow = dose.finish(reason, deliveredUnits: deliveredUnits, endedAt: endedAt, at: now())
            let ended = dose.snapshot

            guard !ended.isFinalized else {
                log.warning("The \(dose.type.rawValue) of \(dose.startDate) is finalized already, not awaiting its record")
                return []
            }

            if endedNow {
                log.info(
                    "\(dose.type.rawValue) of \(dose.startDate) \(reason.rawValue), awaiting its record - " +
                        "delivered \(ended.deliveredUnits) U, ended \(endedAt.map { "\($0)" } ?? "unseen"), " +
                        "record \(ended.recordSequence.map { "#\($0)" } ?? "-"), patch start \(ended.pumpStartTime.map { "\($0)" } ?? "-")"
                )
            } else {
                log.info(
                    "\(dose.type.rawValue) of \(dose.startDate) \(reason.rawValue), but it ended already " +
                        "(\(ended.finishReason?.rawValue ?? "-")) - keeping that end, delivered \(ended.deliveredUnits) U"
                )
            }

            state.mutateAwaitingRecord { doses in
                guard !doses.contains(where: { $0 === dose }) else {
                    return
                }
                doses.append(dose)
            }

            return NewPumpEvent.finishedDose(dose, entry: dose.doseEntry(of: ended, isMutable: true)).map { [$0] } ?? []
        }
    }

    /// Fixes the final report of `dose` - once: nil if it has one already - and keeps it in `awaitingRecord`, to go out
    /// with every batch until the host confirms storing it. Only under `doseReportLock`; the caller hands the final
    /// over before letting go of it. `deliveredUnits`: the record's amount, or nil for our own estimate. `outcome`: how,
    /// for the uncertain deliveries of it. `atSessionEnd`: a bolus final in full as its patch session ended
    /// (`finalizeInFullAtSessionEnd`) - not one of this patch's finals without their record: its record is never read,
    /// and the numbers it was noted with are the old patch's, whatever the next one's records are numbered. No record is
    /// looked at for it, now or later.
    internal func finalize(
        _ dose: UnfinalizedDose,
        deliveredUnits: Double?,
        endDate: Date? = nil,
        _ outcome: UncertainDelivery.Outcome,
        atSessionEnd: Bool = false
    ) -> NewPumpEvent? {
        // Basal doses go final in order: a temp basal ended open before this one goes final first, from our estimate if
        // nothing settled it yet - its final goes out with this one's, as every final the host has yet to confirm
        if dose.type == .tempBasal, !dose.isFinalized {
            for earlier in openTempBasalEnds where earlier !== dose && earlier.startDate < dose.startDate {
                estimateFinal(earlier, because: "the temp basal of \(dose.startDate) after it goes final")
            }
        }

        guard dose.finalize(deliveredUnits: deliveredUnits, endDate: endDate, at: now()) else {
            log.warning("The \(dose.type.rawValue) of \(dose.startDate) is finalized already, not reporting it again")
            return nil
        }

        settleUncertainDeliveries(of: dose, outcome)

        if dose.type == .bolus {
            let final = dose.snapshot
            // The released driver's, final: the record kept for it from the backlog is history, whichever way it went
            if Self.isReleasedDriversBolus(dose, final) {
                state.releasedBolusBacklogRecord = nil
            }
            // Final in full as its session ended: no record of its patch is read from here on, and the next patch's -
            // numbered afresh - are none of its, kept or to come
            if !atSessionEnd {
                let taken = settlePossibleBolusRecords(after: dose, outcome)
                // Its record may come after all, matching no dose then: it is this one's. Kept with a possible record
                // taken for its own all the same, with it: that one may have been another bolus's, at its amount - its
                // own still to come, telling of it (`explain`).
                if outcome == .byEstimate, let sentAt = final.sentAt {
                    state.bolusesFinalWithoutRecord = Array(
                        (state.bolusesFinalWithoutRecord + [
                            BolusFinalWithoutRecord(
                                units: dose.value,
                                delivered: final.finalDeliveredUnits ?? dose.value,
                                sentAt: sentAt,
                                pumpStartTime: final.pumpStartTime,
                                recordSequence: final.recordSequence,
                                taken: taken,
                                datedByItsAnswer: Self.isReleasedDriversBolus(dose, final)
                            )
                        ]).suffix(Self.bolusesFinalWithoutRecordKept)
                    )
                }
            }
        }

        state.mutateAwaitingRecord { doses in
            guard !doses.contains(where: { $0 === dose }) else {
                return
            }
            doses.append(dose)
        }

        guard let event = dose.finalEvent else {
            return nil
        }

        finalizedIdentities = finalizedIdentities.filter { Date.now.timeIntervalSince($0.value) < Self.finalizedIdentityRetention }
        finalizedIdentities[event.raw] = Date.now
        return event
    }

    /// Finalizes `dose`, a bolus, and hands the final to the host at once - behind the records of a temp basal read as it
    /// ended, if any are, as a bolus's end (`emitBolusEvents`): one read on a record sync as a status ends it, say. Only
    /// under `doseReportLock`.
    internal func emitFinal(_ dose: UnfinalizedDose, deliveredUnits: Double, endDate: Date? = nil) {
        guard let event = finalize(dose, deliveredUnits: deliveredUnits, endDate: endDate, .byRecord) else {
            return
        }
        emitBolusEvents([event])
    }

    /// The host stored a batch: the finals it carried need not go out again
    private func acknowledgeFinals(_ finals: [UnfinalizedDose]) {
        guard !finals.isEmpty else {
            return
        }

        var acknowledged = 0
        doseReportLock.withLock {
            state.mutateAwaitingRecord { doses in
                let before = doses.count
                doses.removeAll { dose in dose.isFinalized && finals.contains { $0 === dose } }
                acknowledged = before - doses.count
            }
        }

        guard acknowledged > 0 else {
            return
        }

        log.info("The host stored \(acknowledged) final report(s), done with those doses")
        notifyStateDidChange()
    }

    /// A final the host has not confirmed in time to matter anymore, counted from when it was fixed
    internal static func isUnconfirmedFinalExpired(_ dose: UnfinalizedDose, now: Date = Date.now) -> Bool {
        let final = dose.snapshot
        guard let endDate = final.finalEndDate else {
            return false
        }
        return now.timeIntervalSince(final.finalizedAt ?? endDate) > unconfirmedFinalMaximumAge
    }

    /// Takes the expired finals off `awaitingRecord`. Only under `doseReportLock`.
    private func dropExpiredFinals() {
        let checkedAt = now()
        var expired: [UnfinalizedDose] = []

        state.mutateAwaitingRecord { doses in
            expired = doses.filter { Self.isUnconfirmedFinalExpired($0, now: checkedAt) }
            doses.removeAll { Self.isUnconfirmedFinalExpired($0, now: checkedAt) }
        }

        for dose in expired {
            log.error("The host never confirmed the final of the \(dose.type.rawValue) of \(dose.startDate), giving up on it")
        }

        // What was held back after a temp basal, the same - counted from when it was held - and never before that
        // temp basal's final: fixed from our estimate only after a restart, it may be newer. Kept while a temp basal
        // started before it waits on the host.
        let tempBasals = state.awaitingRecord.filter { $0.type == .tempBasal }
        let expiredHeld = state.heldBasalDoses.filter { held in
            checkedAt.timeIntervalSince(held.heldAt) > Self.unconfirmedFinalMaximumAge &&
                !tempBasals.contains { $0.startDate <= held.dose.startDate }
        }.map(\.dose)
        guard !expiredHeld.isEmpty else {
            return
        }
        state.heldBasalDoses.removeAll { held in expiredHeld.contains { $0 === held.dose } }
        heldInFlight.removeAll { dose in expiredHeld.contains { $0 === dose } }
        for dose in expiredHeld {
            log.error("The host never confirmed storing the \(dose.type.rawValue) of \(dose.startDate), giving up on it")
        }
    }

    /// Finals the host has not confirmed, and no batch has carried for a while - or suspends and resumes kept until it
    /// stores them (`keepUntilStored`), not those held for the records of the temp basal whose command went unanswered:
    /// after a restart, with the patch out of reach, they would wait for its first status. Only under `doseReportLock`.
    internal var isUnconfirmedFinalsResendDue: Bool {
        Date.now.timeIntervalSince(lastFinalsSentAt) >= Self.unconfirmedFinalsResendInterval &&
            (state.awaitingRecord.contains(where: \.isFinalized) || !keptBasalDoses.isEmpty)
    }

    /// The doses held back that go out with any batch: not those held for the records of the temp basal whose command
    /// went unanswered. Only under `doseReportLock`.
    private var keptBasalDoses: [UnfinalizedDose] {
        state.heldBasalDoses.map(\.dose).filter { dose in !heldForUnconfirmedRead.contains { $0 === dose } }
    }

    /// Sends the finals the host has yet to confirm again, if no batch carried them for a while. Needs neither the link
    /// nor a patch.
    internal func resendUnacknowledgedFinalsIfDue() {
        doseReportLock.withLock {
            // The temp basal restored waiting on its read, no status since the restart to read it on: not waited on
            // for good - its final goes out from our estimate, what was held behind it with it
            if let restored = tempBasalEndFromLastRun,
               now().timeIntervalSince(restored.restoredAt) >= Self.tempBasalEndFromLastRunLinkWait
            {
                giveUpOnTempBasalEndFromLastRun(restored.ending)
            }

            guard isUnconfirmedFinalsResendDue else {
                return
            }

            log.warning(
                "The host has not confirmed \(state.awaitingRecord.filter(\.isFinalized).count) final report(s) and " +
                    "\(keptBasalDoses.count) suspend(s) or resume(s), sending them again"
            )
            // A temp basal's records being read: their batch carries every final
            emitPumpEvents([], replacePendingEvents: false, unlessTempBasalEndPending: true)
        }
    }

    /// `next`, of a status - the resume the patch shows - follows the temp basal whose records are read as it ended, if
    /// any is: held back behind its final, as a command's is (`replaceRunningBasal`), rather than taking it out with our
    /// estimate. Returns whether it was. Only under `doseReportLock`.
    internal func holdBehindTempBasalEnd(_ next: (dose: UnfinalizedDose, event: NewPumpEvent)) -> Bool {
        guard let pending = pendingTempBasalEndStorage else {
            return false
        }
        hold(next, after: pending)
        return true
    }

    /// `next` follows the temp basal of `ending`, its report held back until that one's final goes out - and its dose
    /// saved until the host confirms storing it, unless it is a temp basal: see `MedtrumPumpState.heldBasalDoses`.
    /// Only under `doseReportLock`.
    internal func hold(_ next: (dose: UnfinalizedDose, event: NewPumpEvent), after ending: TempBasalEnd) {
        ending.then.append(next.event)
        // A temp basal is not saved here: killed before the final, the next run rebuilds `then` from `heldBasalDoses`
        // only (`takeOverTempBasalEndFromLastRun`) - a set held behind the read, a halt after it moving `basalDose` on,
        // is then reported by nothing. The read's budget at most of a temp basal, seconds on the patch: left so. Behind
        // an end waiting for its record the command names it first (`askForTheRecordOfTheWaitingEnd`) - held longer only
        // if that status does not come.
        guard next.dose.type != .tempBasal else {
            return
        }
        state.heldBasalDoses.append(HeldBasalDose(dose: next.dose, heldAt: now()))
    }

    /// `dose`, a suspend or a resume about to go out, is saved with the state until the host confirms storing a batch
    /// that carried it (`MedtrumPumpState.heldBasalDoses`) - every batch until then carries it again, in the order they
    /// came. Handed over once, it is lost to a kill between the state saved with its batch, which has it reported, and
    /// the host storing it - iAPS stores in a task of its own. A suspend lost, the resume after it - the next patch's,
    /// say - is one with none before it: iAPS takes the patch to have been suspended since before its history, and
    /// with `suspend_zeros_iob` zeroes every temp basal before the resume, and the scheduled basal from 8 h back. A
    /// resume lost leaves the suspend open: every temp basal after it zeroed. IOB far too low either way. Of another
    /// kind, nothing is kept. Only under `doseReportLock`.
    internal func keepUntilStored(_ dose: UnfinalizedDose) {
        guard dose.type == .suspend || dose.type == .resume, !state.heldBasalDoses.contains(where: { $0.dose === dose }) else {
            return
        }
        state.heldBasalDoses.append(HeldBasalDose(dose: dose, heldAt: now()))
    }

    /// The host stored a batch: the held back doses it carried need not go out again - as `acknowledgeFinals`
    private func acknowledgeHeld(_ held: [UnfinalizedDose]) {
        guard !held.isEmpty else {
            return
        }

        let acknowledged = doseReportLock.withLock { () -> Int in
            heldInFlight.removeAll { dose in held.contains { $0 === dose } }
            let before = state.heldBasalDoses.count
            state.heldBasalDoses.removeAll { heldDose in held.contains { $0 === heldDose.dose } }
            return before - state.heldBasalDoses.count
        }

        if acknowledged > 0 {
            notifyStateDidChange()
        }
    }

    /// A batch carrying `held` was not stored: going out again, they are sent again
    private func notInFlight(_ held: [UnfinalizedDose]) {
        guard !held.isEmpty else {
            return
        }
        doseReportLock.withLock {
            heldInFlight.removeAll { dose in held.contains { $0 === dose } }
        }
    }

    /// The report of a dose held back after a temp basal - see `MedtrumPumpState.heldBasalDoses` - as it was first built
    internal static func heldEvent(of dose: UnfinalizedDose) -> NewPumpEvent? {
        switch dose.type {
        case .suspend:
            return NewPumpEvent.suspend(dose: dose.toDoseEntry())
        case .resume:
            return NewPumpEvent.resume(dose: dose.toDoseEntry())
        case .basal:
            return NewPumpEvent.basal(dose: dose.toDoseEntry())
        case .bolus,
             .tempBasal:
            return nil
        }
    }

    /// Loop's watermark as the state was saved - see `MedtrumPumpState.loopWatermark` - or, saved before it was kept, as
    /// the finals the host has yet to confirm make it: the rest is not known
    internal func noteFinalsFromLastRun() {
        doseReportLock.withLock {
            if state.loopWatermark == nil {
                // A held suspend counts with its start: Loop has it from there, ended by what follows
                let finals = state.awaitingRecord.filter { $0.type == .tempBasal }.compactMap(\.finalEndDate)
                let suspends = state.heldBasalDoses.filter { $0.dose.type == .suspend }.map(\.dose.startDate)
                state.loopWatermark = (finals + suspends).max()
            }
            loopWatermarkModel = LoopWatermark(date: state.loopWatermark)
        }
    }
}

private extension EmittedDose {
    /// Events without a dose - alerts, patch replacement - carry no delivery and are skipped.
    init?(_ event: NewPumpEvent) {
        guard let dose = event.dose else {
            return nil
        }

        self.init(
            emittedAt: Date.now,
            kind: dose.type.rawValue.uppercased(),
            start: dose.startDate,
            end: dose.endDate,
            identity: dose.syncIdentifier ?? "-",
            isMutable: dose.isMutable,
            programmed: dose.programmedUnits,
            delivered: dose.deliveredUnits
        )
    }
}

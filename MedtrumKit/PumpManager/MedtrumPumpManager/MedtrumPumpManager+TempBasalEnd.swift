import LoopKit

public extension MedtrumPumpManager {
    /// `record` is of a part of the temp basal still running: of this patch, at its rate, starting on its patch start
    /// or where the part kept before it ended. The patch wrote it as it restarted the segment - at patch-local midnight,
    /// on a profile change made elsewhere - or ended it unseen so far: its end, once seen, has to meet the last part.
    /// Kept on the dose, to be summed with the parts read as it ends (`tempBasalParts`); nothing is reported. Only under
    /// `doseReportLock`.
    internal func keepPartOfRunningTempBasal(_ record: BasalRecord, response: GetRecordResponse) -> String? {
        let dose = state.basalDose
        let running = dose.snapshot
        let tolerance = RecordSyncer.tempBasalStartTolerance
        guard dose.type == .tempBasal, !running.isFinished, !running.recordMatchDisabled,
              let pumpStartTime = running.pumpStartTime,
              RecordSyncer.isSamePatch(response.patchId, state.patchId.toUInt64()),
              RecordSyncer.steps(record.rate) == RecordSyncer.steps(dose.value)
        else {
            return nil
        }

        if running.recordedParts.contains(where: { $0.sequence == response.sequence }) {
            log.info("Record \(response.sequence) is a part of the running temp basal of \(dose.startDate), kept already")
            return "part of running temp basal \(dose.startDate)"
        }

        let partStart = running.recordedParts.last?.end ?? pumpStartTime
        guard abs(record.startTime.timeIntervalSince(partStart)) <= tolerance, record.endTime > record.startTime else {
            return nil
        }

        let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
        let part = UnfinalizedDose.RecordedPart(
            sequence: response.sequence,
            patchId: response.patchId & 0xFFFF,
            start: record.startTime,
            end: record.endTime,
            delivered: record.delivered
        )
        guard dose.keepRecordedPart(part) else {
            return nil
        }

        log.info(
            "Record \(response.sequence) is a part of the running temp basal of \(dose.startDate), from \(record.startTime) " +
                "to \(record.endTime)\(Self.isPatchMidnight(record.endTime, utcOffset: utcOffset) ? " (patch-local midnight)" : ""), " +
                "delivered \(record.delivered) U: kept, to be summed with the rest as it ends"
        )
        return "part of running temp basal \(dose.startDate)"
    }

    // MARK: - Temp basal ends

    /// A temp basal of ours that ended, and what followed it. The patch writes its record as it ends - a record per
    /// part, where it restarted it at patch-local midnight or on a profile change - and names the last: the answer to
    /// the cancel, the record number a status of the scheduled basal or of a suspend shows. Read right away, they make
    /// its final (`RecordSyncer.finishTempBasalEnd`), and the two go out in one batch: the host takes basal doses as final in
    /// order, and moves past a temp basal still mutable as soon as anything after it is stored - its final would be
    /// lost. A batch going out before that carries them out with our estimate (`emitPumpEvents`). Every temp basal ended
    /// open before it (`openTempBasalEnds`) goes final with it. A temp basal a new one replaced back to back is not one of
    /// these: it ends open itself.
    final class TempBasalEnd {
        let dose: UnfinalizedDose
        /// Where its last record ends, on the patch clock: where the segment after it started
        let patchEnd: Date?
        /// The number of its last record - named by a status after the one that ended it, where that one named none
        /// (`awaitsRecord`)
        var lastRecord: Int? {
            named.value.lastRecord
        }

        /// Ended by a status that named no record - a halt's, cut short (device 2026-10-26 10:08:55): the newest record
        /// the next status names is its last, the patch writes it as it ends it - see `namesRecordOfTempBasalEnd`. Until
        /// then its records are not read, nor is it settled from our estimate - for `tempBasalEndRecordWait` at most.
        var awaitsRecord: Bool {
            named.value.awaits
        }

        /// When the status that ended it, naming no record, was received, on the monotonic clock: one received before
        /// says nothing of its record. Nil, restored after a restart: every status of this run came after it.
        let awaitsAfterUptime: TimeInterval?

        private let named: Locked<(lastRecord: Int?, awaits: Bool)>
        /// No record of its own end known, those of the temp basals ended open before it are read all the same - unless
        /// the command that ended it went unanswered: the link may be gone
        let readsOpenEnds: Bool
        /// What followed it - a command that changes the basal again before it is settled adds its own, under
        /// `doseReportLock` (`hold`)
        var then: [NewPumpEvent] = []
        /// The finals of a bolus that came meanwhile, out after `then`, in the same batch - its end, mutable, goes out
        /// from the dose as it is then (`emitBolusEvents`). Under `doseReportLock`.
        var bolusReports: [NewPumpEvent] = []

        init(
            dose: UnfinalizedDose,
            patchEnd: Date?,
            lastRecord: Int?,
            readsOpenEnds: Bool = true,
            awaitsRecord: Bool = false,
            awaitsAfterUptime: TimeInterval? = nil
        ) {
            self.dose = dose
            self.patchEnd = patchEnd
            named = Locked((lastRecord, awaitsRecord && lastRecord == nil))
            self.readsOpenEnds = readsOpenEnds
            self.awaitsAfterUptime = awaitsAfterUptime
        }

        /// A status names `record` its last. Under `doseReportLock`.
        fileprivate func name(_ record: Int) {
            named.value = (record, false)
        }
    }

    internal var pendingTempBasalEnd: TempBasalEnd? {
        doseReportLock.withLock { pendingTempBasalEndStorage }
    }

    /// At most this many records are read for a temp basal as it ends - its parts and a bolus or two: a backlog is left
    /// to the record sync, and our estimate stands in
    internal static let tempBasalEndMaxRecords = 8

    /// How long one record may take to come back as a temp basal ends: 4 to 9 s on a slow link (a fragment every 1.3 s
    /// or so, device logs 2026-10). A link that does not answer by then is not waited on any longer.
    internal static let tempBasalEndRecordTimeout: TimeInterval = 10

    /// How long the records of a temp basal as it ends may take to read, all of them: the command that ended it - and the
    /// loop waiting on it - is held up meanwhile. Two records' worth, for one whose parts the patch split at midnight, or
    /// with a bolus's record ahead of its own: the reading stops as soon as the ones read settle it. Past it, our
    /// estimate stands in.
    internal static let tempBasalEndReadBudget: TimeInterval = 2 * tempBasalEndRecordTimeout

    /// The same, read off a command, the patch suspended - halted or told to - and no command waiting for the link
    /// (`readsLongerAsTempBasalEnds`): nothing the loop sends can deliver meanwhile, nor is held up, and the host has
    /// the temp basal delivering through the suspension until its final - IOB overstated, never understated. A slow
    /// link takes 4 to 7 s a record (device 2026-10-22 20:18:59-20:19:20: four in 21 s, past `tempBasalEndReadBudget`).
    /// Checked before each record: a command come meanwhile waits for the one in flight at most, as within the budget.
    internal static let tempBasalEndSuspendedReadBudget: TimeInterval = 6 * tempBasalEndRecordTimeout

    /// Whether the records of a temp basal as it ends may take `tempBasalEndSuspendedReadBudget` to read
    internal var readsLongerAsTempBasalEnds: Bool {
        doseReportLock.withLock { state.basalDose.type == .suspend } && !isCommandActive && !isLoopWaiting
    }

    /// No record is asked for with less of that budget left than a round trip takes
    internal static let tempBasalEndRecordReadMinimum: TimeInterval = 1.5

    /// The running temp basal, if any, stopped at `endedAt` - its last record `lastRecord`, ending at `patchEnd` on the
    /// patch clock, where known - and `next` follows it: neither goes out before its final, see `TempBasalEnd`. It is
    /// kept in `awaitingRecord` meanwhile, its last record and patch end with it - and `next` in `heldBasalDoses`: a run
    /// killed during the read has the next one read them on its first link, `next` reported after its final all the
    /// same (`takeOverTempBasalEndFromLastRun`). `awaitsRecordAfter`, no last record known: a status received after
    /// then - the status that ended it - names it, see `TempBasalEnd.awaitsRecord`. The caller replaces `state.basalDose` with `next`, then has it finished. Returns
    /// false when no temp basal was running: the caller reports `next` itself. Only under `doseReportLock`.
    internal func beginTempBasalEnd(
        endedAt: Date,
        patchEnd: Date?,
        lastRecord: Int?,
        readsOpenEnds: Bool = true,
        awaitsRecordAfter receivedUptime: TimeInterval? = nil,
        then next: (dose: UnfinalizedDose, event: NewPumpEvent)
    ) -> Bool {
        doseReportLock.withLock { () -> Bool in
            let dose = state.basalDose
            guard dose.type == .tempBasal, !dose.isFinished else {
                return false
            }

            // One that ended before, its records still unread, goes out first - from our estimate. So too one restored
            // after a restart (`takeOverTempBasalEndFromLastRun`) that the first status of this run - a halt over the
            // temp basal set after it, say - ends another before reading it, though its records are no later than the
            // new one's: rare, a restart in the read of a set's cancel and a halt while the app was gone, and the
            // estimate is what any restart gave before
            if pendingTempBasalEndStorage != nil {
                emitPumpEvents([])
            }

            dose.finish(endedAt >= dose.estimatedEndDate ? .completed : .cancelled, endedAt: endedAt, at: now())
            // Saved with it: a restart before its final reads them after all - or waits for the status that names them
            let awaitsRecord = receivedUptime != nil && lastRecord == nil
            if let lastRecord {
                dose.noteEndRead(lastRecord: lastRecord, patchEnd: patchEnd)
            } else if awaitsRecord {
                dose.noteEndAwaitsRecord(patchEnd: patchEnd)
            }
            state.mutateAwaitingRecord { doses in
                guard !doses.contains(where: { $0 === dose }) else {
                    return
                }
                doses.append(dose)
            }
            let ending = TempBasalEnd(
                dose: dose,
                patchEnd: patchEnd,
                lastRecord: lastRecord,
                readsOpenEnds: readsOpenEnds,
                awaitsRecord: awaitsRecord,
                awaitsAfterUptime: receivedUptime
            )
            pendingTempBasalEndStorage = ending
            hold(next, after: ending)

            if awaitsRecord {
                log.info(
                    "Temp basal of \(dose.startDate) ended at \(endedAt), its status naming no record: reported once its " +
                        "records up to the one the next status names are read, \(Int(Self.tempBasalEndRecordWait)) s at most"
                )
                boundTheWaitForItsRecord(ending, after: Self.tempBasalEndRecordWait)
            } else {
                log.info(
                    "Temp basal of \(dose.startDate) ended at \(endedAt), reported once its records up to " +
                        "\(lastRecord.map { "#\($0)" } ?? "-") are read"
                )
            }
            return true
        }
    }

    /// A status received at `receivedUptime` names `newest` the newest record of the patch `patchId` has written: the
    /// temp basal a halt ended with no record named (`TempBasalEnd.awaitsRecord`), if one waits, has it for its last -
    /// written as the patch ended it, it is that one or one before - saved with it, as one named so from the start.
    /// Returns whether one did: the caller has its records read, as for one this status ended. Not for another patch,
    /// nor once the session ended. Nor from a status received before the one that ended it, handled after it - a full
    /// status's thread against the notifications' - nor one naming no record past those read: from before the patch wrote
    /// its record. It waits on then.
    internal func namesRecordOfTempBasalEnd(_ newest: Int, patchId: UInt64, receivedUptime: TimeInterval) -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard let ending = pendingTempBasalEndStorage, ending.awaitsRecord, !state.patchSessionEnded,
                  !state.patchId.isEmpty, RecordSyncer.isSamePatch(patchId, state.patchId.toUInt64())
            else {
                return false
            }
            guard newest > state.syncedSequenceNumber, ending.awaitsAfterUptime.map({ receivedUptime >= $0 }) ?? true else {
                log.info(
                    "A status names record #\(newest), from before the temp basal of \(ending.dose.startDate) ended - " +
                        "read up to #\(state.syncedSequenceNumber): waiting on for one that names its record"
                )
                return false
            }
            ending.name(newest)
            ending.dose.noteEndRead(lastRecord: newest, patchEnd: ending.patchEnd)
            log.info("A status names record #\(newest): the records of the temp basal of \(ending.dose.startDate) are read up to it")
            return true
        }
    }

    /// The temp basal whose end waits for a status to name its record (`TempBasalEnd.awaitsRecord`), on a command's thread
    /// holding `commandLock` - a command that changes the basal behind it, a bolus, the deactivation: a full status is
    /// asked for here, its storage naming it (`namesRecordOfTempBasalEnd`), and the command reads it, as one named from
    /// the start. Not left to the heartbeat: what the command reports would be held behind it meanwhile - a temp basal so
    /// is not saved with the state (`hold`) - and the deactivation would report it from our estimate. Returns whether it
    /// is named now.
    @discardableResult internal func askForTheRecordOfTheWaitingEnd() -> Bool {
        guard let ending = pendingTempBasalEnd, ending.awaitsRecord else {
            return false
        }
        log.info("Asking for a full status in the command: it names the record of the temp basal of \(ending.dose.startDate)")

        let result = link.write(SynchronizePacket(), timeout: Self.tempBasalEndRecordTimeout)
        guard case let .success(data) = result, let response = data as? SynchronizePacketResponse else {
            log.warning("The full status asked for did not come: the temp basal of \(ending.dose.startDate) waits on")
            return false
        }
        handleStatus(response, duringReconnect: false, fullSync: true)
        return !ending.awaitsRecord
    }

    /// `ending` waits for a status to name its last record (`TempBasalEnd.awaitsRecord`) - not for good: none by `delay`
    /// from now, the link likely gone, its final goes out from our estimate, what followed it with it. Only under
    /// `doseReportLock`.
    private func boundTheWaitForItsRecord(_ ending: TempBasalEnd, after delay: TimeInterval) {
        tempBasalEndQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.backgroundReadsStopped.value else {
                return
            }
            self.doseReportLock.withLock {
                guard self.pendingTempBasalEndStorage === ending, ending.awaitsRecord else {
                    return
                }
                _ = self.settleTempBasalEnd(
                    ending,
                    records: [],
                    unread: "no status named its record within \(Int(Self.tempBasalEndRecordWait)) s of its end"
                )
            }
        }
    }

    /// How long the temp basal a halt ended waits for a status to name its record (`TempBasalEnd.awaitsRecord`): the full
    /// status a heartbeat asks for at once names it (`heartbeatSync`) - 3 s later on the device, 2026-10-26 10:08:58.
    /// Past that, the link likely gone, our estimate stands in: the host has the temp basal delivering through the halt
    /// meanwhile, as when the restart's read waits for the link (`tempBasalEndFromLastRunLinkWait`). On the wall clock;
    /// only tests change it.
    internal static var tempBasalEndRecordWait: TimeInterval = tempBasalEndFromLastRunLinkWait

    /// In a new run's state, a temp basal whose records were being read as it ended (`TempBasalEnd`), the app gone
    /// before its final: its last record saved with it (`UnfinalizedDose.State.endReadLastRecord`), it waits on its
    /// read again - on the first status of this run, as one a status ended (`readsTempBasalEndFromLastRun`), or the
    /// command that comes first - what was held back after it held behind its final as before, and nothing reported
    /// meanwhile: the host has it as the run before left it. Our estimate stands in if that read fails, if the patch
    /// session is not the one it was saved with by then, if no status comes within `tempBasalEndFromLastRunLinkWait` of
    /// the restart, and before any batch that goes out first - as in the run that ended it. Not one with no last record
    /// known - unless it waits for a status to name it (`TempBasalEnd.awaitsRecord`): it waits on here, what is left of
    /// `tempBasalEndRecordWait` - one saved by an earlier build, one that ended `tempBasalEndFromLastRunLinkWait` ago or more, nor one whose
    /// record is overdue: from our estimate with the first batch, as before (`emitPumpEvents`).
    ///
    /// The restart used to finalize it from our estimate at once - its end was kept in memory only, and the first batch
    /// of the new run needs no link that way, and carries its final ahead of what followed it, which Loop's watermark
    /// requires. Waiting for the link puts that order at no risk: no batch goes out meanwhile without its final, and what
    /// followed it is saved until the host stores it (`heldBasalDoses`). The wait is bounded, as the read is.
    internal func takeOverTempBasalEndFromLastRun() {
        doseReportLock.withLock {
            guard !state.patchId.isEmpty, !state.patchSessionEnded else {
                return
            }
            let checkedAt = now()
            let waiting = state.awaitingRecord.filter { dose in
                let ended = dose.snapshot
                guard dose.type == .tempBasal, !ended.isFinalized, !ended.endedOpen,
                      ended.endReadLastRecord != nil || ended.endReadAwaitsRecord, let finishedAt = ended.finishedAt
                else {
                    return false
                }
                // Not one that ended `tempBasalEndFromLastRunLinkWait` ago or more: restarts one after the other - a
                // crash loop - would otherwise each wait it out again, the suspend held behind it kept from the host
                // for good. A wall clock set back since - the age negative - restores nothing either.
                let age = checkedAt.timeIntervalSince(finishedAt)
                guard age >= 0, age < Self.tempBasalEndFromLastRunLinkWait else {
                    return false
                }
                return RecordSyncer.fallbackRule(since: finishedAt, caughtUp: isCaughtUp(after: finishedAt), now: checkedAt) == nil
            }
            // One at a time in a run: any other is an older one's, from our estimate ahead of it
            guard let dose = waiting.max(by: { $0.startDate < $1.startDate }), let finishedAt = dose.snapshot.finishedAt else {
                return
            }
            let lastRecord = dose.snapshot.endReadLastRecord

            let ending = TempBasalEnd(
                dose: dose,
                patchEnd: dose.snapshot.endReadPatchEnd,
                lastRecord: lastRecord,
                awaitsRecord: dose.snapshot.endReadAwaitsRecord
            )
            // What followed it, held back - as `hold` had it, as it ended or after: in this batch with its final, after
            // it. Not a suspend or resume kept from before (`keepUntilStored`) that is dated at its start or later - its
            // first, of what followed it, would have its final end there.
            ending.then = state.heldBasalDoses.filter { $0.heldAt >= finishedAt && $0.dose.startDate >= dose.startDate }
                .map(\.dose).compactMap(Self.heldEvent(of:))
            pendingTempBasalEndStorage = ending
            tempBasalEndFromLastRun = (ending, state.patchId, checkedAt)
            if let lastRecord {
                log.info(
                    "The temp basal of \(dose.startDate) was saved as its records up to #\(lastRecord) were read: read on the " +
                        "first link, \(ending.then.count) dose(s) held back behind its final"
                )
            } else {
                log.info(
                    "The temp basal of \(dose.startDate) was saved waiting for a status to name its record: read once one " +
                        "does, \(ending.then.count) dose(s) held back behind its final"
                )
                // What is left of the wait it began with - the restart's own bound, below, ends with the first status
                let waited = max(0, checkedAt.timeIntervalSince(finishedAt))
                boundTheWaitForItsRecord(ending, after: max(0, Self.tempBasalEndRecordWait - waited))
            }

            // At the bound, the loop's next run maybe minutes off - the patch out of reach, no status comes
            tempBasalEndQueue.asyncAfter(deadline: .now() + Self.tempBasalEndFromLastRunCheckDelay) { [weak self] in
                guard let self, !self.backgroundReadsStopped.value else {
                    return
                }
                self.doseReportLock.withLock {
                    self.giveUpOnTempBasalEndFromLastRun(ending)
                }
            }
        }
    }

    /// The temp basal restored waiting on its read (`takeOverTempBasalEndFromLastRun`), `ending`, no read of it begun
    /// within `tempBasalEndFromLastRunLinkWait` of the restart: not waited on for good - its final goes out from our
    /// estimate, what was held behind it with it. Only under `doseReportLock`.
    internal func giveUpOnTempBasalEndFromLastRun(_ ending: TempBasalEnd) {
        guard tempBasalEndFromLastRun?.ending === ending else {
            return
        }
        tempBasalEndFromLastRun = nil
        _ = settleTempBasalEnd(
            ending,
            records: [],
            unread: "no status came within \(Int(Self.tempBasalEndFromLastRunLinkWait)) s of the restart to read them on"
        )
    }

    /// A read of the records of `ending` begins: the temp basal restored waiting on its read, if that is it, is the
    /// read's from here on - not given up on meanwhile (`giveUpOnTempBasalEndFromLastRun`). A command that came first
    /// reads it so, with no status of this run before it.
    internal func noteTempBasalEndReadBegins(_ ending: TempBasalEnd) {
        doseReportLock.withLock {
            if tempBasalEndFromLastRun?.ending === ending {
                tempBasalEndFromLastRun = nil
            }
            // Nor waited on for the bolus's end any longer (`readsTempBasalEndAfterBolus`): its bound is moot
            if tempBasalEndAwaitingBolus === ending {
                tempBasalEndAwaitingBolus = nil
            }
        }
    }

    /// No status within this long of a restart, the temp basal restored waiting on its read goes final from our
    /// estimate - see `takeOverTempBasalEndFromLastRun`. The patch is back within seconds of a relaunch in reach (device
    /// log 2026-10-20 13:38:37, its status 2 s later). Past that it may be out of reach for long - and the suspend held
    /// behind it, which the host would otherwise have again within `unconfirmedFinalsResendInterval`, is worth more
    /// than the record: kept from the host, it has the temp basal deliver through the suspension, an error growing by
    /// the minute, while our estimate is off by the temp basal's rate × the age of its last status at most. Checked
    /// as it runs out, on a timer set at the restart (`tempBasalEndFromLastRunCheckDelay`) - and where the finals the
    /// host has yet to confirm are sent again, which needs no link (`resendUnacknowledgedFinalsIfDue`): the loop's
    /// every run. Nor is one restored that ended this long ago: a run before waited it out already.
    internal static let tempBasalEndFromLastRunLinkWait: TimeInterval = unconfirmedFinalsResendInterval

    /// When that timer fires after the restart, on the wall clock: `tempBasalEndFromLastRunLinkWait`. Only tests change
    /// it, their manager's clock moved on instead.
    internal static var tempBasalEndFromLastRunCheckDelay: TimeInterval = tempBasalEndFromLastRunLinkWait

    /// A status of the patch: the temp basal restored waiting on its read (`takeOverTempBasalEndFromLastRun`), if
    /// any, is read now, as one this status ended - returns true, the caller has it read. Once: it is the read's from
    /// here on. One restored for another patch session goes final from our estimate.
    internal func readsTempBasalEndFromLastRun() -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard let restored = tempBasalEndFromLastRun else {
                return false
            }
            tempBasalEndFromLastRun = nil
            guard pendingTempBasalEndStorage === restored.ending else {
                return false
            }
            guard state.patchId == restored.patchId, !state.patchSessionEnded else {
                _ = settleTempBasalEnd(restored.ending, records: [], unread: "the patch session ended")
                return false
            }
            return true
        }
    }

    /// Reads the records of the temp basal whose end is pending and reports it final, with what followed it - on this
    /// thread, which may block on the link: a full status's. Only if no other operation holds `commandLock`: returns
    /// false, having read nothing, if one does. See `RecordSyncer.finishTempBasalEnd`.
    func finishPendingTempBasalEndIfFree() -> Bool {
        withCommandLockIfFree {
            RecordSyncer.finishTempBasalEnd(pumpManager: self)
        } != nil
    }

    /// The same, off the queue statuses arrive on - once no command is in flight: one that changes the basal finishes it
    /// first, on its own path - and holding `commandLock`, as a command does
    func finishPendingTempBasalEndSoon() {
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

            // Not counted as waiting: a record sync ahead of it may be reading these very records
            let read = self.withCommandLock(waits: false) {
                RecordSyncer.finishTempBasalEnd(pumpManager: self)
            }
            if !read, let ending = self.pendingTempBasalEnd {
                _ = self.settleTempBasalEnd(ending, records: [], unread: "another operation held the patch")
            }
        }
    }

    /// `ending`, read off a command - a halt's, say - with a bolus running: no record is read while it runs
    /// (`RecordSyncer.wouldRead`), and the patch, halted, ends it moments later, its completion in a notification of its
    /// own. Read once it is over - its end held behind the read meanwhile (`emitBolusEvents`) - rather than taking it out
    /// from our estimate now. Not for good: past `tempBasalEndBolusWait` with the bolus still running - the link lost,
    /// its end unseen - our estimate stands in, what followed it with it. A full status past its deadline ends it, the
    /// session's end takes the temp basal out with it. Returns whether it waits.
    internal func readsTempBasalEndAfterBolus(_ ending: TempBasalEnd) -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard pendingTempBasalEndStorage === ending, let bolus = state.bolusDose, !bolus.isFinished,
                  lastRecordToRead(for: ending) != nil
            else {
                return false
            }
            guard tempBasalEndAwaitingBolus !== ending else {
                return true
            }
            tempBasalEndAwaitingBolus = ending
            log.info("A bolus is running: the records of the temp basal of \(ending.dose.startDate) are read once it is over")

            tempBasalEndQueue.asyncAfter(deadline: .now() + Self.tempBasalEndBolusWait) { [weak self] in
                guard let self, !self.backgroundReadsStopped.value else {
                    return
                }
                self.doseReportLock.withLock {
                    guard self.tempBasalEndAwaitingBolus === ending else {
                        return
                    }
                    self.tempBasalEndAwaitingBolus = nil
                    _ = self.settleTempBasalEnd(
                        ending,
                        records: [],
                        unread: "the bolus running as it ended was not over within \(Int(Self.tempBasalEndBolusWait)) s"
                    )
                }
            }
            return true
        }
    }

    /// How long the records of a temp basal that ended with a bolus running wait for it to be over: a halt ends it,
    /// its completion follows within seconds - and the host has no suspend meanwhile, as when the restart's read waits
    /// for the link (`tempBasalEndFromLastRunLinkWait`). On the wall clock; only tests change it.
    internal static var tempBasalEndBolusWait: TimeInterval = tempBasalEndFromLastRunLinkWait

    /// The bolus a temp basal's records waited for is over (`readsTempBasalEndAfterBolus`): read them now
    internal func readTempBasalEndAfterBolus() {
        let due = doseReportLock.withLock { () -> Bool in
            guard let ending = tempBasalEndAwaitingBolus, state.bolusDose.map(\.isFinished) ?? true else {
                return false
            }
            tempBasalEndAwaitingBolus = nil
            return pendingTempBasalEndStorage === ending
        }
        if due {
            finishPendingTempBasalEndSoon()
        }
    }

    /// Fixes the final of the temp basal of `ending` - from `records`, read in one go up to its last record, if they
    /// add up to it; else from our estimate, `unread` saying why not all could be read - and reports it with what
    /// followed it. Every temp basal ended open before it goes final first, in the same batch: from `records` where they
    /// add up to it, else from our estimate - see `openTempBasalEnds`. Returns the outcome for each record a temp basal
    /// was finalized from, for the record screen. Nothing, if a batch carried it out meanwhile.
    internal func settleTempBasalEnd(_ ending: TempBasalEnd, records: [GetRecordResponse], unread: String?) -> [Int: String] {
        doseReportLock.withLock { () -> [Int: String] in
            guard pendingTempBasalEndStorage === ending else {
                return [:]
            }
            pendingTempBasalEndStorage = nil
            if tempBasalEndFromLastRun?.ending === ending {
                tempBasalEndFromLastRun = nil
            }
            if tempBasalEndAwaitingBolus === ending {
                tempBasalEndAwaitingBolus = nil
            }

            let dose = ending.dose
            var events: [NewPumpEvent] = []
            var outcomes: [Int: String] = [:]

            // The temp basal whose command went unanswered started before all of them: its record among these goes final
            // first, in this batch - after theirs, the host would take it as behind them, and drop it
            if state.unconfirmedTempBasal != nil {
                let patchId = state.patchId.toUInt64()
                for response in records.sorted(by: { $0.sequence < $1.sequence })
                    where RecordSyncer.isSamePatch(response.patchId, patchId)
                {
                    guard case let .basal(record) = response.record, record.type == .ABSOLUTE_TEMP,
                          let finalized = finalizeUnconfirmedTempBasal(from: record, sequence: response.sequence, ending: true)
                    else {
                        continue
                    }
                    events += finalized.events
                    outcomes[response.sequence] = finalized.outcome
                    break
                }
            }

            for open in openTempBasalEnds {
                if let parts = openTempBasalParts(of: open, in: records, logging: true) {
                    if let final = finalizeOpen(open, from: parts) {
                        events.append(final)
                    }
                    for sequence in parts.sequences {
                        outcomes[sequence] = "finalized temp basal \(open.startDate)"
                    }
                } else if let final = estimateFinal(
                    open,
                    because: unread ?? "its records do not add up, and the temp basal of \(dose.startDate) after it ended"
                ) {
                    events.append(final)
                }
            }

            if unread == nil, let lastRecord = ending.lastRecord,
               let parts = tempBasalParts(of: dose, in: records, endingAt: ending.patchEnd, through: lastRecord)
            {
                log.info(
                    "Record(s) \(parts.sequences.map(String.init).joined(separator: ", ")) finalize the temp basal of " +
                        "\(dose.startDate): \(String(format: "%.1f", parts.duration / 60)) min on the patch, delivered " +
                        "\(parts.delivered) U by its records - ended at \(dose.observedEndDate.map { "\($0)" } ?? "-"), " +
                        "where what followed it starts"
                )
                // The amount the patch's, the end ours, where what followed it starts: nothing between the two for the
                // host to fill, nor to trim off it - unless the patch had stopped it well before, see `recordedEnd`
                let recorded = recordedEnd(of: dose, parts, in: records, before: ending.then.first?.date)
                if recorded != nil, let next = ending.then.first?.date {
                    // It ended elsewhere than where what followed it is dated: that one's patch start pairs with nothing
                    for following in [state.basalDose] + state.heldBasalDoses.map(\.dose)
                        where following.type != .tempBasal && following.startDate == next
                    {
                        following.forgetPumpStartTime()
                    }
                }
                if let final = finalize(dose, deliveredUnits: parts.delivered, endDate: recorded, .byRecord) {
                    events.append(final)
                }
                for sequence in parts.sequences {
                    outcomes[sequence] = "finalized temp basal \(dose.startDate)"
                }
            } else if let final = estimateFinal(
                dose,
                because: unread ?? (ending.lastRecord == nil ? "no record of its end is known" : "its records do not add up")
            ) {
                events.append(final)
            }

            emitPumpEvents(events + ending.then + ending.bolusReports)
            return outcomes
        }
    }

    /// The last record to read for the temp basal of `ending`: its own - else, no record of its end known and the command
    /// that ended it answered, the newest one a temp basal ended open before it waits on. Nil, none.
    internal func lastRecordToRead(for ending: TempBasalEnd) -> Int? {
        if let last = ending.lastRecord {
            return last
        }
        // Its own named by a status yet to come: those ended open before it are read with it then
        guard ending.readsOpenEnds, !ending.awaitsRecord else {
            return nil
        }
        // The temp basal whose command went unanswered, kept, with no cancel's answer naming its record - a set with no
        // cancel before it went out since: its record, if written, is no later than the newest the patch has
        let unconfirmed = doseReportLock.withLock { () -> Int? in
            guard let pending = state.unconfirmedTempBasal, pending.snapshot.endRecord == nil else {
                return nil
            }
            return state.currentSequenceNumber
        }
        return [lastRecordOfOpenTempBasalEnds, unconfirmed].compactMap { $0 }.max()
    }

    /// Where a temp basal finalized from its records `parts` ends: where we saw it end - what followed it starts there -
    /// unless its records end more than `patchEndTolerance` before that: the patch had stopped it then, unseen, and ran
    /// the schedule since, which the host fills the gap with - nil, where we saw it. A halt the patch announced without
    /// its time is not that: nothing ran after it, and the suspend after it is dated as it was seen.
    private func recordedEnd(
        of dose: UnfinalizedDose,
        _ parts: (delivered: Double, duration: TimeInterval, sequences: [Int], end: Date),
        in records: [GetRecordResponse],
        before next: Date?
    ) -> Date? {
        // Its parts from a patch start not its first segment's: they tell nothing of where it ended on our clock
        guard parts.duration >= Self.shortestComputedDuration, !dose.snapshot.firstSegmentUncertain else {
            return nil
        }
        let recorded = dose.startDate.addingTimeInterval(parts.duration)
        let observed = dose.tempBasalEnd(of: dose.snapshot)
        // Longer than where we took it to end - early, from the cancel's answer: the record wins, short of what follows
        if recorded.timeIntervalSince(observed) > Self.patchEndTolerance {
            let end = next.map { min(recorded, $0) } ?? recorded
            log.warning(
                "The records of the temp basal of \(dose.startDate) run \(Int(recorded.timeIntervalSince(observed))) s past " +
                    "where we took it to end, \(observed): it ends at \(end)"
            )
            return end
        }
        guard observed.timeIntervalSince(recorded) > Self.patchEndTolerance else {
            return nil
        }
        if let last = records.first(where: { $0.sequence == parts.sequences.last }), case let .basal(record) = last.record,
           record.endReason?.isSuspendedByPump() == true
        {
            return nil
        }
        log.warning(
            "The records of the temp basal of \(dose.startDate) end at \(recorded) on our clock, \(Int(observed.timeIntervalSince(recorded))) s " +
                "before we saw it end: the patch had stopped it then - it ends there, and the schedule ran since"
        )
        return recorded
    }

    /// Whether `records`, read in order so far, settle the temp basal of `ending` before its last record: its parts add
    /// up - see `tempBasalParts` - and the last of them is shown to be where it ended - and so every temp basal ended
    /// open before it (`openTempBasalParts`). Where it ended on the patch clock is known: the last part ends there. It is
    /// not - a halt the patch announced without its time, as it does: the last part is one the halt ended, by its end
    /// reason. A part ending where the patch split it, at patch-local midnight, ends with success, and a part after it
    /// may follow: without a known end, nothing short of that settles it - it is read up to its last record. The
    /// records after them are left to the record sync.
    internal func settlesTempBasalEnd(_ ending: TempBasalEnd, records: [GetRecordResponse]) -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard openTempBasalEnds.allSatisfy({ openTempBasalParts(of: $0, in: records) != nil }) else {
                return false
            }
            // No record of its own end known, read for those ended open before it only: they settle it
            guard let lastRecord = ending.lastRecord else {
                return true
            }
            guard let parts = tempBasalParts(of: ending.dose, in: records, endingAt: ending.patchEnd, through: lastRecord, logging: false)
            else {
                return false
            }

            if let patchEnd = ending.patchEnd {
                return abs(parts.end.timeIntervalSince(patchEnd)) <= RecordSyncer.tempBasalStartTolerance
            }

            guard let last = records.first(where: { $0.sequence == parts.sequences.last }),
                  case let .basal(record) = last.record
            else {
                return false
            }
            return record.endReason?.isSuspendedByPump() == true
        }
    }

    /// What `records` show a temp basal of ours delivered, and for how long: its ABSOLUTE_TEMP parts at its rate - the
    /// ones kept as it ran (`keepPartOfRunningTempBasal`), then the ones read now - the first starting on its patch
    /// start, each where the one before ended, all of this patch, the last where it ended (`patchEnd`) or ran its
    /// course. Nil, the reason logged if `logging`, if they don't add up.
    internal func tempBasalParts(
        of dose: UnfinalizedDose,
        in records: [GetRecordResponse],
        endingAt patchEnd: Date?,
        through lastRecord: Int? = nil,
        logging: Bool = true
    ) -> (delivered: Double, duration: TimeInterval, sequences: [Int], end: Date)? {
        let tolerance = RecordSyncer.tempBasalStartTolerance
        let snapshot = dose.snapshot
        let log = logging ? self.log : nil
        guard !snapshot.recordMatchDisabled, let pumpStartTime = snapshot.pumpStartTime else {
            log?.info(
                "The temp basal of \(dose.startDate) is not taken from its records: " +
                    (snapshot.recordMatchDisabled ? "they do not start where its patch start says" : "no patch start")
            )
            return nil
        }

        let patchId = state.patchId.toUInt64()
        var parts: [UnfinalizedDose.RecordedPart] = []
        for kept in snapshot.recordedParts {
            let partStart = parts.last?.end ?? pumpStartTime
            guard RecordSyncer.isSamePatch(kept.patchId, patchId), abs(kept.start.timeIntervalSince(partStart)) <= tolerance else {
                log?.warning(
                    "Record \(kept.sequence), a part of the temp basal of \(dose.startDate) read as it ran, is of patch " +
                        "\(kept.patchId) from \(kept.start): not where the part before it ended (\(partStart)), or not this patch"
                )
                return nil
            }
            parts.append(kept)
        }

        for response in records where !parts.contains(where: { $0.sequence == response.sequence }) {
            // Where it ended, its parts are all in: a record after - of the next one, at the same rate, say - is not one
            if let patchEnd, let last = parts.last, abs(last.end.timeIntervalSince(patchEnd)) <= tolerance {
                break
            }
            // Nor is one numbered past its last
            if let lastRecord, response.sequence > lastRecord {
                continue
            }
            guard case let .basal(record) = response.record, record.type == .ABSOLUTE_TEMP,
                  RecordSyncer.steps(record.rate) == RecordSyncer.steps(dose.value)
            else {
                continue
            }

            let part = UnfinalizedDose.RecordedPart(
                sequence: response.sequence,
                patchId: response.patchId & 0xFFFF,
                start: record.startTime,
                end: record.endTime,
                delivered: record.delivered
            )
            if let previous = parts.last {
                guard abs(record.startTime.timeIntervalSince(previous.end)) <= tolerance else {
                    log?.warning(
                        "Record \(response.sequence) of a temp basal at its rate starts at \(record.startTime), not where " +
                            "the part of the temp basal of \(dose.startDate) before it ended (\(previous.end))"
                    )
                    return nil
                }
                parts.append(part)
            } else if abs(record.startTime.timeIntervalSince(pumpStartTime)) <= tolerance {
                parts.append(part)
            }
        }

        guard let first = parts.first, let last = parts.last else {
            log?.warning("No record read starts where the temp basal of \(dose.startDate) did (\(pumpStartTime))")
            return nil
        }

        let ranItsCourse = pumpStartTime.addingTimeInterval(dose.estimatedEndDate.timeIntervalSince(dose.startDate))
        guard patchEnd.map({ abs(last.end.timeIntervalSince($0)) <= tolerance }) ?? true ||
            abs(last.end.timeIntervalSince(ranItsCourse)) <= tolerance
        else {
            log?.warning(
                "The records of the temp basal of \(dose.startDate) end at \(last.end), not where it ended " +
                    "(\(patchEnd.map { "\($0)" } ?? "-"))"
            )
            return nil
        }

        let delivered = parts.reduce(0) { $0 + $1.delivered }
        return (delivered.rounded(toPlaces: 2), last.end.timeIntervalSince(first.start), parts.map(\.sequence), last.end)
    }

    /// Fixes the final of a finished temp basal from our estimate - see `UnfinalizedDose.tempBasalEstimate`, its rate ×
    /// duration if it ran across patch-local midnight - and logs what it is based on. Only under `doseReportLock`; the
    /// caller hands the final over.
    @discardableResult internal func estimateFinal(_ dose: UnfinalizedDose, because reason: String) -> NewPumpEvent? {
        let snapshot = dose.snapshot
        guard !snapshot.isFinalized else {
            return nil
        }

        let skew = state.patchClockSkew
        let start = snapshot.pumpStartTime ?? dose.startDate.addingTimeInterval(skew)
        let end = dose.tempBasalEnd(of: snapshot).addingTimeInterval(skew)
        let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
        let restarted = Self.crossesPatchMidnight(from: start, to: end, utcOffset: utcOffset)
        // Ended open: delivering up to the cancel, where the patch says it ended - not up to the next one's start
        var until: Date?
        if snapshot.endedOpen, !snapshot.firstSegmentUncertain, let patchEnd = snapshot.patchEndTime,
           let pumpStartTime = snapshot.pumpStartTime
        {
            // How long the patch ran it, from our start: skew-free
            until = dose.startDate.addingTimeInterval(max(0, patchEnd.timeIntervalSince(pumpStartTime)))
        }
        let estimate = dose.tempBasalEstimate(of: snapshot, restarted: restarted, until: until)

        guard let event = finalize(dose, deliveredUnits: estimate.units, .byEstimate) else {
            return nil
        }

        log.warning(
            "Finalized the temp basal of \(dose.startDate) (\(snapshot.finishReason?.rawValue ?? "-")) without its records, " +
                "\(reason): \(estimate.units) U by our estimate, from its \(estimate.source.rawValue)" +
                (restarted ? " - it ran across patch-local midnight" : "")
        )
        return event
    }
}

import Foundation
import LoopKit

/// Reads the patch's own event log, and finalizes the doses waiting on it.
///
/// The patch writes a numbered record when a delivery event ends - a bolus, a basal segment - with what it really
/// delivered. A finished bolus stays mutable for the host (`MedtrumPumpState.awaitingRecord`) until its record has been
/// read here and finalizes it (`MedtrumPumpManager.reconcile`) - or until a fallback gives up on it. So does a temp basal
/// ended back to back with the next (`MedtrumPumpManager.openTempBasalEnds`). Any other temp basal's records are read as
/// it ends, and finalize it then (`finishTempBasalEnd`).
///
/// Reads block on BLE writes, so this must not run on the main queue or the central manager's queue. It never reads
/// while a bolus is running or a command is in flight, and stops between records when one starts: they share the link.
/// Each record is read holding the manager's command lock, never waiting for it (`withCommandLockIfFree`).
enum RecordSyncer {
    private static let logger = MedtrumLogger(category: "RecordSyncer")

    enum Trigger: String {
        /// The full sync the loop asks for, before the loop hears back: a few records only
        case loopSync = "loop sync"
        /// After a full sync: the heartbeat's, or the rest of the loop's
        case fullSync = "full sync"
        /// A heartbeat between full syncs, while doses wait on records the patch has written (or on their timeout), or
        /// records it told of are unread
        case awaitingDoses = "awaiting doses"
        /// Right before the patch is stopped: the last chance to read this session's records
        case beforeStop = "before stop"
        /// After a command that ended a temp basal back to back, for the records of the temp basals ended so
        /// (`MedtrumPumpManager.openTempBasalEnds`)
        case tempBasalEnds = "temp basal ends"

        /// One run reads at most this many records and leaves the rest to the next, so a backlog can't hold the link
        var maxRecords: Int {
            switch self {
            case .loopSync:
                return 3
            case .awaitingDoses,
                 .fullSync:
                return 10
            case .tempBasalEnds:
                return MedtrumPumpManager.tempBasalEndMaxRecords
            case .beforeStop:
                return 50
            }
        }
    }

    /// How far back to go the first time we sync a patch. Without this, adopting a patch that has
    /// been running for days would fetch its entire history one 30s-timeout request at a time.
    private static let initialBacklog = 20

    /// A record that comes back unreadable is asked for once more, then skipped. Two skipped in a row end the run.
    static let maxBadRecordsInARow = 2

    /// A temp basal's record starts on its patch start, to the second
    static let tempBasalStartTolerance: TimeInterval = 1

    /// A bolus's record starts on the start its SetBolus answer gave, to the second
    static let bolusStartTolerance: TimeInterval = 1

    /// Heartbeats can be frequent; while doses wait, read at most this often between full syncs
    private static let awaitingDosesInterval: TimeInterval = .minutes(1)

    /// The before-stop read waits this long for a run in progress - which yields to the stop between two records
    private static let beforeStopWait: TimeInterval = 35

    private struct RunState {
        var isRunning = false
        var lastAwaitingDosesRun = Date.distantPast
        /// A heartbeat turned away since that run was told of: every one after it is not
        var throttledLogged = false
    }

    private enum Begin: Equatable {
        case began
        case running
        /// The heartbeat's, run moments ago - `firstSince`: the first turned away since that run
        case throttled(firstSince: Bool)
    }

    private static let runState = Locked(RunState())

    /// For tests: the run state is global rather than per manager, so a sync one test left running would otherwise turn
    /// away the next test's
    static func resetForTesting() {
        runState.value = RunState()
    }

    /// For tests: `body` runs as a sync run would, holding the single flight
    static func whileRunningForTesting(_ body: () -> Void) {
        guard begin(nil) == .began else {
            preconditionFailure("A record sync is running already")
        }
        defer { end() }
        body()
    }

    /// Single flight, and throttled for the heartbeat trigger
    private static func begin(_ trigger: Trigger?) -> Begin {
        let now = Date.now
        var outcome = Begin.running

        runState.mutate { state in
            guard !state.isRunning else {
                return
            }

            if trigger == .awaitingDoses {
                guard now.timeIntervalSince(state.lastAwaitingDosesRun) >= awaitingDosesInterval else {
                    outcome = .throttled(firstSince: !state.throttledLogged)
                    state.throttledLogged = true
                    return
                }
                state.lastAwaitingDosesRun = now
                state.throttledLogged = false
            }

            state.isRunning = true
            outcome = .began
        }

        return outcome
    }

    /// Waits out a run in progress rather than skipping it: it yields between two records to the command this runs for
    private static func beginWaiting(_ trigger: Trigger?, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while begin(trigger) != .began {
            guard Date.now < deadline else {
                return false
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        return true
    }

    private static func end() {
        runState.mutate { $0.isRunning = false }
    }

    /// Reads the records the patch has written since the last call - up to `through` at most - and finalizes the doses
    /// they match - then, whether it could read or not, the doses that have waited for theirs long enough.
    static func syncRecords(pumpManager: MedtrumPumpManager, trigger: Trigger = .fullSync, through: Int? = nil) {
        // Needs neither the link nor a patch: the host has yet to confirm finals of earlier doses
        pumpManager.resendUnacknowledgedFinalsIfDue()

        let state = pumpManager.state
        guard !state.patchId.isEmpty, !state.pumpState.isSetup else {
            return
        }

        let began: Begin = trigger == .beforeStop ? (beginWaiting(trigger, timeout: beforeStopWait) ? .began : .running) : begin(trigger)
        switch began {
        case .began:
            break
        case .running:
            logger.debug("Record sync already running, skipping (\(trigger.rawValue))")
            return
        case let .throttled(firstSince):
            // Heartbeats come every few seconds: told once until the next run
            if firstSince {
                logger.debug("Record sync ran moments ago, skipping (\(trigger.rawValue)) for up to \(Int(awaitingDosesInterval)) s")
            }
            return
        }
        defer { end() }

        let syncedBefore = state.syncedSequenceNumber
        let currentBefore = state.currentSequenceNumber

        // A bolus record is only written once the bolus is over, and while it runs the link belongs to its
        // notifications - and to a cancel. The before-stop read runs inside the stop command.
        if state.bolusDose != nil {
            logger.debug("Not reading records (\(trigger.rawValue)): a bolus is running")
        } else if trigger != .beforeStop, pumpManager.isCommandActive {
            logger.debug("Not reading records (\(trigger.rawValue)): a command is in flight")
            // Turned away, it read nothing: no run of the cooldown's - a bolus's command, its answer naming the record,
            // would have the dose wait a minute for it. The next heartbeat tries again.
            if trigger == .awaitingDoses {
                runState.mutate { $0.lastAwaitingDosesRun = .distantPast }
            }
        } else if trigger != .beforeStop, let ending = pumpManager.pendingTempBasalEnd, ending.awaitsRecord {
            // Its record unnamed, and maybe among those to read - read here, behind the cursor, it would make no final of
            // it. Read once a status names it, `tempBasalEndRecordWait` at most. Not before the stop: the last chance,
            // and the session's end takes it out from our estimate anyway.
            logger.info(
                "Not reading records (\(trigger.rawValue)): the temp basal of \(ending.dose.startDate) waits for a status to " +
                    "name its record"
            )
            // Turned away, it read nothing: no run of the cooldown's, as for a command in flight
            if trigger == .awaitingDoses {
                runState.mutate { $0.lastAwaitingDosesRun = .distantPast }
            }
        } else {
            // A temp basal that ended has its records read first: read here, they would make no final of it
            _ = pumpManager.withCommandLockIfFree {
                finishTempBasalEndInFlight(pumpManager: pumpManager, until: pumpManager.now().addingTimeInterval(
                    MedtrumPumpManager.tempBasalEndReadBudget
                ))
            }
            let failed = readNewRecords(pumpManager: pumpManager, trigger: trigger, through: through)

            // Read up to the temp basals' last records - matched as theirs no further. A bolus's after them, the loop's
            // right behind the temp basal, is read on now, as a heartbeat's sync would: one would come a minute later at
            // the earliest (`awaitingDosesInterval`), its final with it. Each record asked for once, as up to there: a
            // manual bolus right behind waits no longer for one.
            if trigger == .tempBasalEnds, let through, state.syncedSequenceNumber >= through, pumpManager.awaitsRecordsWritten {
                logger.info("Reading on past record \(through), for the doses waiting on theirs")
                readNewRecords(pumpManager: pumpManager, trigger: .tempBasalEnds, through: nil)
            }

            // A bolus's answer named its record past the newest the patch had told of as this run began - its completion
            // came with the record before it, the heartbeat naming its own a moment later (device 2026-10-20 00:52:56):
            // unread, it is no run of the cooldown's, and the next heartbeat reads it, not one a minute later. So for a
            // run stopped short of it by a command taking the link, or by the run's cap: not one stopped by a read
            // failing - that waits for the cooldown.
            if trigger == .awaitingDoses, !failed, let named = pumpManager.newestRecordNamedForAwaitingDose,
               named > currentBefore, named > state.syncedSequenceNumber
            {
                logger.info("Record \(named), named by the answer of a dose waiting on it, was not told of yet: the next heartbeat reads it")
                runState.mutate { $0.lastAwaitingDosesRun = .distantPast }
            }
        }

        // Needs no link, so it runs either way
        let settled = pumpManager.finalizeOverdueAwaitingDoses()

        // Each final was handed to the host as its record was read, before the cursor moved past it
        if state.syncedSequenceNumber != syncedBefore || settled > 0 {
            pumpManager.notifyStateDidChange()
        }
    }

    /// The doses that have waited for their record long enough, finalized without reading any - for a patch out of
    /// reach. Not while a record sync runs: that one does this once it has read what it could.
    static func finalizeOverdueDosesUnread(pumpManager: MedtrumPumpManager) {
        guard begin(nil) == .began else {
            logger.debug("Record sync running, leaving the doses waiting on their record to it")
            return
        }
        defer { end() }

        if pumpManager.finalizeOverdueAwaitingDoses() > 0 {
            pumpManager.notifyStateDidChange()
        }
    }

    /// Reads forward from the cursor, reconciling each record. AndroidAPS's policy: a lost link or a timeout ends the
    /// run, the record is read again next time; an unreadable record is asked for once more and then skipped; two
    /// skipped in a row end the run. Returns whether the run ended so - on a read failing.
    @discardableResult private static func readNewRecords(pumpManager: MedtrumPumpManager, trigger: Trigger, through: Int?) -> Bool {
        let state = pumpManager.state
        let current = state.currentSequenceNumber
        let patchId = state.patchId

        guard current > 0 else {
            logger.debug("No record sequence known yet, nothing to sync")
            return false
        }

        // `currentSequenceNumber` is the last record the patch has *written*, and it is complete: a
        // record is written when the event it describes finishes, and numbered in write order. The
        // segment currently running has no record at all until it ends, which is why record numbers are
        // not ordered by start time - a bolus that finishes during a temp basal is written, and
        // numbered, before the temp basal it ran inside.
        if state.syncedSequenceNumber == 0, current > initialBacklog {
            logger.info("First sync of this patch at sequence \(current), starting from the last \(initialBacklog) records")
            state.syncedSequenceNumber = current - initialBacklog
        }

        let synced = state.syncedSequenceNumber
        guard synced < current else {
            logger.debug("Records up to date (sequence \(current))")
            return false
        }

        let last = min(current, synced + trigger.maxRecords, through ?? .max)
        guard synced < last else {
            logger.debug("Records up to \(last) read already")
            return false
        }
        logger.info("Syncing records \(synced + 1)...\(last) (patch is at \(current), \(trigger.rawValue))")

        let store = pumpManager.recordStore
        defer { store.finishedSync() }

        var badInARow = 0

        for sequence in synced + 1 ... last {
            // They share the link: whatever is left is read next time
            if trigger != .beforeStop, pumpManager.isCommandActive || state.bolusDose != nil {
                logger.info("Stopping at record \(sequence), a command needs the link")
                return false
            }

            // The cursor can run ahead of this loop, following a record that came back with a later number
            guard sequence > state.syncedSequenceNumber else {
                continue
            }

            // The session ended meanwhile: its records are moot
            guard state.patchId == patchId else {
                logger.warning("The patch session changed during the record sync, stopping")
                return false
            }

            store.setStatus(.syncing(sequence: sequence, upTo: last))

            // Not while a command holds the link, nor once one has started meanwhile
            let result = pumpManager.withCommandLockIfFree { () -> ReadResult? in
                guard trigger == .beforeStop || !pumpManager.isCommandActive else {
                    return nil
                }
                // Right after a command, the loop's bolus right behind it: a record may hold it up no longer than as a temp
                // basal ends, asked for once
                guard trigger != .tempBasalEnds else {
                    return readOnce(sequence, patchId: patchId, pumpManager: pumpManager, timeout: MedtrumPumpManager.tempBasalEndRecordTimeout)
                }
                return read(sequence, patchId: patchId, pumpManager: pumpManager)
            }
            guard let result = result ?? nil else {
                logger.info("Stopping at record \(sequence), a command holds the link")
                return false
            }

            // The session ended while it was read - a base reset, a stop: not this session's to keep
            guard state.patchId == patchId else {
                logger.warning("The patch session changed while record \(sequence) was read, stopping")
                return false
            }

            switch result {
            case let .linkLost(error):
                logger.warning("Aborting record sync at \(sequence): \(error.errorDescription)")
                store.setStatus(.failed("Aborted at \(sequence): \(error.errorDescription)"))
                return true

            case let .bad(problem) where trigger == .tempBasalEnds:
                // Asked for once only: the next sync asks again, and skips it if it has to
                logger.warning("Stopping at record \(sequence), unreadable: \(problem)")
                store.setStatus(.failed("Record \(sequence): \(problem)"))
                return true

            case let .bad(problem):
                badInARow += 1
                logger.error("Skipping record \(sequence), unreadable twice (\(badInARow) in a row): \(problem)")
                store.setStatus(.failed("Record \(sequence): \(problem)"))
                pumpManager.noteSkippedRecord(sequence)
                // Given up on: a temp basal ended open that it would have finished goes final without it, before the
                // cursor moves past it
                pumpManager.settleOpenTempBasalEndsRead(through: sequence)
                state.syncedSequenceNumber = max(state.syncedSequenceNumber, sequence)

                if badInARow >= maxBadRecordsInARow {
                    logger.error("Giving up on record sync after \(badInARow) bad records in a row")
                    return true
                }

            case let .record(response):
                badInARow = 0
                apply(response, requested: sequence, current: current, patchId: patchId, pumpManager: pumpManager)
            }
        }

        if last < current {
            logger.info("Stopped at \(last), \(current - last) records left for the next sync")
        }

        return false
    }

    /// Reconciles a record read off the patch - unless it was applied already (`outcome`) - stores it for the debug
    /// screen, and moves the cursor past it - after what it finalizes has been handed to the host
    private static func apply(
        _ response: GetRecordResponse,
        requested: Int,
        current: Int,
        patchId: Data,
        pumpManager: MedtrumPumpManager,
        outcome applied: String? = nil
    ) {
        let isOurs = isSamePatch(response.patchId, patchId.toUInt64())
        // Another kind's at a bolus's answered number - a temp basal's it settled as it ended among them
        if isOurs {
            pumpManager.noteAnsweredBolusRecordTaken(by: response)
        }
        let outcome = applied ?? (isOurs ? pumpManager.reconcile(response) : "not this patch's record")
        log(
            response,
            requested: requested,
            expectedPatchId: patchId.toUInt64(),
            outcome: outcome,
            patchUTCOffset: pumpManager.state.patchUTCOffset,
            to: pumpManager.recordStore
        )
        // A bolus whose command went unanswered keeps track of the records read in order since it went out
        pumpManager.noteRecordRead(response.sequence, requested: requested, isOurs: isOurs)

        let next = cursorAfterReading(reported: response.sequence, requested: requested, current: current)
        if next != response.sequence {
            logger.warning("Record \(requested) came back numbered \(response.sequence), moving the cursor to \(next)")
        }

        let state = pumpManager.state
        guard state.patchId == patchId else {
            return
        }
        // A temp basal ended open whose last record this is, or one before, and that it did not finish, goes final
        // without it - see `MedtrumPumpManager.openTempBasalEnds`
        pumpManager.settleOpenTempBasalEndsRead(through: next)
        state.syncedSequenceNumber = max(state.syncedSequenceNumber, next)
    }

    /// Reads the records the patch wrote for a temp basal of ours as it ended, up to the last one it named, and has it
    /// reported final with what followed it - see `MedtrumPumpManager.TempBasalEnd`. On the caller's thread, which may
    /// block on the link, holding the command lock: a full status's, or the end queue's. A run in progress is waited
    /// out: it yields between two records to the lock held here. Each record is asked for once: on the first that can't
    /// be read, or the first that is not the one asked for, it stops, and our estimate stands in. Not while a bolus
    /// runs: its notifications and a cancel have the link - read once it is over
    /// (`MedtrumPumpManager.readsTempBasalEndAfterBolus`).
    static func finishTempBasalEnd(pumpManager: MedtrumPumpManager) {
        guard let ending = pumpManager.pendingTempBasalEnd else {
            return
        }
        // A bolus running - a halt's notification ahead of its completion: read once it is over
        if pumpManager.readsTempBasalEndAfterBolus(ending) {
            return
        }
        guard mayRead(ending, pumpManager: pumpManager) else {
            return
        }

        guard beginWaiting(nil, timeout: beforeStopWait) else {
            _ = pumpManager.settleTempBasalEnd(ending, records: [], unread: "a record sync held the link")
            return
        }
        defer { end() }

        finishTempBasalEndInFlight(
            pumpManager: pumpManager,
            until: pumpManager.now().addingTimeInterval(MedtrumPumpManager.tempBasalEndReadBudget)
        )
    }

    /// The same, on a command's own thread, holding the command lock: no other command comes between its answer and
    /// these reads. They end by `deadline`. A run in progress stops at its next record, seeing the command: it is given
    /// `inCommandRunWait` of that time to, then our estimate stands in.
    static func finishTempBasalEnd(pumpManager: MedtrumPumpManager, inCommandUntil deadline: Date) {
        guard let ending = pumpManager.pendingTempBasalEnd, mayRead(ending, pumpManager: pumpManager) else {
            return
        }

        let wait = min(inCommandRunWait, max(0, deadline.timeIntervalSince(pumpManager.now())))
        guard beginWaiting(nil, timeout: wait) else {
            _ = pumpManager.settleTempBasalEnd(ending, records: [], unread: "a record sync was running")
            return
        }
        defer { end() }

        finishTempBasalEndInFlight(pumpManager: pumpManager, until: deadline)
    }

    /// How long a command's read waits for a run in progress to stop - the loop's own sync, say, that its follow-up
    /// started just before
    static let inCommandRunWait: TimeInterval = 1.5

    /// Whether the records of `ending` would be read now: it names its last - or the temp basals ended open before it
    /// do, see `MedtrumPumpManager.lastRecordToRead` - and no bolus runs. Those of the temp basals ended open before it are
    /// read with them, numbered before.
    static func wouldRead(_ ending: MedtrumPumpManager.TempBasalEnd, pumpManager: MedtrumPumpManager) -> Bool {
        pumpManager.lastRecordToRead(for: ending) != nil && pumpManager.state.bolusDose == nil
    }

    /// Whether the records of `ending` are to be read at all - if not, it is settled from our estimate here. Not yet
    /// while it waits for a status to name its last record (`TempBasalEnd.awaitsRecord`): read once one does.
    private static func mayRead(_ ending: MedtrumPumpManager.TempBasalEnd, pumpManager: MedtrumPumpManager) -> Bool {
        guard !ending.awaitsRecord else {
            logger.debug("The records of the temp basal of \(ending.dose.startDate) are read once a status names its last")
            return false
        }
        guard wouldRead(ending, pumpManager: pumpManager) else {
            _ = pumpManager.settleTempBasalEnd(
                ending,
                records: [],
                unread: pumpManager.lastRecordToRead(for: ending) == nil ? "no record of its end is known" : "a bolus is running"
            )
            return false
        }
        return true
    }

    /// `finishTempBasalEnd`, the run already this one's, reading until `deadline` on the manager's clock
    private static func finishTempBasalEndInFlight(pumpManager: MedtrumPumpManager, until deadline: Date) {
        // Its last record named by a status yet to come: read then - not settled here meanwhile
        guard let ending = pumpManager.pendingTempBasalEnd, !ending.awaitsRecord else {
            return
        }
        pumpManager.noteTempBasalEndReadBegins(ending)

        let state = pumpManager.state
        let patchId = state.patchId
        let store = pumpManager.recordStore
        var records: [GetRecordResponse] = []
        var unread: String?

        // Off a command, the patch suspended: longer, for a slow link - see `tempBasalEndSuspendedReadBudget`
        let suspendedDeadline = max(
            deadline,
            pumpManager.now().addingTimeInterval(MedtrumPumpManager.tempBasalEndSuspendedReadBudget)
        )

        if let last = pumpManager.lastRecordToRead(for: ending), !patchId.isEmpty {
            let first = state.syncedSequenceNumber + 1

            if last < first {
                unread = "its record \(last) was read before it ended"
            } else if last - first >= MedtrumPumpManager.tempBasalEndMaxRecords {
                unread = "records \(first)...\(last) are too many to read now"
            } else {
                logger.info("Reading records \(first)...\(last), of the temp basal of \(ending.dose.startDate) that ended")

                reading: for sequence in first ... last {
                    // Less than a round trip left, and the record would be asked for only to be given up on
                    let longer = pumpManager.readsLongerAsTempBasalEnds
                    let left = (longer ? suspendedDeadline : deadline).timeIntervalSince(pumpManager.now())
                    guard left >= MedtrumPumpManager.tempBasalEndRecordReadMinimum else {
                        let budget = longer ? MedtrumPumpManager.tempBasalEndSuspendedReadBudget : MedtrumPumpManager.tempBasalEndReadBudget
                        unread = "the \(Int(budget)) s to read them ran out at \(sequence)"
                        break reading
                    }

                    store.setStatus(.syncing(sequence: sequence, upTo: last))

                    let timeout = min(left, MedtrumPumpManager.tempBasalEndRecordTimeout)
                    switch readOnce(sequence, patchId: patchId, pumpManager: pumpManager, timeout: timeout) {
                    case let .record(response):
                        guard response.sequence == sequence, isSamePatch(response.patchId, patchId.toUInt64()) else {
                            unread = "record \(sequence) came back as \(response.sequence) of patch \(response.patchId)"
                            break reading
                        }
                        records.append(response)

                        // Its own records read, adding up to where it is shown to have ended: the ones after them say
                        // nothing of it - left to the sync
                        if sequence < last, pumpManager.settlesTempBasalEnd(ending, records: records) {
                            logger.info(
                                "Record(s) up to \(sequence) settle the temp basal of \(ending.dose.startDate), " +
                                    "\(sequence + 1)...\(last) are left to the sync"
                            )
                            break reading
                        }

                    case let .bad(problem):
                        unread = "record \(sequence): \(problem)"
                        break reading

                    case let .linkLost(error):
                        unread = "record \(sequence): \(error.errorDescription)"
                        break reading
                    }
                }

                if let unread {
                    logger.warning("Stopped reading the records of the temp basal of \(ending.dose.startDate): \(unread)")
                    store.setStatus(.failed(unread))
                }
            }
        } else {
            unread = "no record of its end is known"
        }

        // The session ended meanwhile - a base reset, a stop: these records are moot, and not this session's to keep
        guard state.patchId == patchId else {
            logger.warning("The patch session changed while the records of the temp basal of \(ending.dose.startDate) were read")
            _ = pumpManager.settleTempBasalEnd(ending, records: [], unread: "the patch session changed while they were read")
            return
        }

        let outcomes = pumpManager.settleTempBasalEnd(ending, records: records, unread: unread)

        // As a sync would: stored, and the cursor past them - after the final went out
        for response in records {
            apply(
                response,
                requested: response.sequence,
                current: state.currentSequenceNumber,
                patchId: patchId,
                pumpManager: pumpManager,
                outcome: outcomes[response.sequence]
            )
        }
        if !records.isEmpty, unread == nil {
            store.finishedSync()
        }
    }

    /// Reads the records from the cursor up to `last`, in order, on a command's own thread, holding the command lock,
    /// and reconciles each as a sync would - every one: a bolus's between the cursor and `last` is not skipped. For
    /// `what`, its record among them. Each is asked for once, `tempBasalEndRecordTimeout` at most, all of them by
    /// `deadline`; on the first that can't be read it stops - the rest are left to the sync. A run in progress stops at
    /// its next record, seeing the command: it is given `inCommandRunWait` to. Not more than `tempBasalEndMaxRecords`.
    static func readInCommand(pumpManager: MedtrumPumpManager, through last: Int, until deadline: Date, of what: String) {
        let state = pumpManager.state
        let patchId = state.patchId
        let first = state.syncedSequenceNumber + 1
        guard !patchId.isEmpty, first <= last else {
            return
        }
        guard last - first < MedtrumPumpManager.tempBasalEndMaxRecords else {
            logger.info("Records \(first)...\(last) are too many to read in the command, of \(what): left to the sync")
            return
        }

        // A temp basal's record unnamed may be among them: left to the sync, which reads them once it is named
        if let ending = pumpManager.pendingTempBasalEnd, ending.awaitsRecord {
            logger.info(
                "The temp basal of \(ending.dose.startDate) waits for a status to name its record: the records of \(what) " +
                    "are left to the sync"
            )
            return
        }

        let wait = min(inCommandRunWait, max(0, deadline.timeIntervalSince(pumpManager.now())))
        guard beginWaiting(nil, timeout: wait) else {
            logger.warning("A record sync was running: the records of \(what) are left to the next")
            return
        }
        defer { end() }

        logger.info("Reading records \(first)...\(last) in the command, of \(what)")
        let store = pumpManager.recordStore
        var unread: String?

        reading: for sequence in first ... last {
            // The cursor can run ahead, following a record that came back with a later number
            guard sequence > state.syncedSequenceNumber else {
                continue
            }
            let left = deadline.timeIntervalSince(pumpManager.now())
            guard left >= MedtrumPumpManager.tempBasalEndRecordReadMinimum else {
                unread = "the \(Int(MedtrumPumpManager.tempBasalEndReadBudget)) s to read them ran out at \(sequence)"
                break reading
            }

            store.setStatus(.syncing(sequence: sequence, upTo: last))
            let timeout = min(left, MedtrumPumpManager.tempBasalEndRecordTimeout)
            switch readOnce(sequence, patchId: patchId, pumpManager: pumpManager, timeout: timeout) {
            case let .record(response):
                // The session ended while it was read: not this session's to keep
                guard state.patchId == patchId else {
                    unread = "the patch session changed while record \(sequence) was read"
                    break reading
                }
                apply(response, requested: sequence, current: state.currentSequenceNumber, patchId: patchId, pumpManager: pumpManager)

            case let .bad(problem):
                unread = "record \(sequence): \(problem)"
                break reading

            case let .linkLost(error):
                unread = "record \(sequence): \(error.errorDescription)"
                break reading
            }
        }

        if let unread {
            logger.warning("Stopped reading the records of \(what): \(unread) - left to the sync")
            store.setStatus(.failed(unread))
        } else {
            store.finishedSync()
        }
    }

    private enum ReadResult {
        case record(GetRecordResponse)
        /// The patch answered twice with nothing we can use: an error code, a garbled answer, a record that does not parse
        case bad(String)
        /// No answer: the link is gone or unresponsive
        case linkLost(MedtrumWriteError)
    }

    /// One record, asked for once more if it comes back unreadable
    private static func read(_ sequence: Int, patchId: Data, pumpManager: MedtrumPumpManager) -> ReadResult {
        var result = ReadResult.bad("not read")

        for attempt in 1 ... 2 {
            result = readOnce(sequence, patchId: patchId, pumpManager: pumpManager)

            guard case let .bad(problem) = result else {
                return result
            }
            logger.warning("Record \(sequence) unreadable (attempt \(attempt)): \(problem)")
        }

        return result
    }

    private static func readOnce(
        _ sequence: Int,
        patchId: Data,
        pumpManager: MedtrumPumpManager,
        timeout: TimeInterval? = nil
    ) -> ReadResult {
        guard let link = pumpManager.link else {
            return .linkLost(.noManager)
        }

        switch link.write(GetRecordPacket(recordIndex: sequence, patchId: patchId.toUInt64()), timeout: timeout) {
        case let .failure(error):
            switch error {
            case .noManager,
                 .noWriteCharacteristic,
                 .notConnected,
                 .timeout:
                return .linkLost(error)

            case .alreadyRunning,
                 .invalidData,
                 .invalidResponse,
                 .noData:
                return .bad(error.errorDescription)
            }

        case let .success(data):
            guard let response = data as? GetRecordResponse else {
                return .bad("invalid response")
            }

            switch response.record {
            case .invalid:
                return .bad("invalid record header")
            case let .truncated(type, size):
                return .bad("record type \(type) too short to parse (\(size) bytes)")
            case .basal,
                 .bolus,
                 .event,
                 .tdd,
                 .unhandled:
                return .record(response)
            }
        }
    }

    /// Whether a record's patch id is that of `patchId`. A record carries only the low two bytes of it.
    static func isSamePatch(_ recordPatchId: UInt64, _ patchId: UInt64) -> Bool {
        recordPatchId & 0xFFFF == patchId & 0xFFFF
    }

    /// Where the cursor goes after reading record `requested`: on to the number the record carries if that is further
    /// on - the same trick AndroidAPS uses - but never short of `requested`. A record answered with a lower number (a
    /// stale slot) or one out of range must not hold it back, or the same record is read forever.
    static func cursorAfterReading(reported: Int, requested: Int, current: Int) -> Int {
        reported > requested && reported <= max(current, requested) ? reported : requested
    }

    // MARK: - Matching

    /// Amounts compared in the patch's 0.05 U steps
    static func steps(_ units: Double) -> Int {
        Int((units / 0.05).rounded())
    }

    /// Whether the response to SetTempBasal describes the temp basal it set, at `rate`: only then is the patch running
    /// what we asked for, and its start the patch's start of it
    static func isCommandedTempBasal(_ response: SetTempBasalResponse, rate: Double) -> Bool {
        response.basalType == .ABSOLUTE_TEMP && steps(response.basalValue) == steps(rate)
    }

    // MARK: - Fallback

    /// Why a dose waiting on its record is given up on
    enum FallbackRule: Equatable {
        /// Every record the patch told of after the dose ended was read, a while after it ended, and none was its
        case noRecord
        /// It waited too long for records that could not be read
        case maximumWait

        var description: String {
            switch self {
            case .noRecord:
                return "no record \(Int(MedtrumPumpManager.awaitingRecordTimeout / 60)) min after it ended, with every record read"
            case .maximumWait:
                return "no record \(Int(MedtrumPumpManager.awaitingRecordMaximumWait / 60)) min after it ended"
            }
        }
    }

    /// Which rule gives up on a dose waiting on its record since `since` - when it ended - nil if none does: caught up
    /// (the cursor at the newest record the patch told of after `since`, see `MedtrumPumpManager.isCaughtUp`) and
    /// `awaitingRecordTimeout`, or `awaitingRecordMaximumWait` whatever is left to read
    static func fallbackRule(since: Date, caughtUp: Bool, now: Date) -> FallbackRule? {
        let waited = now.timeIntervalSince(since)

        if caughtUp, waited >= MedtrumPumpManager.awaitingRecordTimeout {
            return .noRecord
        }

        if waited >= MedtrumPumpManager.awaitingRecordMaximumWait {
            return .maximumWait
        }

        return nil
    }

    private static func log(
        _ response: GetRecordResponse,
        requested: Int,
        expectedPatchId: UInt64,
        outcome: String?,
        patchUTCOffset: TimeInterval?,
        to store: PumpRecordStore
    ) {
        let prefix = "record \(response.sequence)"

        if response.sequence != requested {
            logger.warning("Requested record \(requested) but got \(response.sequence)")
        }

        if !isSamePatch(response.patchId, expectedPatchId) {
            logger.warning("\(prefix): patch id \(response.patchId), expected \(expectedPatchId)")
        }

        let (kind, summary, label, eventDate) = describe(response.record)
        logger.info("\(prefix) \(kind): \(summary)")

        let phoneOffset = TimeInterval(TimeZone.current.secondsFromGMT())
        if let mismatch = timeZoneMismatch(of: response.record, patchUTCOffset: patchUTCOffset, phoneOffset: phoneOffset) {
            logger.warning("\(prefix): \(mismatch)")
        }

        store.store(StoredPumpRecord(
            id: response.sequence,
            fetchedAt: Date.now,
            kind: kind,
            summary: summary,
            label: label,
            eventDate: eventDate,
            outcome: outcome
        ))
    }

    /// The patch keeps the time zone it was given - at activation, or a time sync - which a DST change since does not
    /// move: its TDD and daily snapshot fall on its midnight. A record's zone is compared with the one we last set on the
    /// patch - `patchUTCOffset`, what patch-midnight splits go by (`MedtrumPumpManager.crossesPatchMidnight`) - or, with
    /// none known, the one we would set: the phone's, as `SetTimeZonePacket` sends it (past UTC+12 a day less). Told of
    /// in the log only. Nil if `record` has no time zone, or it is that one. Offsets are east of UTC.
    static func timeZoneMismatch(of record: PumpRecord, patchUTCOffset: TimeInterval?, phoneOffset: TimeInterval) -> String? {
        let offset: Int
        switch record {
        case let .tdd(tdd):
            offset = tdd.signedTimeZoneOffset
        case let .event(.dailySnapshot(snapshot)):
            offset = snapshot.timeZoneOffset
        default:
            return nil
        }

        let phone = Int(phoneOffset / 60)
        let phoneAsSet = Int(SetTimeZonePacket.patchOffset(phoneOffset) / 60)
        let expected = patchUTCOffset.map { Int($0 / 60) } ?? phoneAsSet

        guard offset != expected else {
            return nil
        }

        let set = patchUTCOffset.map { "the one set on the patch \(offsetText(Int($0 / 60)))" } ?? "none known set on the patch"
        let phoneText = "the phone's \(offsetText(phone))" + (phoneAsSet != phone ? ", set on a patch as \(offsetText(phoneAsSet))" : "")
        return "the record's time-zone offset is \(offsetText(offset)), \(set), \(phoneText)"
    }

    /// An offset as "120 min (UTC+2)"
    private static func offsetText(_ offset: Int) -> String {
        "\(offset) min (\(utcOffset(offset)))"
    }

    /// Flattens a record into what both the log and the debug screen want: what kind it is, its fields as one line,
    /// what an event record is in words, and when the patch says it happened.
    static func describe(_ record: PumpRecord) -> (kind: String, summary: String, label: String?, eventDate: Date?) {
        switch record {
        case let .bolus(bolus):
            let fields: [String] = [
                "type=\(bolus.type)",
                "wizard=\(bolus.wizard)",
                "cause=\(bolus.cause)",
                "start=\(format(bolus.startTime))",
                "requested=\(units(bolus.normalAmount))",
                "delivered=\(units(bolus.normalDelivered))",
                "extended=\(units(bolus.extendedAmount))/\(minutes(bolus.extendedDuration))",
                "extendedDelivered=\(units(bolus.extendedDelivered))",
                "carbs=\(bolus.carbs)",
                "glucose=\(bolus.glucose)",
                "iob=\(bolus.iob)"
            ]
            return ("BOLUS", fields.joined(separator: " "), nil, bolus.startTime)

        case let .basal(basal):
            let endReason: String = basal.endReason.map { "\($0)" } ?? "unknown(\(basal.rawEndReason))"
            let fields: [String] = [
                "type=\(basal.type)",
                "endReason=\(endReason)",
                "start=\(format(basal.startTime))",
                "end=\(format(basal.endTime))",
                "duration=\(minutes(basal.duration))",
                "rate=\(units(basal.rate))/h",
                "percent=\(basal.percent)",
                "delivered=\(units(basal.delivered))"
            ]
            return ("BASAL", fields.joined(separator: " "), nil, basal.startTime)

        case let .tdd(tdd):
            let fields: [String] = [
                "timestamp=\(format(tdd.timestamp))",
                "minutes=\(tdd.minutes)",
                "tzOffset=\(tdd.signedTimeZoneOffset)",
                "total=\(units(Double(tdd.total)))",
                "basal=\(units(Double(tdd.basal)))",
                "bolus=\(units(Double(tdd.bolus)))",
                "glucose=\(tdd.glucose)"
            ]
            return ("TDD", fields.joined(separator: " "), nil, tdd.timestamp)

        case let .event(.alarm(alarm)):
            let fields: [String] = [
                "\(alarm.name ?? "alarm bit \(alarm.bit)") (bit \(alarm.bit))",
                "age=\(alarm.patchAge)s",
                "time=\(format(alarm.timestamp))",
                "unknown=\(alarm.unknown1)/\(alarm.unknown2)"
            ]
            return ("ALARM", fields.joined(separator: " "), label(of: alarm), alarm.timestamp)

        case let .event(.resumed(resumed)):
            return ("RESUMED", "time=\(format(resumed.timestamp))", "Delivery resumed", resumed.timestamp)

        case let .event(.dailySnapshot(snapshot)):
            let fields: [String] = [
                "time=\(format(snapshot.timestamp))",
                "tzOffset=\(snapshot.timeZoneOffset)",
                String(format: "a=%.3f", snapshot.a),
                String(format: "b=%.3f", snapshot.b)
            ]
            return (
                "DAILY",
                fields.joined(separator: " "),
                "Daily snapshot · \(utcOffset(snapshot.timeZoneOffset))",
                snapshot.timestamp
            )

        case let .event(.baseCounters(base)):
            let fields: [String] = [
                "time=\(format(base.timestamp))",
                "lifetime=\(units(base.lifetimeInsulin))",
                "hours=\(base.operatingHours)",
                "patches=\(base.patchesUsed)"
            ]
            let lifetime = groupedFormatter.string(from: NSNumber(value: base.lifetimeWholeUnits)) ?? "-"
            return (
                "BASE",
                fields.joined(separator: " "),
                "Base: \(lifetime) U · \(base.operatingHours) h · \(base.patchesUsed) patches",
                base.timestamp
            )

        case let .unhandled(type):
            return ("UNHANDLED", "\(GetRecordPacket.name(forRecordType: type)) (record type \(type))", nil, nil)

        case let .truncated(type, size):
            return (
                "TRUNCATED",
                "\(GetRecordPacket.name(forRecordType: type)) (record type \(type)) is too short to parse (\(size) bytes)",
                nil,
                nil
            )

        case .invalid:
            return ("INVALID", "invalid record header", nil, nil)
        }
    }

    /// An alarm in words, with the patch's age: how far into its life the patch raised it
    private static func label(of alarm: AlarmRecord) -> String {
        let name = alarm.name.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Alarm bit \(alarm.bit)"
        return name + String(format: " · patch age %.1f h", Double(alarm.patchAge) / 3600)
    }

    /// Minutes east of UTC as "UTC+2", "UTC-3:30"
    static func utcOffset(_ minutes: Int) -> String {
        let sign = minutes < 0 ? "-" : "+"
        let hours = abs(minutes) / 60
        let rest = abs(minutes) % 60
        return "UTC\(sign)\(hours)" + (rest == 0 ? "" : String(format: ":%02d", rest))
    }

    /// Thousands grouped the English way, as the rest of the record screen is: "11,419"
    private static let groupedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func units(_ value: Double) -> String {
        String(format: "%.2fU", value)
    }

    private static func minutes(_ duration: TimeInterval) -> String {
        String(format: "%.1fmin", duration / 60)
    }
}

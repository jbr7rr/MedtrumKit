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
    static let logger = MedtrumLogger(category: "RecordSyncer")

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
    static let beforeStopWait: TimeInterval = 35

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
    static func beginWaiting(_ trigger: Trigger?, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while begin(trigger) != .began {
            guard Date.now < deadline else {
                return false
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        return true
    }

    static func end() {
        runState.mutate { $0.isRunning = false }
    }

    /// A run holds the single flight: a sync, a temp basal's end being read - the history's fill gives way to it
    /// (`MedtrumPumpManager.readMissingRecords`)
    static var isRunning: Bool {
        runState.value.isRunning
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

        // What this run read, in its patch's history file: one write a run
        pumpManager.recordHistory?.commit()

        // Needs no link, so it runs either way - read through the newest, the last skipped: the record kept from the
        // backlog for the bolus the released driver had in flight may be its own now
        pumpManager.settleReleasedBolusBacklogRecord()
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
                // Turned away, it read nothing more: no run of the cooldown's, as for a command in flight
                if trigger == .awaitingDoses {
                    runState.mutate { $0.lastAwaitingDosesRun = .distantPast }
                }
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
    static func apply(
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
        // Kept in the patch's history file - another patch's record is not of this one's history
        if isOurs {
            pumpManager.recordHistory?.append(response, patchId: patchId.toUInt64(), outcome: outcome)
        }
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
        // Read through the newest: the record kept from the backlog for the bolus the released driver had in flight may
        // be its own now
        pumpManager.settleReleasedBolusBacklogRecord()
    }

    enum ReadResult {
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

    static func readOnce(
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
}

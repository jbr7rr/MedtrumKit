import Foundation
import LoopKit

/// Reads the patch's own event log, and finalizes the doses waiting on it.
///
/// The patch writes a numbered record when a delivery event ends - a bolus, a basal segment - with what it really
/// delivered. A finished bolus stays mutable for the host (`MedtrumPumpState.awaitingRecord`) until its record has been
/// read here and finalizes it (`MedtrumPumpManager.reconcile`) - or until a fallback gives up on it. A temp basal's
/// records are read as it ends, and finalize it then (`finishTempBasalEnd`).
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
        /// A heartbeat between full syncs, while doses wait on records the patch has written (or on their timeout)
        case awaitingDoses = "awaiting doses"
        /// Right before the patch is stopped: the last chance to read this session's records
        case beforeStop = "before stop"

        /// One run reads at most this many records and leaves the rest to the next, so a backlog can't hold the link
        var maxRecords: Int {
            switch self {
            case .loopSync:
                return 3
            case .awaitingDoses,
                 .fullSync:
                return 10
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
    }

    private static let runState = Locked(RunState())

    /// For tests: the run state is global rather than per manager, so a sync one test left running would otherwise turn
    /// away the next test's
    static func resetForTesting() {
        runState.value = RunState()
    }

    /// For tests: `body` runs as a sync run would, holding the single flight
    static func whileRunningForTesting(_ body: () -> Void) {
        guard begin(nil) else {
            preconditionFailure("A record sync is running already")
        }
        defer { end() }
        body()
    }

    /// Single flight, and throttled for the heartbeat trigger
    private static func begin(_ trigger: Trigger?) -> Bool {
        let now = Date.now
        var began = false

        runState.mutate { state in
            guard !state.isRunning else {
                return
            }

            if trigger == .awaitingDoses {
                guard now.timeIntervalSince(state.lastAwaitingDosesRun) >= awaitingDosesInterval else {
                    return
                }
                state.lastAwaitingDosesRun = now
            }

            state.isRunning = true
            began = true
        }

        return began
    }

    /// Waits out a run in progress rather than skipping it: it yields between two records to the command this runs for
    private static func beginWaiting(_ trigger: Trigger?, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)

        while !begin(trigger) {
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

    /// Reads the records the patch has written since the last call, and finalizes the doses they match - then, whether
    /// it could read or not, the doses that have waited for theirs long enough.
    static func syncRecords(pumpManager: MedtrumPumpManager, trigger: Trigger = .fullSync) {
        // Needs neither the link nor a patch: the host has yet to confirm finals of earlier doses
        pumpManager.resendUnacknowledgedFinalsIfDue()

        let state = pumpManager.state
        guard !state.patchId.isEmpty, !state.pumpState.isSetup else {
            return
        }

        let began = trigger == .beforeStop ? beginWaiting(trigger, timeout: beforeStopWait) : begin(trigger)
        guard began else {
            logger.debug("Record sync already running or ran moments ago, skipping (\(trigger.rawValue))")
            return
        }
        defer { end() }

        let syncedBefore = state.syncedSequenceNumber

        // A bolus record is only written once the bolus is over, and while it runs the link belongs to its
        // notifications - and to a cancel. The before-stop read runs inside the stop command.
        if state.bolusDose != nil {
            logger.debug("Not reading records (\(trigger.rawValue)): a bolus is running")
        } else if trigger != .beforeStop, pumpManager.isCommandActive {
            logger.debug("Not reading records (\(trigger.rawValue)): a command is in flight")
        } else {
            // A temp basal that ended has its records read first: read here, they would make no final of it
            _ = pumpManager.withCommandLockIfFree {
                finishTempBasalEndInFlight(pumpManager: pumpManager, until: pumpManager.now().addingTimeInterval(
                    MedtrumPumpManager.tempBasalEndReadBudget
                ))
            }
            readNewRecords(pumpManager: pumpManager, trigger: trigger)
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
        guard begin(nil) else {
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
    /// skipped in a row end the run.
    private static func readNewRecords(pumpManager: MedtrumPumpManager, trigger: Trigger) {
        let state = pumpManager.state
        let current = state.currentSequenceNumber
        let patchId = state.patchId

        guard current > 0 else {
            logger.debug("No record sequence known yet, nothing to sync")
            return
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
            return
        }

        let last = min(current, synced + trigger.maxRecords)
        logger.info("Syncing records \(synced + 1)...\(last) (patch is at \(current), \(trigger.rawValue))")

        let store = pumpManager.recordStore
        defer { store.finishedSync() }

        var badInARow = 0

        for sequence in synced + 1 ... last {
            // They share the link: whatever is left is read next time
            if trigger != .beforeStop, pumpManager.isCommandActive || state.bolusDose != nil {
                logger.info("Stopping at record \(sequence), a command needs the link")
                return
            }

            // The cursor can run ahead of this loop, following a record that came back with a later number
            guard sequence > state.syncedSequenceNumber else {
                continue
            }

            // The session ended meanwhile: its records are moot
            guard state.patchId == patchId else {
                logger.warning("The patch session changed during the record sync, stopping")
                return
            }

            store.setStatus(.syncing(sequence: sequence, upTo: last))

            // Not while a command holds the link, nor once one has started meanwhile
            let result = pumpManager.withCommandLockIfFree { () -> ReadResult? in
                guard trigger == .beforeStop || !pumpManager.isCommandActive else {
                    return nil
                }
                return read(sequence, patchId: patchId, pumpManager: pumpManager)
            }
            guard let result = result ?? nil else {
                logger.info("Stopping at record \(sequence), a command holds the link")
                return
            }

            switch result {
            case let .linkLost(error):
                logger.warning("Aborting record sync at \(sequence): \(error.errorDescription)")
                store.setStatus(.failed("Aborted at \(sequence): \(error.errorDescription)"))
                return

            case let .bad(problem):
                badInARow += 1
                logger.error("Skipping record \(sequence), unreadable twice (\(badInARow) in a row): \(problem)")
                store.setStatus(.failed("Record \(sequence): \(problem)"))
                pumpManager.noteSkippedRecord(sequence)
                state.syncedSequenceNumber = max(state.syncedSequenceNumber, sequence)

                if badInARow >= maxBadRecordsInARow {
                    logger.error("Giving up on record sync after \(badInARow) bad records in a row")
                    return
                }

            case let .record(response):
                badInARow = 0
                apply(response, requested: sequence, current: current, patchId: patchId, pumpManager: pumpManager)
            }
        }

        if last < current {
            logger.info("Stopped at \(last), \(current - last) records left for the next sync")
        }
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
        let outcome = applied ?? (isOurs ? pumpManager.reconcile(response) : "not this patch's record")
        log(response, requested: requested, expectedPatchId: patchId.toUInt64(), outcome: outcome, to: pumpManager.recordStore)
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
        state.syncedSequenceNumber = max(state.syncedSequenceNumber, next)
    }

    /// Reads the records the patch wrote for a temp basal of ours as it ended, up to the last one it named, and has it
    /// reported final with what followed it - see `MedtrumPumpManager.TempBasalEnd`. On the caller's thread, which may
    /// block on the link, holding the command lock: a full status's, or the end queue's. A run in progress is waited
    /// out: it yields between two records to the lock held here. Each record is asked for once: on the first that can't
    /// be read, or the first that is not the one asked for, it stops, and our estimate stands in. Not while a bolus
    /// runs: its notifications and a cancel have the link.
    static func finishTempBasalEnd(pumpManager: MedtrumPumpManager) {
        guard let ending = pumpManager.pendingTempBasalEnd, mayRead(ending, pumpManager: pumpManager) else {
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

    /// Whether the records of `ending` would be read now: it names its last, and no bolus runs
    static func wouldRead(_ ending: MedtrumPumpManager.TempBasalEnd, pumpManager: MedtrumPumpManager) -> Bool {
        ending.lastRecord != nil && pumpManager.state.bolusDose == nil
    }

    /// Whether the records of `ending` are to be read at all - if not, it is settled from our estimate here
    private static func mayRead(_ ending: MedtrumPumpManager.TempBasalEnd, pumpManager: MedtrumPumpManager) -> Bool {
        guard wouldRead(ending, pumpManager: pumpManager) else {
            _ = pumpManager.settleTempBasalEnd(
                ending,
                records: [],
                unread: ending.lastRecord == nil ? "no record of its end is known" : "a bolus is running"
            )
            return false
        }
        return true
    }

    /// `finishTempBasalEnd`, the run already this one's, reading until `deadline` on the manager's clock
    private static func finishTempBasalEndInFlight(pumpManager: MedtrumPumpManager, until deadline: Date) {
        guard let ending = pumpManager.pendingTempBasalEnd else {
            return
        }

        let state = pumpManager.state
        let patchId = state.patchId
        let store = pumpManager.recordStore
        var records: [GetRecordResponse] = []
        var unread: String?

        if let last = ending.lastRecord, !patchId.isEmpty {
            let first = state.syncedSequenceNumber + 1

            if last < first {
                unread = "its record \(last) was read before it ended"
            } else if last - first >= MedtrumPumpManager.tempBasalEndMaxRecords {
                unread = "records \(first)...\(last) are too many to read now"
            } else {
                logger.info("Reading records \(first)...\(last), of the temp basal of \(ending.dose.startDate) that ended")

                reading: for sequence in first ... last {
                    // Less than a round trip left, and the record would be asked for only to be given up on
                    let left = deadline.timeIntervalSince(pumpManager.now())
                    guard left >= MedtrumPumpManager.tempBasalEndRecordReadMinimum else {
                        unread = "the \(Int(MedtrumPumpManager.tempBasalEndReadBudget)) s to read them ran out at \(sequence)"
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
        to store: PumpRecordStore
    ) {
        let prefix = "record \(response.sequence)"

        if response.sequence != requested {
            logger.warning("Requested record \(requested) but got \(response.sequence)")
        }

        if !isSamePatch(response.patchId, expectedPatchId) {
            logger.warning("\(prefix): patch id \(response.patchId), expected \(expectedPatchId)")
        }

        let (kind, summary, eventDate) = describe(response.record)
        logger.info("\(prefix) \(kind): \(summary)")
        store.store(StoredPumpRecord(
            id: response.sequence,
            fetchedAt: Date.now,
            kind: kind,
            summary: summary,
            eventDate: eventDate,
            outcome: outcome
        ))
    }

    /// Flattens a record into the three things both the log and the debug screen want: what kind it is,
    /// its fields as one line, and when the patch says it happened.
    private static func describe(_ record: PumpRecord) -> (kind: String, summary: String, eventDate: Date?) {
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
            return ("BOLUS", fields.joined(separator: " "), bolus.startTime)

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
            return ("BASAL", fields.joined(separator: " "), basal.startTime)

        case let .tdd(tdd):
            let fields: [String] = [
                "timestamp=\(format(tdd.timestamp))",
                "minutes=\(tdd.minutes)",
                "tzOffset=\(tdd.timeZoneOffset)",
                "total=\(units(Double(tdd.total)))",
                "basal=\(units(Double(tdd.basal)))",
                "bolus=\(units(Double(tdd.bolus)))",
                "glucose=\(tdd.glucose)"
            ]
            return ("TDD", fields.joined(separator: " "), tdd.timestamp)

        case let .unhandled(type):
            return ("UNHANDLED", "\(GetRecordPacket.name(forRecordType: type)) (record type \(type))", nil)

        case let .truncated(type, size):
            return (
                "TRUNCATED",
                "\(GetRecordPacket.name(forRecordType: type)) (record type \(type)) is too short to parse (\(size) bytes)",
                nil
            )

        case .invalid:
            return ("INVALID", "invalid record header", nil)
        }
    }

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

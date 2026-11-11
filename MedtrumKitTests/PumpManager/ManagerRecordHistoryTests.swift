import LoopKit
@testable import MedtrumKit
import XCTest

/// The manager keeps every record the sync reads in its patch's history file (`PatchRecordHistory`), and reads the ones
/// missing on demand (`MedtrumPumpManager.fillRecordHistory`) - to the rules of the review of tomacs's reader: never
/// waiting for the link, never while a bolus runs, only this patch's records, the sync's cursor left alone.
final class ManagerRecordHistoryTests: MedtrumManagerTestCase {
    private static let patch: UInt64 = 236

    /// The record numbers asked for, in order
    private var requestedRecords: [Int] {
        link.writes
            .filter { $0.commandType == CommandType.GET_RECORD }
            .map { Int($0.packet.getRequestBytes().prefix(2).toUInt64()) }
    }

    @discardableResult private func makeHistoryManager(sequence: Int) -> PatchRecordHistory {
        let history = keepRecordHistory()
        makeManager(activePatchState(patchId: Self.patch, scheduledRate: 0.6, sequence: sequence, reservoir: 150))
        return history
    }

    private func scriptAlarmRecord(_ sequence: Int, patchId: UInt64 = ManagerRecordHistoryTests.patch) {
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: sequence, patchId: patchId))
    }

    // MARK: What the sync reads

    /// The records a sync run reads go to the patch's file with what the sync made of them - the text the record screen
    /// shows. Another patch's record is not of this one's history: not kept.
    func testTheSyncKeepsThePatchsRecordsWithTheirOutcomes() async throws {
        let history = makeHistoryManager(sequence: 2)
        pumpManager.state.currentSequenceNumber = 4
        scriptAlarmRecord(3)
        scriptAlarmRecord(4, patchId: 999)

        link.onQueue {
            RecordSyncer.syncRecords(pumpManager: self.pumpManager, trigger: .fullSync)
        }
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 4)

        let records = await pumpManager.historyRecords(forPatch: Self.patch)
        XCTAssertEqual(records.map(\.sequence), [3])
        XCTAssertEqual(records.first?.kind, "ALARM")
        XCTAssertEqual(records.first?.patchId, Self.patch)
        let store = pumpManager.recordStore
        let shown = await MainActor.run { store.records.first { $0.id == 3 } }
        XCTAssertEqual(records.first?.outcome, shown?.outcome)
        XCTAssertEqual(history.patchesWithFiles(), [Self.patch])
    }

    // MARK: The fill

    /// The missing records, newest first, `limit` of them: kept as "history read", matched to nothing - the sync's cursor
    /// where it was, the record screen of the sync untouched
    func testTheFillReadsTheMissingRecordsNewestFirstLeavingTheSyncAlone() async {
        let history = makeHistoryManager(sequence: 5)
        history.append(alarmRecordResponse(sequence: 4, patchId: Self.patch), patchId: Self.patch, outcome: "unmatched")
        let missingBefore = await pumpManager.missingRecordSequences(forPatch: Self.patch)
        XCTAssertEqual(missingBefore, [1, 2, 3, 5])
        scriptAlarmRecord(5)
        scriptAlarmRecord(3)

        let fill = await pumpManager.fillRecordHistory(limit: 2)

        XCTAssertEqual(fill, RecordHistoryFill(read: [5, 3], notKept: [], stop: .limitReached))
        XCTAssertEqual(requestedRecords, [5, 3])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 5)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 5)
        let store = pumpManager.recordStore
        let shown = await MainActor.run { store.records }
        XCTAssertTrue(shown.isEmpty, "not the sync's")

        let records = await pumpManager.historyRecords(forPatch: Self.patch)
        XCTAssertEqual(records.map(\.sequence), [5, 4, 3])
        XCTAssertEqual(records.map(\.outcome), ["history read", "unmatched", "history read"])
        let missingAfter = await pumpManager.missingRecordSequences(forPatch: Self.patch)
        XCTAssertEqual(missingAfter, [1, 2])
    }

    /// Up to the newest the sync went past: the ones after it are the sync's to read
    func testTheFillLeavesTheRecordsTheSyncHasNotReachedToIt() async {
        makeHistoryManager(sequence: 2)
        pumpManager.state.currentSequenceNumber = 4
        scriptAlarmRecord(2)
        scriptAlarmRecord(1)

        let fill = await pumpManager.fillRecordHistory()

        XCTAssertEqual(fill, RecordHistoryFill(read: [2, 1], notKept: [], stop: .done))
        XCTAssertEqual(requestedRecords, [2, 1])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 2)
    }

    /// A bolus runs: the link is its notifications' - nothing asked for
    func testTheFillReadsNothingWhileABolusRuns() {
        makeHistoryManager(sequence: 3)
        let bolus = UnfinalizedDose(units: 1.0, duration: 60, activationType: .manualNoRecommendation, insulinType: nil)
        pumpManager.withDoseReportLock { pumpManager.state.bolusDose = bolus }

        let fill = pumpManager.readMissingRecords()

        XCTAssertEqual(fill, RecordHistoryFill(read: [], notKept: [], stop: .bolusRunning))
        XCTAssertEqual(requestedRecords, [])
        pumpManager.withDoseReportLock { pumpManager.state.bolusDose = nil }
    }

    /// Another operation holds the link: never waited for - nothing asked for
    func testTheFillReadsNothingWhileTheCommandLockIsHeld() {
        makeHistoryManager(sequence: 3)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let manager = pumpManager!
        Thread.detachNewThread {
            manager.commandLock.lock()
            held.signal()
            release.wait()
            manager.commandLock.unlock()
        }
        held.wait()

        let fill = pumpManager.readMissingRecords()
        release.signal()

        XCTAssertEqual(fill, RecordHistoryFill(read: [], notKept: [], stop: .linkBusy))
        XCTAssertEqual(requestedRecords, [])
    }

    /// Answered with another patch's record, or another number: not kept as a record - asked once, the fill goes on; one
    /// unreadable is not kept either. Each noted, as no record: not asked for again.
    func testRecordsThatAreNotTheOnesAskedForAreNotKept() async {
        makeHistoryManager(sequence: 3)
        scriptAlarmRecord(3, patchId: 999)
        scriptAlarmRecord(7)
        link.script(CommandType.GET_RECORD, .garbled(PatchBytes.otherRecord(type: 3, sequence: 1, patchId: Self.patch)))

        let fill = await pumpManager.fillRecordHistory()

        XCTAssertEqual(fill, RecordHistoryFill(read: [], notKept: [3, 2, 1], stop: .done))
        XCTAssertEqual(requestedRecords, [3, 2, 1])
        let records = await pumpManager.historyRecords(forPatch: Self.patch)
        XCTAssertEqual(records.map(\.sequence), [3, 2, 1])
        XCTAssertEqual(records.map(\.isRecord), [false, false, false], "none kept as a record")
        XCTAssertEqual(records.map(\.outcome), [
            "unreadable: answered as 3 of patch 999",
            "unreadable: answered as 7 of patch \(Self.patch)",
            "unreadable: \(MedtrumWriteError.invalidData.errorDescription)"
        ])
        let missing = await pumpManager.missingRecordSequences(forPatch: Self.patch)
        XCTAssertEqual(missing, [])

        let again = await pumpManager.fillRecordHistory()
        XCTAssertEqual(again, RecordHistoryFill(read: [], notKept: [], stop: .done))
        XCTAssertEqual(requestedRecords, [3, 2, 1], "not asked for again")
    }

    /// 25 stale slots at the newest end: the first page asks for 20 of them, the next goes past the other 5 to the
    /// records that can be read - not stuck on the same 20
    func testStaleSlotsDoNotHoldTheFillAtTheNewestEnd() async {
        makeHistoryManager(sequence: 30)
        for sequence in (11 ... 30).reversed() {
            scriptAlarmRecord(sequence, patchId: 999)
        }

        let first = await pumpManager.fillRecordHistory()
        XCTAssertEqual(first, RecordHistoryFill(read: [], notKept: Array((11 ... 30).reversed()), stop: .limitReached))

        for sequence in (6 ... 10).reversed() {
            scriptAlarmRecord(sequence, patchId: 999)
        }
        for sequence in (1 ... 5).reversed() {
            scriptAlarmRecord(sequence)
        }
        let second = await pumpManager.fillRecordHistory()

        XCTAssertEqual(second, RecordHistoryFill(read: [5, 4, 3, 2, 1], notKept: [10, 9, 8, 7, 6], stop: .done))
        XCTAssertEqual(requestedRecords, Array((1 ... 30).reversed()), "each asked for once")
        let records = await pumpManager.historyRecords(forPatch: Self.patch)
        XCTAssertEqual(records.filter(\.isRecord).map(\.sequence), [5, 4, 3, 2, 1])
    }

    // MARK: It gives way

    /// The record sync runs - a sync, a temp basal's end being read: the fill does not start a read
    func testTheFillDoesNotStartWhileTheRecordSyncRuns() {
        makeHistoryManager(sequence: 3)

        var fill: RecordHistoryFill?
        RecordSyncer.whileRunningForTesting {
            fill = pumpManager.readMissingRecords()
        }

        XCTAssertEqual(fill, RecordHistoryFill(read: [], notKept: [], stop: .linkBusy))
        XCTAssertEqual(requestedRecords, [])
    }

    /// The record sync begins as the fill reads: it stops after that record, the sync's to go on
    func testTheFillStopsWhenTheRecordSyncBeginsMeanwhile() {
        makeHistoryManager(sequence: 3)
        let syncRuns = DispatchSemaphore(value: 0)
        let syncMayEnd = DispatchSemaphore(value: 0)
        let syncEnded = DispatchSemaphore(value: 0)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 3, sequence: 3, patchId: Self.patch))) {
            Thread.detachNewThread {
                RecordSyncer.whileRunningForTesting {
                    syncRuns.signal()
                    syncMayEnd.wait()
                }
                syncEnded.signal()
            }
            syncRuns.wait()
        }

        let fill = pumpManager.readMissingRecords()
        syncMayEnd.signal()
        syncEnded.wait()

        XCTAssertEqual(fill, RecordHistoryFill(read: [3], notKept: [], stop: .linkBusy))
        XCTAssertEqual(requestedRecords, [3])
    }

    /// Another operation waits for the command lock - a stop, a prime, the loop's sync: the fill does not start a read
    func testTheFillDoesNotStartWhileAnOperationWaitsForTheLink() {
        makeHistoryManager(sequence: 3)
        let waiting = pumpManager.loopBeginsWaiting()

        let fill = pumpManager.readMissingRecords()
        pumpManager.loopWaits.mutate { $0[waiting] = nil }

        XCTAssertEqual(fill, RecordHistoryFill(read: [], notKept: [], stop: .linkBusy))
        XCTAssertEqual(requestedRecords, [])
    }

    /// An operation begins waiting for the command lock as the fill reads: it stops after that record
    func testTheFillStopsWhenAnOperationBeginsWaitingForTheLink() {
        makeHistoryManager(sequence: 3)
        let manager = pumpManager!
        let waiting = Locked<UUID?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 3, sequence: 3, patchId: Self.patch))) {
            waiting.value = manager.loopBeginsWaiting()
        }

        let fill = pumpManager.readMissingRecords()
        if let token = waiting.value {
            pumpManager.loopWaits.mutate { $0[token] = nil }
        }

        XCTAssertEqual(fill, RecordHistoryFill(read: [3], notKept: [], stop: .linkBusy))
        XCTAssertEqual(requestedRecords, [3])
    }

    /// A sync run turned away by the lock reads nothing more: it is no run of the heartbeat's cooldown - the next
    /// heartbeat reads on
    func testASyncTurnedAwayByTheLockIsNoCooldownRun() {
        makeHistoryManager(sequence: 2)
        pumpManager.state.currentSequenceNumber = 3
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let unlocked = DispatchSemaphore(value: 0)
        let manager = pumpManager!
        Thread.detachNewThread {
            manager.commandLock.lock()
            held.signal()
            release.wait()
            manager.commandLock.unlock()
            unlocked.signal()
        }
        held.wait()
        syncRecords(.awaitingDoses)
        release.signal()
        unlocked.wait()
        XCTAssertEqual(requestedRecords, [])

        scriptAlarmRecord(3)
        syncRecords(.awaitingDoses)
        XCTAssertEqual(requestedRecords, [3], "not throttled")
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 3)
    }

    /// The link lost: the fill ends there
    func testALostLinkEndsTheFill() async {
        makeHistoryManager(sequence: 3)
        link.script(CommandType.GET_RECORD, .failure(.notConnected))

        let fill = await pumpManager.fillRecordHistory()

        XCTAssertEqual(fill.read, [])
        XCTAssertEqual(fill.stop, .linkLost(MedtrumWriteError.notConnected.errorDescription))
        XCTAssertEqual(requestedRecords, [3])
    }

    /// No session: the base cannot be taken to serve another patch's records - nothing asked for
    func testNoFillWithoutASession() async {
        makeHistoryManager(sequence: 3)
        pumpManager.state.patchSessionEnded = true

        let fill = await pumpManager.fillRecordHistory()

        XCTAssertEqual(fill.stop, .noSession)
        XCTAssertEqual(requestedRecords, [])
        XCTAssertEqual(pumpManager.recordHistoryPatches(), [])
    }

    // MARK: Which files

    /// The current patch, then the previous one by its id: what the screens offer, and what is shared with the logs -
    /// written out first
    func testTheCurrentAndThePreviousPatchAreOfferedAndShared() {
        let history = keepRecordHistory(coalesceDelay: 60)
        let state = activePatchState(patchId: Self.patch, scheduledRate: 0.6, sequence: 3, reservoir: 150)
        state.previousPatch = PreviousPatch(
            patchId: UInt64(235).toData(length: 4),
            lastStateRaw: PatchState.stopped.rawValue,
            lastSyncAt: Date.now,
            battery: 0,
            activatedAt: Date.now.addingTimeInterval(-72 * Self.hour),
            deactivatedAt: Date.now,
            initialReservoirLevel: 200,
            reservoirLevel: 20
        )
        makeManager(state)
        XCTAssertEqual(pumpManager.recordHistoryPatches(), [Self.patch], "the previous one has no file")

        for patch: UInt64 in [234, 235, Self.patch] {
            history.append(alarmRecordResponse(sequence: 1, patchId: patch), patchId: patch, outcome: nil)
        }

        let shared = pumpManager.recordHistoryFilesForSharing()
        XCTAssertEqual(shared.map(\.lastPathComponent), ["patch-236.jsonl", "patch-235.jsonl"], "written before they are shared")
        XCTAssertEqual(pumpManager.recordHistoryPatches(), [Self.patch, 235])
    }

    /// A patch change with no patch known - none running, no previous one recorded: nothing to tell the files kept from
    /// the others by - none is deleted
    func testAPruneWithNoPatchToKeepDeletesNothing() {
        let history = keepRecordHistory()
        let state = activePatchState(patchId: Self.patch, scheduledRate: 0.6, sequence: 3, reservoir: 150)
        state.patchId = Data()
        state.previousPatch = nil
        makeManager(state)
        for patch: UInt64 in [234, 235] {
            history.append(alarmRecordResponse(sequence: 1, patchId: patch), patchId: patch, outcome: nil)
        }

        pumpManager.pruneRecordHistory(replacing: Data())

        XCTAssertEqual(history.patchesWithFiles(), [235, 234])
    }

    /// No history kept - a manager given none: nothing offered, nothing read
    func testAManagerWithoutAHistoryKeepsNone() async {
        makeManager(activePatchState(patchId: Self.patch, scheduledRate: 0.6, sequence: 3, reservoir: 150))

        XCTAssertEqual(pumpManager.recordHistoryPatches(), [])
        XCTAssertEqual(pumpManager.recordHistoryFilesForSharing(), [])
        let fill = await pumpManager.fillRecordHistory()
        XCTAssertEqual(fill.stop, .noSession)
        XCTAssertEqual(requestedRecords, [])
    }
}

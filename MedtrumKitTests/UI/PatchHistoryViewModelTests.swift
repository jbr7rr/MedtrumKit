import Combine
@testable import MedtrumKit
import XCTest

/// The history screens' view models on a manager keeping its records' history: which patches offer a history, what the
/// history screen shows of a file, and a fill read from it
final class PatchHistoryManagerViewModelTests: MedtrumManagerTestCase {
    private static let patch: UInt64 = 236
    private static let previousPatch: UInt64 = 235

    private func previousPatchState() -> MedtrumPumpState {
        let state = activePatchState(patchId: Self.patch, scheduledRate: 0.6, sequence: 5, reservoir: 150)
        state.previousPatch = PreviousPatch(
            patchId: Self.previousPatch.toData(length: 4),
            lastStateRaw: PatchState.stopped.rawValue,
            lastSyncAt: Date.now,
            battery: 0,
            activatedAt: Date.now.addingTimeInterval(-72 * Self.hour),
            deactivatedAt: Date.now,
            initialReservoirLevel: 200,
            reservoirLevel: 20
        )
        return state
    }

    /// The history offered as the previous patch's details are checked: the patch, nil if none
    private func offeredHistory(of viewModel: PreviousPatchDetailsViewModel) -> UInt64?? {
        let checked = expectation(description: "the file looked for")
        var offered: UInt64??
        // Set on every check, nil or not: the first after the one from `init`, not run yet - this test holds the main queue
        let subscription = viewModel.$historyPatch.dropFirst().first().sink {
            offered = .some($0)
            checked.fulfill()
        }
        wait(for: [checked], timeout: 5)
        subscription.cancel()
        return offered
    }

    // MARK: The entries

    /// The previous patch's details offer its history only if its file is there - and open it by its id
    func testThePreviousPatchOffersItsHistoryOnlyIfItsFileIsThere() {
        let history = keepRecordHistory()
        makeManager(previousPatchState())

        let without = PreviousPatchDetailsViewModel(pumpManager: pumpManager)
        XCTAssertEqual(offeredHistory(of: without), .some(nil), "no file")

        history.append(alarmRecordResponse(sequence: 1, patchId: Self.previousPatch), patchId: Self.previousPatch, outcome: nil)
        var opened: [UInt64] = []
        let with = PreviousPatchDetailsViewModel(pumpManager: pumpManager, showHistory: { opened.append($0) })
        XCTAssertEqual(offeredHistory(of: with), .some(Self.previousPatch))

        with.toHistory()
        XCTAssertEqual(opened, [Self.previousPatch])
    }

    /// No history kept: the previous patch's details offer none
    func testNoHistoryOfferedWithoutAHistoryKept() {
        makeManager(previousPatchState())

        let viewModel = PreviousPatchDetailsViewModel(pumpManager: pumpManager, showHistory: { _ in XCTFail("opened") })
        XCTAssertEqual(offeredHistory(of: viewModel), .some(nil))
        viewModel.toHistory()
    }

    /// The records screen offers the full history of the current patch - while its session runs, a history kept
    func testTheRecordsScreenOffersTheCurrentPatchsFullHistory() {
        keepRecordHistory()
        makeManager(previousPatchState())
        var opened: [UInt64] = []

        let viewModel = PumpRecordsViewModel(pumpManager: pumpManager, showHistory: { opened.append($0) })
        XCTAssertEqual(viewModel.historyPatch, Self.patch)
        viewModel.toFullHistory()
        XCTAssertEqual(opened, [Self.patch])

        pumpManager.state.patchSessionEnded = true
        XCTAssertNil(PumpRecordsViewModel(pumpManager: pumpManager).historyPatch, "no session")
    }

    func testTheRecordsScreenOffersNoHistoryWithoutOneKept() {
        makeManager(previousPatchState())

        let viewModel = PumpRecordsViewModel(pumpManager: pumpManager, showHistory: { _ in XCTFail("opened") })
        XCTAssertNil(viewModel.historyPatch)
        viewModel.toFullHistory()
    }

    // MARK: The history screen

    /// Newest first, one per number: a number kept without its record marked as such - shown as that, never as an event.
    /// The header counts the records, the numbers missing, and the ones that could not be read.
    @MainActor func testTheRowsAreNewestFirstWithTheUnreadableMarked() async {
        let history = keepRecordHistory()
        makeManager(previousPatchState())
        history.append(alarmRecordResponse(sequence: 1, patchId: Self.patch), patchId: Self.patch, outcome: "unmatched")
        history.appendNotKept(sequence: 2, patchId: Self.patch, raw: Data(), outcome: "unreadable: bad crc")
        history.append(alarmRecordResponse(sequence: 3, patchId: Self.patch), patchId: Self.patch, outcome: nil)

        let viewModel = PatchHistoryViewModel(patchId: Self.patch, isCurrentPatch: true, source: pumpManager)
        await viewModel.load()

        XCTAssertEqual(viewModel.records.map(\.sequence), [3, 2, 1])
        XCTAssertEqual(viewModel.records.map(\.isRecord), [true, false, true])
        XCTAssertEqual(viewModel.missing, [4, 5], "up to the newest the sync went past")
        XCTAssertEqual(viewModel.countsLine, "2 records · 2 missing · 1 could not be read")
        XCTAssertTrue(viewModel.canReadMissing)

        let placeholder = PatchRecordRow(viewModel.records[1], dateFormatter: viewModel.dateFormatter)
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertEqual(placeholder.title, "Record 2 could not be read")
        XCTAssertNil(placeholder.time, "no event")
        XCTAssertNil(placeholder.summary)
        XCTAssertEqual(placeholder.outcome, "unreadable: bad crc")

        let record = PatchRecordRow(viewModel.records[2], dateFormatter: viewModel.dateFormatter)
        XCTAssertFalse(record.isPlaceholder)
        let label = try? XCTUnwrap(viewModel.records[2].label, "an alarm by what it is")
        XCTAssertEqual(record.title, "#1  " + (label ?? ""))
        XCTAssertNotNil(record.time)
        XCTAssertEqual(record.outcome, "unmatched")

        let shared = await viewModel.prepareShare()
        XCTAssertEqual(shared.map(\.lastPathComponent), ["patch-236.jsonl"], "this patch's file only")
        XCTAssertEqual(viewModel.shareURLs, shared)
        XCTAssertFalse(viewModel.isPreparingShare)
        XCTAssertEqual(link.connects, 0, "nothing read off the patch as it loads")
    }

    /// A fill read through the screen: the missing records read off the patch, the rows and counts read again
    @MainActor func testAFillReadsTheMissingRecordsAndReloads() async {
        let history = keepRecordHistory()
        makeManager(previousPatchState())
        for sequence in 1 ... 3 {
            history.append(alarmRecordResponse(sequence: sequence, patchId: Self.patch), patchId: Self.patch, outcome: nil)
        }
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 5, patchId: Self.patch))
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 4, patchId: Self.patch))

        let viewModel = PatchHistoryViewModel(patchId: Self.patch, isCurrentPatch: true, source: pumpManager)
        await viewModel.load()
        XCTAssertEqual(viewModel.countsLine, "3 records · 2 missing")

        await viewModel.fill()

        XCTAssertEqual(viewModel.records.map(\.sequence), [5, 4, 3, 2, 1])
        XCTAssertEqual(viewModel.records.first?.outcome, "history read")
        XCTAssertEqual(viewModel.missing, [])
        XCTAssertEqual(viewModel.countsLine, "5 records · 0 missing")
        XCTAssertEqual(viewModel.stopLine, "Nothing more to read")
        XCTAssertNil(viewModel.progress)
        XCTAssertFalse(viewModel.canReadMissing)
    }
}

/// The history screen's view model on a fake manager: the pages of a fill, and the lines its stops end with
@MainActor final class PatchHistoryViewModelTests: XCTestCase {
    private static let patch: UInt64 = 300

    /// The manager's side of the history, scripted: each page of a fill, and what the file holds after it
    @MainActor private final class FakeSource: PatchHistorySource {
        var records: [StoredRecord] = []
        var missing: [Int] = []
        /// The pages a fill gets, in order - each with what it changes of the file
        var pages: [(fill: RecordHistoryFill, then: () -> Void)] = []
        var fills = 0
        var loads = 0
        /// Before each page is answered: what the screen showed then
        var onFill: (() -> Void)?

        func historyRecords(forPatch _: UInt64) async -> [StoredRecord] {
            loads += 1
            return records
        }

        func missingRecordSequences(forPatch _: UInt64) async -> [Int] {
            missing
        }

        func fillRecordHistory(limit _: Int) async -> RecordHistoryFill {
            fills += 1
            onFill?()
            guard !pages.isEmpty else {
                return RecordHistoryFill(read: [], notKept: [], stop: .done)
            }
            let page = pages.removeFirst()
            page.then()
            return page.fill
        }

        nonisolated func recordHistoryFilesForSharing() -> [URL] {
            []
        }
    }

    private static func record(_ sequence: Int) -> StoredRecord {
        StoredRecord(
            sequence: sequence,
            patchId: patch,
            readAt: Date.now,
            raw: Data(),
            outcome: "history read",
            kind: "ALARM",
            summary: "",
            label: nil,
            eventDate: Date.now,
            isRecord: true
        )
    }

    private static func unreadable(_ sequence: Int) -> StoredRecord {
        StoredRecord(
            sequence: sequence,
            patchId: patch,
            readAt: Date.now,
            raw: Data(),
            outcome: "unreadable: bad crc",
            kind: "UNREADABLE",
            summary: "unreadable: bad crc",
            label: nil,
            eventDate: nil,
            isRecord: false
        )
    }

    /// Appearing reads the file only: a fill takes the link, and runs only when asked
    func testNoFillOnAppear() async {
        let source = FakeSource()
        source.missing = [1, 2, 3]
        let viewModel = PatchHistoryViewModel(patchId: Self.patch, isCurrentPatch: true, source: source)

        await viewModel.load()

        XCTAssertEqual(source.loads, 1)
        XCTAssertEqual(source.fills, 0)
        XCTAssertNil(viewModel.progress)
        XCTAssertNil(viewModel.stopLine)
        XCTAssertEqual(viewModel.countsLine, "0 records · 3 missing")
    }

    /// The previous patch's records cannot be read off any patch: no fill offered, none run
    func testThePreviousPatchIsNeverFilled() async {
        let source = FakeSource()
        source.missing = [1, 2, 3]
        let viewModel = PatchHistoryViewModel(patchId: Self.patch, isCurrentPatch: false, source: source)
        await viewModel.load()

        XCTAssertFalse(viewModel.canReadMissing)
        viewModel.readMissing()
        await viewModel.fill()

        XCTAssertEqual(source.fills, 0)
    }

    /// Asked, pages read one after the other until a stop: progress shown as it goes, the file read again after each page,
    /// and the stop's line at the end
    func testPagesAreReadUntilAStopWithProgressAndAReloadEach() async {
        let source = FakeSource()
        source.missing = Array(1 ... 30)
        source.pages = [
            (RecordHistoryFill(read: Array((11 ... 30).reversed()), notKept: [], stop: .limitReached), {
                source.records = (11 ... 30).reversed().map(Self.record)
                source.missing = Array(1 ... 10)
            }),
            (RecordHistoryFill(read: [10, 9], notKept: [8], stop: .linkBusy), {
                source.records = (9 ... 30).reversed().map(Self.record)
                source.missing = Array(1 ... 7)
            }),
        ]
        let viewModel = PatchHistoryViewModel(patchId: Self.patch, isCurrentPatch: true, source: source)
        await viewModel.load()

        var shown: [String?] = []
        source.onFill = { shown.append(viewModel.progressLine) }
        await viewModel.fill()

        XCTAssertEqual(source.fills, 2)
        XCTAssertEqual(source.loads, 3, "once as it appeared, once after each page")
        XCTAssertEqual(shown, ["Reading… 0 of 30 missing", "Reading… 20 of 30 missing"])
        XCTAssertEqual(viewModel.records.map(\.sequence), Array((9 ... 30).reversed()))
        XCTAssertEqual(viewModel.countsLine, "22 records · 7 missing")
        XCTAssertEqual(viewModel.stopLine, "The pump is busy — try again in a moment")
        XCTAssertNil(viewModel.progress)
        XCTAssertTrue(viewModel.canReadMissing, "asked again, it goes on")
    }

    /// Stopped - the screen gone: no page after the one being read
    func testAStoppedFillReadsNoFurtherPage() async {
        let source = FakeSource()
        source.missing = Array(1 ... 60)
        source.pages = [
            (RecordHistoryFill(read: Array((41 ... 60).reversed()), notKept: [], stop: .limitReached), {}),
            (RecordHistoryFill(read: Array((21 ... 40).reversed()), notKept: [], stop: .limitReached), {}),
        ]
        let viewModel = PatchHistoryViewModel(patchId: Self.patch, isCurrentPatch: true, source: source)
        await viewModel.load()
        var shownStopping: String?
        source.onFill = {
            viewModel.stopReading()
            shownStopping = viewModel.progressLine
        }

        viewModel.readMissing()
        XCTAssertFalse(viewModel.canReadMissing, "one at a time")
        // The task the tap started, run to its end
        for _ in 0 ..< 100 where source.fills == 0 || viewModel.progress != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(source.fills, 1)
        XCTAssertEqual(shownStopping, "Stopping…", "until the page in flight ends")
        XCTAssertNil(viewModel.progress)
        XCTAssertFalse(viewModel.isStopping)
        XCTAssertNil(viewModel.stopLine, "stopped, not a stop of the manager's")
    }

    /// A fill that reads no page - stopped before it began, or with nothing it may read - leaves no progress behind
    func testAFillThatReadsNoPageLeavesNoProgress() async {
        let source = FakeSource()
        source.missing = [1, 2, 3]
        let viewModel = PatchHistoryViewModel(patchId: Self.patch, isCurrentPatch: true, source: source)
        await viewModel.load()

        viewModel.readMissing()
        XCTAssertEqual(viewModel.progressLine, "Reading… 0 of 3 missing", "shown as it is asked")
        viewModel.stopReading()
        XCTAssertEqual(viewModel.progressLine, "Stopping…")
        for _ in 0 ..< 100 where viewModel.progress != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(source.fills, 0)
        XCTAssertNil(viewModel.progress)
        XCTAssertFalse(viewModel.isStopping)
        XCTAssertTrue(viewModel.canReadMissing, "asked again, it goes on")

        // The guard: no source to read from - returns before any page, and still clears what is shown
        let sourceless = PatchHistoryViewModel(patchId: Self.patch, isCurrentPatch: true, source: nil)
        await sourceless.fill()
        XCTAssertNil(sourceless.progress)
        XCTAssertFalse(sourceless.isStopping)
    }

    /// The counts in the catalog's plural variants: one record, one missing - not "1 records"
    func testTheCountsLineIsPluralized() async {
        let source = FakeSource()
        source.records = [Self.record(2), Self.unreadable(1)]
        source.missing = [3]
        let viewModel = PatchHistoryViewModel(patchId: Self.patch, isCurrentPatch: true, source: source)
        await viewModel.load()
        XCTAssertEqual(viewModel.countsLine, "1 record · 1 missing · 1 could not be read")

        source.records = (2 ... 3).map(Self.record)
        source.missing = [1, 4]
        await viewModel.load()
        XCTAssertEqual(viewModel.countsLine, "2 records · 2 missing")
    }

    /// Each stop, in a short line - none alarming
    func testEachStopMapsToItsLine() {
        XCTAssertEqual(PatchHistoryViewModel.line(for: .done), "Nothing more to read")
        XCTAssertEqual(PatchHistoryViewModel.line(for: .linkBusy), "The pump is busy — try again in a moment")
        XCTAssertEqual(PatchHistoryViewModel.line(for: .bolusRunning), "Not while a bolus is running")
        XCTAssertEqual(PatchHistoryViewModel.line(for: .linkLost("timeout")), "Lost the connection")
        XCTAssertEqual(PatchHistoryViewModel.line(for: .noSession), "The patch changed")
        XCTAssertEqual(PatchHistoryViewModel.line(for: .sessionChanged), "The patch changed")
    }
}

@testable import MedtrumKit
import XCTest

/// A record answer as the link puts it together - see `PatchBytes`
func recordResponse(_ fragments: [String]) -> GetRecordResponse {
    var packet = GetRecordPacket(recordIndex: 0, patchId: 0)
    for fragment in fragments {
        packet.decode(Data(hex: fragment)!)
    }
    return packet.parseResponse()
}

/// An alarm record (type 3) numbered `sequence`, of patch `patchId` - its payload zeros
func alarmRecordResponse(sequence: Int, patchId: UInt64) -> GetRecordResponse {
    recordResponse(PatchBytes.otherRecord(type: 3, sequence: sequence, patchId: patchId))
}

/// Each patch's records in a file of its own (`PatchRecordHistory`), in a directory of the test's own
final class PatchRecordHistoryTests: XCTestCase {
    private static let patch: UInt64 = 278

    private var directory: URL!
    private var history: PatchRecordHistory!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PatchRecordHistoryTests-\(UUID().uuidString)")
        history = PatchRecordHistory(directory: directory, coalesceDelay: 0)
    }

    override func tearDown() {
        history.flush()
        try? FileManager.default.removeItem(at: directory)
        history = nil
        super.tearDown()
    }

    private var fileLines: [String] {
        let text = (try? String(contentsOf: history.fileURL(forPatch: Self.patch), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private func bolus(_ sequence: Int, delivered: Double = 1.0) -> GetRecordResponse {
        recordResponse(PatchBytes.bolusRecord(
            sequence: sequence,
            patchId: Self.patch,
            start: Date(timeIntervalSince1970: 1_793_005_740),
            amount: 1.0,
            delivered: delivered
        ))
    }

    // MARK: Writing and loading

    /// Appended, then loaded: decoded from the bytes kept, newest first, with what the syncer made of each
    func testRecordsAppendedLoadDecodedNewestFirst() async throws {
        let start = Date(timeIntervalSince1970: 1_793_005_740)
        let basal = recordResponse(PatchBytes.basalRecord(
            sequence: 2,
            patchId: Self.patch,
            type: .ABSOLUTE_TEMP,
            start: start,
            end: start.addingTimeInterval(600),
            rate: 1.2,
            delivered: 0.2
        ))
        let readAt = Date(timeIntervalSince1970: 1_793_006_000)
        history.append(alarmRecordResponse(sequence: 1, patchId: Self.patch), patchId: Self.patch, outcome: nil, readAt: readAt)
        history.append(basal, patchId: Self.patch, outcome: "finalized temp basal", readAt: readAt)
        history.append(bolus(3), patchId: Self.patch, outcome: "unmatched", readAt: readAt)
        history.flush()

        XCTAssertEqual(fileLines.count, 3, "one line a record")
        let records = await history.records(forPatch: Self.patch)
        XCTAssertEqual(records.map(\.sequence), [3, 2, 1])
        XCTAssertEqual(records.map(\.kind), ["BOLUS", "BASAL", "ALARM"])
        XCTAssertEqual(records.map(\.outcome), ["unmatched", "finalized temp basal", nil])
        XCTAssertEqual(records.first?.raw, bolus(3).raw)
        XCTAssertEqual(records.first?.patchId, Self.patch)
        XCTAssertEqual(records.first?.readAt, readAt)
        XCTAssertEqual(records.first?.eventDate, start)
        XCTAssertEqual(records.dropFirst().first?.eventDate, start)
    }

    /// A record read again is appended again: the newest line of its number wins, one record for it
    func testARecordReadAgainLoadsAsItsNewestLine() async {
        history.append(bolus(5, delivered: 0.5), patchId: Self.patch, outcome: "unmatched")
        history.append(alarmRecordResponse(sequence: 4, patchId: Self.patch), patchId: Self.patch, outcome: nil)
        history.flush()
        history.append(bolus(5), patchId: Self.patch, outcome: "finalized bolus")
        history.flush()

        XCTAssertEqual(fileLines.count, 3)
        let records = await history.records(forPatch: Self.patch)
        XCTAssertEqual(records.map(\.sequence), [5, 4])
        XCTAssertEqual(records.first?.outcome, "finalized bolus")
        XCTAssertTrue(records.first?.summary.contains("1") == true, records.first?.summary ?? "-")
    }

    /// A line that is no record - cut short as the app was killed, garbled, or its bytes not hex - is skipped, the rest
    /// loaded
    func testACorruptLineIsSkipped() async throws {
        history.append(bolus(1), patchId: Self.patch, outcome: "unmatched")
        history.flush()
        let handle = try FileHandle(forWritingTo: history.fileURL(forPatch: Self.patch))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((
            "{\"sequence\":2,\"patchId\":278,\"readAt\":\"2026-11-09T10:00:00Z\",\"raw\":\"zz\",\"outcome\":null}\n" +
                "not json\n" +
                "{\"sequence\":3,\"patchId\":278,\"readAt\":\"2026-11-09T10:00:00Z\",\"raw\":\"aa20\",\"outcome\":null}\n" +
                "{\"sequence\":4,\"patchId\":278,\"rea"
        ).utf8))
        try handle.close()
        history.append(bolus(6), patchId: Self.patch, outcome: "unmatched")
        history.flush()

        let records = await history.records(forPatch: Self.patch)
        XCTAssertEqual(records.map(\.sequence), [6, 1], "2's bytes not hex, 3's too short for a record, 4 cut short")
    }

    /// The numbers from 1 to the newest known with no record kept: from the newest kept, or further on if told
    func testMissingSequencesAreTheGapsFromTheFirstRecord() async {
        for sequence in [3, 5, 6] {
            history.append(alarmRecordResponse(sequence: sequence, patchId: Self.patch), patchId: Self.patch, outcome: nil)
        }

        let missing = await history.missingSequences(forPatch: Self.patch)
        XCTAssertEqual(missing, [1, 2, 4])
        let throughEight = await history.missingSequences(forPatch: Self.patch, through: 8)
        XCTAssertEqual(throughEight, [1, 2, 4, 7, 8])
        let throughFour = await history.missingSequences(forPatch: Self.patch, through: 4)
        XCTAssertEqual(throughFour, [1, 2, 4], "never short of the newest kept")
        let none = await history.missingSequences(forPatch: 1)
        XCTAssertEqual(none, [])
        XCTAssertEqual(history.missingSequencesNow(forPatch: 1, through: 2), [1, 2])
    }

    /// An append returns at once, its write left to the history's own queue: held, nothing is written - and the caller
    /// is not held either
    func testAppendsAreWrittenOffTheCallingQueue() {
        let release = DispatchSemaphore(value: 0)
        let held = DispatchSemaphore(value: 0)
        history.queue.async {
            held.signal()
            release.wait()
        }
        held.wait()

        let appended = expectation(description: "appended")
        DispatchQueue.main.async {
            self.history.append(self.bolus(1), patchId: Self.patch, outcome: "unmatched")
            self.history.commit()
            appended.fulfill()
        }
        wait(for: [appended], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.fileURL(forPatch: Self.patch).path))

        release.signal()
        history.flush()
        XCTAssertEqual(fileLines.count, 1)
    }

    /// Queued appends of one run go out in one write, `coalesceDelay` after the first if no commit comes
    func testQueuedAppendsAreWrittenAfterTheDelay() {
        history = PatchRecordHistory(directory: directory, coalesceDelay: 0.1)
        history.append(bolus(1), patchId: Self.patch, outcome: nil)
        history.append(bolus(2), patchId: Self.patch, outcome: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.fileURL(forPatch: Self.patch).path))

        let written = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            written.fulfill()
        }
        wait(for: [written], timeout: 2)
        XCTAssertEqual(fileLines.count, 2)
    }

    /// A number noted as not answered with its record - with the bytes of another patch's record, or none - is no
    /// record of it: loaded as such, never decoded as one, and not missing. A later read of the record itself wins.
    func testANumberNotKeptLoadsAsNoRecordAndIsNotMissing() async {
        history.append(alarmRecordResponse(sequence: 1, patchId: Self.patch), patchId: Self.patch, outcome: nil)
        let other = alarmRecordResponse(sequence: 2, patchId: 999)
        history.appendNotKept(sequence: 2, patchId: Self.patch, raw: other.raw, outcome: "unreadable: answered as 2 of patch 999")
        history.appendNotKept(sequence: 3, patchId: Self.patch, raw: Data(), outcome: "unreadable: invalid data")
        // Bytes of this patch's record 9 at number 4, not marked: no record of 4 either
        let lines = [
            PatchRecordHistory.Line(
                sequence: 4,
                patchId: Self.patch,
                readAt: Date.now,
                raw: alarmRecordResponse(sequence: 9, patchId: Self.patch).raw.hexEncodedString(),
                outcome: nil
            )
        ]
        history.flush()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let handle = try? FileHandle(forWritingTo: history.fileURL(forPatch: Self.patch))
        _ = try? handle?.seekToEnd()
        try? handle?.write(contentsOf: encoder.encode(lines[0]) + Data([0x0A]))
        try? handle?.close()

        var records = await history.records(forPatch: Self.patch)
        XCTAssertEqual(records.map(\.sequence), [4, 3, 2, 1])
        XCTAssertEqual(records.map(\.isRecord), [false, false, false, true])
        XCTAssertEqual(records.map(\.kind), ["UNREADABLE", "UNREADABLE", "UNREADABLE", "ALARM"])
        XCTAssertEqual(records.dropFirst(2).first?.summary, "unreadable: answered as 2 of patch 999")
        XCTAssertEqual(records.dropFirst(2).first?.raw, other.raw)
        XCTAssertTrue(records.allSatisfy { $0.eventDate == nil || $0.isRecord })
        let missing = await history.missingSequences(forPatch: Self.patch, through: 5)
        XCTAssertEqual(missing, [5])

        history.append(alarmRecordResponse(sequence: 2, patchId: Self.patch), patchId: Self.patch, outcome: "history read")
        records = await history.records(forPatch: Self.patch)
        XCTAssertEqual(records.first { $0.sequence == 2 }?.isRecord, true, "the newest line")
    }

    // MARK: Pruning

    /// Every patch's file but the ones kept goes - nothing else in the directory
    func testPruningKeepsThePatchesGivenOnly() throws {
        for patch: UInt64 in [276, 277, 278] {
            history.append(alarmRecordResponse(sequence: 1, patchId: patch), patchId: patch, outcome: nil)
        }
        history.flush()
        let other = directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: other)
        XCTAssertEqual(history.patchesWithFiles(), [278, 277, 276])

        history.prune(keeping: [278, 277])

        XCTAssertEqual(history.patchesWithFiles(), [278, 277])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(history.files(of: [278, 276, 277]).map(\.lastPathComponent), ["patch-278.jsonl", "patch-277.jsonl"])
    }

    func testFileNames() {
        XCTAssertEqual(history.fileURL(forPatch: 278).lastPathComponent, "patch-278.jsonl")
        XCTAssertEqual(PatchRecordHistory.patchId(ofFileNamed: "patch-278.jsonl"), 278)
        XCTAssertNil(PatchRecordHistory.patchId(ofFileNamed: "patch-x.jsonl"))
        XCTAssertNil(PatchRecordHistory.patchId(ofFileNamed: "medtrumkit_log.txt"))
        XCTAssertEqual(PatchRecordHistory.defaultDirectory.pathComponents.suffix(2), ["medtrumkit", "records"])
    }
}

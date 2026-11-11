import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerBolusScenarioTests {
    // MARK: - A bolus record matching no dose of ours

    /// Record 123, a bolus of 1.0 U delivered that no dose of ours is - one written as the app was killed before the host
    /// saved it pending, another app's: not imported, the user told to add it - once, read again or after a restart
    func testBolusRecordMatchingNoDoseOfOursIsToldOfOnce() throws {
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 123, reservoir: 168.6)
        state.syncedSequenceNumber = 122
        makeManager(state)
        let start = pumpManager.state.pumpTime.addingTimeInterval(-10 * Self.minute)
        let record = PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: start, amount: 1.0, delivered: 1.0)

        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 123 }?.outcome, "unmatched")
        XCTAssertTrue(reports(of: .bolus).isEmpty, "not imported")
        XCTAssertEqual(delegate.alerts.count, 1)
        let alert = try XCTUnwrap(delegate.alerts.first)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted"))
        XCTAssertEqual(alert.foregroundContent?.body.contains("a bolus of 1 U delivered at"), true)

        // Read again
        pumpManager.state.syncedSequenceNumber = 122
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 1, "told of once")

        // And after a restart
        try restart(from: delegate.savedState)
        pumpManager.state.syncedSequenceNumber = 122
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 123 }?.outcome, "unmatched")
        XCTAssertEqual(delegate.alerts.count, 0, "told of before the restart")
    }

    /// Unmatched bolus records the user is not told of: one that delivered nothing, and one written before this state
    /// took up the patch - the backlog of its first status, another app's
    func testBolusRecordMatchingNoDoseOfOursThatDeliveredNothingOrPredatesThePatchIsNotToldOf() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 124, reservoir: 168.6)
        state.syncedSequenceNumber = 122
        state.sessionStartSequence = 123
        makeManager(state)
        let start = pumpManager.state.pumpTime.addingTimeInterval(-10 * Self.minute)

        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: start, amount: 1.0, delivered: 1.0))
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: start.addingTimeInterval(60), amount: 1.0, delivered: 0)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 124)
        XCTAssertEqual(pumpManager.recordStore.records.filter { $0.outcome == "unmatched" }.count, 2)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The record that finalized a bolus whose command went unanswered, read again - the app killed before the cursor
    /// past it was saved, say: taken as it was, no other bolus's, and nothing the host is missing
    func testRecordOfAnUnansweredBolusReadAgainIsNotToldOf() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline()
        link.notify("20000138" + "03f700")
        settle()
        let record = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: Date.fromMedtrumSeconds(0x17CC_31CB).addingTimeInterval(2),
            amount: 0.3,
            delivered: 0.3
        )
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        assertOneFinal(of: started)
        XCTAssertTrue(pumpManager.state.awaitingRecord.isEmpty, "the host stored the final")

        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, record)
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome, "answered bolus finalized already")
        assertOneFinal(of: started)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The record of a bolus of ours final from our estimate - its answer lost, the records unread for an hour, counted
    /// in full, and the user told so - read after all: it matches no dose any more, and is that one's, at its amount near
    /// when it went out. Nothing more to tell.
    func testRecordOfABolusFinalFromOurEstimateIsNotToldOf() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline(confirmingRecords: false)
        advanceClock(by: 60 * Self.minute)
        syncRecords()
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), ["com.nightscout.medtrumkit.bolus-counted-as-delivered"])
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.count, 1)

        link.notify("20000138" + "03f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(
                sequence: 824,
                patchId: 247,
                start: Date.fromMedtrumSeconds(0x17CC_31CB).addingTimeInterval(2),
                amount: 0.3,
                delivered: 0.3
            )
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome, "unmatched")
        XCTAssertEqual(delegate.alerts.count, 1, "nothing more")
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained one record")
    }

    // MARK: - The record of a bolus final from our estimate, read after all

    /// The bolus of 1 U of `testCancelledBolusIsRaisedByItsCompletionAndFinalizedWithoutItsRecord`, cancelled at 0.1 U,
    /// the patch's completion of it lost; its record 490 skipped, it goes final at 0.1 U from our estimate. Read after
    /// all, the record says 0.5 U: the host is missing 0.4 U for good - the user is told, once
    func testCancelledBolusFinalFromOurEstimateBelowItsRecordIsToldOfOnce() throws {
        let cancelled = cancelBolusAndFinalizeItFromOurEstimate(progress: "2022100002005c090000000000")
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.first?.recordSequence, 490)

        readRecordOfTheCancelledBolusAgain(delivered: 0.5)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 490 }?.outcome, "answered bolus finalized already")
        XCTAssertEqual(delegate.alerts.count, 1)
        let alert = try XCTUnwrap(delegate.alerts.first)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted"))
        XCTAssertEqual(alert.foregroundContent?.title, "Bolus not fully counted")
        XCTAssertEqual(alert.foregroundContent?.body.contains("show \(0.5.formatted()) U delivered"), true)
        XCTAssertEqual(alert.foregroundContent?.body.contains("the app counted \(0.1.formatted()) U. Add the \(0.4.formatted()) U missing manually."), true)
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its record")

        readRecordOfTheCancelledBolusAgain(delivered: 0.5)
        XCTAssertEqual(delegate.alerts.count, 1, "told of once")
        assertOneFinal(of: cancelled)
    }

    /// The same, its record at the amount it went final at: nothing to tell
    func testCancelledBolusFinalFromOurEstimateAtItsRecordsAmountIsNotToldOf() {
        let cancelled = cancelBolusAndFinalizeItFromOurEstimate(progress: "2022100002005c090000000000")
        readRecordOfTheCancelledBolusAgain(delivered: 0.1)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its record")
        assertOneFinal(of: cancelled)
    }

    /// Cancelled before any progress, final at 0 U from our estimate, its record 0 U delivered: it explains the record -
    /// taken off, not left to crowd out the others - and there is nothing to tell
    func testZeroDeliveredRecordOfABolusFinalFromOurEstimateIsTakenOffSilently() {
        let cancelled = cancelBolusAndFinalizeItFromOurEstimate(progress: nil)
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.count, 1)

        readRecordOfTheCancelledBolusAgain(delivered: 0)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty)
    }

    /// The bolus of 0.3 U whose answer was lost, counted in full at maximumWait - the user told so - and its record read
    /// after all, 0.1 U delivered: the host has 0.2 U too many for good, insulin on board overstated - the user is told,
    /// once
    func testRecordOfABolusCountedInFullThatDeliveredLessIsToldOfOnce() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline(confirmingRecords: false)
        advanceClock(by: 60 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "counted in full")
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), ["com.nightscout.medtrumkit.bolus-counted-as-delivered"])

        link.notify("20000138" + "03f700")
        settle()
        let record = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: Date.fromMedtrumSeconds(0x17CC_31CB).addingTimeInterval(2),
            amount: 0.3,
            delivered: 0.1
        )
        link.script(CommandType.GET_RECORD, record)
        syncRecords()

        XCTAssertEqual(delegate.alerts.count, 2)
        let alert = try XCTUnwrap(delegate.alerts.last)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted"))
        XCTAssertEqual(alert.foregroundContent?.title, "Bolus counted too high")
        XCTAssertEqual(alert.foregroundContent?.body.contains("Insulin on board is overstated by \(0.2.formatted()) U."), true)

        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 2, "told of once")
    }

    /// The same, its record showing nothing delivered - cancelled on the patch before it began: no bolus the host is
    /// missing, but the 0.3 U it counted were never delivered - the user is told
    func testRecordOfABolusCountedInFullThatDeliveredNothingIsToldOf() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline(confirmingRecords: false)
        advanceClock(by: 60 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "counted in full")
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.count, 1)

        link.notify("20000138" + "03f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(
                sequence: 824,
                patchId: 247,
                start: Date.fromMedtrumSeconds(0x17CC_31CB).addingTimeInterval(2),
                amount: 0.3,
                delivered: 0
            )
        )
        syncRecords()

        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its record")
        XCTAssertEqual(delegate.alerts.count, 2)
        XCTAssertEqual(delegate.alerts.last?.foregroundContent?.body.contains("Insulin on board is overstated by \(0.3.formatted()) U."), true)
    }

    // MARK: - A record that could be that of a bolus whose answer was lost

    /// The bolus of 0.3 U whose answer was lost; record 824, of 0.3 U, starts 5 min after it went out - further than its
    /// record would, but it could be its, the patch clock off: not told of, kept. The bolus goes final from our estimate,
    /// counted in full - the record taken for its, at its amount: nothing more to tell, nor read again
    func testPossibleRecordOfAnUnansweredBolusFinalFromOurEstimateIsTakenForItsRecord() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        let record = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: patchSentAt.addingTimeInterval(5 * Self.minute),
            amount: 0.3,
            delivered: 0.3
        )
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome, "unmatched")
        XCTAssertEqual(delegate.alerts.count, 0, "it could be ours")
        XCTAssertEqual(pumpManager.state.possibleBolusRecords.map(\.sequence), [824])

        advanceClock(by: 15 * Self.minute)
        syncRecords()
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "counted in full")
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), ["com.nightscout.medtrumkit.bolus-counted-as-delivered"])
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.count, 1, "kept all the same: 824 may be another's")

        // Read again - the app killed before the cursor past it was saved, say
        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 1, "nothing more")
    }

    /// The same record 824, kept; then the bolus's own, 825, near when it went out, finalizes it: 824 was no bolus of
    /// ours after all - delivered, missing at the host - and the user is told, once
    func testPossibleRecordOfAnUnansweredBolusFinalByItsOwnRecordIsToldOf() throws {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        let possible = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: patchSentAt.addingTimeInterval(5 * Self.minute),
            amount: 0.3,
            delivered: 0.3
        )
        link.script(CommandType.GET_RECORD, possible)
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 0, "it could be ours")

        link.notify("200001" + "3903f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 825, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        assertOneFinal(of: started)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 825 }?.outcome?.hasPrefix("finalized bolus"), true)

        XCTAssertEqual(delegate.alerts.count, 1)
        let alert = try XCTUnwrap(delegate.alerts.first)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted"))
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)

        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, possible)
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 825, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 1, "told of once")
    }

    /// As `testPossibleRecordOfAnUnansweredBolusFinalFromOurEstimateIsTakenForItsRecord`, 824 another bolus's after all -
    /// one the host is missing: the bolus's own, 825, near when it went out, is read later - it explains it, at the
    /// amount the host has: nothing to tell of it; 824 is told of, once
    func testOwnRecordOfABolusAPossibleRecordWasTakenForTellsOfThatOne() throws {
        let (started, patchSentAt) = try takePossibleRecordAndReadTheBolussOwn(possibleDelivered: 0.3, ownDelivered: 0.3)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 825 }?.outcome, "unmatched")
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its own record")
        XCTAssertEqual(delegate.alerts.count, 2)
        try assertToldOfNotCounted(delegate.alerts.last, 0.3)

        // Read again - the app killed before the cursor past them was saved, say
        pumpManager.state.syncedSequenceNumber = 823
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(5 * Self.minute), amount: 0.3, delivered: 0.3)
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 825, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 2, "told of once")
        assertOneFinal(of: started)
    }

    /// The same, 824 delivering 0.1 U of its 0.3 U: as it was taken, the user was told the bolus was counted too high -
    /// by its numbers. The bolus's own, 825, shows the 0.3 U the host has: nothing more of it - the miscount told of
    /// before is not taken back - and 824's 0.1 U are told of as not counted
    func testOwnRecordOfABolusAPossibleRecordThatDeliveredLessWasTakenForTellsOfThatOne() throws {
        let (started, _) = try takePossibleRecordAndReadTheBolussOwn(possibleDelivered: 0.1, ownDelivered: 0.3) {
            XCTAssertEqual(self.delegate.alerts.count, 2)
            XCTAssertTrue(
                self.delegate.alerts.contains { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted") },
                "by 824's numbers"
            )
        }
        XCTAssertEqual(delegate.alerts.count, 3)
        try assertToldOfNotCounted(delegate.alerts.last, 0.1)
        assertOneFinal(of: started)
    }

    /// The same, 825 delivering 0.1 U too: the user was told of the bolus counted too high as 824 was taken - nothing
    /// more of it; 824's 0.1 U are told of as not counted
    func testOwnRecordAtWhatTheRecordTakenForItDeliveredIsNotComparedAgain() throws {
        let (started, _) = try takePossibleRecordAndReadTheBolussOwn(possibleDelivered: 0.1, ownDelivered: 0.1) {
            XCTAssertEqual(self.delegate.alerts.count, 2)
        }
        XCTAssertEqual(delegate.alerts.count, 3, "no second miscount")
        XCTAssertEqual(delegate.alerts.filter { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted") }.count, 1)
        try assertToldOfNotCounted(delegate.alerts.last, 0.1)
        assertOneFinal(of: started)
    }

    /// The bolus of 0.3 U whose answer was lost; record 824, of 0.3 U, `possibleDelivered`, 5 min off, kept; the bolus
    /// goes final from our estimate, counted in full, 824 taken for its record - `afterTheTake` - then its own, 825,
    /// `ownDelivered`, is read. Returns the bolus as it started, and when it went out on the patch clock.
    private func takePossibleRecordAndReadTheBolussOwn(
        possibleDelivered: Double,
        ownDelivered: Double,
        afterTheTake: () -> Void = {}
    ) throws -> (started: DoseEntry?, patchSentAt: Date) {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(5 * Self.minute), amount: 0.3, delivered: possibleDelivered)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 0, "it could be ours")
        advanceClock(by: 15 * Self.minute)
        syncRecords()
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "counted in full")
        XCTAssertTrue(delegate.alerts.contains { $0.identifier.alertIdentifier == "com.nightscout.medtrumkit.bolus-counted-as-delivered" })
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.first?.taken?.sequence, 824)
        afterTheTake()
        let toldAtTheTake = delegate.alerts.count

        link.notify("200001" + "3903f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 825, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: ownDelivered)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, toldAtTheTake + 1, "824, once")
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its own record")
        return (started, patchSentAt)
    }

    private func assertToldOfNotCounted(_ alert: Alert?, _ units: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let alert = try XCTUnwrap(alert, file: file, line: line)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted"), file: file, line: line)
        XCTAssertEqual(
            alert.foregroundContent?.body.contains("a bolus of \(units.formatted()) U delivered"),
            true,
            file: file,
            line: line
        )
    }

    /// Record 824, 5 min off, kept as possibly that of the unanswered bolus; then the patch clock is found that much
    /// further ahead, and 824 read again - the app killed before the cursor past it was saved, say: near enough now, it
    /// finalizes the bolus - settled with it, not told of as a bolus the host is missing
    func testPossibleRecordThatFinalizesItsBolusWhenReadAgainIsNotToldOf() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        let record = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: patchSentAt.addingTimeInterval(5 * Self.minute),
            amount: 0.3,
            delivered: 0.3
        )
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(pumpManager.state.possibleBolusRecords.map(\.sequence), [824])
        XCTAssertEqual(finals(of: started).count, 0)

        pumpManager.state.pumpTime = pumpManager.state.pumpTime.addingTimeInterval(5 * Self.minute)
        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, record)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)
    }

    /// The bolus of 0.3 U whose answer was lost, seen delivering since - confirmed by its progress, then completed, no
    /// record named: its record is looked for by when it went out all the same. Record 824, 5 min off, read then, could
    /// be its - kept, not told of; it goes final from our estimate, and 824 is taken for its record.
    func testPossibleRecordOfABolusWhoseAnswerWasLostReadAfterItsProgressIsNotToldOf() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        link.notify("2022100002005c090000000000") // 0.1 U
        settle()
        XCTAssertEqual(pumpManager.state.bolusDose?.confirmation, .confirmed)
        link.notify("200200800600") // completed at 0.3 U, no record named
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(5 * Self.minute), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome, "unmatched")
        XCTAssertEqual(delegate.alerts.count, 0, "it could be its")
        XCTAssertEqual(pumpManager.state.possibleBolusRecords.map(\.sequence), [824])

        advanceClock(by: 60 * Self.minute)
        syncRecords()
        assertOneFinal(of: started)
        XCTAssertFalse(delegate.alerts.contains { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted") })
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)
    }

    /// The bolus of 0.3 U whose answer was lost, cancelled before any progress came: record 824, of 0.3 U, 5 min off,
    /// read then, could be its - kept. Only then its completion, 0.1 U naming 824 - its own: confirmed, its answer still
    /// lost. Final from our estimate at 0.1 U, 824 is taken for its record, at that amount: nothing to tell.
    func testPossibleRecordKeptBeforeTheBolusWasConfirmedIsTakenForItsRecord() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(5 * Self.minute), amount: 0.3, delivered: 0.1)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertEqual(pumpManager.state.possibleBolusRecords.map(\.sequence), [824])

        link.notify(Self.completion(delivered: 2, record: 824, patch: "f700"))
        settle()
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.confirmation, .confirmed)
        XCTAssertNil(pumpManager.state.awaitingRecord.first?.recordSequence)

        advanceClock(by: 60 * Self.minute)
        syncRecords()
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)
    }

    /// The bolus of 1 U of `testCancelledBolusIsRaisedByItsCompletionAndFinalizedWithoutItsRecord` answered as record
    /// 490, `progress` - if any - shown, cancelled, the patch's completion of it lost; the patch then names 490 the newest,
    /// which comes back garbled: skipped, the bolus final from our estimate 15 min later. Returns its first report.
    private func cancelBolusAndFinalizeItFromOurEstimate(progress: String?) -> DoseEntry? {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 489, reservoir: 119.9)
        state.basalDose = runningTempBasal(rate: 0.65, startedAgo: 10 * Self.minute, duration: 30 * Self.minute)
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f1303000000ea01ec0059afa9174700")
        XCTAssertNil(commandBolus(1.0))
        let started = reports(of: .bolus).first
        if let progress {
            link.notify(progress)
        }
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return started
        }
        settle()

        link.notify("200001" + "ea01ec00")
        settle()
        let garbled = FakeMedtrumLink.Answer.garbled(
            PatchBytes.bolusRecord(sequence: 490, patchId: 236, start: Date.fromMedtrumSeconds(0x17A9_AF59), amount: 1, delivered: 0.5)
        )
        link.script(CommandType.GET_RECORD, garbled)
        link.script(CommandType.GET_RECORD, garbled)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 490)
        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(delegate.alerts.count, 0)
        return started
    }

    /// Record 490 of `cancelBolusAndFinalizeItFromOurEstimate` read again, delivering `delivered`
    private func readRecordOfTheCancelledBolusAgain(delivered: Double) {
        pumpManager.state.syncedSequenceNumber = 489
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 490, patchId: 236, start: Date.fromMedtrumSeconds(0x17A9_AF59), amount: 1, delivered: delivered)
        )
        syncRecords()
    }

    /// Sends a bolus of `units` the patch answers with `answer`, `answerTakes` seconds after it went out. Returns the state
    /// the host had as it went out - saved before it was written - and the outcome. The run that sent it leaves nothing
    /// pending.
    func sendBolus(
        _ units: Double,
        _ answer: FakeMedtrumLink.Answer,
        activationType: BolusActivationType = .manualNoRecommendation,
        answerTakes: TimeInterval = 0
    ) throws -> (atWrite: PumpManager.RawStateValue, error: PumpManagerError?) {
        let atWrite = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_BOLUS, answer) { [unowned self] in
            atWrite.value = delegate.savedState
            Thread.sleep(forTimeInterval: answerTakes)
        }

        let error = commandBolus(units, activationType: activationType)
        settle()

        XCTAssertNil(pumpManager.state.pendingBolus, "cleared as its outcome came in")
        XCTAssertNil(delegate.savedState?["pendingBolus"])
        return (try XCTUnwrap(atWrite.value, "nothing handed over before the write"), error)
    }

    /// 0.3 U answered as record 824 and cancelled at once, the patch's completion of it lost with the link: the record
    /// number known stays 823. The next SetBolus of 0.3 U gets no answer, and the patch never runs it. Record 824 - at
    /// its amount, starting near when it went out - is the cancelled bolus's, its answer claimed it: no record the
    /// unanswered one could have. Every record past 823 read, none its: final at 0 U.
    func testRecordAnAnsweredBolusClaimedCouldBeNoUnansweredBolussOwn() throws {
        makeManager(unansweredBolusState())
        let patchSentAt = pumpManager.state.pumpTime

        link.script(
            CommandType.SET_BOLUS,
            PatchBytes.answer(
                command: CommandType.SET_BOLUS,
                body: UInt64(824).toData(length: 2) + UInt64(247).toData(length: 2) + patchSentAt.toMedtrumSeconds()
            )
        )
        XCTAssertNil(commandBolus(0.3))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        let cancelled = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 823)

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)
        link.script(CommandType.SET_BOLUS, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandBolus(0.3)))
        settle()
        let unanswered = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != cancelled.syncIdentifier })
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0)
        )
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome?.hasPrefix("finalized bolus"), true)
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: unanswered)
        XCTAssertEqual(finals(of: unanswered).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The same, the other way round: the SetBolus of 0.3 U unanswered and never run first, ended at its deadline, then
    /// 0.3 U answered as record 824 and cancelled at once. Record 824 starts near when the unanswered one went out - the
    /// patch clock off - and is past the 823 known then, but the answer claimed it: the cancelled bolus's, by its
    /// number, and no record the unanswered one could have. Final at 0 U.
    func testRecordABolusSentLaterClaimedCouldBeNoUnansweredBolussOwn() throws {
        startUnansweredBolus()
        let unanswered = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)
        link.script(
            CommandType.SET_BOLUS,
            PatchBytes.answer(
                command: CommandType.SET_BOLUS,
                body: UInt64(824).toData(length: 2) + UInt64(247).toData(length: 2) + pumpManager.state.pumpTime
                    .toMedtrumSeconds()
            )
        )
        XCTAssertNil(commandBolus(0.3))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        let cancelled = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != unanswered.syncIdentifier })

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0)
        )
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome?.hasPrefix("finalized bolus"), true)
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(finals(of: unanswered).count, 0)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: unanswered)
        XCTAssertEqual(finals(of: unanswered).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }
}

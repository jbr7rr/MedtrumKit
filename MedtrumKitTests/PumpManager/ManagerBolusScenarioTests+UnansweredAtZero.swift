@testable import MedtrumKit
import XCTest

extension ManagerBolusScenarioTests {
    // MARK: - An unanswered bolus at 0 U: what keeps it in full

    /// The SetBolus of 0.3 U unanswered and ended past its deadline; record 824 skipped, unreadable, and 825 then read in
    /// its own place: the records past 823 were not all read in order - 824 could have been its. Counted in full, the
    /// host told so.
    func testUnansweredBolusIsCountedInFullWithARecordSkippedBeforeOneReadInPlace() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3903f700")
        settle()
        let garbled = FakeMedtrumLink.Answer.garbled(PatchBytes.otherRecord(type: 3, sequence: 824, patchId: 247))
        link.script(CommandType.GET_RECORD, garbled)
        link.script(CommandType.GET_RECORD, garbled)
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 825, patchId: 247))
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 825)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The same, record 824 read in its own place but of another patch: says nothing of ours, which could be it.
    /// Counted in full, the host told so.
    func testUnansweredBolusIsCountedInFullWithAnotherPatchsRecordInPlace() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 824, patchId: 0x1234))
        syncRecords()

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The SetBolus of 0.3 U unanswered, ended past its deadline, every record read: the session ending then, before
    /// its 15 min, finalizes it at 0 U as the no-record rule would have - nothing to tell the user
    func testUnansweredBolusThePatchNeverRanIsFinalizedAtZeroAsTheSessionEnds() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()
        XCTAssertEqual(finals(of: started).count, 0)

        pumpManager.forceDeactivatePatch()
        settle()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The same, the phone clock set an hour back before the session ends: by the wall clock it is not past its deadline
    /// - counted in full, the host told so
    func testUnansweredBolusIsCountedInFullAsTheSessionEndsBeforeItsDeadlineByTheWallClock() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()

        changeWallClock(by: -Self.hour)
        pumpManager.forceDeactivatePatch()
        settle()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The phone clock an hour ahead as the patch told its newest record, 823, then set right; the SetBolus of 0.3 U
    /// unanswered, ended past its deadline by a full status that tells nothing of the records. By the wall clock the
    /// telling comes after its deadline, by the monotonic clock before the bolus went out: not told since - counted in
    /// full, the host told so.
    func testUnansweredBolusIsCountedInFullWithTheRecordNumberToldOnlyBeforeTheClockWentBack() {
        makeManager(unansweredBolusState())
        changeWallClock(by: Self.hour)
        confirmRecordSequence()
        changeWallClock(by: -Self.hour)

        link.script(CommandType.SET_BOLUS, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandBolus(0.3)))
        settle()
        let started = delegate.batches.first?.events.first?.dose

        advanceClock(by: 173)
        link.deliverFullStatus(notification: "200000", duringReconnect: false)
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertGreaterThan(pumpManager.state.sequenceConfirmedAt ?? .distantPast, pumpManager.now(), "told later, by the wall clock")

        // Final at the longest wait, whatever the wall clock's telling makes of the records read
        advanceClock(by: 61 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The same telling, saved, and the app killed as the SetBolus awaited its answer: a telling of the run before says
    /// nothing of when its deadline passed - counted in full, the host told so
    func testBolusAwaitingItsAnswerWhenTheAppWasKilledIsCountedInFullWithTheRecordNumberToldOnlyInTheRunBefore() throws {
        makeManager(unansweredBolusState())
        changeWallClock(by: Self.hour)
        confirmRecordSequence()
        changeWallClock(by: -Self.hour)

        try restart(from: try sendBolus(0.3, .timeout).atWrite)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertNotNil(pumpManager.state.sequenceConfirmedAt, "saved")

        advanceClock(by: 173)
        link.deliverFullStatus(notification: "200000", duringReconnect: false)
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The SetBolus of 0.3 U unanswered; the patch tells its newest record, 823, a minute after it went out - before its
    /// deadline, when its record would not be written yet - then a full status that tells nothing of the records ends
    /// it. Not told since its deadline: counted in full at the longest wait, the host told so.
    func testUnansweredBolusIsCountedInFullWithTheRecordNumberToldOnlyBeforeItsDeadline() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose

        advanceClock(by: 60)
        confirmRecordSequence()
        advanceClock(by: 113)
        link.deliverFullStatus(notification: "200000", duringReconnect: false)
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        advanceClock(by: 61 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The SetBolus of 0.3 U unanswered, and the phone clock set an hour ahead right after: by it, the next full status
    /// - 10 s later - finds it past its deadline and ends it, and later tellings of 823 come after the deadline. Not by
    /// the monotonic clock: counted in full, the host told so.
    func testUnansweredBolusIsCountedInFullAsTheWallClockJumpsForwardRightAfterItWentOut() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose

        changeWallClock(by: Self.hour)
        uptimeOffset.mutate { $0 += 10 }
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        XCTAssertNil(pumpManager.state.bolusDose, "past its deadline by the wall clock")

        changeWallClock(by: 1 * Self.minute)
        uptimeOffset.mutate { $0 += 10 }
        confirmRecordSequence()
        changeWallClock(by: 16 * Self.minute)
        uptimeOffset.mutate { $0 += 10 }
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The SetBolus of 0.3 U unanswered, the phone asleep - its screen locked - between the wakes that bring the
    /// statuses: the monotonic clock counts sleep as the wall clock does. Ended past its deadline, every record read,
    /// 823 told three times over 15 min: it never ran, final at 0 U as with the phone awake, nothing to tell the user.
    func testUnansweredBolusThePatchNeverRanIsFinalizedAtZeroAcrossPhoneSleep() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose

        // Asleep all but the moment each status comes in
        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        for _ in 0 ..< 3 {
            advanceClock(by: 5 * Self.minute)
            confirmRecordSequence()
        }
        advanceClock(by: 1 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The SetBolus of 0.3 U unanswered, ended past its deadline; the temp basal is then cancelled, its record 824 read
    /// as it ends - in its own place, as a sync would: every record past 823 read, none its. Final at 0 U 15 min after
    /// the bolus ended, nothing to tell the user.
    func testUnansweredBolusCountsTheRecordsReadAsATempBasalEnds() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()

        cancelTempBasalReadingItsRecords(cancelRecord: 824, [unansweredBolusTempBasalRecord(sequence: 824)])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 824)
        XCTAssertEqual(finals(of: started).count, 0, "not 15 min yet")

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The same, had the patch run it: its record 824 is read as the temp basal ends, before the temp basal's 825 - and
    /// finalizes it, with no warning
    func testUnansweredBolusIsFinalizedByItsRecordReadAsATempBasalEnds() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        cancelTempBasalReadingItsRecords(cancelRecord: 825, [
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(2), amount: 0.3, delivered: 0.3),
            unansweredBolusTempBasalRecord(sequence: 825)
        ])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 825)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome?.hasPrefix("finalized bolus"), true)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }
}

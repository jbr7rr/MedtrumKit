import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerTempBasalBackToBackScenarioTests {
    // MARK: - Loop's watermark

    /// An unanswered set with no cancel before it - the schedule running, put in place by a cancel to it, its segment's
    /// start on the patch clock known - our reading of the patch clock an hour off either way: the set's record is told
    /// from that segment, on each clock alone - matched, dated after the schedule
    func testUnansweredSetWithNoCancelIsMatchedFromTheSchedulesSegmentWithThePatchClockAnHourAhead() throws {
        try assertUnansweredSetWithNoCancelIsMatched(patchAhead: 3600)
    }

    func testUnansweredSetWithNoCancelIsMatchedFromTheSchedulesSegmentWithThePatchClockAnHourBehind() throws {
        try assertUnansweredSetWithNoCancelIsMatched(patchAhead: -3600)
    }

    private func assertUnansweredSetWithNoCancelIsMatched(patchAhead: TimeInterval, line: UInt = #line) throws {
        runFirst(patchAhead: patchAhead)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0, duration: 0), line: line)
        settle()
        let schedule = try XCTUnwrap(reports(of: .basal).last, line: line)

        // The set as the patch has it: 61 s after the schedule's segment began
        advanceClock(by: 61.5)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)), line: line)
        settle()
        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_TEMP_BASAL, "no cancel", line: line)

        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(61),
            end: Self.end1.addingTimeInterval(181), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, line: line)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 }, line: line)
        XCTAssertEqual(set.isMutable, false, line: line)
        XCTAssertEqual(set.startDate.timeIntervalSince(schedule.startDate), 61, accuracy: 0.5, line: line)
        XCTAssertEqual(set.endDate.timeIntervalSince(set.startDate), 120, accuracy: 0.5, line: line)
    }

    /// The patch had stopped the 1.2 U/h one 5 min before the cancel to the schedule; then a set from that schedule, no
    /// cancel before it, goes out unanswered: the schedule's start on both clocks is one instant - the cancel on ours,
    /// its patch time 300 s after where the segment began - so the set's record, 61 s after the schedule, is its own
    func testUnansweredSetFromAScheduleAfterAnEarlyStopIsMatched() throws {
        runFirst()
        let stoppedAt = Self.end1.addingTimeInterval(-300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: stoppedAt))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.3, end: stoppedAt))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        let schedule = try XCTUnwrap(reports(of: .basal).last)

        advanceClock(by: 61.5)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()

        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(61),
            end: Self.end1.addingTimeInterval(181), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
        XCTAssertEqual(set.startDate.timeIntervalSince(schedule.startDate), 61, accuracy: 0.5, "at its record's start")
    }

    /// The same early stop, the set right after the answered cancel unanswered: its anchor is the cancel on our clock and
    /// that instant on the patch's - not where the stopped segment began - so its record is its own
    func testUnansweredSetAfterACancelOfAnEarlyStoppedTempBasalIsMatched() throws {
        freezesManagerClock = true
        runFirst()
        let stoppedAt = Self.end1.addingTimeInterval(-300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: stoppedAt))
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()
        let schedule = try XCTUnwrap(reports(of: .basal).last)

        // Its record read once it began: not dated in our future
        advanceClock(by: 2)
        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.3, end: stoppedAt))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(1),
            end: Self.end1.addingTimeInterval(121), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
        XCTAssertEqual(set.isMutable, false)
        XCTAssertEqual(set.startDate.timeIntervalSince(schedule.startDate), 1, accuracy: 0.5, "at its record's start")
    }

    /// The cancel to the schedule answered 8 s late, the patch having ended the 1.2 U/h one 2 s before the cancel went out
    /// - not a stop before it, but its record ends 10 s before the schedule is dated: its final ends there, and the
    /// schedule's start on the patch clock pairs with nothing - the set from it after, unanswered, is told through the
    /// skew: its record, 61 s after the cancel went out on the patch clock, is matched and dated at its start
    func testUnansweredSetFromAScheduleAfterARecordedEndIsDatedAtItsRecordsStart() throws {
        let first = runFirst()
        let endedAt = Self.end1.addingTimeInterval(-2)
        link.script(CommandType.CANCEL_TEMP_BASAL, .fragments(cancelAnswer(record: 131, at: endedAt))) { [unowned self] in
            advanceClock(by: 8)
        }
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35, end: endedAt))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(final.endDate.timeIntervalSince(first.startDate), 1198, accuracy: 0.5, "its record's end")
        XCTAssertNil(pumpManager.state.basalDose.pumpStartTime)

        advanceClock(by: 61.5)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()

        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(69),
            end: Self.end1.addingTimeInterval(189), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
        XCTAssertEqual(set.startDate.timeIntervalSince(first.startDate), 1200 + 69, accuracy: 0.5, "at its record's start")
    }

    /// A set from the schedule goes out unanswered and never runs; 5 min on, a cancel-only for it is answered with the
    /// schedule's segment, still running from `end1`: the schedule after it starts that much later on the patch clock as
    /// well - not where the segment began - so a set from it after, unanswered but run, is matched to its record and
    /// dated at its start
    func testUnansweredSetAfterACancelOfAnUnconfirmedOneThatNeverRanIsMatched() throws {
        freezesManagerClock = true
        runFirst()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        advanceClock(by: 60)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.3, duration: 30 * Self.minute)))
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        let schedule = try XCTUnwrap(reports(of: .basal).last)
        let onPatch = try XCTUnwrap(pumpManager.state.basalDose.pumpStartTime)
        XCTAssertEqual(onPatch.timeIntervalSince(Self.end1), 360, accuracy: 0.5, "the cancel's instant on the patch clock")

        advanceClock(by: 61.5)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()
        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_TEMP_BASAL, "no cancel")

        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(421),
            end: Self.end1.addingTimeInterval(541), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
        XCTAssertEqual(set.isMutable, false)
        XCTAssertEqual(set.startDate.timeIntervalSince(schedule.startDate), 61, accuracy: 0.5, "at its record's start")
    }

    /// `LoopWatermark` as LoopKit makes it: a final moves it to its end; a 0-s scheduled basal moves nothing; a dose
    /// reported after a gap - mutable or not - moves it to its start, the gap filled; a suspend ended by its resume to
    /// the resume. A dose new to the host starting before it is behind it.
    func testLoopWatermarkMovesAsLoopKitMovesIt() {
        checksLoopOrdering = false
        let t0 = Date.now
        func tempBasal(_ start: TimeInterval, _ end: TimeInterval, mutable: Bool) -> NewPumpEvent {
            NewPumpEvent.tempBasal(dose: DoseEntry(
                type: .tempBasal, startDate: t0.addingTimeInterval(start), endDate: t0.addingTimeInterval(end), value: 1,
                unit: .unitsPerHour, deliveredUnits: mutable ? nil : 0.1, isMutable: mutable
            ))
        }
        func basal(_ at: TimeInterval) -> NewPumpEvent {
            NewPumpEvent.basal(dose: DoseEntry(type: .basal, startDate: t0.addingTimeInterval(at), value: 0.7, unit: .unitsPerHour))
        }

        var mark = LoopWatermark()
        mark.store([tempBasal(0, 600, mutable: false), basal(600)], replacePendingEvents: true)
        XCTAssertEqual(mark.date, t0.addingTimeInterval(600))
        mark.store([basal(900)], replacePendingEvents: true)
        XCTAssertEqual(mark.date, t0.addingTimeInterval(600), "a 0-s scheduled basal moves nothing")
        XCTAssertEqual(mark.store([tempBasal(700, 800, mutable: false)], replacePendingEvents: true).count, 0, "not behind it")
        XCTAssertEqual(mark.date, t0.addingTimeInterval(800))

        mark.store([tempBasal(1200, 3000, mutable: true)], replacePendingEvents: true)
        XCTAssertEqual(mark.date, t0.addingTimeInterval(1200), "a mutable one after a gap: the fill up to its start")
        let behind = mark.store([tempBasal(1000, 1100, mutable: false), tempBasal(1200, 3000, mutable: true)], replacePendingEvents: true)
        XCTAssertEqual(behind.map(\.startDate), [t0.addingTimeInterval(1000)], "new, and before it: never stored")

        // Nothing stored yet: Loop syncs from 24 h back, the first dose's start at least
        var fresh = LoopWatermark()
        fresh.store([tempBasal(100, 1900, mutable: true)], replacePendingEvents: true)
        XCTAssertEqual(fresh.date, t0.addingTimeInterval(100))

                var suspended = LoopWatermark(date: t0)
        suspended.store([
            NewPumpEvent.suspend(dose: DoseEntry(suspendDate: t0)),
            NewPumpEvent.resume(dose: DoseEntry(resumeDate: t0.addingTimeInterval(300)))
        ], replacePendingEvents: true)
        XCTAssertEqual(suspended.date, t0.addingTimeInterval(300), "the suspend, ended by its resume")
    }

    // MARK: - The checker

    /// The checker trips on each rule broken, from batches no manager should send
    func testLoopOrderingCheckerTripsOnEachRule() {
        checksLoopOrdering = false
        // On a whole second: the iAPS rules go by whole seconds
        let t0 = LoopOrderingChecker.stored(Date.now)
        func tempBasal(_ start: TimeInterval, _ end: TimeInterval, rate: Double, mutable: Bool, delivered: Double? = nil) -> NewPumpEvent {
            NewPumpEvent.tempBasal(dose: DoseEntry(
                type: .tempBasal,
                startDate: t0.addingTimeInterval(start),
                endDate: t0.addingTimeInterval(end),
                value: rate,
                unit: .unitsPerHour,
                deliveredUnits: mutable ? nil : delivered ?? 0.1,
                isMutable: mutable
            ))
        }
        func basal(_ at: TimeInterval) -> NewPumpEvent {
            NewPumpEvent.basal(dose: DoseEntry(type: .basal, startDate: t0.addingTimeInterval(at), value: 0.7, unit: .unitsPerHour))
        }
        func rules(_ batches: [[NewPumpEvent]]) -> Set<Int> {
            Set(LoopOrderingChecker.violations(in: batches.map { LoopOrderingChecker.Batch(events: $0) }).map(\.rule))
        }

        // Fine: ended open where the next starts, then final in order
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)],
            [tempBasal(0, 600, rate: 1.2, mutable: false), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [])
        // A final ending short of where its mutable report had it - its records say so: the host fills the gap, fine. A
        // mutable one short of the next one is not.
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)],
            [tempBasal(0, 300, rate: 1.2, mutable: false), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [])
        XCTAssertEqual(rules([
            [tempBasal(0, 599, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [1, 6], "the fill up to the next one passes it")
        // 1: a final shorter than a second that delivered - Loop drops it - and one earlier than its report that short
        XCTAssertEqual(rules([
            [tempBasal(0, 0, rate: 1.2, mutable: false, delivered: 0.4), basal(0)]
        ]), [1])
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)],
            [tempBasal(0, 0.5, rate: 1.2, mutable: false, delivered: 0.4), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [1])
        // 1: a final past where the next starts
        XCTAssertEqual(rules([
            [tempBasal(0, 601, rate: 1.2, mutable: false), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [1, 2])
        // 2: a later one final first
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 900, rate: 0.5, mutable: false), tempBasal(900, 2700, rate: 0.8, mutable: true)]
        ]), [2, 6])
        // 3: the schedule after a chain still mutable
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 900, rate: 0.5, mutable: false), basal(900)]
        ]), [2, 3, 6])
        // 4: a replacing batch leaving out the one ended
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)],
            [tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [4])
        // 5: a scheduled basal between two back to back
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: false), basal(599), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [1, 5])
        // 6: a dose new to the host starting before the watermark - final or mutable
        XCTAssertEqual(rules([
            [tempBasal(600, 900, rate: 0.5, mutable: false)],
            [tempBasal(300, 600, rate: 1.2, mutable: false)]
        ]), [6])
        XCTAssertEqual(rules([
            [tempBasal(600, 900, rate: 0.5, mutable: false)],
            [tempBasal(800, 2600, rate: 1.2, mutable: true)]
        ]), [1, 2, 6])
        // 7: oref0's pairing broken - a resume with no suspend before it, stored ahead of it or with none (one in the
        // same batch is fine), one no suspend pairs with, or a suspend paired with a resume past the next suspend
        func suspend(_ at: TimeInterval) -> NewPumpEvent {
            NewPumpEvent.suspend(dose: DoseEntry(suspendDate: t0.addingTimeInterval(at)))
        }
        func resume(_ at: TimeInterval) -> NewPumpEvent {
            NewPumpEvent.resume(dose: DoseEntry(resumeDate: t0.addingTimeInterval(at)))
        }
        XCTAssertEqual(rules([[resume(600)], [suspend(300)]]), [7])
        XCTAssertEqual(rules([[resume(600)]]), [7])
        XCTAssertEqual(rules([[suspend(300), resume(600)]]), [])
        XCTAssertEqual(rules([[suspend(300)], [resume(600)]]), [])
        XCTAssertEqual(rules([[suspend(300), resume(300)]]), [7], "at the same instant: not paired")
        XCTAssertEqual(rules([[suspend(300.2), resume(300.7)]]), [7], "in the same second, as iAPS stores them: not paired")
        XCTAssertEqual(rules([[suspend(300.7), resume(301.2)]]), [], "in the next second")
        XCTAssertEqual(Set(LoopOrderingChecker.violations(in: [LoopOrderingChecker.Batch(events: [resume(600)])], suspendedSince: t0).map(\.rule)), [])
        // Not only the earliest suspend and the latest: S1 and R1 in one second, between S0/R0 and S2/R2 - oref0 pairs S1
        // with R2, past S2, R1 with none: what ran from R1 to S2 zeroed. The same with R1 lost.
        XCTAssertEqual(rules([[suspend(300), resume(600)], [suspend(900.2), resume(900.7)], [suspend(1200), resume(1500)]]), [7])
        XCTAssertEqual(rules([[suspend(300), resume(600)], [suspend(900)], [suspend(1200), resume(1500)]]), [7])
        XCTAssertEqual(rules([[suspend(300), resume(600)], [suspend(900.7), resume(901.2)], [suspend(1200), resume(1500)]]), [])
        XCTAssertEqual(rules([[suspend(300), resume(600)], [suspend(900), resume(1200)]]), [])
        // A suspend in its resume's second - the patch suspended again at once - is paired with the next resume: fine
        XCTAssertEqual(rules([[suspend(300), resume(600.2)], [suspend(600.7)], [resume(900)]]), [])
        // 8: the patch delivering, a suspend with no resume strictly after it
        func rulesDelivering(_ batches: [[NewPumpEvent]], _ delivering: Bool = true, suspendedSince: Date? = nil) -> Set<Int> {
            Set(LoopOrderingChecker.violations(
                in: batches.map { LoopOrderingChecker.Batch(events: $0) }, suspendedSince: suspendedSince, delivering: delivering
            ).map(\.rule))
        }
        XCTAssertEqual(rulesDelivering([[suspend(300)]]), [8])
        XCTAssertEqual(rulesDelivering([[suspend(300)]], false), [], "still suspended")
        XCTAssertEqual(rulesDelivering([[suspend(300), resume(600)]]), [])
        XCTAssertEqual(rulesDelivering([[suspend(300.2), resume(300.7)]]), [7, 8], "in the same second: left open")
        XCTAssertEqual(rulesDelivering([[suspend(300.7), resume(301.2)]]), [])
        XCTAssertEqual(rulesDelivering([[suspend(300), resume(600)], [suspend(900)]]), [8])
        XCTAssertEqual(rulesDelivering([[suspend(300), resume(600)], [suspend(900.2), resume(900.7)]]), [7, 8], "S1 in R1's second: open")
        // Both paired with the one resume: right only if the patch never resumed between them - a resume lost there
        // looks the same
        XCTAssertEqual(rulesDelivering([[suspend(300)], [suspend(900), resume(1200)]]), [7])
        XCTAssertEqual(rulesDelivering([[suspend(300)], [suspend(900)]]), [8], "the first left open, the second dropped")
        XCTAssertEqual(rulesDelivering([[resume(600)]], suspendedSince: t0), [])
        XCTAssertEqual(rulesDelivering([[tempBasal(0, 600, rate: 1.2, mutable: true)]], suspendedSince: t0), [8])
        // A batch the host could not store changes nothing
        XCTAssertEqual(Set(LoopOrderingChecker.violations(in: [
            LoopOrderingChecker.Batch(events: [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)]),
            LoopOrderingChecker.Batch(events: [tempBasal(600, 2400, rate: 0.5, mutable: true)], stored: false)
        ]).map(\.rule)), [])
    }
}

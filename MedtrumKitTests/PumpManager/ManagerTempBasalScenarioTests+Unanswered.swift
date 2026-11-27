import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerTempBasalScenarioTests {
    // MARK: - The temp basal whose command went unanswered, and the ones after it

    /// `startUnansweredTempBasal`, then 1 U/h set - its cancel names 120, the zero temp basal's record had it run, read in
    /// the command before the set: `inCommand` - and answered. Unread there, it is read again after the command:
    /// `afterCommand`
    private func setAfterTheUnansweredTempBasal(
        inCommand: FakeMedtrumLink.Answer,
        afterCommand: FakeMedtrumLink.Answer? = nil,
        patchUTCOffset: TimeInterval? = nil,
        advancingClock: TimeInterval = 0
    ) {
        startUnansweredTempBasal(patchUTCOffset: patchUTCOffset)
        // Our clock up to the cancel, as the patch has it: 301 s after the cancel's segment before the zero one
        advanceClock(by: advancingClock)
        let c1 = Self.patchTime(399_933_337 + 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: c1
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: c1.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, inCommand)
        if let afterCommand {
            link.script(CommandType.GET_RECORD, afterCommand)
        }
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()
    }

    /// Records 120 - 124: the zero temp basal, run from the cancel's second before it up to the cancel `c1`, the second of schedule, the 1 U/h one up to `c2`,
    /// the second of schedule, the 2 U/h one up to `c3`
    static let c1 = patchTime(399_933_337 + 300)
    private static let c2 = c1.addingTimeInterval(300)
    private static let c3 = c2.addingTimeInterval(300)
    private static let recordOfTheZero = PatchBytes.basalRecord(
        sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: patchTime(399_933_336), end: c1, rate: 0, delivered: 0
    )
    private static let recordOfTheOne = PatchBytes.basalRecord(
        sequence: 122, patchId: 251, type: .ABSOLUTE_TEMP, start: c1.addingTimeInterval(1), end: c2, rate: 1, delivered: 0.1
    )
    static func secondOfSchedule(_ sequence: Int, at start: Date) -> [String] {
        PatchBytes.basalRecord(sequence: sequence, patchId: 251, type: .STANDARD, start: start, end: start.addingTimeInterval(1), rate: 0.7, delivered: 0)
    }

    /// The 1 U/h one replaced by 2 U/h back to back - its cancel names 122 - the read after the command timing out
    private func replaceTheOneByTwo() {
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: Self.c2
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 2, sequence: 123, patchId: 251, start: Self.c2.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(2, duration: 30 * Self.minute))
        settle()
    }

    /// The cancel ahead of the 1 U/h one names the zero one's record: read in that command, before the set - the zero one
    /// final ahead of the 1 U/h one's first report, counted. The 1 U/h one, cancelled later, goes final from its own.
    func testUnansweredTempBasalsRecordReadBeforeTheNextSetGoesFinalBeforeIt() throws {
        setAfterTheUnansweredTempBasal(inCommand: .fragments(Self.recordOfTheZero), advancingClock: 302)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: Self.c2
        ))
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.unitsPerHour), [1, 0.7])
        XCTAssertEqual(batch.map(\.isMutable), [false, false])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 120 }?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
        assertCountedAheadOfTheOne()
    }

    /// The zero one final from its record, read in the command before the 1 U/h one was set, in a batch ahead of that
    /// one's first report: counted - nothing warned of, Loop's view (the checker, on) has nothing behind its watermark
    private func assertCountedAheadOfTheOne(byRecord: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            Array(link.writtenCommands.prefix(6).suffix(3)),
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL],
            "read between the cancel and the set",
            file: file,
            line: line
        )
        let zeroFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 0 && $0.dose?.isMutable == false } }
        let oneFirst = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 1 } }
        XCTAssertNotNil(zeroFinal, file: file, line: line)
        XCTAssertLessThan(zeroFinal ?? .max, oneFirst ?? -1, "final before the 1 U/h one's first report", file: file, line: line)
        XCTAssertEqual(uncertainDeliveryErrors, 0, "nothing warned of", file: file, line: line)
        XCTAssertFalse(uncertain.contains { $0.phase == .settled(.notCounted) }, file: file, line: line)
        if byRecord {
            XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.byRecord) }, file: file, line: line)
        }
    }

    /// The same with a third, 2 U/h, after the 1 U/h one back to back: the zero one final before either, counted; the
    /// two final from their own records as the 2 U/h one is cancelled
    func testUnansweredTempBasalsRecordReadBeforeTheNextSetGoesFinalBeforeTwoLaterOnes() throws {
        setAfterTheUnansweredTempBasal(inCommand: .fragments(Self.recordOfTheZero), advancingClock: 302)
        advanceClock(by: 300)
        replaceTheOneByTwo()

        advanceClock(by: 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 124, patchId: 251, start: Self.c3
        ))
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(123, at: Self.c2))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 124, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.c2.addingTimeInterval(1), end: Self.c3, rate: 2, delivered: 0.15
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.unitsPerHour), [1, 2, 0.7])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false])
        assertCountedAheadOfTheOne()
    }

    /// The cancel after the unanswered set names its record: read in that command, between the cancel and the set - the
    /// 1 U/h one reported after it, running
    func testUnansweredTempBasalsRecordTheCancelAfterItNamesIsReadBeforeTheSet() throws {
        setAfterTheUnansweredTempBasal(inCommand: .fragments(Self.recordOfTheZero), advancingClock: 302)

        XCTAssertEqual(link.writtenCommands.suffix(3), [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 })
        XCTAssertEqual(zero.isMutable, false)
        XCTAssertTrue(reports(of: .tempBasal).filter { $0.unitsPerHour == 1 }.allSatisfy(\.isMutable), "nothing after it final before it")
        assertCountedAheadOfTheOne()
    }

    /// A status shows the schedule from a segment begun after the unanswered set - it ran 120 s, if at all - and the next
    /// set goes out with no cancel before it: the patch's newest record, 120, is read in that command first, the zero
    /// one final from it ahead of the new one's first report
    func testUnansweredTempBasalsRecordIsReadBeforeASetWithNoCancel() throws {
        startUnansweredTempBasal()
        let ended = Self.patchTime(399_933_337 + 120)
        advanceClock(by: 121)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 120, patchId: 251, start: ended, rate: 0.7))
        settle()
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 180)
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: ended, rate: 0, delivered: 0
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL], "no cancel")
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        assertZeroFinalAhead(of: { $0.unitsPerHour == 1 })
    }

    /// Killed during the read in the command - the host has the cancel's outcome, the zero one kept, no set pending: the
    /// next set after the restart, no cancel before it, reads the zero one's record first
    func testRestartDuringTheReadLeavesItToTheNextSet() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1
        ))
        let duringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .timeout) { [unowned self] in
            duringRead.value = delegate.savedState
        }
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        try restart(from: duringRead.value)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertEqual(pumpManager.state.basalState, .active)

        advanceClock(by: 60)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 2, sequence: 121, patchId: 251, start: Self.c1.addingTimeInterval(61)
        ))
        XCTAssertNil(commandTempBasal(2, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL], "no cancel")
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        assertZeroFinalAhead(of: { $0.unitsPerHour == 2 })
    }

    /// A suspend while the unanswered one is kept, the patch's status of it - naming 120 the newest record - in before the
    /// command's answer: the suspend is held back, 120 read in the command, the zero one final from it before the suspend
    /// is reported - counted
    func testSuspendWhileAnUnansweredTempBasalIsKeptReportsItsFinalFirst() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"])) { [unowned self] in
            notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        }
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        assertZeroFinalAhead(of: { $0.type == .suspend })
    }

    /// The same, the record unreadable in the command: the suspend goes out all the same - the zero one's record read
    /// later is behind Loop's watermark, warned of (the (d) path)
    func testSuspendWhileAnUnansweredTempBasalIsKeptGoesOutWithItsRecordUnread() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"])) { [unowned self] in
            notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        }
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(reports(of: .suspend).contains { _ in true }, "reported all the same")

        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
    }

    /// The patch halts on its own while the unanswered one is kept: the suspend is held back until 120, the newest record
    /// the status names, is read off the queue statuses arrive on - the zero one final from it first, counted
    func testHaltWhileAnUnansweredTempBasalIsKeptReportsItsFinalFirst() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        settle()

        XCTAssertEqual(link.writtenCommands.last, CommandType.GET_RECORD)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        assertZeroFinalAhead(of: { $0.type == .suspend })
    }

    /// The patch halts at the end of the zero one's record, 300 s after the cancel's segment: the suspend is dated from the
    /// anchor the zero one is dated by - not through the skew, a second off here - and the zero one ends where it starts,
    /// all of its 300 s, nothing warned of
    func testHaltWhileAnUnansweredTempBasalIsKeptIsDatedFromItsAnchor() throws {
        try assertHaltWhileAnUnansweredTempBasalIsKept(haltedAfter: 300, recordLasting: 300)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        XCTAssertEqual(zero.endDate.timeIntervalSince(zero.startDate), 300, accuracy: 0.5, "all of it")
    }

    /// The suspend 2 s before the zero one's record ends, as the two clocks tell them: fitted before it, silently - a
    /// shortfall no larger than the clocks tell apart
    func testUnansweredTempBasalsRecordEndingSecondsPastTheSuspendIsFittedSilently() throws {
        try assertHaltWhileAnUnansweredTempBasalIsKept(haltedAfter: 298, recordLasting: 300)
    }

    /// The suspend 10 s before the zero one's record ends: fitted before it, compressed - warned of
    func testUnansweredTempBasalsRecordEndingWellPastTheSuspendIsWarnedOf() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.GET_RECORD, Self.zeroFromTheCancel(lasting: 300))
        notifyOnTheManagersClock(Self.halted(at: Self.patchTime(399_933_336 + 290), newestRecord: 120))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
    }

    /// The patch halts `haltedAfter` s after the cancel's segment, the zero one's record `recordLasting` s from it: the
    /// zero one final from it, ending where the suspend starts, before it, nothing warned of
    private func assertHaltWhileAnUnansweredTempBasalIsKept(
        haltedAfter: TimeInterval,
        recordLasting: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.GET_RECORD, Self.zeroFromTheCancel(lasting: recordLasting))
        notifyOnTheManagersClock(Self.halted(at: Self.patchTime(399_933_336).addingTimeInterval(haltedAfter), newestRecord: 120))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, file: file, line: line)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable }, file: file, line: line)
        let suspend = try XCTUnwrap(reports(of: .suspend).first, file: file, line: line)
        XCTAssertEqual(zero.endDate.timeIntervalSince1970, suspend.startDate.timeIntervalSince1970, accuracy: 0.01, file: file, line: line)
        assertZeroFinalAhead(of: { $0.type == .suspend }, file: file, line: line)
    }

    /// The patch halts while the unanswered one is kept, as a resume goes out: the suspend, held back for 120, goes out
    /// ahead of the resume - 120 read in the resume first: the schedule's, not the zero one's - and of the set after it.
    /// Loop stores the suspension.
    func testSuspendHeldForAnUnansweredTempBasalGoesOutBeforeAResumeAndASet() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.RESUME_PUMP, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))) { [unowned self] in
            notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        }
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(120, at: Self.c1))
        XCTAssertNil(commandResume())
        settle()
        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.RESUME_PUMP, CommandType.GET_RECORD])

        advanceClock(by: 60)
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(61)
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        let suspendAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .suspend } }
        let resumeAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .resume } }
        let setAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 1 } }
        XCTAssertNotNil(suspendAt)
        XCTAssertLessThan(suspendAt ?? .max, resumeAt ?? -1, "the suspend ahead of the resume")
        XCTAssertLessThan(resumeAt ?? .max, setAt ?? -1)
    }

    /// The same, 120 the zero one's record: read in the resume before the suspend held back for it goes out - the zero
    /// one final from it first, counted, then the suspend, then the resume. The patch's status of its schedule in during
    /// that read, as on a device a second after the resume's answer: the resume it shows is held with the suspend, not
    /// reported ahead of it.
    func testResumeCommandReadsTheUnansweredOnesRecordBeforeTheHeldSuspend() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.RESUME_PUMP, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))) { [unowned self] in
            notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        }
        link.script(CommandType.GET_RECORD, .fragments(Self.recordOfTheZeroUpToTheSuspend)) { [unowned self] in
            notifyOnTheManagersClock(PatchBytes.basalNotification(
                type: .STANDARD, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1), rate: 0.7
            ))
        }
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.RESUME_PUMP, CommandType.GET_RECORD])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        assertZeroFinalAhead(of: { $0.type == .suspend })
        assertSuspendThenResume()
    }

    /// The patch halts while the unanswered one is kept, the read off the queue statuses arrive on yet to run, and the
    /// user resumes: 120 is read in the resume before it is written - the patch still suspended - and the suspend held
    /// back goes out then. The status of the schedule after the resume's answer reports the resume after it.
    func testResumeCommandReadsTheUnansweredOnesRecordBeforeItIsWritten() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let gate = DispatchSemaphore(value: 0)
        pumpManager.tempBasalEndQueue.async { gate.wait() }
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        advanceClock(by: 2)
        link.script(CommandType.RESUME_PUMP, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2)
        ))) { [unowned self] in
            notifyOnTheManagersClock(PatchBytes.basalNotification(
                type: .STANDARD, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2), rate: 0.7
            ))
        }
        XCTAssertNil(commandResume())
        gate.signal()
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.GET_RECORD, CommandType.RESUME_PUMP])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        assertZeroFinalAhead(of: { $0.type == .suspend })
        assertSuspendThenResume()
    }

    /// The patch halts while the unanswered one is kept, then shows its schedule - resumed - before 120 is read off the
    /// queue statuses arrive on, the link held meanwhile: the resume is held with the suspend - ahead of it, iAPS would
    /// zero the basal before it - and both go out once 120 is read, after the zero one's final, counted
    func testResumeShownBeforeTheUnansweredOnesRecordIsReadIsHeldWithTheSuspend() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let release = DispatchSemaphore(value: 0)
        link.holdWriter(until: release)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        advanceClock(by: 2)
        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .STANDARD, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2), rate: 0.7
        ))
        // Not `settle`: the read waits on the link
        delegate.queue.sync {}
        XCTAssertTrue(reports(of: .resume).isEmpty, "the resume held back with the suspend")
        XCTAssertTrue(reports(of: .suspend).isEmpty, "the suspend still held back")
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)

        release.signal()
        settle()

        XCTAssertEqual(link.writtenCommands.last, CommandType.GET_RECORD)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        assertZeroFinalAhead(of: { $0.type == .suspend })
        assertSuspendThenResume()
    }

    /// The same, the zero one's record ending 2 s past the suspend as the two clocks tell them, the resume shown 4 s after
    /// the suspend - held with it: the zero one is fitted before the held suspend, not before the resume. Ending past the
    /// suspend, out ahead of it, it would have Loop's watermark past the suspend: never stored.
    func testUnansweredTempBasalsRecordEndingPastAHeldSuspendIsFittedBeforeItNotBeforeTheResume() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let release = DispatchSemaphore(value: 0)
        link.holdWriter(until: release)
        let haltedAt = Self.patchTime(399_933_336 + 298)
        link.script(CommandType.GET_RECORD, Self.zeroFromTheCancel(lasting: 300))
        notifyOnTheManagersClock(Self.halted(at: haltedAt, newestRecord: 120))
        advanceClock(by: 4)
        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .STANDARD, sequence: 120, patchId: 251, start: haltedAt.addingTimeInterval(4), rate: 0.7
        ))
        // Not `settle`: the read waits on the link
        delegate.queue.sync {}
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume, "the resume held with the suspend")

        release.signal()
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        let suspend = try XCTUnwrap(reports(of: .suspend).first)
        XCTAssertEqual(zero.endDate.timeIntervalSince1970, suspend.startDate.timeIntervalSince1970, accuracy: 0.01, "up to the suspend")
        assertZeroFinalAhead(of: { $0.type == .suspend })
        assertSuspendThenResume()
    }

    /// The patch halts while the unanswered one is kept, 120 - the zero one's record - not yet written: nothing to read,
    /// the suspend reported, not held back. A status then names 120 the newest: the resume command reads it before the
    /// resume is written, the zero one final from it ahead of the resume - not left to a sync after it. Behind Loop's
    /// watermark all the same, the suspend reported before it having moved it there: warned of, the (d) path.
    func testResumeCommandReadsTheUnansweredOnesRecordWithTheSuspendReported() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        advanceClock(by: 302)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 119))
        settle()
        XCTAssertEqual(reports(of: .suspend).count, 1, "nothing to read: reported")
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 120)

        advanceClock(by: 2)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        link.script(CommandType.RESUME_PUMP, PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2)
        ))
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.GET_RECORD, CommandType.RESUME_PUMP], "read before the resume")
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        let zeroFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 0 && $0.dose?.type == .tempBasal && $0.dose?.isMutable == false } }
        let resumeAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .resume } }
        XCTAssertNotNil(zeroFinal)
        XCTAssertLessThan(zeroFinal ?? .max, resumeAt ?? -1, "final ahead of the resume")
        XCTAssertEqual(uncertainDeliveryErrors, 1, "behind the reported suspend")
    }

    /// The patch halts while the unanswered one is kept, nothing to read - the suspend reported - then a status shows the
    /// zero one's segment: late - a halted patch runs no temp basal, the halt ended it. Kept, its record to settle it, the
    /// suspend left running: nothing reported. Taken to run over the suspend, it would be dated over the suspension, and
    /// the host's suspend left open - no resume - or closed by one where the patch never resumed. Its record, 120, then
    /// settles it: final from it, at or before the suspend - behind Loop's watermark, which the suspend moved there:
    /// warned of, the (d) path - and nothing reported again. The resume command after reports the resume, in a later
    /// second than the suspend.
    func testUnansweredTempBasalShownAfterAReportedSuspendIsLateAndLeavesItSuspended() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        advanceClock(by: 302)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 119))
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).first, "nothing to read: reported")
        let batches = delegate.batches.count

        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: Self.patchTime(399_933_337), rate: 0
        ))
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "kept, its record to settle it")
        XCTAssertEqual(delegate.batches.count, batches, "nothing reported")

        advanceClock(by: 1)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let zeros = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        XCTAssertEqual(zeros.map(\.isMutable), [false], "reported once, final")
        XCTAssertLessThanOrEqual(try XCTUnwrap(zeros.first?.endDate), suspend.startDate, "at or before the suspend")
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
        XCTAssertEqual(reports(of: .suspend).count, 1, "nothing reported again")

        advanceClock(by: 2)
        link.script(CommandType.RESUME_PUMP, PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 119, patchId: 251, start: Self.c1.addingTimeInterval(2)
        ))
        XCTAssertNil(commandResume())
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        let resume = try XCTUnwrap(reports(of: .resume).first)
        XCTAssertEqual(reports(of: .resume).count, 1)
        assertResumeInALaterSecond(resume, than: suspend.startDate)
    }

    /// The patch halts while the unanswered one is kept, shows its schedule, and halts again - all before 120 is read off
    /// the queue statuses arrive on, the link held meanwhile: the resume and the second suspend are held behind the first,
    /// and the three go out in order once 120 is read, after the zero one's final
    func testSuspendResumeAndSuspendShownBeforeTheUnansweredOnesRecordIsReadGoOutInOrder() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let release = DispatchSemaphore(value: 0)
        link.holdWriter(until: release)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        let reads = link.requestedCommands.filter { $0 == CommandType.GET_RECORD }.count
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        // The read under way - its budget counted from the clock as it is now - and held up on the link: the clock moved
        // on 62 s before, it would find that budget gone
        XCTAssertTrue(giveTime(timeout: 5) { self.link.requestedCommands.filter { $0 == CommandType.GET_RECORD }.count > reads })
        advanceClock(by: 2)
        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .STANDARD, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2), rate: 0.7
        ))
        advanceClock(by: 60)
        notifyOnTheManagersClock(Self.halted(at: Self.c1.addingTimeInterval(62), newestRecord: 120))
        // Not `settle`: the read waits on the link
        delegate.queue.sync {}
        XCTAssertTrue(reports(of: .suspend).isEmpty, "both suspends held back")
        XCTAssertTrue(reports(of: .resume).isEmpty, "the resume held back with them")
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)

        release.signal()
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        assertZeroFinalAhead(of: { $0.type == .suspend })
        let released = try XCTUnwrap(delegate.batches.first { $0.events.contains { $0.dose?.type == .suspend } })
        let doses = released.events.compactMap(\.dose).filter { $0.type == .suspend || $0.type == .resume }
        XCTAssertEqual(doses.map(\.type), [.suspend, .resume, .suspend], "in one batch, in order")
        XCTAssertEqual(doses.map(\.startDate), doses.map(\.startDate).sorted())
    }

    /// A status shows the zero one over, the next set goes out with no cancel - the zero one's record unread in it - and
    /// then a suspend over that set: the record the patch has newest, 120, is read as the suspend ends the set, no cancel
    /// having named it - the zero one final from it ahead of the set's final in that batch. Loop's watermark passed it
    /// already, as the set was reported running: still warned of, the (d) path.
    func testSuspendOverASetWithNoCancelReadsTheUnansweredOnesRecord() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        let ended = Self.patchTime(399_933_337 + 120)
        advanceClock(by: 121)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 120, patchId: 251, start: ended, rate: 0.7))
        settle()
        advanceClock(by: 180)
        link.script(CommandType.GET_RECORD, .timeout)
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal?.snapshot.endRecord, "no cancel named its record")

        advanceClock(by: 60)
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"]))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: ended, rate: 0, delivered: 0
        ))
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        let zero = batch.firstIndex { $0.unitsPerHour == 0 && $0.type == .tempBasal && !$0.isMutable }
        let set = batch.firstIndex { $0.unitsPerHour == 1 && !$0.isMutable }
        XCTAssertNotNil(zero)
        XCTAssertLessThan(zero ?? .max, set ?? -1, "final ahead of the set's, in start order")
    }

    /// The notification `hex`, received now on the manager's clock - which the scenario moved - not on ours
    func notifyOnTheManagersClock(_ hex: String) {
        let packet = NotificationPacket()
        packet.totalData = FakeMedtrumLink.bytes(hex)
        var response = packet.parseResponse()
        response.receivedAt = pumpManager.now()
        response.receivedUptime = pumpManager.uptime()
        link.onQueue { self.pumpManager.handleStatus(response, duringReconnect: false, fullSync: false) }
    }

    /// Record 120: the zero one, run from the cancel's segment for 300 s, up to the second before the suspend at `c1`
    private static let recordOfTheZeroUpToTheSuspend = zeroFromTheCancel(lasting: 300)

    /// Record 120: the zero one, run from the cancel's segment for `duration`
    private static func zeroFromTheCancel(lasting duration: TimeInterval) -> [String] {
        PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: patchTime(399_933_336),
            end: patchTime(399_933_336).addingTimeInterval(duration), rate: 0, delivered: 0
        )
    }

    /// A notification of the patch suspended at `at`, naming `newestRecord` its newest record
    static func halted(at: Date, newestRecord: Int) -> String {
        (Data([PatchState.suspended.rawValue, 0x01, 0x01]) + at.toMedtrumSeconds() + UInt64(newestRecord).toData(length: 2) +
            UInt64(251).toData(length: 2)).hexEncodedString()
    }

    /// The suspend reported, and the resume after it: in a later batch, or after it in the same one - never ahead of it
    private func assertSuspendThenResume(file: StaticString = #filePath, line: UInt = #line) {
        let suspendAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .suspend } }
        let resumeAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .resume } }
        XCTAssertNotNil(suspendAt, file: file, line: line)
        XCTAssertNotNil(resumeAt, file: file, line: line)
        XCTAssertLessThanOrEqual(suspendAt ?? .max, resumeAt ?? -1, "the suspend ahead of the resume", file: file, line: line)
        if let suspendAt, suspendAt == resumeAt {
            let types = delegate.batches[suspendAt].events.compactMap(\.dose?.type)
            XCTAssertLessThan(
                types.firstIndex(of: .suspend) ?? .max, types.firstIndex(of: .resume) ?? -1, "first in the batch", file: file, line: line
            )
        }
    }

    /// The zero one final from its record in a batch no later than the first carrying a dose `later` picks: counted -
    /// nothing warned of, Loop's view (the checker, on) has nothing behind its watermark
    private func assertZeroFinalAhead(of later: (DoseEntry) -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let zeroFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 0 && $0.dose?.type == .tempBasal && $0.dose?.isMutable == false } }
        let laterFirst = delegate.batches.firstIndex { $0.events.contains { $0.dose.map(later) == true } }
        XCTAssertNotNil(zeroFinal, file: file, line: line)
        XCTAssertNotNil(laterFirst, file: file, line: line)
        XCTAssertLessThanOrEqual(zeroFinal ?? .max, laterFirst ?? -1, file: file, line: line)
        if let zeroFinal, let laterFirst, zeroFinal == laterFirst, let batch = delegate.batches[zeroFinal].events.compactMap(\.dose) as [DoseEntry]? {
            let z = batch.firstIndex { $0.unitsPerHour == 0 && $0.type == .tempBasal } ?? .max
            let l = batch.firstIndex(where: later) ?? -1
            XCTAssertLessThan(z, l, "the final first in the batch", file: file, line: line)
        }
        XCTAssertEqual(uncertainDeliveryErrors, 0, "nothing warned of", file: file, line: line)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.byRecord) }, file: file, line: line)
    }

    /// The cancel ahead of the 1 U/h one names 121: a bolus's record, 120, comes first - read in order and reconciled, its
    /// bolus final from it, not skipped - then the zero one's, before the set
    func testBolusRecordBeforeTheUnansweredTempBasalsIsReadInOrderBeforeTheSet() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let bolus = UnfinalizedDose(
            units: 1,
            duration: 40,
            activationType: .manualNoRecommendation,
            insulinType: nil,
            startDate: pumpManager.now().addingTimeInterval(-200)
        )
        bolus.noteAnswer(recordSequence: 120, pumpStartTime: Self.patchTime(399_933_437))
        bolus.finish(.cancelled, deliveredUnits: 0.1, endedAt: pumpManager.now().addingTimeInterval(-150))
        pumpManager.state.mutateAwaitingRecord { $0.append(bolus) }

        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 121, patchId: 251, start: Self.c1
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 120, patchId: 251, start: Self.patchTime(399_933_437), amount: 1, delivered: 0.15
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 121, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: Self.c1, rate: 0, delivered: 0
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 122, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(
            link.writtenCommands.suffix(4),
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL]
        )
        XCTAssertEqual(link.writes.filter { $0.commandType == CommandType.GET_RECORD }.count, 3, "119, then 120 and 121 in order")
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 121)
        let bolusFinal = try XCTUnwrap(reports(of: .bolus).last { $0.startDate == bolus.startDate && !$0.isMutable })
        XCTAssertEqual(bolusFinal.deliveredUnits ?? 0, 0.15, accuracy: 0.001, "from its record")
        XCTAssertNotEqual(pumpManager.recordStore.records.first { $0.id == 120 }?.outcome, "unmatched")
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 121 }?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
    }

    /// Killed after the read in the command, before the set's write-ahead: the run after has the zero one final from its
    /// record, the cancel's schedule running, no set pending - and reports nothing new of it
    func testRestartBetweenTheReadAndTheSetComesBackWithTheUnansweredOneFinal() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1
        ))
        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        let beforeSet = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_TEMP_BASAL, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))) { [unowned self] in
            // The last state the host had before the set's write-ahead
            beforeSet.value = delegate.savedStates.last { $0["pendingTempBasal"] == nil }
        }
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        let saved = try XCTUnwrap(beforeSet.value)
        XCTAssertNil(saved["unconfirmedTempBasal"], "final from its record in that state")
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        try restart(from: saved)
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        // Saved with the final, before the cursor moved past its record: read again, it changes nothing
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 119)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 120)
        // At most its final again, until the host confirms it: never running, never another identity
        XCTAssertTrue(
            reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }.allSatisfy { !$0.isMutable && $0.syncIdentifier == zero.syncIdentifier }
        )
    }

    /// The zero one's record unread in the command (the (d) path): the 1 U/h one ended back to back, its records unread past its maximum wait: it does not go final from our estimate
    /// while the zero one before it is unsettled - once its record is read, both go final, in order
    /// The 1 U/h one was reported running before the zero one's record was read: in Loop, the zero one is behind the
    /// watermark all the same - see `assertBehindLoopsWatermark`.
    func testTempBasalAfterAnUnansweredOneWaitsForItBeforeGoingFinalFromOurEstimate() throws {
        checksLoopOrdering = false
        setAfterTheUnansweredTempBasal(inCommand: .timeout, afterCommand: .timeout)
        replaceTheOneByTwo()

        advanceClock(by: MedtrumPumpManager.openTempBasalEndMaximumWait + Self.minute)
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds, "waits for the zero one")
        XCTAssertTrue(reports(of: .tempBasal).filter { $0.unitsPerHour == 1 }.allSatisfy(\.isMutable))

        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(123, at: Self.c2))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        let zeroFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 0 && $0.dose?.isMutable == false } }
        let oneFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 1 && $0.dose?.isMutable == false } }
        XCTAssertLessThanOrEqual(zeroFinal ?? .max, oneFinal ?? -1)
        // V went out mutable before: Loop's fill up to its start passed the zero one, which it may not store - what can't
        // be helped yet (scenario 2): warned of, not counted in the settings; iAPS counts it, final before the others
        assertBehindLoopsWatermark()
    }

    /// The zero one final from its record read in the command: the 1 U/h one, ended back to back, its records unread past
    /// its maximum wait, has nothing before it to wait for - final from our estimate, after the zero one
    func testTempBasalAfterAnUnansweredOneReadInTheCommandGoesFinalFromOurEstimate() throws {
        setAfterTheUnansweredTempBasal(inCommand: .fragments(Self.recordOfTheZero), advancingClock: 302)
        advanceClock(by: 300)
        replaceTheOneByTwo()

        advanceClock(by: MedtrumPumpManager.openTempBasalEndMaximumWait + Self.minute)
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()

        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds, "nothing before it to wait for")
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour == 1 && !$0.isMutable })
        assertCountedAheadOfTheOne()
    }

    /// What can't be helped: the zero one's record unreadable as the 1 U/h one is cancelled - that one goes final, from
    /// our estimate, with the schedule. The zero one's record read later still makes its final, which Loop may not count,
    /// behind those: the host is warned of uncertain delivery, the settings show it not counted.
    func testUnansweredTempBasalsRecordReadAfterALaterOnesFinalIsWarnedOf() throws {
        checksLoopOrdering = false
        setAfterTheUnansweredTempBasal(inCommand: .timeout, afterCommand: .timeout)

        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: Self.c2
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        let errors = uncertainDeliveryErrors

        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && !$0.isMutable }, "reported all the same")
        XCTAssertEqual(uncertainDeliveryErrors, errors + 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
        // Loop's view: behind its watermark
        XCTAssertTrue(LoopOrderingChecker.violations(in: delegate.hostBatches).contains { $0.rule == 6 })
    }

    /// The zero one went final after a later temp basal was reported - Loop's watermark passed it: the host was warned,
    /// once, the settings show it not counted, and Loop's view (`LoopOrderingChecker`) has it behind the watermark
    private func assertBehindLoopsWatermark(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && !$0.isMutable }, "reported all the same", file: file, line: line)
        XCTAssertEqual(uncertainDeliveryErrors, 1, file: file, line: line)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) }, file: file, line: line)
        XCTAssertTrue(LoopOrderingChecker.violations(in: delegate.hostBatches).contains { $0.rule == 6 }, file: file, line: line)
    }

    /// The batch with the 1 U/h one running the host could not store: Loop's watermark is where it was - the zero one's
    /// record read right after goes out with the 1 U/h one, in the next batch, ahead of the fill to its start: counted,
    /// nothing warned of
    func testUnansweredTempBasalsRecordAfterABatchTheHostCouldNotStoreIsNotWarnedOf() throws {
        startUnansweredTempBasal()
        // The 1 U/h one set as the patch says: 301 s after the cancel's segment before the zero one
        advanceClock(by: 302)
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, .fragments(Self.recordOfTheZero)) { [unowned self] in
            delegate.batchReply = .acknowledge
        }
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertFalse(uncertain.contains { $0.phase == .settled(.notCounted) })
    }

    /// State saved before Loop's watermark was kept, a suspend held back after a temp basal: it counts with its start
    func testLoopWatermarkOfStateSavedBeforeItWasKeptCountsAHeldSuspend() throws {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 118, reservoir: 150)
        let suspendedAt = Date.now.addingTimeInterval(-Self.minute)
        state.heldBasalDoses = [HeldBasalDose(dose: UnfinalizedDose(suspendStartTime: suspendedAt), heldAt: suspendedAt)]
        XCTAssertNil(state.loopWatermark)
        makeManager(state)
        XCTAssertEqual(pumpManager.state.loopWatermark, suspendedAt)
    }

    /// The state read back with no running basal saved - the schedule put in place then never reported: the temp basal
    /// whose command went unanswered after it is dated by its segment, not after that schedule
    func testUnansweredTempBasalIsNotDatedAfterAScheduleNeverReported() throws {
        var raw = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 118, reservoir: 150).rawValue
        raw["basalDose"] = nil
        let state = MedtrumPumpState(rawValue: raw)
        XCTAssertTrue(state.basalDoseIsPlaceholder)
        let patchNow = Self.patchTime(399_933_337)
        state.lastSegmentStart = patchNow.addingTimeInterval(-Self.hour)
        alignPatchClock(state, patchTime: patchNow)
        makeManager(state)

        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        let sentAt = Date.now
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0, duration: Self.hour)))
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal?.snapshot.basalBefore)

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 118, patchId: 251, start: patchNow.addingTimeInterval(-3), rate: 0))
        settle()

        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal)
        XCTAssertEqual(confirmed.startDate.timeIntervalSince(sentAt), -3, accuracy: 0.5)
    }

    /// The cancel's own segment shown late by a status, our reading of the patch clock an hour behind: it began before the
    /// unanswered set went out - told on each clock alone - so it bounds nothing; the zero one's record is still its own
    func testCancelsSegmentShownLateWithThePatchClockAnHourBehindLeavesTheUnansweredTempBasalsRecordItsOwn() throws {
        startUnansweredTempBasal(patchAhead: -3600)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 119, patchId: 251, start: Self.patchTime(399_933_336), rate: 0.7))
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal?.snapshot.laterSegmentStart)

        link.notify("200001" + "7800fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: Self.patchTime(399_933_456),
            rate: 0, delivered: 0
        ))
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && !$0.isMutable })
    }

    /// A segment begun 10 min after the set went out, our reading of the patch clock an hour ahead: it is after the
    /// command - told on each clock alone - and bounds the unanswered one there
    func testSegmentShownAfterTheCommandWithThePatchClockAnHourAheadBoundsTheUnansweredTempBasal() throws {
        startUnansweredTempBasal(patchAhead: 3600)
        let later = Self.patchTime(399_933_337 + 600)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 119, patchId: 251, start: later, rate: 0.7))
        settle()
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.snapshot.laterSegmentStart, later)
    }

    /// Killed as the set after an answered cancel awaited its answer, the cancel's answer not parsed - its segment not
    /// known: the next run tells the unanswered one's times through the skew, not from the segment before the cancel -
    /// its record, starting as the set went out, is its own
    func testTakenOverTempBasalWithNoCancelSegmentKnownIsMatchedThroughTheSkew() throws {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 119, reservoir: 150)
        let previous = runningTempBasal(rate: 0.2, startedAgo: 601, duration: 30 * Self.minute, pumpStartTime: Self.patchTime(399_932_735))
        state.basalDose = previous
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(399_933_337))
        state.pendingTempBasal = PendingTempBasal(
            unitsPerHour: 0,
            duration: Self.hour,
            automatic: true,
            sentAt: Date.now,
            sequenceAtSend: 119,
            priorSegmentStart: Self.patchTime(399_932_735),
            cancelledAt: Date.now.addingTimeInterval(-1)
        )
        makeManager(state)
        let pending = try XCTUnwrap(pumpManager.state.unconfirmedTempBasal)
        XCTAssertNil(pending.snapshot.basalBeforeOnPatch)

        link.notify("200001" + "7800fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_337), end: Self.patchTime(399_933_457),
            rate: 0, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 120 }?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
    }

    /// The zero one's record, 300 s long, read right after the 1 U/h one was set: dated from the cancel's segment it
    /// would run into that one, which the host has running - Loop would trim it and, its watermark past it, lose it. The
    /// zero one is fitted before it instead: no room for all of its 300 s since the cancel here, so into what there is,
    /// its amount kept - warned of. The 1 U/h one survives in Loop; the zero one, after it was reported, is behind
    /// Loop's watermark - the residual - and the only thing Loop's view finds.
    func testUnansweredTempBasalsRecordThatCannotFitBeforeALaterOneIsFittedBeforeIt() throws {
        checksLoopOrdering = false
        let late = PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_337), end: Self.c1, rate: 0, delivered: 0
        )
        // Unread in the command, read right after it: the 1 U/h one reported running by then
        setAfterTheUnansweredTempBasal(inCommand: .timeout, afterCommand: .fragments(late))

        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        let one = try XCTUnwrap(reports(of: .tempBasal).last { $0.unitsPerHour == 1 })
        XCTAssertEqual(zero.endDate, one.startDate, "up to the one the host has, not over it")
        XCTAssertLessThan(zero.startDate, one.startDate)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
        assertTheRunningOneSurvivesInLoop(zeroStart: zero.startDate)
    }

    /// The same, the 1 U/h one set 215 s after the zero one went out: the zero one's 200 s, dated from the cancel's
    /// segment, run 15 s into it - moved to end where it starts, all of it, nothing compressed. Behind Loop's watermark,
    /// reported after it (the residual).
    func testUnansweredTempBasalsRecordDatedIntoALaterOneIsMovedToEndBeforeIt() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        // The patch puts the cancel 230 s after the cancel's segment before the zero one, our clock 215 s: the 15 s the
        // patch's times run into it
        advanceClock(by: 215)
        let c1 = Self.patchTime(399_933_336 + 230)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: c1
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: c1.addingTimeInterval(1)
        ))
        // Unread in the command, read right after it: the 1 U/h one reported running by then
        link.script(CommandType.GET_RECORD, .timeout)
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_366), end: c1,
            rate: 0, delivered: 0
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        let one = try XCTUnwrap(reports(of: .tempBasal).last { $0.unitsPerHour == 1 })
        XCTAssertEqual(zero.endDate, one.startDate)
        XCTAssertEqual(zero.endDate.timeIntervalSince(zero.startDate), 200, accuracy: 0.001, "all of it")
        XCTAssertEqual(uncertainDeliveryErrors, 1, "behind the watermark only")
        assertTheRunningOneSurvivesInLoop(zeroStart: zero.startDate)
    }

    /// Loop's view of the batches: the running one is not lost - nothing but the zero one, behind the watermark
    private func assertTheRunningOneSurvivesInLoop(zeroStart: Date, file: StaticString = #filePath, line: UInt = #line) {
        let violations = LoopOrderingChecker.violations(in: delegate.hostBatches)
        XCTAssertFalse(violations.contains { $0.message.contains("lost") || $0.rule == 1 || $0.rule == 2 || $0.rule == 3 }, "\(violations)", file: file, line: line)
        XCTAssertTrue(violations.allSatisfy { $0.rule == 6 && $0.message.contains("\(zeroStart)") }, "\(violations)", file: file, line: line)
    }

    /// The zero one's record, starting in the cancel's second, our reading of the patch clock an hour off either way:
    /// matched and dated from the cancel's segment - on each clock alone - not through the skew
    func testUnansweredTempBasalsRecordIsMatchedWithThePatchClockAnHourAhead() throws {
        try assertUnansweredTempBasalsRecordIsMatched(patchAhead: 3600)
    }

    func testUnansweredTempBasalsRecordIsMatchedWithThePatchClockAnHourBehind() throws {
        try assertUnansweredTempBasalsRecordIsMatched(patchAhead: -3600)
    }

    private func assertUnansweredTempBasalsRecordIsMatched(patchAhead: TimeInterval, line: UInt = #line) throws {
        startUnansweredTempBasal(patchAhead: patchAhead)
        let previousEnd = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.2 }?.endDate, line: line)
        link.notify("200001" + "7800fb00")
        settle()

        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: Self.patchTime(399_933_456),
            rate: 0, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, line: line)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 }, line: line)
        XCTAssertEqual(zero.isMutable, false, line: line)
        XCTAssertEqual(zero.startDate.timeIntervalSince(previousEnd), 0, accuracy: 0.5, "from the cancel's segment", line: line)
        XCTAssertEqual(zero.endDate.timeIntervalSince(zero.startDate), 120, accuracy: 0.5, line: line)
    }

    /// The same shown by a status: confirmed as running from the cancel's segment, not taken for a restart of it
    func testUnansweredTempBasalShownWithThePatchClockAnHourAheadIsConfirmedFromItsStart() throws {
        try assertUnansweredTempBasalShownIsConfirmed(patchAhead: 3600)
    }

    func testUnansweredTempBasalShownWithThePatchClockAnHourBehindIsConfirmedFromItsStart() throws {
        try assertUnansweredTempBasalShownIsConfirmed(patchAhead: -3600)
    }

    private func assertUnansweredTempBasalShownIsConfirmed(patchAhead: TimeInterval, line: UInt = #line) throws {
        startUnansweredTempBasal(patchAhead: patchAhead)
        let previousEnd = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.2 }?.endDate, line: line)

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: Self.patchTime(399_933_336), rate: 0))
        settle()

        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal, line: line)
        XCTAssertFalse(confirmed.recordMatchDisabled, "not a restart of it", line: line)
        // From the cancel's segment, 0 s after it on the patch clock: just after the schedule it started
        XCTAssertEqual(confirmed.startDate.timeIntervalSince(previousEnd), 0.001, accuracy: 0.004, line: line)
    }

    /// The unanswered one confirmed by a status after patch-local midnight - its patch start the restart's, 10 min after
    /// it began - then replaced back to back 20 min on, both clocks moving together: how long the patch ran it is not
    /// told from that patch start - it ran its whole 30 min, our estimate up to the next one's start, not a stop
    /// 10 min before the cancel
    func testTempBasalConfirmedFromARestartIsNotTakenAsStoppedBeforeTheCancel() throws {
        let patchNow = Self.patchTime(399_933_337)
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 119, reservoir: 150)
        let sentAt = Date.now.addingTimeInterval(-30 * Self.minute)
        let pending = UnfinalizedDose(tempRate: 1.2, duration: Self.hour, insulinType: nil, automatic: true, confirmation: .uncertain, startDate: sentAt)
        pending.noteCommand(sentAt: sentAt, uptime: nil, sequence: 119, priorSegmentStart: patchNow.addingTimeInterval(-Self.hour))
        state.unconfirmedTempBasal = pending
        state.basalState = .tempBasal
        state.lastSegmentStart = patchNow.addingTimeInterval(-Self.hour)
        alignPatchClock(state, patchTime: patchNow)
        makeManager(state)

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: patchNow.addingTimeInterval(-20 * Self.minute), rate: 1.2
        ))
        settle()
        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.startDate, sentAt)
        XCTAssertEqual(confirmed.pumpStartTime, patchNow.addingTimeInterval(-20 * Self.minute))

        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: patchNow
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 0.5, sequence: 121, patchId: 251, start: patchNow.addingTimeInterval(1)
        ))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == sentAt }).first)
        XCTAssertEqual(final.endDate, pumpManager.state.basalDose.startDate, "back to back")
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.6, accuracy: 0.001, "1.2 U/h × 30 min, by our estimate")
    }

    /// The zero one's late record read after a restart, the 1 U/h one final before it in the run before: the host is
    /// warned all the same - what it has final is kept with the state
    func testUnansweredTempBasalsRecordReadLateAfterARestartIsWarnedOf() throws {
        checksLoopOrdering = false
        setAfterTheUnansweredTempBasal(inCommand: .timeout, afterCommand: .timeout)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: Self.c2
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0, "the host confirmed the finals")

        try restart(from: delegate.savedState)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
    }

    /// The state read back with no running basal saved - a placeholder schedule from the restart: the zero one's record,
    /// read then, is not cut short at that placeholder's start
    func testUnansweredTempBasalsRecordIsNotCutAtAPlaceholderSchedule() throws {
        startUnansweredTempBasal()
        var saved = try XCTUnwrap(delegate.savedState)
        saved["basalDose"] = nil
        try restart(from: saved)
        XCTAssertTrue(pumpManager.state.basalDoseIsPlaceholder)

        link.notify("200001" + "7800fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: Self.c1, rate: 0, delivered: 0
        ))
        syncRecords()

        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        XCTAssertEqual(zero.endDate.timeIntervalSince(zero.startDate), 301, accuracy: 0.5)
    }

    /// The zero one's record ends at patch-local midnight - a part of it - read in the command before the 1 U/h one is
    /// set: it ended by the cancel, final from our estimate - not put back as the running basal - ahead of the 1 U/h
    /// one's first report
    func testUnansweredTempBasalsSplitRecordReadBeforeTheNextSetIsNotPutBackAsRunning() throws {
        let midnight = Self.patchTime(399_933_337 + 100)
        setAfterTheUnansweredTempBasal(
            inCommand: .fragments(PatchBytes.basalRecord(
                sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_337), end: midnight, rate: 0, delivered: 0
            )),
            patchUTCOffset: 24 * Self.hour - midnight.timeIntervalSince1970.truncatingRemainder(dividingBy: 24 * Self.hour),
            advancingClock: 302
        )

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.value, 1, "the 1 U/h one runs")
        XCTAssertFalse(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && $0.isMutable }, "never reported running")
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && !$0.isMutable })
        assertCountedAheadOfTheOne(byRecord: false)
    }

    /// The unanswered set of `startUnansweredTempBasal`, kept, then two more set and answered - 1 U/h, then 2 U/h, the
    /// first one ended back to back and waiting on its record - and only then a status, late, showing the zero temp
    /// basal's segment: a later segment is known, the status is stale. The 2 U/h one runs on, nothing ended or reported
    /// before the ones the host has.
    func testStaleStatusOfAnUnansweredTempBasalAfterTwoMoreLeavesTheRunningOneRunning() {
        startUnansweredTempBasal()

        let c1 = Self.patchTime(399_933_337 + 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: c1
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: c1.addingTimeInterval(1)
        ))
        // The record the cancel names, had the unanswered one run, read in the command and after it: not yet written here
        link.script(CommandType.GET_RECORD, .timeout)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        let c2 = c1.addingTimeInterval(300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: c2
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 2, sequence: 123, patchId: 251, start: c2.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(2, duration: 30 * Self.minute))
        settle()
        let running = pumpManager.state.basalDose
        XCTAssertEqual(running.value, 2)
        let batches = delegate.batches.count

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 123, patchId: 251, start: Self.patchTime(399_933_338), rate: 0))
        settle()

        XCTAssertTrue(pumpManager.state.basalDose === running)
        XCTAssertFalse(running.isFinished)
        XCTAssertEqual(delegate.batches.count, batches)
        XCTAssertTrue(reports(of: .tempBasal).allSatisfy { $0.unitsPerHour > 0.1 }, "the zero temp basal is not reported running")
    }

    /// The same unanswered set, the patch running it from the very second the cancel's scheduled segment began (a 0 s
    /// STANDARD record, as record 88 in `records-aug.txt`): a status showing it confirms it all the same.
    func testUnansweredTempBasalStartingInTheCancelsSecondIsConfirmedByAStatus() {
        startUnansweredTempBasal()

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 119,
            patchId: 251,
            start: Self.patchTime(399_933_336),
            rate: 0
        ))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal)
        XCTAssertEqual(confirmed.value, 0)
        XCTAssertEqual(confirmed.pumpStartTime, Self.patchTime(399_933_336))
        XCTAssertEqual(delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }?.unitsPerHour, 0)
    }

    /// The same, with no status showing it: its record, starting in the cancel's second, finalizes it
    func testUnansweredTempBasalStartingInTheCancelsSecondIsFinalizedByItsRecord() {
        startUnansweredTempBasal()

        link.notify("200001" + "7800fb00")
        settle()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_336),
                end: Self.patchTime(399_933_456),
                rate: 0,
                delivered: 0
            )
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let zero = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        XCTAssertEqual(zero.count, 1)
        XCTAssertEqual(zero.first?.isMutable, false)
        XCTAssertEqual(zero.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
    }

    /// 2026-08-02 08:22:41 - 08:22:43 (`user.txt:28394-28402`), patch 237: a notification showing the cancel's
    /// scheduled basal, handled after the new temp basal is registered. It started before the new one did, on the patch
    /// clock: it says nothing of it.
    func testCancelsSegmentShownAfterTheNewTempBasalSaysNothingOfIt() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 118, reservoir: 175.3)
        state.basalDose = runningTempBasal(
            rate: 0.9,
            startedAgo: 5 * Self.minute,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_117_049)
        )
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_117_349))
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "12196a000000010c007700ed00a587ab177c00")
        link.script(CommandType.SET_TEMP_BASAL, fragments: "12186b000000061f007800ed00a687ab179200")
        link.script(CommandType.GET_RECORD, Self.recordOfThe0Point9TempBasal)
        XCTAssertNil(commandTempBasal(1.55, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(written(CommandType.SET_TEMP_BASAL)?.encoded(sequence: 0x6B), "0a186b00061f001e009900")
        let running = pumpManager.state.basalDose
        XCTAssertEqual(running.pumpStartTime, Self.patchTime(397_117_350))
        let batches = delegate.batches.count

        link.notify("202800017700ed00a587ab170c2000b10d")
        settle()

        XCTAssertTrue(pumpManager.state.basalDose === running)
        XCTAssertFalse(running.isFinished)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertEqual(delegate.batches.count, batches)
    }

    /// 2026-08-03 03:37:11 - 03:37:17 (`user2.txt` near 35886), patch 237: a manual suspend while 0.6 U/h runs. The
    /// notification right after the answer carries the patch's suspend time: the temp basal ends, and the suspend
    /// starts, there. The resume is dated from the start of the segment the ResumePump answer reports.
    func testManualSuspendIsDatedByThePatchAndTheResumeByItsAnswer() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        let tempBasal = runningTempBasal(
            rate: 0.6,
            startedAgo: 266,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_186_357)
        )
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)
        let skew = pumpManager.state.patchClockSkew

        link.script(
            CommandType.SUSPEND_PUMP,
            .fragments(["071c050000001800"]),
            thenNotify: ["4501133c96ac170302ed00100000000000000000"]
        )
        // The status names 515 the newest record: the temp basal's (514, `records-aug3.txt`) ending at the suspend,
        // then an ALARM. The first is read in the command, once it has its answer: it settles the temp basal, and the
        // ALARM is left to the sync.
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 514,
            patchId: 237,
            type: .ABSOLUTE_TEMP,
            start: Self.patchTime(397_186_357),
            end: Self.patchTime(397_186_620),
            rate: 0.6,
            delivered: 0.05
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 515, patchId: 237))
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x05), "071c0500031e6500")
        let suspendedAt = Self.patchTime(397_186_620).addingTimeInterval(-skew)

        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalDose.startDate.timeIntervalSince1970, suspendedAt.timeIntervalSince1970, accuracy: 0.001)

        XCTAssertEqual(delegate.batches.count, 1, "the status reported it; the command adds nothing")
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.tempBasal, .suspend])
        let ended = batch?.events.first?.dose
        XCTAssertEqual(ended?.startDate, tempBasal.startDate)
        XCTAssertEqual(ended?.isMutable, false, "a suspend ends it for good; its record says how much it delivered")
        XCTAssertEqual(ended?.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(ended?.endDate.timeIntervalSince1970 ?? 0, suspendedAt.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 514)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 515)
        XCTAssertEqual(delegate.batches.count, 1)

        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(written(CommandType.RESUME_PUMP)?.encoded(sequence: 0x06), "051d06003000")
        let resumedAt = Self.patchTime(397_186_625).addingTimeInterval(-skew)
        let resume = delegate.batches.last?.events.first { $0.dose?.type == .resume }?.dose
        XCTAssertEqual(resume?.startDate.timeIntervalSince1970 ?? 0, min(resumedAt, Date.now).timeIntervalSince1970, accuracy: 0.5)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 515)

        // The scheduled basal the patch then shows: the resume reported already
        let batches = delegate.batches.count
        link.notify("200801010302ed004196ac170c00000402ed00")
        settle()
        XCTAssertEqual(delegate.batches.count, batches)
        XCTAssertEqual(reports(of: .resume).count, 1)
    }

    /// A resume while the driver still takes a temp basal to run (the suspend went unrecorded): the temp basal stopped
    /// at the suspend for good, so it ends at the resume at the latest, final from its record - 514, written as the patch
    /// suspended, read in the command up to 515, the newest the answer names: it settles it. The schedule after it, not a
    /// resume: no suspend was reported before it.
    func testResumeEndsATempBasalStillTakenToRun() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        let tempBasal = runningTempBasal(
            rate: 0.6,
            startedAgo: 266,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_186_357)
        )
        state.basalDose = tempBasal
        state.basalState = .suspended
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)
        let skew = pumpManager.state.patchClockSkew

        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 514,
            patchId: 237,
            type: .ABSOLUTE_TEMP,
            start: Self.patchTime(397_186_357),
            end: Self.patchTime(397_186_500),
            rate: 0.6,
            delivered: 0,
            endReason: .SUSPEND_MANUAL
        ))
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        XCTAssertTrue(tempBasal.isFinalized)
        XCTAssertEqual(link.writtenCommands, [CommandType.RESUME_PUMP, CommandType.GET_RECORD])

        let resumedAt = min(Self.patchTime(397_186_625).addingTimeInterval(-skew), Date.now)
        XCTAssertEqual(delegate.batches.last?.events.map(\.dose?.type), [.tempBasal, .basal])
        let ended = delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }
        XCTAssertEqual(ended?.isMutable, false)
        XCTAssertEqual(ended?.startDate, tempBasal.startDate)
        XCTAssertEqual(ended?.endDate.timeIntervalSince1970 ?? 0, resumedAt.timeIntervalSince1970, accuracy: 0.5)
        // Not 0.05 U, 0.6 U/h for 266 s by rate × duration to the nearest 0.05 U: what its record says
        XCTAssertEqual(ended?.deliveredUnits ?? 1, 0, accuracy: 0.001)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// Suspended a minute ago, as the host was told: a status shows the schedule from 65 s ago as our clock has it - before
    /// the suspend, the clocks a few seconds apart. The resume is dated in a later second than the suspend, not at it:
    /// iAPS stores both to the second, and oref0 pairs a resume with a suspend only if it is later - in the same second,
    /// the suspend is left open, every temp basal after it zeroed (the checker's rules 7 and 8).
    func testResumeShownFromBeforeTheSuspendIsDatedInALaterSecond() throws {
        let suspend = startSuspendedAMinuteAgo()
        link.notify(PatchBytes.basalNotification(
            type: .STANDARD, sequence: 513, patchId: 237, start: Self.patchTime(397_186_623 - 65), rate: 0.6
        ))
        settle()

        let resume = try XCTUnwrap(reports(of: .resume).first)
        assertResumeInALaterSecond(resume, than: suspend.startDate)
    }

    /// The same, the resume command's answer showing the schedule from before the suspend
    func testResumeAnsweredFromBeforeTheSuspendIsDatedInALaterSecond() throws {
        let suspend = startSuspendedAMinuteAgo()
        link.script(CommandType.RESUME_PUMP, PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.6, sequence: 513, patchId: 237, start: Self.patchTime(397_186_623 - 65)
        ))
        XCTAssertNil(commandResume())
        settle()

        let resume = try XCTUnwrap(reports(of: .resume).first)
        assertResumeInALaterSecond(resume, than: suspend.startDate)
    }

    /// `resume` in a later second than the suspend of `suspendStart` - as iAPS stores them, to the second, floored: paired
    /// with it by oref0 - a second after it at most
    private func assertResumeInALaterSecond(_ resume: DoseEntry, than suspendStart: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(LoopOrderingChecker.stored(resume.startDate), LoopOrderingChecker.stored(suspendStart), "in a later second", file: file, line: line)
        XCTAssertLessThanOrEqual(resume.startDate.timeIntervalSince(suspendStart), 1, "a second after it at most", file: file, line: line)
    }

    /// Suspended since a minute ago - the host told so in a run before - the patch clock `397_186_623` now
    func startSuspendedAMinuteAgo() -> UnfinalizedDose {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        let suspend = UnfinalizedDose(suspendStartTime: Date.now.addingTimeInterval(-Self.minute))
        state.basalDose = suspend
        state.basalState = .suspended
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)
        hostSuspendedSince = suspend.startDate
        return suspend
    }

    /// A status showing a suspend, received before the running temp basal's command went out, says nothing of it: the
    /// temp basal runs on and the basal state stays as it was - not suspended, which would refuse dosing
    func testSuspendShownByAStatusFromBeforeTheTempBasalLeavesItRunning() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        // Its command went out after the status below is received
        var raw = runningTempBasal(rate: 0.6, startedAgo: 0, duration: 30 * Self.minute).rawValue
        raw["sentAt"] = Date.now.addingTimeInterval(Self.minute)
        let tempBasal = UnfinalizedDose(rawValue: raw)!
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)

        link.notify("4501133c96ac170302ed00100000000000000000")
        settle()

        XCTAssertTrue(pumpManager.state.basalDose === tempBasal)
        XCTAssertFalse(tempBasal.isFinished)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertEqual(delegate.batches.count, 0)
    }

    /// A cancel that gets no answer may or may not have stopped the temp basal: it runs on, counted, with delivery
    /// uncertain - until a status shows the scheduled basal since the cancel, which ends it there
    func testUnansweredCancelKeepsTheTempBasalUntilAStatusEndsIt() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 118, reservoir: 175.3)
        let tempBasal = runningTempBasal(
            rate: 0.9,
            startedAgo: 5 * Self.minute,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_117_049)
        )
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_117_349))
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(1.55, duration: 30 * Self.minute)))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL], "not set over what may still run")
        XCTAssertTrue(pumpManager.state.basalDose === tempBasal)
        XCTAssertFalse(tempBasal.isFinished)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(delegate.batches.count, 0)

        // The scheduled basal since the cancel reached the patch: the record it names (119) is read off the queue
        // notifications arrive on, and the temp basal goes out final with the scheduled basal
        link.script(CommandType.GET_RECORD, Self.recordOfThe0Point9TempBasal)
        link.notify("202800017700ed00a587ab170c2000b10d")
        settle()

        XCTAssertTrue(tempBasal.isFinalized)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.last?.events.map(\.dose?.type), [.tempBasal, .basal])
        let ended = delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }
        XCTAssertEqual(ended?.isMutable, false)
        XCTAssertEqual(ended?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(ended.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 119)
    }

    /// The record of the 0.9 U/h temp basal of `user.txt:28394` the cancel there ended: 5 min, built
    private static let recordOfThe0Point9TempBasal = PatchBytes.basalRecord(
        sequence: 119,
        patchId: 237,
        type: .ABSOLUTE_TEMP,
        start: patchTime(397_117_049),
        end: patchTime(397_117_349),
        rate: 0.9,
        delivered: 0.1
    )

    /// The same unanswered set, every record read - the cursor at the newest record the patch told of before the send -
    /// then the link lost: past its planned end and 15 min more, that is no word on its record, which it would have by
    /// then. Not dropped. Back in reach, the patch says it wrote record 120 - the temp basal's, which finalizes it.
    func testUnansweredTempBasalIsNotDroppedWhileTheLinkIsLostAndItsRecordFinalizesItOnReconnect() {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()

        // The loop's syncs fail: the doses waiting are settled without the link
        advanceClock(by: 76 * Self.minute)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "its record may be written and unread")
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)

        link.notify("200001" + "7800fb00")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_338),
                end: Self.patchTime(399_933_338 + 3600),
                rate: 0,
                delivered: 0
            )
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        let zero = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        XCTAssertEqual(zero.count, 1)
        XCTAssertEqual(zero.first?.isMutable, false)
        XCTAssertEqual(zero.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 3600, accuracy: 0.001)
    }

    /// The same unanswered set, the patch having written record 120 - which comes back unreadable twice, and is
    /// skipped. It could be the temp basal's record: with every other record read, 15 min past its planned end, it is
    /// not dropped - it stays, delivery uncertain, until the patch session ends.
    func testUnansweredTempBasalWhoseRecordMayBeTheOneSkippedIsNotDropped() {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()

        link.notify("200001" + "7800fb00")
        settle()
        let record = PatchBytes.basalRecord(
            sequence: 120,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: Self.patchTime(399_933_338),
            end: Self.patchTime(399_933_338 + 3600),
            rate: 0,
            delivered: 0
        )
        link.script(CommandType.GET_RECORD, .garbled(record))
        link.script(CommandType.GET_RECORD, .garbled(record))
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 120)
        XCTAssertEqual(pumpManager.state.skippedRecordSequences, [120])

        advanceClock(by: 76 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)

        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.skippedRecordSequences, [])
        XCTAssertTrue(reports(of: .tempBasal).allSatisfy { $0.unitsPerHour > 0.1 }, "the zero temp basal never reached the host")
    }

    /// The same unanswered set at 23:35:37 patch-local time (UTC+3), the link lost until a cancel at 00:05:37, answered.
    /// The patch split the temp basal at midnight: record 120 up to midnight, 121 after it. The first is proof it ran,
    /// but only a part: reported from its start on, ended where it ended at the latest - the cancel - and final at once
    /// from our estimate. The second finalizes nothing.
    func testUnansweredTempBasalWhoseRecordEndsAtPatchMidnightIsFinalizedFromOurEstimate() throws {
        try assertSplitRecordEndsUpToTheCancel(patchAhead: 0)
    }

    /// The same, our reading of the patch clock an hour off either way: its end, up to the cancel, told from the cancel's
    /// segment before it, on each clock alone
    func testUnansweredTempBasalWhoseRecordEndsAtPatchMidnightWithThePatchClockAnHourAhead() throws {
        try assertSplitRecordEndsUpToTheCancel(patchAhead: 3600)
    }

    func testUnansweredTempBasalWhoseRecordEndsAtPatchMidnightWithThePatchClockAnHourBehind() throws {
        try assertSplitRecordEndsUpToTheCancel(patchAhead: -3600)
    }

    private func assertSplitRecordEndsUpToTheCancel(patchAhead: TimeInterval) throws {
        let sentAt = startUnansweredTempBasal(patchUTCOffset: 3 * Self.hour, patchAhead: patchAhead)
        readTheCancelledTempBasalsRecord()
        let midnight = Self.patchTime(399_934_800)
        let cancelledAt = Self.patchTime(399_933_337 + 1800)

        // 1801 s after the cancel's segment before the unanswered set (336)
        advanceClock(by: 30 * Self.minute + 1)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 121,
            patchId: 251,
            start: cancelledAt
        ))
        // The record the cancel names, had the unanswered one run, read after the command: not yet written here
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let patchStart = Self.patchTime(399_933_338)
        let unconfirmed = try XCTUnwrap(pumpManager.state.unconfirmedTempBasal?.snapshot)
        let basalBefore = try XCTUnwrap(unconfirmed.basalBefore)
        let basalBeforeOnPatch = try XCTUnwrap(unconfirmed.basalBeforeOnPatch)
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: patchStart, end: midnight, rate: 0, delivered: 0)
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 121, patchId: 251, type: .ABSOLUTE_TEMP, start: midnight, end: cancelledAt, rate: 0, delivered: 0)
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let records = pumpManager.recordStore.records
        XCTAssertEqual(records.first { $0.id == 120 }?.outcome?.hasPrefix("part of split unconfirmed temp basal"), true)
        XCTAssertEqual(records.first { $0.id == 121 }?.outcome, "unmatched")

        // Told from the cancel's segment before the unanswered set, on each clock alone
        let onOurClock = { (patchTime: Date) in basalBefore.addingTimeInterval(patchTime.timeIntervalSince(basalBeforeOnPatch)) }
        let reported = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 })
        XCTAssertEqual(reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }.count, 1, "reported once, final")
        XCTAssertGreaterThanOrEqual(reported.startDate, sentAt.addingTimeInterval(-MedtrumPumpManager.unansweredStartSlack))
        XCTAssertEqual(reported.startDate.timeIntervalSince1970, onOurClock(patchStart).timeIntervalSince1970, accuracy: 0.001, "from the record's start")

        let final = finals(of: reported)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.startDate, reported.startDate)
        XCTAssertEqual(
            final.first?.endDate.timeIntervalSince1970 ?? 0,
            onOurClock(cancelledAt).timeIntervalSince1970,
            accuracy: 0.001,
            "up to the cancel - the part up to midnight ends 1462 s in"
        )
        XCTAssertFalse(uncertain.contains { $0.phase == .settled(.notCounted) })
    }

    /// The same unanswered set, a status then showing the scheduled basal the cancel before it started (from before
    /// the command): that says nothing of whether the patch runs the temp basal. The next temp basal cancels first.
    func testScheduledBasalFromBeforeTheCommandLeavesTheNextTempBasalToCancelFirst() {
        startUnansweredTempBasal()

        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 119, patchId: 251, start: Self.patchTime(399_933_336), rate: 0.7))
        settle()
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)

        let next = Self.patchTime(399_933_337 + 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 120,
            patchId: 251,
            start: next
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 0.5,
            sequence: 121,
            patchId: 251,
            start: next
        ))
        // The record the cancel names, had the unanswered one run, read in the command and again after it: not yet
        // written here
        link.script(CommandType.GET_RECORD, .timeout)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(
            link.writtenCommands.suffix(4),
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD]
        )
    }

    /// The same unanswered set, and a basal profile set 30 s later: had the patch run the temp basal, it split it there.
    /// Record 120, of the part before, is proof it ran - but only a part: reported from its start on, finalized from
    /// our estimate up to the cancel. Record 121, of the part after, finalizes nothing.
    func testProfileSetRightAfterAnUnansweredTempBasalLeavesItToOurEstimate() throws {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()
        let profileSetAt = Self.patchTime(399_933_337 + 30)

        XCTAssertNotNil(setBasalProfile(restartingAt: profileSetAt))
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.recordMatchDisabled, true)

        let cancelledAt = Self.patchTime(399_933_337 + 1200)
        // 1201 s after the cancel's segment before the unanswered set (336)
        advanceClock(by: 20 * Self.minute + 1)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 121,
            patchId: 251,
            start: cancelledAt
        ))
        // The record the cancel names, had the unanswered one run, read after the command: not yet written here
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_338),
                end: profileSetAt,
                rate: 0,
                delivered: 0
            )
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 121, patchId: 251, type: .ABSOLUTE_TEMP, start: profileSetAt, end: cancelledAt, rate: 0, delivered: 0)
        )
        syncRecords()

        let records = pumpManager.recordStore.records
        XCTAssertEqual(records.first { $0.id == 120 }?.outcome?.hasPrefix("part of split unconfirmed temp basal"), true)
        XCTAssertEqual(records.first { $0.id == 121 }?.outcome, "unmatched")
        let reported = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 })
        XCTAssertEqual(reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }.count, 1, "reported once, final")

        let final = finals(of: reported)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 1200, accuracy: 1.5, "not the 30 s part")
        XCTAssertFalse(uncertain.contains { $0.phase == .settled(.notCounted) })
    }

    /// The same, a status then showing the temp basal running since the profile was set: confirmed, it keeps record
    /// matching off - the records the cancel names finalize nothing, our estimate does, at once
    func testProfileSetRightAfterAnUnansweredTempBasalKeepsItsRecordsOffOnceAStatusShowsIt() throws {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()
        let profileSetAt = Self.patchTime(399_933_337 + 30)
        XCTAssertNotNil(setBasalProfile(restartingAt: profileSetAt))

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 120, patchId: 251, start: profileSetAt, rate: 0))
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(pumpManager.state.basalDose.recordMatchDisabled)
        let reported = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 })

        let cancelledAt = Self.patchTime(399_933_337 + 1200)
        advanceClock(by: 20 * Self.minute)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 121,
            patchId: 251,
            start: cancelledAt
        ))
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_338),
                end: profileSetAt,
                rate: 0,
                delivered: 0
            )
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 121, patchId: 251, type: .ABSOLUTE_TEMP, start: profileSetAt, end: cancelledAt, rate: 0, delivered: 0)
        )
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertNotEqual(pumpManager.recordStore.records.first { $0.id == 121 }?.outcome?.hasPrefix("finalized"), true)
        assertOneFinal(of: reported)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        assertOneFinal(of: reported)
    }
}

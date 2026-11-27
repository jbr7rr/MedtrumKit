import LoopKit
@testable import MedtrumKit
import XCTest

// MARK: - Suspends and resumes kept until the host stores them

extension ManagerTempBasalScenarioTests {
    /// A suspend command, the patch on its schedule: the host takes the state saved with the suspend's batch, and the app
    /// is killed before it stores the suspend - the host "fails" it. Kept with the state, the suspend goes out again with
    /// the next run's first batch, the resume command's, ahead of the resume: never a resume with no suspend before it.
    func testSuspendCommandTheHostDidNotStoreGoesOutAgainAfterARestart() throws {
        startOnTheSchedule()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        XCTAssertNil(commandSuspend())
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).first)
        XCTAssertEqual(pumpManager.state.heldBasalDoses.map(\.dose.type), [.suspend], "kept: the host did not store it")

        try restart(from: delegate.savedState)
        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()

        assertReportedAgain(suspend, aheadOf: .resume)
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty, "stored")
    }

    /// The same, the patch halting on its own: the halt's suspend goes out again ahead of the resume a status shows
    func testHaltTheHostDidNotStoreGoesOutAgainAfterARestart() throws {
        startOnTheSchedule()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.notify(PatchBytes.suspendNotification(suspendedAt: Self.patchTime(397_186_623)))
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).first)

        try restart(from: delegate.savedState)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 513, patchId: 237, start: Self.patchTime(397_186_683), rate: 0.6))
        settle()

        assertReportedAgain(suspend, aheadOf: .resume)
    }

    /// A resume command, the host failing its batch, the app killed: the resume goes out again with the next run's first
    /// batch, the temp basal's - ahead of it. Lost, the suspend before it would stay open at the host: every temp basal
    /// after it zeroed.
    func testResumeCommandTheHostDidNotStoreGoesOutAgainAfterARestart() throws {
        startSuspendedAMinuteAgo()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()
        let resume = try XCTUnwrap(reports(of: .resume).first)

        try restart(from: delegate.savedState)
        setTempBasalOnTheSchedule()

        assertReportedAgain(resume, aheadOf: .tempBasal)
    }

    /// The same for the resume a status shows
    func testResumeShownTheHostDidNotStoreGoesOutAgainAfterARestart() throws {
        startSuspendedAMinuteAgo()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 513, patchId: 237, start: Self.patchTime(397_186_620), rate: 0.6))
        settle()
        let resume = try XCTUnwrap(reports(of: .resume).first)

        try restart(from: delegate.savedState)
        setTempBasalOnTheSchedule()

        assertReportedAgain(resume, aheadOf: .tempBasal)
    }

    /// The host failing a batch, no restart: the suspend goes out with every batch until the host stores one - here the
    /// resume's, ahead of the resume - and is done with then
    func testSuspendTheHostDidNotStoreGoesOutWithTheNextBatch() throws {
        startOnTheSchedule()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        XCTAssertNil(commandSuspend())
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).first)
        XCTAssertEqual(delegate.batches.map(\.stored), [false])

        delegate.batchReply = .acknowledge
        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()

        let carried = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(carried.filter { $0.type == .suspend || $0.type == .resume }.map(\.type), [.suspend, .resume])
        XCTAssertEqual(carried.first { $0.type == .suspend }?.syncIdentifier, suspend.syncIdentifier)
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)
        XCTAssertNil(delegate.savedState?["heldBasalDoses"])
    }

    /// A suspend and a resume command, the host failing both batches, the app killed - the patch out of reach since: both
    /// go out again, in order, with the first resend of what the host has yet to confirm - the loop's
    /// `ensureCurrentPumpData` - which needs no link, not with the patch's first status
    func testSuspendAndResumeTheHostDidNotStoreGoOutAgainAfterARestartWithNoLink() throws {
        startOnTheSchedule()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        XCTAssertNil(commandSuspend())
        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()
        let kept = try [XCTUnwrap(reports(of: .suspend).first), XCTUnwrap(reports(of: .resume).first)]
        let written = link.writtenCommands.count

        try restart(from: delegate.savedState)
        pumpManager.resendUnacknowledgedFinalsIfDue()
        settle()

        XCTAssertEqual(link.writtenCommands.count, written, "no link")
        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.syncIdentifier), kept.map(\.syncIdentifier), "again, in order")
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty, "stored")

        pumpManager.resendUnacknowledgedFinalsIfDue()
        settle()
        XCTAssertEqual(delegate.batches.count, 1, "nothing left to send")
    }

    // MARK: The temp basal a suspend command ends

    /// A suspend while 1.2 U/h runs, the patch's status of it in a moment after the answer (device 2026-10-20 09:50:01-02,
    /// in the second of the answer - which the command raced, the temp basal finalized from our estimate): waited for, it
    /// ends the temp basal where the patch suspended, its record 131 read in the command - final from it.
    func testSuspendCommandWaitsForItsStatusAndReadsTheTempBasalsRecord() throws {
        let tempBasal = runTempBasalOfOurs()
        let delivered = notifySoonAfterTheSuspend(haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131))
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35, endReason: .SUSPEND_MANUAL))
        XCTAssertNil(commandSuspend())
        wait(for: [delivered], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(reports(of: .suspend).count, 1)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
    }

    /// The same, no status in, a heartbeat naming 131 the newest record instead: the command ends the temp basal itself,
    /// reading up to 131 - final from its record
    func testSuspendCommandReadsUpToTheRecordAHeartbeatNamesAfterIt() throws {
        let tempBasal = runTempBasalOfOurs()
        let delivered = notifySoonAfterTheSuspend(Self.heartbeat(naming: 131))
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35, endReason: .SUSPEND_MANUAL))
        XCTAssertNil(commandSuspend())
        wait(for: [delivered], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
    }

    /// The same, 131 unreadable: our estimate stands in, as before
    func testSuspendCommandWithTheTempBasalsRecordUnreadableFinalizesItFromOurEstimate() throws {
        let tempBasal = runTempBasalOfOurs()
        let delivered = notifySoonAfterTheSuspend(Self.heartbeat(naming: 131))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandSuspend())
        wait(for: [delivered], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "1.2 U/h for 20 min, by our estimate")
    }

    /// Nothing announced within the wait: the suspend - and the temp basal's end, by our estimate - is dated at the
    /// answer, not after the wait: the temp basal's rate counted over it, the patch suspended
    func testSuspendCommandWithNothingAnnouncedIsDatedAtItsAnswer() throws {
        let tempBasal = runTempBasalOfOurs()
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        let sentAt = Date.now
        XCTAssertNil(commandSuspend())
        XCTAssertGreaterThanOrEqual(Date.now.timeIntervalSince(sentAt), MedtrumPumpManager.suspendAnnouncementWait, "waited")
        settle()

        let suspend = try XCTUnwrap(reports(of: .suspend).first)
        XCTAssertLessThan(suspend.startDate.timeIntervalSince(sentAt), 1, "at the answer")
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.endDate, suspend.startDate)
    }

    /// Nothing announced within the wait, record 131 told of before the write and unread: the patch may have ended the
    /// temp basal before, unseen - it did, 5 min ago. 131 is read: final from it, not from our estimate up to the suspend.
    func testSuspendCommandWithNothingAnnouncedReadsTheRecordsUnreadBeforeIt() throws {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.state.currentSequenceNumber = 131
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.ourStart, end: Self.ourEnd.addingTimeInterval(-5 * Self.minute),
            rate: 1.2, delivered: 0.3, endReason: .SUSPEND_LOW_GLUCOSE
        ))
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "from its record, not 0.4 U by our estimate")
    }

    /// A temp basal past its end - it ran its course, its record 131 told of and unread: no announcement is waited for,
    /// and 131 is read - final from it
    func testSuspendCommandAfterATempBasalRanItsCourseReadsItsRecordWithoutWaiting() throws {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        let tempBasal = runningTempBasal(rate: 1.2, startedAgo: 40 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.ourStart)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        state.currentSequenceNumber = 131
        alignPatchClock(state, patchTime: Self.ourStart.addingTimeInterval(40 * Self.minute))
        makeManager(state)
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.ourStart, end: Self.ourStart.addingTimeInterval(30 * Self.minute),
            rate: 1.2, delivered: 0.55, endReason: .SUCCESS
        ))

        let sentAt = Date.now
        XCTAssertNil(commandSuspend())
        XCTAssertLessThan(Date.now.timeIntervalSince(sentAt), MedtrumPumpManager.suspendAnnouncementWait, "not waited")
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.55, accuracy: 0.001, "from its record, not 0.6 U by our estimate")
    }

    // MARK: After a resume dated ahead

    /// Suspended in this very second: the resume a status shows is dated in the next - up to a second ahead of now. A
    /// halt in that second is dated just after the resume, not at it: at its instant, Loop orders the two either way.
    func testHaltInTheSecondOfAResumeDatedAheadIsDatedJustAfterIt() throws {
        let resume = try resumeDatedAhead()
        link.notify(PatchBytes.suspendNotification(suspendedAt: Self.patchTime(397_186_623)))
        settle()

        let halt = try XCTUnwrap(reports(of: .suspend).last)
        XCTAssertGreaterThan(halt.startDate, resume.startDate)
        XCTAssertEqual(LoopOrderingChecker.stored(halt.startDate), LoopOrderingChecker.stored(resume.startDate), "in its second")
    }

    /// A suspend command in that second: dated after the resume, not at now - before it, oref0 would pair the suspend
    /// before the resume with it as well
    func testSuspendCommandInTheSecondOfAResumeDatedAheadIsDatedAfterIt() throws {
        let resume = try resumeDatedAhead()
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        XCTAssertNil(commandSuspend())
        settle()

        let suspend = try XCTUnwrap(reports(of: .suspend).last)
        XCTAssertGreaterThan(suspend.startDate, resume.startDate)
    }

    /// A temp basal set in that second starts after the resume, not before it
    func testTempBasalSetInTheSecondOfAResumeDatedAheadStartsAfterIt() throws {
        let resume = try resumeDatedAhead()
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1.2, sequence: 513, patchId: 237, start: Self.patchTime(397_186_623)
        ))
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        settle()

        let tempBasal = try XCTUnwrap(reports(of: .tempBasal).first)
        XCTAssertGreaterThan(tempBasal.startDate, resume.startDate)
    }

    // MARK: The unanswered one shown late

    /// The patch halts while the unanswered one is kept - a segment begun after it, the halt's - then resumes on a command
    /// whose answer tells no segment: a late status of the zero one's segment is late all the same, by that later segment.
    /// Kept, nothing reported. Taken to run from here, it would be dated over the suspension and the resume.
    func testUnansweredTempBasalShownAfterTheResumeOfAReportedSuspendIsLate() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 119))
        settle()
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.snapshot.laterSegmentStart, Self.c1)

        advanceClock(by: 2)
        link.script(CommandType.RESUME_PUMP, PatchBytes.answer(command: CommandType.RESUME_PUMP, body: Data()))
        XCTAssertNil(commandResume())
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        let batches = delegate.batches.count

        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: Self.patchTime(399_933_337), rate: 0
        ))
        settle()

        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "kept, its record to settle it")
        XCTAssertEqual(delegate.batches.count, batches, "nothing reported")
        XCTAssertFalse(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 })
    }

    /// The zero one shown late - it ran - and no record read up to past the halt is its, the halt's the schedule's: not
    /// dropped as never run, silently - warned of, shown not counted. Nothing of it is reported.
    func testUnansweredTempBasalShownLateWithNoRecordOfItsIsWarnedOf() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 119))
        settle()
        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: Self.patchTime(399_933_337), rate: 0
        ))
        settle()
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.snapshot.shownRunningFrom, Self.patchTime(399_933_337))

        advanceClock(by: 2)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(120, at: Self.c1))
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 0)

        advanceClock(by: 16 * Self.minute)
        confirmRecordSequence()
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
        XCTAssertFalse(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 })
    }

    // MARK: Driving

    /// Patch 237 on its schedule, 0.6 U/h, every record read up to 513, the patch clock `397_186_623` now
    func startOnTheSchedule() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)
    }

    /// 1.2 U/h set on the schedule of `startOnTheSchedule`, answered: no cancel before it
    func setTempBasalOnTheSchedule() {
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1.2, sequence: 515, patchId: 237, start: Self.patchTime(397_186_630)
        ))
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        settle()
    }

    /// `dose`, which the host did not store, goes out again in the first batch carrying a dose of `later` - ahead of it
    private func assertReportedAgain(_ dose: DoseEntry, aheadOf later: DoseType, file: StaticString = #filePath, line: UInt = #line) {
        guard let batch = delegate.batches.first(where: { $0.events.contains { $0.dose?.type == later } }) else {
            XCTFail("no batch carries a \(later)", file: file, line: line)
            return
        }
        let doses = batch.events.compactMap(\.dose)
        let again = doses.firstIndex { $0.syncIdentifier == dose.syncIdentifier }
        XCTAssertNotNil(again, "the \(dose.type) of \(dose.startDate) did not go out again", file: file, line: line)
        XCTAssertLessThan(again ?? .max, doses.firstIndex { $0.type == later } ?? -1, "ahead of it", file: file, line: line)
    }

    /// `hex` notified 0.3 s after the suspend command's answer - off the command's thread, as the patch sends it after
    /// its answer: fulfilled once handled
    func notifySoonAfterTheSuspend(_ hex: String) -> XCTestExpectation {
        let delivered = expectation(description: "notified after the answer")
        let link = link!
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"])) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                link.notify(hex)
                delivered.fulfill()
            }
        }
        return delivered
    }

    /// The patch's heartbeat naming `record` its newest, of patch 251
    private static func heartbeat(naming record: Int) -> String {
        "200001" + (UInt64(record).toData(length: 2) + UInt64(251).toData(length: 2)).hexEncodedString()
    }

    /// Suspended in this second - the host told so in a run before - then a status of the schedule: the resume is dated
    /// in the next second, ahead of now. Returns it.
    private func resumeDatedAhead() throws -> DoseEntry {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        // The clock aligned first: the schedule shown from then, before the second after the suspend's
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        let suspendedAt = Date(timeIntervalSinceReferenceDate: Date.now.timeIntervalSinceReferenceDate.rounded(.down))
        state.basalDose = UnfinalizedDose(suspendStartTime: suspendedAt)
        state.basalState = .suspended
        makeManager(state)
        hostSuspendedSince = suspendedAt

        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 513, patchId: 237, start: Self.patchTime(397_186_623), rate: 0.6))
        settle()
        let resume = try XCTUnwrap(reports(of: .resume).first)
        XCTAssertEqual(resume.startDate, suspendedAt.addingTimeInterval(1), "dated ahead, in the next second")
        return resume
    }
}

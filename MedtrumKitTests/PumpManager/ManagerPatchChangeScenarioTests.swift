import LoopKit
@testable import MedtrumKit
import XCTest

/// A patch change driven through the manager: the old patch's session ending, the new one's starting - its activation
/// answered, lost and retried - and the statuses either patch sends meanwhile. No log has these bytes: built with
/// `PatchBytes` and `notification`.
final class ManagerPatchChangeScenarioTests: MedtrumManagerTestCase {
    private static let oldPatchId: UInt64 = 270
    private static let newPatchId: UInt64 = 271
    private static let scheduledRate = 0.8

    // MARK: The new patch takes commands

    /// #210: the patch ran empty and halted, then was deactivated. The new patch delivers from its activation on: a temp
    /// basal and a bolus right after it are sent, not refused as suspended until its first status showing a basal - the
    /// first one shows only its state.
    func testTempBasalAndBolusRightAfterActivationFollowingAHaltedPatchAreSent() {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 0.5))
        link.notify(Self.notification(state: .reservoirEmpty, suspendedAt: Date.now.addingTimeInterval(-2 * Self.minute)))
        settle()
        XCTAssertEqual(pumpManager.state.basalState, .suspended)

        XCTAssertEqual(deactivate(), true)
        XCTAssertEqual(activate(), true)
        link.notify(Self.notification(state: .active, reservoir: 199))
        settle()
        XCTAssertEqual(pumpManager.state.basalState, .active)

        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 1.2,
            sequence: 0,
            patchId: Self.newPatchId,
            start: Self.patchSecond(Date.now)
        ))
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))

        link.script(CommandType.SET_BOLUS, Self.bolusAnswer(record: 1, start: Date.now))
        XCTAssertNil(commandBolus(0.5))
        settle()

        XCTAssertEqual(
            Array(link.writtenCommands.suffix(2)),
            [CommandType.SET_TEMP_BASAL, CommandType.SET_BOLUS],
            "no cancel first: the old patch's basal state is not the new one's"
        )
        XCTAssertNotNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
    }

    // MARK: One suspend per patch change

    /// The halt reported the suspend: deactivating reports no second one, which a host keeping only the last would take
    /// as delivering between the two
    func testDeactivatingAHaltedPatchReportsNoSecondSuspend() {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 0.5))
        let haltedAt = Self.patchSecond(Date.now.addingTimeInterval(-2 * Self.minute))
        link.notify(Self.notification(state: .reservoirEmpty, suspendedAt: haltedAt))
        settle()
        XCTAssertEqual(reports(of: .suspend).map(\.startDate), [haltedAt])

        XCTAssertEqual(deactivate(), true)

        XCTAssertEqual(reports(of: .suspend).map(\.startDate), [haltedAt])
        XCTAssertEqual(reports(of: .resume).count, 0)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalDose.startDate, haltedAt)
        XCTAssertEqual(pumpManager.state.previousPatch?.patchId, Self.oldPatchId.toData(length: 4))
    }

    /// A running patch's deactivation is when it stopped
    func testDeactivatingARunningPatchReportsItsSuspend() {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))

        let before = Date.now
        XCTAssertEqual(deactivate(), true)

        let suspends = reports(of: .suspend)
        XCTAssertEqual(suspends.count, 1)
        XCTAssertGreaterThanOrEqual(suspends.first?.startDate ?? .distantPast, before)
        XCTAssertEqual(pumpManager.state.basalState, .suspended, "no patch delivers until the next one's session starts")
        XCTAssertTrue(pumpManager.state.patchSessionEnded)
    }

    /// Suspended by a command, the status current while connected: deactivating reports no second suspend. Forced, out
    /// of reach, the suspend may have ended on its own since: then it does - the first one resumed before it.
    func testDeactivatingASuspendedPatchReportsASuspendOnlyWhenForced() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        link.notify(PatchBytes.suspendNotification(suspendedAt: Self.patchSecond(Date.now.addingTimeInterval(-10 * Self.minute))))
        settle()
        XCTAssertEqual(reports(of: .suspend).count, 1)
        let suspended = pumpManager.state.rawValue

        XCTAssertEqual(deactivate(), true)
        XCTAssertEqual(reports(of: .suspend).count, 1)
        XCTAssertEqual(reports(of: .resume).count, 0)

        // The next run's host has it
        hostSuspendedSince = try XCTUnwrap(reports(of: .suspend).first?.startDate)
        try restart(from: suspended)
        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertEqual(reports(of: .suspend).count, 1, "the forced one's own")
        XCTAssertEqual(delegate.batches.flatMap(\.events).compactMap(\.dose).map(\.type), [.resume, .suspend])
        XCTAssertGreaterThan(pumpManager.state.basalDose.startDate, Date.now.addingTimeInterval(-Self.minute))
    }

    /// Suspended 10 min ago, the patch last heard from 4 min ago still suspended, then forced out of reach: it may have
    /// resumed since. Its suspend is resumed where it was last known suspended, and the session's own suspend follows in
    /// a later second - a second suspend over the open one would have oref0 pair both with the next patch's resume, and
    /// zero the time from the second one to it twice. The new patch's activation resumes the second one.
    func testForcingASuspendedPatchResumesItsSuspendBeforeReportingAnother() throws {
        let suspendedAt = Self.patchSecond(Date.now.addingTimeInterval(-10 * Self.minute))
        let lastHeardAt = Date.now.addingTimeInterval(-4 * Self.minute)
        makeManager(suspendedPatchState(since: suspendedAt, lastHeardAt: lastHeardAt, showing: .suspended))

        let forcedAt = Date.now
        pumpManager.forceDeactivatePatch()
        settle()

        let doses = delegate.batches.flatMap(\.events).compactMap(\.dose)
        XCTAssertEqual(doses.map(\.type), [.resume, .suspend])
        let resumedAt = try XCTUnwrap(doses.first?.startDate)
        let suspendedAgainAt = try XCTUnwrap(doses.last?.startDate)
        XCTAssertEqual(resumedAt, lastHeardAt, "where it was last known suspended")
        XCTAssertGreaterThan(LoopOrderingChecker.stored(suspendedAgainAt), LoopOrderingChecker.stored(resumedAt), "in a later second")
        XCTAssertGreaterThanOrEqual(suspendedAgainAt, forcedAt, "when forced")

        XCTAssertEqual(activate(), true)
        assertEachSuspendResumedOnItsOwn(storedBefore: suspendedAt)
    }

    /// The same with a command answered since that status - a basal profile set, which moves `lastSync` and shows
    /// nothing of the patch's state: the suspend is resumed where that status showed it suspended, not at the answer.
    /// The patch may have resumed on its own in between: what it delivered from then on would be zeroed in iAPS.
    func testForcingASuspendedPatchResumesItsSuspendAtItsLastSuspendedStatusNotACommandsAnswer() throws {
        let suspendedAt = Self.patchSecond(Date.now.addingTimeInterval(-10 * Self.minute))
        makeManager(suspendedPatchState(since: suspendedAt, lastHeardAt: suspendedAt, showing: .suspended))
        link.notify(Self.notification(state: .suspended))
        settle()
        let shownSuspendedAt = try XCTUnwrap(pumpManager.state.lastShownNotDeliveringAt)
        XCTAssertGreaterThan(shownSuspendedAt, suspendedAt.addingTimeInterval(9 * Self.minute), "the status's")

        link.script(CommandType.SET_BASAL_PROFILE, PatchBytes.segmentAnswer(
            command: CommandType.SET_BASAL_PROFILE,
            type: .SUSPEND_MANUAL,
            rate: 0,
            sequence: 10,
            patchId: Self.oldPatchId,
            start: suspendedAt
        ))
        let result: Result<BasalRateSchedule, Error>? = completion(of: "syncBasalRateSchedule") { done in
            self.pumpManager.syncBasalRateSchedule(items: [RepeatingScheduleValue(startTime: 0, value: 0.7)], completion: done)
        }
        settle()
        XCTAssertNotNil(try result?.get())
        XCTAssertGreaterThan(pumpManager.state.lastSync, shownSuspendedAt, "the answer's")
        XCTAssertEqual(pumpManager.state.lastShownNotDeliveringAt, shownSuspendedAt)

        pumpManager.forceDeactivatePatch()
        settle()

        let doses = delegate.batches.flatMap(\.events).compactMap(\.dose)
        XCTAssertEqual(doses.map(\.type), [.resume, .suspend])
        XCTAssertEqual(doses.first?.startDate, shownSuspendedAt, "where its last status showed it suspended")

        XCTAssertEqual(activate(), true)
        assertEachSuspendResumedOnItsOwn(storedBefore: suspendedAt)
    }

    /// The same for a base reset, the last status of the patch from before its suspend - a suspend command's, its status
    /// not in: resumed in the second after it, the reset's suspend where delivery stopped
    func testBaseResetUnderASuspendedPatchResumesItsSuspendBeforeReportingAnother() throws {
        let suspendedAt = Self.patchSecond(Date.now.addingTimeInterval(-10 * Self.minute)).addingTimeInterval(0.4)
        makeManager(suspendedPatchState(since: suspendedAt, lastHeardAt: suspendedAt, showing: .active))
        let stoppedAt = Date.now.addingTimeInterval(-Self.minute)

        pumpManager.handleBaseReset(deliveryStoppedAt: stoppedAt)
        settle()

        let doses = delegate.batches.flatMap(\.events).compactMap(\.dose)
        XCTAssertEqual(doses.map(\.type), [.resume, .suspend])
        XCTAssertEqual(doses.first?.startDate, MedtrumPumpManager.earliestResume(after: suspendedAt))
        XCTAssertEqual(doses.last?.startDate, stoppedAt)

        XCTAssertEqual(activate(), true)
        assertEachSuspendResumedOnItsOwn(storedBefore: suspendedAt)
    }

    /// Ended already, a forced deactivation keeps the previous patch the deactivation recorded
    func testForcingADeactivatedPatchKeepsThePreviousPatch() {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivate(), true)
        let deactivatedAt = pumpManager.state.previousPatch?.deactivatedAt

        pumpManager.forceDeactivatePatch()
        settle()

        XCTAssertEqual(pumpManager.state.previousPatch?.patchId, Self.oldPatchId.toData(length: 4))
        XCTAssertEqual(pumpManager.state.previousPatch?.deactivatedAt, deactivatedAt)
        XCTAssertEqual(reports(of: .suspend).count, 1)
    }

    // MARK: The new patch's session

    /// The resume comes after the suspend it ends, in a later second - iAPS stores both to the second, and pairs a resume
    /// with an earlier suspend only - and the patch replacement is dated when the session started, no later than it
    func testActivationResumesAfterTheSuspendTheDeactivationReported() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivate(), true)
        XCTAssertEqual(activate(), true)

        let suspends = reports(of: .suspend)
        let resumes = reports(of: .resume)
        XCTAssertEqual(suspends.count, 1)
        XCTAssertEqual(resumes.count, 1)
        let suspendedAt = try XCTUnwrap(suspends.first?.startDate)
        let resumedAt = try XCTUnwrap(resumes.first?.startDate)
        XCTAssertGreaterThan(LoopOrderingChecker.stored(resumedAt), LoopOrderingChecker.stored(suspendedAt), "in a later second")
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(patchReplacements.first?.date), resumedAt)
        XCTAssertLessThanOrEqual(resumedAt.timeIntervalSince(try XCTUnwrap(patchReplacements.first?.date)), 1)
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(pumpManager.state.patchId, Self.newPatchId.toData(length: 4))
    }

    /// The deactivation's suspend, the app killed before the host stored it - the host "fails" its batch: kept with the
    /// state, it goes out again with the next run's first batch, the activation's, ahead of its resume. Lost, the resume
    /// would be one with none before it: iAPS takes the patch to have been suspended since before its history, and zeroes
    /// every temp basal before the resume, and the scheduled basal from 8 h back.
    func testDeactivationSuspendTheHostDidNotStoreGoesOutAgainWithTheActivationsResume() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        XCTAssertEqual(deactivate(), true)
        let suspend = try XCTUnwrap(reports(of: .suspend).first)

        try restart(from: delegate.savedState)
        XCTAssertEqual(activate(), true)

        let batch = try XCTUnwrap(delegate.batches.first { $0.events.contains { $0.dose?.type == .resume } })
        let doses = batch.events.compactMap(\.dose)
        XCTAssertEqual(doses.map(\.type), [.suspend, .resume], "again, ahead of the resume")
        XCTAssertEqual(doses.first?.syncIdentifier, suspend.syncIdentifier)
    }

    /// The activation's resume, the app killed before the host stored it: it goes out again with the next run's first
    /// batch - a full status's. Lost, the deactivation's suspend would stay open: every temp basal after it zeroed.
    func testActivationResumeTheHostDidNotStoreGoesOutAgainAfterARestart() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivate(), true)
        // Stored: the next run's host has it, not only this one's
        hostSuspendedSince = try XCTUnwrap(reports(of: .suspend).first?.startDate)
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        XCTAssertEqual(activate(), true)
        let resume = try XCTUnwrap(reports(of: .resume).first)

        try restart(from: delegate.savedState)
        link.deliverFullStatus(
            notification: Self.notification(state: .active, storage: (sequence: 1, patchId: Self.newPatchId)),
            duringReconnect: false
        )
        settle()

        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.filter { $0.type == .resume }.map(\.syncIdentifier), [resume.syncIdentifier], "again")
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty, "stored")
    }

    /// The first patch: nothing was reported before it - no suspend, so no resume
    func testFirstActivationReportsOnlyThePatchReplacement() {
        let state = MedtrumPumpState(nil)
        state.isOnboarded = true
        state.pumpState = .primed
        state.basalSchedule = BasalSchedule(entries: [RepeatingScheduleValue(startTime: 0, value: Self.scheduledRate)])
        makeManager(state)

        XCTAssertEqual(activate(), true)

        XCTAssertEqual(delegate.batches.flatMap(\.events).compactMap(\.dose).map(\.type), [])
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
    }

    /// The previous patch was never deactivated - it fell off, or was swapped outside the app - with a temp basal
    /// running: it ends at the activation, and the schedule runs from there. No suspend, nor a resume with it.
    func testActivationAfterASessionThatNeverEndedEndsItsTempBasalThere() throws {
        let state = activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50)
        let tempBasal = runningTempBasal(rate: 1.5, startedAgo: 10 * Self.minute, duration: 30 * Self.minute)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        state.pumpState = .primed
        makeManager(state)

        let before = Date.now
        XCTAssertEqual(activate(), true)

        let start = try XCTUnwrap(patchReplacements.first?.date)
        XCTAssertGreaterThanOrEqual(start, before)
        let finals = reports(of: .tempBasal).filter { !$0.isMutable }
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(finals.first?.endDate, start)
        XCTAssertEqual(reports(of: .basal).map(\.startDate), [start])
        XCTAssertEqual(reports(of: .suspend).count, 0)
        XCTAssertEqual(reports(of: .resume).count, 0)
        XCTAssertEqual(pumpManager.state.basalState, .active)
    }

    /// The same with a bolus running: it ends at the activation, at the amount last reported - warned of, and shown, as
    /// uncertain
    func testActivationAfterASessionThatNeverEndedWarnsOfTheBolusInFlight() {
        let state = activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50)
        let bolus = UnfinalizedDose(
            units: 2,
            duration: 80,
            activationType: .manualNoRecommendation,
            insulinType: nil,
            startDate: Date.now.addingTimeInterval(-30)
        )
        bolus.noteCommand(sentAt: bolus.startDate, uptime: nil, sequence: 10)
        state.bolusDose = bolus
        state.pumpState = .primed
        makeManager(state)

        XCTAssertEqual(activate(), true)

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(reports(of: .bolus).filter { !$0.isMutable }.count, 1)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(uncertain.map(\.cause), [.patchDeactivated])
        XCTAssertEqual(uncertain.first?.phase, .settled(.byEstimate))
    }

    // MARK: An activation whose answer was lost

    /// The patch activated and is delivering, its answer lost: the retry starts the session, resuming where the patch says
    /// it activated - no status resumed meanwhile - the expiry from then too. A second retry starts none. The activation
    /// sent by an earlier build, which kept no marker: its status starts no session on its own.
    func testRetriedActivationStartsTheSessionOfADeliveringPatch() throws {
        makeManager(endedSessionState())
        XCTAssertEqual(activateWithTheAnswerLostByAnEarlierBuild(), true)

        let activatedAt = Self.patchSecond(Date.now.addingTimeInterval(-Self.minute))
        link.notify(Self.notification(state: .active, activatedAt: activatedAt, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()
        XCTAssertTrue(pumpManager.state.patchSessionEnded)

        let retriedAt = Date.now
        XCTAssertEqual(activate(), true)

        let resumes = reports(of: .resume)
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(resumes.first?.startDate.timeIntervalSince(activatedAt) ?? -1, 0, accuracy: 1, "the patch's start")
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(pumpManager.state.patchActivatedAt, activatedAt, "the patch's own, not the retry's")
        let delay = try XCTUnwrap(expiryReminderDelays.last)
        XCTAssertEqual(delay, pumpManager.state.notificationAfterActivation - retriedAt.timeIntervalSince(activatedAt), accuracy: 2)

        let batches = delegate.batches.count
        let alerts = delegate.alerts.count
        XCTAssertEqual(activate(), true)
        XCTAssertEqual(delegate.batches.count, batches)
        XCTAssertEqual(delegate.alerts.count, alerts)
        XCTAssertEqual(pumpManager.state.patchActivatedAt, activatedAt)

        // The first status after the retry sets the new patch's id
        link.notify(Self.notification(state: .active, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()
        XCTAssertEqual(pumpManager.state.patchId, Self.newPatchId.toData(length: 4))
    }

    /// The previous patch's start time, still kept: the expiry counts from the retry
    func testRetriedActivationWithThePreviousPatchsStartCountsFromTheRetry() throws {
        let state = endedSessionState()
        state.pumpState = .active
        makeManager(state)

        let retriedAt = Date.now
        XCTAssertEqual(activate(), true)

        XCTAssertGreaterThanOrEqual(pumpManager.state.patchActivatedAt ?? .distantPast, retriedAt)
        let delay = try XCTUnwrap(expiryReminderDelays.last)
        XCTAssertEqual(delay, pumpManager.state.notificationAfterActivation, accuracy: 1)
    }

    /// Suspended since its lost answer - here at its hourly maximum: the retry resumes nothing, and dosing is refused.
    /// The first status showing it delivering resumes.
    func testRetriedActivationOfASuspendedPatchResumesOnItsFirstDeliveringStatus() throws {
        makeManager(endedSessionState())
        XCTAssertEqual(activateWithTheAnswerLostByAnEarlierBuild(), true)

        link.notify(Self.notification(state: .hourlyMaxSuspended, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()
        XCTAssertEqual(activate(), true)

        XCTAssertEqual(reports(of: .resume).count, 0)
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        guard case .deviceState? = commandBolus(0.5) else {
            XCTFail("a suspended patch is sent no bolus")
            return
        }

        let resumedAt = Self.patchSecond(Date.now)
        link.notify(PatchBytes.basalNotification(
            type: .STANDARD,
            sequence: 1,
            patchId: Self.newPatchId,
            start: resumedAt,
            rate: Self.scheduledRate
        ))
        settle()

        // Through the skew of the patch time the activation read, within a second
        let resumes = reports(of: .resume)
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(resumes.first?.startDate.timeIntervalSince(resumedAt) ?? -1, 0, accuracy: 1)
        XCTAssertEqual(pumpManager.state.basalState, .active)
    }

    // MARK: An activation whose answer was lost, its session started on its own

    /// The patch activated, its answer lost, and the activation sheet swiped away - no retry, nothing else reaching the
    /// activation: the first status showing the patch running under its own id starts the session, as a retry would -
    /// resumed where the patch says it activated, the expiry from then - and commands go to it
    func testLostActivationAnswerStartsTheSessionOnTheFirstRunningStatus() throws {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)
        XCTAssertNotNil(pumpManager.state.activationSentAt)
        XCTAssertTrue(pumpManager.state.patchSessionEnded)

        let activatedAt = Self.patchSecond(Date.now.addingTimeInterval(-Self.minute))
        link.notify(Self.notification(state: .active, activatedAt: activatedAt, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()

        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertNil(pumpManager.state.activationSentAt)
        let resumes = reports(of: .resume)
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(resumes.first?.startDate.timeIntervalSince(activatedAt) ?? -1, 0, accuracy: 1, "the patch's start")
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(pumpManager.state.patchActivatedAt, activatedAt)
        assertEachSuspendResumedOnItsOwn(storedBefore: try XCTUnwrap(hostSuspendedSince))

        // Its id from the next status, and dosing goes to it
        link.notify(Self.notification(state: .active, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()
        XCTAssertEqual(pumpManager.state.patchId, Self.newPatchId.toData(length: 4))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 1.2,
            sequence: 1,
            patchId: Self.newPatchId,
            start: Self.patchSecond(Date.now)
        ))
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)

        // The sheet opened again: its retry starts nothing more
        let batches = delegate.batches.count
        XCTAssertEqual(activate(), true)
        XCTAssertEqual(delegate.batches.count, batches)
        XCTAssertEqual(patchReplacements.count, 1)
    }

    /// The same, the app killed after the activation went out: the marker comes back with the state, and the connect's
    /// status starts the session
    func testLostActivationAnswerStartsTheSessionOnTheFirstRunningStatusAfterARestart() throws {
        makeManager(endedSessionState())
        XCTAssertEqual(activateWithTheAnswerLost(), true)
        let sentAt = try XCTUnwrap(pumpManager.state.activationSentAt)

        try restart(from: delegate.savedState)
        XCTAssertEqual(pumpManager.state.activationSentAt, sentAt, "saved")
        XCTAssertTrue(pumpManager.state.patchSessionEnded)

        let activatedAt = Self.patchSecond(Date.now.addingTimeInterval(-2 * Self.minute))
        link.deliverFullStatus(notification: Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: activatedAt, patchId: Self.newPatchId),
            reservoir: 199,
            activatedAt: activatedAt,
            storage: (sequence: 1, patchId: Self.newPatchId)
        ), duringReconnect: true)
        settle()

        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertNil(pumpManager.state.activationSentAt)
        let resumes = reports(of: .resume)
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(resumes.first?.startDate.timeIntervalSince(activatedAt) ?? -1, 0, accuracy: 1, "the patch's start")
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        assertEachSuspendResumedOnItsOwn(storedBefore: try XCTUnwrap(hostSuspendedSince))
    }

    /// No activation sent - none of this host's, or one an earlier build sent: a patch running under a new id starts no
    /// session. Its statuses are taken - its state, its id - and commands refused until an activation starts one.
    func testRunningStatusWithNoActivationSentStartsNoSession() {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertNil(pumpManager.state.activationSentAt)

        link.notify(Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now), patchId: Self.newPatchId),
            activatedAt: Self.patchSecond(Date.now.addingTimeInterval(-Self.minute)),
            storage: (sequence: 1, patchId: Self.newPatchId)
        ))
        settle()

        XCTAssertEqual(pumpManager.state.pumpState, .active)
        XCTAssertTrue(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(reports(of: .resume).count, 0)
        XCTAssertEqual(patchReplacements.count, 0)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
    }

    /// A marker left from an activation of a patch never activated - its answer lost, the patch still primed - and the
    /// old patch heard from running after: not the new patch, no session
    func testOldPatchRunningAfterALostActivationAnswerStartsNoSession() {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)

        link.notify(Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now), patchId: Self.oldPatchId),
            storage: (sequence: 12, patchId: Self.oldPatchId)
        ))
        // Naming no id: can't be told apart
        link.notify(Data([PatchState.active.rawValue]).hexEncodedString())
        settle()

        XCTAssertTrue(pumpManager.state.patchSessionEnded)
        XCTAssertNotNil(pumpManager.state.activationSentAt)
        XCTAssertEqual(reports(of: .resume).count, 0)
        XCTAssertEqual(patchReplacements.count, 0)
    }

    /// The session started on its own keeps the id the status named, and the records it took up there: a temp basal and a
    /// bolus sent before the next status go to that patch - the bolus's answer names its record, claimed - and the next
    /// status takes nothing up again. The record finalizes the bolus by its number: nothing uncertain, nothing not counted.
    func testSessionStartedOnItsOwnKeepsThePatchIdForTheDosesBeforeTheNextStatus() throws {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)

        let activatedAt = Self.patchSecond(Date.now.addingTimeInterval(-Self.minute))
        link.notify(Self.notification(state: .active, activatedAt: activatedAt, storage: (sequence: 2, patchId: Self.newPatchId)))
        settle()
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(pumpManager.state.patchId, Self.newPatchId.toData(length: 4))
        XCTAssertEqual(pumpManager.state.sessionStartSequence, 2)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 2)

        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 1.2,
            sequence: 3,
            patchId: Self.newPatchId,
            start: Self.patchSecond(Date.now)
        ))
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        let bolusStart = Self.patchSecond(Date.now)
        link.script(CommandType.SET_BOLUS, Self.bolusAnswer(record: 4, start: bolusStart))
        XCTAssertNil(commandBolus(1))
        settle()
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 4, "its answer is this patch's")
        let started = try XCTUnwrap(reports(of: .bolus).first)

        link.notify(Self.notification(
            state: .active,
            bolus: (completed: true, delivered: 1),
            storage: (sequence: 4, patchId: Self.newPatchId)
        ))
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.sessionStartSequence, 2, "not taken up again")
        XCTAssertEqual(pumpManager.state.answeredBolusRecords, [4])

        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 1, patchId: Self.newPatchId))
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 2, patchId: Self.newPatchId))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 3,
            patchId: Self.newPatchId,
            type: .STANDARD,
            start: activatedAt,
            end: Self.patchSecond(Date.now),
            rate: Self.scheduledRate,
            delivered: 0
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 4,
            patchId: Self.newPatchId,
            start: bolusStart,
            amount: 1,
            delivered: 1
        ))
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(uncertain.isEmpty)
        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertFalse(delegate.alerts.contains { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted") })
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
    }

    /// The patch's running status in while its ActivatePacket is out, the answer coming after: the answer starts the
    /// session, the start the status queued finds it started - one session, one resume, one patch replacement
    func testRunningStatusDuringTheActivationWriteStartsOneSession() {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()

        scriptTimeSync()
        link.script(CommandType.ACTIVATE, .fragments(Self.activateAnswer(start: Date.now))) {
            self.link.notify(Self.notification(
                state: .active,
                activatedAt: Self.patchSecond(Date.now),
                storage: (sequence: 0, patchId: Self.newPatchId)
            ))
        }
        XCTAssertEqual(runActivation(), true)
        settle()

        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertNil(pumpManager.state.activationSentAt)
        XCTAssertEqual(reports(of: .resume).count, 1)
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertEqual(expiryReminderDelays.count, 1, "one session started")
        XCTAssertEqual(pumpManager.state.patchId, Self.newPatchId.toData(length: 4))
    }

    /// The patch activated, its answer lost, its first status suspended - at its hourly maximum: the session starts on it
    /// all the same, its suspend standing - no resume, dosing refused - until the first status showing it delivering
    func testSuspendedRunningStatusStartsTheSessionItsSuspendStandingUntilItDelivers() {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)

        link.notify(Self.notification(state: .hourlyMaxSuspended, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()

        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertEqual(reports(of: .resume).count, 0)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        guard case .deviceState? = commandBolus(0.5) else {
            XCTFail("a suspended patch is sent no bolus")
            return
        }

        let resumedAt = Self.patchSecond(Date.now)
        link.notify(PatchBytes.basalNotification(
            type: .STANDARD,
            sequence: 1,
            patchId: Self.newPatchId,
            start: resumedAt,
            rate: Self.scheduledRate
        ))
        settle()

        let resumes = reports(of: .resume)
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(resumes.first?.startDate.timeIntervalSince(resumedAt) ?? -1, 0, accuracy: 1)
        XCTAssertEqual(pumpManager.state.basalState, .active)
    }

    /// The marker set, a running status naming no id - can't be told from the old patch's - starts nothing; the next one
    /// naming the new patch's id does
    func testRunningStatusNamingNoIdStartsNoSessionTheNextNamingOneDoes() {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)

        link.notify(Data([PatchState.active.rawValue]).hexEncodedString())
        settle()
        XCTAssertEqual(pumpManager.state.pumpState, .active)
        XCTAssertTrue(pumpManager.state.patchSessionEnded)
        XCTAssertNotNil(pumpManager.state.activationSentAt)
        XCTAssertEqual(patchReplacements.count, 0)

        link.notify(Self.notification(state: .active, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertNil(pumpManager.state.activationSentAt)
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertEqual(reports(of: .resume).count, 1)
    }

    /// The status that starts the session in while another operation holds the patch - a full status the heartbeat asked
    /// for between commands: the start waits for it, and runs once it is over
    func testSessionStartQueuedBehindAnOperationHoldingThePatchRunsOnceItIsOver() {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)

        let held = pumpManager.betweenCommands { () -> Bool in
            link.notify(Self.notification(state: .active, storage: (sequence: 1, patchId: Self.newPatchId)))
            // No settle: the start waits on this very lock
            return pumpManager.state.patchSessionEnded
        }
        XCTAssertEqual(held, true, "not started while the patch is held")

        settle()
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertEqual(reports(of: .resume).count, 1)
    }

    /// The previous patch's id not known - a retried activation's session forced out before a status named it - and an
    /// activation sent since with that patch still on the base, its answer lost: its running status, naming its id, is
    /// not taken - nothing of a next patch seen - and starts no session
    func testOldPatchOfAnUnknownIdRunningWithTheMarkerSetStartsNoSession() throws {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)
        link.notify(Data([PatchState.active.rawValue]).hexEncodedString())
        settle()
        XCTAssertEqual(activate(), true)
        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertEqual(pumpManager.state.previousPatch?.patchId, Data())
        let replacements = patchReplacements.count
        let resumes = reports(of: .resume).count

        XCTAssertEqual(activateWithTheAnswerLost(), true)
        XCTAssertNotNil(pumpManager.state.activationSentAt)
        link.notify(Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now), patchId: Self.newPatchId),
            storage: (sequence: 2, patchId: Self.newPatchId)
        ))
        settle()

        XCTAssertTrue(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(pumpManager.state.pumpState, .none, "not taken")
        XCTAssertEqual(patchReplacements.count, replacements)
        XCTAssertEqual(reports(of: .resume).count, resumes)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
    }

    /// The activation turned down, or never sent: the patch did not activate on it - the marker goes. Its answer lost, it
    /// stays, through a primed status - one may come as it is written - until a next patch is seen being set up.
    func testActivationMarkerGoesWithARefusedActivationOrANextPatchsSetup() {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()

        for refusal in [MedtrumWriteError.invalidResponse(code: 8), .notConnected] {
            scriptTimeSync()
            link.script(CommandType.ACTIVATE, .failure(refusal))
            XCTAssertEqual(runActivation(), false)
            XCTAssertNil(pumpManager.state.activationSentAt, "\(refusal)")
        }

        XCTAssertEqual(activateWithTheAnswerLost(), true)
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertNotNil(pumpManager.state.activationSentAt, "primed: kept")

        link.notify(Self.notification(state: .filled))
        settle()
        XCTAssertNil(pumpManager.state.activationSentAt)
    }

    /// The marker set, a status in state `.none` - what an unknown state byte reads as too: no next patch seen being set
    /// up, the marker stays - and the next running status naming the new patch's id starts its session
    func testNoneStatusWithTheMarkerSetKeepsItAndTheSessionStillStartsOnItsOwn() {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)

        link.notify(Self.notification(state: .none))
        link.notify(Data([0x55]).hexEncodedString())
        settle()
        XCTAssertEqual(pumpManager.state.pumpState, .none)
        XCTAssertNotNil(pumpManager.state.activationSentAt, "kept")

        link.notify(Self.notification(state: .active, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertNil(pumpManager.state.activationSentAt)
        XCTAssertEqual(patchReplacements.count, 1)
        XCTAssertEqual(reports(of: .resume).count, 1)
    }

    /// A marker left from an activation whose answer was lost, no status since showing a next patch set up: priming the
    /// next patch clears it - a running status of it after starts no session on its own
    func testPrimingANextPatchClearsAStaleMarker() throws {
        let state = endedSessionState()
        state.pumpSN = Data([0x01, 0x02, 0x03, 0x04])
        state.pumpState = .filled
        state.activationSentAt = Date.now.addingTimeInterval(-Self.hour)
        makeManager(state)

        link.script(CommandType.PRIME, PatchBytes.answer(command: CommandType.PRIME, body: Data()))
        let result: MedtrumPrimePatchResult? = completion(of: "primePatch") { done in
            self.pumpManager.primePatch(done)
        }
        settle()
        guard case .success? = result else {
            XCTFail("primed: \(String(describing: result))")
            return
        }

        XCTAssertNil(pumpManager.state.activationSentAt)
        XCTAssertNil(MedtrumPumpState(rawValue: try XCTUnwrap(delegate.savedState)).activationSentAt, "saved")

        link.notify(Self.notification(state: .active, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()
        XCTAssertTrue(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(patchReplacements.count, 0)
    }

    /// The settings screen with a patch running and no session - the activation sheet dismissed after its answer was
    /// lost - offers the activation, whose retry starts it: as the row with a patch shown, and as the one with none shown
    /// (its id not named yet), which goes there rather than to setting up a base. The screens open there too.
    func testSettingsOfferTheActivationOfARunningPatchWithNoSession() {
        let state = endedSessionState()
        state.pumpState = .active
        makeManager(state)

        var activations: [Bool] = []
        var baseSetups = 0
        let viewModel = MedtrumKitSettingsViewModel(
            pumpManager, {}, { activations.append($0) }, {}, {}, {}, {}, {}, {}, {}, { baseSetups += 1 }
        )
        XCTAssertTrue(viewModel.showsActivatePatch)
        viewModel.toPumpActivation()
        viewModel.activatePatchPressed()
        XCTAssertEqual(activations, [true, true], "to the activation, not to priming")
        XCTAssertEqual(baseSetups, 0)
        XCTAssertEqual(MedtrumKitUICoordinator.initialScreens(for: pumpManager), [.patchActivationScreen])

        // In its session: none of it
        makeManager(activePatchState(patchId: Self.newPatchId, scheduledRate: Self.scheduledRate, sequence: 1, reservoir: 199))
        let running = MedtrumKitSettingsViewModel(pumpManager, {}, { activations.append($0) }, {}, {}, {}, {}, {}, {}, {}, { baseSetups += 1 })
        XCTAssertFalse(running.showsActivatePatch)
        XCTAssertEqual(MedtrumKitUICoordinator.initialScreens(for: pumpManager), [.settingsScreen])

        // No patch at all: set up from the base
        makeManager(endedSessionState())
        let none = MedtrumKitSettingsViewModel(pumpManager, {}, { activations.append($0) }, {}, {}, {}, {}, {}, {}, {}, { baseSetups += 1 })
        none.activatePatchPressed()
        XCTAssertEqual(baseSetups, 1)
        XCTAssertEqual(activations, [true, true])
    }

    // MARK: Commands with no session

    /// Rule 1 alone: a patch shown running - its activation's answer lost, sent by an earlier build - its basal state not
    /// suspended (as no path leaves it, so the dosing commands' own checks pass): every command is refused before
    /// anything is written, told so
    func testEveryCommandIsRefusedForARunningPatchWithNoSession() {
        let state = endedSessionState()
        state.pumpState = .active
        state.basalState = .active
        makeManager(state)

        for error in [commandBolus(0.5), commandTempBasal(1.2, duration: 30 * Self.minute), commandTempBasal(0, duration: 0)] {
            guard case let .deviceState(refusal)? = error, case .noActivePatch? = refusal as? MedtrumConnectError else {
                XCTFail("refused for no session: \(String(describing: error))")
                continue
            }
        }
        for error in [commandResume(), commandSuspend()] {
            guard case .noActivePatch? = error as? MedtrumConnectError else {
                XCTFail("refused for no session: \(String(describing: error))")
                continue
            }
        }
        guard case let .failure(.deviceState(refusal))? = commandCancelBolus(), case .noActivePatch? = refusal as? MedtrumConnectError else {
            XCTFail("the cancel refused for no session")
            return
        }
        let cleared: Bool? = completion(of: "clearAlert") { done in
            self.pumpManager.clearAlert(alertType: .hourly, completion: done)
        }
        XCTAssertEqual(cleared, false)
        settle()

        XCTAssertEqual(link.writtenCommands, [], "nothing written")
        XCTAssertEqual(MedtrumConnectError.noActivePatch.errorDescription, "No patch is active. Activate a patch first.")
    }

    /// Rule 1 again, holding the command lock: a command that passed it before a deactivation took the lock - queued
    /// behind it - is refused once the deactivation ended the session, nothing written
    func testACommandQueuedBehindADeactivationIsRefused() {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        let refused = expectation(description: "resumeDelivery")
        let outcome = Locked<Error?>(nil)
        link.script(
            CommandType.STOP_PATCH,
            .fragments(PatchBytes.answer(command: CommandType.STOP_PATCH, body: UInt64(10).toData(length: 2) + Self.oldPatchId.toData(length: 2)))
        ) {
            // The session still runs: past the check before the lock, waiting for it
            XCTAssertFalse(self.pumpManager.state.patchSessionEnded)
            self.pumpManager.resumeDelivery { error in
                outcome.value = error
                refused.fulfill()
            }
        }
        let result: MedtrumDeactivatePatchResult? = completion(of: "deactivatePatch") { done in
            self.pumpManager.deactivatePatch(done)
        }
        wait(for: [refused], timeout: 5)
        settle()

        guard case .success? = result else {
            XCTFail("Not deactivated: \(String(describing: result))")
            return
        }
        guard case .noActivePatch? = outcome.value as? MedtrumConnectError else {
            XCTFail("refused once the session ended: \(String(describing: outcome.value))")
            return
        }
        XCTAssertEqual(link.writtenCommands.filter { $0 != CommandType.STOP_PATCH }, [], "nothing but the stop")
        XCTAssertEqual(reports(of: .resume).count, 0)
    }

    // MARK: A session forced to end while a command is out

    /// The SetTempBasal answered by the old patch as the deactivation is forced: the command fails, nothing pending, no
    /// temp basal kept or reported. Killed with the state saved as it was forced - the temp basal pending in it - the
    /// app comes back with none of it: no uncertain delivery, not taken to run a temp basal - and the next patch's session
    /// starts clear of it.
    func testSessionForcedToEndDuringASetTempBasalLeavesNothingOfItAfterARestart() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        let atForce = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_TEMP_BASAL, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 1.2,
            sequence: 10,
            patchId: Self.oldPatchId,
            start: Self.patchSecond(Date.now)
        ))) {
            self.pumpManager.forceDeactivatePatch()
            atForce.value = self.pumpManager.state.rawValue
        }
        let error = commandTempBasal(1.2, duration: 30 * Self.minute)
        settle()

        guard case let .deviceState(refusal)? = error, case .noActivePatch? = refusal as? MedtrumConnectError else {
            XCTFail("the set fails, the session ended: \(String(describing: error))")
            return
        }
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertEqual(reports(of: .tempBasal).count, 0)
        XCTAssertNotNil(atForce.value?["pendingTempBasal"], "pending as it was forced")

        try restart(from: atForce.value)
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertTrue(uncertain.isEmpty)

        XCTAssertEqual(activate(), true)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(reports(of: .tempBasal).count, 0)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
    }

    /// The same, the set unanswered: not kept unconfirmed - it went to the old patch - the command fails, and the next
    /// patch's session has nothing of it
    func testSessionForcedToEndDuringAnUnansweredSetTempBasalKeepsNothing() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        link.script(CommandType.SET_TEMP_BASAL, .timeout) {
            self.pumpManager.forceDeactivatePatch()
        }
        let error = commandTempBasal(1.2, duration: 30 * Self.minute)
        settle()

        guard case let .deviceState(refusal)? = error, case .noActivePatch? = refusal as? MedtrumConnectError else {
            XCTFail("the set fails, the session ended: \(String(describing: error))")
            return
        }
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertTrue(uncertain.isEmpty)

        XCTAssertEqual(activate(), true)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(reports(of: .tempBasal).count, 0)
    }

    /// The suspend answered as the deactivation is forced: the command fails, the session's own suspend the only one
    func testSessionForcedToEndDuringASuspendFailsIt() {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"])) {
            self.pumpManager.forceDeactivatePatch()
        }
        let error = commandSuspend()
        settle()

        guard case .noActivePatch? = error as? MedtrumConnectError else {
            XCTFail("the suspend fails, the session ended: \(String(describing: error))")
            return
        }
        XCTAssertEqual(reports(of: .suspend).count, 1, "the session's")
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
    }

    /// The SetBolus answered by the old patch as the deactivation is forced: delivered - the patch still on the body -
    /// and nothing of that patch heard any more, so final at once at the full amount. Told as one running as the session
    /// is forced to end is: noted uncertain, the host warned and the user told it was counted in full. No bolus running:
    /// the next patch takes the first bolus after its activation.
    func testSessionForcedToEndDuringASetBolusFinalizesItAtItsFullAmount() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        let answer = UInt64(11).toData(length: 2) + Self.oldPatchId.toData(length: 2) + Date.now.toMedtrumSeconds()
        link.script(CommandType.SET_BOLUS, .fragments(PatchBytes.answer(command: CommandType.SET_BOLUS, body: answer))) {
            self.pumpManager.forceDeactivatePatch()
        }
        XCTAssertNil(commandBolus(1.5), "delivered")
        settle()

        let boluses = reports(of: .bolus)
        XCTAssertEqual(Set(boluses.map(\.syncIdentifier)).count, 1, "one bolus")
        XCTAssertTrue(boluses.allSatisfy { !$0.isMutable }, "final at once")
        XCTAssertEqual(boluses.first?.deliveredUnits ?? 0, 1.5, accuracy: 0.001, "the full amount")
        XCTAssertEqual(boluses.first?.programmedUnits ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(countedAtSessionEndAlerts, 1)
        XCTAssertEqual(uncertain.map(\.cause), [.patchDeactivated])
        XCTAssertEqual(uncertain.first?.phase, .settled(.byEstimate))
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertNil(pumpManager.state.pendingBolus)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
        XCTAssertFalse(pumpManager.state.awaitingRecord.contains { $0.type == .bolus && !$0.isFinalized }, "waiting on no record")

        XCTAssertEqual(activate(), true)
        link.notify(Self.notification(state: .active, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()
        link.script(CommandType.SET_BOLUS, Self.bolusAnswer(record: 2, start: Date.now))
        XCTAssertNil(commandBolus(0.5), "the next patch's first bolus")
        settle()
        XCTAssertNotNil(pumpManager.state.bolusDose)
        XCTAssertEqual(uncertainDeliveryErrors, 1, "no more")
    }

    /// The same, the SetBolus unanswered: it may not have run - counted in full all the same, final at once, and warned of
    /// as uncertain, the user told it was counted in full; no bolus running
    func testSessionForcedToEndDuringAnUnansweredSetBolusCountsItInFullAndWarns() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        link.script(CommandType.SET_BOLUS, .timeout) {
            self.pumpManager.forceDeactivatePatch()
        }
        XCTAssertTrue(isUncertainDelivery(commandBolus(1.5)))
        settle()

        let boluses = reports(of: .bolus)
        XCTAssertEqual(Set(boluses.map(\.syncIdentifier)).count, 1)
        XCTAssertTrue(boluses.allSatisfy { !$0.isMutable })
        XCTAssertEqual(boluses.first?.deliveredUnits ?? 0, 1.5, accuracy: 0.001, "in full")
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(countedAtSessionEndAlerts, 1)
        XCTAssertEqual(uncertain.map(\.phase), [.settled(.byEstimate)])
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
    }

    /// The same, the app killed with the state saved as the deactivation was forced - the bolus pending in it. Taken over
    /// as the next run starts, it is final in full at once: not left running with the old patch's record number, to be
    /// finalized at 0 U against the new patch's counter once overdue, silently - nor holding up the new patch's boluses.
    /// The host is warned, the user told, on the first status after the restart.
    func testSessionForcedToEndDuringAnUnansweredSetBolusThenAKillCountsItInFullAfterTheRestart() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        let atForce = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_BOLUS, .timeout) {
            self.pumpManager.forceDeactivatePatch()
            atForce.value = self.pumpManager.state.rawValue
        }
        XCTAssertTrue(isUncertainDelivery(commandBolus(1.5)))
        settle()
        XCTAssertNotNil(atForce.value?["pendingBolus"], "pending as it was forced")

        try restart(from: atForce.value)
        XCTAssertNil(pumpManager.state.pendingBolus)
        XCTAssertNil(pumpManager.state.bolusDose, "not running")
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)

        // The first status after the restart: the host warned, the user told, the final handed over
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(countedAtSessionEndAlerts, 1)
        XCTAssertEqual(reports(of: .bolus).first?.deliveredUnits ?? 0, 1.5, accuracy: 0.001)

        XCTAssertEqual(activate(), true)
        link.notify(Self.notification(state: .active, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()

        // Past its deadline, the new patch's records read, then past the fallback: nothing more of it
        advanceClock(by: 10 * Self.minute)
        link.deliverFullStatus(
            notification: Self.notification(state: .active, reservoir: 199, storage: (sequence: 1, patchId: Self.newPatchId)),
            duringReconnect: false
        )
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 1, patchId: Self.newPatchId))
        syncRecords()
        advanceClock(by: 16 * Self.minute)
        syncRecords()

        let boluses = reports(of: .bolus)
        XCTAssertEqual(Set(boluses.map(\.syncIdentifier)).count, 1)
        XCTAssertFalse(boluses.isEmpty)
        XCTAssertTrue(boluses.allSatisfy { !$0.isMutable }, "final")
        XCTAssertTrue(boluses.allSatisfy { abs(($0.deliveredUnits ?? 0) - 1.5) < 0.001 }, "in full: \(boluses.map(\.deliveredUnits))")
        XCTAssertEqual(uncertainDeliveryErrors, 1, "warned")
        XCTAssertEqual(countedAtSessionEndAlerts, 1, "told")
        XCTAssertEqual(uncertain.map(\.cause), [.patchDeactivated])
        XCTAssertEqual(uncertain.first?.phase, .settled(.byEstimate))

        link.script(CommandType.SET_BOLUS, Self.bolusAnswer(record: 2, start: Date.now))
        XCTAssertNil(commandBolus(0.5), "the next patch's first bolus")
        settle()
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 2)
    }

    /// A state an earlier build saved: the bolus out as the session was forced to end taken over running, its command
    /// unanswered, with the old patch's record number. Final in full as the state is taken up - warned of, told as the
    /// next session starts, no status before it - so neither the new patch's counter is ever held against its number, nor
    /// its boluses refused until it ends.
    func testBolusLeftRunningByAnEndedSessionIsFinalInFullAsTheNextSessionStarts() throws {
        let state = endedSessionState()
        state.pumpState = .primed
        let bolus = UnfinalizedDose(
            units: 2,
            duration: 120,
            activationType: .manualNoRecommendation,
            insulinType: nil,
            confirmation: .uncertain,
            startDate: Date.now.addingTimeInterval(-2 * Self.minute)
        )
        bolus.noteCommand(sentAt: bolus.startDate, uptime: nil, sequence: 1200)
        state.bolusDose = bolus
        makeManager(state)

        XCTAssertEqual(activate(), true)

        XCTAssertNil(pumpManager.state.bolusDose)
        let finals = reports(of: .bolus).filter { !$0.isMutable }
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals.first?.deliveredUnits ?? 0, 2, accuracy: 0.001, "in full")
        XCTAssertEqual(countedAtSessionEndAlerts, 1)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertFalse(pumpManager.state.awaitingRecord.contains { $0.type == .bolus && !$0.isFinalized })
    }

    /// A bolus of 5 U running as the deactivation is forced, 0.1 U reported so far: the old patch, on the body, delivers
    /// the rest - nothing of it heard from after. Final in full, noted as uncertain, the host warned and the user told.
    func testSessionForcedToEndDuringARunningBolusCountsItInFull() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        let answer = UInt64(11).toData(length: 2) + Self.oldPatchId.toData(length: 2) + Date.now.toMedtrumSeconds()
        link.script(CommandType.SET_BOLUS, .fragments(PatchBytes.answer(command: CommandType.SET_BOLUS, body: answer)))
        XCTAssertNil(commandBolus(5))
        link.notify(Self.notification(state: .active, bolus: (completed: false, delivered: 0.1)))
        settle()
        XCTAssertEqual(pumpManager.state.bolusDose?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        let started = try XCTUnwrap(reports(of: .bolus).first)

        pumpManager.forceDeactivatePatch()
        settle()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 5, accuracy: 0.001, "in full")
        XCTAssertEqual(uncertain.map(\.cause), [.patchDeactivated])
        XCTAssertEqual(uncertain.first?.phase, .settled(.byEstimate))
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(countedAtSessionEndAlerts, 1)
        XCTAssertNil(pumpManager.state.bolusDose)
    }

    /// A state an earlier build saved in the window of a lost activation answer - the new patch activated, no session yet
    /// - with the bolus out as the old session was forced to end still running, unanswered, its record number the old
    /// patch's. Taken up, it is final in full at once: the new patch's records, numbered past it, never decide it never
    /// ran. The host is warned, the user told, on the first status.
    func testBolusLeftRunningWithNoSessionByAnEarlierBuildIsFinalInFullAsTheStateIsTakenUp() throws {
        let state = lostActivationAnswerState()
        state.bolusDose = bolusOfTheEndedSession(units: 2, sentAgo: 2 * Self.minute)
        try restart(from: state.rawValue)

        try assertBolusLeftByTheEndedSessionFinalInFullAsTakenUp(units: 2)
    }

    /// The same, the bolus over and waiting on its record
    func testBolusLeftWaitingOnItsRecordWithNoSessionByAnEarlierBuildIsFinalInFullAsTheStateIsTakenUp() throws {
        let state = lostActivationAnswerState()
        let bolus = bolusOfTheEndedSession(units: 2, sentAgo: 4 * Self.minute)
        bolus.finish(.completionNotSeen, endedAt: nil)
        state.mutateAwaitingRecord { $0.append(bolus) }
        try restart(from: state.rawValue)

        try assertBolusLeftByTheEndedSessionFinalInFullAsTakenUp(units: 2)
    }

    /// Two boluses counted in full as the session's end is taken up - one running, one waiting on its record: each told
    /// of on its own, not one notification for both
    func testBolusesCountedInFullAtTheSessionEndAreToldOfEachOnItsOwn() throws {
        let state = lostActivationAnswerState()
        let waiting = bolusOfTheEndedSession(units: 1, sentAgo: 10 * Self.minute)
        waiting.finish(.completionNotSeen, endedAt: nil)
        state.mutateAwaitingRecord { $0.append(waiting) }
        state.bolusDose = bolusOfTheEndedSession(units: 2, sentAgo: 2 * Self.minute)
        try restart(from: state.rawValue)

        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()

        XCTAssertEqual(countedAtSessionEndAlerts, 2)
        let identifiers = delegate.alerts.map(\.identifier.alertIdentifier).filter {
            $0.hasPrefix("com.nightscout.medtrumkit.bolus-counted-at-session-end")
        }
        XCTAssertEqual(Set(identifiers).count, 2, "one each: \(identifiers)")
        XCTAssertEqual(Set(reports(of: .bolus).filter { !$0.isMutable }.map(\.syncIdentifier)).count, 2)
    }

    /// The bolus left by the ended session final in full as the state is taken up, no host yet - and the deactivation
    /// forced again from the setup screens before any status: the batch it ends with carries the final, the host stores
    /// it, the dose gone. The user is told of it as it goes out - once
    func testBolusFinalInFullAsTakenUpIsToldOfWhenAForcedDeactivationCarriesItsFinalBeforeAnyStatus() throws {
        let state = lostActivationAnswerState()
        state.bolusDose = bolusOfTheEndedSession(units: 2, sentAgo: 2 * Self.minute)
        try restart(from: state.rawValue)
        XCTAssertEqual(countedAtSessionEndAlerts, 0, "no host yet")

        pumpManager.forceDeactivatePatch()
        settle()

        XCTAssertTrue(pumpManager.state.awaitingRecord.filter { $0.type == .bolus }.isEmpty, "the host stored its final")
        let finals = reports(of: .bolus).filter { !$0.isMutable }
        XCTAssertFalse(finals.isEmpty)
        XCTAssertTrue(finals.allSatisfy { abs(($0.deliveredUnits ?? 0) - 2) < 0.001 }, "in full")
        XCTAssertEqual(countedAtSessionEndAlerts, 1, "told")
        XCTAssertEqual(uncertainDeliveryErrors, 1, "warned")

        // Once: not again on the first status
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(countedAtSessionEndAlerts, 1)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
    }

    /// The bolus out as the deactivation was forced, taken over in full after a kill - and the app killed again before
    /// the host was told, the state saved with it final: the next run tells of it all the same, on its first status
    func testBolusTakenOverInFullThenAKillBeforeItIsToldOfIsToldOfAfterTheNextRestart() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        let atForce = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_BOLUS, .timeout) {
            self.pumpManager.forceDeactivatePatch()
            atForce.value = self.pumpManager.state.rawValue
        }
        XCTAssertTrue(isUncertainDelivery(commandBolus(1.5)))
        settle()

        try restart(from: atForce.value)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finalDeliveredUnits ?? 0, 1.5, accuracy: 0.001)
        // Saved as it was taken over, then killed before any status
        let takenOver = pumpManager.state.rawValue
        XCTAssertNil(takenOver["pendingBolus"])

        try restart(from: takenOver)
        XCTAssertEqual(countedAtSessionEndAlerts, 0)
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()

        XCTAssertEqual(countedAtSessionEndAlerts, 1, "told")
        XCTAssertEqual(uncertainDeliveryErrors, 1, "warned")
        let finals = reports(of: .bolus)
        XCTAssertFalse(finals.isEmpty)
        XCTAssertTrue(finals.allSatisfy { !$0.isMutable && abs(($0.deliveredUnits ?? 0) - 1.5) < 0.001 }, "in full")

        // Once
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(countedAtSessionEndAlerts, 1)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
    }

    /// A bolus an earlier build left waiting on its record with no session, answered as the old patch's record 3, and
    /// the new patch's id named by a status already - its records taken up from there: final in full as the session
    /// starts, it is no final of the new patch's waiting on its record. The new patch's own record 3, a bolus of no dose
    /// of ours, is not taken for its record - no miscount told of; it is a bolus the host is missing.
    func testBolusFinalInFullAtTheSessionEndTakesNoRecordOfTheNextPatchAtItsOldNumber() throws {
        let state = lostActivationAnswerState()
        state.pumpState = .active
        state.patchId = Self.newPatchId.toData(length: 4)
        state.sessionStartSequence = 1
        state.currentSequenceNumber = 1
        state.syncedSequenceNumber = 1
        let bolus = bolusOfTheEndedSession(units: 2, sentAgo: 4 * Self.minute, confirmation: .confirmed)
        bolus.noteAnswer(recordSequence: 3)
        bolus.finish(.completionNotSeen, endedAt: nil)
        state.mutateAwaitingRecord { $0.append(bolus) }
        try restart(from: state.rawValue)

        link.notify(Self.notification(state: .active, storage: (sequence: 3, patchId: Self.newPatchId)))
        settle()
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(pumpManager.state.sessionStartSequence, 1, "taken up there")
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty)

        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 2, patchId: Self.newPatchId))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 3,
            patchId: Self.newPatchId,
            start: Self.patchSecond(Date.now.addingTimeInterval(-Self.minute)),
            amount: 0.5,
            delivered: 0.5
        ))
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 3)
        XCTAssertEqual(miscountedAlerts, 0)
        XCTAssertEqual(
            delegate.alerts.filter { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted") }.count,
            1
        )
        XCTAssertEqual(countedAtSessionEndAlerts, 1)
    }

    /// A bolus running as the patch is deactivated, its StopPatch answered: delivery stopped there - final at once at the
    /// last amount the patch reported, not in full
    func testBolusRunningAsThePatchIsDeactivatedKeepsItsLastReportedAmount() throws {
        let started = try runBolusOfOldPatch(units: 5, reported: 0.1)

        XCTAssertEqual(deactivate(), true)

        let final = assertOneFinal(of: started)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.1, accuracy: 0.001, "the last amount reported")
        XCTAssertEqual(uncertain.map(\.cause), [.patchDeactivated])
        XCTAssertEqual(countedAtSessionEndAlerts, 0)
        XCTAssertNil(pumpManager.state.bolusDose)
    }

    /// The same as the base resets under it: delivery stopped with the base
    func testBolusRunningAsTheBaseResetsKeepsItsLastReportedAmount() throws {
        let started = try runBolusOfOldPatch(units: 5, reported: 0.1)

        pumpManager.handleBaseReset(deliveryStoppedAt: Date.now)
        settle()

        let final = assertOneFinal(of: started)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.1, accuracy: 0.001, "the last amount reported")
        XCTAssertEqual(uncertain.map(\.cause), [.patchDeactivated])
        XCTAssertEqual(countedAtSessionEndAlerts, 0)
        XCTAssertEqual(baseResetAlerts, 1)
        XCTAssertNil(pumpManager.state.bolusDose)
    }

    // MARK: The basal schedule with no session

    /// The basal profile changed between patches: kept, not written - no patch to write it to - and the host told it is
    /// set, which saves it only then. The next patch's activation writes it.
    func testBasalScheduleSetWithNoSessionIsKeptForTheNextActivation() throws {
        makeManager(endedSessionState())
        let items = [RepeatingScheduleValue(startTime: 0, value: 1.1), RepeatingScheduleValue(startTime: 12 * Self.hour, value: 0.6)]

        let result: Result<BasalRateSchedule, Error>? = completion(of: "syncBasalRateSchedule") { done in
            self.pumpManager.syncBasalRateSchedule(items: items, completion: done)
        }
        settle()

        XCTAssertNotNil(try result?.get())
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertEqual(pumpManager.state.basalSchedule.toData(), BasalSchedule(entries: items).toData())
        XCTAssertEqual(
            MedtrumPumpState(rawValue: try XCTUnwrap(delegate.savedState)).basalSchedule.toData(),
            BasalSchedule(entries: items).toData(),
            "saved"
        )

        XCTAssertEqual(activate(), true)
        let activation = try XCTUnwrap(link.writes.first { $0.commandType == CommandType.ACTIVATE }?.packet as? ActivatePacket)
        XCTAssertEqual(activation.basalProfile, BasalSchedule(entries: items).toData())
    }

    /// The window of a lost activation answer: the new patch running, its session not started - to start on its next
    /// status, with the profile it was activated with. A profile changed now would be kept and never written to it: refused,
    /// nothing written, the schedule as it was. With no patch on the base it is kept, as before.
    func testBasalScheduleSetWhileAPatchRunsWithNoSessionIsRefused() throws {
        let state = endedSessionState()
        state.pumpState = .active
        makeManager(state)
        let before = pumpManager.state.basalSchedule.toData()
        let items = [RepeatingScheduleValue(startTime: 0, value: 1.1)]

        let refused: Result<BasalRateSchedule, Error>? = completion(of: "syncBasalRateSchedule") { done in
            self.pumpManager.syncBasalRateSchedule(items: items, completion: done)
        }
        settle()
        guard case let .failure(error)? = refused, case .noActivePatch? = error as? MedtrumConnectError else {
            XCTFail("refused: \(String(describing: refused))")
            return
        }
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertEqual(pumpManager.state.basalSchedule.toData(), before)

        makeManager(endedSessionState())
        let kept: Result<BasalRateSchedule, Error>? = completion(of: "syncBasalRateSchedule") { done in
            self.pumpManager.syncBasalRateSchedule(items: items, completion: done)
        }
        settle()
        XCTAssertNotNil(try kept?.get())
        XCTAssertEqual(pumpManager.state.basalSchedule.toData(), BasalSchedule(entries: items).toData())
    }

    // MARK: The session marker

    /// The activation's answer lost, no status since - the patch still shown primed: it may run on the profile it was
    /// activated with, its session starting on the next status. A profile changed now would never be written to it:
    /// refused, nothing written or kept.
    func testBasalScheduleSetWithTheActivationAnswerLostBeforeAnyStatusIsRefused() throws {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)
        XCTAssertEqual(pumpManager.state.pumpState, .primed)
        XCTAssertNotNil(pumpManager.state.activationSentAt)
        let before = pumpManager.state.basalSchedule.toData()
        let written = link.writtenCommands

        let refused: Result<BasalRateSchedule, Error>? = completion(of: "syncBasalRateSchedule") { done in
            self.pumpManager.syncBasalRateSchedule(items: [RepeatingScheduleValue(startTime: 0, value: 1.1)], completion: done)
        }
        settle()

        guard case let .failure(error)? = refused, case .noActivePatch? = error as? MedtrumConnectError else {
            XCTFail("refused: \(String(describing: refused))")
            return
        }
        XCTAssertEqual(link.writtenCommands, written)
        XCTAssertEqual(pumpManager.state.basalSchedule.toData(), before)
        XCTAssertEqual(MedtrumPumpState(rawValue: try XCTUnwrap(delegate.savedState)).basalSchedule.toData(), before)
    }


    /// Not kept by earlier versions: a patch being set up has no session, an activated one has
    func testSessionMarkerOfAStateFromBeforeIsTakenFromThePatchState() {
        let cases: [(PatchState, Bool)] = [(.none, true), (.primed, true), (.active, false), (.suspended, false), (.expired, false)]
        for (pumpState, ended) in cases {
            var raw = MedtrumPumpState(nil).rawValue
            raw["pumpState"] = pumpState.rawValue
            raw["patchSessionEnded"] = nil
            XCTAssertEqual(MedtrumPumpState(rawValue: raw).patchSessionEnded, ended, "\(pumpState)")
        }

        XCTAssertTrue(MedtrumPumpState(nil).patchSessionEnded)

        let state = MedtrumPumpState(nil)
        state.patchSessionEnded = false
        XCTAssertFalse(MedtrumPumpState(rawValue: state.rawValue).patchSessionEnded)
    }

    // MARK: Statuses while no session runs

    /// An id kept from before - the previous patch's, written back by a late status of it - rejects nothing of the new
    /// patch's while no session runs: its reservoir and id are taken
    func testNewPatchsPayloadsAreTakenWithAStaleIdWhileNoSessionRuns() {
        let state = endedSessionState()
        state.patchId = Self.oldPatchId.toData(length: 4)
        makeManager(state)

        link.notify(Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now), patchId: Self.newPatchId),
            reservoir: 199,
            storage: (sequence: 1, patchId: Self.newPatchId)
        ))
        settle()

        XCTAssertEqual(pumpManager.state.reservoir, 199, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.patchId, Self.newPatchId.toData(length: 4))
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 1)
    }

    /// The old patch, stopped, still reports its id until it disconnects: neither the id nor its record number is taken.
    /// Nor is the new patch's setup that follows taken for a reset of the base under an activated patch.
    func testOldPatchsStatusesAfterTheDeactivationAreNotTaken() {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivate(), true)
        let previousPatch = pumpManager.state.previousPatch?.patchId
        let batches = delegate.batches.count

        link.notify(Self.notification(state: .stopped, storage: (sequence: 12, patchId: Self.oldPatchId)))
        settle()

        XCTAssertEqual(pumpManager.state.patchId, Data())
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 0)

        link.notify(Self.notification(state: .priming, primeProgress: 5))
        settle()

        XCTAssertEqual(pumpManager.state.pumpState, .priming)
        XCTAssertEqual(pumpManager.state.primeProgress, 5)
        XCTAssertEqual(link.disconnects, [true], "the deactivation's only")
        XCTAssertEqual(delegate.batches.count, batches)
        XCTAssertEqual(pumpManager.state.previousPatch?.patchId, previousPatch)
    }

    // MARK: The loop while no session runs

    /// 2026-10-30: the old patch reported itself stopped as it was deactivated. The loop syncs nothing with it - every
    /// loop until the new patch's setup scanned 15 s for a base that was not there.
    func testLoopSyncsNothingWithTheOldPatchStoppedAfterItsSessionEnded() {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivate(), true)
        link.notify(Self.notification(state: .stopped, storage: (sequence: 12, patchId: Self.oldPatchId)))
        settle()
        XCTAssertEqual(pumpManager.state.pumpState, .stopped)

        // Past the freshness interval
        let lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
        pumpManager.state.lastSync = lastSync
        let connects = link.connects
        let writes = link.writtenCommands

        XCTAssertEqual(loopSync(), .some(nil))
        settle()

        XCTAssertEqual(link.connects, connects)
        XCTAssertEqual(link.writtenCommands, writes)
        XCTAssertEqual(pumpManager.state.lastSync, lastSync, "not synced")
    }

    /// Nor with a patch that ended otherwise - expired, faulted - its session ended since
    func testLoopSyncsNothingWithAnyTerminatedPatchAfterItsSessionEnded() {
        for pumpState in [PatchState.expired, .patchFault] {
            let state = endedSessionState()
            state.pumpState = pumpState
            let lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
            state.lastSync = lastSync
            makeManager(state)

            XCTAssertEqual(loopSync(), .some(nil), "\(pumpState)")
            settle()

            XCTAssertEqual(link.connects, 0, "\(pumpState)")
            XCTAssertEqual(pumpManager.state.lastSync, lastSync, "not synced: \(pumpState)")
        }
    }

    /// A patch in its session syncs as before. In the simulator the sync never touches the link: `lastSync` tells it ran.
    func testLoopSyncsAPatchInItsSession() {
        let state = activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50)
        let lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
        state.lastSync = lastSync
        makeManager(state)

        XCTAssertNotNil(loopSync())
        settle()

        XCTAssertGreaterThan(pumpManager.state.lastSync, lastSync)
    }

    /// So does a running patch with no session - its activation's answer lost: its statuses are all that follow it
    /// until the retry starts the session
    func testLoopSyncsARunningPatchWithNoSession() {
        let state = endedSessionState()
        state.pumpState = .active
        let lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
        state.lastSync = lastSync
        makeManager(state)

        XCTAssertNotNil(loopSync())
        settle()

        XCTAssertGreaterThan(pumpManager.state.lastSync, lastSync)
    }

    // MARK: The old patch heard from after a forced deactivation

    /// The StopPatch lost every time, the user forces the deactivation - the old patch, running our temp basal, still on
    /// the base and running. It is heard from again: the connect's status (the setup screens connecting), the end of the
    /// temp basal and its schedule, a bolus completion, the heartbeat's full status, the loop's sync. None of it is this
    /// host's: no resume over the session's suspend, no dose of the old patch, dosing still refused. Nor is the new
    /// patch's setup taken for a base reset under the old one's running state. The new patch's activation resumes.
    func testOldPatchRunningAfterAForcedDeactivationReportsNothingUntilTheNewPatchIsActivated() throws {
        let state = activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50)
        let tempBasalPatchStart = Self.patchSecond(Date.now.addingTimeInterval(-10 * Self.minute))
        state.basalDose = runningTempBasal(rate: 1.5, startedAgo: 10 * Self.minute, duration: 30 * Self.minute, pumpStartTime: tempBasalPatchStart)
        state.basalState = .tempBasal
        makeManager(state)

        XCTAssertEqual(deactivateWithTheStopLost(), false)
        XCTAssertEqual(deactivateWithTheStopLost(), false)
        XCTAssertFalse(pumpManager.state.patchSessionEnded)

        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertTrue(pumpManager.state.patchSessionEnded)
        let suspend = try XCTUnwrap(reports(of: .suspend).last)
        XCTAssertEqual(reports(of: .suspend).count, 1)
        XCTAssertEqual(reports(of: .resume).count, 0)
        let batchesAtTheEnd = delegate.batches.count

        // The connect's status: the old patch still running our temp basal
        link.deliverFullStatus(notification: Self.notification(
            state: .active,
            basal: (type: .ABSOLUTE_TEMP, start: tempBasalPatchStart, patchId: Self.oldPatchId),
            reservoir: 49,
            storage: (sequence: 10, patchId: Self.oldPatchId)
        ), duringReconnect: true)
        settle()
        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 10,
            patchId: Self.oldPatchId,
            start: tempBasalPatchStart,
            rate: 1.5,
            delivered: 0.25
        ))
        settle()

        // Its temp basal ends on it, back to its schedule
        let scheduleStart = Self.patchSecond(Date.now)
        link.notify(PatchBytes.basalNotification(
            type: .STANDARD,
            sequence: 11,
            patchId: Self.oldPatchId,
            start: scheduleStart,
            rate: Self.scheduledRate
        ))
        settle()

        // A bolus completion, as a notification shows one
        link.notify(Self.notification(
            state: .active,
            bolus: (completed: true, delivered: 0.5),
            storage: (sequence: 12, patchId: Self.oldPatchId)
        ))
        settle()

        // The heartbeat's full status and its record sync
        let runningStatus = Self.notification(
            state: .active,
            bolus: (completed: true, delivered: 0.5),
            basal: (type: .STANDARD, start: scheduleStart, patchId: Self.oldPatchId),
            reservoir: 48,
            storage: (sequence: 12, patchId: Self.oldPatchId)
        )
        link.deliverFullStatus(notification: runningStatus, duringReconnect: false)
        settle()
        syncRecords(.fullSync)

        // The loop: what it asks of the manager - nothing to sync, no patch taken to run - and the Synchronize answer and
        // record sync its sync would do on a device all the same
        pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
        let connects = link.connects
        XCTAssertEqual(loopSync(), .some(nil))
        settle()
        XCTAssertEqual(link.connects, connects, "nothing to sync with the old patch")
        XCTAssertEqual(pumpManager.state.pumpState, .none, "the old patch's running state not taken")
        link.deliverFullStatus(notification: runningStatus, duringReconnect: false)
        settle()
        syncRecords(.loopSync)

        assertNothingReportedOverTheSessionEnd(after: batchesAtTheEnd, suspend: suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended, "no patch delivers for us until the next one's session starts")
        guard case .deviceState? = commandBolus(0.5) else {
            XCTFail("no bolus goes to the old patch")
            return
        }

        // The base on the new patch: its setup is no base reset under the old patch's running state
        link.notify(Self.notification(state: .filled))
        link.notify(Self.notification(state: .priming, primeProgress: 5))
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        assertNothingReportedOverTheSessionEnd(after: batchesAtTheEnd, suspend: suspend)
        XCTAssertEqual(link.disconnects, [true], "the forced deactivation's only")
        XCTAssertEqual(baseResetAlerts, 0)
        XCTAssertEqual(pumpManager.state.previousPatch?.patchId, Self.oldPatchId.toData(length: 4))
        XCTAssertEqual(pumpManager.state.pumpState, .primed)

        XCTAssertEqual(activate(), true)
        let resumes = reports(of: .resume)
        XCTAssertEqual(resumes.count, 1, "the activation's")
        XCTAssertGreaterThan(LoopOrderingChecker.stored(resumes.first?.startDate ?? .distantPast), LoopOrderingChecker.stored(suspend.startDate))
        XCTAssertEqual(patchReplacements.count, 1)
    }

    /// The old patch's running state in a status naming no id - its state alone - is not taken either: no next patch was
    /// seen since the session's end. The new patch's setup after it is no base reset: no alert, no second end of the session
    func testOldPatchsRunningStateNamingNoIdAfterAForcedDeactivationMakesTheNewPatchsSetupNoBaseReset() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivateWithTheStopLost(), false)
        pumpManager.forceDeactivatePatch()
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).last)
        let batchesAtTheEnd = delegate.batches.count

        link.notify(Data([PatchState.active.rawValue]).hexEncodedString())
        settle()
        XCTAssertEqual(pumpManager.state.pumpState, .none)

        link.notify(Self.notification(state: .filled))
        settle()

        XCTAssertEqual(baseResetAlerts, 0)
        XCTAssertEqual(link.disconnects, [true], "the forced deactivation's only")
        XCTAssertEqual(pumpManager.state.pumpState, .filled)
        assertNothingReportedOverTheSessionEnd(after: batchesAtTheEnd, suspend: suspend)

        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activate(), true)
        XCTAssertEqual(reports(of: .resume).count, 1, "the activation's")
    }

    /// The StopPatch reached the patch, its answer lost; forced, the patch answers stopped for two minutes - the connect's
    /// status, notifications, a heartbeat's full status - its last basal still in them. Nothing is resumed or reported,
    /// the loop syncs nothing with it, and the activation resumes once.
    func testOldPatchStoppedWithItsAnswerLostReportsNothingAfterTheForcedDeactivation() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivateWithTheStopLost(), false)

        pumpManager.forceDeactivatePatch()
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).last)
        let batchesAtTheEnd = delegate.batches.count

        let lastSegmentStart = Self.patchSecond(Date.now.addingTimeInterval(-Self.hour))
        let stoppedStatus = Self.notification(
            state: .stopped,
            bolus: (completed: true, delivered: 0.5),
            basal: (type: .STANDARD, start: lastSegmentStart, patchId: Self.oldPatchId),
            reservoir: 49,
            storage: (sequence: 11, patchId: Self.oldPatchId)
        )
        link.deliverFullStatus(notification: stoppedStatus, duringReconnect: true)
        settle()
        link.notify(Self.notification(state: .stopped, storage: (sequence: 11, patchId: Self.oldPatchId)))
        link.notify(Self.notification(
            state: .stopped,
            basal: (type: .STOP, start: Self.patchSecond(Date.now), patchId: Self.oldPatchId),
            storage: (sequence: 11, patchId: Self.oldPatchId)
        ))
        settle()
        link.deliverFullStatus(notification: stoppedStatus, duringReconnect: false)
        settle()
        syncRecords(.fullSync)

        pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
        let connects = link.connects
        XCTAssertEqual(loopSync(), .some(nil))
        settle()
        XCTAssertEqual(link.connects, connects, "nothing to sync with the stopped patch")

        assertNothingReportedOverTheSessionEnd(after: batchesAtTheEnd, suspend: suspend)

        link.notify(Self.notification(state: .filled))
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        assertNothingReportedOverTheSessionEnd(after: batchesAtTheEnd, suspend: suspend)

        XCTAssertEqual(activate(), true)
        XCTAssertEqual(reports(of: .resume).count, 1, "the activation's")
    }

    /// The same, the patch's stopped status in before the force - the session still running: its halt is the suspend,
    /// the force reports no second one, and the statuses after it nothing
    func testOldPatchStoppedBeforeTheForcedDeactivationReportsOneSuspendAndNothingAfter() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivateWithTheStopLost(), false)
        link.notify(Self.notification(state: .stopped, suspendedAt: Self.patchSecond(Date.now), storage: (sequence: 11, patchId: Self.oldPatchId)))
        settle()
        XCTAssertEqual(reports(of: .suspend).count, 1, "the halt's")

        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertEqual(reports(of: .suspend).count, 1, "no second one")
        let suspend = try XCTUnwrap(reports(of: .suspend).last)
        let batchesAtTheEnd = delegate.batches.count

        let stoppedStatus = Self.notification(
            state: .stopped,
            bolus: (completed: true, delivered: 0.5),
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now.addingTimeInterval(-Self.hour)), patchId: Self.oldPatchId),
            storage: (sequence: 11, patchId: Self.oldPatchId)
        )
        link.deliverFullStatus(notification: stoppedStatus, duringReconnect: true)
        link.notify(stoppedStatus)
        link.deliverFullStatus(notification: stoppedStatus, duringReconnect: false)
        settle()
        syncRecords(.fullSync)

        assertNothingReportedOverTheSessionEnd(after: batchesAtTheEnd, suspend: suspend)

        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activate(), true)
        XCTAssertEqual(reports(of: .resume).count, 1, "the activation's")
    }

    /// Forced out, the old patch heard from running in statuses that name no id - its state alone, its reservoir and
    /// battery - leaves no patch taken to run: what the resume iAPS sends on its own (`unsuspend_if_no_temp`, a
    /// Nightscout announcement), a cleared alert and a temp basal would have gone to the old patch are refused, nothing
    /// written, nothing reported over the session's suspend
    func testOldPatchsRunningStatusesNamingNoIdAfterAForcedDeactivationTakeNoCommands() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivateWithTheStopLost(), false)
        pumpManager.forceDeactivatePatch()
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).last)
        let batchesAtTheEnd = delegate.batches.count

        link.notify(Data([PatchState.active.rawValue]).hexEncodedString())
        link.notify(Self.notification(state: .active, reservoir: 48))
        link.deliverFullStatus(notification: Self.notification(state: .active, reservoir: 48), duringReconnect: true)
        settle()
        XCTAssertEqual(pumpManager.state.pumpState, .none)

        let writes = link.writtenCommands
        let resumeError: Error?? = completion(of: "resumeDelivery") { done in
            self.pumpManager.resumeDelivery(completion: done)
        }
        guard case .noActivePatch? = (resumeError ?? nil) as? MedtrumConnectError else {
            XCTFail("no resume goes to the old patch: \(String(describing: resumeError))")
            return
        }
        let cleared: Bool? = completion(of: "clearAlert") { done in
            self.pumpManager.clearAlert(alertType: .hourly, completion: done)
        }
        XCTAssertEqual(cleared, false)
        XCTAssertNotNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, writes, "nothing written to the old patch")
        assertNothingReportedOverTheSessionEnd(after: batchesAtTheEnd, suspend: suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
    }

    /// No session, a patch taken to run - the new one, its activation's answer lost (sent by an earlier build: no session
    /// starts on its own), its statuses naming its id: still no command goes to it until the retried activation starts its
    /// session - no resume, no cleared alert, no suspend, no dose. Nor does its schedule shown resume over the session's
    /// suspend. The retry does.
    func testNoCommandGoesToARunningPatchUntilItsSessionStarts() throws {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLostByAnEarlierBuild(), true)
        link.notify(Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now), patchId: Self.newPatchId),
            storage: (sequence: 1, patchId: Self.newPatchId)
        ))
        settle()
        XCTAssertEqual(pumpManager.state.pumpState, .active)
        XCTAssertTrue(pumpManager.state.patchSessionEnded)

        let writes = link.writtenCommands
        let resumeError: Error?? = completion(of: "resumeDelivery") { done in
            self.pumpManager.resumeDelivery(completion: done)
        }
        guard case .noActivePatch? = (resumeError ?? nil) as? MedtrumConnectError else {
            XCTFail("no resume before the session: \(String(describing: resumeError))")
            return
        }
        let cleared: Bool? = completion(of: "clearAlert") { done in
            self.pumpManager.clearAlert(alertType: .daily, completion: done)
        }
        XCTAssertEqual(cleared, false)
        let suspendError: Error?? = completion(of: "suspendDelivery") { done in
            self.pumpManager.suspendDelivery(completion: done)
        }
        XCTAssertNotNil(suspendError ?? nil)
        XCTAssertNotNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        XCTAssertNotNil(commandBolus(0.5))
        settle()

        XCTAssertEqual(link.writtenCommands, writes, "nothing written before the session")
        XCTAssertEqual(reports(of: .resume).count, 0)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)

        XCTAssertEqual(activate(), true)
        XCTAssertEqual(reports(of: .resume).count, 1, "the activation's")
        XCTAssertEqual(pumpManager.state.basalState, .active)
    }

    /// The new patch's activation answer lost, its statuses naming its id - so the previous patch's id is the one before.
    /// It is deactivated, its StopPatch lost, then forced out: it is the previous patch now, its running statuses after
    /// that not taken - no running state, no id, no resume over the suspend - and the next patch's setup is no base reset.
    func testANewPatchForcedOutBeforeItsSessionStartedIsThePreviousPatch() throws {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLostByAnEarlierBuild(), true)
        // No record written yet: none for the deactivation to read
        link.notify(Self.notification(state: .active, reservoir: 199, storage: (sequence: 0, patchId: Self.newPatchId)))
        settle()
        XCTAssertEqual(pumpManager.state.patchId, Self.newPatchId.toData(length: 4))

        let suspendStart = pumpManager.state.basalDose.startDate
        XCTAssertEqual(deactivateWithTheStopLost(), false)
        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertEqual(pumpManager.state.previousPatch?.patchId, Self.newPatchId.toData(length: 4))

        let runningStatus = Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now), patchId: Self.newPatchId),
            reservoir: 198,
            storage: (sequence: 2, patchId: Self.newPatchId)
        )
        link.deliverFullStatus(notification: runningStatus, duringReconnect: true)
        link.notify(runningStatus)
        settle()

        XCTAssertEqual(pumpManager.state.pumpState, .none)
        XCTAssertEqual(pumpManager.state.patchId, Data())
        // The session's suspend, from before, stands: nothing reported since - the force's end neither
        XCTAssertEqual(delegate.batches.flatMap(\.events).compactMap(\.dose).map(\.type), [])
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalDose.startDate, suspendStart)

        link.notify(Self.notification(state: .filled))
        settle()
        XCTAssertEqual(baseResetAlerts, 0)
        XCTAssertEqual(pumpManager.state.pumpState, .filled)
    }

    /// A retried activation starts its session with no id - none named yet - and the patch is forced out before a status
    /// names it: the previous patch's id is not known. Its running statuses after that, naming its id, are not taken
    /// for the next patch's - none of a next patch was seen since - and resume nothing over the session's suspend.
    func testARetriedActivationsPatchForcedOutBeforeAStatusNamedItReportsNothingAfter() throws {
        makeManager(endedSessionState())
        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        XCTAssertEqual(activateWithTheAnswerLost(), true)
        link.notify(Data([PatchState.active.rawValue]).hexEncodedString())
        settle()
        XCTAssertEqual(pumpManager.state.pumpState, .active, "the new patch's: its setup was seen")
        XCTAssertEqual(activate(), true)
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(pumpManager.state.patchId, Data())
        XCTAssertEqual(reports(of: .resume).count, 1, "the retry's")

        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertEqual(pumpManager.state.previousPatch?.patchId, Data())
        let suspend = try XCTUnwrap(reports(of: .suspend).last)
        let batches = delegate.batches.count

        let runningStatus = Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now), patchId: Self.newPatchId),
            reservoir: 198,
            storage: (sequence: 2, patchId: Self.newPatchId)
        )
        link.deliverFullStatus(notification: runningStatus, duringReconnect: true)
        link.notify(runningStatus)
        settle()

        XCTAssertEqual(pumpManager.state.pumpState, .none)
        XCTAssertEqual(pumpManager.state.patchId, Data())
        XCTAssertEqual(delegate.batches.dropFirst(batches).flatMap(\.events).compactMap(\.dose).map(\.type), [])
        let suspendsAndResumes = delegate.batches.flatMap(\.events).compactMap(\.dose).filter { $0.type == .suspend || $0.type == .resume }
        XCTAssertEqual(suspendsAndResumes.last?.syncIdentifier, suspend.syncIdentifier)
        XCTAssertEqual(reports(of: .resume).count, 1)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
    }

    /// The race of a forced deactivation with a command: the session ends while a resume is out - the force from the
    /// main queue, as the answer comes in. The command reports nothing after it: no resume over the session's suspend.
    func testASessionForcedToEndWhileAResumeIsOutReportsNoResumeOverItsSuspend() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        link.notify(PatchBytes.suspendNotification(suspendedAt: Self.patchSecond(Date.now.addingTimeInterval(-10 * Self.minute))))
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)

        link.script(CommandType.RESUME_PUMP, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP,
            type: .STANDARD,
            rate: Self.scheduledRate,
            sequence: 10,
            patchId: Self.oldPatchId,
            start: Self.patchSecond(Date.now)
        ))) {
            self.pumpManager.forceDeactivatePatch()
        }
        let resumed: Error?? = completion(of: "resumeDelivery") { done in
            self.pumpManager.resumeDelivery(completion: done)
        }
        XCTAssertNotNil(resumed, "completed")
        guard case .noActivePatch? = (resumed ?? nil) as? MedtrumConnectError else {
            XCTFail("the resume fails, the session ended: \(String(describing: resumed))")
            return
        }
        settle()

        XCTAssertTrue(pumpManager.state.patchSessionEnded)
        let suspendsAndResumes = delegate.batches.flatMap(\.events).compactMap(\.dose).filter { $0.type == .suspend || $0.type == .resume }
        XCTAssertEqual(suspendsAndResumes.last?.type, .suspend, "the session's suspend the latest")
        XCTAssertEqual(reports(of: .resume).count, 1, "the force's own, of the suspend before it")
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
    }

    /// A status the gate takes while no session runs - the new patch's, its activation's answer lost, naming its id -
    /// showing its schedule resumes nothing over the session's suspend: only the activation does. The retry resumes once,
    /// where the patch says it activated: what it delivered since counted.
    func testAStatusTakenWhileNoSessionRunsResumesNothingTheRetryResumesAtThePatchsStart() throws {
        makeManager(endedSessionState())
        XCTAssertEqual(activateWithTheAnswerLostByAnEarlierBuild(), true)

        let activatedAt = Self.patchSecond(Date.now.addingTimeInterval(-Self.minute))
        link.notify(Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: activatedAt, patchId: Self.newPatchId),
            reservoir: 199,
            activatedAt: activatedAt,
            storage: (sequence: 1, patchId: Self.newPatchId)
        ))
        settle()
        XCTAssertEqual(pumpManager.state.reservoir, 199, accuracy: 0.001)
        XCTAssertEqual(reports(of: .resume).count, 0)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)

        XCTAssertEqual(activate(), true)
        let resumes = reports(of: .resume)
        XCTAssertEqual(resumes.count, 1, "the activation's")
        XCTAssertEqual(resumes.first?.startDate.timeIntervalSince(activatedAt) ?? -1, 0, accuracy: 1)
        assertEachSuspendResumedOnItsOwn(storedBefore: try XCTUnwrap(hostSuspendedSince))
    }

    /// The heartbeat asks for a full status when the last one is stale. One of the old patch, forced out and still on the
    /// base, is not taken - it moves no `lastSync` - but it is no less fresh: the next heartbeat asks for none.
    func testHeartbeatAsksForNoFullStatusRightAfterOneOfThePreviousPatch() {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivateWithTheStopLost(), false)
        pumpManager.forceDeactivatePatch()
        settle()

        let lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
        pumpManager.state.lastSync = lastSync
        XCTAssertEqual(pumpManager.heartbeatSync(), .full)

        link.deliverFullStatus(notification: Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now), patchId: Self.oldPatchId),
            storage: (sequence: 11, patchId: Self.oldPatchId)
        ), duringReconnect: false)
        settle()

        XCTAssertNil(pumpManager.heartbeatSync())
        XCTAssertEqual(pumpManager.state.lastSync, lastSync, "not taken")
    }

    // MARK: The priming screen

    /// The state the old patch stopped in, kept until the new patch's first status, is not the new patch failing. Once it
    /// is seen being set up, a terminated state is - before priming and while priming.
    func testPrimingScreenTakesATerminatedStateForAFailureOnlyOnceThePatchWasSeenBeingSetUp() {
        let state = endedSessionState()
        state.pumpState = .stopped
        // The deactivation's forced disconnect
        state.isConnected = false
        makeManager(state)
        let viewModel = PatchPrimingViewModel(pumpManager, {}, {})

        viewModel.statusDidUpdate()
        XCTAssertEqual(viewModel.primingError, "", "the old patch's state")

        pumpManager.state.pumpState = .filled
        viewModel.statusDidUpdate()
        XCTAssertEqual(viewModel.primingError, "")

        pumpManager.state.pumpState = .patchFault
        viewModel.statusDidUpdate()
        XCTAssertEqual(viewModel.primingError, MedtrumPrimePatchError.patchNotPrimeable(state: .patchFault).description)

        let priming = PatchPrimingViewModel(pumpManager, {}, {})
        pumpManager.state.pumpState = .priming
        priming.statusDidUpdate()
        priming.isPriming = true
        pumpManager.state.pumpState = .occlusion
        priming.statusDidUpdate()
        XCTAssertFalse(priming.isPriming)
        XCTAssertEqual(priming.primingError, MedtrumPrimePatchError.patchNotPrimeable(state: .occlusion).description)
    }

    /// Opened on a patch being primed - after a restart, say - that faulted since: its first update shows the failure
    func testPrimingScreenOpenedOnAPrimingPatchShowsItsFaultOnTheFirstUpdate() {
        let state = endedSessionState()
        state.pumpState = .priming
        state.isConnected = false
        makeManager(state)
        let viewModel = PatchPrimingViewModel(pumpManager, {}, {})

        pumpManager.state.pumpState = .patchFault
        viewModel.statusDidUpdate()

        XCTAssertEqual(viewModel.primingError, MedtrumPrimePatchError.patchNotPrimeable(state: .patchFault).description)
    }

    /// Connected, a terminated state is current - the base still on the old, stopped patch: it can't be primed
    func testPrimingScreenShowsAStoppedPatchReportedOverTheLink() {
        let state = endedSessionState()
        state.pumpState = .stopped
        state.isConnected = true
        makeManager(state)
        let viewModel = PatchPrimingViewModel(pumpManager, {}, {})

        viewModel.statusDidUpdate()

        XCTAssertEqual(viewModel.primingError, MedtrumPrimePatchError.patchNotPrimeable(state: .stopped).description)
    }

    // MARK: Driving

    /// No session, the new patch activated - its answer lost, the marker saved - and no status of it since
    private func lostActivationAnswerState() -> MedtrumPumpState {
        let state = endedSessionState()
        state.pumpState = .primed
        state.activationSentAt = Date.now.addingTimeInterval(-Self.minute)
        return state
    }

    /// A bolus of `units` sent `sentAgo` to the old patch by an earlier build, its command unanswered: the record
    /// number known then the old patch's, 5, no patch noted with it
    private func bolusOfTheEndedSession(
        units: Double,
        sentAgo: TimeInterval,
        confirmation: UnfinalizedDose.Confirmation = .uncertain
    ) -> UnfinalizedDose {
        let bolus = UnfinalizedDose(
            units: units,
            duration: units * Self.minute,
            activationType: .manualNoRecommendation,
            insulinType: nil,
            confirmation: confirmation,
            startDate: Date.now.addingTimeInterval(-sentAgo)
        )
        bolus.noteCommand(sentAt: bolus.startDate, uptime: nil, sequence: 5)
        return bolus
    }

    /// The one bolus of the ended session in the state just taken up is final in full - nothing running, nothing waiting
    /// on its record - the host not told yet. Told, and the user too, on the first status - the new patch's, starting its
    /// session, its records numbered past the bolus's - and nothing more of it once they are read and the fallback is
    /// past.
    private func assertBolusLeftByTheEndedSessionFinalInFullAsTakenUp(
        units: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNil(pumpManager.state.bolusDose, "not running", file: file, line: line)
        let left = pumpManager.state.awaitingRecord.filter { $0.type == .bolus }
        XCTAssertEqual(left.count, 1, file: file, line: line)
        XCTAssertEqual(left.first?.snapshot.finalDeliveredUnits ?? 0, units, accuracy: 0.001, "final in full", file: file, line: line)
        XCTAssertEqual(countedAtSessionEndAlerts, 0, "no host yet", file: file, line: line)

        let activatedAt = Self.patchSecond(Date.now.addingTimeInterval(-Self.minute))
        link.notify(Self.notification(state: .active, activatedAt: activatedAt, storage: (sequence: 6, patchId: Self.newPatchId)))
        settle()
        XCTAssertFalse(pumpManager.state.patchSessionEnded, "started on its own", file: file, line: line)
        XCTAssertEqual(countedAtSessionEndAlerts, 1, "told", file: file, line: line)
        XCTAssertEqual(uncertainDeliveryErrors, 1, "warned", file: file, line: line)
        XCTAssertEqual(uncertain.map(\.cause), [.patchDeactivated], file: file, line: line)
        XCTAssertEqual(uncertain.first?.phase, .settled(.byEstimate), file: file, line: line)
        let final = try XCTUnwrap(reports(of: .bolus).first, file: file, line: line)
        XCTAssertEqual(assertOneFinal(of: final, file: file, line: line)?.deliveredUnits ?? 0, units, accuracy: 0.001, file: file, line: line)

        // The new patch's records, past the number known as the bolus went out, read - then past the fallback
        advanceClock(by: 10 * Self.minute)
        for sequence in 1 ... 6 {
            link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: sequence, patchId: Self.newPatchId))
        }
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 6, file: file, line: line)
        advanceClock(by: 16 * Self.minute)
        syncRecords()

        XCTAssertEqual(assertOneFinal(of: final, file: file, line: line)?.deliveredUnits ?? 0, units, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(countedAtSessionEndAlerts, 1, file: file, line: line)
        XCTAssertEqual(uncertainDeliveryErrors, 1, file: file, line: line)
        XCTAssertNil(pumpManager.state.bolusDose, file: file, line: line)
    }

    /// The old patch running a bolus of `units` of ours, answered as record 11, `reported` delivered so far. Returns it as
    /// the host was first told of it.
    private func runBolusOfOldPatch(units: Double, reported: Double) throws -> DoseEntry {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        let answer = UInt64(11).toData(length: 2) + Self.oldPatchId.toData(length: 2) + Date.now.toMedtrumSeconds()
        link.script(CommandType.SET_BOLUS, .fragments(PatchBytes.answer(command: CommandType.SET_BOLUS, body: answer)))
        XCTAssertNil(commandBolus(units))
        link.notify(Self.notification(state: .active, bolus: (completed: false, delivered: reported)))
        settle()
        XCTAssertEqual(pumpManager.state.bolusDose?.deliveredUnits ?? 0, reported, accuracy: 0.001)
        return try XCTUnwrap(reports(of: .bolus).first)
    }

    /// What the loop's `ensureCurrentPumpData` hands back - nil if it never completes
    private func loopSync() -> Date?? {
        completion(of: "ensureCurrentPumpData") { done in
            self.pumpManager.ensureCurrentPumpData(completion: done)
        }
    }

    /// The old patch suspended since `since` - the host told so in a run before - its last status at `lastHeardAt`,
    /// showing `state`
    private func suspendedPatchState(since: Date, lastHeardAt: Date, showing state: PatchState) -> MedtrumPumpState {
        let patch = activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50)
        patch.basalDose = UnfinalizedDose(suspendStartTime: since)
        patch.basalState = .suspended
        patch.pumpState = state
        patch.lastSync = lastHeardAt
        if !state.isDelivering {
            patch.lastShownNotDeliveringAt = lastHeardAt
        }
        hostSuspendedSince = since
        return patch
    }

    /// As oref0 pairs them, the suspend from `storedBefore` and those reported since: each with a resume of its own, none
    /// left open - see `LoopOrderingChecker`, rule 7
    private func assertEachSuspendResumedOnItsOwn(storedBefore: Date, file: StaticString = #filePath, line: UInt = #line) {
        let suspends = ([storedBefore] + reports(of: .suspend).map(\.startDate)).map(LoopOrderingChecker.stored)
        let resumes = reports(of: .resume).map(\.startDate).map(LoopOrderingChecker.stored)
        let pairing = LoopOrderingChecker.oref0Pairing(suspends: suspends, resumes: resumes)
        XCTAssertNil(pairing.open, file: file, line: line)
        XCTAssertEqual(pairing.paired.count, suspends.count, file: file, line: line)
        XCTAssertEqual(Set(pairing.paired.map(\.resume)).count, suspends.count, "no two suspends paired with one resume", file: file, line: line)
        XCTAssertEqual(pairing.unpaired, [], file: file, line: line)
    }

    /// What the deactivation leaves: no session, the old patch's suspend reported 3 min ago
    private func endedSessionState() -> MedtrumPumpState {
        let state = activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 0, reservoir: 0)
        let deactivatedAt = Date.now.addingTimeInterval(-3 * Self.minute)
        state.previousPatch = PreviousPatch(
            patchId: Self.oldPatchId.toData(length: 4),
            lastStateRaw: PatchState.active.rawValue,
            lastSyncAt: deactivatedAt,
            battery: 0,
            activatedAt: Date.now.addingTimeInterval(-72 * Self.hour),
            deactivatedAt: deactivatedAt,
            initialReservoirLevel: 200,
            reservoirLevel: 50
        )
        state.patchActivatedAt = Date.now.addingTimeInterval(-72 * Self.hour)
        state.patchId = Data()
        state.pumpState = .none
        state.patchSessionEnded = true
        state.basalDose = UnfinalizedDose(suspendStartTime: deactivatedAt)
        state.basalState = .suspended
        state.initialReservoir = nil
        hostSuspendedSince = deactivatedAt
        return state
    }

    private func deactivate() -> Bool? {
        link.script(
            CommandType.STOP_PATCH,
            PatchBytes.answer(command: CommandType.STOP_PATCH, body: UInt64(10).toData(length: 2) + Self.oldPatchId.toData(length: 2))
        )
        let result: MedtrumDeactivatePatchResult? = completion(of: "deactivatePatch") { done in
            self.pumpManager.deactivatePatch(done)
        }
        settle()

        guard let result else {
            return nil
        }
        if case .success = result {
            return true
        }
        return false
    }

    /// A deactivation whose StopPatch goes unanswered: it fails, the session still running
    private func deactivateWithTheStopLost() -> Bool? {
        link.script(CommandType.STOP_PATCH, .timeout)
        let result: MedtrumDeactivatePatchResult? = completion(of: "deactivatePatch") { done in
            self.pumpManager.deactivatePatch(done)
        }
        settle()

        guard let result else {
            return nil
        }
        if case .success = result {
            return true
        }
        return false
    }

    /// Since the session's end - from batch `after` on - the host was handed nothing but the session's `suspend` again: no
    /// resume, no dose of the old patch. The suspend stays the latest suspend or resume, and the dose running.
    private func assertNothingReportedOverTheSessionEnd(
        after batches: Int,
        suspend: DoseEntry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let since = delegate.batches.dropFirst(batches).flatMap(\.events).compactMap(\.dose)
        XCTAssertEqual(
            since.filter { $0.syncIdentifier != suspend.syncIdentifier }.map(\.type), [],
            "nothing reported over the session's suspend",
            file: file,
            line: line
        )
        let suspendsAndResumes = delegate.batches.flatMap(\.events).compactMap(\.dose).filter { $0.type == .suspend || $0.type == .resume }
        XCTAssertEqual(suspendsAndResumes.last?.syncIdentifier, suspend.syncIdentifier, "the latest", file: file, line: line)
        XCTAssertEqual(reports(of: .resume).count, 0, file: file, line: line)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend, file: file, line: line)
        XCTAssertEqual(pumpManager.state.patchId, Data(), file: file, line: line)
    }

    /// Activates the patch: with its answer, unless it is running already - then nothing is sent
    private func activate() -> Bool? {
        if !pumpManager.state.pumpState.isRunning {
            scriptTimeSync()
            link.script(CommandType.ACTIVATE, Self.activateAnswer(start: Date.now))
        }
        return runActivation()
    }

    /// The patch activates, its answer lost
    private func activateWithTheAnswerLost() -> Bool? {
        scriptTimeSync()
        link.script(CommandType.ACTIVATE, .timeout)
        guard let result = runActivation() else {
            return nil
        }
        return !result
    }

    /// The same, sent by a build that kept no marker of it (`MedtrumPumpState.activationSentAt`), the app updated before
    /// the statuses after it: a running patch's status starts no session on its own - only a retried activation does
    private func activateWithTheAnswerLostByAnEarlierBuild() -> Bool? {
        let lost = activateWithTheAnswerLost()
        XCTAssertNotNil(pumpManager.state.activationSentAt)
        pumpManager.state.activationSentAt = nil
        return lost
    }

    private func runActivation() -> Bool? {
        let result: MedtrumActivatePatchResult? = completion(of: "activatePatch") { done in
            self.pumpManager.activatePatch(done)
        }
        settle()

        guard let result else {
            return nil
        }
        if case .success = result {
            return true
        }
        return false
    }

    /// What the activation sends before it: the time, the time zone, then the patch time read back
    private func scriptTimeSync() {
        link.script(CommandType.SET_TIME, PatchBytes.answer(command: CommandType.SET_TIME, body: Data()))
        link.script(CommandType.SET_TIME_ZONE, PatchBytes.answer(command: CommandType.SET_TIME_ZONE, body: Data()))
        link.script(CommandType.GET_TIME, PatchBytes.answer(command: CommandType.GET_TIME, body: Date.now.toMedtrumSeconds()))
    }

    private var patchReplacements: [NewPumpEvent] {
        delegate.batches.flatMap(\.events).filter { String(data: $0.raw, encoding: .utf8)?.hasPrefix("PATCH_REPLACE") == true }
    }

    private var countedAtSessionEndAlerts: Int {
        delegate.alerts.filter { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-counted-at-session-end") }.count
    }

    private var miscountedAlerts: Int {
        delegate.alerts.filter { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted") }.count
    }

    private var baseResetAlerts: Int {
        delegate.alerts.filter { $0.identifier.alertIdentifier == "com.nightscout.medtrumkit.base-reset" }.count
    }

    private var expiryReminderDelays: [TimeInterval] {
        delegate.alerts.filter { $0.identifier.alertIdentifier == "com.nightscout.medtrumkit.patch-expired" }.compactMap { alert in
            if case let .delayed(interval) = alert.trigger {
                return interval
            }
            return nil
        }
    }

    /// The new patch's ACTIVATE answer: its id, and its schedule started at `start`
    private static func activateAnswer(start: Date) -> [String] {
        var body = newPatchId.toData(length: 4) + start.toMedtrumSeconds()
        body += Data([BasalType.STANDARD.rawValue]) + UInt64((scheduledRate / 0.05).rounded()).toData(length: 2)
        body += UInt64(0).toData(length: 2) + newPatchId.toData(length: 2) + start.toMedtrumSeconds()
        return PatchBytes.answer(command: CommandType.ACTIVATE, body: body)
    }

    /// The new patch's SET_BOLUS answer: record `record`, started at `start`
    private static func bolusAnswer(record: Int, start: Date) -> [String] {
        let body = UInt64(record).toData(length: 2) + newPatchId.toData(length: 2) + start.toMedtrumSeconds()
        return PatchBytes.answer(command: CommandType.SET_BOLUS, body: body)
    }

    /// A notification in patch state `state` with the fields given, laid out as `NotificationPacket` reads them
    private static func notification(
        state: PatchState,
        suspendedAt: Date? = nil,
        bolus: (completed: Bool, delivered: Double)? = nil,
        basal: (type: BasalType, start: Date, patchId: UInt64)? = nil,
        primeProgress: UInt8? = nil,
        reservoir: Double? = nil,
        activatedAt: Date? = nil,
        storage: (sequence: Int, patchId: UInt64)? = nil
    ) -> String {
        var mask: UInt16 = 0
        var fields = Data()
        if let suspendedAt {
            mask |= MASK_SUSPEND
            fields += suspendedAt.toMedtrumSeconds()
        }
        if let bolus {
            mask |= MASK_NORMAL_BOLUS
            fields += Data([bolus.completed ? 0x81 : 0x01]) + UInt64((bolus.delivered / 0.05).rounded()).toData(length: 2)
        }
        if let basal {
            mask |= MASK_BASAL
            fields += Data([basal.type.rawValue]) + UInt64(0).toData(length: 2) + basal.patchId.toData(length: 2)
            fields += basal.start.toMedtrumSeconds() + UInt64((scheduledRate / 0.05).rounded()).toData(length: 3)
        }
        if let primeProgress {
            mask |= MASK_SETUP
            fields += Data([primeProgress])
        }
        if let reservoir {
            mask |= MASK_RESERVOIR
            fields += UInt64((reservoir / 0.05).rounded()).toData(length: 2)
        }
        if let activatedAt {
            mask |= MASK_START_TIME
            fields += activatedAt.toMedtrumSeconds()
        }
        if let storage {
            mask |= MASK_STORAGE
            fields += UInt64(storage.sequence).toData(length: 2) + storage.patchId.toData(length: 2)
        }
        return (Data([state.rawValue]) + UInt64(mask).toData(length: 2) + fields).hexEncodedString()
    }

    /// `date` as the patch clock has it, in whole seconds
    private static func patchSecond(_ date: Date) -> Date {
        Date.fromMedtrumSeconds(date.toMedtrumSeconds().toUInt64())
    }
}

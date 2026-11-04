import LoopKit
@testable import MedtrumKit
import XCTest

/// A patch change driven through the manager: the old patch's session ending, the new one's starting - its activation
/// answered, lost and retried - and the statuses either patch sends meanwhile. No log has these bytes: built with
/// `PatchBytes` and `notification`.
final class ManagerPatchChangeScenarioTests: MedtrumManagerTestCase {
    static let oldPatchId: UInt64 = 270
    static let newPatchId: UInt64 = 271
    static let scheduledRate = 0.8

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
        XCTAssertEqual(patchReplacements.first?.date.timeIntervalSince(activatedAt) ?? -1, 0, accuracy: 1, "not the retry's")
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

    /// The session started minutes after the patch activated, its answer lost: the patch replacement is dated where the
    /// patch says it activated, not as the session started - a host would split the patch in two there - ahead of the resume
    func testLostActivationAnswerDatesThePatchReplacementAtTheActivation() throws {
        makeManager(endedSessionState())
        XCTAssertEqual(activateWithTheAnswerLost(), true)

        let activatedAt = Self.patchSecond(Date.now.addingTimeInterval(-2 * Self.minute))
        let startedAt = Date.now
        link.notify(Self.notification(state: .active, activatedAt: activatedAt, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()

        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(patchReplacements.count, 1)
        let replacedAt = try XCTUnwrap(patchReplacements.first?.date)
        XCTAssertEqual(replacedAt.timeIntervalSince(activatedAt), 0, accuracy: 1, "the patch's start")
        XCTAssertLessThan(replacedAt, startedAt.addingTimeInterval(-Self.minute), "not the session's")
        XCTAssertLessThanOrEqual(replacedAt, try XCTUnwrap(reports(of: .resume).first?.startDate))
    }

    /// Its start after the deactivation on the patch clock, before it on ours - the patch clock ahead: the replacement is
    /// dated at the previous session's end, never before it
    func testLostActivationAnswerDatesThePatchReplacementNoEarlierThanThePreviousSessionsEnd() throws {
        makeManager(endedSessionState())
        let deactivatedAt = try XCTUnwrap(pumpManager.state.previousPatch?.deactivatedAt)
        XCTAssertEqual(activateWithTheAnswerLost(), true)
        pumpManager.state.pumpTime = pumpManager.state.pumpTimeSyncedAt.addingTimeInterval(2 * Self.minute)

        let activatedAt = Self.patchSecond(Date.now.addingTimeInterval(-2 * Self.minute))
        XCTAssertGreaterThan(activatedAt, deactivatedAt)
        link.notify(Self.notification(state: .active, activatedAt: activatedAt, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()

        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(patchReplacements.count, 1)
        let replacedAt = try XCTUnwrap(patchReplacements.first?.date)
        XCTAssertEqual(replacedAt, deactivatedAt)
        XCTAssertLessThanOrEqual(replacedAt, try XCTUnwrap(reports(of: .resume).first?.startDate))
    }

    /// Its answer come: the patch replacement is dated as the session started - the patch's start the same moment
    func testAnsweredActivationDatesThePatchReplacementAtTheSessionStart() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(deactivate(), true)

        let before = Date.now
        XCTAssertEqual(activate(), true)
        let after = Date.now

        XCTAssertEqual(patchReplacements.count, 1)
        let replacedAt = try XCTUnwrap(patchReplacements.first?.date)
        XCTAssertGreaterThanOrEqual(replacedAt, before)
        XCTAssertLessThanOrEqual(replacedAt, after)
        XCTAssertGreaterThanOrEqual(replacedAt, try XCTUnwrap(pumpManager.state.previousPatch?.deactivatedAt))
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
}

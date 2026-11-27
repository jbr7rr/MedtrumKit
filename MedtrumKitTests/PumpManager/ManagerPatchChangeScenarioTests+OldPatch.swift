@testable import MedtrumKit
import XCTest

extension ManagerPatchChangeScenarioTests {
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
}

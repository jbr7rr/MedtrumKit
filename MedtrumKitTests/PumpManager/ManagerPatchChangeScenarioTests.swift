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
    /// of reach, the suspend may have ended on its own since: then it does.
    func testDeactivatingASuspendedPatchReportsASuspendOnlyWhenForced() throws {
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        link.notify(PatchBytes.suspendNotification(suspendedAt: Self.patchSecond(Date.now.addingTimeInterval(-10 * Self.minute))))
        settle()
        XCTAssertEqual(reports(of: .suspend).count, 1)
        let suspended = pumpManager.state.rawValue

        XCTAssertEqual(deactivate(), true)
        XCTAssertEqual(reports(of: .suspend).count, 1)

        try restart(from: suspended)
        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertEqual(reports(of: .suspend).count, 1, "the forced one's own")
        XCTAssertGreaterThan(pumpManager.state.basalDose.startDate, Date.now.addingTimeInterval(-Self.minute))
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

    /// The resume comes after the suspend it ends, never at the same time - a host pairs a resume with an earlier suspend
    /// only - and the patch replacement is dated when the session started
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
        XCTAssertGreaterThan(resumedAt, suspendedAt)
        XCTAssertEqual(patchReplacements.map(\.date), [resumedAt])
        XCTAssertFalse(pumpManager.state.patchSessionEnded)
        XCTAssertEqual(pumpManager.state.patchId, Self.newPatchId.toData(length: 4))
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

    /// The patch activated and is delivering, its answer lost: the retry starts the session, resuming at the retry, the
    /// expiry from when the patch says it activated. A second retry starts none.
    func testRetriedActivationStartsTheSessionOfADeliveringPatch() throws {
        makeManager(endedSessionState())
        XCTAssertEqual(activateWithTheAnswerLost(), true)

        let activatedAt = Self.patchSecond(Date.now.addingTimeInterval(-Self.minute))
        link.notify(Self.notification(state: .active, activatedAt: activatedAt, storage: (sequence: 1, patchId: Self.newPatchId)))
        settle()
        XCTAssertTrue(pumpManager.state.patchSessionEnded)

        let retriedAt = Date.now
        XCTAssertEqual(activate(), true)

        let resumes = reports(of: .resume)
        XCTAssertEqual(resumes.count, 1)
        XCTAssertGreaterThanOrEqual(resumes.first?.startDate ?? .distantPast, retriedAt)
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
        XCTAssertEqual(activateWithTheAnswerLost(), true)

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

    // MARK: The session marker

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

    // MARK: Driving

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

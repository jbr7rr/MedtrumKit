import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerPatchChangeScenarioTests {
    // MARK: Driving

    /// No session, the new patch activated - its answer lost, the marker saved - and no status of it since
    func lostActivationAnswerState() -> MedtrumPumpState {
        let state = endedSessionState()
        state.pumpState = .primed
        state.activationSentAt = Date.now.addingTimeInterval(-Self.minute)
        return state
    }

    /// A bolus of `units` sent `sentAgo` to the old patch by an earlier build, its command unanswered: the record
    /// number known then the old patch's, 5, no patch noted with it
    func bolusOfTheEndedSession(
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
    func assertBolusLeftByTheEndedSessionFinalInFullAsTakenUp(
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
    func runBolusOfOldPatch(units: Double, reported: Double) throws -> DoseEntry {
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
    func loopSync() -> Date?? {
        completion(of: "ensureCurrentPumpData") { done in
            self.pumpManager.ensureCurrentPumpData(completion: done)
        }
    }

    /// The old patch suspended since `since` - the host told so in a run before - its last status at `lastHeardAt`,
    /// showing `state`
    func suspendedPatchState(since: Date, lastHeardAt: Date, showing state: PatchState) -> MedtrumPumpState {
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
    func assertEachSuspendResumedOnItsOwn(storedBefore: Date, file: StaticString = #filePath, line: UInt = #line) {
        let suspends = ([storedBefore] + reports(of: .suspend).map(\.startDate)).map(LoopOrderingChecker.stored)
        let resumes = reports(of: .resume).map(\.startDate).map(LoopOrderingChecker.stored)
        let pairing = LoopOrderingChecker.oref0Pairing(suspends: suspends, resumes: resumes)
        XCTAssertNil(pairing.open, file: file, line: line)
        XCTAssertEqual(pairing.paired.count, suspends.count, file: file, line: line)
        XCTAssertEqual(Set(pairing.paired.map(\.resume)).count, suspends.count, "no two suspends paired with one resume", file: file, line: line)
        XCTAssertEqual(pairing.unpaired, [], file: file, line: line)
    }

    /// What the deactivation leaves: no session, the old patch's suspend reported 3 min ago
    func endedSessionState() -> MedtrumPumpState {
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

    func deactivate() -> Bool? {
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
    func deactivateWithTheStopLost() -> Bool? {
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
    func assertNothingReportedOverTheSessionEnd(
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
    func activate() -> Bool? {
        if !pumpManager.state.pumpState.isRunning {
            scriptTimeSync()
            link.script(CommandType.ACTIVATE, Self.activateAnswer(start: Date.now))
        }
        return runActivation()
    }

    /// The patch activates, its answer lost
    func activateWithTheAnswerLost() -> Bool? {
        scriptTimeSync()
        link.script(CommandType.ACTIVATE, .timeout)
        guard let result = runActivation() else {
            return nil
        }
        return !result
    }

    /// The same, sent by a build that kept no marker of it (`MedtrumPumpState.activationSentAt`), the app updated before
    /// the statuses after it: a running patch's status starts no session on its own - only a retried activation does
    func activateWithTheAnswerLostByAnEarlierBuild() -> Bool? {
        let lost = activateWithTheAnswerLost()
        XCTAssertNotNil(pumpManager.state.activationSentAt)
        pumpManager.state.activationSentAt = nil
        return lost
    }

    func runActivation() -> Bool? {
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
    func scriptTimeSync() {
        link.script(CommandType.SET_TIME, PatchBytes.answer(command: CommandType.SET_TIME, body: Data()))
        link.script(CommandType.SET_TIME_ZONE, PatchBytes.answer(command: CommandType.SET_TIME_ZONE, body: Data()))
        link.script(CommandType.GET_TIME, PatchBytes.answer(command: CommandType.GET_TIME, body: Date.now.toMedtrumSeconds()))
    }

    var patchReplacements: [NewPumpEvent] {
        delegate.batches.flatMap(\.events).filter { String(data: $0.raw, encoding: .utf8)?.hasPrefix("PATCH_REPLACE") == true }
    }

    var countedAtSessionEndAlerts: Int {
        delegate.alerts.filter { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-counted-at-session-end") }.count
    }

    var miscountedAlerts: Int {
        delegate.alerts.filter { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted") }.count
    }

    var baseResetAlerts: Int {
        delegate.alerts.filter { $0.identifier.alertIdentifier == "com.nightscout.medtrumkit.base-reset" }.count
    }

    var expiryReminderDelays: [TimeInterval] {
        delegate.alerts.filter { $0.identifier.alertIdentifier == "com.nightscout.medtrumkit.patch-expired" }.compactMap { alert in
            if case let .delayed(interval) = alert.trigger {
                return interval
            }
            return nil
        }
    }

    /// The new patch's ACTIVATE answer: its id, and its schedule started at `start`
    static func activateAnswer(start: Date) -> [String] {
        var body = newPatchId.toData(length: 4) + start.toMedtrumSeconds()
        body += Data([BasalType.STANDARD.rawValue]) + UInt64((scheduledRate / 0.05).rounded()).toData(length: 2)
        body += UInt64(0).toData(length: 2) + newPatchId.toData(length: 2) + start.toMedtrumSeconds()
        return PatchBytes.answer(command: CommandType.ACTIVATE, body: body)
    }

    /// The new patch's SET_BOLUS answer: record `record`, started at `start`
    static func bolusAnswer(record: Int, start: Date) -> [String] {
        let body = UInt64(record).toData(length: 2) + newPatchId.toData(length: 2) + start.toMedtrumSeconds()
        return PatchBytes.answer(command: CommandType.SET_BOLUS, body: body)
    }

    /// A notification in patch state `state` with the fields given, laid out as `NotificationPacket` reads them
    static func notification(
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
    static func patchSecond(_ date: Date) -> Date {
        Date.fromMedtrumSeconds(date.toMedtrumSeconds().toUInt64())
    }
}

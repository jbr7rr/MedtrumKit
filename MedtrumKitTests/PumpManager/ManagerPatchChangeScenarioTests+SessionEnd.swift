import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerPatchChangeScenarioTests {
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
}

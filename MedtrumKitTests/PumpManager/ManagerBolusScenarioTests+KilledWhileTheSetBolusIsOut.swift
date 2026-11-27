import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerBolusScenarioTests {
    // MARK: - Killed while a SetBolus awaits its answer

    /// A bolus is saved pending, and handed to the host, before its SetBolus goes out; answered, it is registered in its
    /// place: the state the host saves with its report has the dose and nothing pending
    func testBolusIsPendingWhileItsCommandGoesOutAndRegisteredInItsPlace() throws {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        // The host busy a while as the bolus is to go out: it goes out once the host has the state, not before
        delegate.queue.async { Thread.sleep(forTimeInterval: 0.5) }
        let sent = try sendBolus(2.0, .fragments(["0f13280000007b00ec009786a8178900"]), activationType: .automatic)
        XCTAssertNil(sent.error)

        let pending = try XCTUnwrap((sent.atWrite["pendingBolus"] as? PendingBolus.RawValue).flatMap(PendingBolus.init(rawValue:)))
        XCTAssertEqual(pending.units, 2.0)
        XCTAssertEqual(pending.sequenceAtSend, 122)
        XCTAssertTrue(pending.automatic)
        XCTAssertNil(sent.atWrite["bolusDose"])
        XCTAssertEqual(pumpManager.state.bolusDose?.sentAt, pending.sentAt)
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 123)

        let reported = try XCTUnwrap(delegate.batches.first)
        XCTAssertEqual(reported.events.first?.dose?.isMutable, true)
        XCTAssertNil(reported.savedState?["pendingBolus"], "saved with its report: the dose, nothing pending")
        XCTAssertNotNil(reported.savedState?["bolusDose"])
        XCTAssertEqual(delegate.errors.count, 0)
    }

    /// A SetBolus that never left the phone, and one the patch turned down: pending while they went out, nothing
    /// pending after, nothing reported - and a restart from what the host has runs nothing
    func testBolusNotSentOrTurnedDownLeavesNothingPending() throws {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))

        for answer: FakeMedtrumLink.Answer in [.failure(.notConnected), .failure(.invalidResponse(code: 8))] {
            let sent = try sendBolus(1.0, answer)
            guard case .communication? = sent.error else {
                XCTFail("The bolus did not fail: \(String(describing: sent.error))")
                continue
            }
            XCTAssertNotNil(sent.atWrite["pendingBolus"])
            XCTAssertNil(pumpManager.state.bolusDose)
        }

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.SET_BOLUS])
        XCTAssertEqual(delegate.batches.count, 0)
        XCTAssertEqual(delegate.errors.count, 0)

        try restart(from: delegate.savedState)
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
    }

    /// Killed before the answer to the SetBolus of 0.3 U of `user.txt:67542` came in: the state the host had saved
    /// before it went out has it pending, and the next run runs it as one whose command went unanswered - from the
    /// start, no other bolus going out; once the host is there, reported running in full, delivery uncertain and the
    /// host warned, once. Past its deadline a full status ends it, and the record after the 823 known when it went out,
    /// at its amount and near when it went out, finalizes it.
    func testBolusAwaitingItsAnswerWhenTheAppWasKilledRunsUnansweredAfterTheRestart() throws {
        makeManager(unansweredBolusState())
        let patchSentAt = pumpManager.state.pumpTime
        let sent = try sendBolus(0.3, .timeout)
        XCTAssertTrue(isUncertainDelivery(sent.error))

        let pending = try XCTUnwrap((sent.atWrite["pendingBolus"] as? PendingBolus.RawValue).flatMap(PendingBolus.init(rawValue:)))
        XCTAssertEqual(pending.units, 0.3)
        XCTAssertEqual(pending.sequenceAtSend, 823)
        XCTAssertFalse(pending.automatic)
        XCTAssertNil(sent.atWrite["bolusDose"])

        try restart(from: sent.atWrite)

        let running = try XCTUnwrap(pumpManager.state.bolusDose)
        XCTAssertNil(pumpManager.state.pendingBolus)
        XCTAssertEqual(running.confirmation, .uncertain)
        XCTAssertEqual(running.value, 0.3)
        XCTAssertEqual(running.startDate, pending.sentAt)
        XCTAssertEqual(running.sentAt, pending.sentAt)
        XCTAssertEqual(running.snapshot.sequenceAtSend, 823)
        XCTAssertNil(running.recordSequence)
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(delegate.batches.count, 0)
        XCTAssertEqual(uncertain.map(\.kind), [.bolus])
        XCTAssertEqual(uncertain.first?.cause, .appRestarted)
        XCTAssertEqual(uncertain.first?.phase, .countedInFull)

        guard case let .deviceState(error)? = commandBolus(1.0), case .isBolussing? = error as? MedtrumConnectError else {
            XCTFail("Another bolus was not refused as bolusing")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])

        // The loop's first sync
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()

        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.replacePendingEvents, false)
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(started?.type, .bolus)
        XCTAssertEqual(started?.isMutable, true)
        XCTAssertEqual(started?.programmedUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertNil(started?.deliveredUnits, "counted in full")
        XCTAssertEqual(started?.startDate, pending.sentAt)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertEqual(delegate.statusUpdates.last?.status.deliveryIsUncertain, true)

        pumpManager.ensureCurrentPumpData(completion: nil)
        confirmRecordSequence()
        XCTAssertEqual(delegate.batches.count, 1, "reported once")
        XCTAssertEqual(delegate.errors.count, 1, "warned once")

        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)

        link.notify("20000138" + "03f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(2), amount: 0.3, delivered: 0.3)
        )
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized bolus"), true)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertEqual(delegate.errors.count, 1)
    }

    /// The same, had the patch not run it - its SetBolus killed with the app before it went out, say: past its deadline
    /// the patch writes record 824, an alarm, and every record past the 823 known when it went out is read, none its -
    /// final at 0 U 15 min after it ended, nothing to tell the user
    func testBolusAwaitingItsAnswerWhenTheAppWasKilledThatNeverRanIsFinalizedAtZero() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline()

        link.notify("20000138" + "03f700")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 824, patchId: 247))
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 824)
        XCTAssertEqual(finals(of: started).count, 0, "not 15 min yet")

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
    }

    /// The same, the bolus noted with another patch's record number - one of a patch since replaced: every record past
    /// 823 read, none its, says nothing of it - record numbers restart with every patch. It may have run: counted in
    /// full, and the host told so
    func testBolusAwaitingItsAnswerWhenTheAppWasKilledNumberedOnAnotherPatchIsCountedInFull() throws {
        makeManager(unansweredBolusState())
        var saved = try sendBolus(0.3, .timeout).atWrite
        var pending = try XCTUnwrap(saved["pendingBolus"] as? [String: Any])
        XCTAssertEqual(pending["sequencePatchId"] as? Int, 247, "noted with this patch's")
        pending["sequencePatchId"] = 246
        saved["pendingBolus"] = pending
        try restart(from: saved)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertNil(started?.deliveredUnits, "counted in full")
        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        link.notify("20000138" + "03f700")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 824, patchId: 247))
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 824)
        advanceClock(by: 15 * Self.minute)
        syncRecords()

        XCTAssertEqual(assertOneFinal(of: started)?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "in full")
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), ["com.nightscout.medtrumkit.bolus-counted-as-delivered"])
    }

    /// The same, with record 824 skipped, unreadable: it could have been its - counted in full, and the host told so
    func testBolusAwaitingItsAnswerWhenTheAppWasKilledIsCountedInFullWithARecordSkipped() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline()

        link.notify("20000138" + "03f700")
        settle()
        let garbled = FakeMedtrumLink.Answer.garbled(PatchBytes.otherRecord(type: 3, sequence: 824, patchId: 247))
        link.script(CommandType.GET_RECORD, garbled)
        link.script(CommandType.GET_RECORD, garbled)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 824, "skipped")

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
        XCTAssertEqual(delegate.alerts.first?.identifier.alertIdentifier, "com.nightscout.medtrumkit.bolus-counted-as-delivered")
    }

    /// The same, ended by a full status that shows nothing of the records, none telling the newest since: a record of it
    /// may be past the ones known - counted in full once it waited the maximum, and the host told so
    func testBolusAwaitingItsAnswerWhenTheAppWasKilledIsCountedInFullWithTheRecordNumberNotToldSinceItsDeadline() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline(confirmingRecords: false)
        XCTAssertNil(pumpManager.state.sequenceConfirmedAt)

        advanceClock(by: 15 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).count, 0, "not caught up")

        advanceClock(by: 45 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
        XCTAssertEqual(delegate.alerts.first?.identifier.alertIdentifier, "com.nightscout.medtrumkit.bolus-counted-as-delivered")
    }

    /// The SetBolus of 0.3 U unanswered, then cancelled: a bolus cancelled may have no record - counted in full, as
    /// before, with every record read and none its, and the host told so
    func testCancelledUnansweredBolusWithoutItsRecordIsCountedInFull() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose

        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.finishReason, .cancelled)

        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
        XCTAssertEqual(delegate.alerts.first?.identifier.alertIdentifier, "com.nightscout.medtrumkit.bolus-counted-as-delivered")
    }

    /// The SetBolus of 0.3 U unanswered; record 824 is a bolus of 0.3 U that starts 5 min after it went out and matches
    /// nothing of ours - its, should the patch clock be further off than we think: counted in full, the host told so
    func testUnansweredBolusWithARecordAtItsAmountMatchingNothingIsCountedInFull() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime

        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        link.notify("20000138" + "03f700")
        settle()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(300), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome, "unmatched")

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// Two SetBoluses of 0.3 U unanswered a second apart, the first cancelled: the record of the second, 824, is taken
    /// for the first - near when both went out. The second, left without a record that could be its, is counted in full,
    /// the host told so - not taken for one that never ran.
    func testUnansweredBolusWhoseRecordAnotherTookIsCountedInFull() throws {
        startUnansweredBolus()
        let first = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        let patchSentAt = pumpManager.state.pumpTime

        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)

        link.script(CommandType.SET_BOLUS, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandBolus(0.3)))
        settle()
        let second = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != first.syncIdentifier })

        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        link.notify("20000138" + "03f700")
        settle()
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 2)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(2), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        XCTAssertEqual(finals(of: first).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(finals(of: second).count, 0)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: second)
        XCTAssertEqual(finals(of: second).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// Killed after the answer to the SetBolus of 2 U (`user.txt:11229`) came in, before the host had the state with its
    /// dose: the state saved before it went out has it pending, so the next run counts it all the same - as one whose
    /// command went unanswered, in full and warned of, all it can know. Its completion, and the record past the 122
    /// known when it went out, finalize it.
    func testBolusAnsweredAsTheAppWasKilledIsCountedAfterTheRestart() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)
        let sent = try sendBolus(2.0, .fragments(["0f13280000007b00ec009786a8178900"]))
        XCTAssertNil(sent.error)
        XCTAssertEqual(delegate.batches.count, 1, "registered in the run that sent it")

        try restart(from: sent.atWrite)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()

        let started = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(started?.programmedUnits ?? 0, 2.0, accuracy: 0.001)
        XCTAssertNil(started?.deliveredUnits, "counted in full")
        XCTAssertEqual(uncertainDeliveryErrors, 1)

        // Its completion, 2 U, the patch at record 123
        link.notify("202211802800040d7b00ec000000000000")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 123)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: patchSentAt, amount: 2.0, delivered: 2.0)
        )
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertEqual(delegate.errors.count, 1)
    }

    /// The SetBolus unanswered in the run that sent it: nothing is pending once it runs unanswered there, and a restart
    /// from the state the host has brings back the same bolus, warned of already - not taken over again, nor reported or
    /// warned of again
    func testUnansweredBolusIsNotTakenOverAgainAfterARestart() throws {
        startUnansweredBolus()
        let running = try XCTUnwrap(pumpManager.state.bolusDose)
        XCTAssertNil(pumpManager.state.pendingBolus)
        XCTAssertNil(delegate.savedState?["pendingBolus"])

        try restart(from: delegate.savedState)
        pumpManager.ensureCurrentPumpData(completion: nil)
        confirmRecordSequence()

        XCTAssertEqual(pumpManager.state.bolusDose?.startDate, running.startDate)
        XCTAssertEqual(pumpManager.state.bolusDose?.confirmation, .uncertain)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(delegate.batches.count, 0)
        XCTAssertEqual(delegate.errors.count, 0)
    }

    /// A state read as the answered bolus was registered, its pending bolus not cleared yet - the dose ended since, and
    /// waits on its record: the pending one is that dose, and is dropped
    func testPendingBolusSavedWithItsDoseIsNotTakenOver() throws {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        let sent = try sendBolus(2.0, .fragments(["0f13280000007b00ec009786a8178900"]))
        link.notify("202211802800040d7b00ec000000000000")
        settle()
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 1)

        var saved = pumpManager.state.rawValue
        saved["pendingBolus"] = sent.atWrite["pendingBolus"]
        try restart(from: saved)

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertNil(pumpManager.state.pendingBolus)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 1)

        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        XCTAssertEqual(delegate.batches.count, 0)
        XCTAssertEqual(delegate.errors.count, 0)
    }

    /// Killed again after taking the bolus over, before the host was told of it - the state saved meanwhile no longer
    /// has it pending: the next run reports it, and warns, on the first status from the patch here. Killed before that
    /// state was saved, it is taken over again, the same dose.
    func testBolusTakenOverButNeverReportedIsReportedAfterTheNextRestart() throws {
        makeManager(unansweredBolusState())
        let atWrite = try sendBolus(0.3, .timeout).atWrite

        try restart(from: atWrite)
        let takenOver = try XCTUnwrap(pumpManager.state.bolusDose)
        let savedBeforeTheFirstSync = pumpManager.state.rawValue

        try restart(from: atWrite)
        XCTAssertEqual(pumpManager.state.bolusDose?.startDate, takenOver.startDate)

        try restart(from: savedBeforeTheFirstSync)
        XCTAssertEqual(pumpManager.state.bolusDose?.startDate, takenOver.startDate)
        XCTAssertNil(pumpManager.state.pendingBolus)

        confirmRecordSequence()
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.startDate, takenOver.startDate)
        XCTAssertNil(delegate.batches.first?.events.first?.dose?.deliveredUnits)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
    }

    /// A SetBolus that never left the phone, and one the patch turned down, are off the state the host has by the time
    /// the command fails - a host busy a while included: killed right then, the app comes back with no bolus
    func testBolusNotSentOrTurnedDownIsOffTheSavedStateBeforeItFails() throws {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))

        for answer: FakeMedtrumLink.Answer in [.failure(.notConnected), .failure(.invalidResponse(code: 8))] {
            link.script(CommandType.SET_BOLUS, answer) { [unowned self] in
                delegate.queue.async { Thread.sleep(forTimeInterval: 0.5) }
            }
            let atFailure = Locked<PumpManager.RawStateValue?>(nil)
            let failed: PumpManagerError?? = completion(of: "enactBolus") { done in
                self.pumpManager.enactBolus(units: 1.0, activationType: .manualNoRecommendation) { error in
                    atFailure.value = self.delegate.savedState
                    done(error)
                }
            }
            guard case .communication? = failed ?? nil else {
                XCTFail("The bolus did not fail: \(String(describing: failed))")
                continue
            }

            let saved = try XCTUnwrap(atFailure.value)
            XCTAssertNil(saved["pendingBolus"], "the host still had it pending as the command failed")
            settle()

            try restart(from: saved)
            XCTAssertNil(pumpManager.state.bolusDose)
            XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
        }
    }

    /// The live report of a bolus answered 1.5 s after it went out, and the report of the same bolus taken over after a
    /// kill: one identity - both dated from when it went out - so a host holding both holds one bolus
    func testBolusReportedLiveAndTakenOverAfterAKillIsOneDose() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)
        let sent = try sendBolus(2.0, .fragments(["0f13280000007b00ec009786a8178900"]), answerTakes: 1.5)
        XCTAssertNil(sent.error)
        let pending = try XCTUnwrap((sent.atWrite["pendingBolus"] as? PendingBolus.RawValue).flatMap(PendingBolus.init(rawValue:)))
        let live = try XCTUnwrap(delegate.batches.first?.events.first)
        XCTAssertEqual(live.dose?.startDate, pending.sentAt)

        try restart(from: sent.atWrite)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let takenOver = try XCTUnwrap(delegate.batches.first?.events.first)

        XCTAssertEqual(takenOver.raw, live.raw)
        XCTAssertEqual(takenOver.dose?.syncIdentifier, live.dose?.syncIdentifier)
    }

    /// Killed after the answer to the SetBolus of 2 U was kept for its record, #123, before its dose was registered: a
    /// state saved in between has both. Taken over, the bolus has its answer: its record, delivered 1.2 U after a cut
    /// short, finalizes it by number.
    func testBolusTakenOverWithItsAnswerSavedIsFinalizedByItsOwnRecord() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)
        let sent = try sendBolus(2.0, .fragments(["0f13280000007b00ec009786a8178900"]))
        XCTAssertNil(sent.error)

        var saved = sent.atWrite
        saved["answeredBolusRecords"] = pumpManager.state.rawValue["answeredBolusRecords"]
        XCTAssertNotNil(saved["answeredBolusRecords"])
        try restart(from: saved)
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 123)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let started = delegate.batches.first?.events.first?.dose

        link.notify("202211802800040d7b00ec000000000000")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: patchSentAt, amount: 2.0, delivered: 1.2)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized bolus"), true)
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 1.2, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// 2 U answered as record 123, cancelled at 0.4 U, the patch's completion of it lost with the link: the record number
    /// known stays 122. Killed awaiting the answer to the next SetBolus of 2 U, which the patch runs as record 124. The
    /// answer kept for 123 is the cancelled bolus's - not taken for the answer of the one taken over, which its record
    /// 124 then finalizes.
    func testBolusTakenOverIsNotGivenTheNumberAnEarlierBolusClaimed() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        link.notify("202210000800280d0000000000") // 0.4 U
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        let cancelled = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 122)

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)
        let sent = try sendBolus(2.0, .timeout)
        XCTAssertEqual(sent.atWrite["answeredBolusRecords"] as? [Int], [123])
        try restart(from: sent.atWrite)

        XCTAssertNotNil(pumpManager.state.bolusDose)
        XCTAssertNil(pumpManager.state.bolusDose?.recordSequence, "123 is the cancelled bolus's")
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let takenOver = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != cancelled.syncIdentifier })

        // Its completion, 2 U, and the patch at record 124
        advanceClock(by: 3 * Self.minute)
        link.notify("200200802800")
        link.notify("200001" + "7c00ec00")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: patchSentAt, amount: 2.0, delivered: 0.4)
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: patchSentAt.addingTimeInterval(1), amount: 2.0, delivered: 2.0)
        )
        syncRecords()

        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
        assertOneFinal(of: takenOver)
        XCTAssertEqual(finals(of: takenOver).last?.deliveredUnits ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 124 }?.outcome?.hasPrefix("finalized bolus"), true)
    }

    /// The same, but nothing tells the record number for 61 min: the cancelled bolus is finalized at its maximum wait,
    /// 0.4 U, and the host stores it - no dose we hold claims 123 any more, and the number known is still 122. The next
    /// SetBolus of 2 U goes out with 123, the newest claimed, as the newest known: taken over, it is not given 123. Record
    /// 123 finalizes nothing, its own record 124 finalizes it at 2 U.
    func testBolusTakenOverIsNotGivenTheNumberOfAnEarlierBolusFinalizedAndGone() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        link.notify("202210000800280d0000000000") // 0.4 U
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        let cancelled = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 122)

        advanceClock(by: 61 * Self.minute)
        syncRecords()
        assertOneFinal(of: cancelled)
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? -1, 0.4, accuracy: 0.001)
        XCTAssertTrue(pumpManager.state.awaitingRecord.isEmpty, "stored by the host, gone")
        XCTAssertEqual(pumpManager.state.answeredBolusRecords, [123])

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)
        let sent = try sendBolus(2.0, .timeout)
        XCTAssertEqual((sent.atWrite["pendingBolus"] as? [String: Any])?["sequenceAtSend"] as? Int, 123)
        try restart(from: sent.atWrite)
        XCTAssertNotNil(pumpManager.state.bolusDose)
        XCTAssertNil(pumpManager.state.bolusDose?.recordSequence, "123 is the cancelled bolus's")
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let takenOver = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != cancelled.syncIdentifier })

        // Its completion, 2 U, and the patch at record 124
        advanceClock(by: 3 * Self.minute)
        link.notify("200200802800")
        link.notify("200001" + "7c00ec00")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: patchSentAt, amount: 2.0, delivered: 0.4)
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: patchSentAt.addingTimeInterval(1), amount: 2.0, delivered: 2.0)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 123 }?.outcome, "answered bolus finalized already")
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 124 }?.outcome?.hasPrefix("finalized bolus"), true)
        assertOneFinal(of: takenOver)
        XCTAssertEqual(finals(of: takenOver).last?.deliveredUnits ?? -1, 2.0, accuracy: 0.001)
    }

    /// A state with two saved answers past the record known when the pending SetBolus went out - 123, an earlier
    /// bolus's whose dose is gone, and 124, the pending one's own - which `sequenceAtSend` taking in the newest claimed
    /// rules out today: taken over, the bolus adopts the latest, its own, and its record 124 finalizes it by number.
    func testBolusTakenOverAdoptsTheLatestOfTheAnswersSavedPastItsSend() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)
        let answer = PatchBytes.answer(
            command: CommandType.SET_BOLUS,
            body: UInt64(124).toData(length: 2) + UInt64(236).toData(length: 2) + patchSentAt.toMedtrumSeconds()
        )
        let sent = try sendBolus(2.0, .fragments(answer))
        XCTAssertNil(sent.error)
        XCTAssertEqual((sent.atWrite["pendingBolus"] as? [String: Any])?["sequenceAtSend"] as? Int, 122)

        var saved = sent.atWrite
        saved["answeredBolusRecords"] = [123, 124]
        try restart(from: saved)
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 124)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let started = try XCTUnwrap(delegate.batches.first?.events.first?.dose)

        advanceClock(by: 3 * Self.minute)
        link.notify("200200802800")
        link.notify("200001" + "7c00ec00")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: patchSentAt.addingTimeInterval(-60), amount: 2.0, delivered: 0.4)
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: patchSentAt, amount: 2.0, delivered: 2.0)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 123 }?.outcome, "answered bolus finalized already")
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 124 }?.outcome?.hasPrefix("finalized bolus"), true)
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 2.0, accuracy: 0.001)
    }

    /// A status the link hands the manager as it starts - the completion of the bolus its state has pending - finds the
    /// bolus taken over already, and ends it
    func testStatusAsTheManagerStartsFindsThePendingBolusTakenOver() throws {
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: Date.fromMedtrumSeconds(0x17A8_8697))
        makeManager(state)
        let sent = try sendBolus(2.0, .fragments(["0f13280000007b00ec009786a8178900"]))

        link.whenAttached = { [unowned self] in
            link.notify("202211802800040d7b00ec000000000000")
        }
        try restart(from: sent.atWrite)

        XCTAssertNil(pumpManager.state.bolusDose, "running still: the status came before the bolus was taken over")
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.finishReason, .completed)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.deliveredUnits ?? 0, 2.0, accuracy: 0.001)
    }

    /// The first status of the run after the kill is the completion of the bolus taken over: the host is told of it
    /// running, in full, before the completion ends it - not only of it ended
    func testFirstStatusAfterTheRestartReportsTheBolusTakenOverBeforeItEndsIt() throws {
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: Date.fromMedtrumSeconds(0x17A8_8697))
        makeManager(state)
        let sent = try sendBolus(2.0, .fragments(["0f13280000007b00ec009786a8178900"]))
        let pending = try XCTUnwrap((sent.atWrite["pendingBolus"] as? PendingBolus.RawValue).flatMap(PendingBolus.init(rawValue:)))

        try restart(from: sent.atWrite)
        link.notify("202211802800040d7b00ec000000000000")
        settle()

        XCTAssertEqual(delegate.batches.count, 2)
        let running = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(running?.isMutable, true)
        XCTAssertEqual(running?.startDate, pending.sentAt)
        XCTAssertNil(running?.deliveredUnits, "counted in full")
        let ended = delegate.batches.last?.events.last?.dose
        XCTAssertEqual(ended?.syncIdentifier, running?.syncIdentifier)
        XCTAssertEqual(ended?.deliveredUnits ?? 0, 2.0, accuracy: 0.001)
    }

    /// A host that does not take the state within the bound (device 2026-10-23 15:42, its queue stalled 80 s): the bolus
    /// is not written - killed after the write, the app would come back with no dose of it - and fails, not delivered,
    /// with a warning. A manual one and an automatic one alike. Nothing is left pending or running, the state the host
    /// takes once it is free has nothing pending, and the next bolus goes out as ever.
    func testBolusIsNotWrittenAndFailsWhenTheHostDoesNotTakeTheState() throws {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        MedtrumLogger.pumpManager = pumpManager
        defer { MedtrumLogger.pumpManager = nil }
        pumpManager.dosingHandOverTimeout = 1

        for activationType: BolusActivationType in [.manualNoRecommendation, .automatic] {
            let releaseHost = stallHost()
            defer { releaseHost() }

            let started = Date.now
            let error = commandBolus(2.0, activationType: activationType, timeout: 10)
            let took = Date.now.timeIntervalSince(started)

            XCTAssertTrue(isStateNotSaved(error), "failed, not uncertain: \(String(describing: error))")
            XCTAssertGreaterThan(took, 0.9, "not before the bound is up")
            XCTAssertEqual(link.writtenCommands, [], "not written")
            XCTAssertNil(pumpManager.state.pendingBolus)
            XCTAssertNil(pumpManager.state.bolusDose)
            XCTAssertEqual(pumpManager.state.bolusState, .noBolus)

            XCTAssertNil(pumpManager.rawState["pendingBolus"], "no read from now on has it pending")

            releaseHost()
            settle()
            XCTAssertNil(delegate.savedState?["pendingBolus"], "the host took the state late, nothing pending")
        }

        XCTAssertEqual(delegate.batches.count, 0)
        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertTrue(uncertain.isEmpty)
        XCTAssertEqual(delegate.logEntries.filter { entry in
            entry.message.contains("did not take the state within 1 s, nor read it: the bolus of 2.0 U is not written, it fails - not delivered")
        }.count, 2)

        // The loop's next SMB
        link.script(CommandType.SET_BOLUS, .fragments(["0f13280000007b00ec009786a8178900"]))
        XCTAssertNil(commandBolus(2.0, activationType: .automatic))
        settle()
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 123)
        XCTAssertEqual(delegate.batches.count, 1)
    }

    /// A host taking 5 s to take the state - past the 3 s every other hand-over waits, within the bolus's bound: the
    /// bolus goes out once it has it, pending on disk, as ever
    func testBolusGoesOutWhenTheHostTakesTheStateWithinItsBound() throws {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        XCTAssertEqual(pumpManager.dosingHandOverTimeout, 10)
        delegate.queue.async { Thread.sleep(forTimeInterval: 5) }

        let started = Date.now
        let wroteAt = Locked<Date?>(nil)
        let atWrite = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_BOLUS, .fragments(["0f13280000007b00ec009786a8178900"])) { [unowned self] in
            atWrite.value = delegate.savedState
            wroteAt.value = Date.now
        }
        XCTAssertNil(commandBolus(2.0, timeout: 20))
        settle()

        XCTAssertGreaterThan(try XCTUnwrap(wroteAt.value).timeIntervalSince(started), 4.9, "once the host has it")
        XCTAssertNotNil(atWrite.value?["pendingBolus"], "on disk as it went out")
        XCTAssertNotNil(pumpManager.state.bolusDose)
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.errors.count, 0)
    }

    /// The host saved the state with the bolus pending, and is held up before it is done with it - as iAPS logs it,
    /// stalled (device 2026-10-23 15:42): it is on its disk, the bound runs out all the same. The bolus is written, and
    /// that is logged - killed after the write, the app comes back with it pending, as one gone unanswered.
    func testBolusIsWrittenWhenTheHostSavedTheStateWithItPendingAndIsHeldUp() throws {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        MedtrumLogger.pumpManager = pumpManager
        defer { MedtrumLogger.pumpManager = nil }
        pumpManager.dosingHandOverTimeout = 1
        let releaseHost = stallHostAfterSaving("pendingBolus")
        defer { releaseHost() }

        let started = Date.now
        let wroteAt = Locked<Date?>(nil)
        let atWrite = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_BOLUS, .fragments(["0f13280000007b00ec009786a8178900"])) { [unowned self] in
            atWrite.value = delegate.savedState
            wroteAt.value = Date.now
        }
        XCTAssertNil(commandBolus(2.0, timeout: 10))

        XCTAssertGreaterThan(try XCTUnwrap(wroteAt.value).timeIntervalSince(started), 0.9, "once the bound is up")
        XCTAssertNotNil(atWrite.value?["pendingBolus"], "on disk as it went out")

        releaseHost()
        settle()
        // Handed to the host on its queue, as everything else
        XCTAssertTrue(delegate.logEntries.contains { entry in
            entry.message.contains("did not take the state within 1 s, but read it with the bolus of 2.0 U pending - saving it: written")
        })
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 123)
        XCTAssertNil(delegate.savedState?["pendingBolus"])
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.errors.count, 0)
    }

    /// The manager's own read of the state as the bolus is pending - for the status updates it hands out - is not the
    /// host's: it saves nothing, and the bolus is not written as the bound runs out
    func testStateReadByTheManagerItselfIsNotTakenForTheHostsWithABolusPending() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        pumpManager.dosingHandOverTimeout = 1
        let releaseHost = stallHost()
        defer { releaseHost() }

        // Once it is pending: a change of the state told of, its old state read again on the main queue after
        let readWhilePending = Locked(false)
        DispatchQueue.global().async { [pumpManager] in
            guard let pumpManager else {
                return
            }
            let until = Date.now.addingTimeInterval(5)
            while pumpManager.state.pendingBolus == nil, Date.now < until {
                Thread.sleep(forTimeInterval: 0.01)
            }
            pumpManager.notifyStateDidChange()
            DispatchQueue.main.async {
                readWhilePending.value = pumpManager.oldState.pendingBolus != nil
            }
        }

        XCTAssertTrue(isStateNotSaved(commandBolus(2.0, timeout: 10)))
        XCTAssertTrue(readWhilePending.value, "read while it was pending")
        XCTAssertEqual(link.writtenCommands, [], "not written")
        XCTAssertNil(pumpManager.state.pendingBolus)
    }

    /// A host taking 5 s to take the state, a completion with no bolus running coming meanwhile - kept for the bolus
    /// pending, a tiny one completes before its answer: it came before the bolus was written, and is not its completion,
    /// though after `sentAt`, which is from before the wait
    func testCompletionWhileTheHostTakesTheStateIsNotTheBolussOwn() throws {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        MedtrumLogger.pumpManager = pumpManager
        defer { MedtrumLogger.pumpManager = nil }
        delegate.queue.async { Thread.sleep(forTimeInterval: 5) }

        DispatchQueue.global().async { [pumpManager, link] in
            guard let pumpManager, let link else {
                return
            }
            let until = Date.now.addingTimeInterval(5)
            while pumpManager.state.pendingBolus == nil, Date.now < until {
                Thread.sleep(forTimeInterval: 0.01)
            }
            Thread.sleep(forTimeInterval: 0.5)
            link.notify("200200802800") // 2 U, no record named
        }

        link.script(CommandType.SET_BOLUS, .fragments(["0f13280000007b00ec009786a8178900"]))
        XCTAssertNil(commandBolus(2.0, timeout: 20))
        settle()

        XCTAssertTrue(delegate.logEntries.contains { $0.message.contains("before the answer to the bolus of 2.0 U") })
        XCTAssertTrue(delegate.logEntries.contains { $0.message.contains("it came before the bolus went out") })
        XCTAssertNotNil(pumpManager.state.bolusDose, "still running")
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
    }

    /// The patch shows itself halted as the bolus waits for the host to take the state with it pending: not written to
    /// a halted patch - it fails, nothing pending in the state the host has after
    func testBolusIsNotWrittenWithAHaltShownAsItWaitsForTheHost() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        settle()
        // Halted, of its own - no time told - its newest record 122
        let halt = (Data([PatchState.suspended.rawValue, 0x00, 0x01]) + UInt64(122).toData(length: 2) + UInt64(236).toData(length: 2))
            .hexEncodedString()
        let shown = Locked(false)
        delegate.afterSavingState = { [link] saved in
            guard saved["pendingBolus"] != nil, !shown.value else {
                return
            }
            shown.value = true
            // Off the host's queue, while it is held up
            DispatchQueue.global().async { link?.notify(halt) }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let error = commandBolus(2.0, activationType: .automatic)
        delegate.afterSavingState = nil
        guard case let .deviceState(cause)? = error, case .isSuspended? = cause as? MedtrumConnectError else {
            XCTFail("Not failed as suspended: \(String(describing: error))")
            return
        }
        settle()
        XCTAssertTrue(shown.value)
        XCTAssertEqual(link.writtenCommands, [], "not written")
        XCTAssertNil(pumpManager.state.pendingBolus)
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertNil(delegate.savedState?["pendingBolus"], "off the state the host has")
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertTrue(reports(of: .bolus).isEmpty)
    }

    /// A SetBolus whose write failed - it never left the phone - the app killed before the host took the state that
    /// failure cleared: the next run comes back with it pending, as one gone unanswered, counted in full. Every record
    /// past the 823 known when it went out read, none its: final at 0 U, and the next bolus goes out as ever.
    func testBolusWhoseWriteFailedTakenOverAfterAKillIsFinalizedAtZero() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline(answer: .failure(.notConnected))

        link.notify("20000138" + "03f700")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 824, patchId: 247))
        syncRecords()
        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)

        link.script(
            CommandType.SET_BOLUS,
            PatchBytes.answer(
                command: CommandType.SET_BOLUS,
                body: UInt64(825).toData(length: 2) + UInt64(247).toData(length: 2) + pumpManager.state.pumpTime.toMedtrumSeconds() +
                    Data([0])
            )
        )
        XCTAssertNil(commandBolus(0.3))
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 825)
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
    }
}

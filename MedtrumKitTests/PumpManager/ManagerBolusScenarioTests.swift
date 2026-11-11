import LoopKit
@testable import MedtrumKit
import XCTest

/// Bolus scenarios driven through the manager: the command, the patch's notifications and statuses, its records, and
/// what the host is told along the way.
///
/// Bytes are from the user's MedtrumKit logs (pump f7ae759e, firmware 1.80.88), cited by the line in the merged
/// analysis log `user.txt` or the record-reading log `aug12.txt`. Records no log has are built with `PatchBytes`.
final class ManagerBolusScenarioTests: MedtrumManagerTestCase {
    /// 2026-08-01 23:17:39 - 23:21:02 (`aug12.txt:8414-8485`), patch 236: an SMB of 0.05 U while 1.25 U/h runs. Its
    /// completion comes without any progress; the answer names record 937, which a full status later says is written.
    func testTinyBolusEndsOnItsCompletionAndIsFinalizedByItsRecordNumber() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75.35)
        let tempBasal = runningTempBasal(
            rate: 1.25,
            startedAgo: 3,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_084_662)
        )
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_084_665))
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()

        // The answer: record 937, started on the patch at 23:17:45
        let running = pumpManager.state.bolusDose
        XCTAssertEqual(running?.recordSequence, 937)
        XCTAssertEqual(running?.pumpStartTime, Self.patchTime(397_084_665))
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 936, "allocated, not written: nothing to read yet")
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.replacePendingEvents, false)
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(started?.isMutable, true)

        guard let reporter = pumpManager.createBolusProgressReporter(reportingOn: DispatchQueue.main) else {
            XCTFail("No progress reporter for the running bolus")
            return
        }

        // Completed, 0.05 U - and over at once, not held until a deadline
        link.notify("202a0080010006a803ec00f607ab17191000e205")
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
        XCTAssertTrue(reporter.progress.isComplete)
        XCTAssertEqual(reporter.progress.deliveredUnits, 0.05, accuracy: 0.001)

        XCTAssertEqual(delegate.batches.count, 2)
        let completed = delegate.batches.last
        XCTAssertEqual(completed?.replacePendingEvents, true)
        XCTAssertEqual(completed?.events.map(\.dose?.type), [.tempBasal, .bolus])
        let awaiting = completed?.events.last?.dose
        XCTAssertEqual(awaiting?.isMutable, true, "mutable until its record")
        XCTAssertEqual(awaiting?.syncIdentifier, started?.syncIdentifier)
        XCTAssertEqual(awaiting?.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        let completedAt = awaiting?.endDate

        // The periodic full sync says record 937 is written; its bolus field repeats the completion, which says nothing
        link.deliverFullStatus([
            "2f034401000020ee0d80010080000006a803ec2a",
            "2f03440200f607ab17193000e0052b33a817c5a8",
            "2f0344033b59a903ec00b5d602001905735c"
        ])
        settle()
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 937)

        link.script(
            CommandType.GET_RECORD,
            fragments: "33634c010000aa2c01ff9e75aef7ec00a90301a0",
            "33634c02000000f907ab1701000100000000001e",
            "33634c03000000000000000000000000a3507873",
            "33634c040a3e52"
        )
        syncRecords()

        XCTAssertEqual(link.writes.last?.encoded(sequence: 0x4C), "09634c00a903ec00e800")
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 937)

        let final = finals(of: started).last
        assertOneFinal(of: started)
        XCTAssertEqual(final?.programmedUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(final?.endDate, completedAt, "ends when its completion came")
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0, "the host stored the final")
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized bolus"), true)
        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertTrue(uncertain.isEmpty, "nothing was uncertain")
    }

    /// 2026-10-20 00:52:53 - 00:54:05 (device test #2, patch 273): the answer names the bolus's record, 421, its
    /// completion comes naming 420 the newest - the heartbeat's read takes up to 420 - and 421 is named a moment later.
    /// That read counts for no cooldown: the next heartbeat reads 421, not one a minute later. Here with patch 236's bytes.
    func testBolusRecordNamedPastTheNewestToldIsReadByTheNextHeartbeat() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75.35)
        state.syncedSequenceNumber = 935
        state.basalDose = runningTempBasal(rate: 1.25, startedAgo: 3, duration: 30 * Self.minute, pumpStartTime: Self.patchTime(397_084_662))
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_084_665))
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()
        let started = reports(of: .bolus).first
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 937)

        // Completed, naming 936 the newest
        link.notify("202a0080010006a803ec00f607ab17191000e205")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 936)

        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 936, patchId: 236))
        syncRecords(.awaitingDoses)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 936)
        XCTAssertTrue(finals(of: started).isEmpty)

        // The heartbeat naming 937, moments later
        pumpManager.state.currentSequenceNumber = 937
        confirmRecordSequence()
        XCTAssertEqual(pumpManager.heartbeatSync(), .records)
        link.script(
            CommandType.GET_RECORD,
            fragments: "33634c010000aa2c01ff9e75aef7ec00a90301a0",
            "33634c02000000f907ab1701000100000000001e",
            "33634c03000000000000000000000000a3507873",
            "33634c040a3e52"
        )
        syncRecords(.awaitingDoses)

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 937)
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).first?.deliveredUnits ?? 0, 0.05, accuracy: 0.001, "from its record")
    }

    /// The same, the heartbeat's read of 936 failing: that run counts for the cooldown - one cut short does - and the next
    /// heartbeat reads nothing. Every heartbeat would retry a failing link otherwise.
    func testBolusRecordNamedPastTheNewestToldWaitsForTheCooldownAfterAFailedRead() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75.35)
        state.syncedSequenceNumber = 935
        state.basalDose = runningTempBasal(rate: 1.25, startedAgo: 3, duration: 30 * Self.minute, pumpStartTime: Self.patchTime(397_084_662))
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_084_665))
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()
        link.notify("202a0080010006a803ec00f607ab17191000e205")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords(.awaitingDoses)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 935)

        pumpManager.state.currentSequenceNumber = 937
        confirmRecordSequence()
        syncRecords(.awaitingDoses)

        XCTAssertEqual(link.writtenCommands.filter { $0 == CommandType.GET_RECORD }.count, 1, "throttled")
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 935)
    }

    /// The same, the heartbeat's read stopped short of 936 by a command taking the link - a settings update - with no
    /// read failing: that run counts for no cooldown either, and the next heartbeat reads 936 and 937.
    func testBolusRecordNamedPastTheNewestToldIsReadByTheNextHeartbeatAfterACommandCutTheReadShort() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75.35)
        state.syncedSequenceNumber = 934
        state.basalDose = runningTempBasal(rate: 1.25, startedAgo: 3, duration: 30 * Self.minute, pumpStartTime: Self.patchTime(397_084_662))
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_084_665))
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()
        let started = reports(of: .bolus).first
        link.notify("202a0080010006a803ec00f607ab17191000e205")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        // 935 read, then the command - in flight until the sync stopped for it: over before the sync looks again, the
        // sync would read on, as it should
        let updated = expectation(description: "settings updated")
        let commandHeld = DispatchSemaphore(value: 0)
        link.script(CommandType.SET_PATCH, .fragments(PatchBytes.answer(command: CommandType.SET_PATCH, body: Data()))) {
            commandHeld.wait()
        }
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 3, sequence: 935, patchId: 236))) { [unowned self] in
            pumpManager.updatePatchSettings { _ in updated.fulfill() }
        }
        syncRecords(.awaitingDoses)
        commandHeld.signal()
        wait(for: [updated], timeout: 5)
        settle()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 935)
        XCTAssertEqual(link.writtenCommands.filter { $0 == CommandType.GET_RECORD }.count, 1, "stopped at 936 for the command")

        pumpManager.state.currentSequenceNumber = 937
        confirmRecordSequence()
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 936, patchId: 236))
        link.script(
            CommandType.GET_RECORD,
            fragments: "33634c010000aa2c01ff9e75aef7ec00a90301a0",
            "33634c02000000f907ab1701000100000000001e",
            "33634c03000000000000000000000000a3507873",
            "33634c040a3e52"
        )
        syncRecords(.awaitingDoses)

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 937, "not held up for the cooldown")
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).first?.deliveredUnits ?? 0, 0.05, accuracy: 0.001, "from its record")
    }

    /// The same, the heartbeat's run turned away by a command in flight - a settings update - reading nothing: it counts
    /// for no cooldown, and the heartbeat after the command reads 936.
    func testHeartbeatRunTurnedAwayByACommandInFlightLeavesNoCooldown() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75.35)
        state.syncedSequenceNumber = 935
        state.basalDose = runningTempBasal(rate: 1.25, startedAgo: 3, duration: 30 * Self.minute, pumpStartTime: Self.patchTime(397_084_662))
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_084_665))
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()
        link.notify("202a0080010006a803ec00f607ab17191000e205")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        let updated = expectation(description: "settings updated")
        link.script(CommandType.SET_PATCH, .fragments(PatchBytes.answer(command: CommandType.SET_PATCH, body: Data()))) { [unowned self] in
            RecordSyncer.syncRecords(pumpManager: pumpManager, trigger: .awaitingDoses)
        }
        pumpManager.updatePatchSettings { _ in updated.fulfill() }
        wait(for: [updated], timeout: 5)
        settle()
        XCTAssertEqual(link.writtenCommands.filter { $0 == CommandType.GET_RECORD }.count, 0, "turned away")

        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 936, patchId: 236))
        syncRecords(.awaitingDoses)

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 936, "not held up for the cooldown")
    }

    /// 2026-10-17 10:43:07 - 10:45:47 (log 16, patch 270): an SMB of 0.05 U over a slow link - the patch delivers it, and
    /// sends its completion naming its record, before its answer comes. Kept for it: the bolus ends on that completion,
    /// not unseen at its deadline with a warning of uncertain delivery. Here with patch 236's bytes.
    func testTinyBolusCompletedBeforeItsAnswerEndsOnThatCompletion() throws {
        runTinyBolusSetup()

        let completedBy = Locked<Date?>(nil)
        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            link.notify(Self.completion(delivered: 1, record: 937))
            completedBy.value = Date.now
        }
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 937)
        XCTAssertEqual(delegate.batches.count, 2)
        let started = delegate.batches.first?.events.first?.dose
        let awaiting = try XCTUnwrap(delegate.batches.last?.events.last?.dose)
        XCTAssertEqual(awaiting.syncIdentifier, started?.syncIdentifier)
        XCTAssertEqual(awaiting.isMutable, true, "mutable until its record")
        XCTAssertEqual(awaiting.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertLessThanOrEqual(awaiting.endDate, try XCTUnwrap(completedBy.value), "ends when its completion came")

        // Past its deadline, the periodic full sync: nothing is left to end unseen
        advanceClock(by: 5 * Self.minute)
        deliverTinyBolusFullStatus()
        XCTAssertEqual(delegate.errors.count, 0, "warned of uncertain delivery")
    }

    /// The same, the completion naming no record - as one in three do: no cancelled bolus is there to take it, so it is
    /// the one sent's
    func testTinyBolusCompletedBeforeItsAnswerWithoutItsRecordEndsOnThatCompletion() throws {
        runTinyBolusSetup()

        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            link.notify("202a0080010006a803ec00f607ab17191000e205")
        }
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        let awaiting = try XCTUnwrap(delegate.batches.last?.events.last?.dose)
        XCTAssertEqual(awaiting.deliveredUnits ?? 0, 0.05, accuracy: 0.001)

        advanceClock(by: 5 * Self.minute)
        deliverTinyBolusFullStatus()
        XCTAssertEqual(delegate.errors.count, 0, "warned of uncertain delivery")
    }

    /// A completion before the answer naming a record past every one known when the bolus went out - but not the one
    /// its answer then gives: not its. It runs on, until its own completion.
    func testCompletionBeforeTheAnswerNamingAnotherRecordLeavesTheBolusRunning() {
        runTinyBolusSetup()

        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            link.notify(Self.completion(delivered: 1, record: 938))
        }
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()

        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 937)
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
        XCTAssertEqual(delegate.batches.count, 1)
    }

    /// A bolus cancelled, the next sent at once, and the cancelled one's completion - naming its record, 490 - comes
    /// before the answer to the next: the cancelled one's, raised to it. The next runs on.
    func testCompletionOfTheCancelledBolusBeforeTheNextOnesAnswerRaisesTheCancelledOne() throws {
        let running = try cancelBolusAtOneStep()

        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            link.notify(Self.completion(delivered: 4, record: 490))
        }
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()

        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 937, "the next runs on")
        let cancelled = try XCTUnwrap(pumpManager.state.awaitingRecord.first { $0.startDate == running?.startDate })
        XCTAssertEqual(cancelled.deliveredUnits, 0.2, accuracy: 0.001, "raised by its completion")
    }

    /// The same completion naming no record: either bolus's. Left to the cancelled one, as with no bolus sent - the next
    /// is not ended on it.
    func testCompletionWithoutItsRecordBeforeTheNextOnesAnswerIsLeftToTheCancelledOne() throws {
        let running = try cancelBolusAtOneStep()

        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            link.notify("2002008004000000")
        }
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()

        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 937, "the next runs on")
        let cancelled = try XCTUnwrap(pumpManager.state.awaitingRecord.first { $0.startDate == running?.startDate })
        XCTAssertEqual(cancelled.deliveredUnits, 0.2, accuracy: 0.001, "raised by its completion")
    }

    /// The completion right after the answer: `completeBolus` looked before the command thread, woken by the answer,
    /// registered the bolus - and the rest of its handling after. It is still the bolus's.
    func testCompletionHandledAsTheBolusIsRegisteredEndsIt() throws {
        runTinyBolusSetup()

        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        XCTAssertNotNil(pumpManager.state.bolusDose)

        pumpManager.noteCompletionWithNoBolusRunning(
            delivered: 0.05,
            record: 937,
            receivedAt: Date.now,
            receivedUptime: pumpManager.uptime()
        )
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        let awaiting = try XCTUnwrap(delegate.batches.last?.events.last?.dose)
        XCTAssertEqual(awaiting.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
    }

    /// A completion before the answer naming no record, of more than the bolus was for: not its. It runs on.
    func testCompletionBeforeTheAnswerOfMoreThanTheBolusLeavesItRunning() {
        runTinyBolusSetup()

        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            link.notify("2002008004000000")
        }
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()

        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 937)
        XCTAssertEqual(delegate.batches.count, 1)
    }

    /// A bolus cancelled moments ago whose command went unanswered - its record number unknown - and a completion naming
    /// a record past every one known before the answer to the next: either's. Left to the cancelled one.
    func testCompletionNamingARecordBeforeTheNextOnesAnswerIsLeftToACancelledUnansweredOne() throws {
        runTinyBolusSetup()
        let cancelled = UnfinalizedDose(
            units: 1,
            duration: 40,
            activationType: .manualNoRecommendation,
            insulinType: nil,
            confirmation: .uncertain,
            startDate: Date.now.addingTimeInterval(-30)
        )
        cancelled.finish(.cancelled, deliveredUnits: 0, endedAt: Date.now.addingTimeInterval(-10))
        pumpManager.state.mutateAwaitingRecord { $0.append(cancelled) }

        // As much as the next was for: could be either's
        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            link.notify(Self.completion(delivered: 1, record: 937))
        }
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()

        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 937, "the next runs on")
        XCTAssertEqual(cancelled.deliveredUnits, 0.05, accuracy: 0.001, "raised by its completion")
    }

    /// The SetBolus unanswered on the slow link, a completion having come meanwhile: still uncertain - running, counted
    /// in full, and warned of - until its record settles it
    func testUnansweredBolusCompletedBeforeTheCommandTimedOutIsStillUncertain() {
        runTinyBolusSetup()

        link.script(CommandType.SET_BOLUS, .timeout) { [unowned self] in
            link.notify(Self.completion(delivered: 1, record: 937))
        }
        guard case .uncertainDelivery? = commandBolus(0.05, activationType: .automatic) else {
            XCTFail("Not uncertain")
            return
        }
        settle()

        XCTAssertNotNil(pumpManager.state.bolusDose)
        XCTAssertTrue(pumpManager.state.deliveryIsUncertain)
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.errors.count, 1, "warned of uncertain delivery")
    }

    /// A completion kept for the bolus sent that turns out to have come before it went out - held up on the way: a
    /// cancelled bolus's, raised to it. The next runs on.
    func testCompletionKeptButReceivedBeforeTheBolusWentOutRaisesTheCancelledOne() throws {
        let running = try cancelBolusAtOneStep()
        let before = (at: Date.now.addingTimeInterval(-1), uptime: pumpManager.uptime() - 1)

        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            pumpManager.noteCompletionWithNoBolusRunning(
                delivered: 0.2,
                record: 937,
                receivedAt: before.at,
                receivedUptime: before.uptime
            )
        }
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        settle()

        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 937, "the next runs on")
        let cancelled = try XCTUnwrap(pumpManager.state.awaitingRecord.first { $0.startDate == running?.startDate })
        XCTAssertEqual(cancelled.deliveredUnits, 0.2, accuracy: 0.001, "raised by its completion")
    }

    /// An answered bolus whose completion never comes: ended unseen at its deadline - by a full status that does not
    /// name its record - counted in full - shown as uncertain - until its record settles it
    func testBolusEndedUnseenIsShownUncertainUntilItsRecordSettlesIt() {
        runTinyBolusSetup()
        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        XCTAssertTrue(uncertain.isEmpty)

        advanceClock(by: 5 * Self.minute)
        link.deliverFullStatus(notification: "200200800100", duringReconnect: false)
        settle()
        link.notify("200001" + "a903ec00")
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(uncertain.map(\.kind), [.bolus])
        XCTAssertEqual(uncertain.first?.cause, .endNotSeen)
        XCTAssertEqual(uncertain.first?.phase, .countedInFull)

        link.script(
            CommandType.GET_RECORD,
            fragments: "33634c010000aa2c01ff9e75aef7ec00a90301a0",
            "33634c02000000f907ab1701000100000000001e",
            "33634c03000000000000000000000000a3507873",
            "33634c040a3e52"
        )
        syncRecords()

        XCTAssertEqual(uncertain.first?.phase, .settled(.byRecord))
        XCTAssertEqual(uncertain.first?.delivered ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(uncertain.first?.record, 937)
    }

    /// An unanswered bolus a progress notification then confirms, cancelled at 0.1 U: the host counts the 0.1 U, not
    /// the full amount - and the notice says so
    func testUnansweredBolusCancelledAfterItsProgressIsShownCountedAsReported() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 489, reservoir: 119.9)
        state.basalDose = runningTempBasal(rate: 0.65, startedAgo: 10 * Self.minute, duration: 30 * Self.minute)
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.SET_BOLUS, .timeout)
        guard case .uncertainDelivery? = commandBolus(1.0) else {
            XCTFail("Not uncertain")
            return
        }
        XCTAssertEqual(uncertain.first?.phase, .countedInFull)

        link.notify("2022100002005c090000000000") // 0.1 U
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()

        XCTAssertEqual(uncertain.map(\.cause), [.unanswered])
        XCTAssertEqual(uncertain.first?.phase, .countedAs(0.1))
    }

    /// The SetBolus of 0.3 U unanswered, cancelled before any progress came, then the patch's completion of it: 0.1 U,
    /// naming record 824 - past the 823 known when it went out, claimed by no answer, no other bolus out. Its own: the
    /// host counts the 0.1 U, not the full 0.3 U, until its record. Still uncertain, and warned of once.
    func testCancelledUnansweredBolusIsCountedAsItsOwnCompletionSays() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose

        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        XCTAssertNil(reports(of: .bolus).last?.deliveredUnits, "counted in full")
        XCTAssertEqual(uncertain.first?.phase, .countedInFull)

        link.notify(Self.completion(delivered: 2, record: 824, patch: "f700"))
        settle()

        let awaiting = reports(of: .bolus).last
        XCTAssertEqual(awaiting?.syncIdentifier, started?.syncIdentifier)
        XCTAssertEqual(awaiting?.isMutable, true, "mutable until its record")
        XCTAssertEqual(awaiting?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(uncertain.map(\.cause), [.unanswered])
        XCTAssertEqual(uncertain.first?.phase, .countedAs(0.1))
        XCTAssertEqual(delegate.errors.count, 1, "warned once")

        // Its record settles it
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: pumpManager.state.pumpTime, amount: 0.3, delivered: 0.1)
        )
        syncRecords()
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(uncertain.first?.phase, .settled(.byRecord))
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The same completion naming record 823, the newest known when the bolus went out: not provably its own - its
    /// amount is raised, but it counts in full until its record
    func testCancelledUnansweredBolusIsCountedInFullWithACompletionNotProvablyItsOwn() {
        startUnansweredBolus()

        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()

        link.notify(Self.completion(delivered: 2, record: 823, patch: "f700"))
        settle()

        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.deliveredUnits ?? 0, 0.1, accuracy: 0.001, "raised")
        XCTAssertNil(reports(of: .bolus).last?.deliveredUnits, "counted in full")
        XCTAssertEqual(uncertain.first?.phase, .countedInFull)
    }

    /// An answered bolus whose completion is lost with the link: the reconnect's full status names record 937, the one
    /// its answer gave it, written - and shows the last bolus completed at 0.05 U. It is over: ended there, at that
    /// amount, not held until its deadline - the next bolus goes out, no warning of uncertain delivery. Its record
    /// finalizes it.
    func testAnsweredBolusWhoseCompletionWasLostEndsOnTheFullStatusNamingItsRecord() {
        runTinyBolusSetup()
        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)

        // Well before its deadline
        advanceClock(by: 30)
        link.deliverFullStatus([
            "2f034401000020ee0d80010080000006a803ec2a",
            "2f03440200f607ab17193000e0052b33a817c5a8",
            "2f0344033b59a903ec00b5d602001905735c"
        ], duringReconnect: true)
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
        let awaiting = reports(of: .bolus).last
        XCTAssertEqual(awaiting?.syncIdentifier, started?.syncIdentifier)
        XCTAssertEqual(awaiting?.isMutable, true, "mutable until its record")
        XCTAssertEqual(awaiting?.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertTrue(uncertain.isEmpty)

        link.script(
            CommandType.GET_RECORD,
            fragments: "33634c010000aa2c01ff9e75aef7ec00a90301a0",
            "33634c02000000f907ab1701000100000000001e",
            "33634c03000000000000000000000000a3507873",
            "33634c040a3e52"
        )
        syncRecords()
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
    }

    /// A full status of an answered bolus still running - record 937 not written yet, 936 the newest - repeating the
    /// last bolus's completion: says nothing of it, which runs on
    func testFullStatusRepeatingTheLastCompletionBeforeTheBolussRecordIsWrittenLeavesItRunning() {
        runTinyBolusSetup()
        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))

        link.deliverFullStatus(notification: "200201" + "800100" + "a803ec00", duringReconnect: false)
        settle()

        XCTAssertNotNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
    }

    /// The deactivation forced while a bolus runs, none of it reported delivered yet: final at once, in full - the old
    /// patch may deliver it still - shown so
    func testBolusRunningAsTheDeactivationIsForcedIsShownSettledInFull() {
        runTinyBolusSetup()
        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        let started = reports(of: .bolus).first
        XCTAssertEqual(pumpManager.state.bolusDose?.deliveredUnits ?? -1, 0, accuracy: 0.001)

        pumpManager.forceDeactivatePatch()
        settle()

        XCTAssertEqual(assertOneFinal(of: started)?.deliveredUnits ?? 0, 0.05, accuracy: 0.001, "in full")
        XCTAssertEqual(uncertain.map(\.cause), [.patchDeactivated])
        XCTAssertEqual(uncertain.first?.phase, .settled(.byEstimate))
        XCTAssertEqual(uncertain.first?.delivered ?? 0, 0.05, accuracy: 0.001)
    }

    /// State saved as a dose was finalized, before its uncertain delivery was settled, and one whose dose is gone: both
    /// settled as the state is read back - what is not known not claimed. A final dose is not noted.
    func testUncertainDeliveriesLeftUnsettledAreSettledAsTheStateIsReadBack() throws {
        runTinyBolusSetup()
        let finalized = UnfinalizedDose(units: 1, duration: 40, activationType: .automatic, insulinType: nil, startDate: Date.now.addingTimeInterval(-600))
        finalized.noteCommand(sentAt: finalized.startDate, uptime: nil, sequence: 936)
        let gone = UnfinalizedDose(units: 2, duration: 80, activationType: .automatic, insulinType: nil, startDate: Date.now.addingTimeInterval(-300))
        gone.noteCommand(sentAt: gone.startDate, uptime: nil, sequence: 936)
        pumpManager.withDoseReportLock {
            pumpManager.noteUncertainDelivery(.bolus, .endNotSeen, of: finalized)
            pumpManager.noteUncertainDelivery(.bolus, .unanswered, of: gone)
        }

        finalized.finish(.completionNotSeen, endedAt: nil)
        XCTAssertTrue(finalized.finalize(deliveredUnits: 0.5, endDate: nil))
        pumpManager.state.mutateAwaitingRecord { $0.append(finalized) }
        XCTAssertEqual(uncertain.map(\.phase), [.countedInFull, .countedInFull])

        let readBack = MedtrumPumpState(rawValue: pumpManager.state.rawValue)
        let phases = readBack.uncertainDeliveries.map(readBack.phase(of:))
        XCTAssertEqual(phases, [.settled(.final), .settled(.untracked)])
        XCTAssertEqual(readBack.uncertainDeliveries.first?.delivered ?? 0, 0.5, accuracy: 0.001)

        let late = UnfinalizedDose(units: 3, duration: 120, activationType: .automatic, insulinType: nil, startDate: Date.now)
        late.finish(.completionNotSeen, endedAt: nil)
        XCTAssertTrue(late.finalize(deliveredUnits: 3, endDate: nil))
        pumpManager.withDoseReportLock {
            pumpManager.noteUncertainDelivery(.bolus, .endNotSeen, of: late)
        }
        XCTAssertEqual(uncertain.count, 2, "a final dose is not noted: nothing would settle it")
    }

    /// Saved with the state and read back; the settled ones cleared by the user, the others kept; no more than
    /// `uncertainDeliveriesKept`, the oldest settled going first
    func testUncertainDeliveriesAreSavedClearedAndCapped() {
        runTinyBolusSetup()
        let settled = UnfinalizedDose(
            units: 1,
            duration: 40,
            activationType: .automatic,
            insulinType: nil,
            startDate: Date.now.addingTimeInterval(-600)
        )
        settled.noteCommand(sentAt: settled.startDate, uptime: nil, sequence: 936)
        let pending = UnfinalizedDose(
            units: 2,
            duration: 80,
            activationType: .automatic,
            insulinType: nil,
            startDate: Date.now.addingTimeInterval(-60)
        )
        pending.noteCommand(sentAt: pending.startDate, uptime: nil, sequence: 936)
        pumpManager.withDoseReportLock {
            pumpManager.noteUncertainDelivery(.bolus, .endNotSeen, of: settled)
            pumpManager.noteUncertainDelivery(.bolus, .unanswered, of: pending)
            pumpManager.noteUncertainDelivery(.bolus, .endNotSeen, of: pending)
        }
        XCTAssertEqual(uncertain.map(\.cause), [.endNotSeen, .unanswered], "once per dose, the first cause")
        // Tracked, still running: not settled as the state is read back
        pumpManager.state.mutateAwaitingRecord { $0.append(pending) }

        // Its record never read: final from our estimate once it has waited the most
        settled.finish(.completionNotSeen, endedAt: nil)
        pumpManager.state.mutateAwaitingRecord { $0.append(settled) }
        advanceClock(by: MedtrumPumpManager.awaitingRecordMaximumWait + Self.minute)
        pumpManager.finalizeOverdueAwaitingDoses()
        XCTAssertEqual(uncertain.first?.phase, .settled(.byEstimate))
        XCTAssertEqual(uncertain.first?.delivered ?? 0, 1, accuracy: 0.001, "counted in full")

        let readBack = MedtrumPumpState(rawValue: pumpManager.state.rawValue)
        XCTAssertEqual(readBack.uncertainDeliveries, pumpManager.state.uncertainDeliveries)

        pumpManager.clearSettledUncertainDeliveries()
        XCTAssertEqual(uncertain.map(\.phase), [.countedInFull])

        for index in 0 ..< MedtrumPumpManager.uncertainDeliveriesKept + 5 {
            let dose = UnfinalizedDose(
                units: 1,
                duration: 40,
                activationType: .automatic,
                insulinType: nil,
                startDate: Date.now.addingTimeInterval(TimeInterval(index * 60))
            )
            pumpManager.withDoseReportLock {
                pumpManager.noteUncertainDelivery(.bolus, .endNotSeen, of: dose)
            }
        }
        XCTAssertEqual(uncertain.count, MedtrumPumpManager.uncertainDeliveriesKept)
        XCTAssertFalse(
            pumpManager.state.uncertainDeliveries.contains { abs($0.sentAt.timeIntervalSince(pending.startDate)) < 1 },
            "none settled: the oldest went"
        )
    }

    /// Patch 236 with 1.25 U/h running, every record up to 936 read - `testTinyBolusEndsOnItsCompletionAndIsFinalizedByItsRecordNumber`
    private func runTinyBolusSetup() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75.35)
        state.basalDose = runningTempBasal(
            rate: 1.25,
            startedAgo: 3,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_084_662)
        )
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_084_665))
        makeManager(state)
    }

    /// The periodic full sync of that test, record 937 written, its bolus field repeating the completion
    private func deliverTinyBolusFullStatus() {
        link.deliverFullStatus([
            "2f034401000020ee0d80010080000006a803ec2a",
            "2f03440200f607ab17193000e0052b33a817c5a8",
            "2f0344033b59a903ec00b5d602001905735c"
        ])
        settle()
    }

    /// The 1 U bolus of `testCancelledBolusIsRaisedByItsCompletionAndFinalizedWithoutItsRecord`, record 490, cancelled
    /// at 0.1 U, its completion yet to come. Returns it as the host was first told of it.
    private func cancelBolusAtOneStep() throws -> DoseEntry? {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 489, reservoir: 119.9)
        state.basalDose = runningTempBasal(rate: 0.65, startedAgo: 10 * Self.minute, duration: 30 * Self.minute)
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f1303000000ea01ec0059afa9174700")
        XCTAssertNil(commandBolus(1.0))
        link.notify("2022100002005c090000000000") // 0.1 U
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return nil
        }
        settle()

        let running = delegate.batches.first?.events.first?.dose
        let cancelled = try XCTUnwrap(pumpManager.state.awaitingRecord.first { $0.startDate == running?.startDate })
        XCTAssertEqual(cancelled.deliveredUnits, 0.1, accuracy: 0.001)
        return running
    }

    /// A completion notification of `delivered` steps of 0.05 U, naming `record` of patch 236 - or `patch`, its low two
    /// bytes in hex - as the newest
    static func completion(delivered: UInt8, record: Int, patch: String = "ec00") -> String {
        "200211" + "80" + String(format: "%02x", delivered) + "00" +
            String(format: "%02x%02x", record & 0xFF, record >> 8) + patch + "0000000000"
    }

    /// 2026-07-31 01:41:10 - 01:42:29 (`user.txt:11229-11295`), patch 236: 2 U while a 2.5 U/h temp basal runs.
    /// The SetBolus answer, progress in 0.1 U steps, the completion, then its record (built: no record was read that day).
    func testBolusProgressesCompletesAndIsFinalizedByItsRecord() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        let tempBasal = runningTempBasal(rate: 2.5, startedAgo: 10 * Self.minute, duration: 2 * Self.hour)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")

        XCTAssertNil(commandBolus(2.0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x28), "09132800012800002800")

        // Reported as running straight away, without replacing what the host holds
        XCTAssertEqual(delegate.batches.count, 1)
        let started = delegate.batches.first
        XCTAssertEqual(started?.replacePendingEvents, false)
        XCTAssertEqual(started?.events.count, 1)

        let running = started?.events.first?.dose
        XCTAssertEqual(running?.type, .bolus)
        XCTAssertEqual(running?.isMutable, true)
        XCTAssertEqual(running?.programmedUnits ?? 0, 2.0, accuracy: 0.001)
        XCTAssertNil(running?.deliveredUnits)

        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
        guard case .inProgress? = delegate.statusUpdates.last?.status.bolusState else {
            XCTFail("Status does not show the bolus: \(String(describing: delegate.statusUpdates.last?.status.bolusState))")
            return
        }

        // The record the bolus will be written under, and its patch start: allocated, not written yet
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 123)
        XCTAssertEqual(pumpManager.state.bolusDose?.pumpStartTime, Date.fromMedtrumSeconds(0x17A8_8697))
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 122)

        guard let reporter = pumpManager.createBolusProgressReporter(reportingOn: DispatchQueue.main) else {
            XCTFail("No progress reporter for the running bolus")
            return
        }

        link.notify("2022100002002a0d0000000000") // 0.1 U
        link.notify("202210000400280d0000000000") // 0.2 U
        link.notify("202210001400180d0000000000") // 1.0 U
        link.notify("202210002600060d0000000000") // 1.9 U
        settle()

        XCTAssertEqual(delegate.batches.count, 1, "progress is not reported to the host")
        XCTAssertEqual(pumpManager.state.bolusDose?.deliveredUnits ?? 0, 1.9, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.reservoir, 166.7, accuracy: 0.001)
        XCTAssertEqual(reporter.progress.deliveredUnits, 1.9, accuracy: 0.001)
        XCTAssertFalse(reporter.progress.isComplete)

        // Completed, 2.0 U, and the patch is now at record 123
        link.notify("202211802800040d7b00ec000000000000")
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 123)
        XCTAssertTrue(reporter.progress.isComplete)
        XCTAssertEqual(reporter.progress.deliveredUnits, 2.0, accuracy: 0.001)
        guard case .noBolus? = delegate.statusUpdates.last?.status.bolusState else {
            XCTFail("Status still shows a bolus")
            return
        }

        XCTAssertEqual(delegate.batches.count, 2)
        let completed = delegate.batches.last
        XCTAssertEqual(completed?.replacePendingEvents, true)
        XCTAssertEqual(completed?.events.map(\.dose?.type), [.tempBasal, .bolus])

        // The running temp basal goes along, since the batch replaces everything the host holds as mutable
        let stillRunning = completed?.events.first?.dose
        XCTAssertEqual(stillRunning?.isMutable, true)
        XCTAssertEqual(stillRunning?.startDate, tempBasal.startDate)
        XCTAssertEqual(stillRunning?.unitsPerHour ?? 0, 2.5, accuracy: 0.001)

        // Same dose, same identity, still mutable: it waits on its record, counting what the patch said it delivered
        let awaiting = completed?.events.last?.dose
        XCTAssertEqual(awaiting?.isMutable, true)
        XCTAssertEqual(awaiting?.syncIdentifier, running?.syncIdentifier)
        XCTAssertEqual(awaiting?.deliveredUnits ?? 0, 2.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(awaiting?.endDate ?? .distantFuture, Date.now)

        XCTAssertEqual(delegate.reservoirReads.count, 1)
        XCTAssertEqual(delegate.reservoirReads.last?.units ?? 0, 166.6, accuracy: 0.001)

        // Its record, by number: final with what the patch says it delivered, ending when it completed
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: Date.fromMedtrumSeconds(0x17A8_8697), amount: 2.0, delivered: 2.0)
        )
        syncRecords()

        assertOneFinal(of: running)
        let final = finals(of: running).last
        XCTAssertEqual(final?.startDate, running?.startDate)
        XCTAssertEqual(final?.programmedUnits ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(final?.endDate, awaiting?.endDate)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 123)
        XCTAssertEqual(delegate.errors.count, 0)
    }

    /// 2026-07-31 22:47:19 - 22:47:28 (`user.txt:16885-16899`), patch 236: 1 U cancelled while 0.65 U/h runs. Here
    /// the 0.2 U progress reaches us only after the cancel: the patch's completion of the cancelled bolus (type 32)
    /// raises the amount the cancel kept. Its record can't be read, and it is finalized at that amount 15 min later.
    func testCancelledBolusIsRaisedByItsCompletionAndFinalizedWithoutItsRecord() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 489, reservoir: 119.9)
        state.basalDose = runningTempBasal(rate: 0.65, startedAgo: 10 * Self.minute, duration: 30 * Self.minute)
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f1303000000ea01ec0059afa9174700")
        XCTAssertNil(commandBolus(1.0))
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 490)

        link.notify("2022100002005c090000000000") // 0.1 U

        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        let cancel = commandCancelBolus()
        guard case let .success(returned)? = cancel else {
            XCTFail("Cancel failed: \(String(describing: cancel))")
            return
        }
        XCTAssertNil(returned, "the cancelled dose goes to the host as an event, not as the result")
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.CANCEL_BOLUS])
        XCTAssertEqual(link.writes.last?.encoded(sequence: 0x04), "0614040001f300")

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertNil(pumpManager.state.cancelingBolusSince)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)

        XCTAssertEqual(delegate.batches.count, 2)
        let running = delegate.batches.first?.events.first?.dose
        let cancelled = delegate.batches.last
        XCTAssertEqual(cancelled?.replacePendingEvents, true)
        XCTAssertEqual(cancelled?.events.map(\.dose?.type), [.tempBasal, .bolus])

        // Stopped at the last progress, waiting on its record under the identity it was started with
        let awaiting = cancelled?.events.last?.dose
        XCTAssertEqual(awaiting?.isMutable, true)
        XCTAssertEqual(awaiting?.syncIdentifier, running?.syncIdentifier)
        XCTAssertEqual(awaiting?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)

        // The 0.2 U progress, late: no bolus runs to take it
        link.notify("2022100004005a090000000000")
        settle()
        XCTAssertEqual(delegate.batches.count, 2)

        // The patch's own completion of the cancelled bolus, 0.2 U, and the record it wrote for it
        link.notify("200211a00400ea01ec000000000000")
        settle()

        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 490)
        XCTAssertEqual(delegate.batches.count, 3)
        let raised = delegate.batches.last?.events.first { $0.raw == delegate.batches.first?.events.first?.raw }?.dose
        XCTAssertEqual(raised?.isMutable, true)
        XCTAssertEqual(raised?.deliveredUnits ?? 0, 0.2, accuracy: 0.001)

        // Record 490 comes back garbled, twice: skipped
        let garbled = FakeMedtrumLink.Answer.garbled(
            PatchBytes.bolusRecord(sequence: 490, patchId: 236, start: Date.fromMedtrumSeconds(0x17A9_AF59), amount: 1, delivered: 0.2)
        )
        link.script(CommandType.GET_RECORD, garbled)
        link.script(CommandType.GET_RECORD, garbled)
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 490)
        XCTAssertEqual(finals(of: running).count, 0, "not 15 min yet")

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        assertOneFinal(of: running)
        let final = finals(of: running).last
        XCTAssertEqual(final?.programmedUnits ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The same bolus cancelled before any progress, and the patch's completion of it says 0 U: nothing to raise, but
    /// what the patch said it delivered is logged, with its record
    func testCancelledBolusCompletionOfZeroIsLogged() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 489, reservoir: 119.9)
        state.basalDose = runningTempBasal(rate: 0.65, startedAgo: 10 * Self.minute, duration: 30 * Self.minute)
        state.basalState = .tempBasal
        makeManager(state)
        MedtrumLogger.pumpManager = pumpManager
        defer { MedtrumLogger.pumpManager = nil }

        link.script(CommandType.SET_BOLUS, fragments: "0f1303000000ea01ec0059afa9174700")
        XCTAssertNil(commandBolus(1.0))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        XCTAssertEqual(delegate.batches.count, 2)

        link.notify("200211a00000ea01ec000000000000")
        settle()

        XCTAssertEqual(delegate.batches.count, 2, "nothing raised")
        XCTAssertTrue(delegate.logEntries.contains { entry in
            entry.message.contains("Completion of 0.0 U after the cancel of the bolus of") &&
                entry.message.contains("record #490: keeping its 0.0 U")
        })
    }

    /// 2026-08-27 03:00:55 - 03:05:35 (`user.txt:67542-67612`), patch 247: a SetBolus of 0.3 U gets no answer, and the
    /// patch never runs it. Four full statuses follow, each repeating the previous bolus's completion of 0.1 U, and
    /// the record number stays at 823. Counted in full until every record past 823 the patch told of since its deadline
    /// was read, none its: it never ran, final at 0 U.
    func testUnansweredBolusThePatchNeverRanIsFinalizedAtZero() {
        startUnansweredBolus()

        // The reconnect's full status, 13 s later: the bolus field is the previous bolus's completion
        link.deliverFullStatus([
            "2f030101000020ee0d800200800000063703f76a",
            "2f03010200ca31cc172f00009f092493c917d574",
            "2f030103ab563703f700c3a102009c08ac8b"
        ], duringReconnect: true)
        settle()

        XCTAssertNotNil(pumpManager.state.bolusDose, "a full status never confirms nor ends it before its deadline")
        XCTAssertEqual(pumpManager.state.bolusDose?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(uncertain.map(\.kind), [.bolus])
        XCTAssertEqual(uncertain.first?.cause, .unanswered)
        XCTAssertEqual(uncertain.first?.phase, .countedInFull)

        // 2:53 after the command, past its deadline of 0.3 U at 0.5 U/min and 2 min: the next full status ends it
        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(delegate.statusUpdates.last?.status.deliveryIsUncertain, false)
        let ended = delegate.batches.last?.events.last?.dose
        XCTAssertEqual(ended?.type, .bolus)
        XCTAssertEqual(ended?.isMutable, true)
        XCTAssertNil(ended?.deliveredUnits, "counted in full until its record")

        for fragments in [
            ["2f030101000020ee0d800200800000063703f76a", "2f03010200ca31cc172f40009b092493c917d087", "2f0301038b563703f700aaa2020098089963"],
            ["2f030101000020ee0d800200800000063703f76a", "2f03010200ca31cc172f40009b092493c917da33", "2f030103bb563703f700cda202009808b617"]
        ] {
            link.deliverFullStatus(fragments, duringReconnect: true)
        }
        settle()

        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 823, "no record was allocated")
        XCTAssertEqual(delegate.errors.count, 1, "warned once, when the command went unanswered")
        XCTAssertEqual(delegate.alerts.count, 0)

        // Every record read, none its, 15 min after it ended: final at 0 U, nothing to tell the user
        advanceClock(by: 15 * Self.minute)
        syncRecords()

        let started = delegate.batches.first?.events.first?.dose
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(uncertain.count, 1)
        XCTAssertEqual(uncertain.first?.phase, .settled(.neverRan))
        XCTAssertEqual(uncertain.first?.delivered, 0)
    }

    /// The same unanswered SetBolus, had the patch run it: its record is the next one after the 823 known when it went
    /// out, at its amount and near when it went out - and finalizes it, with no warning
    func testUnansweredBolusIsFinalizedByTheRecordAfterTheLastKnown() {
        startUnansweredBolus()
        let patchSentAt = pumpManager.state.pumpTime

        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        // The patch has written record 824
        link.notify("20000138" + "03f700")
        settle()
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 824)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(2), amount: 0.3, delivered: 0.3)
        )
        syncRecords()

        let started = delegate.batches.first?.events.first?.dose
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized bolus"), true)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertEqual(uncertain.count, 1)
        XCTAssertEqual(uncertain.first?.cause, .unanswered)
        XCTAssertEqual(uncertain.first?.phase, .settled(.byRecord))
        XCTAssertEqual(uncertain.first?.delivered ?? 0, 0.3, accuracy: 0.001)
    }

    /// A SetBolus answer garbled on the air is no answer either: the patch may have run it, as with none at all - here it
    /// did not, its record number staying at 823
    func testGarbledBolusAnswerIsAnUnansweredCommand() {
        let state = activePatchState(patchId: 247, scheduledRate: 0.6, sequence: 823, reservoir: 120)
        makeManager(state)

        link.script(CommandType.SET_BOLUS, .garbled(["0f13280000007b00ec009786a8178900"]))

        XCTAssertTrue(isUncertainDelivery(commandBolus(0.3)))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertEqual(pumpManager.state.bolusDose?.confirmation, .uncertain)
        XCTAssertNil(pumpManager.state.bolusDose?.recordSequence)
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.isMutable, true)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)

        // Not sent again: the next bolus is refused while this one runs
        XCTAssertNotNil(commandBolus(0.3))

        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()

        let started = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
    }

    /// A record under the bolus's number is its record, though it starts elsewhere than its answer said: the answer
    /// claimed the number - it finalizes the bolus, the difference only logged
    func testRecordWithTheBolusNumberButAnotherStartFinalizesIt() {
        let started = completeAnsweredBolus()
        MedtrumLogger.pumpManager = pumpManager
        defer { MedtrumLogger.pumpManager = nil }

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(
                sequence: 123,
                patchId: 236,
                start: Date.fromMedtrumSeconds(0x17A8_8697).addingTimeInterval(5 * Self.minute),
                amount: 2.0,
                delivered: 1.0
            )
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized bolus"), true)
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 1.0, accuracy: 0.001, "what its record said")
        XCTAssertTrue(delegate.logEntries.contains { $0.message.contains("finalizing it with it, by its number") })
    }

    /// A record under the bolus's number, of another amount: its record all the same
    func testRecordWithTheBolusNumberButAnotherAmountFinalizesIt() {
        let started = completeAnsweredBolus()
        MedtrumLogger.pumpManager = pumpManager
        defer { MedtrumLogger.pumpManager = nil }

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: Date.fromMedtrumSeconds(0x17A8_8697), amount: 1.5, delivered: 1.5)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized bolus"), true)
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 1.5, accuracy: 0.001, "what its record said")
        XCTAssertTrue(delegate.logEntries.contains { $0.message.contains("finalizing it with it, by its number") })
    }

    /// Device 2026-10-22 13:52: the patch wrote a low-reservoir alarm as the bolus ran, under the number its answer
    /// named - the bolus's own record the next one, at its answered start. Finalized by it in the same read, with what it
    /// says, not 15 min later from our estimate - and that number claimed as an answered one is
    func testBolusRecordPastAnAlarmThatTookItsNumberFinalizesIt() {
        let started = completeAnsweredBolus()
        pumpManager.state.currentSequenceNumber = 124

        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 123, patchId: 236))
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: Date.fromMedtrumSeconds(0x17A8_8697), amount: 2.0, delivered: 1.95)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 124)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 124 }?.outcome?.hasPrefix("finalized bolus"), true)
        assertOneFinal(of: started)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 1.95, accuracy: 0.001, "what its record said")
        XCTAssertTrue(pumpManager.state.answeredBolusRecords.contains(124))
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// The same, the record after the alarm of another amount: not the bolus's
    func testBolusRecordPastAnAlarmThatTookItsNumberOfAnotherAmountIsNotTaken() {
        assertRecordPastAnAlarmIsNotTaken(start: Date.fromMedtrumSeconds(0x17A8_8697), amount: 1.5)
    }

    /// The same, the record after the alarm from another start: not the bolus's
    func testBolusRecordPastAnAlarmThatTookItsNumberFromAnotherStartIsNotTaken() {
        assertRecordPastAnAlarmIsNotTaken(start: Date.fromMedtrumSeconds(0x17A8_8697 + 5), amount: 2.0)
    }

    /// The alarm read, the app killed before the bolus's record could be: the next run takes it all the same
    func testBolusRecordPastAnAlarmThatTookItsNumberIsTakenAfterARestartBetweenThem() throws {
        let started = completeAnsweredBolus()
        pumpManager.state.currentSequenceNumber = 124

        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 123, patchId: 236))
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 123)
        XCTAssertTrue(finals(of: started).isEmpty)

        try restart(from: delegate.savedState)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.answeredRecordTaken, true, "saved with it")
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: Date.fromMedtrumSeconds(0x17A8_8697), amount: 2.0, delivered: 1.95)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 124)
        let final = try XCTUnwrap(finals(of: started).last)
        XCTAssertEqual(final.deliveredUnits ?? 0, 1.95, accuracy: 0.001, "what its record said")
    }

    private func assertRecordPastAnAlarmIsNotTaken(start: Date, amount: Double, line: UInt = #line) {
        let started = completeAnsweredBolus()
        pumpManager.state.currentSequenceNumber = 124

        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 123, patchId: 236))
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: start, amount: amount, delivered: amount)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 124, line: line)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 124 }?.outcome, "unmatched", line: line)
        XCTAssertTrue(finals(of: started).isEmpty, line: line)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.answeredRecordTaken, true, line: line)
    }

    /// 2 U answered as record 123 is cancelled at 0.4 U, the link lost before the patch's completion of it (which
    /// carries record 123) came in; a 2 U SetBolus right after goes unanswered - the record number known then still 122
    /// - and the patch runs it (record 124). Record 123 finalizes the cancelled bolus by number. The app is then killed
    /// with that final handed over and the cursor not yet saved past 123: read again after the restart, record 123 is
    /// still the cancelled bolus's - its answer claimed the number - not the unanswered one's, though it has its amount
    /// and starts near when that one went out. Record 124 finalizes the unanswered one.
    func testRecordOfAnAnsweredBolusReadAgainAfterARestartIsNotTakenForAnUnansweredOne() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let (cancelled, unanswered) = try cancelledThenUnansweredBolus(patchSentAt: patchSentAt)

        // The host has yet to confirm the final when the app is killed
        delegate.batchReply = .hold
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: patchSentAt, amount: 2.0, delivered: 0.4)
        )
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()

        assertOneFinal(of: cancelled)
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)

        // Saved as the final went out, before the cursor moved past 123
        var raw = pumpManager.state.rawValue
        raw["syncedSequenceNumber"] = 122
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        delegate.batchReply = .acknowledge
        makeManager(MedtrumPumpState(rawValue: saved))

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
        assertOneFinal(of: unanswered)
        XCTAssertEqual(finals(of: unanswered).last?.deliveredUnits ?? 0, 2.0, accuracy: 0.001)
        // Sent again until the host stores it, the same final
        XCTAssertEqual(Set(finals(of: cancelled).map(\.deliveredUnits)), [0.4])
    }

    /// The same two boluses, no record readable for an hour: the cancelled one is finalized from our estimate at the
    /// maximum wait, and the host stores it. Record 123, read before the unanswered one's maximum wait is up, is still
    /// the cancelled bolus's - not the unanswered one's.
    func testRecordOfAnAnsweredBolusFinalizedWithoutItIsNotTakenForAnUnansweredOne() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let (cancelled, unanswered) = try cancelledThenUnansweredBolus(patchSentAt: patchSentAt)

        // An hour on from the cancel, the patch out of reach: the cancelled bolus is given up on, not the other yet
        advanceClock(by: 57 * Self.minute)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()
        assertOneFinal(of: cancelled)
        XCTAssertEqual(finals(of: unanswered).count, 0)
        XCTAssertEqual(pumpManager.state.awaitingRecord.filter { !$0.isFinalized }.count, 1)

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
        assertOneFinal(of: unanswered)
        XCTAssertEqual(finals(of: unanswered).last?.deliveredUnits ?? 0, 2.0, accuracy: 0.001)
    }

    /// 2 U answered as record 123, every record read up to 122 as the patch last said, cancelled at 0.4 U - and the link
    /// lost before the patch's completion of it, which would have said it wrote 123. The cursor at 122 says nothing of
    /// that record: not caught up, so 15 min on it is not finalized without it - only once it waited 60 min.
    func testDoseEndedWithTheLinkLostWaitsTheMaximumForItsRecord() throws {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        confirmRecordSequence()

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
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, pumpManager.state.currentSequenceNumber)

        // The loop's syncs fail: the doses waiting are settled without the link
        let settleUnread = {
            self.link.onQueue {
                RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
            }
            self.settle()
        }

        advanceClock(by: 16 * Self.minute)
        settleUnread()
        XCTAssertEqual(finals(of: cancelled).count, 0)

        advanceClock(by: 44 * Self.minute)
        settleUnread()
        assertOneFinal(of: cancelled)
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
    }

    /// The same unanswered SetBolus, past its deadline: a full status that fails validation - here a reservoir level
    /// garbled out of range - shows nothing, and neither ends the bolus nor counts as a sync. A valid one ends it.
    func testFullStatusThatFailsValidationDoesNotEndAnOverdueBolus() {
        startUnansweredBolus()
        advanceClock(by: 173)
        let lastSync = pumpManager.state.lastSync

        var garbled = SynchronizePacketResponse(
            state: .active,
            bolus: BolusData(type: 0, completed: true, delivered: 0.1),
            reservoir: 6553.5,
            storage: StorageData(sequence: 823, patchId: 247),
            activeAlarms: []
        )
        garbled.receivedUptime += uptimeOffset.value
        link.onQueue {
            self.pumpManager.handleStatus(garbled, duringReconnect: false, fullSync: true)
        }
        settle()

        XCTAssertNotNil(pumpManager.state.bolusDose, "still running")
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.lastSync, lastSync)
        XCTAssertTrue(pumpManager.isRunningBolusOverdue)

        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertGreaterThan(pumpManager.state.lastSync, lastSync)
    }

    /// A bolus whose end was never seen (the link lost meanwhile) stays running, and dosing refused, until a full status
    /// settles it: once past its deadline a heartbeat asks for one, sooner than the freshness interval but not on every
    /// heartbeat - while before its deadline, a running bolus keeps heartbeats from syncing at all
    func testHeartbeatAsksForAFullStatusOnceTheRunningBolusIsOverdue() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        settle()
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)

        pumpManager.state.lastSync = Date.now.addingTimeInterval(-3 * Self.minute)
        XCTAssertNil(pumpManager.heartbeatSync(), "not while it may still be delivering")

        // 2 U at 0.5 U/min + 2 min
        advanceClock(by: 6 * Self.minute + 1)
        XCTAssertTrue(pumpManager.isRunningBolusOverdue)
        XCTAssertEqual(pumpManager.heartbeatSync(), .full)

        pumpManager.state.lastSync = Date.now.addingTimeInterval(-90)
        XCTAssertEqual(pumpManager.heartbeatSync(), .full, "sooner than the freshness interval")

        pumpManager.state.lastSync = Date.now.addingTimeInterval(-30)
        XCTAssertNil(pumpManager.heartbeatSync(), "not on every heartbeat")
    }

    /// 2026-10-30: the patch delivers about 1 U/min - 3 U took 180 s, 2 U 154 s. The running bolus's end, which the host
    /// stores as its duration, is estimated at that rate.
    func testRunningBolusEndIsEstimatedAtTheObservedRate() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75.35)
        alignPatchClock(state, patchTime: Self.patchTime(397_084_665))
        makeManager(state)
        XCTAssertEqual(pumpManager.estimatedDuration(toBolus: 2), 120, accuracy: 0.001)

        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(2))
        settle()

        let started = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(started?.isMutable, true)
        XCTAssertEqual(started.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 120, accuracy: 0.001)
    }
}

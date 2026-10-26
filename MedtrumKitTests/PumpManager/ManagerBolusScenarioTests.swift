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
        XCTAssertEqual(finals(of: started).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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

    /// The patch deactivated while a bolus runs: final at once from its last amount, shown so
    func testBolusRunningAsThePatchIsDeactivatedIsShownSettledFromOurEstimate() {
        runTinyBolusSetup()
        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05, activationType: .automatic))

        pumpManager.forceDeactivatePatch()
        settle()

        XCTAssertEqual(uncertain.map(\.cause), [.patchDeactivated])
        XCTAssertEqual(uncertain.first?.phase, .settled(.byEstimate))
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
    private static func completion(delivered: UInt8, record: Int, patch: String = "ec00") -> String {
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

        XCTAssertEqual(finals(of: running).count, 1)
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

        XCTAssertEqual(finals(of: running).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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

        XCTAssertEqual(finals(of: cancelled).count, 1)
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
        XCTAssertEqual(finals(of: unanswered).count, 1)
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
        XCTAssertEqual(finals(of: cancelled).count, 1)
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
        XCTAssertEqual(finals(of: unanswered).count, 1)
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
        XCTAssertEqual(finals(of: cancelled).count, 1)
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

        XCTAssertEqual(finals(of: started).count, 1)
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

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
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

        XCTAssertEqual(finals(of: started).count, 1)
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

        XCTAssertEqual(finals(of: started).count, 1)
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

        XCTAssertEqual(finals(of: started).count, 1)
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

        XCTAssertEqual(finals(of: started).count, 1)
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

        XCTAssertEqual(finals(of: second).count, 1)
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

        XCTAssertEqual(finals(of: started).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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
        XCTAssertEqual(finals(of: takenOver).count, 1)
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
        XCTAssertEqual(finals(of: cancelled).count, 1)
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
        XCTAssertEqual(finals(of: takenOver).count, 1)
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
        XCTAssertEqual(finals(of: started).count, 1)
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

        XCTAssertEqual(finals(of: started).count, 1)
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

    // MARK: - A bolus record matching no dose of ours

    /// Record 123, a bolus of 1.0 U delivered that no dose of ours is - one written as the app was killed before the host
    /// saved it pending, another app's: not imported, the user told to add it - once, read again or after a restart
    func testBolusRecordMatchingNoDoseOfOursIsToldOfOnce() throws {
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 123, reservoir: 168.6)
        state.syncedSequenceNumber = 122
        makeManager(state)
        let start = pumpManager.state.pumpTime.addingTimeInterval(-10 * Self.minute)
        let record = PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: start, amount: 1.0, delivered: 1.0)

        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 123 }?.outcome, "unmatched")
        XCTAssertTrue(reports(of: .bolus).isEmpty, "not imported")
        XCTAssertEqual(delegate.alerts.count, 1)
        let alert = try XCTUnwrap(delegate.alerts.first)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted"))
        XCTAssertEqual(alert.foregroundContent?.body.contains("a bolus of 1 U delivered at"), true)

        // Read again
        pumpManager.state.syncedSequenceNumber = 122
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 1, "told of once")

        // And after a restart
        try restart(from: delegate.savedState)
        pumpManager.state.syncedSequenceNumber = 122
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 123 }?.outcome, "unmatched")
        XCTAssertEqual(delegate.alerts.count, 0, "told of before the restart")
    }

    /// Unmatched bolus records the user is not told of: one that delivered nothing, and one written before this state
    /// took up the patch - the backlog of its first status, another app's
    func testBolusRecordMatchingNoDoseOfOursThatDeliveredNothingOrPredatesThePatchIsNotToldOf() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 124, reservoir: 168.6)
        state.syncedSequenceNumber = 122
        state.sessionStartSequence = 123
        makeManager(state)
        let start = pumpManager.state.pumpTime.addingTimeInterval(-10 * Self.minute)

        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: start, amount: 1.0, delivered: 1.0))
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: start.addingTimeInterval(60), amount: 1.0, delivered: 0)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 124)
        XCTAssertEqual(pumpManager.recordStore.records.filter { $0.outcome == "unmatched" }.count, 2)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The record that finalized a bolus whose command went unanswered, read again - the app killed before the cursor
    /// past it was saved, say: taken as it was, no other bolus's, and nothing the host is missing
    func testRecordOfAnUnansweredBolusReadAgainIsNotToldOf() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline()
        link.notify("20000138" + "03f700")
        settle()
        let record = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: Date.fromMedtrumSeconds(0x17CC_31CB).addingTimeInterval(2),
            amount: 0.3,
            delivered: 0.3
        )
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertTrue(pumpManager.state.awaitingRecord.isEmpty, "the host stored the final")

        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, record)
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome, "answered bolus finalized already")
        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The record of a bolus of ours final from our estimate - its answer lost, the records unread for an hour, counted
    /// in full, and the user told so - read after all: it matches no dose any more, and is that one's, at its amount near
    /// when it went out. Nothing more to tell.
    func testRecordOfABolusFinalFromOurEstimateIsNotToldOf() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline(confirmingRecords: false)
        advanceClock(by: 60 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), ["com.nightscout.medtrumkit.bolus-counted-as-delivered"])
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.count, 1)

        link.notify("20000138" + "03f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(
                sequence: 824,
                patchId: 247,
                start: Date.fromMedtrumSeconds(0x17CC_31CB).addingTimeInterval(2),
                amount: 0.3,
                delivered: 0.3
            )
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome, "unmatched")
        XCTAssertEqual(delegate.alerts.count, 1, "nothing more")
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained one record")
    }

    // MARK: - The record of a bolus final from our estimate, read after all

    /// The bolus of 1 U of `testCancelledBolusIsRaisedByItsCompletionAndFinalizedWithoutItsRecord`, cancelled at 0.1 U,
    /// the patch's completion of it lost; its record 490 skipped, it goes final at 0.1 U from our estimate. Read after
    /// all, the record says 0.5 U: the host is missing 0.4 U for good - the user is told, once
    func testCancelledBolusFinalFromOurEstimateBelowItsRecordIsToldOfOnce() throws {
        let cancelled = cancelBolusAndFinalizeItFromOurEstimate(progress: "2022100002005c090000000000")
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.first?.recordSequence, 490)

        readRecordOfTheCancelledBolusAgain(delivered: 0.5)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 490 }?.outcome, "answered bolus finalized already")
        XCTAssertEqual(delegate.alerts.count, 1)
        let alert = try XCTUnwrap(delegate.alerts.first)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted"))
        XCTAssertEqual(alert.foregroundContent?.title, "Bolus not fully counted")
        XCTAssertEqual(alert.foregroundContent?.body.contains("show \(0.5.formatted()) U delivered"), true)
        XCTAssertEqual(alert.foregroundContent?.body.contains("the app counted \(0.1.formatted()) U. Add the \(0.4.formatted()) U missing manually."), true)
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its record")

        readRecordOfTheCancelledBolusAgain(delivered: 0.5)
        XCTAssertEqual(delegate.alerts.count, 1, "told of once")
        XCTAssertEqual(finals(of: cancelled).count, 1)
    }

    /// The same, its record at the amount it went final at: nothing to tell
    func testCancelledBolusFinalFromOurEstimateAtItsRecordsAmountIsNotToldOf() {
        let cancelled = cancelBolusAndFinalizeItFromOurEstimate(progress: "2022100002005c090000000000")
        readRecordOfTheCancelledBolusAgain(delivered: 0.1)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its record")
        XCTAssertEqual(finals(of: cancelled).count, 1)
    }

    /// Cancelled before any progress, final at 0 U from our estimate, its record 0 U delivered: it explains the record -
    /// taken off, not left to crowd out the others - and there is nothing to tell
    func testZeroDeliveredRecordOfABolusFinalFromOurEstimateIsTakenOffSilently() {
        let cancelled = cancelBolusAndFinalizeItFromOurEstimate(progress: nil)
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.count, 1)

        readRecordOfTheCancelledBolusAgain(delivered: 0)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty)
    }

    /// The bolus of 0.3 U whose answer was lost, counted in full at maximumWait - the user told so - and its record read
    /// after all, 0.1 U delivered: the host has 0.2 U too many for good, insulin on board overstated - the user is told,
    /// once
    func testRecordOfABolusCountedInFullThatDeliveredLessIsToldOfOnce() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline(confirmingRecords: false)
        advanceClock(by: 60 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "counted in full")
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), ["com.nightscout.medtrumkit.bolus-counted-as-delivered"])

        link.notify("20000138" + "03f700")
        settle()
        let record = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: Date.fromMedtrumSeconds(0x17CC_31CB).addingTimeInterval(2),
            amount: 0.3,
            delivered: 0.1
        )
        link.script(CommandType.GET_RECORD, record)
        syncRecords()

        XCTAssertEqual(delegate.alerts.count, 2)
        let alert = try XCTUnwrap(delegate.alerts.last)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted"))
        XCTAssertEqual(alert.foregroundContent?.title, "Bolus counted too high")
        XCTAssertEqual(alert.foregroundContent?.body.contains("Insulin on board is overstated by \(0.2.formatted()) U."), true)

        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 2, "told of once")
    }

    /// The same, its record showing nothing delivered - cancelled on the patch before it began: no bolus the host is
    /// missing, but the 0.3 U it counted were never delivered - the user is told
    func testRecordOfABolusCountedInFullThatDeliveredNothingIsToldOf() throws {
        let started = try takeOverUnansweredBolusAndEndItAtItsDeadline(confirmingRecords: false)
        advanceClock(by: 60 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "counted in full")
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.count, 1)

        link.notify("20000138" + "03f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(
                sequence: 824,
                patchId: 247,
                start: Date.fromMedtrumSeconds(0x17CC_31CB).addingTimeInterval(2),
                amount: 0.3,
                delivered: 0
            )
        )
        syncRecords()

        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its record")
        XCTAssertEqual(delegate.alerts.count, 2)
        XCTAssertEqual(delegate.alerts.last?.foregroundContent?.body.contains("Insulin on board is overstated by \(0.3.formatted()) U."), true)
    }

    // MARK: - A record that could be that of a bolus whose answer was lost

    /// The bolus of 0.3 U whose answer was lost; record 824, of 0.3 U, starts 5 min after it went out - further than its
    /// record would, but it could be its, the patch clock off: not told of, kept. The bolus goes final from our estimate,
    /// counted in full - the record taken for its, at its amount: nothing more to tell, nor read again
    func testPossibleRecordOfAnUnansweredBolusFinalFromOurEstimateIsTakenForItsRecord() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        let record = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: patchSentAt.addingTimeInterval(5 * Self.minute),
            amount: 0.3,
            delivered: 0.3
        )
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome, "unmatched")
        XCTAssertEqual(delegate.alerts.count, 0, "it could be ours")
        XCTAssertEqual(pumpManager.state.possibleBolusRecords.map(\.sequence), [824])

        advanceClock(by: 15 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "counted in full")
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), ["com.nightscout.medtrumkit.bolus-counted-as-delivered"])
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.count, 1, "kept all the same: 824 may be another's")

        // Read again - the app killed before the cursor past it was saved, say
        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 1, "nothing more")
    }

    /// The same record 824, kept; then the bolus's own, 825, near when it went out, finalizes it: 824 was no bolus of
    /// ours after all - delivered, missing at the host - and the user is told, once
    func testPossibleRecordOfAnUnansweredBolusFinalByItsOwnRecordIsToldOf() throws {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        let possible = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: patchSentAt.addingTimeInterval(5 * Self.minute),
            amount: 0.3,
            delivered: 0.3
        )
        link.script(CommandType.GET_RECORD, possible)
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 0, "it could be ours")

        link.notify("200001" + "3903f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 825, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 825 }?.outcome?.hasPrefix("finalized bolus"), true)

        XCTAssertEqual(delegate.alerts.count, 1)
        let alert = try XCTUnwrap(delegate.alerts.first)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted"))
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)

        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, possible)
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 825, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 1, "told of once")
    }

    /// As `testPossibleRecordOfAnUnansweredBolusFinalFromOurEstimateIsTakenForItsRecord`, 824 another bolus's after all -
    /// one the host is missing: the bolus's own, 825, near when it went out, is read later - it explains it, at the
    /// amount the host has: nothing to tell of it; 824 is told of, once
    func testOwnRecordOfABolusAPossibleRecordWasTakenForTellsOfThatOne() throws {
        let (started, patchSentAt) = try takePossibleRecordAndReadTheBolussOwn(possibleDelivered: 0.3, ownDelivered: 0.3)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 825 }?.outcome, "unmatched")
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its own record")
        XCTAssertEqual(delegate.alerts.count, 2)
        try assertToldOfNotCounted(delegate.alerts.last, 0.3)

        // Read again - the app killed before the cursor past them was saved, say
        pumpManager.state.syncedSequenceNumber = 823
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(5 * Self.minute), amount: 0.3, delivered: 0.3)
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 825, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 2, "told of once")
        XCTAssertEqual(finals(of: started).count, 1)
    }

    /// The same, 824 delivering 0.1 U of its 0.3 U: as it was taken, the user was told the bolus was counted too high -
    /// by its numbers. The bolus's own, 825, shows the 0.3 U the host has: nothing more of it - the miscount told of
    /// before is not taken back - and 824's 0.1 U are told of as not counted
    func testOwnRecordOfABolusAPossibleRecordThatDeliveredLessWasTakenForTellsOfThatOne() throws {
        let (started, _) = try takePossibleRecordAndReadTheBolussOwn(possibleDelivered: 0.1, ownDelivered: 0.3) {
            XCTAssertEqual(self.delegate.alerts.count, 2)
            XCTAssertTrue(
                self.delegate.alerts.contains { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted") },
                "by 824's numbers"
            )
        }
        XCTAssertEqual(delegate.alerts.count, 3)
        try assertToldOfNotCounted(delegate.alerts.last, 0.1)
        XCTAssertEqual(finals(of: started).count, 1)
    }

    /// The same, 825 delivering 0.1 U too: the user was told of the bolus counted too high as 824 was taken - nothing
    /// more of it; 824's 0.1 U are told of as not counted
    func testOwnRecordAtWhatTheRecordTakenForItDeliveredIsNotComparedAgain() throws {
        let (started, _) = try takePossibleRecordAndReadTheBolussOwn(possibleDelivered: 0.1, ownDelivered: 0.1) {
            XCTAssertEqual(self.delegate.alerts.count, 2)
        }
        XCTAssertEqual(delegate.alerts.count, 3, "no second miscount")
        XCTAssertEqual(delegate.alerts.filter { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-miscounted") }.count, 1)
        try assertToldOfNotCounted(delegate.alerts.last, 0.1)
        XCTAssertEqual(finals(of: started).count, 1)
    }

    /// The bolus of 0.3 U whose answer was lost; record 824, of 0.3 U, `possibleDelivered`, 5 min off, kept; the bolus
    /// goes final from our estimate, counted in full, 824 taken for its record - `afterTheTake` - then its own, 825,
    /// `ownDelivered`, is read. Returns the bolus as it started, and when it went out on the patch clock.
    private func takePossibleRecordAndReadTheBolussOwn(
        possibleDelivered: Double,
        ownDelivered: Double,
        afterTheTake: () -> Void = {}
    ) throws -> (started: DoseEntry?, patchSentAt: Date) {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(5 * Self.minute), amount: 0.3, delivered: possibleDelivered)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 0, "it could be ours")
        advanceClock(by: 15 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "counted in full")
        XCTAssertTrue(delegate.alerts.contains { $0.identifier.alertIdentifier == "com.nightscout.medtrumkit.bolus-counted-as-delivered" })
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.first?.taken?.sequence, 824)
        afterTheTake()
        let toldAtTheTake = delegate.alerts.count

        link.notify("200001" + "3903f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 825, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: ownDelivered)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, toldAtTheTake + 1, "824, once")
        XCTAssertTrue(pumpManager.state.bolusesFinalWithoutRecord.isEmpty, "it explained its own record")
        return (started, patchSentAt)
    }

    private func assertToldOfNotCounted(_ alert: Alert?, _ units: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let alert = try XCTUnwrap(alert, file: file, line: line)
        XCTAssertTrue(alert.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted"), file: file, line: line)
        XCTAssertEqual(
            alert.foregroundContent?.body.contains("a bolus of \(units.formatted()) U delivered"),
            true,
            file: file,
            line: line
        )
    }

    /// Record 824, 5 min off, kept as possibly that of the unanswered bolus; then the patch clock is found that much
    /// further ahead, and 824 read again - the app killed before the cursor past it was saved, say: near enough now, it
    /// finalizes the bolus - settled with it, not told of as a bolus the host is missing
    func testPossibleRecordThatFinalizesItsBolusWhenReadAgainIsNotToldOf() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        let record = PatchBytes.bolusRecord(
            sequence: 824,
            patchId: 247,
            start: patchSentAt.addingTimeInterval(5 * Self.minute),
            amount: 0.3,
            delivered: 0.3
        )
        link.script(CommandType.GET_RECORD, record)
        syncRecords()
        XCTAssertEqual(pumpManager.state.possibleBolusRecords.map(\.sequence), [824])
        XCTAssertEqual(finals(of: started).count, 0)

        pumpManager.state.pumpTime = pumpManager.state.pumpTime.addingTimeInterval(5 * Self.minute)
        pumpManager.state.syncedSequenceNumber = 823
        link.script(CommandType.GET_RECORD, record)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)
    }

    /// The bolus of 0.3 U whose answer was lost, seen delivering since - confirmed by its progress, then completed, no
    /// record named: its record is looked for by when it went out all the same. Record 824, 5 min off, read then, could
    /// be its - kept, not told of; it goes final from our estimate, and 824 is taken for its record.
    func testPossibleRecordOfABolusWhoseAnswerWasLostReadAfterItsProgressIsNotToldOf() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        link.notify("2022100002005c090000000000") // 0.1 U
        settle()
        XCTAssertEqual(pumpManager.state.bolusDose?.confirmation, .confirmed)
        link.notify("200200800600") // completed at 0.3 U, no record named
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(5 * Self.minute), amount: 0.3, delivered: 0.3)
        )
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome, "unmatched")
        XCTAssertEqual(delegate.alerts.count, 0, "it could be its")
        XCTAssertEqual(pumpManager.state.possibleBolusRecords.map(\.sequence), [824])

        advanceClock(by: 60 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertFalse(delegate.alerts.contains { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted") })
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)
    }

    /// The bolus of 0.3 U whose answer was lost, cancelled before any progress came: record 824, of 0.3 U, 5 min off,
    /// read then, could be its - kept. Only then its completion, 0.1 U naming 824 - its own: confirmed, its answer still
    /// lost. Final from our estimate at 0.1 U, 824 is taken for its record, at that amount: nothing to tell.
    func testPossibleRecordKeptBeforeTheBolusWasConfirmedIsTakenForItsRecord() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(5 * Self.minute), amount: 0.3, delivered: 0.1)
        )
        syncRecords()
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertEqual(pumpManager.state.possibleBolusRecords.map(\.sequence), [824])

        link.notify(Self.completion(delivered: 2, record: 824, patch: "f700"))
        settle()
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.confirmation, .confirmed)
        XCTAssertNil(pumpManager.state.awaitingRecord.first?.recordSequence)

        advanceClock(by: 60 * Self.minute)
        syncRecords()
        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)
    }

    /// The bolus of 1 U of `testCancelledBolusIsRaisedByItsCompletionAndFinalizedWithoutItsRecord` answered as record
    /// 490, `progress` - if any - shown, cancelled, the patch's completion of it lost; the patch then names 490 the newest,
    /// which comes back garbled: skipped, the bolus final from our estimate 15 min later. Returns its first report.
    private func cancelBolusAndFinalizeItFromOurEstimate(progress: String?) -> DoseEntry? {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 489, reservoir: 119.9)
        state.basalDose = runningTempBasal(rate: 0.65, startedAgo: 10 * Self.minute, duration: 30 * Self.minute)
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f1303000000ea01ec0059afa9174700")
        XCTAssertNil(commandBolus(1.0))
        let started = reports(of: .bolus).first
        if let progress {
            link.notify(progress)
        }
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return started
        }
        settle()

        link.notify("200001" + "ea01ec00")
        settle()
        let garbled = FakeMedtrumLink.Answer.garbled(
            PatchBytes.bolusRecord(sequence: 490, patchId: 236, start: Date.fromMedtrumSeconds(0x17A9_AF59), amount: 1, delivered: 0.5)
        )
        link.script(CommandType.GET_RECORD, garbled)
        link.script(CommandType.GET_RECORD, garbled)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 490)
        advanceClock(by: 15 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(delegate.alerts.count, 0)
        return started
    }

    /// Record 490 of `cancelBolusAndFinalizeItFromOurEstimate` read again, delivering `delivered`
    private func readRecordOfTheCancelledBolusAgain(delivered: Double) {
        pumpManager.state.syncedSequenceNumber = 489
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 490, patchId: 236, start: Date.fromMedtrumSeconds(0x17A9_AF59), amount: 1, delivered: delivered)
        )
        syncRecords()
    }

    /// Sends a bolus of `units` the patch answers with `answer`, `answerTakes` seconds after it went out. Returns the state
    /// the host had as it went out - saved before it was written - and the outcome. The run that sent it leaves nothing
    /// pending.
    private func sendBolus(
        _ units: Double,
        _ answer: FakeMedtrumLink.Answer,
        activationType: BolusActivationType = .manualNoRecommendation,
        answerTakes: TimeInterval = 0
    ) throws -> (atWrite: PumpManager.RawStateValue, error: PumpManagerError?) {
        let atWrite = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_BOLUS, answer) { [unowned self] in
            atWrite.value = delegate.savedState
            Thread.sleep(forTimeInterval: answerTakes)
        }

        let error = commandBolus(units, activationType: activationType)
        settle()

        XCTAssertNil(pumpManager.state.pendingBolus, "cleared as its outcome came in")
        XCTAssertNil(delegate.savedState?["pendingBolus"])
        return (try XCTUnwrap(atWrite.value, "nothing handed over before the write"), error)
    }

    /// 0.3 U answered as record 824 and cancelled at once, the patch's completion of it lost with the link: the record
    /// number known stays 823. The next SetBolus of 0.3 U gets no answer, and the patch never runs it. Record 824 - at
    /// its amount, starting near when it went out - is the cancelled bolus's, its answer claimed it: no record the
    /// unanswered one could have. Every record past 823 read, none its: final at 0 U.
    func testRecordAnAnsweredBolusClaimedCouldBeNoUnansweredBolussOwn() throws {
        makeManager(unansweredBolusState())
        let patchSentAt = pumpManager.state.pumpTime

        link.script(
            CommandType.SET_BOLUS,
            PatchBytes.answer(
                command: CommandType.SET_BOLUS,
                body: UInt64(824).toData(length: 2) + UInt64(247).toData(length: 2) + patchSentAt.toMedtrumSeconds()
            )
        )
        XCTAssertNil(commandBolus(0.3))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        let cancelled = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 823)

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)
        link.script(CommandType.SET_BOLUS, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandBolus(0.3)))
        settle()
        let unanswered = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != cancelled.syncIdentifier })
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0)
        )
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome?.hasPrefix("finalized bolus"), true)
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: unanswered).count, 1)
        XCTAssertEqual(finals(of: unanswered).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The same, the other way round: the SetBolus of 0.3 U unanswered and never run first, ended at its deadline, then
    /// 0.3 U answered as record 824 and cancelled at once. Record 824 starts near when the unanswered one went out - the
    /// patch clock off - and is past the 823 known then, but the answer claimed it: the cancelled bolus's, by its
    /// number, and no record the unanswered one could have. Final at 0 U.
    func testRecordABolusSentLaterClaimedCouldBeNoUnansweredBolussOwn() throws {
        startUnansweredBolus()
        let unanswered = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)
        link.script(
            CommandType.SET_BOLUS,
            PatchBytes.answer(
                command: CommandType.SET_BOLUS,
                body: UInt64(824).toData(length: 2) + UInt64(247).toData(length: 2) + pumpManager.state.pumpTime
                    .toMedtrumSeconds()
            )
        )
        XCTAssertNil(commandBolus(0.3))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        let cancelled = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != unanswered.syncIdentifier })

        link.notify("200001" + "3803f700")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(1), amount: 0.3, delivered: 0)
        )
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome?.hasPrefix("finalized bolus"), true)
        XCTAssertEqual(finals(of: cancelled).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(finals(of: unanswered).count, 0)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: unanswered).count, 1)
        XCTAssertEqual(finals(of: unanswered).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    // MARK: - An unanswered bolus at 0 U: what keeps it in full

    /// The SetBolus of 0.3 U unanswered and ended past its deadline; record 824 skipped, unreadable, and 825 then read in
    /// its own place: the records past 823 were not all read in order - 824 could have been its. Counted in full, the
    /// host told so.
    func testUnansweredBolusIsCountedInFullWithARecordSkippedBeforeOneReadInPlace() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3903f700")
        settle()
        let garbled = FakeMedtrumLink.Answer.garbled(PatchBytes.otherRecord(type: 3, sequence: 824, patchId: 247))
        link.script(CommandType.GET_RECORD, garbled)
        link.script(CommandType.GET_RECORD, garbled)
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 825, patchId: 247))
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 825)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The same, record 824 read in its own place but of another patch: says nothing of ours, which could be it.
    /// Counted in full, the host told so.
    func testUnansweredBolusIsCountedInFullWithAnotherPatchsRecordInPlace() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()

        link.notify("200001" + "3803f700")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 824, patchId: 0x1234))
        syncRecords()

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The SetBolus of 0.3 U unanswered, ended past its deadline, every record read: the session ending then, before
    /// its 15 min, finalizes it at 0 U as the no-record rule would have - nothing to tell the user
    func testUnansweredBolusThePatchNeverRanIsFinalizedAtZeroAsTheSessionEnds() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()
        XCTAssertEqual(finals(of: started).count, 0)

        pumpManager.forceDeactivatePatch()
        settle()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The same, the phone clock set an hour back before the session ends: by the wall clock it is not past its deadline
    /// - counted in full, the host told so
    func testUnansweredBolusIsCountedInFullAsTheSessionEndsBeforeItsDeadlineByTheWallClock() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()

        changeWallClock(by: -Self.hour)
        pumpManager.forceDeactivatePatch()
        settle()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The phone clock an hour ahead as the patch told its newest record, 823, then set right; the SetBolus of 0.3 U
    /// unanswered, ended past its deadline by a full status that tells nothing of the records. By the wall clock the
    /// telling comes after its deadline, by the monotonic clock before the bolus went out: not told since - counted in
    /// full, the host told so.
    func testUnansweredBolusIsCountedInFullWithTheRecordNumberToldOnlyBeforeTheClockWentBack() {
        makeManager(unansweredBolusState())
        changeWallClock(by: Self.hour)
        confirmRecordSequence()
        changeWallClock(by: -Self.hour)

        link.script(CommandType.SET_BOLUS, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandBolus(0.3)))
        settle()
        let started = delegate.batches.first?.events.first?.dose

        advanceClock(by: 173)
        link.deliverFullStatus(notification: "200000", duringReconnect: false)
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertGreaterThan(pumpManager.state.sequenceConfirmedAt ?? .distantPast, pumpManager.now(), "told later, by the wall clock")

        // Final at the longest wait, whatever the wall clock's telling makes of the records read
        advanceClock(by: 61 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The same telling, saved, and the app killed as the SetBolus awaited its answer: a telling of the run before says
    /// nothing of when its deadline passed - counted in full, the host told so
    func testBolusAwaitingItsAnswerWhenTheAppWasKilledIsCountedInFullWithTheRecordNumberToldOnlyInTheRunBefore() throws {
        makeManager(unansweredBolusState())
        changeWallClock(by: Self.hour)
        confirmRecordSequence()
        changeWallClock(by: -Self.hour)

        try restart(from: try sendBolus(0.3, .timeout).atWrite)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertNotNil(pumpManager.state.sequenceConfirmedAt, "saved")

        advanceClock(by: 173)
        link.deliverFullStatus(notification: "200000", duringReconnect: false)
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The SetBolus of 0.3 U unanswered; the patch tells its newest record, 823, a minute after it went out - before its
    /// deadline, when its record would not be written yet - then a full status that tells nothing of the records ends
    /// it. Not told since its deadline: counted in full at the longest wait, the host told so.
    func testUnansweredBolusIsCountedInFullWithTheRecordNumberToldOnlyBeforeItsDeadline() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose

        advanceClock(by: 60)
        confirmRecordSequence()
        advanceClock(by: 113)
        link.deliverFullStatus(notification: "200000", duringReconnect: false)
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        advanceClock(by: 61 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The SetBolus of 0.3 U unanswered, and the phone clock set an hour ahead right after: by it, the next full status
    /// - 10 s later - finds it past its deadline and ends it, and later tellings of 823 come after the deadline. Not by
    /// the monotonic clock: counted in full, the host told so.
    func testUnansweredBolusIsCountedInFullAsTheWallClockJumpsForwardRightAfterItWentOut() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose

        changeWallClock(by: Self.hour)
        uptimeOffset.mutate { $0 += 10 }
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        XCTAssertNil(pumpManager.state.bolusDose, "past its deadline by the wall clock")

        changeWallClock(by: 1 * Self.minute)
        uptimeOffset.mutate { $0 += 10 }
        confirmRecordSequence()
        changeWallClock(by: 16 * Self.minute)
        uptimeOffset.mutate { $0 += 10 }
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
    }

    /// The SetBolus of 0.3 U unanswered, the phone asleep - its screen locked - between the wakes that bring the
    /// statuses: the monotonic clock counts sleep as the wall clock does. Ended past its deadline, every record read,
    /// 823 told three times over 15 min: it never ran, final at 0 U as with the phone awake, nothing to tell the user.
    func testUnansweredBolusThePatchNeverRanIsFinalizedAtZeroAcrossPhoneSleep() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose

        // Asleep all but the moment each status comes in
        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        for _ in 0 ..< 3 {
            advanceClock(by: 5 * Self.minute)
            confirmRecordSequence()
        }
        advanceClock(by: 1 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The SetBolus of 0.3 U unanswered, ended past its deadline; the temp basal is then cancelled, its record 824 read
    /// as it ends - in its own place, as a sync would: every record past 823 read, none its. Final at 0 U 15 min after
    /// the bolus ended, nothing to tell the user.
    func testUnansweredBolusCountsTheRecordsReadAsATempBasalEnds() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        endUnansweredBolusAtItsDeadline()

        cancelTempBasalReadingItsRecords(cancelRecord: 824, [unansweredBolusTempBasalRecord(sequence: 824)])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 824)
        XCTAssertEqual(finals(of: started).count, 0, "not 15 min yet")

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// The same, had the patch run it: its record 824 is read as the temp basal ends, before the temp basal's 825 - and
    /// finalizes it, with no warning
    func testUnansweredBolusIsFinalizedByItsRecordReadAsATempBasalEnds() {
        startUnansweredBolus()
        let started = delegate.batches.first?.events.first?.dose
        let patchSentAt = pumpManager.state.pumpTime
        endUnansweredBolusAtItsDeadline()

        cancelTempBasalReadingItsRecords(cancelRecord: 825, [
            PatchBytes.bolusRecord(sequence: 824, patchId: 247, start: patchSentAt.addingTimeInterval(2), amount: 0.3, delivered: 0.3),
            unansweredBolusTempBasalRecord(sequence: 825)
        ])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 825)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 824 }?.outcome?.hasPrefix("finalized bolus"), true)

        advanceClock(by: 15 * Self.minute)
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    // MARK: - Commands queued on the command lock

    /// A bolus asked for while another's SetBolus awaits its answer waits for that command, then finds the first one
    /// running: it is refused without going out, and the first runs on
    func testBolusQueuedBehindAnotherIsRefusedWithoutGoingOut() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75))

        let secondDone = expectation(description: "second bolus")
        let secondResult = Locked<PumpManagerError?>(nil)
        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { error in
                secondResult.value = error
                secondDone.fulfill()
            }
            // Past its checks, and waiting for the lock
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        wait(for: [secondDone], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        guard case let .deviceState(error)? = secondResult.value, case .isBolussing? = error as? MedtrumConnectError else {
            XCTFail("The second bolus was not refused as bolusing: \(String(describing: secondResult.value))")
            return
        }
        XCTAssertEqual(pumpManager.state.bolusDose?.value, 0.05)
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
        XCTAssertEqual(reports(of: .bolus).count, 1)
    }

    /// The patch turns a bolus down: nothing of it is in the state, and what is there belongs to others - a cancel
    /// asked for meanwhile, waiting to go out, and a bolus the state has running by then, whatever put it there
    func testRejectedBolusLeavesWhatOtherOperationsHaveInTheState() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75))

        let running = UnfinalizedDose(units: 0.5, duration: 20, activationType: .manualNoRecommendation, insulinType: nil)
        let cancelDone = expectation(description: "cancelBolus")
        link.script(CommandType.SET_BOLUS, .failure(.invalidResponse(code: 8))) { [unowned self] in
            pumpManager.state.bolusDose = running
            pumpManager.cancelBolus { _ in cancelDone.fulfill() }
        }
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")

        let atRejection = Locked<(bolus: UnfinalizedDose?, cancelingSince: Date?)?>(nil)
        let rejected: PumpManagerError?? = completion(of: "enactBolus") { done in
            self.pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { error in
                // The cancel waits for this command: what it finds is what the rejection left
                atRejection.value = (self.pumpManager.state.bolusDose, self.pumpManager.state.cancelingBolusSince)
                done(error)
            }
        }
        wait(for: [cancelDone], timeout: 5)
        settle()

        XCTAssertNotNil(rejected ?? nil, "turned down")
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.CANCEL_BOLUS])
        XCTAssertTrue(atRejection.value?.bolus === running, "the running bolus was taken out of the state")
        XCTAssertNotNil(atRejection.value?.cancelingSince, "the cancel waiting to go out was cleared")
    }

    /// A bolus whose connect fails while another command holds the lock - the first bolus, here - is reported failed at
    /// once, not once that command is over, and leaves the first running
    func testBolusWhoseConnectFailsIsReportedAtOnceAndLeavesTheRunningOne() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75))

        let secondResult = Locked<PumpManagerError?>(nil)
        let secondReportedDuringTheFirst = Locked(false)
        let secondDone = expectation(description: "second bolus")
        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            link.connectError = .failedToConnectToDevice
            let reported = DispatchSemaphore(value: 0)
            pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { error in
                secondResult.value = error
                reported.signal()
                secondDone.fulfill()
            }
            secondReportedDuringTheFirst.value = reported.wait(timeout: .now() + 1) == .success
            link.connectError = nil
        }

        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        wait(for: [secondDone], timeout: 5)
        settle()

        XCTAssertTrue(secondReportedDuringTheFirst.value, "the failed connect waited for the command holding the lock")
        guard case .communication? = secondResult.value else {
            XCTFail("The second bolus did not fail to connect: \(String(describing: secondResult.value))")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertEqual(pumpManager.state.bolusDose?.value, 0.05)
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
    }

    // MARK: - A cancel waiting for the link

    /// iAPS review 2026-10-26: a cancel waits for the command lock behind another operation - as long as a command may
    /// take - while the bolus it was asked for completes and the loop's next starts, taking the lock first. It shows
    /// `.canceling` only while its own bolus runs, and once it has the link writes nothing: the new bolus runs on and is
    /// finalized by its record.
    func testCancelOfABolusOverByTheTimeItHasTheLinkDoesNotStopTheNextOne() throws {
        startAnsweredBolus()
        let release = holdCommandLock()
        let cancel = startCancel()
        XCTAssertEqual(pumpManager.state.bolusState, .canceling)

        link.notify("202211802800040d7b00ec000000000000") // 2.0 U, complete, record 123
        settle()
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus, "the bolus it was asked for is over")
        XCTAssertNil(pumpManager.state.cancelingBolusSince)

        // The loop's next bolus, ahead of the cancel on the lock
        let next = UnfinalizedDose(units: 0.5, duration: 20, activationType: .automatic, insulinType: nil)
        next.noteAnswer(recordSequence: 124)
        pumpManager.withDoseReportLock { pumpManager.state.bolusDose = next }
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress, "not shown as cancelled")

        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS], "no CancelBolus")
        XCTAssertTrue(pumpManager.state.bolusDose === next)
        XCTAssertFalse(next.isFinished)

        link.notify(Self.completion(delivered: 10, record: 124))
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: Date.now, amount: 2, delivered: 2))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: Date.now, amount: 0.5, delivered: 0.45))
        syncRecords()

        let nextFinal = finals(of: reports(of: .bolus).first { $0.programmedUnits == 0.5 })
        XCTAssertFalse(nextFinal.isEmpty)
        XCTAssertEqual(nextFinal.first?.deliveredUnits ?? 0, 0.45, accuracy: 0.001, "by its record, not cancelled")
    }

    /// A cancel waiting for the link while its bolus completes on its own: nothing is written, the bolus ends as
    /// completed - not cancelled - and it succeeds
    func testCancelOfABolusThatCompletedBeforeTheLinkWritesNothing() {
        startAnsweredBolus()
        let release = holdCommandLock()
        let cancel = startCancel()

        link.notify("202211802800040d7b00ec000000000000")
        settle()
        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .completed)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
    }

    /// Two cancels of the same bolus - the host's retry while the first waits: one CancelBolus goes out, the bolus ends
    /// once, and both succeed, whichever runs first
    func testTwoCancelsOfTheSameBolusWriteOneCancel() {
        startAnsweredBolus()
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        let release = holdCommandLock()
        let first = startCancel()
        let second = startCancel()
        XCTAssertEqual(pumpManager.state.bolusState, .canceling)

        release()
        guard case .success? = first(), case .success? = second() else {
            XCTFail("A cancel did not succeed")
            return
        }
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.CANCEL_BOLUS])
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.awaitingRecord.filter { $0.type == .bolus }.count, 1)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .cancelled)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
        XCTAssertNil(pumpManager.state.cancelingBolusSince)
    }

    /// A cancel asked for while the SetBolus waits for the host to take the state - its command out, no dose yet: it
    /// is of that bolus, by when it went out. Answered, the dose registered with it, the cancel stops it.
    func testCancelAskedWhileTheSetBolusIsOutStopsItOnceAnswered() {
        let bolus = sendBolusCancelledAsItIsOut(.fragments(["0f13280000007b00ec009786a8178900"]), cancelWritten: true)
        XCTAssertNil(bolus.error ?? nil)
        guard case .success? = bolus.cancel else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.CANCEL_BOLUS])
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .cancelled)
    }

    /// The same, the SetBolus turned down: no bolus runs, and the cancel writes nothing
    func testCancelAskedWhileTheSetBolusIsOutWritesNothingOnceItFailed() {
        let bolus = sendBolusCancelledAsItIsOut(.failure(.invalidResponse(code: 8)), cancelWritten: false)
        XCTAssertNotNil(bolus.error ?? nil)
        guard case .success? = bolus.cancel else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
    }

    /// The same, the SetBolus's answer lost: the bolus may be running, registered with when it went out - the cancel
    /// stops it
    func testCancelAskedWhileTheSetBolusIsOutStopsItWithItsAnswerLost() {
        let bolus = sendBolusCancelledAsItIsOut(.timeout, cancelWritten: true)
        XCTAssertTrue(isUncertainDelivery(bolus.error ?? nil))
        guard case .success? = bolus.cancel else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.CANCEL_BOLUS])
        XCTAssertNil(pumpManager.state.bolusDose)
    }

    /// A cancel with no bolus known - none running nor out - is written as before, with none by then either. It shows
    /// no `.canceling`, nor refuses dosing meanwhile: it stops nothing that runs.
    func testCancelWithNoBolusKnownIsWrittenWithNoneRunning() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        let release = holdCommandLock()
        let cancel = startCancel()
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus, "not shown cancelling")
        XCTAssertNil(pumpManager.state.cancelingBolusSince)

        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_BOLUS])
    }

    /// The same, a bolus out by the time it has the link - its SetBolus waiting on the host: not written
    func testCancelWithNoBolusKnownWritesNothingWithABolusOut() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        let release = holdCommandLock()
        let cancel = startCancel()
        pumpManager.withDoseReportLock {
            pumpManager.state.pendingBolus = PendingBolus(units: 1, sentAt: Date.now, sequenceAtSend: 122, automatic: true)
        }

        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [])
        pumpManager.withDoseReportLock { pumpManager.state.pendingBolus = nil }
    }

    /// The same, a bolus running by the time it has the link: not written, the bolus runs on
    func testCancelWithNoBolusKnownWritesNothingWithABolusRunning() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        let release = holdCommandLock()
        let cancel = startCancel()
        let running = UnfinalizedDose(units: 0.5, duration: 20, activationType: .automatic, insulinType: nil)
        pumpManager.withDoseReportLock { pumpManager.state.bolusDose = running }
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)

        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertTrue(pumpManager.state.bolusDose === running)
        XCTAssertFalse(running.isFinished)
        pumpManager.withDoseReportLock { pumpManager.state.bolusDose = nil }
    }

    /// 2 U sent, its SetBolus answered with `answer`, a cancel asked for while it waits for the host to take the state -
    /// held up after saving it, the command going on once its bound is up - the CancelBolus answered if `cancelWritten`.
    /// Returns both outcomes.
    private func sendBolusCancelledAsItIsOut(
        _ answer: FakeMedtrumLink.Answer,
        cancelWritten: Bool
    ) -> (error: PumpManagerError??, cancel: PumpManagerResult<DoseEntry?>?) {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        pumpManager.dosingHandOverTimeout = 1
        let releaseHost = stallHostAfterSaving("pendingBolus")
        defer { releaseHost() }
        link.script(CommandType.SET_BOLUS, answer)
        if cancelWritten {
            link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        }

        let sent = expectation(description: "enactBolus")
        let error = Locked<PumpManagerError??>(nil)
        pumpManager.enactBolus(units: 2, activationType: .manualNoRecommendation) { outcome in
            error.value = outcome
            sent.fulfill()
        }
        let until = Date.now.addingTimeInterval(5)
        while pumpManager.state.pendingBolus == nil, Date.now < until {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNotNil(pumpManager.state.pendingBolus, "out")
        let cancel = startCancel()
        XCTAssertEqual(pumpManager.state.bolusState, .canceling, "of the bolus out")

        wait(for: [sent], timeout: 10)
        let cancelled = cancel()
        releaseHost()
        settle()
        return (error.value, cancelled)
    }

    /// 2 U answered as record 123, running - `user.txt:11229`
    private func startAnsweredBolus() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
    }

    /// Holds the command lock on another thread, as an operation in flight does, until the returned release is called
    private func holdCommandLock() -> () -> Void {
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [pumpManager] in
            pumpManager?.withCommandLock {
                held.signal()
                _ = release.wait(timeout: .now() + 30)
            }
        }
        held.wait()
        return { release.signal() }
    }

    /// A cancel asked for now, its outcome waited for by the returned call - 5 s at most
    private func startCancel() -> () -> PumpManagerResult<DoseEntry?>? {
        let done = expectation(description: "cancelBolus")
        let result = Locked<PumpManagerResult<DoseEntry?>?>(nil)
        pumpManager.cancelBolus { outcome in
            result.value = outcome
            done.fulfill()
        }
        return { [unowned self] in
            wait(for: [done], timeout: 5)
            return result.value
        }
    }

    /// `user.txt:11229-11295`: 2 U answered as record 123 from patch second 0x17A88697, completed at 2.0 U - waiting on
    /// its record. Returns its first report.
    private func completeAnsweredBolus() -> DoseEntry? {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        link.notify("202211802800040d7b00ec000000000000")
        settle()

        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.recordSequence, 123)
        return delegate.batches.first?.events.first?.dose
    }

    /// 2 U answered as record 123 from `patchSentAt` (`user.txt:11229`), cancelled at 0.4 U; the patch's completion of it
    /// lost with the link, so the record number known stays 122. Then 2 U whose SetBolus gets no answer, which the
    /// patch runs to completion as record 124. Returns the first report of each.
    private func cancelledThenUnansweredBolus(patchSentAt: Date) throws -> (cancelled: DoseEntry, unanswered: DoseEntry) {
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        link.notify("202210000800280d0000000000") // 0.4 U
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            throw CancellationError()
        }
        settle()

        let cancelled = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 122)

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)

        link.script(CommandType.SET_BOLUS, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandBolus(2.0)))
        settle()
        let unanswered = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != cancelled.syncIdentifier })
        // Gone out with 123, the newest claimed, as the newest known: the number known lags it
        XCTAssertEqual(pumpManager.state.bolusDose?.snapshot.sequenceAtSend, 123)

        // The link back: its completion, 2 U, and the patch at record 124
        advanceClock(by: 3 * Self.minute)
        link.notify("200200802800")
        link.notify("200001" + "7c00ec00")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 124)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 2)

        return (cancelled, unanswered)
    }

    /// The SetBolus of 0.3 U of `user.txt:67542` taken over after the app was killed awaiting its answer, reported in
    /// full; past its deadline a full status ends it - `confirmingRecords`: one telling the newest record, 823. `answer`:
    /// what came of its write in the run before - none, or a failure, the host's state still pending. Returns its first
    /// report.
    private func takeOverUnansweredBolusAndEndItAtItsDeadline(
        confirmingRecords: Bool = true,
        answer: FakeMedtrumLink.Answer = .timeout
    ) throws -> DoseEntry? {
        makeManager(unansweredBolusState())
        try restart(from: try sendBolus(0.3, answer).atWrite)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertNil(started?.deliveredUnits, "counted in full")

        advanceClock(by: 173)
        if confirmingRecords {
            link.deliverFullStatus([
                "2f030301000020ee0d800200800000063703f7ab",
                "2f03030200ca31cc172f20009d092493c917d076",
                "2f030303ab563703f7005ea202009a0827bb"
            ])
        } else {
            link.deliverFullStatus(notification: "200000", duringReconnect: false)
        }
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertNil(delegate.batches.last?.events.last?.dose?.deliveredUnits, "counted in full until its record")
        return started
    }

    /// 2:53 after the SetBolus of `startUnansweredBolus`, past its deadline: the next full status of `user.txt` ends it,
    /// telling the newest record, 823
    private func endUnansweredBolusAtItsDeadline() {
        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
    }

    /// Where the cancel of `cancelTempBasalReadingItsRecords` ends the temp basal of `unansweredBolusState`, on the patch
    /// clock
    private static let unansweredBolusTempBasalEnd = Date.fromMedtrumSeconds(0x17CC_31CA + 200)

    /// The record of the temp basal of `unansweredBolusState`, as the cancel ends it
    private func unansweredBolusTempBasalRecord(sequence: Int) -> [String] {
        PatchBytes.basalRecord(
            sequence: sequence,
            patchId: 247,
            type: .ABSOLUTE_TEMP,
            start: Date.fromMedtrumSeconds(0x17CC_31CA),
            end: Self.unansweredBolusTempBasalEnd,
            rate: 2.35,
            delivered: 0.15
        )
    }

    /// The temp basal of `unansweredBolusState` cancelled, the answer naming its record `cancelRecord`: `records`, the
    /// ones past the cursor up to it, are read as it ends
    private func cancelTempBasalReadingItsRecords(cancelRecord: Int, _ records: [[String]]) {
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.6,
            sequence: cancelRecord,
            patchId: 247,
            start: Self.unansweredBolusTempBasalEnd
        ))
        for record in records {
            link.script(CommandType.GET_RECORD, record)
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        XCTAssertEqual(link.writtenCommands.filter { $0 == CommandType.GET_RECORD }.count, records.count, "read as it ended")
    }

    /// The state of `user.txt:67525-67555`
    private func unansweredBolusState() -> MedtrumPumpState {
        let state = activePatchState(patchId: 247, scheduledRate: 0.6, sequence: 823, reservoir: 123.15)
        state.basalDose = runningTempBasal(
            rate: 2.35,
            startedAgo: 1,
            duration: 30 * Self.minute,
            pumpStartTime: Date.fromMedtrumSeconds(0x17CC_31CA)
        )
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Date.fromMedtrumSeconds(0x17CC_31CB))
        return state
    }

    /// The state of `user.txt:67525-67555`, then the SetBolus of 0.3 U that got no answer
    private func startUnansweredBolus() {
        makeManager(unansweredBolusState())

        link.script(CommandType.SET_BOLUS, .timeout)

        XCTAssertTrue(isUncertainDelivery(commandBolus(0.3)))
        settle()

        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x06), "09130600010600000500")
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
        XCTAssertEqual(pumpManager.state.bolusDose?.confirmation, .uncertain)

        // Reported running in full, and the host warned once
        XCTAssertEqual(delegate.batches.count, 1)
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(started?.isMutable, true)
        XCTAssertNil(started?.deliveredUnits)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(delegate.statusUpdates.last?.status.deliveryIsUncertain, true)
    }
}

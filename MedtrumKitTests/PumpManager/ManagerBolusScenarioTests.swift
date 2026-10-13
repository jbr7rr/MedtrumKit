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

    /// 2026-08-27 03:00:55 - 03:05:35 (`user.txt:67542-67612`), patch 247: a SetBolus of 0.3 U gets no answer, and the
    /// patch never runs it. Four full statuses follow, each repeating the previous bolus's completion of 0.1 U, and
    /// the record number stays at 823.
    func testUnansweredBolusIsCountedInFullAndFinalizedSoWithoutItsRecord() {
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

        // Every record read, none its, 15 min after it ended: final in full, and the user is told
        advanceClock(by: 15 * Self.minute)
        syncRecords()

        let started = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
        XCTAssertEqual(delegate.alerts.first?.identifier.alertIdentifier, "com.nightscout.medtrumkit.bolus-counted-as-delivered")
        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
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
    }

    /// A SetBolus answer garbled on the air is no answer either: the patch may have run it, as with none at all
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
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 1)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
    }

    /// A record under the bolus's number that starts elsewhere than its answer said is another bolus's - the number
    /// reused, after a cancel the patch wrote no record for: it does not finalize this one, which falls back
    func testRecordWithTheBolusNumberButAnotherStartDoesNotFinalizeIt() {
        let started = completeAnsweredBolus()

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

        XCTAssertEqual(finals(of: started).count, 0)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 1)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("start differs"), true)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 2.0, accuracy: 0.001, "what its completion said")
    }

    /// A record under the bolus's number, of another amount: not this bolus's either
    func testRecordWithTheBolusNumberButAnotherAmountDoesNotFinalizeIt() {
        let started = completeAnsweredBolus()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: Date.fromMedtrumSeconds(0x17A8_8697), amount: 1.5, delivered: 1.5)
        )
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 0)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 1)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("amount differs"), true)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 2.0, accuracy: 0.001, "what its completion said")
    }

    /// A 2 U bolus answered as record 123 is cancelled before it delivered anything: the patch writes no record for it,
    /// and gives that number to the next bolus - 1 U, whose SetBolus goes unanswered, and which the patch runs to
    /// completion. Record 123 starts elsewhere than the first one's answer said: not the first one's, but the second's,
    /// found by when its command went out.
    func testRecordWithAReusedNumberFinalizesTheUnansweredBolusItBelongsTo() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()

        let cancelled = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.recordSequence, 123)

        link.script(CommandType.SET_BOLUS, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandBolus(1.0)))
        settle()
        let unanswered = try XCTUnwrap(
            reports(of: .bolus).first { $0.syncIdentifier != cancelled.syncIdentifier }
        )

        // Its completion, 1 U, and the record the patch then wrote: 123
        link.notify("200200801400")
        link.notify("200001" + "7b00ec00")
        settle()
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 123)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 2)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: patchSentAt.addingTimeInterval(20), amount: 1.0, delivered: 1.0)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized bolus"), true)
        XCTAssertEqual(finals(of: unanswered).count, 1)
        XCTAssertEqual(finals(of: unanswered).last?.deliveredUnits ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(finals(of: cancelled).count, 0)
        XCTAssertEqual(delegate.alerts.count, 0)
    }

    /// 2 U answered as record 123 is cancelled before it delivered anything, the patch writing no record for it; the next
    /// 2 U is answered with the same number, from 2 min later, and cancelled too. Record 123 starts where the second
    /// one's answer said: it is the second's, though the first waits under the same number.
    func testRecordWithAReusedNumberFinalizesTheAnsweredBolusWithItsStart() throws {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let secondStart = patchSentAt.addingTimeInterval(2 * Self.minute)
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        let first = try XCTUnwrap(delegate.batches.first?.events.first?.dose)

        // The identity of a dose is its start to the second: the second bolus must not start in the first one's
        Thread.sleep(forTimeInterval: 1.1)
        link.script(
            CommandType.SET_BOLUS,
            PatchBytes.answer(
                command: CommandType.SET_BOLUS,
                body: UInt64(123).toData(length: 2) + UInt64(236).toData(length: 2) + secondStart.toMedtrumSeconds()
            )
        )
        XCTAssertNil(commandBolus(2.0))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()
        let second = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != first.syncIdentifier })
        XCTAssertEqual(pumpManager.state.awaitingRecord.filter { $0.recordSequence == 123 }.count, 2)

        // The patch then says it wrote record 123
        link.notify("200001" + "7b00ec00")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: secondStart, amount: 2.0, delivered: 0.4)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized bolus"), true)
        XCTAssertEqual(finals(of: second).count, 1)
        XCTAssertEqual(finals(of: second).last?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(finals(of: first).count, 0)
    }

    /// 2 U answered as record 123 is cancelled at 0.4 U, the link lost before the patch's completion of it (which
    /// carries record 123) came in; a 2 U SetBolus right after goes unanswered - the record number known then still 122
    /// - and the patch runs it (record 124). Record 123 finalizes the cancelled bolus by number. The app is then killed
    /// with that final handed over and the cursor not yet saved past 123: read again after the restart, record 123 is
    /// still the cancelled bolus's - by its number and its start - not the unanswered one's, though it has its amount
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

        let garbled = SynchronizePacketResponse(
            state: .active,
            bolus: BolusData(type: 0, completed: true, delivered: 0.1),
            reservoir: 6553.5,
            storage: StorageData(sequence: 823, patchId: 247),
            activeAlarms: []
        )
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
        XCTAssertEqual(pumpManager.state.bolusDose?.snapshot.sequenceAtSend, 122)

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

    /// The state of `user.txt:67525-67555`, then the SetBolus of 0.3 U that got no answer
    private func startUnansweredBolus() {
        let state = activePatchState(patchId: 247, scheduledRate: 0.6, sequence: 823, reservoir: 123.15)
        state.basalDose = runningTempBasal(
            rate: 2.35,
            startedAgo: 1,
            duration: 30 * Self.minute,
            pumpStartTime: Date.fromMedtrumSeconds(0x17CC_31CA)
        )
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Date.fromMedtrumSeconds(0x17CC_31CB))
        makeManager(state)

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

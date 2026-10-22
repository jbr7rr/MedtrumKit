import LoopKit
@testable import MedtrumKit
import XCTest

/// Temp basals a new one replaces back to back - a cancel, then a set - end open: the command completes once the set is
/// answered, the old one reported ended where the new one starts and mutable, its records read after the command. They
/// go final in order, the oldest first, and before anything that leaves a gap after them goes out. Every scenario's
/// batches are checked against the rules Loop needs kept (`LoopOrderingChecker`, in `tearDown`). Records are built with
/// `PatchBytes`, on patch 251: 1.2 U/h from `start1`, cancelled at `end1` for 0.5 U/h, cancelled at `end2` for 0.8 U/h.
final class ManagerTempBasalBackToBackScenarioTests: MedtrumManagerTestCase {
    private static let patchId: UInt64 = 251
    private static let start1 = patchTime(400_000_000)
    private static let end1 = patchTime(400_001_200)
    private static let end2 = patchTime(400_001_500)

    // MARK: - The command completes before the read

    /// The set answered, the command completes: the record the cancel named is asked for only after it, and the host
    /// has the old temp basal ended where the new one starts, mutable, then final from that record
    func testReplacingATempBasalCompletesBeforeItsRecordIsAskedFor() throws {
        let first = runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))

        let writtenAtCompletion = Locked<[UInt8]?>(nil)
        let outcome: PumpManagerError?? = completion(of: "enactTempBasal") { done in
            self.pumpManager.enactTempBasal(unitsPerHour: 0.5, for: 30 * Self.minute) { error in
                writtenAtCompletion.value = self.link.writtenCommands
                done(error)
            }
        }
        XCTAssertNil(outcome ?? nil)
        settle()

        XCTAssertEqual(writtenAtCompletion.value, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL])
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])

        let open = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(open.map(\.unitsPerHour), [1.2, 0.5])
        XCTAssertEqual(open.map(\.isMutable), [true, true])
        XCTAssertEqual(open.first?.endDate, open.last?.startDate, "ended exactly where the new one starts")

        let final = try XCTUnwrap(finals(of: open.first).first)
        XCTAssertEqual(final.startDate, first.startDate)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(final.endDate, open.last?.startDate, "still ends where the new one starts")
        XCTAssertEqual(finals(of: final).count, 1)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
    }

    /// The loop's bolus, right behind the temp basal: it goes out at once, no record asked for ahead of it - and while
    /// it runs no record is read, the old temp basal mutable meanwhile
    func testBolusRightAfterTheTempBasalIsNotHeldUpByItsRecord() {
        runFirst(patchId: 236)
        pumpManager.openTempBasalEndReadDelay = 1
        scriptReplacement(of: 1, patchId: 236)
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")

        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        let started = Date.now
        XCTAssertNil(commandBolus(0.5, activationType: .automatic))
        let took = Date.now.timeIntervalSince(started)
        settle()

        XCTAssertLessThan(took, 1)
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.SET_BOLUS])

        // Past the delay, the bolus running: still nothing read
        Thread.sleep(forTimeInterval: 1.5)
        settle()
        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_BOLUS)
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds)
        XCTAssertTrue(reports(of: .tempBasal).filter { $0.unitsPerHour == 1.2 }.allSatisfy(\.isMutable))
    }

    /// The patch's heartbeat naming the cancel's record moments after the set, as it does: within
    /// `openTempBasalEndReadDelay` the record is the read's after the command - the heartbeat syncs nothing, and the
    /// loop's bolus a second after the set goes out with no record read ahead of it. Past the delay a heartbeat would:
    /// the read after the command lost - the delay a minute here, it does not run - one reads it, the old one final.
    func testHeartbeatRightAfterTheSetLeavesTheRecordToTheReadAfterTheCommand() throws {
        runFirst()
        pumpManager.openTempBasalEndReadDelay = 60
        scriptReplacement(of: 1)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        heartbeat()
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL], "no record read")
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds)

        Thread.sleep(forTimeInterval: 1)
        let bolusStart = Self.end1.addingTimeInterval(2)
        link.script(CommandType.SET_BOLUS, bolusAnswer(record: 133, start: bolusStart))
        let started = Date.now
        XCTAssertNil(commandBolus(0.5, activationType: .automatic))
        XCTAssertLessThan(Date.now.timeIntervalSince(started), 1)
        settle()
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.SET_BOLUS])

        // The old one alone waits on its record as the bolus runs: past the window it counts again
        XCTAssertFalse(pumpManager.hasPendingRecordWork)
        advanceClock(by: 60)
        XCTAssertTrue(pumpManager.hasPendingRecordWork)

        link.notify(completion(delivered: 0.5, record: 133))
        settle()
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        link.script(CommandType.GET_RECORD, scheduledSecond(sequence: 132, at: Self.end1))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 133, patchId: Self.patchId, start: bolusStart, amount: 0.5, delivered: 0.5
        ))
        heartbeat()

        XCTAssertEqual(link.writtenCommands.suffix(3), [CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_RECORD])
        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 133)
    }

    /// The wall clock set back right after the set: the window goes by the age of the end, which is negative now - the
    /// heartbeat counts the record again rather than leave it until the wall clock catches up
    func testWallClockSetBackAfterTheSetDoesNotHoldTheHeartbeatOff() {
        runFirst()
        pumpManager.openTempBasalEndReadDelay = 60
        scriptReplacement(of: 1)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()
        XCTAssertFalse(pumpManager.hasPendingRecordWork)

        changeWallClock(by: -10 * Self.minute)
        XCTAssertTrue(pumpManager.hasPendingRecordWork)
    }

    // MARK: - Chains

    /// Two in a row, the first one's record not read after the first command: the second command's read gets both,
    /// and they go final in order, each from its own record
    func testChainOfTwoGoesFinalInOrderFromTheirRecords() throws {
        let first = runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds)
        let second = pumpManager.state.basalDose

        scriptReplacement(of: 2)
        for answer in recordsThroughTheSecond(delivered: 0.05) {
            link.script(CommandType.GET_RECORD, answer)
        }
        XCTAssertNil(commandTempBasal(0.8, duration: 30 * Self.minute))
        settle()

        let reported = try XCTUnwrap(delegate.batches.dropFirst().first?.events.compactMap(\.dose))
            .sorted { $0.startDate < $1.startDate }
        XCTAssertEqual(reported.map(\.unitsPerHour), [1.2, 0.5, 0.8], "the second command's batch carries the chain")
        XCTAssertTrue(reported.allSatisfy(\.isMutable))
        XCTAssertEqual(reported[0].endDate, reported[1].startDate)
        XCTAssertEqual(reported[1].endDate, reported[2].startDate)

        let firstFinal = try XCTUnwrap(finals(of: reported[0]).first)
        let secondFinal = try XCTUnwrap(finals(of: reported[1]).first)
        XCTAssertEqual(firstFinal.startDate, first.startDate)
        XCTAssertEqual(firstFinal.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(secondFinal.startDate, second.startDate)
        XCTAssertEqual(secondFinal.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertLessThanOrEqual(batchIndex(ofFinal: firstFinal) ?? .max, batchIndex(ofFinal: secondFinal) ?? -1)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 133)
    }

    /// Three in a row, no record read until a sync after the third: every replacing batch carries the two ended, and the
    /// sync makes them final in order
    func testChainOfThreeWithLateRecordsGoesFinalInOrderOnTheSync() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        scriptReplacement(of: 2)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.8, duration: 30 * Self.minute))
        settle()

        // A full status meanwhile: its batch carries both mutable, nothing final from our estimate
        link.deliverFullStatus(notification: running(rate: 0.8, from: Self.end2.addingTimeInterval(1), sequence: 134), duringReconnect: false)
        settle()
        let carried = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose)).filter { $0.type == .tempBasal }
        XCTAssertEqual(Set(carried.map(\.unitsPerHour)), [1.2, 0.5, 0.8])
        XCTAssertTrue(carried.allSatisfy(\.isMutable))
        XCTAssertEqual(pumpManager.heartbeatSync(), .records, "the records are waited on - the heartbeat reads them")

        for answer in recordsThroughTheSecond(delivered: 0.05) + [.fragments(scheduledSecond(sequence: 134, at: Self.end2))] {
            link.script(CommandType.GET_RECORD, answer)
        }
        syncRecords()

        let ended = reports(of: .tempBasal).filter { $0.unitsPerHour == 1.2 || $0.unitsPerHour == 0.5 }
        let firstFinal = try XCTUnwrap(ended.first { $0.unitsPerHour == 1.2 && !$0.isMutable })
        let secondFinal = try XCTUnwrap(ended.first { $0.unitsPerHour == 0.5 && !$0.isMutable })
        XCTAssertEqual(firstFinal.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(secondFinal.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertLessThanOrEqual(batchIndex(ofFinal: firstFinal) ?? .max, batchIndex(ofFinal: secondFinal) ?? -1)
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.8)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    // MARK: - Records that never come

    /// The record never read: after `openTempBasalEndMaximumWait` the old one goes final from our estimate - 1.2 U/h ×
    /// 20 min - its end still where the new one starts
    func testRecordThatNeverComesLeavesItToOurEstimateAfterTheMaximumWait() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        advanceClock(by: MedtrumPumpManager.openTempBasalEndMaximumWait - Self.minute)
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds)

        advanceClock(by: 2 * Self.minute)
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()

        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        let open = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 })
        let final = try XCTUnwrap(finals(of: open).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        XCTAssertEqual(final.endDate, open.endDate)
        XCTAssertEqual(uncertain.count, 0)
    }

    /// Its record comes back unreadable: the read after the command asks for it once, within a record's time, and stops -
    /// the next sync asks twice and skips it. Read past it, the old one goes final from our estimate.
    func testRecordSkippedLeavesItToOurEstimate() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .garbled(recordOfFirst(delivered: 0.35)))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()
        XCTAssertEqual(link.writtenCommands.filter { $0 == CommandType.GET_RECORD }.count, 1, "asked for once")
        XCTAssertLessThanOrEqual(link.writes.last?.timeout ?? .infinity, MedtrumPumpManager.tempBasalEndRecordTimeout)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 130)
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds)

        link.script(CommandType.GET_RECORD, .garbled(recordOfFirst(delivered: 0.35)))
        link.script(CommandType.GET_RECORD, .garbled(recordOfFirst(delivered: 0.35)))
        link.script(CommandType.GET_RECORD, .fragments(scheduledSecond(sequence: 132, at: Self.end1)))
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 132)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
    }

    // MARK: - What leaves a gap after them

    /// A cancel to the schedule after a chain: the temp basals ended back to back go final first - from their records,
    /// read in the command with the cancelled one's - all in the batch with the schedule
    func testCancelAfterAChainFinalizesItFirst() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()
        let batchesBefore = delegate.batches.count

        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 133, at: Self.end2))
        for answer in recordsThroughTheSecond(delivered: 0.05) {
            link.script(CommandType.GET_RECORD, answer)
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(delegate.batches.count, batchesBefore + 1)
        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .basal])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(batch[1].deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(batch[0].endDate, batch[1].startDate)
        XCTAssertEqual(batch[1].endDate, batch[2].startDate)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// The patch suspends after a chain, announcing it with its time: every temp basal before goes final with the
    /// suspend, from their records
    func testSuspendAfterAChainFinalizesItFirst() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        for answer in recordsThroughTheSecond(delivered: 0.05) {
            link.script(CommandType.GET_RECORD, answer)
        }
        link.notify(halt(.suspended, at: Self.end2, newestRecord: 133))
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .suspend])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(batch[1].deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(batch[1].endDate, batch[2].startDate)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
    }

    /// An occlusion after a chain, its status with no time of the halt: the same - the running one settled by its own
    /// record, which the halt ended
    func testOcclusionAfterAChainFinalizesItFirst() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        for answer in recordsThroughTheSecond(delivered: 0.05, endReason: .STOP_OCCLUSION) {
            link.script(CommandType.GET_RECORD, answer)
        }
        link.notify(halt(.occlusion, at: nil, newestRecord: 133))
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .suspend])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(batch[1].deliveredUnits ?? 0, 0.05, accuracy: 0.001, "from its record")
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// The new one runs its course while the old one waits on its record: the scheduled basal after it leaves a gap, so
    /// both go final first - with the schedule, the old one from its record
    func testExpiryAfterAChainFinalizesItFirst() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 5 * Self.minute))
        settle()

        let expiredAt = Self.end1.addingTimeInterval(301)
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        link.script(CommandType.GET_RECORD, .fragments(scheduledSecond(sequence: 132, at: Self.end1)))
        link.script(CommandType.GET_RECORD, .fragments(recordOfSecond(delivered: 0.05, end: expiredAt)))
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 133, patchId: Self.patchId, start: expiredAt, rate: 0.7))
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .basal])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
    }

    /// The set after a chain unanswered: the cancel ended the running one, and the schedule goes out after it - nothing
    /// is read on that link, so both go final from our estimate first, in order
    func testUnansweredSetAfterAChainFinalizesItFromOurEstimateFirst() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 133, at: Self.end2))
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.8, duration: 30 * Self.minute)))
        settle()

        XCTAssertEqual(link.writtenCommands.suffix(2), [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL])
        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .basal])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
    }

    /// Killed as the set after a chain awaited its answer: the next run ends the running one at the cancel from our
    /// estimate - and the one ended back to back before it first - then the schedule
    func testAppKilledAsTheSetAfterAChainAwaitedItsAnswer() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 133, at: Self.end2))
        let savedAtSet = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_TEMP_BASAL, .timeout) { [unowned self] in
            savedAtSet.value = delegate.savedState
        }
        _ = commandTempBasal(0.8, duration: 30 * Self.minute)
        settle()

        let restarted = try restart(from: savedAtSet.value)
        XCTAssertNotNil(restarted.state.unconfirmedTempBasal)
        XCTAssertFalse(restarted.hasOpenTempBasalEnds)
        restarted.emitPumpEvents([])
        settle()

        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(batch.filter { $0.type == .tempBasal }.map(\.unitsPerHour), [1.2, 0.5])
        XCTAssertTrue(batch.filter { $0.type == .tempBasal }.allSatisfy { !$0.isMutable })
        XCTAssertEqual(batch.filter { $0.type == .basal }.count, 1)
    }

    // MARK: - Restarts, patch changes, midnight

    /// A restart with a chain: the first batch carries it mutable, and a sync reads the records that make its finals
    func testRestartWithAChainKeepsItOpenAndReadsItsRecords() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()
        scriptReplacement(of: 2)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.8, duration: 30 * Self.minute))
        settle()

        let restarted = try restart(from: delegate.savedState)
        restarted.emitPumpEvents([])
        settle()
        let first = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose)).sorted { $0.startDate < $1.startDate }
        XCTAssertEqual(first.map(\.unitsPerHour), [1.2, 0.5, 0.8])
        XCTAssertTrue(first.allSatisfy(\.isMutable))
        XCTAssertEqual(first[0].endDate, first[1].startDate)
        XCTAssertEqual(first[1].endDate, first[2].startDate)

        for answer in recordsThroughTheSecond(delivered: 0.05) + [.fragments(scheduledSecond(sequence: 134, at: Self.end2))] {
            link.script(CommandType.GET_RECORD, answer)
        }
        syncRecords()

        XCTAssertFalse(restarted.hasOpenTempBasalEnds)
        XCTAssertEqual(finals(of: first[0]).first?.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(finals(of: first[1]).first?.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
    }

    /// The patch deactivated with a chain: the read before the stop gets the old one's record, the running one goes final
    /// from our estimate with the suspend
    func testDeactivationWithAChainFinalizesItInOrder() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        link.script(CommandType.GET_RECORD, .fragments(scheduledSecond(sequence: 132, at: Self.end1)))
        link.script(
            CommandType.STOP_PATCH,
            PatchBytes.answer(command: CommandType.STOP_PATCH, body: UInt64(10).toData(length: 2) + Self.patchId.toData(length: 2))
        )
        let result: MedtrumDeactivatePatchResult? = completion(of: "deactivatePatch") { done in
            self.pumpManager.deactivatePatch(done)
        }
        settle()
        guard case .success? = result else {
            XCTFail("Not deactivated: \(String(describing: result))")
            return
        }

        let old = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 && !$0.isMutable })
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record, read before the stop")
        XCTAssertEqual(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 }).count, 1)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// The patch session ending with no read - a forced deactivation: every temp basal goes final from our estimate,
    /// in order, with the suspend
    func testForcedDeactivationWithAChainFinalizesItFromOurEstimate() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        pumpManager.forceDeactivatePatch()
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .suspend])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false])
        XCTAssertEqual(batch[0].endDate, batch[1].startDate)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// The old one split at patch-local midnight, 10 min in: the cancel names its second half, and the read after the
    /// command gets both - its final their sum
    func testTempBasalSplitAtMidnightEndedBackToBackIsFinalizedFromBothHalves() throws {
        runFirst()
        let midnight = Self.start1.addingTimeInterval(600)
        pumpManager.state.patchUTCOffset = 24 * Self.hour - midnight.timeIntervalSince1970.truncatingRemainder(dividingBy: 24 * Self.hour)

        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 132, at: Self.end1))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(rate: 0.5, record: 133, at: Self.end1.addingTimeInterval(1)))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.start1, end: midnight, rate: 1.2, delivered: 0.15
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: midnight, end: Self.end1, rate: 1.2, delivered: 0.2
        ))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "both halves")
        XCTAssertEqual(final.endDate, pumpManager.state.basalDose.startDate)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// The same, the first half read while it ran: kept on it, and summed with the second half read after the command
    func testTempBasalSplitAtMidnightWhoseFirstHalfWasReadWhileItRanIsFinalizedFromBoth() throws {
        runFirst(sequence: 130)
        let midnight = Self.start1.addingTimeInterval(600)
        pumpManager.state.patchUTCOffset = 24 * Self.hour - midnight.timeIntervalSince1970.truncatingRemainder(dividingBy: 24 * Self.hour)
        pumpManager.state.currentSequenceNumber = 131
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.start1, end: midnight, rate: 1.2, delivered: 0.15
        ))
        syncRecords()
        XCTAssertEqual(pumpManager.state.basalDose.snapshot.recordedParts.map(\.sequence), [131])

        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 132, at: Self.end1))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(rate: 0.5, record: 133, at: Self.end1.addingTimeInterval(1)))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: midnight, end: Self.end1, rate: 1.2, delivered: 0.2
        ))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "both halves")
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// A status showing the old one's segment after it ended back to back is not one of a temp basal none of ours: no
    /// warning
    func testOldSegmentShownAfterItEndedBackToBackIsNotWarnedOf() {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        link.notify(running(rate: 1.2, from: Self.start1, sequence: 132))
        settle()

        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds)
    }

    // MARK: - At the same rate

    /// The new one at the same rate as the old: a cancel to the schedule after them reads both, each final from its own
    /// record - the second one's record, starting where the first ended, is not taken as a part of the first
    func testSameRateChainCancelledFinalizesEachFromItsOwnRecord() throws {
        runFirst()
        scriptReplacement(of: 1, rate: 1.2)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        settle()

        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 133, at: Self.end2))
        for answer in recordsThroughTheSecond(delivered: 0.1, rate: 1.2) {
            link.script(CommandType.GET_RECORD, answer)
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .basal])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001, "the first one's record, not our estimate")
        XCTAssertEqual(batch[1].deliveredUnits ?? 0, 0.1, accuracy: 0.001, "the second one's record")
        XCTAssertEqual(pumpManager.recordStore.records.filter { $0.outcome?.hasPrefix("finalized temp basal") == true }.map(\.id).sorted(), [131, 133])
    }

    /// The same, the patch suspending after them
    func testSameRateChainSuspendedFinalizesEachFromItsOwnRecord() throws {
        runFirst()
        scriptReplacement(of: 1, rate: 1.2)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        settle()

        for answer in recordsThroughTheSecond(delivered: 0.1, rate: 1.2) {
            link.script(CommandType.GET_RECORD, answer)
        }
        link.notify(halt(.suspended, at: Self.end2, newestRecord: 133))
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .suspend])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(batch[1].deliveredUnits ?? 0, 0.1, accuracy: 0.001)
    }

    /// The same, the second one running its course: its record, and the first one's, settle the read before the record
    /// after them
    func testSameRateChainExpiredFinalizesEachFromItsOwnRecord() throws {
        runFirst()
        scriptReplacement(of: 1, rate: 1.2)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(1.2, duration: 5 * Self.minute))
        settle()

        let expiredAt = Self.end1.addingTimeInterval(301)
        for answer in recordsThroughTheSecond(delivered: 0.1, rate: 1.2, end: expiredAt) {
            link.script(CommandType.GET_RECORD, answer)
        }
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 134, patchId: Self.patchId, start: expiredAt, rate: 0.7))
        settle()

        XCTAssertEqual(link.writtenCommands.filter { $0 == CommandType.GET_RECORD }.count, 4, "1 timed out, 131 - 133: 134 left to the sync")
        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .basal])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(batch[1].deliveredUnits ?? 0, 0.1, accuracy: 0.001)
    }

    /// 1.2, then 0.5, then 1.2 again, all read as the third is cancelled: each final from its own record - the third
    /// one's record not taken as a part of the first
    func testSameRateTwoApartFinalizesEachFromItsOwnRecord() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        scriptReplacement(of: 2, rate: 1.2)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        settle()

        // The third, at 1.2 U/h again, cancelled: every record read in the command, the third's starting where the
        // second one's ended
        let end3 = Self.end2.addingTimeInterval(300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 135, at: end3))
        for answer in recordsThroughTheSecond(delivered: 0.05) {
            link.script(CommandType.GET_RECORD, answer)
        }
        link.script(CommandType.GET_RECORD, scheduledSecond(sequence: 134, at: Self.end2))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 135, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end2.addingTimeInterval(1), end: end3, rate: 1.2, delivered: 0.1
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let finals = reports(of: .tempBasal).filter { !$0.isMutable }.sorted { $0.startDate < $1.startDate }
        XCTAssertEqual(finals.map(\.unitsPerHour), [1.2, 0.5, 1.2])
        XCTAssertEqual(finals.map { $0.deliveredUnits ?? -1 }, [0.35, 0.05, 0.1])
    }

    // MARK: - The patch had stopped it before the cancel

    /// The cancel says the old one ended 5 min before it went out - an earlier cancel that went unanswered, say: the patch
    /// ran the schedule since. Not ended back to back: final from its record, at its record's end - 900 s - and the gap
    /// to the new one left for the host to fill with the schedule
    func testTempBasalThePatchHadStoppedBeforeTheCancelLeavesTheGapToTheSchedule() throws {
        let first = runFirst()
        let stoppedAt = Self.end1.addingTimeInterval(-300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: stoppedAt))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(rate: 0.5, record: 132, at: Self.end1.addingTimeInterval(1)))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.3, end: stoppedAt))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(delegate.batches.count, 1, "never mutable once ended")
        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.unitsPerHour), [1.2, 0.5])
        XCTAssertEqual(batch[0].isMutable, false)
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(batch[0].endDate.timeIntervalSince(first.startDate), 900, accuracy: 0.5, "its record's duration")
        XCTAssertEqual(batch[1].startDate.timeIntervalSince(batch[0].endDate), 300, accuracy: 1, "the schedule's, for the host to fill")
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// The same, cancelled to the schedule: final at its record's end, the scheduled basal reported from the cancel - the
    /// gap between the host's to fill
    func testTempBasalThePatchHadStoppedBeforeACancelToTheScheduleEndsAtItsRecord() throws {
        let first = runFirst()
        let stoppedAt = Self.end1.addingTimeInterval(-300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: stoppedAt))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.3, end: stoppedAt))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .basal])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(batch[0].endDate.timeIntervalSince(first.startDate), 900, accuracy: 0.5)
        XCTAssertEqual(batch[1].startDate.timeIntervalSince(batch[0].endDate), 300, accuracy: 1)
    }

    /// A real early stop, our reading of the patch clock an hour off either way: told on each clock alone - the patch
    /// ran it 900 s, we had it 1200 s - it is still found, and the old one ends at its record's end
    func testTempBasalThePatchHadStoppedIsFoundWithThePatchClockAnHourAhead() throws {
        try assertStoppedBeforeTheCancel(patchAhead: 3600, cancelOnly: false)
    }

    func testTempBasalThePatchHadStoppedIsFoundWithThePatchClockAnHourBehind() throws {
        try assertStoppedBeforeTheCancel(patchAhead: -3600, cancelOnly: false)
    }

    func testTempBasalThePatchHadStoppedIsFoundOnACancelWithThePatchClockAnHourAhead() throws {
        try assertStoppedBeforeTheCancel(patchAhead: 3600, cancelOnly: true)
    }

    func testTempBasalThePatchHadStoppedIsFoundOnACancelWithThePatchClockAnHourBehind() throws {
        try assertStoppedBeforeTheCancel(patchAhead: -3600, cancelOnly: true)
    }

    private func assertStoppedBeforeTheCancel(patchAhead: TimeInterval, cancelOnly: Bool, line: UInt = #line) throws {
        let first = runFirst(patchAhead: patchAhead)
        let stoppedAt = Self.end1.addingTimeInterval(-300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: stoppedAt))
        if !cancelOnly {
            link.script(CommandType.SET_TEMP_BASAL, setAnswer(rate: 0.5, record: 132, at: Self.end1.addingTimeInterval(1)))
        }
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.3, end: stoppedAt))
        XCTAssertNil(cancelOnly ? commandTempBasal(0, duration: 0) : commandTempBasal(0.5, duration: 30 * Self.minute), line: line)
        settle()

        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose), line: line)
        XCTAssertEqual(batch.first?.isMutable, false, "never mutable once ended", line: line)
        XCTAssertEqual(batch.first?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, line: line)
        XCTAssertEqual(batch.first.map { $0.endDate.timeIntervalSince(first.startDate) } ?? 0, 900, accuracy: 0.5, line: line)
        // Real time passes between the fixture and the command: a few seconds on a loaded machine
        XCTAssertEqual(batch.last.map { $0.startDate.timeIntervalSince(batch[0].endDate) } ?? 0, 300, accuracy: 5, line: line)
    }

    /// No early stop, our reading of the patch clock minutes off either way - the skew is read every 30 min at best: the
    /// old one ran to the cancel, back to back on a cancel and set, its whole 1200 s, its record's amount
    func testTempBasalReplacedWithThePatchClockMinutesAheadEndsBackToBack() throws {
        try assertReplacedBackToBack(patchAhead: 300)
    }

    func testTempBasalReplacedWithThePatchClockMinutesBehindEndsBackToBack() throws {
        try assertReplacedBackToBack(patchAhead: -300)
    }

    private func assertReplacedBackToBack(patchAhead: TimeInterval) throws {
        do {
            let first = runFirst(patchAhead: patchAhead)
            scriptReplacement(of: 1)
            link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
            XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
            settle()

            let open = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
            XCTAssertEqual(open.map(\.isMutable), [true, true], "back to back, skew \(patchAhead)")
            let final = try XCTUnwrap(finals(of: open.first).first)
            XCTAssertEqual(final.endDate, open.last?.startDate)
            XCTAssertEqual(final.endDate.timeIntervalSince(first.startDate), 1200, accuracy: 5)
            XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        }
    }

    /// The same, cancelled to the schedule: it ends at the cancel, its whole 1200 s, its record's amount
    func testTempBasalCancelledWithThePatchClockMinutesAheadRunsToTheCancel() throws {
        try assertCancelledToTheCancel(patchAhead: 300)
    }

    func testTempBasalCancelledWithThePatchClockMinutesBehindRunsToTheCancel() throws {
        try assertCancelledToTheCancel(patchAhead: -300)
    }

    private func assertCancelledToTheCancel(patchAhead: TimeInterval) throws {
        do {
            let first = runFirst(patchAhead: patchAhead)
            link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1))
            link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
            XCTAssertNil(commandTempBasal(0, duration: 0))
            settle()

            let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
            XCTAssertEqual(batch.map(\.type), [.tempBasal, .basal])
            XCTAssertEqual(batch[0].endDate, batch[1].startDate)
            XCTAssertEqual(batch[0].endDate.timeIntervalSince(first.startDate), 1200, accuracy: 5, "skew \(patchAhead)")
            XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        }
    }

    /// The patch says it ran the old one no time at all: not ended at its start - the host would drop it as 0-duration -
    /// but where we saw it end, its record's amount
    func testTempBasalThePatchRanNoTimeIsNotEndedAtItsStart() throws {
        let first = runFirst()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.start1))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0, end: Self.start1))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .basal])
        XCTAssertEqual(batch[0].endDate.timeIntervalSince(first.startDate), 1200, accuracy: 5)
        XCTAssertEqual(batch[0].endDate, batch[1].startDate)
        XCTAssertEqual(batch[0].deliveredUnits ?? 1, 0, accuracy: 0.001)
    }

    /// Its patch start taken from a status - a later segment's, maybe: how long the patch ran it is not told from it, nor
    /// does a short record mean it stopped early - its records cover what it ran since that patch start. Ended open, its
    /// final ends where the next one starts.
    func testTempBasalEndedBackToBackWithAnAdoptedPatchStartEndsWhereTheNextOneStarts() throws {
        let state = activePatchState(patchId: Self.patchId, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        var raw = runningTempBasal(rate: 1.2, startedAgo: 20 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.start1).rawValue
        raw["firstSegmentUncertain"] = true
        let first = try XCTUnwrap(UnfinalizedDose(rawValue: raw))
        state.basalDose = first
        state.basalState = .tempBasal
        state.lastSegmentStart = Self.start1
        alignPatchClock(state, patchTime: Self.end1)
        makeManager(state)

        let stoppedAt = Self.end1.addingTimeInterval(-300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: stoppedAt))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(rate: 0.5, record: 132, at: Self.end1.addingTimeInterval(1)))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.3, end: stoppedAt))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let open = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(open.map(\.isMutable), [true, true])
        let final = try XCTUnwrap(finals(of: open.first).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(final.endDate, open.last?.startDate)
        XCTAssertGreaterThan(final.endDate.timeIntervalSince(first.startDate), 1100)
    }

    /// The same cancelled to the schedule: the records' end does not cut it short either - it ends at the cancel
    func testTempBasalCancelledWithAnAdoptedPatchStartEndsAtTheCancel() throws {
        let state = activePatchState(patchId: Self.patchId, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        var raw = runningTempBasal(rate: 1.2, startedAgo: 20 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.start1).rawValue
        raw["firstSegmentUncertain"] = true
        let first = try XCTUnwrap(UnfinalizedDose(rawValue: raw))
        state.basalDose = first
        state.basalState = .tempBasal
        state.lastSegmentStart = Self.start1
        alignPatchClock(state, patchTime: Self.end1)
        makeManager(state)

        let stoppedAt = Self.end1.addingTimeInterval(-300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: stoppedAt))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.3, end: stoppedAt))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .basal])
        XCTAssertEqual(batch[0].endDate, batch[1].startDate, "at the cancel, not its records' end")
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.3, accuracy: 0.001)
    }

    /// Its command 30 s before its answer - a slow hand-over and transfer: how long we had it running counts from the
    /// answer, so the patch's 1200 s are not taken for a stop before the cancel. Back to back.
    func testTempBasalWhoseCommandWentOutWellBeforeItsAnswerIsNotTakenAsStoppedBefore() throws {
        let state = activePatchState(patchId: Self.patchId, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        var raw = runningTempBasal(rate: 1.2, startedAgo: 20 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.start1).rawValue
        raw["sentAt"] = (raw["startDate"] as? Date)?.addingTimeInterval(-30)
        state.basalDose = try XCTUnwrap(UnfinalizedDose(rawValue: raw))
        state.basalState = .tempBasal
        state.lastSegmentStart = Self.start1
        alignPatchClock(state, patchTime: Self.end1)
        makeManager(state)

        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let open = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(open.map(\.isMutable), [true, true], "back to back")
        XCTAssertEqual(finals(of: open.first).first?.endDate, open.last?.startDate)
    }

    /// The set after an answered cancel unanswered, the cancel saying the patch had stopped the old one 5 min before: it
    /// ends there - from our estimate, nothing read on that link - the schedule from the cancel
    func testUnansweredSetAfterACancelTheOldOneHadStoppedBeforeEndsItThere() throws {
        let first = runFirst()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1.addingTimeInterval(-300)))
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL])
        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .basal])
        XCTAssertEqual(batch[0].endDate.timeIntervalSince(first.startDate), 900, accuracy: 0.5)
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.3, accuracy: 0.001, "1.2 U/h × 900 s, by our estimate")
        XCTAssertEqual(batch[1].startDate.timeIntervalSince(batch[0].endDate), 300, accuracy: 1)
    }

    /// A few seconds between where the patch says it ended and the cancel - the skew is known to that only: back to back
    func testTempBasalEndedSecondsBeforeTheCancelOnThePatchClockIsStillBackToBack() throws {
        runFirst(patchAhead: 3)
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let open = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(open.map(\.isMutable), [true, true])
        let final = try XCTUnwrap(finals(of: open.first).first)
        XCTAssertEqual(final.endDate, open.last?.startDate)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
    }

    // MARK: - Reading after the command

    /// A suspend command after a chain, its status not in: no record of the running one's end is known, but the command
    /// was answered - the chain's records are read in it, up to 132, the newest told of before it - the running one's
    /// end among them, had the patch ended it unseen - and the running one goes final from our estimate
    func testSuspendCommandAfterAChainReadsItsRecords() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .STANDARD, start: Self.end1, end: Self.end1.addingTimeInterval(1), rate: 0.7, delivered: 0
        ))
        XCTAssertNil(commandSuspend())
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .suspend])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false])
    }

    /// The loop's bolus right behind the temp basal: the read after the command finds it running and waits - and reads
    /// as soon as it is over, with no sync to wait for
    func testRecordsAreReadOnceTheBolusRightAfterIsOver() throws {
        runFirst(patchId: 236)
        pumpManager.openTempBasalEndReadDelay = 1
        scriptReplacement(of: 1, patchId: 236)
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")

        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        XCTAssertNil(commandBolus(2.0))
        Thread.sleep(forTimeInterval: 1.5)
        settle()
        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_BOLUS, "nothing read while it runs")

        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35, patchId: 236))
        // The bolus waiting on its record: read on past the old one's, to the scheduled second after it
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: 236, type: .STANDARD, start: Self.end1, end: Self.end1.addingTimeInterval(1), rate: 0.7, delivered: 0
        ))
        link.notify("202211802800040d7b00ec000000000000")
        settle()

        XCTAssertEqual(link.writtenCommands.last, CommandType.GET_RECORD)
        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// The same, the bolus's own record written after the old one's: the read once it is over, up to the old one's
    /// record, reads on to it - the bolus final in that read, not a minute later behind the heartbeat's throttle
    func testBolusRecordAfterTheTempBasalsIsReadInTheSameRead() throws {
        runFirst()
        pumpManager.openTempBasalEndReadDelay = 1
        scriptReplacement(of: 1)
        let bolusStart = Self.end1.addingTimeInterval(2)
        link.script(CommandType.SET_BOLUS, bolusAnswer(record: 133, start: bolusStart))

        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        XCTAssertNil(commandBolus(0.5, activationType: .automatic))
        Thread.sleep(forTimeInterval: 1.5)
        settle()
        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_BOLUS, "nothing read while it runs")

        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        link.script(CommandType.GET_RECORD, scheduledSecond(sequence: 132, at: Self.end1))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 133, patchId: Self.patchId, start: bolusStart, amount: 0.5, delivered: 0.45
        ))
        link.notify(completion(delivered: 0.5, record: 133))
        settle()

        XCTAssertEqual(link.writtenCommands.suffix(4), [
            CommandType.SET_BOLUS, CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_RECORD
        ])
        // Each asked for once, as the old one's own: a bolus right behind waits for one no longer
        XCTAssertTrue(link.writes.suffix(3).allSatisfy { $0.timeout <= MedtrumPumpManager.tempBasalEndRecordTimeout })
        let tempBasalFinal = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(tempBasalFinal.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        let bolusFinal = try XCTUnwrap(finals(of: reports(of: .bolus).first).first)
        XCTAssertEqual(bolusFinal.deliveredUnits ?? 0, 0.45, accuracy: 0.001, "from its record")
        XCTAssertLessThanOrEqual(batchIndex(ofFinal: tempBasalFinal) ?? .max, batchIndex(ofFinal: bolusFinal) ?? -1)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 133)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// Device 2026-10-22 20:18:59: the loop's bolus right behind the set, the old one's read waiting for it to be over -
    /// and the patch runs empty, the halt and the bolus's completion in one notification. The halt ends the new one,
    /// read up to the record it names; the bolus's end waits behind that read, not taking both out from our estimate:
    /// both final from their records, then the suspend, then the bolus - final from its record, read on the way
    func testHaltWithTheBolussCompletionReadsTheTempBasalsItEndedBeforeTheBolusGoesOut() throws {
        let (bolus, second) = try startBolusRightAfterTheSet()

        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        link.script(CommandType.GET_RECORD, scheduledSecond(sequence: 132, at: Self.end1))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 133, patchId: Self.patchId, start: Self.end1.addingTimeInterval(2), amount: 0.5, delivered: 0.3
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 134, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(1),
            end: Self.end1.addingTimeInterval(4), rate: 0.5, delivered: 0.05, endReason: .STOP_EMPTY
        ))
        link.notify(emptyWithCompletion(delivered: 0.3, newestRecord: 135))
        settle()

        // Read up to the new one's record, which settles it: 135 is left to the sync
        XCTAssertEqual(link.writtenCommands.suffix(5), [
            CommandType.SET_BOLUS, CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_RECORD
        ])
        let firstFinal = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(firstFinal.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        let secondFinal = try XCTUnwrap(finals(of: second).first)
        XCTAssertEqual(secondFinal.deliveredUnits ?? 0, 0.05, accuracy: 0.001, "from its record")
        XCTAssertEqual(finals(of: second).count, 1)

        // One batch: the finals, then the suspend, then the bolus waiting on its record
        let index = try XCTUnwrap(batchIndex(ofFinal: firstFinal))
        XCTAssertEqual(batchIndex(ofFinal: secondFinal), index)
        let batch = delegate.batches[index].events.compactMap(\.dose)
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .suspend, .bolus])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false, true])
        XCTAssertEqual(batch[3].deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertFalse(
            delegate.batches[..<index].contains { $0.events.contains { $0.dose?.type == .suspend } },
            "nothing ahead of the finals"
        )

        let bolusFinal = try XCTUnwrap(finals(of: bolus).first)
        XCTAssertEqual(bolusFinal.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "from its record")
        XCTAssertGreaterThan(batchIndex(ofFinal: bolusFinal) ?? -1, index)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 134)
    }

    /// The same, the records not readable: both final from our estimate, as before - then the suspend, then the bolus
    func testHaltWithTheBolussCompletionWhoseReadFailsGoesFinalFromOurEstimate() throws {
        let (_, second) = try startBolusRightAfterTheSet()

        link.script(CommandType.GET_RECORD, .timeout)
        link.notify(emptyWithCompletion(delivered: 0.3, newestRecord: 135))
        settle()

        XCTAssertEqual(link.writtenCommands.last, CommandType.GET_RECORD)
        let firstFinal = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(firstFinal.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        let secondFinal = try XCTUnwrap(finals(of: second).first)
        XCTAssertEqual(secondFinal.deliveredUnits ?? -1, 0, accuracy: 0.001, "by our estimate: seconds at 0.5 U/h")
        let index = try XCTUnwrap(batchIndex(ofFinal: firstFinal))
        let batch = delegate.batches[index].events.compactMap(\.dose)
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .suspend, .bolus])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false, true])
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
    }

    /// The same on the device's slow link: 7 s a record (20:18:59-20:19:20), the four past `tempBasalEndReadBudget`. The
    /// patch suspended and no command waiting, they are read all the same - both final from their records
    func testHaltWithTheBolussCompletionReadsTheTempBasalsItEndedOnASlowLink() throws {
        let (_, second) = try startBolusRightAfterTheSet()

        let slow = { [unowned self] in self.advanceClock(by: 7) }
        link.script(CommandType.GET_RECORD, .fragments(recordOfFirst(delivered: 0.35)), then: slow)
        link.script(CommandType.GET_RECORD, .fragments(scheduledSecond(sequence: 132, at: Self.end1)), then: slow)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.bolusRecord(
            sequence: 133, patchId: Self.patchId, start: Self.end1.addingTimeInterval(2), amount: 0.5, delivered: 0.3
        )), then: slow)
        link.script(CommandType.GET_RECORD, .fragments(secondsRecordEmptied()), then: slow)
        link.notify(emptyWithCompletion(delivered: 0.3, newestRecord: 135))
        settle()

        let firstFinal = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(firstFinal.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        let secondFinal = try XCTUnwrap(finals(of: second).first)
        XCTAssertEqual(secondFinal.deliveredUnits ?? 0, 0.05, accuracy: 0.001, "from its record")
        XCTAssertTrue(
            link.writes.suffix(4).allSatisfy { $0.timeout > MedtrumPumpManager.tempBasalEndRecordTimeout - 1 },
            "each given the time a record may take"
        )
    }

    /// The halt's notification ahead of the bolus's completion, which comes in one of its own: the read waits for the
    /// bolus to be over, not taking both out from our estimate at the halt - then as with the two in one
    func testHaltWithTheBolusStillRunningReadsTheTempBasalsOnceItCompletes() throws {
        let (bolus, second) = try startBolusRightAfterTheSet()

        link.notify(halt(.reservoirEmpty, at: nil, newestRecord: 135))
        settle()
        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_BOLUS, "nothing read while it runs")
        XCTAssertTrue(finals(of: second).isEmpty, "not from our estimate")
        XCTAssertNotNil(pumpManager.pendingTempBasalEnd)
        XCTAssertFalse(delegate.batches.contains { $0.events.contains { $0.dose?.type == .suspend } })

        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        link.script(CommandType.GET_RECORD, scheduledSecond(sequence: 132, at: Self.end1))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 133, patchId: Self.patchId, start: Self.end1.addingTimeInterval(2), amount: 0.5, delivered: 0.3
        ))
        link.script(CommandType.GET_RECORD, secondsRecordEmptied())
        link.notify(emptyWithCompletion(delivered: 0.3, newestRecord: 135))
        settle()

        let firstFinal = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(firstFinal.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        let secondFinal = try XCTUnwrap(finals(of: second).first)
        XCTAssertEqual(secondFinal.deliveredUnits ?? 0, 0.05, accuracy: 0.001, "from its record")
        let index = try XCTUnwrap(batchIndex(ofFinal: firstFinal))
        let batch = delegate.batches[index].events.compactMap(\.dose)
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .suspend, .bolus])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false, true])
        let bolusFinal = try XCTUnwrap(finals(of: bolus).first)
        XCTAssertEqual(bolusFinal.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "from its record")
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
    }

    /// The same, the bolus's end never seen - the link lost: not waited on for good, both final from our estimate with
    /// the suspend once `tempBasalEndBolusWait` is up
    func testHaltWithTheBolusStillRunningGoesFinalFromOurEstimateOnceTheWaitIsUp() throws {
        let wait = MedtrumPumpManager.tempBasalEndBolusWait
        MedtrumPumpManager.tempBasalEndBolusWait = 0.5
        defer { MedtrumPumpManager.tempBasalEndBolusWait = wait }
        let (_, second) = try startBolusRightAfterTheSet()

        link.notify(halt(.reservoirEmpty, at: nil, newestRecord: 135))
        settle()
        XCTAssertTrue(finals(of: second).isEmpty)

        Thread.sleep(forTimeInterval: 1)
        settle()

        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_BOLUS, "nothing read")
        let firstFinal = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(firstFinal.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        XCTAssertEqual(finals(of: second).first?.deliveredUnits ?? -1, 0, accuracy: 0.001, "by our estimate")
        let index = try XCTUnwrap(batchIndex(ofFinal: firstFinal))
        XCTAssertEqual(delegate.batches[index].events.compactMap(\.dose).map(\.type).prefix(3), [.tempBasal, .tempBasal, .suspend])
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
    }

    /// The patch halts as the cancel's record is read in the command: the suspend waits behind the old one's final -
    /// from its record - and the schedule the cancel started, not taking it out from our estimate
    func testHaltDuringTheReadOfTheCancelsRecordIsReportedBehindItsFinal() throws {
        runFirst()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1))
        link.script(
            CommandType.GET_RECORD,
            .fragments(recordOfFirst(delivered: 0.35)),
            thenNotify: [halt(.reservoirEmpty, at: nil, newestRecord: 132)]
        )
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        let index = try XCTUnwrap(batchIndex(ofFinal: final))
        XCTAssertEqual(delegate.batches[index].events.compactMap(\.dose).map(\.type), [.tempBasal, .basal, .suspend])
        XCTAssertFalse(delegate.batches[..<index].contains { $0.events.contains { $0.dose?.type == .suspend } })
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
    }

    /// The halted one's record took the number the bolus's answer named - #133 - as it ran, the bolus's own #134. Read
    /// as the temp basal ends, and taken by it there, it still tells the bolus's record is the next: final from it
    func testTempBasalsRecordReadAsItEndsAtTheBolussAnsweredNumberLeavesTheBolusItsNext() throws {
        let (bolus, second) = try startBolusRightAfterTheSet()

        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        link.script(CommandType.GET_RECORD, scheduledSecond(sequence: 132, at: Self.end1))
        link.script(CommandType.GET_RECORD, secondsRecordEmptied(sequence: 133))
        link.notify(emptyWithCompletion(delivered: 0.3, newestRecord: 134))
        settle()
        XCTAssertEqual(finals(of: second).first?.deliveredUnits ?? -1, 0.05, accuracy: 0.001, "from its record")
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 133)
        XCTAssertTrue(finals(of: bolus).isEmpty)

        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 134, patchId: Self.patchId, start: Self.end1.addingTimeInterval(2), amount: 0.5, delivered: 0.3
        ))
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 134 }?.outcome?.hasPrefix("finalized bolus"), true)
        let bolusFinal = try XCTUnwrap(finals(of: bolus).first)
        XCTAssertEqual(bolusFinal.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "from its record")
    }

    /// The read waiting for the bolus to be over, the bolus is cancelled at 0.2 U - and the patch's completion after the
    /// cancel, 0.25 U, comes as the records are read: the batch they make carries 0.25, not the cancel's 0.2
    func testBolusCancelledWhileTheReadWaitsGoesOutWithWhatItsCompletionRaisedIt() throws {
        let (bolus, _) = try startBolusRightAfterTheSet()
        link.notify("200200" + "000400")
        link.notify(halt(.reservoirEmpty, at: nil, newestRecord: 135))
        settle()

        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        link.script(
            CommandType.GET_RECORD,
            .fragments(recordOfFirst(delivered: 0.35)),
            thenNotify: [emptyWithCompletion(delivered: 0.25, newestRecord: 135)]
        )
        link.script(CommandType.GET_RECORD, scheduledSecond(sequence: 132, at: Self.end1))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 133, patchId: Self.patchId, start: Self.end1.addingTimeInterval(2), amount: 0.5, delivered: 0.25
        ))
        link.script(CommandType.GET_RECORD, secondsRecordEmptied())
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            return
        }
        settle()

        let firstFinal = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        let index = try XCTUnwrap(batchIndex(ofFinal: firstFinal))
        let batch = delegate.batches[index].events.compactMap(\.dose)
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .suspend, .bolus])
        XCTAssertEqual(batch[3].isMutable, true)
        XCTAssertEqual(batch[3].deliveredUnits ?? 0, 0.25, accuracy: 0.001, "as its completion raised it")
        XCTAssertEqual(finals(of: bolus).first?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from its record")
    }

    /// The slow link's read, and the loop's patch time fetch waiting for the link meanwhile - not a command: the read
    /// takes no longer than `tempBasalEndReadBudget` for it, stopping before the fourth record, and the fetch goes out
    func testHaltWithTheBolussCompletionReadOnASlowLinkStopsForTheLoopWaitingOnIt() throws {
        let (_, second) = try startBolusRightAfterTheSet()

        link.script(CommandType.GET_TIME, PatchBytes.answer(command: CommandType.GET_TIME, body: Date.now.toMedtrumSeconds()))
        let fetched = expectation(description: "GetTime")
        let slow = { [unowned self] in self.advanceClock(by: 7) }
        link.script(CommandType.GET_RECORD, .fragments(recordOfFirst(delivered: 0.35)), then: slow)
        link.script(CommandType.GET_RECORD, .fragments(scheduledSecond(sequence: 132, at: Self.end1))) { [unowned self] in
            slow()
            pumpManager.state.pumpTimeSyncedAt = .distantPast
            DispatchQueue.global().async {
                StateSyncer.fetchPatchTimeIfStale(pumpManager: self.pumpManager)
                fetched.fulfill()
            }
            let deadline = Date.now.addingTimeInterval(1)
            while pumpManager.readsLongerAsTempBasalEnds, Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.bolusRecord(
            sequence: 133, patchId: Self.patchId, start: Self.end1.addingTimeInterval(2), amount: 0.5, delivered: 0.3
        )), then: slow)
        link.notify(emptyWithCompletion(delivered: 0.3, newestRecord: 135))
        wait(for: [fetched], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands.suffix(4), [
            CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_TIME
        ])
        let firstFinal = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(firstFinal.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(finals(of: second).first?.deliveredUnits ?? -1, 0, accuracy: 0.001, "by our estimate: its record unread")
    }

    /// The slow link's read, and the user deactivating the emptied patch meanwhile - waiting for the link, no command:
    /// the read stops at the next record, within `tempBasalEndReadBudget`, and the deactivation goes out - its read
    /// before the stop taking the records left
    func testHaltWithTheBolussCompletionReadOnASlowLinkStopsForADeactivation() throws {
        let (_, second) = try startBolusRightAfterTheSet()

        let deactivated = expectation(description: "deactivatePatch")
        let result = Locked<MedtrumDeactivatePatchResult?>(nil)
        let slow = { [unowned self] in self.advanceClock(by: 7) }
        link.script(CommandType.GET_RECORD, .fragments(recordOfFirst(delivered: 0.35)), then: slow)
        link.script(CommandType.GET_RECORD, .fragments(scheduledSecond(sequence: 132, at: Self.end1))) { [unowned self] in
            slow()
            DispatchQueue.global().async {
                self.pumpManager.deactivatePatch { outcome in
                    result.value = outcome
                    deactivated.fulfill()
                }
            }
            let deadline = Date.now.addingTimeInterval(1)
            while pumpManager.readsLongerAsTempBasalEnds, Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.bolusRecord(
            sequence: 133, patchId: Self.patchId, start: Self.end1.addingTimeInterval(2), amount: 0.5, delivered: 0.3
        )), then: slow)
        // The deactivation's read before the stop
        link.script(CommandType.GET_RECORD, secondsRecordEmptied())
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 10, sequence: 135, patchId: Self.patchId))
        link.script(
            CommandType.STOP_PATCH,
            PatchBytes.answer(command: CommandType.STOP_PATCH, body: UInt64(10).toData(length: 2) + Self.patchId.toData(length: 2))
        )
        link.notify(emptyWithCompletion(delivered: 0.3, newestRecord: 135))
        wait(for: [deactivated], timeout: 5)
        settle()

        guard case .success? = result.value else {
            XCTFail("Not deactivated: \(String(describing: result.value))")
            return
        }
        XCTAssertEqual(link.writtenCommands.suffix(6), [
            CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_RECORD,
            CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.STOP_PATCH
        ])
        let firstFinal = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(firstFinal.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(finals(of: second).first?.deliveredUnits ?? -1, 0, accuracy: 0.001, "by our estimate: the read stopped short of it")
    }

    /// A wait for the link never over - its connect's completion orphaned - holds the longer read off only until
    /// `loopWaitExpiry`, then no longer counts, with a warning
    func testWaitForTheLinkNeverOverNoLongerCountsOnceItExpires() {
        let expiry = MedtrumPumpManager.loopWaitExpiry
        MedtrumPumpManager.loopWaitExpiry = 0.3
        defer { MedtrumPumpManager.loopWaitExpiry = expiry }
        runFirst()
        MedtrumLogger.pumpManager = pumpManager
        defer { MedtrumLogger.pumpManager = nil }
        pumpManager.state.basalDose = UnfinalizedDose(suspendStartTime: Date.now)
        XCTAssertTrue(pumpManager.readsLongerAsTempBasalEnds)

        _ = pumpManager.loopBeginsWaiting()
        XCTAssertFalse(pumpManager.readsLongerAsTempBasalEnds, "waiting")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(pumpManager.readsLongerAsTempBasalEnds, "expired")
        settle()
        XCTAssertEqual(delegate.logEntries.filter { $0.message.contains("no longer counted") }.count, 1)
    }

    /// The 0.5 U/h one's record, `sequence`: from `end1` + 1 s, emptied 3 s later, 0.05 U
    private func secondsRecordEmptied(sequence: Int = 134) -> [String] {
        PatchBytes.basalRecord(
            sequence: sequence, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(1),
            end: Self.end1.addingTimeInterval(4), rate: 0.5, delivered: 0.05, endReason: .STOP_EMPTY
        )
    }

    /// The 1.2 U/h one replaced by 0.5 U/h back to back, its read after the command waiting for the loop's 0.5 U bolus
    /// right behind - record 133, from `end1` + 2 s - to be over. Returns the bolus's first report and the new one's.
    private func startBolusRightAfterTheSet() throws -> (bolus: DoseEntry, second: DoseEntry) {
        runFirst()
        pumpManager.openTempBasalEndReadDelay = 1
        scriptReplacement(of: 1)
        link.script(CommandType.SET_BOLUS, bolusAnswer(record: 133, start: Self.end1.addingTimeInterval(2)))

        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        XCTAssertNil(commandBolus(0.5, activationType: .automatic))
        Thread.sleep(forTimeInterval: 1.5)
        settle()
        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_BOLUS, "nothing read while it runs")
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds)

        let bolus = try XCTUnwrap(reports(of: .bolus).first)
        let second = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
        return (bolus, second)
    }

    /// The patch's notification that it ran empty - no time of the halt, as it sends one - with the running bolus's
    /// completion at `delivered`, naming `newestRecord` (device 2026-10-22 20:18:59)
    private func emptyWithCompletion(delivered: Double, newestRecord: Int) -> String {
        let storage = UInt64(newestRecord).toData(length: 2) + Self.patchId.toData(length: 2)
        let bolus = Data([0x80]) + UInt64((delivered / 0.05).rounded()).toData(length: 2)
        return (Data([PatchState.reservoirEmpty.rawValue, 0x02, 0x01]) + bolus + storage).hexEncodedString()
    }

    /// Past `openTempBasalEndMaximumWait`, a status's batch - no record sync - makes the old one final from our estimate
    func testOverdueTempBasalEndedBackToBackGoesFinalWithAStatusBatch() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        advanceClock(by: MedtrumPumpManager.openTempBasalEndMaximumWait + Self.minute)
        link.deliverFullStatus(notification: running(rate: 0.5, from: Self.end1.addingTimeInterval(1), sequence: 132), duringReconnect: false)
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        let old = try XCTUnwrap(batch.first { $0.unitsPerHour == 1.2 })
        XCTAssertEqual(old.isMutable, false)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// The patch's schedule shown while the cancel is in flight, and the cancel unanswered: the status is taken once the
    /// cancel failed - the temp basal ended there, final from the record it names, the schedule after it
    func testScheduleShownWhileAnUnansweredCancelWasInFlightIsTakenOnceItFailed() throws {
        let first = runFirst()
        link.script(CommandType.CANCEL_TEMP_BASAL, .timeout) { [unowned self] in
            link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 131, patchId: Self.patchId, start: Self.end1, rate: 0.7))
        }
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()

        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == first.startDate }).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(reports(of: .basal).count, 1)
    }

    /// The old one at 30 U/h, the patch saying it ran it 4 s less than we had it up to the new one's start: our
    /// estimate counts its rate up to the cancel only, 0.05 U less than up to the new one's start. It still ends there.
    func testEstimateOfATempBasalEndedBackToBackCountsItsRateUpToTheCancel() throws {
        runFirst(rate: 30)
        // The patch ran it 4 s less than we had it, up to the next one's start: within what the cancel takes
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1.addingTimeInterval(-4)))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(rate: 0.5, record: 132, at: Self.end1.addingTimeInterval(-3)))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        advanceClock(by: MedtrumPumpManager.openTempBasalEndMaximumWait + Self.minute)
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()

        let open = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 30 })
        let final = try XCTUnwrap(finals(of: open).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 9.95, accuracy: 0.001, "30 U/h × (20 min - 4 s), not 10 U")
        XCTAssertEqual(final.endDate, open.endDate)
    }

    /// The estimate goes from the last status of its segment: 0.1 U 10 min before the cancel, + 1.2 U/h × 10 min
    func testEstimateOfATempBasalEndedBackToBackGoesFromItsLastStatus() throws {
        let first = runFirst()
        let status = NotificationPacket()
        status.totalData = FakeMedtrumLink.bytes(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP, sequence: 130, patchId: Self.patchId, start: Self.start1, rate: 1.2, delivered: 0.1
        ))
        var response = status.parseResponse()
        response.receivedAt = response.receivedAt.addingTimeInterval(-10 * Self.minute)
        response.receivedUptime += uptimeOffset.value - 10 * Self.minute
        link.onQueue { self.pumpManager.handleStatus(response, duringReconnect: false, fullSync: false) }
        settle()
        XCTAssertEqual(first.snapshot.statusDelivery ?? 0, 0.1, accuracy: 0.001)

        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()
        advanceClock(by: MedtrumPumpManager.openTempBasalEndMaximumWait + Self.minute)
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()

        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
    }

    // MARK: - Held, and too many to read

    /// The patch halts as the set awaits its answer: the old one ends at the halt, its records read in the command, and
    /// the new one is held behind its final - one batch, in order
    func testHaltWhileTheSetAwaitsItsAnswerHoldsTheNewOneBehindTheOldOnesFinal() throws {
        runFirst()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1))
        link.script(CommandType.SET_TEMP_BASAL, .fragments(setAnswer(rate: 0.5, record: 132, at: Self.end1.addingTimeInterval(1))), thenNotify: [
            halt(.suspended, at: Self.end1, newestRecord: 131)
        ])
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        // The status asked for right after the command: still halted
        link.script(CommandType.SYNCHRONIZE, haltedStatus())
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .suspend, .tempBasal])
        XCTAssertEqual(batch[0].isMutable, false)
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(batch[0].endDate, batch[1].startDate)

        // The new one, reported running, ended by the status asked for after the command - not left to the next heartbeat
        XCTAssertEqual(link.writtenCommands.last, CommandType.SYNCHRONIZE, "asked for right after the command")
        XCTAssertEqual(link.writtenCommands.filter { $0 == CommandType.SYNCHRONIZE }.count, 1, "once")
        let ended = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 }).first)
        XCTAssertTrue(reports(of: .suspend).contains { $0.startDate == ended.endDate }, "the suspend from where it ended")
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
    }

    /// The same set with no halt shown during it: no status is asked for after it
    func testNoStatusIsAskedForAfterASetWithNoHalt() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertFalse(link.writtenCommands.contains(CommandType.SYNCHRONIZE))
        XCTAssertEqual(pumpManager.state.basalDose.type, .tempBasal)
    }

    /// A full status of the patch halted, nothing but its newest record
    private func haltedStatus() -> FakeMedtrumLink.Answer {
        .fragments(PatchBytes.answer(command: CommandType.SYNCHRONIZE, body: Data(hex: halt(.suspended, at: nil, newestRecord: 131))!))
    }

    /// A cancel to the schedule after a chain naming a record too far on to read now: every one goes final from our
    /// estimate, in order, with the schedule
    func testCancelAfterAChainWithTooManyRecordsToReadFinalizesItFromOurEstimate() throws {
        runFirst()
        scriptReplacement(of: 1)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let last = 131 + MedtrumPumpManager.tempBasalEndMaxRecords
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: last, at: Self.end2))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands.last, CommandType.CANCEL_TEMP_BASAL, "nothing read")
        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .tempBasal, .basal])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.4, accuracy: 0.001)
    }

    // MARK: - Ends dated from the patch start, not the skew

    /// Where the patch stopped the 1.2 U/h one, 10 min in - unseen until a status or a command 10 min later, our reading
    /// of the patch clock an hour off either way: well before its planned end and before it is heard of, so neither
    /// bound gives it - it ends 600 s after its start, as long as the patch ran it
    private static let stoppedAt = start1.addingTimeInterval(600)

    private func recordStoppedAt(endReason: BasalEndReason = .SUCCESS) -> [String] {
        PatchBytes.basalRecord(
            sequence: 131, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.start1, end: Self.stoppedAt, rate: 1.2,
            delivered: 0.2, endReason: endReason
        )
    }

    /// The scheduled basal shown since then
    func testTempBasalTheScheduleEndedEndsWhereThePatchStoppedItWithThePatchClockAnHourAhead() throws {
        try assertScheduleEndsItWhereThePatchStoppedIt(patchAhead: 3600)
    }

    func testTempBasalTheScheduleEndedEndsWhereThePatchStoppedItWithThePatchClockAnHourBehind() throws {
        try assertScheduleEndsItWhereThePatchStoppedIt(patchAhead: -3600)
    }

    private func assertScheduleEndsItWhereThePatchStoppedIt(patchAhead: TimeInterval, line: UInt = #line) throws {
        let first = runFirst(patchAhead: patchAhead)
        link.script(CommandType.GET_RECORD, recordStoppedAt())
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 131, patchId: Self.patchId, start: Self.stoppedAt, rate: 0.7))
        settle()

        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose), line: line)
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .basal], line: line)
        XCTAssertEqual(batch[0].endDate.timeIntervalSince(first.startDate), 600, accuracy: 0.001, line: line)
        XCTAssertEqual(batch[0].endDate, batch[1].startDate, line: line)
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.2, accuracy: 0.001, line: line)
    }

    /// The suspend the patch announced with its time
    func testTempBasalTheSuspendEndedEndsWhereThePatchSuspendedWithThePatchClockAnHourAhead() throws {
        try assertSuspendEndsItWhereThePatchSuspended(patchAhead: 3600)
    }

    func testTempBasalTheSuspendEndedEndsWhereThePatchSuspendedWithThePatchClockAnHourBehind() throws {
        try assertSuspendEndsItWhereThePatchSuspended(patchAhead: -3600)
    }

    private func assertSuspendEndsItWhereThePatchSuspended(patchAhead: TimeInterval, line: UInt = #line) throws {
        let first = runFirst(patchAhead: patchAhead)
        link.script(CommandType.GET_RECORD, recordStoppedAt())
        link.notify(halt(.suspended, at: Self.stoppedAt, newestRecord: 131))
        settle()

        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose), line: line)
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .suspend], line: line)
        XCTAssertEqual(batch[0].endDate.timeIntervalSince(first.startDate), 600, accuracy: 0.001, line: line)
        XCTAssertEqual(batch[0].endDate, batch[1].startDate, line: line)
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.2, accuracy: 0.001, line: line)
    }

    /// A resume, its answer naming the segment the patch resumed with, and 131 the newest record: the temp basal's, written
    /// as the patch suspended unseen - read in the command, 0.15 U from it, not 0.2 U by our estimate, 1.2 U/h × 600 s
    func testTempBasalAResumeEndedEndsWhereTheResumeStartedWithThePatchClockAnHourAhead() throws {
        try assertResumeEndsItWhereTheResumeStarted(patchAhead: 3600)
    }

    func testTempBasalAResumeEndedEndsWhereTheResumeStartedWithThePatchClockAnHourBehind() throws {
        try assertResumeEndsItWhereTheResumeStarted(patchAhead: -3600)
    }

    private func assertResumeEndsItWhereTheResumeStarted(patchAhead: TimeInterval, line: UInt = #line) throws {
        let first = runFirst(patchAhead: patchAhead)
        link.script(CommandType.RESUME_PUMP, PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 131, patchId: Self.patchId, start: Self.stoppedAt
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.start1, end: Self.stoppedAt, rate: 1.2,
            delivered: 0.15, endReason: .SUSPEND_MANUAL
        ))
        XCTAssertNil(commandResume(), line: line)
        settle()

        let batch = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose), line: line)
        XCTAssertEqual(batch.map(\.type), [.tempBasal, .basal], "the schedule after it: no suspend was reported", line: line)
        XCTAssertEqual(batch[0].endDate.timeIntervalSince(first.startDate), 600, accuracy: 0.001, line: line)
        XCTAssertEqual(batch[0].endDate, batch[1].startDate, line: line)
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.15, accuracy: 0.001, "from its record", line: line)
    }

    // MARK: - Loop's watermark

    /// An unanswered set with no cancel before it - the schedule running, put in place by a cancel to it, its segment's
    /// start on the patch clock known - our reading of the patch clock an hour off either way: the set's record is told
    /// from that segment, on each clock alone - matched, dated after the schedule
    func testUnansweredSetWithNoCancelIsMatchedFromTheSchedulesSegmentWithThePatchClockAnHourAhead() throws {
        try assertUnansweredSetWithNoCancelIsMatched(patchAhead: 3600)
    }

    func testUnansweredSetWithNoCancelIsMatchedFromTheSchedulesSegmentWithThePatchClockAnHourBehind() throws {
        try assertUnansweredSetWithNoCancelIsMatched(patchAhead: -3600)
    }

    private func assertUnansweredSetWithNoCancelIsMatched(patchAhead: TimeInterval, line: UInt = #line) throws {
        runFirst(patchAhead: patchAhead)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0, duration: 0), line: line)
        settle()
        let schedule = try XCTUnwrap(reports(of: .basal).last, line: line)

        // The set as the patch has it: 61 s after the schedule's segment began
        advanceClock(by: 61.5)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)), line: line)
        settle()
        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_TEMP_BASAL, "no cancel", line: line)

        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(61),
            end: Self.end1.addingTimeInterval(181), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, line: line)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 }, line: line)
        XCTAssertEqual(set.isMutable, false, line: line)
        XCTAssertEqual(set.startDate.timeIntervalSince(schedule.startDate), 61, accuracy: 0.5, line: line)
        XCTAssertEqual(set.endDate.timeIntervalSince(set.startDate), 120, accuracy: 0.5, line: line)
    }

    /// The patch had stopped the 1.2 U/h one 5 min before the cancel to the schedule; then a set from that schedule, no
    /// cancel before it, goes out unanswered: the schedule's start on both clocks is one instant - the cancel on ours,
    /// its patch time 300 s after where the segment began - so the set's record, 61 s after the schedule, is its own
    func testUnansweredSetFromAScheduleAfterAnEarlyStopIsMatched() throws {
        runFirst()
        let stoppedAt = Self.end1.addingTimeInterval(-300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: stoppedAt))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.3, end: stoppedAt))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        let schedule = try XCTUnwrap(reports(of: .basal).last)

        advanceClock(by: 61.5)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()

        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(61),
            end: Self.end1.addingTimeInterval(181), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
        XCTAssertEqual(set.startDate.timeIntervalSince(schedule.startDate), 61, accuracy: 0.5, "at its record's start")
    }

    /// The same early stop, the set right after the answered cancel unanswered: its anchor is the cancel on our clock and
    /// that instant on the patch's - not where the stopped segment began - so its record is its own
    func testUnansweredSetAfterACancelOfAnEarlyStoppedTempBasalIsMatched() throws {
        freezesManagerClock = true
        runFirst()
        let stoppedAt = Self.end1.addingTimeInterval(-300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: stoppedAt))
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()
        let schedule = try XCTUnwrap(reports(of: .basal).last)

        // Its record read once it began: not dated in our future
        advanceClock(by: 2)
        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.3, end: stoppedAt))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(1),
            end: Self.end1.addingTimeInterval(121), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
        XCTAssertEqual(set.isMutable, false)
        XCTAssertEqual(set.startDate.timeIntervalSince(schedule.startDate), 1, accuracy: 0.5, "at its record's start")
    }

    /// The cancel to the schedule answered 8 s late, the patch having ended the 1.2 U/h one 2 s before the cancel went out
    /// - not a stop before it, but its record ends 10 s before the schedule is dated: its final ends there, and the
    /// schedule's start on the patch clock pairs with nothing - the set from it after, unanswered, is told through the
    /// skew: its record, 61 s after the cancel went out on the patch clock, is matched and dated at its start
    func testUnansweredSetFromAScheduleAfterARecordedEndIsDatedAtItsRecordsStart() throws {
        let first = runFirst()
        let endedAt = Self.end1.addingTimeInterval(-2)
        link.script(CommandType.CANCEL_TEMP_BASAL, .fragments(cancelAnswer(record: 131, at: endedAt))) { [unowned self] in
            advanceClock(by: 8)
        }
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35, end: endedAt))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.unitsPerHour == 1.2 }).first)
        XCTAssertEqual(final.endDate.timeIntervalSince(first.startDate), 1198, accuracy: 0.5, "its record's end")
        XCTAssertNil(pumpManager.state.basalDose.pumpStartTime)

        advanceClock(by: 61.5)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()

        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(69),
            end: Self.end1.addingTimeInterval(189), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
        XCTAssertEqual(set.startDate.timeIntervalSince(first.startDate), 1200 + 69, accuracy: 0.5, "at its record's start")
    }

    /// A set from the schedule goes out unanswered and never runs; 5 min on, a cancel-only for it is answered with the
    /// schedule's segment, still running from `end1`: the schedule after it starts that much later on the patch clock as
    /// well - not where the segment began - so a set from it after, unanswered but run, is matched to its record and
    /// dated at its start
    func testUnansweredSetAfterACancelOfAnUnconfirmedOneThatNeverRanIsMatched() throws {
        freezesManagerClock = true
        runFirst()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1))
        link.script(CommandType.GET_RECORD, recordOfFirst(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        advanceClock(by: 60)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.3, duration: 30 * Self.minute)))
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: 131, at: Self.end1))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        let schedule = try XCTUnwrap(reports(of: .basal).last)
        let onPatch = try XCTUnwrap(pumpManager.state.basalDose.pumpStartTime)
        XCTAssertEqual(onPatch.timeIntervalSince(Self.end1), 360, accuracy: 0.5, "the cancel's instant on the patch clock")

        advanceClock(by: 61.5)
        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()
        XCTAssertEqual(link.writtenCommands.last, CommandType.SET_TEMP_BASAL, "no cancel")

        link.notify("200001" + "8400fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132, patchId: Self.patchId, type: .ABSOLUTE_TEMP, start: Self.end1.addingTimeInterval(421),
            end: Self.end1.addingTimeInterval(541), rate: 0.5, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let set = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
        XCTAssertEqual(set.isMutable, false)
        XCTAssertEqual(set.startDate.timeIntervalSince(schedule.startDate), 61, accuracy: 0.5, "at its record's start")
    }

    /// `LoopWatermark` as LoopKit makes it: a final moves it to its end; a 0-s scheduled basal moves nothing; a dose
    /// reported after a gap - mutable or not - moves it to its start, the gap filled; a suspend ended by its resume to
    /// the resume. A dose new to the host starting before it is behind it.
    func testLoopWatermarkMovesAsLoopKitMovesIt() {
        checksLoopOrdering = false
        let t0 = Date.now
        func tempBasal(_ start: TimeInterval, _ end: TimeInterval, mutable: Bool) -> NewPumpEvent {
            NewPumpEvent.tempBasal(dose: DoseEntry(
                type: .tempBasal, startDate: t0.addingTimeInterval(start), endDate: t0.addingTimeInterval(end), value: 1,
                unit: .unitsPerHour, deliveredUnits: mutable ? nil : 0.1, isMutable: mutable
            ))
        }
        func basal(_ at: TimeInterval) -> NewPumpEvent {
            NewPumpEvent.basal(dose: DoseEntry(type: .basal, startDate: t0.addingTimeInterval(at), value: 0.7, unit: .unitsPerHour))
        }

        var mark = LoopWatermark()
        mark.store([tempBasal(0, 600, mutable: false), basal(600)], replacePendingEvents: true)
        XCTAssertEqual(mark.date, t0.addingTimeInterval(600))
        mark.store([basal(900)], replacePendingEvents: true)
        XCTAssertEqual(mark.date, t0.addingTimeInterval(600), "a 0-s scheduled basal moves nothing")
        XCTAssertEqual(mark.store([tempBasal(700, 800, mutable: false)], replacePendingEvents: true).count, 0, "not behind it")
        XCTAssertEqual(mark.date, t0.addingTimeInterval(800))

        mark.store([tempBasal(1200, 3000, mutable: true)], replacePendingEvents: true)
        XCTAssertEqual(mark.date, t0.addingTimeInterval(1200), "a mutable one after a gap: the fill up to its start")
        let behind = mark.store([tempBasal(1000, 1100, mutable: false), tempBasal(1200, 3000, mutable: true)], replacePendingEvents: true)
        XCTAssertEqual(behind.map(\.startDate), [t0.addingTimeInterval(1000)], "new, and before it: never stored")

        // Nothing stored yet: Loop syncs from 24 h back, the first dose's start at least
        var fresh = LoopWatermark()
        fresh.store([tempBasal(100, 1900, mutable: true)], replacePendingEvents: true)
        XCTAssertEqual(fresh.date, t0.addingTimeInterval(100))

                var suspended = LoopWatermark(date: t0)
        suspended.store([
            NewPumpEvent.suspend(dose: DoseEntry(suspendDate: t0)),
            NewPumpEvent.resume(dose: DoseEntry(resumeDate: t0.addingTimeInterval(300)))
        ], replacePendingEvents: true)
        XCTAssertEqual(suspended.date, t0.addingTimeInterval(300), "the suspend, ended by its resume")
    }

    // MARK: - The checker

    /// The checker trips on each rule broken, from batches no manager should send
    func testLoopOrderingCheckerTripsOnEachRule() {
        checksLoopOrdering = false
        // On a whole second: the iAPS rules go by whole seconds
        let t0 = LoopOrderingChecker.stored(Date.now)
        func tempBasal(_ start: TimeInterval, _ end: TimeInterval, rate: Double, mutable: Bool, delivered: Double? = nil) -> NewPumpEvent {
            NewPumpEvent.tempBasal(dose: DoseEntry(
                type: .tempBasal,
                startDate: t0.addingTimeInterval(start),
                endDate: t0.addingTimeInterval(end),
                value: rate,
                unit: .unitsPerHour,
                deliveredUnits: mutable ? nil : delivered ?? 0.1,
                isMutable: mutable
            ))
        }
        func basal(_ at: TimeInterval) -> NewPumpEvent {
            NewPumpEvent.basal(dose: DoseEntry(type: .basal, startDate: t0.addingTimeInterval(at), value: 0.7, unit: .unitsPerHour))
        }
        func rules(_ batches: [[NewPumpEvent]]) -> Set<Int> {
            Set(LoopOrderingChecker.violations(in: batches.map { LoopOrderingChecker.Batch(events: $0) }).map(\.rule))
        }

        // Fine: ended open where the next starts, then final in order
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)],
            [tempBasal(0, 600, rate: 1.2, mutable: false), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [])
        // A final ending short of where its mutable report had it - its records say so: the host fills the gap, fine. A
        // mutable one short of the next one is not.
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)],
            [tempBasal(0, 300, rate: 1.2, mutable: false), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [])
        XCTAssertEqual(rules([
            [tempBasal(0, 599, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [1, 6], "the fill up to the next one passes it")
        // 1: a final shorter than a second that delivered - Loop drops it - and one earlier than its report that short
        XCTAssertEqual(rules([
            [tempBasal(0, 0, rate: 1.2, mutable: false, delivered: 0.4), basal(0)]
        ]), [1])
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)],
            [tempBasal(0, 0.5, rate: 1.2, mutable: false, delivered: 0.4), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [1])
        // 1: a final past where the next starts
        XCTAssertEqual(rules([
            [tempBasal(0, 601, rate: 1.2, mutable: false), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [1, 2])
        // 2: a later one final first
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 900, rate: 0.5, mutable: false), tempBasal(900, 2700, rate: 0.8, mutable: true)]
        ]), [2, 6])
        // 3: the schedule after a chain still mutable
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 900, rate: 0.5, mutable: false), basal(900)]
        ]), [2, 3, 6])
        // 4: a replacing batch leaving out the one ended
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)],
            [tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [4])
        // 5: a scheduled basal between two back to back
        XCTAssertEqual(rules([
            [tempBasal(0, 600, rate: 1.2, mutable: false), basal(599), tempBasal(600, 2400, rate: 0.5, mutable: true)]
        ]), [1, 5])
        // 6: a dose new to the host starting before the watermark - final or mutable
        XCTAssertEqual(rules([
            [tempBasal(600, 900, rate: 0.5, mutable: false)],
            [tempBasal(300, 600, rate: 1.2, mutable: false)]
        ]), [6])
        XCTAssertEqual(rules([
            [tempBasal(600, 900, rate: 0.5, mutable: false)],
            [tempBasal(800, 2600, rate: 1.2, mutable: true)]
        ]), [1, 2, 6])
        // 7: oref0's pairing broken - a resume with no suspend before it, stored ahead of it or with none (one in the
        // same batch is fine), one no suspend pairs with, or a suspend paired with a resume past the next suspend
        func suspend(_ at: TimeInterval) -> NewPumpEvent {
            NewPumpEvent.suspend(dose: DoseEntry(suspendDate: t0.addingTimeInterval(at)))
        }
        func resume(_ at: TimeInterval) -> NewPumpEvent {
            NewPumpEvent.resume(dose: DoseEntry(resumeDate: t0.addingTimeInterval(at)))
        }
        XCTAssertEqual(rules([[resume(600)], [suspend(300)]]), [7])
        XCTAssertEqual(rules([[resume(600)]]), [7])
        XCTAssertEqual(rules([[suspend(300), resume(600)]]), [])
        XCTAssertEqual(rules([[suspend(300)], [resume(600)]]), [])
        XCTAssertEqual(rules([[suspend(300), resume(300)]]), [7], "at the same instant: not paired")
        XCTAssertEqual(rules([[suspend(300.2), resume(300.7)]]), [7], "in the same second, as iAPS stores them: not paired")
        XCTAssertEqual(rules([[suspend(300.7), resume(301.2)]]), [], "in the next second")
        XCTAssertEqual(Set(LoopOrderingChecker.violations(in: [LoopOrderingChecker.Batch(events: [resume(600)])], suspendedSince: t0).map(\.rule)), [])
        // Not only the earliest suspend and the latest: S1 and R1 in one second, between S0/R0 and S2/R2 - oref0 pairs S1
        // with R2, past S2, R1 with none: what ran from R1 to S2 zeroed. The same with R1 lost.
        XCTAssertEqual(rules([[suspend(300), resume(600)], [suspend(900.2), resume(900.7)], [suspend(1200), resume(1500)]]), [7])
        XCTAssertEqual(rules([[suspend(300), resume(600)], [suspend(900)], [suspend(1200), resume(1500)]]), [7])
        XCTAssertEqual(rules([[suspend(300), resume(600)], [suspend(900.7), resume(901.2)], [suspend(1200), resume(1500)]]), [])
        XCTAssertEqual(rules([[suspend(300), resume(600)], [suspend(900), resume(1200)]]), [])
        // A suspend in its resume's second - the patch suspended again at once - is paired with the next resume: fine
        XCTAssertEqual(rules([[suspend(300), resume(600.2)], [suspend(600.7)], [resume(900)]]), [])
        // 8: the patch delivering, a suspend with no resume strictly after it
        func rulesDelivering(_ batches: [[NewPumpEvent]], _ delivering: Bool = true, suspendedSince: Date? = nil) -> Set<Int> {
            Set(LoopOrderingChecker.violations(
                in: batches.map { LoopOrderingChecker.Batch(events: $0) }, suspendedSince: suspendedSince, delivering: delivering
            ).map(\.rule))
        }
        XCTAssertEqual(rulesDelivering([[suspend(300)]]), [8])
        XCTAssertEqual(rulesDelivering([[suspend(300)]], false), [], "still suspended")
        XCTAssertEqual(rulesDelivering([[suspend(300), resume(600)]]), [])
        XCTAssertEqual(rulesDelivering([[suspend(300.2), resume(300.7)]]), [7, 8], "in the same second: left open")
        XCTAssertEqual(rulesDelivering([[suspend(300.7), resume(301.2)]]), [])
        XCTAssertEqual(rulesDelivering([[suspend(300), resume(600)], [suspend(900)]]), [8])
        XCTAssertEqual(rulesDelivering([[suspend(300), resume(600)], [suspend(900.2), resume(900.7)]]), [7, 8], "S1 in R1's second: open")
        // Both paired with the one resume: right only if the patch never resumed between them - a resume lost there
        // looks the same
        XCTAssertEqual(rulesDelivering([[suspend(300)], [suspend(900), resume(1200)]]), [7])
        XCTAssertEqual(rulesDelivering([[suspend(300)], [suspend(900)]]), [8], "the first left open, the second dropped")
        XCTAssertEqual(rulesDelivering([[resume(600)]], suspendedSince: t0), [])
        XCTAssertEqual(rulesDelivering([[tempBasal(0, 600, rate: 1.2, mutable: true)]], suspendedSince: t0), [8])
        // A batch the host could not store changes nothing
        XCTAssertEqual(Set(LoopOrderingChecker.violations(in: [
            LoopOrderingChecker.Batch(events: [tempBasal(0, 600, rate: 1.2, mutable: true), tempBasal(600, 2400, rate: 0.5, mutable: true)]),
            LoopOrderingChecker.Batch(events: [tempBasal(600, 2400, rate: 0.5, mutable: true)], stored: false)
        ]).map(\.rule)), [])
    }

    // MARK: - Driving

    /// `rate` U/h of ours, 30 min, running for 20 min from `start1`, every record read up to `sequence` - the patch clock
    /// `end1` plus `patchAhead` now
    @discardableResult private func runFirst(
        patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId,
        sequence: Int = 130,
        rate: Double = 1.2,
        patchAhead: TimeInterval = 0
    ) -> UnfinalizedDose {
        let state = activePatchState(patchId: patchId, scheduledRate: 0.7, sequence: sequence, reservoir: 150)
        let tempBasal = runningTempBasal(rate: rate, startedAgo: 20 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.start1)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        state.lastSegmentStart = Self.start1
        alignPatchClock(state, patchTime: Self.end1.addingTimeInterval(patchAhead))
        makeManager(state)
        return tempBasal
    }

    /// The answers to replacing the `n`th temp basal: 1, the 1.2 U/h one at `end1` for 0.5 U/h (its record 131, the
    /// scheduled second 132); 2, the 0.5 U/h one at `end2` for 0.8 U/h (133, 134)
    private func scriptReplacement(of n: Int, patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId, rate: Double? = nil) {
        let (end, record, defaultRate) = n == 1 ? (Self.end1, 131, 0.5) : (Self.end2, 133, 0.8)
        let rate = rate ?? defaultRate
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: record, at: end, patchId: patchId))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(rate: rate, record: record + 1, at: end.addingTimeInterval(1), patchId: patchId))
    }

    private func cancelAnswer(record: Int, at end: Date, patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId) -> [String] {
        PatchBytes.segmentAnswer(command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: record, patchId: patchId, start: end)
    }

    private func setAnswer(rate: Double, record: Int, at start: Date, patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId) -> [String] {
        PatchBytes.segmentAnswer(command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: rate, sequence: record, patchId: patchId, start: start)
    }

    private func recordOfFirst(
        delivered: Double,
        patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId,
        end: Date = ManagerTempBasalBackToBackScenarioTests.end1
    ) -> [String] {
        PatchBytes.basalRecord(
            sequence: 131, patchId: patchId, type: .ABSOLUTE_TEMP, start: Self.start1, end: end, rate: 1.2, delivered: delivered
        )
    }

    private func recordOfSecond(
        delivered: Double,
        end: Date = ManagerTempBasalBackToBackScenarioTests.end2,
        rate: Double = 0.5,
        endReason: BasalEndReason = .SUCCESS
    ) -> [String] {
        PatchBytes.basalRecord(
            sequence: 133,
            patchId: Self.patchId,
            type: .ABSOLUTE_TEMP,
            start: Self.end1.addingTimeInterval(1),
            end: end,
            rate: rate,
            delivered: delivered,
            endReason: endReason
        )
    }

    /// The second of scheduled basal between a cancel at `at` and the set after it
    private func scheduledSecond(sequence: Int, at: Date) -> [String] {
        PatchBytes.basalRecord(
            sequence: sequence, patchId: Self.patchId, type: .STANDARD, start: at, end: at.addingTimeInterval(1), rate: 0.7, delivered: 0
        )
    }

    /// Records 131 - 133: the first temp basal, the scheduled second, the second temp basal
    private func recordsThroughTheSecond(
        delivered: Double,
        rate: Double = 0.5,
        endReason: BasalEndReason = .SUCCESS,
        end: Date = ManagerTempBasalBackToBackScenarioTests.end2
    ) -> [FakeMedtrumLink.Answer] {
        [
            .fragments(recordOfFirst(delivered: 0.35)),
            .fragments(scheduledSecond(sequence: 132, at: Self.end1)),
            .fragments(recordOfSecond(delivered: delivered, end: end, rate: rate, endReason: endReason))
        ]
    }

    /// The SET_BOLUS answer: record `record`, started at `start`
    private func bolusAnswer(record: Int, start: Date) -> [String] {
        let body = UInt64(record).toData(length: 2) + Self.patchId.toData(length: 2) + start.toMedtrumSeconds()
        return PatchBytes.answer(command: CommandType.SET_BOLUS, body: body)
    }

    /// The patch's notification of the running bolus complete at `delivered`, naming `record` the newest
    private func completion(delivered: Double, record: Int) -> String {
        let storage = UInt64(record).toData(length: 2) + Self.patchId.toData(length: 2)
        return "200211" + "80" + UInt64((delivered / 0.05).rounded()).toData(length: 2).hexEncodedString() +
            storage.hexEncodedString() + "0000000000"
    }

    /// The patch's heartbeat naming its newest record, then what `PeripheralManager.considerFullSync` does between full
    /// syncs
    private func heartbeat() {
        confirmRecordSequence()
        if pumpManager.heartbeatSync() == .records {
            syncRecords(.awaitingDoses)
        }
    }

    private func running(rate: Double, from start: Date, sequence: Int) -> String {
        PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: sequence, patchId: Self.patchId, start: start, rate: rate)
    }

    /// The patch's notification that it halted delivery, in `state`, naming `newestRecord`, with when it halted - or
    /// without, as for a halt of its own
    private func halt(_ state: PatchState, at: Date?, newestRecord: Int) -> String {
        let storage = UInt64(newestRecord).toData(length: 2) + Self.patchId.toData(length: 2)
        guard let at else {
            return (Data([state.rawValue, 0x00, 0x01]) + storage).hexEncodedString()
        }
        return (Data([state.rawValue, 0x01, 0x01]) + at.toMedtrumSeconds() + storage).hexEncodedString()
    }

    /// The first batch that carries `final`
    private func batchIndex(ofFinal final: DoseEntry) -> Int? {
        delegate.batches.firstIndex { batch in
            batch.events.contains { $0.dose?.syncIdentifier == final.syncIdentifier && $0.dose?.isMutable == false }
        }
    }
}

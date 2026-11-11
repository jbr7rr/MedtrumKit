import LoopKit
@testable import MedtrumKit
import XCTest

/// Temp basals a new one replaces back to back - a cancel, then a set - end open: the command completes once the set is
/// answered, the old one reported ended where the new one starts and mutable, its records read after the command. They
/// go final in order, the oldest first, and before anything that leaves a gap after them goes out. Every scenario's
/// batches are checked against the rules Loop needs kept (`LoopOrderingChecker`, in `tearDown`). Records are built with
/// `PatchBytes`, on patch 251: 1.2 U/h from `start1`, cancelled at `end1` for 0.5 U/h, cancelled at `end2` for 0.8 U/h.
final class ManagerTempBasalBackToBackScenarioTests: MedtrumManagerTestCase {
    static let patchId: UInt64 = 251
    static let start1 = patchTime(400_000_000)
    static let end1 = patchTime(400_001_200)
    static let end2 = patchTime(400_001_500)

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
        assertOneFinal(of: final)
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
        assertOneFinal(of: reports(of: .tempBasal).first { $0.unitsPerHour == 0.5 })
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
}

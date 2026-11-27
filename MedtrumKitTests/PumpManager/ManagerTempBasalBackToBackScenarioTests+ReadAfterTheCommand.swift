import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerTempBasalBackToBackScenarioTests {
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
        assertOneFinal(of: second)

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
}

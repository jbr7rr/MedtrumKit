import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerTempBasalScenarioTests {
    // MARK: - A halt naming no record

    /// Device 2026-10-26 10:08:55 (`logs1026/mt/log.txt:16031`, patch 274): the reservoir runs dry as 4.6 U/h of ours
    /// runs - the halt's status as the patch sent it, its basal field of type none the type byte alone. It names 1643:
    /// the temp basal's record, 1641 (STOP_EMPTY, 0.25 U), is read at once and makes its final - not 0.2 U from our
    /// estimate, its record left unmatched after.
    func testHaltWithABasalFieldOfTypeNoneOnlyItsTypeByteNamesTheRecordsToRead() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        scriptRecordOfTheTempBasalTheReservoirRanDryOn()
        link.notify("6228130000006b061201040100000000000000")
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 1641)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        let doses = try XCTUnwrap(firstDosesReported())
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1641")
    }

    /// The same halt, its status naming no record - cut short as before the parser took the basal field of type none,
    /// or one without storage, as the patch sends right after (10:08:55, `6200520401...`): the temp basal's end waits,
    /// nothing reported, the heartbeat asking for a full status at once. The one it gets (10:08:58, the device's bytes)
    /// names 1643: 1641 is read and makes its final, 0.25 U - nothing estimated - and the sync reads 1642-1643 after.
    func testHaltNamingNoRecordWaitsForTheFullStatusThatNamesIt() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()

        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertNil(firstDosesReported(), "nothing reported before its final")
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.heartbeatSync(), .full, "asked for at once, the status fresh")

        // A heartbeat with no storage meanwhile, as the patch sends every 8 s (10:09:03): it neither settles nor names it
        link.notify("620012040100000000000000")
        settle()
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertNil(firstDosesReported())
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true)

        scriptRecordOfTheTempBasalTheReservoirRanDryOn()
        link.deliverFullStatus(Self.fullStatusAfterTheReservoirRanDry)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD])
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        let doses = try XCTUnwrap(firstDosesReported())
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1641, STOP_EMPTY")

        scriptRecordsAfterTheTempBasalTheReservoirRanDryOn()
        syncRecords()
        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 1643)
        XCTAssertEqual(oneFinal(of: doses.first)?.deliveredUnits ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 1641 }?.outcome, "finalized temp basal \(tempBasal.startDate)")
    }

    /// No status naming a record within `tempBasalEndRecordWait` - the link gone: the temp basal goes final from our
    /// estimate, the suspend with it, as before - on the timer the halt set, with no status after. Shortened here.
    func testHaltNamingNoRecordGoesFinalFromOurEstimateOnceTheWaitIsUp() throws {
        let wait = MedtrumPumpManager.tempBasalEndRecordWait
        MedtrumPumpManager.tempBasalEndRecordWait = 0.5
        addTeardownBlock { MedtrumPumpManager.tempBasalEndRecordWait = wait }

        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()
        XCTAssertNotNil(pumpManager.pendingTempBasalEnd, "not yet")

        XCTAssertTrue(giveTime(timeout: 5) { self.pumpManager.pendingTempBasalEnd == nil }, "given up on")
        settle()

        XCTAssertEqual(link.writtenCommands, [])
        let doses = try XCTUnwrap(firstDosesReported())
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.25, accuracy: 0.051, "by our estimate, 4.6 U/h for 185 s")
        XCTAssertNotNil(oneFinal(of: doses.first))
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)

        // A status naming the record after that reads nothing for it
        link.deliverFullStatus(Self.fullStatusAfterTheReservoirRanDry)
        settle()
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertNotNil(oneFinal(of: doses.first))
    }

    /// The patch deactivated while the temp basal waits for a status to name its record: the deactivation asks for a
    /// full status first - the device's, naming 1643 - and the records read before the stop make its final, 0.25 U by
    /// 1641, once - the suspend with it, no second one
    func testDeactivationWhileAHaltWaitsForItsRecordAsksForItAndReportsTheFinalByIt() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true)

        link.script(CommandType.SYNCHRONIZE, Self.fullStatusAfterTheReservoirRanDry)
        scriptRecordOfTheTempBasalTheReservoirRanDryOn()
        scriptRecordsAfterTheTempBasalTheReservoirRanDryOn()
        XCTAssertEqual(deactivateThePatchTheReservoirRanDryOn(), true)

        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        XCTAssertEqual(
            link.writtenCommands,
            [CommandType.SYNCHRONIZE, CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.STOP_PATCH]
        )
        let final = oneFinal(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate })
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1641")
        XCTAssertEqual(Set(reports(of: .suspend).map(\.syncIdentifier)).count, 1, "the halt's, no second one")
    }

    /// The same, the full status it asks for not coming: the session's end takes it out from our estimate - once, the
    /// suspend with it, and nothing after once the wait is up
    func testDeactivationWhileAHaltWaitsForItsRecordReportsTheFinalOnce() throws {
        let wait = MedtrumPumpManager.tempBasalEndRecordWait
        MedtrumPumpManager.tempBasalEndRecordWait = 0.5
        addTeardownBlock { MedtrumPumpManager.tempBasalEndRecordWait = wait }

        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()
        XCTAssertNotNil(pumpManager.pendingTempBasalEnd)

        link.script(CommandType.SYNCHRONIZE, .timeout)
        XCTAssertEqual(deactivateThePatchTheReservoirRanDryOn(), true)

        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        XCTAssertEqual(link.writtenCommands, [CommandType.SYNCHRONIZE, CommandType.STOP_PATCH])
        let final = oneFinal(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate })
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.25, accuracy: 0.051, "by our estimate, 4.6 U/h for 185 s")
        XCTAssertEqual(Set(reports(of: .suspend).map(\.syncIdentifier)).count, 1, "the halt's, no second one")

        Thread.sleep(forTimeInterval: 1)
        settle()
        XCTAssertEqual(oneFinal(of: final)?.deliveredUnits, final?.deliveredUnits, "not another once the wait is up")
    }

    /// The app killed while the temp basal waits for a status to name its record: the next run waits on - nothing
    /// reported before its final - and the first status naming one has it read, the final 0.25 U by record 1641, the
    /// halt's suspend after it in the same batch
    func testHaltNamingNoRecordWaitsOnAcrossARestart() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()
        XCTAssertNil(firstDosesReported())
        let saved = try XCTUnwrap(delegate.savedState)

        try restart(from: saved)
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true, "waiting on")
        XCTAssertEqual(pumpManager.heartbeatSync(), .full)

        scriptRecordOfTheTempBasalTheReservoirRanDryOn()
        link.deliverFullStatus(Self.fullStatusAfterTheReservoirRanDry)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD])
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        let doses = try XCTUnwrap(firstDosesReported())
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1641")
    }

    /// The same restart, the first status of the new run naming no record either - a heartbeat: it neither settles nor
    /// names it, the wait goes on - and the full status after it does
    func testHaltNamingNoRecordWaitsOnAcrossARestartPastAStatusNamingNone() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()
        try restart(from: try XCTUnwrap(delegate.savedState))

        link.notify("620012040100000000000000")
        settle()
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertNil(firstDosesReported())
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true, "neither settled nor named")

        scriptRecordOfTheTempBasalTheReservoirRanDryOn()
        link.deliverFullStatus(Self.fullStatusAfterTheReservoirRanDry)
        settle()

        let doses = try XCTUnwrap(firstDosesReported())
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1641")
    }

    /// The same restart, no status at all in the new run: the wait the restart re-armed - what was left of it - runs
    /// out, and the temp basal goes final from our estimate, once, the suspend with it. Shortened here.
    func testHaltNamingNoRecordGoesFinalFromOurEstimateAfterARestartWithNoStatus() throws {
        let wait = MedtrumPumpManager.tempBasalEndRecordWait
        MedtrumPumpManager.tempBasalEndRecordWait = 0.5
        addTeardownBlock { MedtrumPumpManager.tempBasalEndRecordWait = wait }

        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()
        // The first run's own timer stops with it
        try restart(from: try XCTUnwrap(delegate.savedState))
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true)

        XCTAssertTrue(giveTime(timeout: 5) { self.pumpManager.pendingTempBasalEnd == nil }, "given up on")
        settle()

        XCTAssertEqual(link.writtenCommands, [])
        let doses = try XCTUnwrap(firstDosesReported())
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.25, accuracy: 0.051, "by our estimate")
        XCTAssertNotNil(oneFinal(of: doses.first))
    }

    /// Statuses that say nothing of its record keep it waiting: one naming no record past those read (1640, from before
    /// the patch wrote it), and one received before the halt, handled after it. The full status after them names it.
    func testHaltNamingNoRecordIsNotNamedByAStaleStatus() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()

        link.notify("620001" + "6806" + "1201")
        settle()
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true, "1640 is read already")
        notify("620001" + "6b06" + "1201", receivedAgo: 5)
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true, "received before the halt")
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertNil(firstDosesReported())

        scriptRecordOfTheTempBasalTheReservoirRanDryOn()
        link.deliverFullStatus(Self.fullStatusAfterTheReservoirRanDry)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD])
        let doses = try XCTUnwrap(firstDosesReported())
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1641")
    }

    /// While it waits, a record sync reads nothing - 1641 read there, behind the cursor, would make no final of it - and
    /// the records are read once a status names it
    func testRecordSyncReadsNothingWhileAHaltWaitsForItsRecord() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()
        // The patch's newest record told of meanwhile, without storage
        pumpManager.state.currentSequenceNumber = 1643

        syncRecords()
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 1640)
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true)

        scriptRecordOfTheTempBasalTheReservoirRanDryOn()
        link.deliverFullStatus(Self.fullStatusAfterTheReservoirRanDry)
        settle()
        let final = finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate })
        XCTAssertEqual(final.first?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1641")
    }

    /// A suspend-type segment shown in a state still delivering, with no storage: the segment is current, and its
    /// sequence names the newest record - read at once, no wait
    func testSuspendSegmentShownWithoutStorageNamesItsRecordBySequence() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        scriptRecordOfTheTempBasalTheReservoirRanDryOn()
        link.notify(PatchBytes.basalNotification(
            // From where record 1641 ends
            type: .SUSPEND_LOW_GLUCOSE, sequence: 1641, patchId: 274, start: Date(timeIntervalSinceReferenceDate: 814_698_540), rate: 0
        ))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD])
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        let doses = try XCTUnwrap(firstDosesReported())
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1641")
    }

    /// A bolus running as the halt names no record: no full status is asked for while it runs; its completion is held
    /// behind the temp basal's end, which is asked for once it is over. The full status names 1643: the bolus's record
    /// (1641) and the temp basal's (1642) are read, both final from them, in one batch after the suspend.
    func testHaltNamingNoRecordWithABolusRunningReadsBothOnceTheBolusIsOver() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        let bolusStart = Self.reservoirRanDryAt.addingTimeInterval(-60)
        link.script(
            CommandType.SET_BOLUS,
            PatchBytes.answer(
                command: CommandType.SET_BOLUS,
                body: UInt64(1641).toData(length: 2) + UInt64(274).toData(length: 2) + bolusStart.toMedtrumSeconds()
            )
        )
        XCTAssertNil(commandBolus(0.5, activationType: .automatic))
        settle()

        link.notify("6200520401000000000000000010")
        settle()
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true)
        XCTAssertNil(pumpManager.heartbeatSync(), "not while the bolus runs")

        // Its completion, with no storage either
        link.notify("620200" + "80" + "0600")
        settle()
        XCTAssertEqual(pumpManager.heartbeatSync(), .full, "the bolus over")
        XCTAssertNil(finals(of: reports(of: .bolus).first).first, "held behind the temp basal's end")

        // More than its completion said: a final from the completion is told apart
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 1641, patchId: 274, start: bolusStart, amount: 0.5, delivered: 0.35
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 1642, patchId: 274, type: .ABSOLUTE_TEMP, start: Self.tempBasalTheReservoirRanDryOnStart,
            end: Self.reservoirRanDryAt, rate: 4.6, delivered: 0.25, endReason: .STOP_EMPTY
        ))
        link.deliverFullStatus(notification: "620001" + "6b06" + "1201", duringReconnect: false)
        settle()

        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.GET_RECORD, CommandType.GET_RECORD])
        // Each final goes out again with the bolus's, built before the host confirmed the first - the same final each time
        let tempBasalFinal = oneFinal(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate })
        XCTAssertEqual(tempBasalFinal?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1642")
        let bolusFinal = oneFinal(of: reports(of: .bolus).first)
        XCTAssertEqual(bolusFinal?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from record 1641, not its completion")
    }

    /// The patch halts on its own (hourly max), naming no record; the resume's full status does not come, the temp basal
    /// of 1 U/h after it is held behind the old one's end - and the full status its command asks for shows a second
    /// halt, naming 1643. The old one is read right there, before that halt ends the new one: 0.25 U by record 1641,
    /// not taken out from our estimate as the second end begins.
    func testSecondHaltInTheStatusACommandAsksForReadsTheFirstEndBeforeEndingTheNewTempBasal() throws {
        // Statuses are stamped on the wall clock, doses on the manager's: the halt 5 s ago, the resume 3 s ago on the
        // patch clock, and the manager's clock set back a second before the set - the second halt, stamped as it is
        // received, a second into the new temp basal
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        notify("4300520401000000000000000010", receivedAgo: 5)
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true)

        let resumedAt = Self.reservoirRanDryAt.addingTimeInterval(-3)
        link.script(CommandType.RESUME_PUMP, PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 1641, patchId: 274, start: resumedAt
        ))
        link.script(CommandType.SYNCHRONIZE, .timeout)
        XCTAssertNil(commandResume())
        settle()
        XCTAssertEqual(pumpManager.pendingTempBasalEnd?.awaitsRecord, true, "the status did not come")
        changeWallClock(by: -1)

        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 1641, patchId: 274,
            start: resumedAt.addingTimeInterval(1)
        ))
        link.script(CommandType.SYNCHRONIZE, PatchBytes.answer(
            command: CommandType.SYNCHRONIZE,
            body: Data([PatchState.hourlyMaxSuspended.rawValue, 0x00, 0x01]) + UInt64(1643).toData(length: 2) + UInt64(274).toData(length: 2)
        ))
        scriptRecordOfTheTempBasalTheReservoirRanDryOn()
        // The new one's, read in the command: not answered, our estimate stands in for it
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(Array(link.writtenCommands.prefix(5)), [
            CommandType.RESUME_PUMP, CommandType.SYNCHRONIZE, CommandType.SET_TEMP_BASAL, CommandType.SYNCHRONIZE,
            CommandType.GET_RECORD
        ])
        let final = oneFinal(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate })
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.25, accuracy: 0.001, "from record 1641, not 0.24 U by our estimate")
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
    }

    /// The deactivation asks for the full status that names the record, and it shows the base reset instead: the
    /// session ends with it, the temp basal final from our estimate once - and no stop goes out after
    func testBaseResetInTheStatusTheDeactivationAsksForEndsTheSessionWithNoStop() throws {
        let tempBasal = runTempBasalTheReservoirRunsDryOn()
        link.notify("6200520401000000000000000010")
        settle()

        link.script(CommandType.SYNCHRONIZE, PatchBytes.answer(
            command: CommandType.SYNCHRONIZE,
            body: Data([PatchState.none.rawValue, 0x00, 0x01]) + UInt64(1).toData(length: 2) + UInt64(999).toData(length: 2)
        ))
        let result: MedtrumDeactivatePatchResult? = completion(of: "deactivatePatch") { done in
            self.pumpManager.deactivatePatch(done)
        }
        settle()

        guard case .success? = result else {
            XCTFail("Not deactivated: \(String(describing: result))")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SYNCHRONIZE], "no stop")
        XCTAssertTrue(pumpManager.state.patchSessionEnded)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        let final = oneFinal(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate })
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.25, accuracy: 0.051, "by our estimate")
    }

    /// The final of `dose` the host was handed - one: every copy of it the same, as it goes out again until the host
    /// confirms it. Nil, and a failure, if there is none or they differ.
    private func oneFinal(of dose: DoseEntry?, file: StaticString = #filePath, line: UInt = #line) -> DoseEntry? {
        let copies = finals(of: dose)
        guard let first = copies.first else {
            XCTFail("No final", file: file, line: line)
            return nil
        }
        for copy in copies.dropFirst() {
            XCTAssertEqual(copy.deliveredUnits, first.deliveredUnits, "copies differ", file: file, line: line)
            XCTAssertEqual(copy.startDate, first.startDate, "copies differ", file: file, line: line)
            XCTAssertEqual(copy.endDate, first.endDate, "copies differ", file: file, line: line)
        }
        return first
    }

    /// Deactivates the patch of `runTempBasalTheReservoirRunsDryOn`, its stop answered. Returns whether it succeeded.
    private func deactivateThePatchTheReservoirRanDryOn() -> Bool? {
        link.script(
            CommandType.STOP_PATCH,
            PatchBytes.answer(command: CommandType.STOP_PATCH, body: UInt64(1643).toData(length: 2) + UInt64(274).toData(length: 2))
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

    /// The doses of the first batch that carries any - the halt's alarm goes out in one of its own
    private func firstDosesReported() -> [DoseEntry]? {
        delegate.batches.lazy.map { $0.events.compactMap(\.dose) }.first { !$0.isEmpty }
    }

    /// Where 4.6 U/h of ours started on patch 274's clock, and where the reservoir ran dry - device 2026-10-26
    private static let tempBasalTheReservoirRanDryOnStart = Date(timeIntervalSinceReferenceDate: 814_698_350)
    private static let reservoirRanDryAt = Date(timeIntervalSinceReferenceDate: 814_698_535)

    /// The full status asked for after the halt, 10:08:58: state 98, reservoir 0, storage 1643 of patch 274
    private static let fullStatusAfterTheReservoirRanDry = [
        "21039201000062e00f0000c7fe161864eb596b40",
        "21039202061201040100005dc104000000beed"
    ]

    /// 4.6 U/h of ours on patch 274, 185 s in as the reservoir runs dry, every record up to 1640 read
    @discardableResult private func runTempBasalTheReservoirRunsDryOn() -> UnfinalizedDose {
        let state = activePatchState(patchId: 274, scheduledRate: 0.7, sequence: 1640, reservoir: 0.5)
        let tempBasal = runningTempBasal(
            rate: 4.6,
            startedAgo: 185,
            duration: 30 * Self.minute,
            pumpStartTime: Self.tempBasalTheReservoirRanDryOnStart
        )
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.reservoirRanDryAt)
        makeManager(state)
        return tempBasal
    }

    /// Record 1641, as the device read it: ABSOLUTE_TEMP 4.6 U/h, ended by STOP_EMPTY, 0.25 U
    private func scriptRecordOfTheTempBasalTheReservoirRanDryOn() {
        link.script(CommandType.GET_RECORD, [
            "276393010000aa2002ff9e75aef7120169066e62",
            "27639302bd1b182cbe1b1806095c0005005c00fa",
            "27639303ab01b5162051"
        ])
    }

    /// Records 1642 (type 10) and 1643 (an alarm), as the device read them
    private func scriptRecordsAfterTheTempBasalTheReservoirRanDryOn() {
        link.script(CommandType.GET_RECORD, [
            "2b6394010000aa240aff9e75aef712016a062c69",
            "2b639402be1b187800ffff8428c23f77c85b3f7f",
            "2b63940300000000bd1d794d9da1"
        ])
        link.script(CommandType.GET_RECORD, [
            "276395010000aa2003ff9e75aef712016b065bda",
            "27639502c104002cbe1b180800ffffa20ea20e23",
            "2763950383693d2dd13a"
        ])
    }

    // MARK: - Turned down

    /// The basal state left active while a temp basal of ours runs - a status's write landing after the command's own:
    /// the next set goes out without a cancel, and the patch turns it down. Nothing was cancelled: the temp basal runs
    /// on, not ended at the rejection.
    func testRejectedSetWithNoCancelLeavesTheTempBasalRunning() {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.state.basalState = .active

        link.script(CommandType.SET_TEMP_BASAL, .failure(.invalidResponse(code: 8)))
        guard case .communication? = commandTempBasal(0.5, duration: 30 * Self.minute) else {
            XCTFail("The set did not fail")
            return
        }
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_TEMP_BASAL])
        XCTAssertTrue(pumpManager.state.basalDose === tempBasal)
        XCTAssertFalse(tempBasal.isFinished)
        XCTAssertEqual(delegate.batches.count, 0)
    }

    /// The cancel answered, the set turned down: the patch runs the schedule from the cancel - the temp basal before
    /// ended there, final from the record the cancel named
    func testRejectedSetAfterTheCancelEndsTheTempBasalAtTheCancel() {
        let tempBasal = runTempBasalOfOurs()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer())
        link.script(CommandType.SET_TEMP_BASAL, .failure(.invalidResponse(code: 8)))
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        guard case .communication? = commandTempBasal(0.5, duration: 30 * Self.minute) else {
            XCTFail("The set did not fail")
            return
        }
        settle()

        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.startDate, tempBasal.startDate)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        XCTAssertEqual(pumpManager.state.basalState, .active)
    }
}

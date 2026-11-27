import LoopKit
@testable import MedtrumKit
import XCTest

// MARK: - Killed while a temp basal's records are read as it ends

extension ManagerTempBasalScenarioTests {
    /// Device 2026-10-20 13:38:30 (`logs1020c`, M:21452-21586): a suspend while 0.85 U/h runs, the patch's status of it
    /// naming the temp basal's record, the command reading it - and iAPS killed during the read. The state the host had
    /// then is what the app comes back with: the temp basal ended, waiting on its record 131, the suspend held behind it.
    /// Nothing goes out before the patch is back; its first status - the connect's - has 131 read: final from it, the
    /// suspend after it in the same batch, then the resume.
    func testTempBasalASuspendEndedIsReadAfterARestartDuringItsRead() throws {
        let tempBasal = try suspendCommandKilledDuringTheRead().tempBasal
        XCTAssertNotNil(pumpManager.pendingTempBasalEnd, "waiting on its read again")

        // The loop's first run, the patch not back yet: nothing reported - not the suspend, nor the temp basal's final
        pumpManager.resendUnacknowledgedFinalsIfDue()
        settle()
        XCTAssertTrue(delegate.batches.isEmpty)

        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35, endReason: .SUSPEND_MANUAL))
        link.deliverFullStatus(notification: haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131), duringReconnect: true)
        settle()

        XCTAssertEqual(link.writtenCommands.last, CommandType.GET_RECORD)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        XCTAssertEqual(delegate.batches.count, 1)
        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record, not 0.4 U by our estimate")
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty, "stored")
        assertOneFinal(of: doses.first)

        link.script(CommandType.RESUME_PUMP, PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 131, patchId: 251, start: Self.ourEnd.addingTimeInterval(60)
        ))
        advanceClock(by: 60)
        XCTAssertNil(commandResume())
        settle()
        XCTAssertEqual(reports(of: .resume).count, 1)
        XCTAssertEqual(reports(of: .suspend).count, 1)
    }

    /// The same restart, the read on the first status failing: our estimate stands in, as it did on any restart before,
    /// the suspend after it
    func testTempBasalASuspendEndedFallsBackToOurEstimateWhenItsReadAfterTheRestartFails() throws {
        let tempBasal = try suspendCommandKilledDuringTheRead().tempBasal

        link.script(CommandType.GET_RECORD, .timeout)
        link.deliverFullStatus(notification: haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131), duringReconnect: true)
        settle()

        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "1.2 U/h for 20 min, by our estimate")
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
    }

    /// The same restart, the patch out of reach: within `tempBasalEndFromLastRunLinkWait` the loop's runs report
    /// nothing; past it the temp basal goes final from our estimate, the suspend with it - with no link. A status after
    /// that reads nothing.
    func testTempBasalASuspendEndedGoesFinalFromOurEstimateWithNoLinkAfterTheRestart() throws {
        let tempBasal = try suspendCommandKilledDuringTheRead().tempBasal
        let written = link.writtenCommands.count

        advanceClock(by: MedtrumPumpManager.tempBasalEndFromLastRunLinkWait - 5)
        pumpManager.resendUnacknowledgedFinalsIfDue()
        settle()
        XCTAssertTrue(delegate.batches.isEmpty, "not yet")

        advanceClock(by: 5)
        pumpManager.resendUnacknowledgedFinalsIfDue()
        settle()

        XCTAssertEqual(link.writtenCommands.count, written, "no link")
        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)

        link.notify(haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131))
        settle()
        XCTAssertEqual(link.writtenCommands.count, written, "nothing read")
        assertOneFinal(of: doses.first)
    }

    /// A state saved by the build before - the temp basal waiting on its record with no last record kept - decodes, and
    /// goes out as it did: final from our estimate with the first batch, the suspend after it, nothing read
    func testTempBasalSavedWaitingOnItsRecordByTheBuildBeforeGoesFinalFromOurEstimate() throws {
        var raw = try suspendCommandKilledDuringTheRead(restarting: false).saved
        let awaiting = try XCTUnwrap(raw["awaitingRecord"] as? [UnfinalizedDose.RawValue])
        XCTAssertTrue(awaiting.contains { $0["endReadLastRecord"] as? Int == 131 }, "kept with it")
        raw["awaitingRecord"] = awaiting.map { dose in
            var dose = dose
            dose["endReadLastRecord"] = nil
            dose["endReadPatchEnd"] = nil
            return dose
        }
        try restart(from: raw)
        let written = link.writtenCommands.count
        let ended = try XCTUnwrap(pumpManager.state.awaitingRecord.first { $0.type == .tempBasal })
        XCTAssertTrue(ended.isFinished)
        XCTAssertNil(ended.snapshot.endReadLastRecord)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)

        pumpManager.resendUnacknowledgedFinalsIfDue()
        settle()

        XCTAssertEqual(link.writtenCommands.count, written)
        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
    }

    /// A cancel to the schedule, killed during the read of the record its answer named: after the restart the first
    /// status reads it - final from it, the scheduled basal after it
    func testTempBasalACancelEndedIsReadAfterARestartDuringItsRead() throws {
        let tempBasal = runTempBasalOfOurs()
        scriptCancel()
        let duringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            duringRead.value = delegate.savedState
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        try restart(from: duringRead.value)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        XCTAssertNotNil(pumpManager.pendingTempBasalEnd)

        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        link.deliverFullStatus(notification: scheduledBasalRunning(), duringReconnect: true)
        settle()

        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .basal])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)
    }

    // MARK: Records left to the sync

    /// Device 2026-10-20 13:35:23-13:41:25 (M:21381, 21441, 21555): the records after a temp basal's own, its read left to
    /// the sync, waited 7 min for a full sync - the commands' answers kept the status fresh, and no dose waited on them.
    /// Here an occlusion's status names 133, 131 settles the temp basal, 132-133 are left: the next heartbeat reads them,
    /// the status fresh.
    func testRecordsATempBasalsReadLeftToTheSyncAreReadByTheNextHeartbeat() {
        runTempBasalOfOurs()
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35, endReason: .STOP_OCCLUSION))
        link.notify(haltNotification(.occlusion, at: nil, newestRecord: 133))
        settle()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)

        pumpManager.state.lastSync = Date.now
        XCTAssertEqual(pumpManager.heartbeatSync(), .records, "no dose waits on them, the status fresh")
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 132, patchId: 251))
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 133, patchId: 251))
        syncRecords(.awaitingDoses)

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 133)
        XCTAssertNil(pumpManager.heartbeatSync(), "read up")
    }

    /// Records a command told of moments ago are not the heartbeat's: the loop's bolus right behind the command has the
    /// link first. Past `openTempBasalEndReadDelay` they are.
    func testRecordsACommandToldOfAreLeftToTheBolusBehindItForAMoment() {
        startOnTheSchedule()
        pumpManager.openTempBasalEndReadDelay = 60
        setTempBasalOnTheSchedule()
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 515)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 513)

        pumpManager.state.lastSync = Date.now
        XCTAssertNil(pumpManager.heartbeatSync(), "right after the command")
        advanceClock(by: 60)
        XCTAssertEqual(pumpManager.heartbeatSync(), .records)
    }

    /// The last record and patch end of a temp basal whose records are read as it ends survive the state's round trip -
    /// and a dose saved without them decodes with none
    func testTempBasalEndReadSurvivesTheRoundTrip() throws {
        let dose = runningTempBasal(rate: 1.2, startedAgo: 20 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.ourStart)
        dose.finish(.cancelled, endedAt: Date.now)
        dose.noteEndRead(lastRecord: 131, patchEnd: Self.ourEnd)

        let restored = try XCTUnwrap(UnfinalizedDose(rawValue: dose.rawValue))
        XCTAssertEqual(restored.snapshot.endReadLastRecord, 131)
        XCTAssertEqual(restored.snapshot.endReadPatchEnd, Self.ourEnd)

        var raw = dose.rawValue
        raw["endReadLastRecord"] = nil
        raw["endReadPatchEnd"] = nil
        let old = try XCTUnwrap(UnfinalizedDose(rawValue: raw))
        XCTAssertNil(old.snapshot.endReadLastRecord)
        XCTAssertNil(old.snapshot.endReadPatchEnd)
        XCTAssertTrue(old.isFinished)
    }

    /// The same restart, the patch out of reach and the loop not running either: at the bound, on the timer the restart
    /// set, the temp basal goes final from our estimate, the suspend with it - not with the loop's next run, minutes
    /// later. The timer's delay shortened here.
    func testTempBasalASuspendEndedGoesFinalFromOurEstimateAtTheBoundWithNoLoopRun() throws {
        let delay = MedtrumPumpManager.tempBasalEndFromLastRunCheckDelay
        MedtrumPumpManager.tempBasalEndFromLastRunCheckDelay = 0.5
        addTeardownBlock { MedtrumPumpManager.tempBasalEndFromLastRunCheckDelay = delay }

        let tempBasal = try suspendCommandKilledDuringTheRead().tempBasal
        let written = link.writtenCommands.count
        XCTAssertNotNil(pumpManager.pendingTempBasalEnd, "not yet")

        XCTAssertTrue(giveTime(timeout: 5) { self.pumpManager.pendingTempBasalEnd == nil }, "given up on, no loop run")
        settle()

        XCTAssertEqual(link.writtenCommands.count, written, "no link")
        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)
    }

    /// Restarts one after the other, the patch out of reach - a crash loop: the first, right after the suspend, waits
    /// on the read; the next, `tempBasalEndFromLastRunLinkWait` since the temp basal ended, does not wait it out again -
    /// final from our estimate with its first batch, the suspend after it, nothing read. A manager's init goes by the
    /// wall clock, not the one the scenario moves: the end is dated back in the state instead.
    func testTempBasalASuspendEndedIsNotRestoredAgainOnceItEndedTheBoundAgo() throws {
        let killed = try suspendCommandKilledDuringTheRead()
        XCTAssertNotNil(pumpManager.pendingTempBasalEnd, "waiting on its read")

        var raw = pumpManager.rawState
        let awaiting = try XCTUnwrap(raw["awaitingRecord"] as? [UnfinalizedDose.RawValue])
        raw["awaitingRecord"] = awaiting.map { dose in
            var dose = dose
            if let finishedAt = dose["finishedAt"] as? Date {
                dose["finishedAt"] = finishedAt.addingTimeInterval(-MedtrumPumpManager.tempBasalEndFromLastRunLinkWait)
            }
            return dose
        }
        try restart(from: raw)
        XCTAssertNil(pumpManager.pendingTempBasalEnd, "not waited on again")
        let written = link.writtenCommands.count

        pumpManager.resendUnacknowledgedFinalsIfDue()
        settle()

        XCTAssertEqual(link.writtenCommands.count, written)
        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .suspend])
        XCTAssertEqual(doses.first?.startDate, killed.tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
    }

    /// The same restart, a resume kept from before the temp basal - the host yet to store it - dated at the temp basal's
    /// start: the clamps after a resume keep that from arising in a run (`earliestAfter`), a wall clock set back between
    /// the two would not. Restored, it is not taken for one held behind the temp basal's end: its record running a minute
    /// past where we took it to end, the final ends where the suspend after it starts - not at its own start, where the
    /// resume would have it end as the first of what followed it.
    func testTempBasalRestoredWaitingOnItsReadHoldsBehindItOnlyWhatFollowedIt() throws {
        checksLoopOrdering = false
        let killed = try suspendCommandKilledDuringTheRead(restarting: false)
        let start = killed.tempBasal.startDate
        hostSuspendedSince = start.addingTimeInterval(-Self.minute)
        var kept = UnfinalizedDose(resumeStartTime: start, insulinType: nil).rawValue
        kept["heldAt"] = start
        var raw = killed.saved
        raw["heldBasalDoses"] = [kept] + (raw["heldBasalDoses"] as? [UnfinalizedDose.RawValue] ?? [])
        // The patch shows it end a minute past where we took it to
        let recordEnd = Self.ourEnd.addingTimeInterval(Self.minute)
        let awaiting = try XCTUnwrap(raw["awaitingRecord"] as? [UnfinalizedDose.RawValue])
        raw["awaitingRecord"] = awaiting.map { dose in
            var dose = dose
            if dose["endReadLastRecord"] != nil {
                dose["endReadPatchEnd"] = recordEnd
            }
            return dose
        }
        try restart(from: raw)
        XCTAssertEqual(pumpManager.state.heldBasalDoses.map(\.dose.type), [.resume, .suspend])
        XCTAssertNotNil(pumpManager.pendingTempBasalEnd)

        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: Self.ourStart,
            end: recordEnd,
            rate: 1.2,
            delivered: 0.35,
            endReason: .SUSPEND_MANUAL
        ))
        link.deliverFullStatus(notification: haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131), duringReconnect: true)
        settle()

        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.type), [.resume, .tempBasal, .suspend], "the resume ahead, as kept from before")
        let final = try XCTUnwrap(doses.first { $0.type == .tempBasal })
        let suspend = try XCTUnwrap(doses.first { $0.type == .suspend })
        XCTAssertEqual(final.isMutable, false)
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(final.endDate, suspend.startDate, "where the suspend starts, not at its own start")
    }

    /// A cancel to the schedule killed during its read, as above: after the restart the connect's status leaves the read
    /// to the queue, and the loop's bolus gets the patch first. The bolus reads it before it goes out - final from its
    /// record, the scheduled basal after it - rather than its batch taking it out from our estimate.
    func testTempBasalRestoredWaitingOnItsReadIsReadByABolusThatComesFirst() throws {
        let tempBasal = runTempBasalOfOurs()
        scriptCancel()
        let duringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            duringRead.value = delegate.savedState
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        try restart(from: duringRead.value)
        XCTAssertNotNil(pumpManager.pendingTempBasalEnd)
        let written = link.writtenCommands.count

        // The queue's read held up behind the bolus
        let queueFree = DispatchSemaphore(value: 0)
        pumpManager.tempBasalEndQueue.async { queueFree.wait() }
        link.deliverFullStatus(notification: scheduledBasalRunning(), duringReconnect: true)
        delegate.queue.sync {}
        XCTAssertTrue(delegate.batches.isEmpty, "the read left to the queue")

        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(1.0))
        queueFree.signal()
        settle()

        XCTAssertEqual(Array(link.writtenCommands.dropFirst(written)), [CommandType.GET_RECORD, CommandType.SET_BOLUS], "read first")
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.type), [.tempBasal, .basal])
        XCTAssertEqual(doses.first?.startDate, tempBasal.startDate)
        XCTAssertEqual(doses.first?.isMutable, false)
        XCTAssertEqual(doses.first?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record, not 0.4 U by our estimate")
        XCTAssertTrue(finals(of: doses.first).allSatisfy { abs(($0.deliveredUnits ?? 0) - 0.35) < 0.001 }, "one final, the same every time")
        XCTAssertEqual(reports(of: .bolus).count, 1)
    }

    /// 1.2 U/h of ours, suspended on a command - the patch's status of it, naming 131, in after the answer - the command
    /// reading 131, and the app killed then: restarted from the state the host had during the read, unless not
    /// `restarting`. Returns the temp basal, and that state.
    @discardableResult private func suspendCommandKilledDuringTheRead(
        restarting: Bool = true
    ) throws -> (tempBasal: UnfinalizedDose, saved: PumpManager.RawStateValue) {
        let tempBasal = runTempBasalOfOurs()
        let delivered = notifySoonAfterTheSuspend(haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131))
        let duringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35, endReason: .SUSPEND_MANUAL))) {
            [unowned self] in
            duringRead.value = delegate.savedState
        }
        XCTAssertNil(commandSuspend())
        wait(for: [delivered], timeout: 5)
        settle()
        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])

        let saved = try XCTUnwrap(duringRead.value, "no state handed over before the read")
        guard restarting else {
            return (tempBasal, saved)
        }
        try restart(from: saved)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.heldBasalDoses.map(\.dose.type), [.suspend])
        XCTAssertTrue(delegate.batches.isEmpty)
        return (tempBasal, saved)
    }
}

import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerTempBasalScenarioTests {
    // MARK: - While the records are read

    /// The host has the state before the command reads the record the cancel named: the app killed during the read
    /// comes back with the schedule running - not the old 1.2 U/h - and the old one ended at the cancel, which its first
    /// batch reports final from our estimate, with the schedule
    func testStateTheHostHasDuringTheReadRestartsWithTheSchedule() throws {
        let tempBasal = runTempBasalOfOurs()
        scriptCancel()
        let savedDuringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            savedDuringRead.value = delegate.savedState
        }
        let cancelSentAt = Date.now
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        // Killed during the read: what the host saved then is what the app comes back with
        let restored = MedtrumPumpState(rawValue: try XCTUnwrap(savedDuringRead.value, "no state handed over before the read"))
        XCTAssertEqual(restored.basalDose.type, .basal)
        XCTAssertEqual(restored.basalDose.value, 0.7)
        XCTAssertEqual(restored.basalState, .active)
        let ended = try XCTUnwrap(restored.awaitingRecord.first { $0.type == .tempBasal })
        XCTAssertEqual(ended.startDate, tempBasal.startDate)
        XCTAssertEqual(ended.value, 1.2)
        XCTAssertTrue(ended.isFinished)
        XCTAssertFalse(ended.isFinalized)
        XCTAssertGreaterThanOrEqual(ended.observedEndDate ?? .distantPast, cancelSentAt)

        let host = FakePumpManagerDelegate()
        let restarted = MedtrumPumpManager(state: restored, link: FakeMedtrumLink())
        restarted.delegateQueue = host.queue
        restarted.pumpManagerDelegate = host
        restarted.emitPumpEvents([])
        host.queue.sync {}

        let events = try XCTUnwrap(host.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(events.map(\.unitsPerHour), [1.2, 0.7])
        XCTAssertEqual(events.first?.isMutable, false)
        XCTAssertEqual(events.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        XCTAssertEqual(events.last?.type, .basal)
    }

    /// The cancel's scheduled basal, shown during the read after the command, arrives on the queue statuses do and waits
    /// for nothing: it is from before the new temp basal, which runs on
    func testCancelsSegmentShownDuringTheReadLeavesTheNewTempBasalRunning() throws {
        let tempBasal = runTempBasalOfOurs()
        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            link.notify(scheduledBasalRunning())
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
        XCTAssertFalse(pumpManager.state.basalDose.isFinished)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertEqual(delegate.batches.count, 2)
        XCTAssertEqual(delegate.batches.last?.events.map(\.dose?.unitsPerHour), [1.2, 0.5])
        let old = delegate.batches.last?.events.first?.dose
        XCTAssertEqual(old?.startDate, tempBasal.startDate)
        XCTAssertEqual(old?.isMutable, false)
        XCTAssertEqual(old?.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
    }

    /// A bolus asked for while the records of the temp basal a command ended back to back are read, after it: the read
    /// stops at the record in flight, and the bolus goes out - the record it waits on is left to a later sync, the old
    /// temp basal mutable meanwhile
    func testBolusAskedForDuringTheReadAfterTheCommandWaitsForTheRecordInFlightOnly() throws {
        let tempBasal = runTempBasalOfOurs(patchId: 236)
        scriptCancelAndSet(patchId: 236, cancelRecord: 132)
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")

        let bolusDone = expectation(description: "enactBolus")
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 236))) { [unowned self] in
            pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { _ in bolusDone.fulfill() }
            // The time a device gives it to go out
            giveTime { self.link.writtenCommands.contains(CommandType.SET_BOLUS) }
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        wait(for: [bolusDone], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [
            CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SET_BOLUS
        ])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131, "132 is left for a later sync")
        XCTAssertTrue(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).isEmpty)
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds)
        XCTAssertEqual(reports(of: .bolus).count, 1)
    }

    /// A command asked for while a sync reads a record waits for that read - and the sync reads no record after it
    func testCommandAskedForDuringASyncsReadWaitsForIt() {
        runTempBasalOfOurs(patchId: 236)
        pumpManager.state.currentSequenceNumber = 132
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")

        let bolusDone = expectation(description: "enactBolus")
        let bolusDuringRead = Locked(false)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 236))) { [unowned self] in
            pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { _ in bolusDone.fulfill() }
            bolusDuringRead.value = giveTime { self.link.writtenCommands.contains(CommandType.SET_BOLUS) }
        }
        syncRecords()
        wait(for: [bolusDone], timeout: 5)
        settle()

        XCTAssertFalse(bolusDuringRead.value, "the bolus went out while the record was read")
        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD, CommandType.SET_BOLUS])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131, "132 is left for the next sync")
    }

    /// The record the cancel named times out: the read waits no longer than a record may take, not a write's 30 s
    func testReadThatTimesOutTakesNoMoreThanItsBudget() {
        runTempBasalOfOurs()
        link.onTimeout = { [unowned self] waited in advanceClock(by: waited) }

        let final = cancelItUnread()

        XCTAssertLessThanOrEqual(written(CommandType.GET_RECORD)?.timeout ?? .infinity, MedtrumPumpManager.tempBasalEndReadBudget)
        XCTAssertLessThanOrEqual(clockOffset.value, MedtrumPumpManager.tempBasalEndReadBudget)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
    }

    /// The cancel names 132: 131 takes all of the budget to come back, and 132 is not asked for - our estimate stands in.
    /// 131 is kept as any record read is.
    func testReadStopsWhereItsBudgetRunsOutKeepingWhatItRead() {
        runTempBasalOfOurs()
        scriptCancel(cancelRecord: 132)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 251))) { [unowned self] in
            advanceClock(by: MedtrumPumpManager.tempBasalEndReadBudget + 1)
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
        XCTAssertEqual(pumpManager.recordStore.records.map(\.id), [131])
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
    }

    /// A record sync is running as the command would read, and goes on running: it waits for it only a moment - our
    /// estimate stands in, and the record is left for a sync
    func testReadDoesNotWaitForARecordSyncRunning() {
        runTempBasalOfOurs()
        scriptCancel()

        let started = Date.now
        RecordSyncer.whileRunningForTesting {
            XCTAssertNil(commandTempBasal(0, duration: 0))
        }
        XCTAssertLessThan(Date.now.timeIntervalSince(started), RecordSyncer.inCommandRunWait + 1.5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 130)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.7])
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.isMutable, false)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
    }

    /// A record sync is running as the command would read - the loop's own, which its follow-up started just before:
    /// it stops at its next record, seeing the command, and the read waits the moment that takes
    func testReadWaitsForARecordSyncRunningToStop() {
        runTempBasalOfOurs()
        scriptCancel()
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))

        let running = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [unowned self] in
            RecordSyncer.whileRunningForTesting {
                running.signal()
                giveTime(timeout: 5) { self.link.writtenCommands.contains(CommandType.CANCEL_TEMP_BASAL) }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        running.wait()
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
    }

    /// The cancel names 132: 131 comes back with less than a round trip of the budget left, and 132 is not asked for
    /// only to be given up on - our estimate stands in
    func testReadAsksForNoRecordWithLessThanARoundTripOfItsBudgetLeft() {
        runTempBasalOfOurs()
        scriptCancel(cancelRecord: 132)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 251))) { [unowned self] in
            advanceClock(by: MedtrumPumpManager.tempBasalEndReadBudget - 1)
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
    }

    /// The cancel names 132, and as it is to be read the link is held by another path's write - the heartbeat's full
    /// sync, say, waiting on an answer that does not come: the read waits for the link only for what is left of its
    /// budget, does not write 132 at all, and our estimate stands in
    func testReadWaitsForTheLinkNoLongerThanItsBudget() {
        runTempBasalOfOurs()
        scriptCancel(cancelRecord: 132)
        let release = DispatchSemaphore(value: 0)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 251))) { [unowned self] in
            advanceClock(by: MedtrumPumpManager.tempBasalEndReadBudget - 2.5)
            link.holdWriter(until: release)
        }

        let started = Date.now
        XCTAssertNil(commandTempBasal(0, duration: 0))
        let took = Date.now.timeIntervalSince(started)
        release.signal()
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertLessThan(took, 4)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
    }

    /// One write on the link at a time. With a time limit, the wait for the write ahead is part of it - given up past it,
    /// what is left of it otherwise for the answer. Without, as long as the write ahead takes, then the full write
    /// timeout for the answer.
    func testLinkWriterWaitsForTheWriteAheadOnlyWithinItsTimeLimit() {
        let writer = LinkWriter()
        let release = DispatchSemaphore(value: 0)
        let held = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = writer.exclusively(within: nil) { _ in
                held.signal()
                release.wait()
            }
        }
        held.wait()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { release.signal() }

        var started = Date.now
        XCTAssertNil(writer.exclusively(within: 0.3) { _ in XCTFail("written while another write held the link") })
        XCTAssertEqual(Date.now.timeIntervalSince(started), 0.3, accuracy: 0.25)

        started = Date.now
        let left = writer.exclusively(within: 5) { $0 }
        let waited = Date.now.timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.4)
        XCTAssertEqual(left ?? 0, 5 - waited, accuracy: 0.1)

        XCTAssertEqual(writer.exclusively(within: nil) { $0 }, PeripheralManager.writeTimeout)
    }

    /// The host is slow to take the state before the read - 2.5 s: the time that takes is not taken from the read's
    /// budget. The cancel names 132, and 131 takes 9 s to come back: 132 is given all the 10 s a record may take - with
    /// the hand-over counted, only the 8.5 s left.
    func testHandOverBeforeTheReadIsNotCountedInItsBudget() {
        runTempBasalOfOurs()
        link.script(CommandType.CANCEL_TEMP_BASAL, .fragments(cancelAnswer(record: 132))) { [unowned self] in
            delegate.queue.async { Thread.sleep(forTimeInterval: 2.5) }
        }
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 251))) { [unowned self] in
            advanceClock(by: 9)
        }
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(sequence: 132, delivered: 0.35))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.GET_RECORD])
        XCTAssertLessThanOrEqual(link.writes.first { $0.commandType == CommandType.GET_RECORD }?.timeout ?? .infinity, 10)
        XCTAssertGreaterThan(written(CommandType.GET_RECORD)?.timeout ?? 0, MedtrumPumpManager.tempBasalEndRecordTimeout - 0.5)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
    }

    /// The host does not take the state within the bound as the set is to go out, after the cancel ended the temp basal
    /// running: the set is not written - killed after it, the app would come back with the patch running a temp basal it
    /// has no dose of, uncounted - and fails. The cancel stands: the temp basal ends there, final from the record it
    /// named, the scheduled basal after it - as when the set fails. Nothing pending, and the next set goes out as ever.
    func testTempBasalIsNotWrittenAndFailsWhenTheHostDoesNotTakeTheStateAfterTheCancel() {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.dosingHandOverTimeout = 1
        // Free once the cancel is answered, busy from then on
        let releaseHost = Locked<(() -> Void)?>(nil)
        defer { releaseHost.value?() }
        link.script(CommandType.CANCEL_TEMP_BASAL, .fragments(cancelAnswer(record: 131))) { [unowned self] in
            releaseHost.value = stallHost()
        }
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))

        let error = commandTempBasal(0.5, duration: 30 * Self.minute, timeout: 15)
        XCTAssertTrue(isStateNotSaved(error, tempBasalCancelled: true), "failed, not uncertain: \(String(describing: error))")
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD], "no set")
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        XCTAssertEqual(pumpManager.state.basalState, .active)

        releaseHost.value?()
        settle()
        XCTAssertNil(delegate.savedState?["pendingTempBasal"])
        let doses = delegate.batches.flatMap(\.events).compactMap(\.dose)
        let finals = doses.filter { $0.type == .tempBasal && !$0.isMutable }
        XCTAssertEqual(finals.map(\.startDate), [tempBasal.startDate])
        XCTAssertEqual(finals.first?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(doses.last?.type, .basal)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(delegate.errors.count, 0)

        link.script(CommandType.SET_TEMP_BASAL, setAnswer(record: 132))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
    }

    /// The same with no temp basal running: nothing goes out, nothing is reported
    func testTempBasalIsNotWrittenAndFailsWhenTheHostDoesNotTakeTheState() {
        makeManager(activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150))
        pumpManager.dosingHandOverTimeout = 1
        let releaseHost = stallHost()
        defer { releaseHost() }

        XCTAssertTrue(isStateNotSaved(commandTempBasal(0.5, duration: 30 * Self.minute, timeout: 10)))
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)

        releaseHost()
        settle()
        XCTAssertNil(delegate.savedState?["pendingTempBasal"])
        XCTAssertEqual(delegate.batches.count, 0)
    }

    /// The host does not take the state at all as a temp basal of ours runs: the command fails before it cancels it -
    /// nothing sent, the temp basal running runs on, reported as it was - within the one bound, not one for the cancel
    /// and another for the set
    func testTempBasalCommandFailsBeforeItsCancelWhenTheHostDoesNotTakeTheState() {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.dosingHandOverTimeout = 1
        let releaseHost = stallHost()
        defer { releaseHost() }

        let started = Date.now
        let error = commandTempBasal(0.5, duration: 30 * Self.minute, timeout: 10)
        let took = Date.now.timeIntervalSince(started)
        XCTAssertTrue(isStateNotSaved(error, tempBasalCancelled: false), "nothing sent: \(String(describing: error))")
        XCTAssertGreaterThan(took, 0.9)
        XCTAssertLessThan(took, 2.5, "one bound")
        XCTAssertEqual(link.writtenCommands, [], "not cancelled either")
        XCTAssertTrue(pumpManager.state.basalDose === tempBasal)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertNil(pumpManager.state.pendingTempBasal)

        releaseHost()
        settle()
        XCTAssertEqual(delegate.batches.count, 0)
        XCTAssertEqual(delegate.errors.count, 0)
    }

    /// The host saves the state with the set pending, and is held up before it is done with it: on its disk, the set
    /// goes out once the bound is up, logged
    func testTempBasalIsWrittenWhenTheHostSavedTheStateWithItPendingAndIsHeldUp() {
        makeManager(activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150))
        MedtrumLogger.pumpManager = pumpManager
        defer { MedtrumLogger.pumpManager = nil }
        pumpManager.dosingHandOverTimeout = 1
        let releaseHost = stallHostAfterSaving("pendingTempBasal")
        defer { releaseHost() }

        let atWrite = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_TEMP_BASAL, .fragments(setAnswer(record: 131))) { [unowned self] in
            atWrite.value = delegate.savedState
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute, timeout: 10))
        XCTAssertNotNil(atWrite.value?["pendingTempBasal"], "on disk as it went out")

        releaseHost()
        settle()
        XCTAssertTrue(delegate.logEntries.contains { entry in
            entry.message.contains("but read it with the temp basal of 0.5 U/h pending - saving it: written")
        })
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertNil(delegate.savedState?["pendingTempBasal"])
    }

    /// The set not written - the host not taking the state - after the cancel, and the patch shows it suspended as the
    /// command waits: the schedule is not reported from the cancel, dated behind the suspend - the patch is suspended,
    /// as the status says
    func testTempBasalNotWrittenAfterTheCancelWithASuspendShownMeanwhileLeavesItSuspended() {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.dosingHandOverTimeout = 1
        let releaseHost = Locked<(() -> Void)?>(nil)
        defer { releaseHost.value?() }
        link.script(CommandType.CANCEL_TEMP_BASAL, .fragments(cancelAnswer(record: 131))) { [unowned self] in
            releaseHost.value = stallHost()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [link] in
                link?.notify(self.haltNotification(.suspended, at: Self.ourEnd.addingTimeInterval(2), newestRecord: 131))
            }
        }
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))

        let error = commandTempBasal(0.5, duration: 30 * Self.minute, timeout: 20)
        XCTAssertTrue(isStateNotSaved(error, tempBasalCancelled: true), "\(String(describing: error))")
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend, "the status's")
        XCTAssertEqual(pumpManager.state.basalState, .suspended)

        releaseHost.value?()
        settle()
        let doses = delegate.batches.flatMap(\.events).compactMap(\.dose)
        XCTAssertFalse(doses.contains { $0.type == .basal }, "no schedule from the cancel")
        XCTAssertEqual(doses.filter { $0.type == .tempBasal && !$0.isMutable }.map(\.startDate), [tempBasal.startDate])
        XCTAssertEqual(doses.last?.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
    }

    /// A cancel only, and the patch shows itself halted as its answer comes in - before the command carries on: the
    /// schedule is not reported from the cancel - behind the suspend, it would leave it open, no resume after it - the
    /// temp basal ends at the suspend, final from its record, and the patch is suspended. The next halted status reports
    /// no second suspend.
    func testCancelOnlyWithAHaltShownDuringTheCancelLeavesItSuspended() {
        let tempBasal = runTempBasalOfOurs()
        let halt = haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131)
        link.script(CommandType.CANCEL_TEMP_BASAL, .fragments(cancelAnswer(record: 131)), thenNotify: [halt])
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))

        XCTAssertNil(commandTempBasal(0, duration: 0), "cancelled")
        settle()
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)

        link.notify(halt)
        settle()
        let doses = delegate.batches.flatMap(\.events).compactMap(\.dose)
        XCTAssertFalse(doses.contains { $0.type == .basal }, "no schedule from the cancel")
        let finals = doses.filter { $0.type == .tempBasal && !$0.isMutable }
        XCTAssertEqual(finals.map(\.startDate), [tempBasal.startDate])
        XCTAssertEqual(finals.first?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(Set(reports(of: .suspend).map(\.startDate)).count, 1, "one suspend")
        XCTAssertEqual(doses.last?.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
    }

    /// The same halt during the cancel of a command that sets a temp basal after it: the set is not written to a halted
    /// patch - it fails - and nothing follows the suspend
    func testSetIsNotWrittenWithAHaltShownDuringItsCancel() {
        let tempBasal = runTempBasalOfOurs()
        let halt = haltNotification(.suspended, at: Self.ourEnd.addingTimeInterval(2), newestRecord: 131)
        link.script(CommandType.CANCEL_TEMP_BASAL, .fragments(cancelAnswer(record: 131)), thenNotify: [halt])
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))

        let error = commandTempBasal(0.5, duration: 30 * Self.minute)
        guard case let .deviceState(cause)? = error, case .isSuspended? = cause as? MedtrumConnectError else {
            XCTFail("Not failed as suspended: \(String(describing: error))")
            return
        }
        settle()
        XCTAssertFalse(link.writtenCommands.contains(CommandType.SET_TEMP_BASAL))
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertNil(delegate.savedState?["pendingTempBasal"])
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        let doses = delegate.batches.flatMap(\.events).compactMap(\.dose)
        XCTAssertFalse(doses.contains { $0.type == .basal })
        XCTAssertEqual(doses.filter { $0.type == .tempBasal && !$0.isMutable }.map(\.startDate), [tempBasal.startDate])
        XCTAssertEqual(doses.last?.type, .suspend)
    }

    /// A halt shown as the command hands the state to the host before its cancel: the status ended the temp basal
    /// running - nothing is cancelled, nor set
    func testSetIsNotSentWithAHaltShownAsTheCommandWaitsForTheHost() {
        let tempBasal = runTempBasalOfOurs()
        settle()
        let halt = haltNotification(.suspended, at: Self.ourEnd.addingTimeInterval(2), newestRecord: 131)
        let shown = Locked(false)
        delegate.afterSavingState = { [link] _ in
            guard !shown.value else {
                return
            }
            shown.value = true
            // Off the host's queue, while it is held up
            DispatchQueue.global().async { link?.notify(halt) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))

        let error = commandTempBasal(0.5, duration: 30 * Self.minute)
        delegate.afterSavingState = nil
        guard case let .deviceState(cause)? = error, case .isSuspended? = cause as? MedtrumConnectError else {
            XCTFail("Not failed as suspended: \(String(describing: error))")
            return
        }
        settle()
        XCTAssertTrue(shown.value)
        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD], "nothing sent")
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        let doses = delegate.batches.flatMap(\.events).compactMap(\.dose)
        XCTAssertEqual(doses.filter { $0.type == .tempBasal && !$0.isMutable }.map(\.startDate), [tempBasal.startDate])
        XCTAssertEqual(doses.last?.type, .suspend)
    }

    /// A suspend while a temp basal runs, the patch's status of it not in - nor in within the moment it is waited for:
    /// no record of the temp basal's end is known, nothing is read, and the command does not wait for a busy host to
    /// take the state first
    func testSuspendWithNothingToReadDoesNotWaitForTheHost() {
        runTempBasalOfOurs()
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"])) { [unowned self] in
            delegate.queue.async { Thread.sleep(forTimeInterval: 4) }
        }

        let started = Date.now
        XCTAssertNil(commandSuspend())
        let took = Date.now.timeIntervalSince(started)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP])
        XCTAssertLessThan(took, MedtrumPumpManager.suspendAnnouncementWait + 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .suspend])
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.isMutable, false)
    }

    /// Killed while the records of the temp basal ended back to back are read: the app comes back with it ended, mutable,
    /// and the new one running - its first batch carries both mutable, nothing final from our estimate - and its records
    /// are read as ever, making its final
    func testRestartDuringTheReadOfATempBasalEndedBackToBackReadsItsRecordsAgain() throws {
        let tempBasal = runTempBasalOfOurs()
        scriptCancelAndSet()
        let savedDuringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .timeout) { [unowned self] in
            savedDuringRead.value = delegate.savedState
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds, "the record timed out: left to a later sync")

        let restarted = try restart(from: savedDuringRead.value)
        XCTAssertTrue(restarted.hasOpenTempBasalEnds)
        XCTAssertEqual(restarted.state.basalDose.value, 0.5)
        XCTAssertFalse(restarted.state.basalDose.isFinished)
        restarted.emitPumpEvents([])
        settle()

        let first = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose)).sorted { $0.startDate < $1.startDate }
        XCTAssertEqual(first.map(\.unitsPerHour), [1.2, 0.5])
        XCTAssertTrue(first.allSatisfy(\.isMutable), "nothing final from our estimate")
        XCTAssertEqual(first.first?.endDate, first.last?.startDate)

        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        link.script(CommandType.GET_RECORD, cancelsScheduledSecond())
        syncRecords()

        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(old.endDate, first.last?.startDate)
        XCTAssertFalse(restarted.hasOpenTempBasalEnds)
    }

    /// A temp basal asked for while a bolus's SetBolus awaits its answer waits for that command, then finds the bolus
    /// running: refused, neither the cancel of the running temp basal nor the set goes out
    func testTempBasalQueuedBehindABolusIsRefusedWhileItRuns() {
        let tempBasal = runTempBasalOfOurs(patchId: 236)

        let tempBasalDone = expectation(description: "enactTempBasal")
        let tempBasalResult = Locked<PumpManagerError?>(nil)
        link.script(CommandType.SET_BOLUS, .fragments(["0f13280000007b00ec009786a8178900"])) { [unowned self] in
            pumpManager.enactTempBasal(unitsPerHour: 0.5, for: 30 * Self.minute) { error in
                tempBasalResult.value = error
                tempBasalDone.fulfill()
            }
            // Past its checks, and waiting for the lock
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        wait(for: [tempBasalDone], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        guard case let .deviceState(error)? = tempBasalResult.value, case .isBolussing? = error as? MedtrumConnectError else {
            XCTFail("The temp basal was not refused as bolusing: \(String(describing: tempBasalResult.value))")
            return
        }
        XCTAssertTrue(pumpManager.state.basalDose === tempBasal)
        XCTAssertFalse(tempBasal.isFinished)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertNotNil(pumpManager.state.bolusDose)
    }

    /// The set unanswered after an answered cancel: the record the cancel named is not read on that link - see
    /// `startUnansweredTempBasal`
    func testUnansweredSetLeavesTheTempBasalTheCancelEndedToOurEstimate() {
        startUnansweredTempBasal()
    }

    /// Expiry first seen by the reconnect's full status, with no command in flight: its record is read off the queue
    /// statuses arrive on, and nothing goes out before - the full status's own batch would carry it out from our
    /// estimate first
    func testExpiryTheReconnectsFullStatusShowsIsFinalizedFromItsRecord() {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        let tempBasal = runningTempBasal(rate: 0.5, startedAgo: 30 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.ourStart)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.ourStart.addingTimeInterval(1800))
        makeManager(state)

        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: Self.ourStart,
            end: Self.ourStart.addingTimeInterval(1800),
            rate: 0.5,
            delivered: 0.2
        ))
        link.deliverFullStatus(
            notification: PatchBytes.basalNotification(
                type: .STANDARD,
                sequence: 131,
                patchId: 251,
                start: Self.ourStart.addingTimeInterval(1800),
                rate: 0.7
            ),
            duringReconnect: true
        )
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        XCTAssertEqual(delegate.batches.first?.replacePendingEvents, true)
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.startDate, tempBasal.startDate)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.2, accuracy: 0.001, "the record's, not 0.25 U by rate × duration")
        XCTAssertEqual(reports(of: .tempBasal).count, 1, "never mutable")
    }

    /// The base resets while the command reads the record the cancel named: the session ended, the temp basal went out
    /// final from our estimate with it, and the record read is not this session's - not kept, the cursor not moved
    func testRecordReadAcrossABaseResetIsNotKept() {
        let tempBasal = runTempBasalOfOurs()
        scriptCancelAndSet()
        // A second into the new temp basal, on the manager's clock it starts on: not cut to its start
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            advanceClock(by: 1)
            link.onQueue {
                self.pumpManager.handleBaseReset(deliveryStoppedAt: self.pumpManager.now())
            }
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertTrue(pumpManager.state.patchId.isEmpty)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 0)
        XCTAssertEqual(pumpManager.recordStore.records.map(\.id), [])
        let old = finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate })
        XCTAssertEqual(old.count, 1)
        XCTAssertEqual(old.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
    }

    // MARK: - Saved before the set goes out

    /// Killed as the set of 0.5 U/h after the answered cancel of the 1.2 U/h one awaited its answer: the state the host
    /// saved before it went out has it pending. The next run keeps it unconfirmed - the old one ended at the cancel, final
    /// from our estimate - and the reconnect's status showing it running has it reported from its start on: not taken for
    /// a temp basal none of ours is, the old one not left to run on at its rate.
    func testTempBasalAwaitingItsAnswerWhenTheAppWasKilledIsReportedOnceTheReconnectShowsIt() throws {
        let tempBasal = runTempBasalOfOurs()
        let atWrite = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer())
        link.script(CommandType.SET_TEMP_BASAL, .timeout) { [unowned self] in
            atWrite.value = delegate.savedState
        }
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()

        let saved = try XCTUnwrap(atWrite.value, "nothing handed over before the write")
        let pending = try XCTUnwrap(
            (saved["pendingTempBasal"] as? PendingTempBasal.RawValue).flatMap(PendingTempBasal.init(rawValue:))
        )
        XCTAssertEqual(pending.unitsPerHour, 0.5)
        XCTAssertEqual(pending.duration, 30 * Self.minute)
        XCTAssertEqual(pending.sequenceAtSend, 131)
        XCTAssertEqual(pending.priorSegmentStart, Self.ourEnd)
        XCTAssertNotNil(pending.cancelledAt)
        XCTAssertNil(pumpManager.state.pendingTempBasal, "cleared as its outcome came in")
        XCTAssertNil(delegate.savedState?["pendingTempBasal"])

        try restart(from: saved)

        let unconfirmed = try XCTUnwrap(pumpManager.state.unconfirmedTempBasal)
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertEqual(unconfirmed.value, 0.5)
        XCTAssertEqual(unconfirmed.sentAt, pending.sentAt)
        XCTAssertEqual(unconfirmed.confirmation, .uncertain)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal, "the cancel ended the old one")
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal, "it may be running: the next temp basal cancels first")
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(uncertain.map(\.kind), [.tempBasal])
        XCTAssertEqual(uncertain.first?.cause, .appRestarted)
        XCTAssertEqual(uncertain.first?.phase, .notReported)
        let ended = try XCTUnwrap(pumpManager.state.awaitingRecord.first { $0.startDate == tempBasal.startDate })
        XCTAssertTrue(ended.isFinalized)
        XCTAssertEqual(ended.observedEndDate, pending.cancelledAt)

        // The reconnect: the patch runs it
        link.deliverFullStatus(notification: newTempBasalRunning(), duringReconnect: true)
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
        XCTAssertEqual(pumpManager.state.basalDose.pumpStartTime, Self.ourEnd.addingTimeInterval(1))
        // Then the full status's own
        XCTAssertEqual(delegate.batches.count, 2)
        let doses = delegate.batches.first?.events.compactMap(\.dose) ?? []
        let old = doses.first { $0.startDate == tempBasal.startDate }
        XCTAssertEqual(old?.isMutable, false)
        XCTAssertEqual(old?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate, to the cancel")
        let new = doses.first { $0.type == .tempBasal && $0.unitsPerHour == 0.5 }
        XCTAssertEqual(new?.isMutable, true)
        XCTAssertEqual(delegate.errors.count, 0, "not taken for a temp basal none of ours is")
    }

    /// The same with nothing running before - no cancel: the set of 0.5 U/h over the schedule, the app killed before its
    /// answer. The next run keeps it unconfirmed, and a status showing it running has it reported.
    func testTempBasalOverTheScheduleAwaitingItsAnswerWhenTheAppWasKilledIsReportedOnceAStatusShowsIt() throws {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        state.lastSegmentStart = Self.ourStart
        alignPatchClock(state, patchTime: Self.ourEnd)
        makeManager(state)

        let atWrite = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_TEMP_BASAL, .timeout) { [unowned self] in
            atWrite.value = delegate.savedState
        }
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0.5, duration: 30 * Self.minute)))
        settle()

        let saved = try XCTUnwrap(atWrite.value, "nothing handed over before the write")
        let pending = try XCTUnwrap(
            (saved["pendingTempBasal"] as? PendingTempBasal.RawValue).flatMap(PendingTempBasal.init(rawValue:))
        )
        XCTAssertNil(pending.cancelledAt)

        try restart(from: saved)
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.value, 0.5)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)

        link.notify(newTempBasalRunning())
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
        let reported = reports(of: .tempBasal)
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.unitsPerHour ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(reported.first?.isMutable, true)
        XCTAssertEqual(delegate.errors.count, 0)
    }

    /// A SetTempBasal turned down, saved pending before it went out: off the saved state before it fails - a restart
    /// from that runs nothing
    func testRejectedSetLeavesNothingPending() throws {
        makeManager(activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150))
        let atWrite = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_TEMP_BASAL, .failure(.invalidResponse(code: 8))) { [unowned self] in
            atWrite.value = delegate.savedState
        }
        guard case .communication? = commandTempBasal(0.5, duration: 30 * Self.minute) else {
            XCTFail("The set did not fail")
            return
        }
        settle()

        XCTAssertNotNil(atWrite.value?["pendingTempBasal"])
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertNil(delegate.savedState?["pendingTempBasal"])
        try restart(from: delegate.savedState)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
    }

    /// A status showing a temp basal of 1.5 U/h no dose of ours is - none running, none sent, none unconfirmed, none
    /// that ended - from after the latest segment known: what it delivers is counted nowhere. The host is warned of
    /// uncertain delivery, once for the segment, and the settings say it is not counted.
    func testTempBasalNoneOfOursAStatusShowsIsWarnedOfOnce() {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        state.lastSegmentStart = Self.ourStart
        alignPatchClock(state, patchTime: Self.ourEnd)
        makeManager(state)

        let unknown = PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 130,
            patchId: 251,
            start: Self.ourEnd.addingTimeInterval(-60),
            rate: 1.5
        )
        link.notify(unknown)
        settle()

        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(uncertain.map(\.kind), [.tempBasal])
        XCTAssertEqual(uncertain.first?.cause, .unknownSegment)
        XCTAssertEqual(uncertain.first?.phase, .settled(.notCounted))
        XCTAssertEqual(pumpManager.state.uncertainDeliveries.first?.amount ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal, "the next temp basal cancels first")
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)

        // Shown again, by a notification and a full status
        link.notify(unknown)
        link.deliverFullStatus(notification: unknown, duringReconnect: false)
        settle()
        XCTAssertEqual(uncertainDeliveryErrors, 1, "warned once")
        XCTAssertEqual(uncertain.count, 1)
        XCTAssertTrue(reports(of: .tempBasal).isEmpty)
    }

    /// The new temp basal's segment, shown while its set awaits its answer - the set being written - and the old one's,
    /// shown after the new one runs: both ours, neither warned of
    func testTempBasalsOfOursShownAsTheyChangeAreNotWarnedOf() {
        let tempBasal = runTempBasalOfOurs()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer())
        link.script(CommandType.SET_TEMP_BASAL, .fragments(setAnswer()), thenNotify: [newTempBasalRunning()])
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.2))
        settle()

        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertTrue(uncertain.isEmpty)
        XCTAssertTrue(pumpManager.state.basalDose !== tempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
    }

    // MARK: - Held behind a temp basal's records

    /// The patch suspends while 1.2 U/h runs - its status naming 131, the temp basal's record, read off the queue
    /// statuses arrive on - and the app is killed during the read: the state saved then has the suspend running, its
    /// report held back with the temp basal. The next run reports it after all, with the temp basal final - from 131,
    /// read on its first status, the resume that status shows held behind them: never one with no suspend before it.
    func testSuspendHeldBehindATempBasalsRecordIsReportedAfterARestartDuringTheRead() throws {
        let tempBasal = try suspendRestartingDuringTheRead()

        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        link.notify(PatchBytes.basalNotification(
            type: .STANDARD,
            sequence: 131,
            patchId: 251,
            start: Self.ourEnd.addingTimeInterval(300),
            rate: 0.7
        ))
        settle()

        let batches = delegate.batches.map { $0.events.compactMap(\.dose) }
        let suspendAt = batches.firstIndex { $0.contains { $0.type == .suspend } }
        let resumeAt = batches.firstIndex { $0.contains { $0.type == .resume } }
        XCTAssertNotNil(suspendAt, "the suspend never reached the host")
        XCTAssertNotNil(resumeAt)
        XCTAssertLessThanOrEqual(suspendAt ?? .max, resumeAt ?? -1)
        let doses = batches.joined()
        XCTAssertEqual(doses.filter { $0.type == .suspend }.count, 1)
        let suspend = doses.first { $0.type == .suspend }
        let resume = doses.first { $0.type == .resume }
        XCTAssertLessThan(suspend?.startDate ?? .distantFuture, resume?.startDate ?? .distantPast)
        let final = doses.first { $0.type == .tempBasal && $0.startDate == tempBasal.startDate }
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(delegate.batches.first?.events.compactMap(\.dose).map(\.type), [.tempBasal, .suspend, .resume], "in one batch")
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)
    }

    /// The same restart, its first batch one the host could not store: the suspend goes out again with the next, with
    /// the temp basal's final - and is done with once the host stores them
    func testSuspendHeldBehindATempBasalsRecordGoesOutAgainUntilTheHostStoresIt() throws {
        let tempBasal = try suspendRestartingDuringTheRead()

        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        pumpManager.emitPumpEvents([])
        settle()
        XCTAssertEqual(pumpManager.state.heldBasalDoses.map(\.dose.type), [.suspend], "kept: the host did not store it")

        delegate.batchReply = .acknowledge
        pumpManager.emitPumpEvents([])
        settle()

        XCTAssertEqual(delegate.batches.count, 2)
        for batch in delegate.batches {
            let doses = batch.events.compactMap(\.dose)
            XCTAssertEqual(doses.filter { $0.type == .suspend }.count, 1)
            XCTAssertEqual(doses.first { $0.startDate == tempBasal.startDate }?.isMutable, false, "with the temp basal's final")
        }
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)
        XCTAssertNil(delegate.savedState?["heldBasalDoses"])
    }

    /// The same restart, the host failing every batch for a day: what was held back after the temp basal is given up
    /// on as an unconfirmed final is - not sent with every batch for good
    func testHeldBackDosesTheHostNeverConfirmsAreGivenUpOnAsFinalsAre() throws {
        try suspendRestartingDuringTheRead()

        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        pumpManager.emitPumpEvents([])
        settle()
        XCTAssertEqual(pumpManager.state.heldBasalDoses.map(\.dose.type), [.suspend])

        advanceClock(by: MedtrumPumpManager.unconfirmedFinalMaximumAge + Self.minute)
        pumpManager.emitPumpEvents([])
        settle()

        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)
        XCTAssertFalse(delegate.batches.last?.events.contains { $0.dose?.type == .suspend } ?? true)
    }

    /// What was held back goes out again with a batch sent while the one that carried it awaits its answer - as a matter
    /// of course, not warned of. Once that one is not stored, it is.
    func testHeldBackDoseSentAgainIsWarnedOfOnlyAfterABatchTheHostCouldNotStore() {
        runTempBasalOfOurs()
        MedtrumLogger.pumpManager = pumpManager
        defer { MedtrumLogger.pumpManager = nil }
        let resent = { [unowned self] in
            delegate.logEntries.filter { $0.message.contains("Reporting again what the host has yet to confirm storing") }.count
        }

        delegate.batchReply = .hold
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        link.notify(haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131))
        settle()
        pumpManager.emitPumpEvents([])
        settle()

        XCTAssertEqual(delegate.batches.count, 2)
        XCTAssertTrue(delegate.batches.allSatisfy { $0.events.contains { $0.dose?.type == .suspend } })
        XCTAssertEqual(resent(), 0, "warned of while its batch awaited its answer")

        delegate.releaseHeldBatches(error: NSError(domain: "host", code: 1))
        settle()
        pumpManager.emitPumpEvents([])
        settle()

        XCTAssertEqual(delegate.batches.last?.events.contains { $0.dose?.type == .suspend }, true)
        XCTAssertEqual(resent(), 1)
        delegate.releaseHeldBatches()
        settle()
    }

    /// Killed during the read, restarted a day later: the temp basal's final from our estimate is fixed only now, and
    /// the suspend held back with it goes out with it - not given up on for having been held a day ago
    func testHeldBackDoseOfARestartADayAfterTheKillGoesOutWithItsTempBasalsFinal() throws {
        let tempBasal = try suspendRestartingDuringTheRead(after: MedtrumPumpManager.unconfirmedFinalMaximumAge + Self.minute)

        pumpManager.emitPumpEvents([])
        settle()

        let doses = delegate.batches.last?.events.compactMap(\.dose) ?? []
        XCTAssertEqual(doses.first { $0.startDate == tempBasal.startDate }?.isMutable, false)
        XCTAssertTrue(doses.contains { $0.type == .suspend }, "the suspend was given up on")
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty, "stored")
    }

    /// The wall clock drifts against the monotonic one - the one not frequency-corrected - half a second between each of
    /// many statuses. A status of the old temp basal received before a suspend the user set, handled after it, is still
    /// one from before the suspend: not warned of.
    func testStatusFromBeforeASuspendIsStaleWhateverTheWallClockDrift() {
        runTempBasalOfOurs()
        // The wall clock half a second further behind with each
        func deliver(_ hex: String, drift: Int, receivedAgo: TimeInterval = 0) {
            let packet = NotificationPacket()
            packet.totalData = FakeMedtrumLink.bytes(hex)
            var status = packet.parseResponse()
            status.receivedAt = status.receivedAt.addingTimeInterval(-receivedAgo - 0.5 * Double(drift))
            status.receivedUptime += uptimeOffset.value - receivedAgo
            link.onQueue {
                self.pumpManager.handleStatus(status, duringReconnect: false, fullSync: false)
            }
        }
        for drift in 0 ..< 12 {
            deliver("200001" + "8200fb00", drift: drift)
        }
        settle()

        pumpManager.state.basalDose = UnfinalizedDose(suspendStartTime: Date.now)
        pumpManager.state.basalState = .suspended
        deliver(
            PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.0),
            drift: 12,
            receivedAgo: 5
        )
        settle()

        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// The wall clock set back an hour after the scheduled basal began: a temp basal none of ours is, shown since, is
    /// still warned of - not taken for a status from before that basal, by the wall clock alone
    func testTempBasalNoneOfOursShownAfterTheWallClockWentBackIsWarnedOf() {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        state.lastSegmentStart = Self.ourStart
        state.basalDose = UnfinalizedDose(basalRate: 0.7, insulinType: nil, startDate: Date.now)
        alignPatchClock(state, patchTime: Self.ourEnd)
        makeManager(state)
        confirmRecordSequence()

        let packet = NotificationPacket()
        packet.totalData = FakeMedtrumLink.bytes(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 130,
            patchId: 251,
            start: Self.ourEnd.addingTimeInterval(-60),
            rate: 1.5
        ))
        var status = packet.parseResponse()
        status.receivedAt = status.receivedAt.addingTimeInterval(-Self.hour)
        link.onQueue {
            self.pumpManager.handleStatus(status, duringReconnect: false, fullSync: false)
        }
        settle()

        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(uncertain.first?.cause, .unknownSegment)
    }

    /// The patch splits 1.2 U/h at patch-local midnight, 10 min in, and an occlusion stops it later: its status names
    /// 133, without the time of the halt - as the patch sends it. Its first half (131) ends at midnight, with success:
    /// not where it ended, which is not known - read on, its second half (132) is the one the halt ended, and both make
    /// its final. The alarm after them is left to the sync.
    func testTempBasalSplitAtPatchMidnightAHaltEndedIsFinalizedFromBothHalvesWithNoTimeOfTheHalt() {
        let tempBasal = runTempBasalOfOurs()
        let midnight = Self.ourStart.addingTimeInterval(600)
        pumpManager.state.patchUTCOffset = 24 * Self.hour - midnight.timeIntervalSince1970.truncatingRemainder(dividingBy: 24 * Self.hour)

        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: Self.ourStart,
            end: midnight,
            rate: 1.2,
            delivered: 0.15
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: midnight,
            end: Self.ourEnd,
            rate: 1.2,
            delivered: 0.15,
            endReason: .STOP_OCCLUSION
        ))
        link.notify(haltNotification(.occlusion, at: nil, newestRecord: 133))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 132)
        let final = finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate })
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "both halves, not the first alone")
    }

    /// The state the host saves is taken in one step with what changes the doses: a save asked for while they change
    /// waits for them, and has the change whole
    func testStateIsSavedInOneStepWithWhatChangesTheDoses() {
        runTempBasalOfOurs()
        let saved = Locked<PumpManager.RawStateValue?>(nil)
        let saving = DispatchSemaphore(value: 0)

        pumpManager.withDoseReportLock {
            DispatchQueue.global().async { [unowned self] in
                saving.signal()
                saved.value = pumpManager.rawState
            }
            saving.wait()
            XCTAssertFalse(giveTime(timeout: 0.3) { saved.value != nil }, "saved while the doses changed")
            pumpManager.state.basalDose = UnfinalizedDose(suspendStartTime: Date.now)
        }

        XCTAssertTrue(giveTime { saved.value != nil })
        XCTAssertEqual(saved.value.map(MedtrumPumpState.init(rawValue:))?.basalDose.type, .suspend)
    }

    /// A status of the running temp basal received before a suspend the user just set, handled after it: the patch is
    /// suspended - commands are refused - and it is not taken for a temp basal none of ours is
    func testTempBasalStatusFromBeforeASuspendLeavesItSuspended() {
        runTempBasalOfOurs()
        pumpManager.state.basalDose = UnfinalizedDose(suspendStartTime: Date.now)
        pumpManager.state.basalState = .suspended

        notify(
            PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.2),
            receivedAgo: 5
        )

        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// The patch deactivated as 1.2 U/h runs - its temp basal final - and a late status of it after: the old patch's,
    /// its session over, not a temp basal of this one none of ours is
    func testOldPatchsTempBasalShownAfterItsSessionEndedIsNotWarnedOf() {
        runTempBasalOfOurs()
        pumpManager.forceDeactivatePatch()
        settle()
        let errors = delegate.errors.count

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.2))
        settle()

        XCTAssertEqual(delegate.errors.count, errors)
        XCTAssertFalse(uncertain.contains { $0.cause == .unknownSegment })
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
    }

    /// The patch suspends while 1.2 U/h runs - its status naming 131, the temp basal's record, read off the queue
    /// statuses arrive on - and the app is killed during the read, restarting from the state saved then. Returns the
    /// temp basal.
    @discardableResult private func suspendRestartingDuringTheRead(after downtime: TimeInterval = 0) throws -> UnfinalizedDose {
        let tempBasal = runTempBasalOfOurs()
        let savedDuringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            savedDuringRead.value = pumpManager.rawState
        }
        link.notify(haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131))
        settle()

        // The run itself: one batch, the temp basal final from its record, then the suspend - none held any longer
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .suspend])
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)
        XCTAssertNil(delegate.savedState?["heldBasalDoses"])

        // Killed during the read, restarted `downtime` later
        advanceClock(by: downtime)
        try restart(from: try XCTUnwrap(savedDuringRead.value))
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.heldBasalDoses.map(\.dose.type), [.suspend])
        return tempBasal
    }
}

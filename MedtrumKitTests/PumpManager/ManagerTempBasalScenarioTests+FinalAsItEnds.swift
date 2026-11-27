import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerTempBasalScenarioTests {
    // MARK: - Final as it ends

    /// A cancel to the schedule, the record it named timing out - one attempt: the temp basal goes out final at once from
    /// our estimate, with the schedule. The last status of its segment, 10 min before the cancel, showed 0.1 U delivered (a bolus
    /// paused it): 0.1 U + 1.2 U/h × 10 min = 0.3 U, not its rate × duration of 0.4 U.
    func testTempBasalWhoseRecordCannotBeReadIsFinalizedFromItsLastStatus() {
        let tempBasal = runTempBasalOfOurs()
        notify(
            PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.2, delivered: 0.1),
            receivedAgo: 10 * Self.minute
        )
        XCTAssertEqual(tempBasal.snapshot.statusDelivery ?? 0, 0.1, accuracy: 0.001)

        let final = cancelItUnread()
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 20 * Self.minute, accuracy: 1)
    }

    /// The same with no status of its segment: its rate × duration, 1.2 U/h × 20 min = 0.4 U
    func testTempBasalWhoseRecordCannotBeReadIsFinalizedFromItsRateAndDuration() {
        runTempBasalOfOurs()

        let final = cancelItUnread()
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
    }

    /// The record the cancel named comes back garbled: it is not asked for again - our estimate stands in, and the
    /// record is left for a sync
    func testTempBasalWhoseRecordComesBackGarbledIsFinalizedFromOurEstimateAfterOneAttempt() {
        runTempBasalOfOurs()
        scriptCancel()
        link.script(CommandType.GET_RECORD, .garbled(recordOfOurTempBasal(delivered: 0.35)))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 130)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.isMutable, false)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
    }

    /// The record the cancel named ends 5 min before the cancel says the temp basal ended: it does not add up to it -
    /// our estimate stands in, not the record's 0.25 U
    func testTempBasalWhoseRecordsDoNotAddUpIsFinalizedFromOurEstimate() {
        runTempBasalOfOurs()
        scriptCancel()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: Self.ourStart,
            end: Self.ourEnd.addingTimeInterval(-300),
            rate: 1.2,
            delivered: 0.25
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131, "read, and stored")
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 20 * Self.minute, accuracy: 1)
    }

    /// The same, the status of its segment from before patch-local midnight, which restarted what the statuses show: its
    /// rate × duration, not 0.05 U + 1.2 U/h × 15 min = 0.35 U
    func testTempBasalAcrossMidnightWhoseRecordCannotBeReadIsFinalizedFromItsRateAndDuration() {
        runTempBasalOfOurs()
        // A zone whose midnight falls 10 min into the temp basal
        pumpManager.state.patchUTCOffset = 24 * Self.hour -
            (Self.ourStart.timeIntervalSince1970 + 600).truncatingRemainder(dividingBy: 24 * Self.hour)
        notify(
            PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.2, delivered: 0.05),
            receivedAgo: 15 * Self.minute
        )

        let final = cancelItUnread()
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
    }

    /// Expiry: 0.5 U/h ran its 30 min, and the patch shows the scheduled basal from then on, naming record 131 - read
    /// off the queue notifications arrive on. The temp basal goes out final from it, with the scheduled basal.
    func testExpiredTempBasalIsFinalizedFromTheRecordTheScheduledBasalNames() {
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
        link.notify(PatchBytes.basalNotification(
            type: .STANDARD,
            sequence: 131,
            patchId: 251,
            start: Self.ourStart.addingTimeInterval(1800),
            rate: 0.7
        ))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)

        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.startDate, tempBasal.startDate)
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 1800, accuracy: 0.001)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.2, accuracy: 0.001, "the record's, not 0.25 U by rate × duration")
        XCTAssertEqual(reports(of: .tempBasal).count, 1, "never mutable")
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized temp basal"), true)
    }

    /// A 2 U bolus (`user.txt:11229-11295`, record 123) during 1.2 U/h, which the patch paused for it: the cancel names
    /// 124, and 123 - the bolus - and 124 are read in the command. The temp basal is final at 0.3 U, its record's, not
    /// 0.4 U by its rate × duration; the bolus is final from its own record, as ever.
    func testTempBasalABolusPausedIsFinalizedWithWhatItsRecordSays() throws {
        let tempBasal = runTempBasalOfOurs(patchId: 236, sequence: 122)

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        link.notify("202211802800040d7b00ec000000000000")
        settle()
        let bolus = try XCTUnwrap(reports(of: .bolus).first)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 1)

        scriptCancelAndSet(patchId: 236, cancelRecord: 124)
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: Date.fromMedtrumSeconds(0x17A8_8697), amount: 2, delivered: 2)
        )
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(patchId: 236, sequence: 124, delivered: 0.3))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands.suffix(4), [
            CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD, CommandType.GET_RECORD
        ])
        // Ended back to back: reported mutable first, ended where the new one starts
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.startDate == tempBasal.startDate && $0.isMutable && $0.endDate < tempBasal.estimatedEndDate })
        // Its one final - sent again with the bolus's if the host had yet to confirm it
        let ended = reports(of: .tempBasal).filter { $0.startDate == tempBasal.startDate && !$0.isMutable }
        XCTAssertFalse(ended.isEmpty)
        XCTAssertTrue(ended.allSatisfy { $0.deliveredUnits == ended.first?.deliveredUnits && $0.endDate == ended.first?.endDate })
        XCTAssertEqual(ended.first?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        // Ending where the new one starts: the time the bolus took here, on our clock, with it
        XCTAssertEqual(ended.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 20 * Self.minute, accuracy: 5)

        assertOneFinal(of: bolus)
        XCTAssertEqual(finals(of: bolus).first?.deliveredUnits ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 124)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0)
    }

    /// 2026-08-02 08:22:41 (`user.txt:28394-28402`): the cancel's scheduled basal, shown while the set awaits its answer,
    /// is the cancel's own: the command reports what follows the temp basal it cancels. Nothing comes between the two -
    /// no scheduled basal, which would cut the old one off a second early - the old one ends open where the new one
    /// starts, and its record makes its final once the command is over.
    func testCancelsSegmentShownWhileTheSetAwaitsItsAnswerPutsNothingBetweenTheTwo() throws {
        let tempBasal = runTempBasalOfOurs()

        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer())
        link.script(CommandType.SET_TEMP_BASAL, .fragments(setAnswer()), thenNotify: [
            scheduledBasalRunning(),
            "200001" + "8400fb00"
        ])
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertTrue(reports(of: .basal).isEmpty, "no scheduled basal between the two")
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .tempBasal])
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(old.endDate, pumpManager.state.basalDose.startDate)
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
    }

    /// A cancel to the schedule, a batch going out while the record it named is read - a heartbeat's full status, say:
    /// that batch carries the old temp basal final, from our estimate, with the schedule. The record then changes nothing.
    func testScheduleNeverGoesOutBeforeTheOldOnesFinalWithABatchWhileItsRecordIsRead() throws {
        let tempBasal = runTempBasalOfOurs()

        scriptCancel()
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            pumpManager.emitPumpEvents([])
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate: the batch went out first")
        assertOneFinal(of: old)
        assertScheduledBasalNeverBeforeTheFinal(of: old)
        XCTAssertNotEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized"), true)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
    }

    /// 2026-10-14 18:21:56 (log 15, patch 270): a heartbeat's full status, its Synchronize on the link ahead of the
    /// record a cancel to the schedule named, arrives while the command reads it. It shows nothing new - the schedule
    /// running - so it hands the host nothing: the old temp basal goes out final from its record, with the schedule, in
    /// one batch. The status itself is taken. (A temp basal ended back to back holds up no batch: see
    /// `ManagerTempBasalBackToBackScenarioTests`.)
    func testFullStatusShowingNothingNewWhileItsRecordIsReadLeavesTheOldTempBasalToItsRecord() throws {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)

        scriptCancel()
        let batchesDuringRead = Locked<Int?>(nil)
        let syncedByStatus = Locked<Date?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            // Stale, whatever the command's answers made it: only the status moves it now
            pumpManager.state.lastSync = .distantPast
            link.deliverFullStatus(notification: scheduledBasalRunning(), duringReconnect: false)
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
            syncedByStatus.value = pumpManager.state.lastSync
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(batchesDuringRead.value, 0, "the status handed the host a batch during the read")
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.7])
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        assertOneFinal(of: old)
        assertScheduledBasalNeverBeforeTheFinal(of: old)
        XCTAssertEqual(delegate.batches.first?.events.last?.dose?.type, .basal)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        XCTAssertNotEqual(syncedByStatus.value, .distantPast, "the status was not taken")
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
    }

    /// The same full status, the record the cancel named timing out: our estimate stands in - once, with the schedule
    /// after it, from the read's own batch
    func testFullStatusShowingNothingNewWhileItsRecordTimesOutLeavesTheOldTempBasalToTheReadsEstimate() throws {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)

        scriptCancel()
        let batchesDuringRead = Locked<Int?>(nil)
        link.script(CommandType.GET_RECORD, .timeout) { [unowned self] in
            link.deliverFullStatus(notification: scheduledBasalRunning(), duringReconnect: false)
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(batchesDuringRead.value, 0, "the status handed the host a batch during the read")
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.7])
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        assertOneFinal(of: old)
        assertScheduledBasalNeverBeforeTheFinal(of: old)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
    }

    /// A batch with events of its own still goes out while the record is read - our estimate standing in for the old
    /// temp basal, ahead of them: only an empty refresh waits
    func testBatchWithEventsWhileItsRecordIsReadStillGoesOut() throws {
        let tempBasal = runTempBasalOfOurs()
        let own = NewPumpEvent.replacedPump()

        scriptCancel()
        let batchesDuringRead = Locked<Int?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            pumpManager.emitPumpEvents([own], unlessTempBasalEndPending: true)
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(batchesDuringRead.value, 1)
        XCTAssertEqual(delegate.batches.first?.events.contains { $0.raw == own.raw }, true)
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate: the batch went out first")
        assertOneFinal(of: old)
        assertScheduledBasalNeverBeforeTheFinal(of: old)
    }

    /// Finals the host has yet to confirm, due to go out again while the record is read - the loop's
    /// `ensureCurrentPumpData`, or a record sync starting: the resend waits for the read's batch, which carries them, with
    /// the old temp basal final from its record
    func testResendOfUnconfirmedFinalsWhileItsRecordIsReadWaitsForTheReadsBatch() throws {
        let tempBasal = runTempBasalOfOurs()
        let bolus = UnfinalizedDose(
            units: 1,
            duration: 40,
            activationType: .manualNoRecommendation,
            insulinType: nil,
            startDate: Date.now.addingTimeInterval(-10 * Self.minute)
        )
        bolus.finish(.completed, deliveredUnits: 1, endedAt: bolus.estimatedEndDate)
        bolus.finalize(deliveredUnits: 1)
        pumpManager.state.mutateAwaitingRecord { $0.append(bolus) }

        scriptCancel()
        let batchesDuringRead = Locked<Int?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            pumpManager.resendUnacknowledgedFinalsIfDue()
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(batchesDuringRead.value, 0, "the resend handed the host a batch during the read")
        XCTAssertEqual(delegate.batches.count, 1)
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        assertScheduledBasalNeverBeforeTheFinal(of: old)
        let bolusFinals = reports(of: .bolus).filter { $0.startDate == bolus.startDate && !$0.isMutable }
        XCTAssertEqual(bolusFinals.count, 1, "the read's batch carries the unconfirmed final")
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0, "stored")
    }

    /// The completion after a bolus cancel, raising it while the record is read: the raised bolus goes out with the
    /// read's batch, the old temp basal final from its record
    func testCancelledBolusRaisedWhileItsRecordIsReadGoesOutWithTheReadsBatch() throws {
        let tempBasal = runTempBasalOfOurs()
        let bolus = UnfinalizedDose(
            units: 1,
            duration: 40,
            activationType: .manualNoRecommendation,
            insulinType: nil,
            startDate: Date.now.addingTimeInterval(-30)
        )
        bolus.finish(.cancelled, deliveredUnits: 0.1, endedAt: Date.now.addingTimeInterval(-10))
        pumpManager.state.mutateAwaitingRecord { $0.append(bolus) }

        scriptCancel()
        let batchesDuringRead = Locked<Int?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            pumpManager.raiseCancelledBolus(delivered: 0.3)
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(bolus.deliveredUnits, 0.3, accuracy: 0.001, "raised")
        XCTAssertEqual(batchesDuringRead.value, 0, "the raise handed the host a batch during the read")
        XCTAssertEqual(delegate.batches.count, 1)
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        assertScheduledBasalNeverBeforeTheFinal(of: old)
        XCTAssertEqual(reports(of: .bolus).filter { $0.startDate == bolus.startDate }.count, 1, "the read's batch carries it")
    }

    /// While the records are read, a heartbeat asks for no full status - its Synchronize would go out on the link
    /// ahead of them - nor for records; once they are, it does again
    func testHeartbeatSyncsNothingWhileTheRecordIsRead() {
        runTempBasalOfOurs()
        pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
        XCTAssertEqual(pumpManager.heartbeatSync(), .full)

        scriptCancel()
        let duringRead = Locked<MedtrumPumpManager.HeartbeatSync??>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            // Stale, whatever the command's answers made it
            pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
            duringRead.value = .some(pumpManager.heartbeatSync())
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(duringRead.value, .some(nil), "a sync during the read")
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
        XCTAssertEqual(pumpManager.heartbeatSync(), .full)
    }

    /// The loop's or the heartbeat's Synchronize, asked for while the command reads the record the cancel named, waits
    /// for the read: it would go out ahead of the record, eating into its budget
    func testStatusAskedForDuringTheReadWaitsForIt() throws {
        let tempBasal = runTempBasalOfOurs()

        scriptCancel()
        link.script(CommandType.SYNCHRONIZE, .timeout)
        let synced = expectation(description: "Synchronize")
        let syncDuringRead = Locked(false)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            DispatchQueue.global().async {
                _ = self.pumpManager.betweenCommands { self.link.write(SynchronizePacket()) }
                synced.fulfill()
            }
            syncDuringRead.value = giveTime(timeout: 0.5) { self.link.writtenCommands.contains(CommandType.SYNCHRONIZE) }
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        wait(for: [synced], timeout: 5)
        settle()

        XCTAssertFalse(syncDuringRead.value, "the Synchronize went out while the record was read")
        XCTAssertEqual(
            link.writtenCommands,
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SYNCHRONIZE]
        )
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
    }

    /// The patch time, stale, fetched while the command reads the record the cancel named: the same
    func testPatchTimeFetchedDuringTheReadWaitsForIt() throws {
        let tempBasal = runTempBasalOfOurs()

        scriptCancel()
        link.script(CommandType.GET_TIME, .timeout)
        let fetched = expectation(description: "GetTime")
        let fetchDuringRead = Locked(false)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            pumpManager.state.pumpTimeSyncedAt = .distantPast
            DispatchQueue.global().async {
                StateSyncer.fetchPatchTimeIfStale(pumpManager: self.pumpManager)
                fetched.fulfill()
            }
            fetchDuringRead.value = giveTime(timeout: 0.5) { self.link.writtenCommands.contains(CommandType.GET_TIME) }
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        wait(for: [fetched], timeout: 5)
        settle()

        XCTAssertFalse(fetchDuringRead.value, "the patch time was asked for while the record was read")
        XCTAssertEqual(
            link.writtenCommands,
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.GET_TIME]
        )
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
    }

    /// A temp basal a status ended - the connect flow's, its records read off the queue statuses arrive on - and a
    /// second full status, showing nothing new, while they are read: it hands the host nothing, the temp basal goes
    /// out final from its record, with the scheduled basal after it, in one batch. The status itself is taken.
    func testSecondFullStatusWhileTheRecordsOfATempBasalAStatusEndedAreReadLeavesItToItsRecord() {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        let tempBasal = runningTempBasal(rate: 0.5, startedAgo: 30 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.ourStart)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.ourStart.addingTimeInterval(1800))
        makeManager(state)

        let scheduledRunning = PatchBytes.basalNotification(
            type: .STANDARD,
            sequence: 131,
            patchId: 251,
            start: Self.ourStart.addingTimeInterval(1800),
            rate: 0.7
        )
        let batchesDuringRead = Locked<Int?>(nil)
        let syncedByStatus = Locked<Date?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.basalRecord(
            sequence: 131,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: Self.ourStart,
            end: Self.ourStart.addingTimeInterval(1800),
            rate: 0.5,
            delivered: 0.2
        ))) { [unowned self] in
            // Stale, whatever the first status made it: only the second moves it now
            pumpManager.state.lastSync = .distantPast
            link.deliverFullStatus(notification: scheduledRunning, duringReconnect: false)
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
            syncedByStatus.value = pumpManager.state.lastSync
        }
        link.deliverFullStatus(notification: scheduledRunning, duringReconnect: true)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD])
        XCTAssertEqual(batchesDuringRead.value, 0, "the second status handed the host a batch during the read")
        XCTAssertNotEqual(syncedByStatus.value, .distantPast, "the second status was not taken")
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.startDate, tempBasal.startDate)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.2, accuracy: 0.001, "the record's, not 0.25 U by rate × duration")
        XCTAssertEqual(reports(of: .tempBasal).count, 1)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
    }

    /// The cancel of our temp basal unanswered: counted as running until a full status shows whether it stopped - here
    /// it did not. Shown so, then settled by its record as it ends.
    func testUnansweredCancelIsShownUncertainUntilTheTempBasalsRecordSettlesIt() throws {
        let tempBasal = runTempBasalOfOurs()

        link.script(CommandType.CANCEL_TEMP_BASAL, .timeout)
        guard case .uncertainDelivery? = commandTempBasal(0.5, duration: 30 * Self.minute) else {
            XCTFail("Not uncertain")
            return
        }
        settle()
        XCTAssertEqual(uncertain.map(\.kind), [.tempBasalCancel])
        XCTAssertEqual(uncertain.first?.phase, .countedRunning)

        link.deliverFullStatus(
            notification: PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.2),
            duringReconnect: false
        )
        settle()
        XCTAssertEqual(uncertain.first?.phase, .stillRunning)

        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(uncertain.map(\.phase), [.settled(.byRecord)])
        XCTAssertEqual(uncertain.first?.delivered ?? 0, 0.35, accuracy: 0.001)
    }

    /// The same unanswered cancel, then a cancel answered whose record cannot be read: final from our estimate - shown
    /// so, not as settled by its record
    func testUnansweredCancelOfATempBasalFinalizedFromOurEstimateIsShownSo() throws {
        runTempBasalOfOurs()

        link.script(CommandType.CANCEL_TEMP_BASAL, .timeout)
        guard case .uncertainDelivery? = commandTempBasal(0, duration: 0) else {
            XCTFail("Not uncertain")
            return
        }
        settle()

        scriptCancel()
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(uncertain.map(\.phase), [.settled(.byEstimate)])
        XCTAssertEqual(uncertain.first?.delivered ?? 0, 0.4, accuracy: 0.001, "our estimate")
        // No status showed it still running
        let delivery = try XCTUnwrap(pumpManager.state.uncertainDeliveries.first)
        XCTAssertFalse(delivery.cancelDidNotStop)
        let status = settingsNotice(for: delivery).status
        XCTAssertFalse(status.contains("The cancel did not stop it"), status)
    }

    /// The same, a full status showing the temp basal still running after the cancel, then its record: the settled
    /// note keeps saying the cancel did not stop it - saved and read back too
    func testSettledCancelThatDidNotStopItsTempBasalKeepsSayingSo() throws {
        runTempBasalOfOurs()

        link.script(CommandType.CANCEL_TEMP_BASAL, .timeout)
        guard case .uncertainDelivery? = commandTempBasal(0.5, duration: 30 * Self.minute) else {
            XCTFail("Not uncertain")
            return
        }
        settle()
        link.deliverFullStatus(
            notification: PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.2),
            duringReconnect: false
        )
        settle()
        XCTAssertEqual(pumpManager.state.uncertainDeliveries.first?.cancelDidNotStop, true, "shown still running")

        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let delivery = try XCTUnwrap(pumpManager.state.uncertainDeliveries.first)
        XCTAssertEqual(pumpManager.state.phase(of: delivery), .settled(.byRecord))
        XCTAssertTrue(delivery.cancelDidNotStop)
        let status = settingsNotice(for: delivery).status
        XCTAssertTrue(status.hasPrefix("The cancel did not stop it: the patch kept running it. "), status)
        XCTAssertTrue(status.contains("Settled by the patch's records"), status)

        let data = try PropertyListSerialization.data(fromPropertyList: pumpManager.state.rawValue, format: .binary, options: 0)
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(MedtrumPumpState(rawValue: saved).uncertainDeliveries.first?.cancelDidNotStop, true)

        // Its day counted on the manager's clock, which settled it
        advanceClock(by: 23 * Self.hour)
        XCTAssertEqual(pumpManager.state.uncertainDeliveries.count, 1)
        advanceClock(by: 2 * Self.hour)
        XCTAssertTrue(pumpManager.state.uncertainDeliveries.isEmpty)
    }

    /// A cancel unanswered, a status showing the temp basal still running, then a second cancel unanswered: the one
    /// note forgets the first cancel's, and its record settles it with no word of a cancel that did not stop it
    func testSecondUnansweredCancelClearsWhatTheFirstOneShowed() throws {
        let status = try settledStatusAfterTwoUnansweredCancels(shownRunningAfterTheSecond: false)
        XCTAssertFalse(status.contains("The cancel did not stop it"), status)
    }

    /// The same, a status showing it still running after the second cancel too: said again, of that one
    func testSecondUnansweredCancelShownNotToStopItIsSaidSo() throws {
        let status = try settledStatusAfterTwoUnansweredCancels(shownRunningAfterTheSecond: true)
        XCTAssertTrue(status.hasPrefix("The cancel did not stop it: the patch kept running it. "), status)
    }

    /// What the settings screen says of the one cancel note once its temp basal's record settled it
    private func settledStatusAfterTwoUnansweredCancels(shownRunningAfterTheSecond: Bool) throws -> String {
        runTempBasalOfOurs()
        let stillRunning = PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.2)

        link.script(CommandType.CANCEL_TEMP_BASAL, .timeout)
        guard case .uncertainDelivery? = commandTempBasal(0.5, duration: 30 * Self.minute) else {
            XCTFail("Not uncertain")
            return ""
        }
        settle()
        link.deliverFullStatus(notification: stillRunning, duringReconnect: false)
        settle()
        XCTAssertEqual(pumpManager.state.uncertainDeliveries.first?.cancelDidNotStop, true, "shown still running")

        link.script(CommandType.CANCEL_TEMP_BASAL, .timeout)
        guard case .uncertainDelivery? = commandTempBasal(0.5, duration: 30 * Self.minute) else {
            XCTFail("Second not uncertain")
            return ""
        }
        settle()
        XCTAssertEqual(uncertain.map(\.kind), [.tempBasalCancel], "one note of the dose")
        XCTAssertEqual(uncertain.first?.phase, .countedRunning)
        XCTAssertEqual(pumpManager.state.uncertainDeliveries.first?.cancelDidNotStop, false, "the second cancel's not known")

        if shownRunningAfterTheSecond {
            link.deliverFullStatus(notification: stillRunning, duringReconnect: false)
            settle()
            XCTAssertEqual(pumpManager.state.uncertainDeliveries.first?.cancelDidNotStop, true, "shown still running again")
        }

        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let delivery = try XCTUnwrap(pumpManager.state.uncertainDeliveries.first)
        XCTAssertEqual(pumpManager.state.phase(of: delivery), .settled(.byRecord))
        XCTAssertEqual(delivery.cancelDidNotStop, shownRunningAfterTheSecond)
        return settingsNotice(for: delivery).status
    }

    /// Shown still running, then ended, waiting on its record: it still says the cancel did not stop it
    func testCancelThatDidNotStopItsTempBasalSaysSoWhileItsRecordIsAwaited() {
        var delivery = UncertainDelivery(
            kind: .tempBasalCancel,
            cause: .unanswered,
            sentAt: Self.ourStart,
            amount: 1.2,
            duration: 30 * Self.minute,
            notedAt: Self.ourStart.addingTimeInterval(10 * Self.minute)
        )
        delivery.cancelDidNotStop = true
        let viewModel = MedtrumKitSettingsViewModel(nil, {}, { _ in }, {}, {}, {}, {}, {}, {}, {}, {})

        let awaiting = viewModel.notice(for: delivery, phase: .awaitingRecord).status
        XCTAssertTrue(awaiting.hasPrefix("The cancel did not stop it: the patch kept running it. "), awaiting)
        XCTAssertTrue(awaiting.contains("Final once its record is read."), awaiting)

        let running = viewModel.notice(for: delivery, phase: .stillRunning).status
        XCTAssertFalse(running.contains("The cancel did not stop it: the patch kept running it."), "said once: \(running)")
    }

    /// A note saved by a build that did not keep whether a cancel stopped its temp basal reads back as not shown so
    func testUncertainDeliverySavedWithoutTheCancelFlagReadsBack() throws {
        var delivery = UncertainDelivery(
            kind: .tempBasalCancel,
            cause: .unanswered,
            sentAt: Self.ourStart,
            amount: 1.2,
            duration: 30 * Self.minute,
            notedAt: Self.ourStart.addingTimeInterval(10 * Self.minute)
        )
        XCTAssertNil(delivery.rawValue["cancelDidNotStop"])
        delivery.cancelDidNotStop = true
        XCTAssertEqual(UncertainDelivery(rawValue: delivery.rawValue), delivery)

        var raw = delivery.rawValue
        raw["cancelDidNotStop"] = nil
        let old = try XCTUnwrap(UncertainDelivery(rawValue: raw))
        XCTAssertFalse(old.cancelDidNotStop)
        XCTAssertEqual(old.kind, .tempBasalCancel)
        XCTAssertEqual(old.sentAt, Self.ourStart)
    }

    /// Settled notes drop out a day after they were settled - as they are read, and from the state saved. Never one
    /// not settled, however old.
    func testSettledUncertainDeliveriesDropOutADayAfterTheyWereSettled() throws {
        let now = Date.now
        func note(_ index: Int, settledAgo: TimeInterval?) -> UncertainDelivery {
            let sentAt = now.addingTimeInterval(-30 * Self.hour + TimeInterval(index))
            var delivery = UncertainDelivery(kind: .tempBasalCancel, cause: .unanswered, sentAt: sentAt, amount: 0, notedAt: sentAt)
            if let settledAgo {
                delivery.outcome = .byRecord
                delivery.delivered = 0
                delivery.settledAt = now.addingTimeInterval(-settledAgo)
            }
            return delivery
        }
        let old = note(0, settledAgo: 25 * Self.hour)
        let recent = note(1, settledAgo: 23 * Self.hour)
        let unsettled = note(2, settledAgo: nil)

        XCTAssertEqual(UncertainDelivery.kept([old, recent, unsettled], at: now), [recent, unsettled])
        XCTAssertEqual(UncertainDelivery.kept([recent, unsettled], at: now.addingTimeInterval(2 * Self.hour)), [unsettled])

        // Settled with no time of it: counted from when it was noted
        var undated = note(3, settledAgo: Self.hour)
        undated.settledAt = nil
        XCTAssertEqual(UncertainDelivery.kept([undated], at: undated.notedAt.addingTimeInterval(23 * Self.hour)), [undated])
        XCTAssertEqual(UncertainDelivery.kept([undated], at: undated.notedAt.addingTimeInterval(25 * Self.hour)), [])

        let state = MedtrumPumpState(nil)
        state.mutateUncertainDeliveries { $0 = [old, recent, unsettled] }
        XCTAssertEqual(state.uncertainDeliveries, [recent, unsettled])
        let saved = try XCTUnwrap(state.rawValue["uncertainDeliveries"] as? [UncertainDelivery.RawValue])
        XCTAssertEqual(saved.compactMap(UncertainDelivery.init(rawValue:)), [recent, unsettled])
    }

    /// The record of a temp basal that is final, read again - the cursor saved before it moved past it - by a sync:
    /// nothing changes
    func testTempBasalsRecordReadAgainChangesNothing() throws {
        let tempBasal = runTempBasalOfOurs()
        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        let batches = delegate.batches.count

        // 131 again, and 132 - the second of scheduled basal between the cancel and the set
        pumpManager.state.syncedSequenceNumber = 130
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 132,
            patchId: 251,
            type: .STANDARD,
            start: Self.ourEnd,
            end: Self.ourEnd.addingTimeInterval(1),
            rate: 0.7,
            delivered: 0
        ))
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 132)
        assertOneFinal(of: old)
        XCTAssertEqual(delegate.batches.count, batches)
        XCTAssertNotEqual(pumpManager.recordStore.records.first { $0.id == 131 }?.outcome?.hasPrefix("finalized"), true)
    }

    // MARK: - Across patch-local midnight

    /// `testTempBasalAcrossPatchMidnightIsFinalizedFromBothItsRecords` as it goes on a device: the loop's own sync reads
    /// three records before the loop sets anything - 946, the first half, which is kept on the running temp basal, 947
    /// and 948. The cancel then names 949, the only one read in the command: both halves make the final.
    func testTempBasalAcrossPatchMidnightWhoseFirstHalfALoopSyncReadIsFinalizedFromBothHalves() {
        let tempBasal = runTempBasalAcrossPatchMidnight()

        for fragments in Self.recordsAcrossMidnight.prefix(3) {
            link.script(CommandType.GET_RECORD, .fragments(fragments))
        }
        syncRecords(.loopSync)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 948)
        XCTAssertEqual(pumpManager.state.basalDose.snapshot.recordedParts.map(\.sequence), [946])
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 946 }?.outcome?.hasPrefix("part of running temp basal"), true)
        XCTAssertEqual(delegate.batches.count, 0)
        XCTAssertEqual(
            MedtrumPumpState(rawValue: pumpManager.state.rawValue).basalDose.snapshot.recordedParts,
            pumpManager.state.basalDose.snapshot.recordedParts,
            "saved with the state"
        )

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121967000000010e00b503ec00ae13ab17b500")
        link.script(CommandType.GET_RECORD, .fragments(Self.recordsAcrossMidnight[3]))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands.suffix(2), [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 949)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 949 }?.outcome?.hasPrefix("finalized temp basal"), true)

        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.startDate, tempBasal.startDate)
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 897, accuracy: 1)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        assertOneFinal(of: final)
    }

    /// The same, the second half not starting where the first one kept ended: the parts do not add up - our estimate
    func testTempBasalAcrossPatchMidnightWhoseHalvesDoNotMeetIsFinalizedFromOurEstimate() {
        let tempBasal = runTempBasalAcrossPatchMidnight()

        for fragments in Self.recordsAcrossMidnight.prefix(3) {
            link.script(CommandType.GET_RECORD, .fragments(fragments))
        }
        syncRecords(.loopSync)
        XCTAssertEqual(pumpManager.state.basalDose.snapshot.recordedParts.map(\.sequence), [946])

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121967000000010e00b503ec00ae13ab17b500")
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 949,
            patchId: 236,
            type: .ABSOLUTE_TEMP,
            start: Self.patchTime(397_087_200 + 60),
            end: Self.patchTime(397_087_662),
            rate: 0.6,
            delivered: 0.05
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 949)
        XCTAssertNotEqual(pumpManager.recordStore.records.first { $0.id == 949 }?.outcome?.hasPrefix("finalized"), true)
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.startDate, tempBasal.startDate)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.15, accuracy: 0.001, "its rate × duration: 0.6 U/h × 897 s")
    }

    // MARK: - Read as it ends, over a slow link

    /// 2026-10-18 05:55 (`logs1018/today.txt:9166`, patch 271): an occlusion while 1.2 U/h runs, its status - the
    /// state and the newest record only, 133, no time of the halt, as the patch sends it - after the temp basal's own
    /// record (131, ended by the occlusion) and two alarms. Its own read, ended by the halt, it is settled: the alarms
    /// are left to the sync, and do not run the read out of time before the final is made.
    func testTempBasalAnOcclusionEndedIsSettledByItsOwnRecordLeavingTheRecordsAfterItToTheSync() {
        let tempBasal = runTempBasalOfOurs()
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35, endReason: .STOP_OCCLUSION))
        link.notify(haltNotification(.occlusion, at: nil, newestRecord: 133))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
        let final = finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate })
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)

        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 132, patchId: 251))
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 133, patchId: 251))
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 133)
        assertOneFinal(of: final.first)
    }

    /// The patch split 1.2 U/h at patch-local midnight, 10 min in: the cancel names 132, its second half, and each record
    /// takes 9 s to come back on a slow link. Both are read - the budget is two records' worth - and make its final.
    func testTempBasalSplitAtPatchMidnightIsFinalizedFromBothHalvesOverASlowLink() {
        let tempBasal = runTempBasalOfOurs()
        let midnight = Self.ourStart.addingTimeInterval(600)
        pumpManager.state.patchUTCOffset = 24 * Self.hour - midnight.timeIntervalSince1970.truncatingRemainder(dividingBy: 24 * Self.hour)

        scriptCancel(cancelRecord: 132)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.basalRecord(
            sequence: 131,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: Self.ourStart,
            end: midnight,
            rate: 1.2,
            delivered: 0.15
        ))) { [unowned self] in
            advanceClock(by: 9)
        }
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.basalRecord(
            sequence: 132,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: midnight,
            end: Self.ourEnd,
            rate: 1.2,
            delivered: 0.15
        ))) { [unowned self] in
            advanceClock(by: 9)
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(
            link.writtenCommands,
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.GET_RECORD]
        )
        XCTAssertLessThanOrEqual(link.writes.last?.timeout ?? .infinity, MedtrumPumpManager.tempBasalEndRecordTimeout)
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.startDate, tempBasal.startDate)
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "from both halves, not 0.4 U by rate × duration")
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 20 * Self.minute, accuracy: 1)
    }
}

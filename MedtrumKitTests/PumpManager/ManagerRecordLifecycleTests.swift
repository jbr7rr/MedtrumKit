import LoopKit
@testable import MedtrumKit
import XCTest

/// What happens to a dose between its end and the host storing its final: a restart, a host that fails to store a
/// batch, the batches that replace what the host holds, the saved state, and how records are read.
final class ManagerRecordLifecycleTests: MedtrumManagerTestCase {
    private struct HostError: Error {}

    // `user.txt:11229-11295` - see `ManagerBolusScenarioTests`
    private static let setBolusAnswer = "0f13280000007b00ec009786a8178900"
    private static let completion = "202211802800040d7b00ec000000000000"
    private static let bolusStart = Date.fromMedtrumSeconds(0x17A8_8697)

    /// A 2 U bolus answered with record 123, and completed
    @discardableResult private func completeBolus(_ state: MedtrumPumpState) -> DoseEntry? {
        makeManager(state)
        link.script(CommandType.SET_BOLUS, fragments: Self.setBolusAnswer)
        XCTAssertNil(commandBolus(2.0))
        link.notify(Self.completion)
        settle()
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 1)
        return delegate.batches.first?.events.first?.dose
    }

    private func roundTripped(_ raw: [String: Any]) throws -> [String: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Killed while the bolus waits on its record: the saved state brings it back waiting, and its record finalizes it
    /// once - read again, it finalizes nothing
    func testDoseAwaitingItsRecordIsFinalizedOnceAfterARestart() throws {
        let started = completeBolus(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))

        let saved = try roundTripped(pumpManager.state.rawValue)
        makeManager(MedtrumPumpState(rawValue: saved))

        let waiting = pumpManager.state.awaitingRecord
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting.first?.recordSequence, 123)
        XCTAssertEqual(waiting.first?.finishReason, .completed)
        XCTAssertEqual(waiting.first?.deliveredUnits ?? 0, 2.0, accuracy: 0.001)
        XCTAssertFalse(waiting.first?.isFinalized ?? true)
        XCTAssertNil(pumpManager.state.bolusDose)

        let record = PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: Self.bolusStart, amount: 2, delivered: 1.95)
        link.script(CommandType.GET_RECORD, .fragments(record))
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(finals(of: started).last?.deliveredUnits ?? 0, 1.95, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0)

        // Read again - the cursor saved before it moved past the record
        pumpManager.state.syncedSequenceNumber = 122
        link.script(CommandType.GET_RECORD, .fragments(record))
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome, "answered bolus finalized already")
    }

    /// The host fails to store the batch with the final: it goes out again with the next batch, the same final, until
    /// one is stored - then never again
    func testFinalGoesOutAgainUntilTheHostStoresIt() throws {
        let started = completeBolus(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))

        delegate.batchReply = .fail(HostError())
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: Self.bolusStart, amount: 2, delivered: 2)
        )
        syncRecords()

        XCTAssertEqual(finals(of: started).count, 1)
        XCTAssertEqual(pumpManager.state.awaitingRecord.map(\.isFinalized), [true], "kept until the host stores it")

        // Any batch carries it - here a full status's
        delegate.batchReply = .acknowledge
        let fullStatus = [
            "2f034401000020ee0d80010080000006a803ec2a",
            "2f03440200f607ab17193000e0052b33a817c5a8",
            "2f0344033b59a903ec00b5d602001905735c"
        ]
        link.deliverFullStatus(fullStatus)
        settle()

        let sent = finals(of: started)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.endDate, sent.last?.endDate)
        XCTAssertEqual(sent.first?.deliveredUnits, sent.last?.deliveredUnits)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0, "stored")

        link.deliverFullStatus(fullStatus)
        settle()
        XCTAssertEqual(finals(of: started).count, 2)
    }

    /// A batch replacing what the host holds carries everything still in flight: the running bolus and temp basal,
    /// and a final the host has not stored yet - and a temp basal saved waiting on its record by an earlier build,
    /// final now from our estimate
    func testReplacingBatchCarriesEverythingInFlight() throws {
        let start = Date.now.addingTimeInterval(-20 * Self.minute)
        var raw = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75.35).rawValue

        var waitingTempBasal = runningTempBasal(rate: 0.8, startedAgo: 20 * Self.minute, duration: 30 * Self.minute).rawValue
        waitingTempBasal["finishReason"] = "cancelled"
        waitingTempBasal["finishedAt"] = start.addingTimeInterval(5 * Self.minute)
        waitingTempBasal["observedEndDate"] = start.addingTimeInterval(5 * Self.minute)

        let finalBolus: [String: Any] = [
            "type": DoseType.bolus.rawValue,
            "value": 1.0,
            "startDate": start.addingTimeInterval(Self.minute),
            "estimatedEndDate": start.addingTimeInterval(2 * Self.minute),
            "deliveredUnits": 1.0,
            "automatic": false,
            "finishReason": "completed",
            "finishedAt": start.addingTimeInterval(2 * Self.minute),
            "observedEndDate": start.addingTimeInterval(2 * Self.minute),
            "finalDeliveredUnits": 0.95,
            "finalEndDate": start.addingTimeInterval(2 * Self.minute),
            "finalizedAt": start.addingTimeInterval(10 * Self.minute)
        ]
        raw["awaitingRecord"] = [waitingTempBasal, finalBolus]

        let tempBasal = runningTempBasal(
            rate: 1.25,
            startedAgo: 3,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_084_662)
        )
        raw["basalDose"] = tempBasal.rawValue
        raw["basalState"] = BasalState.tempBasal.rawValue
        makeManager(MedtrumPumpState(rawValue: try roundTripped(raw)))

        delegate.batchReply = .fail(HostError())
        link.script(CommandType.SET_BOLUS, fragments: "0f1343000000a903ec00f907ab17b300")
        XCTAssertNil(commandBolus(0.05))
        delegate.batchReply = .acknowledge

        link.deliverFullStatus([
            "2f034401000020ee0d80010080000006a803ec2a",
            "2f03440200f607ab17193000e0052b33a817c5a8",
            "2f0344033b59a903ec00b5d602001905735c"
        ])
        settle()

        let batch = delegate.batches.last
        XCTAssertEqual(batch?.replacePendingEvents, true)
        let doses = batch?.events.compactMap(\.dose) ?? []
        XCTAssertEqual(doses.count, 4)

        let runningBolus = doses.first { $0.type == .bolus && $0.isMutable }
        XCTAssertEqual(runningBolus?.programmedUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertNil(runningBolus?.deliveredUnits)

        let runningTempBasal = doses.first { $0.type == .tempBasal && $0.startDate == tempBasal.startDate }
        XCTAssertEqual(runningTempBasal?.isMutable, true)

        let waiting = doses.first { $0.type == .tempBasal && $0.unitsPerHour == 0.8 }
        XCTAssertEqual(waiting?.isMutable, false)
        XCTAssertEqual(waiting?.endDate, start.addingTimeInterval(5 * Self.minute))
        // 0.8 U/h for 5 min, by rate × duration
        XCTAssertEqual(waiting?.deliveredUnits ?? 0, 0.05, accuracy: 0.001)

        let final = doses.first { $0.type == .bolus && !$0.isMutable }
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.95, accuracy: 0.001)
        XCTAssertEqual(final?.startDate, start.addingTimeInterval(Self.minute))

        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0, "both finals stored now")
    }

    /// State saved by the build before, a temp basal in it waiting on its record - mutable for the host: the first batch
    /// after the launch carries it final, from our estimate, once. It is never reported mutable again.
    func testTempBasalSavedWaitingOnItsRecordIsFinalizedOnceFromOurEstimate() throws {
        var raw = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75.35).rawValue
        let saved = runningTempBasal(rate: 1.2, startedAgo: 20 * Self.minute, duration: 30 * Self.minute)
        let start = saved.startDate
        var waitingTempBasal = saved.rawValue
        waitingTempBasal["pumpStartTime"] = Self.patchTime(397_084_000)
        waitingTempBasal["finishReason"] = "cancelled"
        waitingTempBasal["finishedAt"] = start.addingTimeInterval(11 * Self.minute)
        waitingTempBasal["observedEndDate"] = start.addingTimeInterval(11 * Self.minute)
        raw["awaitingRecord"] = [waitingTempBasal]
        makeManager(MedtrumPumpState(rawValue: try roundTripped(raw)))
        XCTAssertEqual(pumpManager.state.awaitingRecord.map(\.isFinalized), [false])

        let fullStatus = [
            "2f034401000020ee0d80010080000006a803ec2a",
            "2f03440200f607ab17193000e0052b33a817c5a8",
            "2f0344033b59a903ec00b5d602001905735c"
        ]
        link.deliverFullStatus(fullStatus)
        settle()

        let reported = reports(of: .tempBasal).filter { $0.startDate == start }
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.isMutable, false)
        XCTAssertEqual(reported.first?.endDate, start.addingTimeInterval(11 * Self.minute))
        // 1.2 U/h for 11 min, by rate × duration
        XCTAssertEqual(reported.first?.deliveredUnits ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0, "stored")

        link.deliverFullStatus(fullStatus)
        settle()
        XCTAssertEqual(reports(of: .tempBasal).filter { $0.startDate == start }.count, 1)
    }

    /// Killed right after the host stored the batch of a replacing temp basal: the state it saved by then knows the new
    /// temp basal, so the next replacing batch after the restart still carries it (and the old one's final, not yet
    /// confirmed when that state was saved)
    func testRestartRightAfterTheHostStoredAReplacingTempBasalKeepsIt() throws {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 490, reservoir: 119.7)
        state.basalDose = runningTempBasal(
            rate: 0.65,
            startedAgo: 10 * Self.minute,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(396_996_756 - 600)
        )
        state.basalState = .tempBasal
        makeManager(state)
        // What the host had saved before the command
        delegate.pumpManagerDidUpdateState(pumpManager)

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121907000000010e00eb01ec0094b0a9170300")
        link.script(CommandType.SET_TEMP_BASAL, fragments: "121808000000060000ec01ec0097b0a917f900")
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 491,
            patchId: 236,
            type: .ABSOLUTE_TEMP,
            start: Self.patchTime(396_996_756 - 600),
            end: Self.patchTime(396_996_756),
            rate: 0.65,
            delivered: 0.1
        ))
        XCTAssertNil(commandTempBasal(0, duration: 30 * Self.minute))
        settle()

        let stored = try XCTUnwrap(delegate.batches.last)
        XCTAssertEqual(stored.events.map(\.dose?.unitsPerHour), [0.65, 0.0])
        let saved = try roundTripped(XCTUnwrap(stored.savedState))
        makeManager(MedtrumPumpState(rawValue: saved))

        XCTAssertEqual(pumpManager.state.basalDose.type, .tempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.value, 0)
        XCTAssertEqual(pumpManager.state.awaitingRecord.map(\.value), [0.65])
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.isFinalized, true)

        link.deliverFullStatus([
            "2f034401000020ee0d80010080000006a803ec2a",
            "2f03440200f607ab17193000e0052b33a817c5a8",
            "2f0344033b59a903ec00b5d602001905735c"
        ])
        settle()

        let replacing = try XCTUnwrap(delegate.batches.last)
        XCTAssertTrue(replacing.replacePendingEvents)
        let tempBasals = replacing.events.compactMap(\.dose).filter { $0.type == .tempBasal }
        XCTAssertEqual(Set(tempBasals.map(\.unitsPerHour)), [0, 0.65])
        XCTAssertEqual(tempBasals.first { $0.unitsPerHour == 0 }?.syncIdentifier, stored.events.last?.dose?.syncIdentifier)
    }

    /// A suspend the command dates (no status announced it first), then a resume: restarted from the state saved with
    /// either batch, the basal state is the one the batch reports - not the one before it.
    /// This guards the restart round trip; it cannot fail deterministically with the state assigned after the emit: the
    /// host reads the state asynchronously, so that race needs the delegate queue to run inside the window.
    func testRestartRightAfterTheHostStoredASuspendOrAResumeKeepsTheBasalState() throws {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        state.basalDose = runningTempBasal(
            rate: 0.6,
            startedAgo: 266,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_186_357)
        )
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)

        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        XCTAssertNil(commandSuspend())
        settle()

        let suspended = try XCTUnwrap(delegate.batches.last)
        XCTAssertEqual(suspended.events.map(\.dose?.type), [.tempBasal, .suspend])
        makeManager(MedtrumPumpState(rawValue: try roundTripped(XCTUnwrap(suspended.savedState))))

        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)

        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()

        let resumed = try XCTUnwrap(delegate.batches.last)
        XCTAssertEqual(resumed.events.first?.dose?.type, .resume)
        makeManager(MedtrumPumpState(rawValue: try roundTripped(XCTUnwrap(resumed.savedState))))

        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        XCTAssertEqual(pumpManager.state.basalState, .active)
    }

    /// Commands and statuses are stamped on the one monotonic clock, and it is the one that counts sleep
    /// (`mach_continuous_time`), not the one that stops in it (`mach_absolute_time`, `systemUptime`): a phone with its
    /// screen locked sleeps between the wakes that bring its statuses. The two read the same on a host that has not
    /// slept since it booted.
    func testCommandsAndStatusesAreStampedOnTheClockThatCountsSleep() {
        let manager = MedtrumPumpManager(
            state: activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 100),
            link: FakeMedtrumLink()
        )
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let continuous = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000

        XCTAssertEqual(TimeInterval.continuousUptime, continuous, accuracy: 0.5)
        XCTAssertEqual(manager.uptime(), continuous, accuracy: 0.5, "commands, and the record counter's tellings")
        XCTAssertEqual(SynchronizePacketResponse(state: .active, activeAlarms: []).receivedUptime, continuous, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(TimeInterval.continuousUptime + 0.5, ProcessInfo.processInfo.systemUptime)
    }

    /// Every field a dose keeps for its record and its final, through the property list the host saves the state in -
    /// and the state's own new fields
    func testEveryNewFieldSurvivesARoundTrip() throws {
        let t0 = Date(timeIntervalSince1970: 1_785_630_000)

        let uncertain = UnfinalizedDose(
            units: 0.3,
            duration: 12,
            activationType: .automatic,
            insulinType: .novolog,
            confirmation: .uncertain
        )
        uncertain.noteCommand(sentAt: t0, uptime: 100, sequence: 823)
        XCTAssertTrue(uncertain.noteUncertaintyReported())
        XCTAssertTrue(uncertain.finish(.completionNotSeen, endedAt: nil, at: t0.addingTimeInterval(173)))
        uncertain.noteRecordRead(824)
        uncertain.notePossibleRecord(824)

        let bolus = UnfinalizedDose(units: 2, duration: 80, activationType: .manualNoRecommendation, insulinType: nil)
        bolus.noteCommand(sentAt: t0, uptime: nil, sequence: 122)
        bolus.noteAnswer(recordSequence: 123, pumpStartTime: t0.addingTimeInterval(1))
        bolus.updateProgress(delivered: 1.9, at: t0.addingTimeInterval(70))
        XCTAssertTrue(bolus.finish(.completed, deliveredUnits: 2, endedAt: t0.addingTimeInterval(78), at: t0.addingTimeInterval(79)))
        XCTAssertTrue(bolus.finalize(deliveredUnits: 2, at: t0.addingTimeInterval(200)))

        let tempBasal = UnfinalizedDose(
            tempRate: 0,
            duration: 3600,
            insulinType: nil,
            automatic: true,
            confirmation: .uncertain,
            startDate: t0
        )
        tempBasal.noteCommand(sentAt: t0, uptime: nil, sequence: 118, priorSegmentStart: t0.addingTimeInterval(-10))
        tempBasal.noteLaterSegment(startingAt: t0.addingTimeInterval(300))
        XCTAssertTrue(tempBasal.setPumpStartTime(t0.addingTimeInterval(2)))
        XCTAssertTrue(tempBasal.markStopUnanswered(at: t0.addingTimeInterval(250)))
        XCTAssertTrue(tempBasal.disableRecordMatch())

        XCTAssertTrue(Set(uncertain.rawValue.keys).isSuperset(of: [
            "confirmation", "uncertaintyReported", "sentAt", "sequenceAtSend", "finishReason", "finishedAt",
            "recordsReadThrough", "possibleRecord"
        ]))
        XCTAssertTrue(Set(bolus.rawValue.keys).isSuperset(of: [
            "recordSequence", "pumpStartTime", "lastProgressAt", "lastProgressUnits", "observedEndDate",
            "finalDeliveredUnits", "finalEndDate", "finalizedAt"
        ]))
        XCTAssertTrue(Set(tempBasal.rawValue.keys).isSuperset(of: [
            "priorSegmentStart", "laterSegmentStart", "stopUnansweredAt", "recordMatchDisabled"
        ]))

        for dose in [uncertain, bolus, tempBasal] {
            let restored = try XCTUnwrap(UnfinalizedDose(rawValue: try roundTripped(dose.rawValue)))
            XCTAssertEqual(restored.rawValue as NSDictionary, dose.rawValue as NSDictionary)
        }

        let restoredUncertain = try XCTUnwrap(UnfinalizedDose(rawValue: try roundTripped(uncertain.rawValue)))
        XCTAssertEqual(restoredUncertain.confirmation, .uncertain)
        XCTAssertTrue(restoredUncertain.snapshot.uncertaintyReported)
        XCTAssertNil(restoredUncertain.snapshot.sentUptime, "the monotonic clock of another run is not kept")
        XCTAssertEqual(restoredUncertain.snapshot.recordsReadThrough, 824)
        XCTAssertEqual(restoredUncertain.snapshot.possibleRecord, 824)

        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 100)
        state.mutateAwaitingRecord { $0 = [uncertain, bolus] }
        state.unconfirmedTempBasal = tempBasal
        state.patchUTCOffset = 7200
        state.sequenceConfirmedAt = t0.addingTimeInterval(400)
        state.skippedRecordSequences = [120]
        state.answeredBolusRecords = [123]
        let pending = PendingBolus(units: 1.5, sentAt: t0.addingTimeInterval(500), sequenceAtSend: 124, automatic: true)
        state.pendingBolus = pending

        let restored = MedtrumPumpState(rawValue: try roundTripped(state.rawValue))
        XCTAssertEqual(restored.awaitingRecord.map { $0.rawValue as NSDictionary }, [uncertain, bolus].map { $0.rawValue as NSDictionary })
        XCTAssertEqual(restored.unconfirmedTempBasal?.rawValue as NSDictionary?, tempBasal.rawValue as NSDictionary)
        XCTAssertEqual(restored.patchUTCOffset, 7200)
        XCTAssertEqual(restored.sequenceConfirmedAt, t0.addingTimeInterval(400))
        XCTAssertEqual(restored.skippedRecordSequences, [120])
        XCTAssertEqual(restored.answeredBolusRecords, [123])
        XCTAssertEqual(restored.pendingBolus, pending)
        XCTAssertTrue(restored.deliveryIsUncertain, "the unconfirmed temp basal")
    }

    /// The answered bolus records saved with their patch starts, as builds before kept them, decode to their numbers
    func testAnsweredBolusRecordsSavedWithTheirStartsDecode() throws {
        var raw = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 124, reservoir: 100).rawValue
        raw["answeredBolusRecords"] = [
            ["sequence": 123, "pumpStartTime": Date.now],
            ["sequence": 124, "pumpStartTime": Date.now]
        ]

        XCTAssertEqual(MedtrumPumpState(rawValue: try roundTripped(raw)).answeredBolusRecords, [123, 124])
    }

    /// The state the shipped driver saves decodes without loss, and saves again as it was
    func testStateSavedBeforeRecordsWereMatchedDecodes() throws {
        let t0 = Date.now.addingTimeInterval(-Self.minute)
        let bolus: [String: Any] = [
            "type": DoseType.bolus.rawValue,
            "value": 1.5,
            "startDate": t0,
            "estimatedEndDate": t0.addingTimeInterval(60),
            "deliveredUnits": 0.4,
            "insulinType": InsulinType.novolog.rawValue,
            "automatic": false
        ]
        let tempBasal: [String: Any] = [
            "type": DoseType.tempBasal.rawValue,
            "value": 1.2,
            "startDate": t0.addingTimeInterval(-600),
            "estimatedEndDate": t0.addingTimeInterval(1200),
            "deliveredUnits": 0.0,
            "automatic": true,
            "pumpStartTime": t0.addingTimeInterval(-590)
        ]
        let shipped: [String: Any] = [
            "isOnboarded": true,
            "lastSync": t0,
            "pumpSN": Data([1, 2, 3, 4]),
            "sessionToken": Data([5, 6, 7, 8]),
            "backupSessionToken": Data(),
            "patchId": UInt64(236).toData(length: 4),
            "currentSequenceNumber": 122,
            "syncedSequenceNumber": 120,
            "patchActivatedAt": t0.addingTimeInterval(-Self.hour),
            "deviceType": UInt8(80),
            "swVersion": "1.80.88",
            "pumpTime": t0,
            "pumpTimeSyncedAt": t0,
            "pumpState": PatchState.active.rawValue,
            "maxHourlyInsulin": 20.0,
            "maxDailyInsulin": 100.0,
            "basalSchedule": BasalSchedule(entries: [RepeatingScheduleValue(startTime: 0, value: 0.6)]).rawValue,
            "initialReservoir": 200.0,
            "bolusDose": bolus,
            "basalDose": tempBasal,
            "reservoir": 120.0,
            "battery": 2.8,
            "basalState": BasalState.tempBasal.rawValue,
            "alarmSetting": AlarmSettings.BeepOnly.rawValue,
            "expiryMode": ExpiryMode.default.rawValue,
            "notificationAfterActivation": 72 * Self.hour,
            "useSilentTones": false
        ]

        let state = MedtrumPumpState(rawValue: try roundTripped(shipped))

        let running = try XCTUnwrap(state.bolusDose)
        XCTAssertEqual(running.deliveredUnits, 0.4, accuracy: 0.001)
        XCTAssertEqual(running.confirmation, .confirmed)
        XCTAssertFalse(running.isFinished)
        XCTAssertNil(running.recordSequence)
        XCTAssertNil(running.sentAt)
        XCTAssertNil(running.snapshot.recordsReadThrough)
        XCTAssertNil(running.snapshot.possibleRecord)
        XCTAssertEqual(state.basalDose.type, .tempBasal)
        XCTAssertEqual(state.basalDose.pumpStartTime, t0.addingTimeInterval(-590))
        XCTAssertEqual(state.awaitingRecord.count, 0)
        XCTAssertNil(state.unconfirmedTempBasal)
        XCTAssertNil(state.patchUTCOffset)
        XCTAssertNil(state.sequenceConfirmedAt, "never told: not caught up until a status says so")
        XCTAssertEqual(state.skippedRecordSequences, [])
        XCTAssertEqual(state.answeredBolusRecords, [])
        XCTAssertNil(state.pendingBolus)
        XCTAssertFalse(state.deliveryIsUncertain)
        XCTAssertEqual(state.currentSequenceNumber, 122)
        XCTAssertEqual(state.syncedSequenceNumber, 120)

        let saved = state.rawValue
        XCTAssertEqual(saved["bolusDose"] as? NSDictionary, bolus as NSDictionary)
        XCTAssertEqual(saved["basalDose"] as? NSDictionary, tempBasal as NSDictionary)
        XCTAssertEqual((saved["awaitingRecord"] as? [Any])?.count, 0)
        XCTAssertNil(saved["unconfirmedTempBasal"])
        XCTAssertNil(saved["pendingBolus"])

        // A bolus without a send time still has a deadline - from its start
        XCTAssertEqual(
            running.deliveryDeadline(of: running.snapshot),
            t0.addingTimeInterval(3 * Self.minute + UnfinalizedDose.deliveryGrace)
        )
    }

    /// AndroidAPS's policy for records that can't be read: asked for once more, then skipped; two skipped in a row end
    /// the run; a timeout ends it with the record left for the next run
    func testRecordsThatCannotBeReadAreSkippedOrLeftForTheNextRun() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 945, reservoir: 75)
        state.syncedSequenceNumber = 940
        makeManager(state)

        let record943 = ["276378010000aa2002ff9e75aef7ec00af03055f", "276378020fab17080fab1701000e000000110039", "2763780325c085893860"]
        let record945 = ["27637a010000aa2002ff9e75aef7ec00b1032b37", "27637a0210ab172d10ab1701000e0000000c008e", "27637a0349cbf5a44c9b"]

        link.script(CommandType.GET_RECORD, .garbled(record943))
        link.script(CommandType.GET_RECORD, .garbled(record943))
        link.script(
            CommandType.GET_RECORD,
            fragments: "276377010000aa2002ff9e75aef7ec00ae03a86a",
            "276377020cab17050fab17060000000000000061",
            "276377036a775b0bba38"
        )
        link.script(CommandType.GET_RECORD, .failure(.invalidResponse(code: 8)))
        link.script(CommandType.GET_RECORD, .failure(.invalidResponse(code: 8)))
        link.script(CommandType.GET_RECORD, .garbled(record943))
        link.script(CommandType.GET_RECORD, .garbled(record943))
        syncRecords()

        // 941 skipped, 942 read, 943 and 944 skipped - two in a row: 945 is not asked for
        XCTAssertEqual(link.writtenCommands.count, 7)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 944)
        XCTAssertEqual(pumpManager.recordStore.records.map(\.id), [942])

        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()
        XCTAssertEqual(link.writtenCommands.count, 8)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 944, "left for the next run")

        link.script(CommandType.GET_RECORD, .fragments(record945))
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 945)
        XCTAssertEqual(pumpManager.recordStore.records.map(\.id), [945, 942])
    }
}

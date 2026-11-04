import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerTempBasalScenarioTests {
    /// The patch's notification that it halted delivery, in state `state`, naming `newestRecord` - of patch 251 - the
    /// newest record written: with when it halted, `at`, as after a suspend we asked for - or without, nil, as the patch
    /// sends one for a halt of its own (`logs1018/today.txt:9166`)
    func haltNotification(_ state: PatchState, at: Date?, newestRecord: Int) -> String {
        let storage = UInt64(newestRecord).toData(length: 2) + UInt64(251).toData(length: 2)
        guard let at else {
            return (Data([state.rawValue, 0x00, 0x01]) + storage).hexEncodedString()
        }
        return (Data([state.rawValue, 0x01, 0x01]) + at.toMedtrumSeconds() + storage).hexEncodedString()
    }

    /// Where our temp basal started, on the patch clock, and where the cancel ended it 20 min later
    static let ourStart = patchTime(400_000_000)
    static let ourEnd = patchTime(400_001_200)

    /// What the settings screen says of `delivery`
    func settingsNotice(for delivery: UncertainDelivery) -> UncertainDeliveryNotice {
        MedtrumKitSettingsViewModel(nil, {}, { _ in }, {}, {}, {}, {}, {}, {}, {}, {})
            .notice(for: delivery, phase: pumpManager.state.phase(of: delivery))
    }

    /// 1.2 U/h of ours, 30 min, running for 20 min, every record read up to `sequence`
    @discardableResult func runTempBasalOfOurs(patchId: UInt64 = 251, sequence: Int = 130) -> UnfinalizedDose {
        let state = activePatchState(patchId: patchId, scheduledRate: 0.7, sequence: sequence, reservoir: 150)
        let tempBasal = runningTempBasal(rate: 1.2, startedAgo: 20 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.ourStart)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.ourEnd)
        makeManager(state)
        return tempBasal
    }

    /// The cancel of it, answered with the scheduled basal from `ourEnd` and the number of its record
    func cancelAnswer(patchId: UInt64 = 251, record: Int = 131) -> [String] {
        PatchBytes.segmentAnswer(command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: record, patchId: patchId, start: Self.ourEnd)
    }

    /// The set of 0.5 U/h after it, answered with the scheduled basal's record
    func setAnswer(patchId: UInt64 = 251, record: Int = 132) -> [String] {
        PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 0.5,
            sequence: record,
            patchId: patchId,
            start: Self.ourEnd.addingTimeInterval(1)
        )
    }

    /// The cancel only, to the schedule: what follows leaves a gap after the temp basal, which ends final - its records
    /// read in the command
    func scriptCancel(patchId: UInt64 = 251, cancelRecord: Int = 131) {
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(patchId: patchId, record: cancelRecord))
    }

    func scriptCancelAndSet(patchId: UInt64 = 251, cancelRecord: Int = 131) {
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(patchId: patchId, record: cancelRecord))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(patchId: patchId, record: cancelRecord + 1))
    }

    func recordOfOurTempBasal(
        patchId: UInt64 = 251,
        sequence: Int = 131,
        delivered: Double,
        endReason: BasalEndReason = .SUCCESS
    ) -> [String] {
        PatchBytes.basalRecord(
            sequence: sequence,
            patchId: patchId,
            type: .ABSOLUTE_TEMP,
            start: Self.ourStart,
            end: Self.ourEnd,
            rate: 1.2,
            delivered: delivered,
            endReason: endReason
        )
    }

    /// The new temp basal of 0.5 U/h running from just after `ourEnd`, as a status shows it
    func newTempBasalRunning() -> String {
        PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 132, patchId: 251, start: Self.ourEnd.addingTimeInterval(1), rate: 0.5)
    }

    /// The record of the second of scheduled basal between the cancel and the set, `sequence`
    func cancelsScheduledSecond(sequence: Int = 132) -> [String] {
        PatchBytes.basalRecord(
            sequence: sequence,
            patchId: 251,
            type: .STANDARD,
            start: Self.ourEnd,
            end: Self.ourEnd.addingTimeInterval(1),
            rate: 0.7,
            delivered: 0
        )
    }

    /// The scheduled basal running from `ourEnd`, as a status shows it after the cancel
    func scheduledBasalRunning() -> String {
        PatchBytes.basalNotification(type: .STANDARD, sequence: 131, patchId: 251, start: Self.ourEnd, rate: 0.7)
    }

    /// Cancels it, the record the cancel names timing out. Returns its final.
    func cancelItUnread(file: StaticString = #filePath, line: UInt = #line) -> DoseEntry? {
        let tempBasal = pumpManager.state.basalDose
        scriptCancel()
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0), file: file, line: line)
        settle()

        XCTAssertEqual(
            link.writtenCommands,
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD],
            "asked for once",
            file: file,
            line: line
        )
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 130, "left for a sync", file: file, line: line)
        XCTAssertEqual(delegate.batches.count, 1, file: file, line: line)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.7], file: file, line: line)
        XCTAssertEqual(delegate.batches.first?.events.last?.dose?.type, .basal, file: file, line: line)

        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false, file: file, line: line)
        XCTAssertEqual(final?.startDate, tempBasal.startDate, file: file, line: line)
        return final
    }

    /// The 0.6 U/h temp basal of `testTempBasalAcrossPatchMidnightIsFinalizedFromBothItsRecords`, every record up to 945
    /// read, the patch having written up to 948 - as the loop's full status says
    @discardableResult func runTempBasalAcrossPatchMidnight() -> UnfinalizedDose {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 945, reservoir: 74.9)
        state.currentSequenceNumber = 948
        let tempBasal = runningTempBasal(
            rate: 0.6,
            startedAgo: 897,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_086_765)
        )
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        state.patchUTCOffset = 2 * Self.hour
        alignPatchClock(state, patchTime: Self.patchTime(397_087_662))
        makeManager(state)
        return tempBasal
    }

    /// Waits on this thread until `condition` holds, `timeout` at most: the time a device gives a command from another
    /// thread to go out. Returns whether it held.
    @discardableResult func giveTime(timeout: TimeInterval = 1, until condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// A status received `receivedAgo` before now
    func notify(_ hex: String, receivedAgo: TimeInterval) {
        let packet = NotificationPacket()
        packet.totalData = FakeMedtrumLink.bytes(hex)
        var status = packet.parseResponse()
        status.receivedAt = status.receivedAt.addingTimeInterval(-receivedAgo)
        status.receivedUptime += uptimeOffset.value - receivedAgo
        link.onQueue {
            self.pumpManager.handleStatus(status, duringReconnect: false, fullSync: false)
        }
        settle()
    }

    /// No batch carries the scheduled basal after the cancel before `final` went out, nor the one `final` is of as
    /// mutable after
    func assertScheduledBasalNeverBeforeTheFinal(of final: DoseEntry, file: StaticString = #filePath, line: UInt = #line) {
        let batches = delegate.batches.map { $0.events.compactMap(\.dose) }
        let finalAt = batches.firstIndex { $0.contains { $0.syncIdentifier == final.syncIdentifier && !$0.isMutable } }
        let newAt = batches.firstIndex { $0.contains { $0.type == .basal } }
        XCTAssertNotNil(finalAt, file: file, line: line)
        XCTAssertNotNil(newAt, file: file, line: line)
        XCTAssertLessThanOrEqual(finalAt ?? .max, newAt ?? -1, file: file, line: line)
        XCTAssertFalse(
            batches.joined().contains { $0.syncIdentifier == final.syncIdentifier && $0.isMutable },
            "never mutable",
            file: file,
            line: line
        )
    }

    /// `user.txt:87370-87380`: 0.2 U/h running, the cancel answered, the set of zero for 60 min not. Returns when
    /// the set went out, about.
    @discardableResult func startUnansweredTempBasal(
        duration: TimeInterval = MedtrumManagerTestCase.hour,
        automatic: Bool = true,
        patchUTCOffset: TimeInterval? = nil,
        patchAhead: TimeInterval = 0
    ) -> Date {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 118, reservoir: 172.1)
        state.patchUTCOffset = patchUTCOffset
        let previous = runningTempBasal(
            rate: 0.2,
            startedAgo: 601,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(399_932_735)
        )
        state.basalDose = previous
        state.basalState = .tempBasal
        state.lastSegmentStart = Self.patchTime(399_932_735)
        alignPatchClock(state, patchTime: Self.patchTime(399_933_337).addingTimeInterval(patchAhead))
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121904000000010e007700fb00987fd617d800")
        link.script(CommandType.SET_TEMP_BASAL, .timeout)

        let sentAt = Date.now
        let outcome: PumpManagerError?? = completion(of: "enactTempBasal") { done in
            self.pumpManager.enactTempBasal(unitsPerHour: 0, duration: duration, automatic: automatic, completion: done)
        }
        XCTAssertTrue(isUncertainDelivery(outcome ?? nil))
        settle()

        if duration == Self.hour {
            XCTAssertEqual(written(CommandType.SET_TEMP_BASAL)?.encoded(sequence: 0x05), "0a1805000600003c005c00")
        }
        // The cancel names the record of the temp basal it ended, but the set went unanswered: it is not read on that
        // link
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL])
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 119)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 118)

        // What the host is told: the temp basal before ended at the cancel, final from our estimate - 0.2 U/h × 10 min,
        // to the nearest 0.05 U - then the schedule, and nothing of the new one
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.startDate, previous.startDate)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.isMutable, false)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 1, 0.05, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)

        // A sync reads it later: it changes nothing
        link.script(CommandType.GET_RECORD, Self.cancelledTempBasalsRecord)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 119)
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome, "unmatched")

        let pending = pumpManager.state.unconfirmedTempBasal
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.value, 0)
        XCTAssertEqual(pending?.snapshot.priorSegmentStart, Self.patchTime(399_933_336))
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal, "the next temp basal cancels first")
        return sentAt
    }

    /// A basal profile set, answered with the segment the patch restarted at `restartingAt`. Returns the schedule set.
    func setBasalProfile(restartingAt start: Date) -> BasalRateSchedule? {
        link.script(CommandType.SET_BASAL_PROFILE, PatchBytes.segmentAnswer(
            command: CommandType.SET_BASAL_PROFILE,
            type: .ABSOLUTE_TEMP,
            rate: 0,
            sequence: 120,
            patchId: 251,
            start: start
        ))
        let result: Result<BasalRateSchedule, Error>? = completion(of: "syncBasalRateSchedule") { done in
            self.pumpManager.syncBasalRateSchedule(items: [RepeatingScheduleValue(startTime: 0, value: 0.7)], completion: done)
        }
        settle()
        return try? result?.get()
    }

    /// The record of the temp basal the cancel in `startUnansweredTempBasal` ended - the only one written
    private static let cancelledTempBasalsRecord = PatchBytes.basalRecord(
        sequence: 119,
        patchId: 251,
        type: .ABSOLUTE_TEMP,
        start: patchTime(399_932_735),
        end: patchTime(399_933_336),
        rate: 0.2,
        delivered: 0.05
    )

    /// Every record is read: the one the cancel in `startUnansweredTempBasal` named was read by the sync after it, and
    /// another finds nothing more
    func readTheCancelledTempBasalsRecord() {
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 119)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 119)
    }

    /// The last command of `type` written
    func written(_ type: UInt8) -> FakeMedtrumLink.Write? {
        link.writes.last { $0.commandType == type }
    }

    /// The unanswered set of `startUnansweredTempBasal`, every record read, then a status showing - from `notification`
    /// - a segment or a suspend from 10 min after the command, not the temp basal: had it run, it ended by then. It is
    /// dropped 15 min after that.
    func assertShownSinceAfterTheCommandEndsTheUnansweredTempBasal(
        _ notification: (Date) -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()

        let shownFrom = Self.patchTime(399_933_337 + 600)
        link.notify(notification(shownFrom))
        settle()
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.snapshot.laterSegmentStart, shownFrom, file: file, line: line)

        advanceClock(by: 24 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, file: file, line: line)

        advanceClock(by: 2 * Self.minute)
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, file: file, line: line)
        XCTAssertTrue(
            reports(of: .tempBasal).allSatisfy { $0.unitsPerHour > 0.1 },
            "the zero temp basal never reached the host",
            file: file,
            line: line
        )
    }

    /// No temp basal running, the last segment we heard of from an hour before: the set of zero for 60 min goes out
    /// unanswered, and a notification right after it shows the scheduled segment the patch restarted 5 min before the
    /// command, which must not bound the temp basal. Returns the patch's time when the set went out, about.
    func startUnansweredTempBasalAfterAStaleSegment() -> Date {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 118, reservoir: 172.1)
        let patchSentAt = Self.patchTime(399_933_337)
        state.lastSegmentStart = patchSentAt.addingTimeInterval(-Self.hour)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)

        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        let outcome: PumpManagerError?? = completion(of: "enactTempBasal") { done in
            self.pumpManager.enactTempBasal(unitsPerHour: 0, duration: Self.hour, automatic: true, completion: done)
        }
        XCTAssertTrue(isUncertainDelivery(outcome ?? nil))
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        link.notify(PatchBytes.basalNotification(
            type: .STANDARD,
            sequence: 118,
            patchId: 251,
            start: patchSentAt.addingTimeInterval(-5 * Self.minute),
            rate: 0.7
        ))
        settle()
        XCTAssertNil(
            pumpManager.state.unconfirmedTempBasal?.snapshot.laterSegmentStart,
            "a segment begun before the command is not a later one"
        )
        return patchSentAt
    }
}

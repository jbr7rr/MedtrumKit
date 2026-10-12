import LoopKit
@testable import MedtrumKit
import XCTest

/// Temp basal scenarios driven through the manager: commands, statuses, records, and what the host is told.
/// Bytes are from the user's MedtrumKit logs, cited by the line in the merged analysis log `user.txt` or the
/// record-reading log `aug12.txt`. Records no log has are built with `PatchBytes`.
final class ManagerTempBasalScenarioTests: MedtrumManagerTestCase {
    /// 2026-08-02 02:32:37 (`user.txt:25803-25806`), patch 237 minutes after activation: 2.1 U/h for
    /// 30 min over the scheduled 0.6 U/h
    func testTempBasalOverTheSchedule() {
        makeManager(activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 1, reservoir: 184.85))

        link.script(CommandType.SET_TEMP_BASAL, fragments: "12180e000000062a000200ed009835ab174000")

        XCTAssertNil(commandTempBasal(2.1, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_TEMP_BASAL])
        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x0E), "0a180e00062a001e005500")

        XCTAssertEqual(delegate.batches.count, 1)
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.replacePendingEvents, true)
        // Only the temp basal: the scheduled basal it interrupts has no event of its own to end
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.tempBasal])

        let dose = batch?.events.first?.dose
        XCTAssertEqual(dose?.isMutable, true)
        XCTAssertEqual(dose?.automatic, true)
        XCTAssertEqual(dose?.unitsPerHour ?? 0, 2.1, accuracy: 0.001)
        XCTAssertEqual(dose.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 30 * Self.minute, accuracy: 0.001)
        XCTAssertNil(dose?.deliveredUnits)

        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .tempBasal)
        guard case .tempBasal? = pumpManager.status.basalDeliveryState else {
            XCTFail("Status does not show the temp basal: \(String(describing: pumpManager.status.basalDeliveryState))")
            return
        }

        // The answer's start time becomes the dose's patch start. Its record number (2) is the record the
        // patch wrote for the scheduled segment this ended - adopted as the newest record.
        XCTAssertEqual(pumpManager.state.basalDose.pumpStartTime, Date(timeIntervalSince1970: 1_785_630_744))
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 2)
    }

    /// 2026-07-31 22:52:34 - 22:52:38 (`user.txt:16914-16920`), patch 236: a zero temp for 30 min while
    /// 0.65 U/h runs - which is a cancel, then a set
    func testTempBasalReplacesARunningOne() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 490, reservoir: 119.7)
        let previous = runningTempBasal(rate: 0.65, startedAgo: 10 * Self.minute, duration: 30 * Self.minute)
        state.basalDose = previous
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121907000000010e00eb01ec0094b0a9170300")
        link.script(CommandType.SET_TEMP_BASAL, fragments: "121808000000060000ec01ec0097b0a917f900")

        let commandedAt = Date.now
        XCTAssertNil(commandTempBasal(0, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL])
        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x07), "05190700c500")
        XCTAssertEqual(link.writes.last?.encoded(sequence: 0x08), "0a1808000600001e007900")

        // One batch: the old temp basal ended, the new one running. The second or two of scheduled basal
        // the patch ran between the cancel and the set is not reported.
        XCTAssertEqual(delegate.batches.count, 1)
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.replacePendingEvents, true)
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.tempBasal, .tempBasal])

        // Ended on the phone's clock when the new one was set, not at the patch time the cancel answered
        // with - and waiting on its record, mutable
        let ended = batch?.events.first?.dose
        XCTAssertEqual(ended?.isMutable, true)
        XCTAssertEqual(ended?.startDate, previous.startDate)
        XCTAssertEqual(ended?.unitsPerHour ?? 0, 0.65, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(ended?.endDate ?? .distantPast, commandedAt)
        XCTAssertNil(ended?.deliveredUnits)
        XCTAssertEqual(pumpManager.state.awaitingRecord.map(\.startDate), [previous.startDate])

        // Without its record: rate x duration, floored to 0.05 U - 0.65 U/h for 10 min -> 0.1 U
        XCTAssertEqual(previous.fallbackDeliveredUnits, 0.1, accuracy: 0.001)

        let started = batch?.events.last?.dose
        XCTAssertEqual(started?.isMutable, true)
        XCTAssertEqual(started?.unitsPerHour ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(started.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 30 * Self.minute, accuracy: 0.001)

        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.pumpStartTime, Date(timeIntervalSince1970: 1_785_531_159))
        // 491 from the cancel answer, then 492 from the set's
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 492)
    }

    /// A zero duration cancels the running temp basal. No log has one, so the answer is the cancel from
    /// 2026-07-31 22:52:36 (`user.txt:16917`), patch 236.
    func testCancellingTheTempBasalGoesBackToTheSchedule() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 490, reservoir: 119.7)
        let previous = runningTempBasal(rate: 0.65, startedAgo: 10 * Self.minute, duration: 30 * Self.minute)
        state.basalDose = previous
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121907000000010e00eb01ec0094b0a9170300")

        let commandedAt = Date.now
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL])

        XCTAssertEqual(delegate.batches.count, 1)
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.replacePendingEvents, true)
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.tempBasal, .basal])

        let ended = batch?.events.first?.dose
        XCTAssertEqual(ended?.isMutable, true, "waiting on its record")
        XCTAssertEqual(ended?.startDate, previous.startDate)
        XCTAssertGreaterThanOrEqual(ended?.endDate ?? .distantPast, commandedAt)
        XCTAssertEqual(previous.fallbackDeliveredUnits, 0.1, accuracy: 0.001)

        // The schedule's rate from now on - not the patch's start time from the cancel answer
        let scheduled = batch?.events.last?.dose
        XCTAssertEqual(scheduled?.unitsPerHour ?? 0, 0.7, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(scheduled?.startDate ?? .distantPast, commandedAt)

        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 491)
        guard case .active? = pumpManager.status.basalDeliveryState else {
            XCTFail("Status does not show scheduled basal: \(String(describing: pumpManager.status.basalDeliveryState))")
            return
        }
    }

    /// 2026-08-01 23:52:39 - 2026-08-02 00:23:05 (`aug12.txt:8584-8748`), patch 236: 0.85 U/h replaced by 0.6 U/h - a
    /// cancel, then a set, both answered with the patch start of the segment they began. The records the patch then
    /// wrote: the 0.85 U/h temp basal (944), and the second of scheduled basal between the two commands (945).
    func testReplacedTempBasalIsFinalizedByItsRecord() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 943, reservoir: 75)
        let previous = runningTempBasal(
            rate: 0.85,
            startedAgo: 291,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_086_472)
        )
        state.basalDose = previous
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_086_763))
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "12195f000000010e00b003ec002b10ab17cd00")
        link.script(CommandType.SET_TEMP_BASAL, fragments: "121860000000060c00b103ec002d10ab170100")

        XCTAssertNil(commandTempBasal(0.6, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x5F), "05195f005400")
        XCTAssertEqual(link.writes.last?.encoded(sequence: 0x60), "0a186000060c001e004700")
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 945)
        XCTAssertEqual(pumpManager.state.basalDose.pumpStartTime, Self.patchTime(397_086_765))

        let ended = delegate.batches.last?.events.first?.dose
        XCTAssertEqual(ended?.startDate, previous.startDate)
        XCTAssertEqual(ended?.isMutable, true)

        link.script(
            CommandType.GET_RECORD,
            fragments: "276379010000aa2002ff9e75aef7ec00b0030857",
            "276379020fab172b10ab17060011000200110056",
            "276379031fc86ab4b429"
        )
        link.script(
            CommandType.GET_RECORD,
            fragments: "27637a010000aa2002ff9e75aef7ec00b1032b37",
            "27637a0210ab172d10ab1701000e0000000c008e",
            "27637a0349cbf5a44c9b"
        )
        syncRecords()

        // 944 starts on the patch start the set answered with, to the second: its record. 291 s, 0.1 U.
        let final = finals(of: ended)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.last?.startDate, previous.startDate)
        XCTAssertEqual(final.last?.unitsPerHour ?? 0, 0.85, accuracy: 0.001)
        XCTAssertEqual(final.last?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(final.last.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 291, accuracy: 0.001)

        // 945, the scheduled basal: logged only
        let records = pumpManager.recordStore.records
        XCTAssertEqual(records.map(\.id), [945, 944])
        XCTAssertNil(records.first?.outcome)
        XCTAssertEqual(records.last?.outcome?.hasPrefix("finalized temp basal"), true)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 945)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0)
        XCTAssertEqual(pumpManager.state.basalDose.type, .tempBasal, "the new one runs on")
    }

    /// 2026-08-01 23:52:45 - 2026-08-02 00:07:42 (`aug12.txt:8590-8784`), patch 236: 0.6 U/h runs across patch-local
    /// midnight (UTC+2), and the patch writes it as two records, 946 up to midnight and 949 after it. Neither is the
    /// whole temp basal: it is finalized from our estimate, all of its 15 minutes.
    func testTempBasalAcrossPatchMidnightIsFinalizedFromOurEstimate() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 945, reservoir: 74.9)
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

        // 23:59:56: the patch shows the segment running from midnight - another segment, not ours: nothing changes
        link.notify("20080106b203ec00e011ab170c0000b203ec00")
        settle()
        XCTAssertEqual(delegate.batches.count, 0)
        XCTAssertEqual(pumpManager.state.basalDose.pumpStartTime, Self.patchTime(397_086_765))

        // 00:07:39: cancelled
        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121967000000010e00b503ec00ae13ab17b500")
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 949)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.recordMatchDisabled, true)

        for fragments in [
            ["27637b010000aa2002ff9e75aef7ec00b2032d14", "27637b0210ab17e011ab1706000c0002000c0047", "27637b033b9ebe1fcbb7"],
            ["2b637c010000aa240aff9e75aef7ec00b303e046", "2b637c0211ab177800ffffdaac963f2bd1043fe5", "2b637c03000000001c26d17892e8"],
            [
                "5f637d010000aa5809ff9e75aef7ec00b40360ad",
                "5f637d02c0a9177800a0050000000033332f42b7",
                "5f637d03666688410000000000000000000000d1",
                "5f637d0400000053428a88283f0000f042cdccba",
                "5f637d05a83fcccc47428a88283f0000f042cdec",
                "5f637d06cca83f00000000f401f4018897e27da0",
                "5f637d074db0"
            ],
            ["27637e010000aa2002ff9e75aef7ec00b503e021", "27637e0211ab17ae13ab1706000c0000000c00b3", "27637e035b7a87734e7c"]
        ] {
            link.script(CommandType.GET_RECORD, .fragments(fragments))
        }
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 949)
        XCTAssertEqual(pumpManager.recordStore.records.map(\.kind), ["BASAL", "TDD", "UNHANDLED", "BASAL"])
        XCTAssertEqual(pumpManager.recordStore.records.last?.outcome?.hasPrefix("part of split temp basal"), true)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome, "unmatched")

        let ended = reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }
        XCTAssertEqual(finals(of: ended).count, 0)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()

        // The first record alone would have ended it at midnight, 435 s in
        let final = finals(of: ended).last
        XCTAssertEqual(finals(of: ended).count, 1)
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 897, accuracy: 2)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
    }

    /// 2026-09-03 22:35:33 - 22:36:06 (`user.txt:87370-87407`), patch 251: zero for 60 min over 0.2 U/h - the cancel
    /// is answered, the set is not, and the patch never runs it: the reconnect's full status shows the scheduled
    /// basal since the cancel. Kept unreported - it could be running, and have no record yet, until its planned end -
    /// it is dropped once every record was read 15 min past that, never having reached the host.
    func testUnansweredTempBasalTheStatusesNeverShowIsDroppedUnreported() {
        startUnansweredTempBasal()

        link.deliverFullStatus([
            "2f030201000020ee0d800100800000017700fbb4",
            "2f03020200987fd6170e2000700dfd1ed6175134",
            "2f030203dc567700fb0033630000e50c3352"
        ], duringReconnect: true)
        link.notify("202840017700fb00987fd6170e2000700d0010")
        settle()

        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "a segment from before its command says nothing of it")
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal, "it may be running: the next temp basal cancels first")

        // The temp basal the cancel ended has its record; nothing else was written
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 119,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_932_735),
                end: Self.patchTime(399_933_336),
                rate: 0.2,
                delivered: 0.05
            )
        )
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 15 * Self.minute)
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "it may run until its planned end, with no record before")

        // The next loop's status: nothing written since
        advanceClock(by: 59 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 2 * Self.minute)
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(delegate.statusUpdates.last?.status.deliveryIsUncertain, false)
        XCTAssertTrue(reports(of: .tempBasal).allSatisfy { $0.unitsPerHour > 0.1 }, "the zero temp basal never reached the host")
        XCTAssertEqual(delegate.errors.count, 0)
    }

    /// The same unanswered set, the patch running it with no status showing it for 20 min, every record read: it may
    /// still be running, so it has no record yet - kept. A status then shows it: reported from its start on.
    func testUnansweredTempBasalStillRunningIsKeptUntilAStatusShowsIt() {
        let sentAt = startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()

        advanceClock(by: 20 * Self.minute)
        syncRecords()

        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "not dropped while it may run")
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        let batches = delegate.batches.count

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 119,
            patchId: 251,
            start: Self.patchTime(399_933_338),
            rate: 0
        ))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal)
        XCTAssertEqual(confirmed.value, 0)
        XCTAssertEqual(confirmed.pumpStartTime, Self.patchTime(399_933_338))
        XCTAssertGreaterThanOrEqual(confirmed.startDate, sentAt.addingTimeInterval(-MedtrumPumpManager.unansweredStartSlack))
        XCTAssertLessThanOrEqual(confirmed.startDate, sentAt.addingTimeInterval(Self.minute), "from its start, not the status")

        XCTAssertEqual(delegate.batches.count, batches + 1)
        let reported = delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }
        XCTAssertEqual(reported?.isMutable, true)
        XCTAssertEqual(reported?.startDate, confirmed.startDate)
    }

    /// The same unanswered set, kept for 20 min, then cancelled - answered with the scheduled basal from then, and the
    /// record the patch wrote as the cancel ended it: the cancel is when it ended at the latest, and its record, read
    /// right away, makes its one final report
    func testAnsweredCancelEndsTheUnansweredTempBasalAndItsRecordFinalizesIt() throws {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()

        advanceClock(by: 20 * Self.minute)
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        let cancelledAt = Self.patchTime(399_933_337 + 1200)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 120,
            patchId: 251,
            start: cancelledAt
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let pending = try XCTUnwrap(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pending.snapshot.laterSegmentStart, cancelledAt)
        XCTAssertEqual(
            pumpManager.unconfirmedTempBasalEnd(pending).timeIntervalSince1970,
            cancelledAt.addingTimeInterval(-pumpManager.state.patchClockSkew).timeIntervalSince1970,
            accuracy: 0.001
        )

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_338),
                end: cancelledAt,
                rate: 0,
                delivered: 0
            )
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        let zero = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        XCTAssertEqual(zero.count, 1)
        XCTAssertEqual(zero.first?.isMutable, false)
        XCTAssertEqual(zero.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 1199, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
    }

    /// The same, the cancel's answer carrying no new record: it is dropped 15 min after the cancel with every record
    /// read - not 15 min after its planned end
    func testUnansweredTempBasalWithNoRecordIsDroppedFifteenMinutesAfterTheCancel() {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()

        advanceClock(by: 20 * Self.minute)
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 119,
            patchId: 251,
            start: Self.patchTime(399_933_337 + 1200)
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        advanceClock(by: 14 * Self.minute)
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 2 * Self.minute)
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, "36 min in, its planned end 60 min")
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertTrue(reports(of: .tempBasal).allSatisfy { $0.unitsPerHour > 0.1 }, "the zero temp basal never reached the host")
    }

    /// The same, a status showing the scheduled basal since 10 min after the command: had it run, it ended by then. It
    /// is dropped 15 min after that, with every record read.
    func testScheduledBasalShownSinceAfterTheCommandEndsTheUnansweredTempBasal() {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()

        let resumedAt = Self.patchTime(399_933_337 + 600)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 119, patchId: 251, start: resumedAt, rate: 0.7))
        settle()
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.snapshot.laterSegmentStart, resumedAt)

        advanceClock(by: 24 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 2 * Self.minute)
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(reports(of: .tempBasal).allSatisfy { $0.unitsPerHour > 0.1 }, "the zero temp basal never reached the host")
    }

    /// The same, the patch showing it suspended since 10 min after the command, by the time it says it suspended
    func testSuspendTimeShownSinceAfterTheCommandEndsTheUnansweredTempBasal() {
        assertShownSinceAfterTheCommandEndsTheUnansweredTempBasal { suspendedAt in
            PatchBytes.suspendNotification(suspendedAt: suspendedAt)
        }
    }

    /// The same, by the start of the suspend segment it shows
    func testSuspendSegmentShownSinceAfterTheCommandEndsTheUnansweredTempBasal() {
        assertShownSinceAfterTheCommandEndsTheUnansweredTempBasal { suspendedAt in
            PatchBytes.basalNotification(
                type: .SUSPEND_MANUAL,
                sequence: 119,
                patchId: 251,
                start: suspendedAt,
                rate: 0,
                state: .suspended
            )
        }
    }

    /// The same, by a temp basal segment that is not ours - another rate
    func testOtherTempBasalShownSinceAfterTheCommandEndsTheUnansweredTempBasal() {
        assertShownSinceAfterTheCommandEndsTheUnansweredTempBasal { startedAt in
            PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: startedAt, rate: 1.5)
        }
    }

    /// A set of zero going out unanswered while the schedule runs, the last segment we heard of an hour old: right
    /// after the send, a notification shows the scheduled segment the patch restarted (at patch-local midnight, say)
    /// 5 min before the command - after that stale segment, but before the command. It says nothing of the temp basal:
    /// a status then showing it running from 2 s after the command confirms it.
    func testSegmentBegunBeforeTheCommandLeavesTheUnansweredTempBasalToBeConfirmedByAStatus() {
        let patchSentAt = startUnansweredTempBasalAfterAStaleSegment()

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 118,
            patchId: 251,
            start: patchSentAt.addingTimeInterval(2),
            rate: 0
        ))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, "the status shows it running: confirmed")
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal)
        XCTAssertEqual(confirmed.value, 0)
        XCTAssertEqual(confirmed.pumpStartTime, patchSentAt.addingTimeInterval(2))
        XCTAssertEqual(reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }.count, 1)
    }

    /// The same, the next loop cancelling it 5 min on - answered - and its record then read: the record finalizes it,
    /// once
    func testSegmentBegunBeforeTheCommandLeavesTheUnansweredTempBasalToBeFinalizedByItsRecord() throws {
        let patchSentAt = startUnansweredTempBasalAfterAStaleSegment()
        let patchStart = patchSentAt.addingTimeInterval(2)

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 118, patchId: 251, start: patchStart, rate: 0))
        settle()
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)

        let cancelledAt = patchSentAt.addingTimeInterval(300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 119,
            patchId: 251,
            start: cancelledAt
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 119, patchId: 251, type: .ABSOLUTE_TEMP, start: patchStart, end: cancelledAt, rate: 0, delivered: 0)
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized temp basal"), true)
        let zero = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        XCTAssertEqual(Set(zero.compactMap(\.syncIdentifier)).count, 1)
        let final = finals(of: try XCTUnwrap(zero.first))
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 298, accuracy: 0.001)
    }

    /// The same unanswered set, the link lost until after patch-local midnight: the first status shows the temp basal
    /// restarted there, 10 min after the command. It ran from the command on - reported from there - and the patch
    /// split its record at the restart: neither part finalizes it, our estimate does.
    func testUnansweredTempBasalAStatusShowsFromARestartIsReportedFromItsCommandAndFinalizedFromOurEstimate() throws {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()
        let sentAt = try XCTUnwrap(pumpManager.state.unconfirmedTempBasal?.sentAt)

        let restartedAt = Self.patchTime(399_933_337 + 600)
        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: restartedAt, rate: 0))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal)
        XCTAssertEqual(confirmed.startDate, sentAt, "from its command, not from the restart")
        XCTAssertEqual(confirmed.pumpStartTime, restartedAt)
        XCTAssertTrue(confirmed.recordMatchDisabled)
        let reported = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal })
        XCTAssertEqual(reported.startDate, sentAt)
        XCTAssertEqual(reported.isMutable, true)

        // Cancelled 20 min after the command: one record up to the restart, one from it
        let cancelledAt = Self.patchTime(399_933_337 + 1200)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 121,
            patchId: 251,
            start: cancelledAt
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 121)
        let ended = delegate.batches.last?.events.compactMap(\.dose).first { $0.syncIdentifier == reported.syncIdentifier }
        XCTAssertEqual(ended?.isMutable, true)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_338),
                end: restartedAt,
                rate: 0,
                delivered: 0
            )
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 121, patchId: 251, type: .ABSOLUTE_TEMP, start: restartedAt, end: cancelledAt, rate: 0, delivered: 0)
        )
        syncRecords()

        let records = pumpManager.recordStore.records
        XCTAssertEqual(records.first { $0.id == 120 }?.outcome, "unmatched")
        XCTAssertEqual(records.first { $0.id == 121 }?.outcome?.hasPrefix("part of split temp basal"), true)
        XCTAssertEqual(finals(of: reported).count, 0)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()

        let final = finals(of: reported)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.startDate, sentAt)
        XCTAssertEqual(final.first?.endDate, ended?.endDate, "where we saw it end, not where the second record says")
    }

    /// A set of zero that went out unanswered 5 min ago, pending, and the next loop asks for zero again: the cancel is
    /// answered with the scheduled basal from C2, the set with a zero temp basal from that same second. Two temp basals
    /// at one rate, told apart by when they started on the patch clock: a status showing zero from C2 is the new one's;
    /// the record of one started before C2 is the pending one's; the new one's record matches it by its answer's start.
    /// Each reaches the host under its own identity, final once.
    func testSameRateTempBasalOverAnUnansweredOneKeepsTheTwoApart() throws {
        let c2 = Self.patchTime(399_933_337 + 300)
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 119, reservoir: 172.1)
        // Back-dated - the identity of a dose is its start to the second, and the new one starts now
        let sentAt = Date.now.addingTimeInterval(-300)
        let pending = UnfinalizedDose(
            tempRate: 0,
            duration: Self.hour,
            insulinType: nil,
            automatic: true,
            confirmation: .uncertain,
            startDate: sentAt
        )
        pending.noteCommand(sentAt: sentAt, uptime: nil, sequence: 119, priorSegmentStart: Self.patchTime(399_933_336))
        state.unconfirmedTempBasal = pending
        state.basalState = .tempBasal
        state.lastSegmentStart = Self.patchTime(399_933_336)
        alignPatchClock(state, patchTime: c2)
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 120,
            patchId: 251,
            start: c2
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 0,
            sequence: 121,
            patchId: 251,
            start: c2
        ))
        XCTAssertNil(commandTempBasal(0, duration: 30 * Self.minute))
        settle()

        let extended = pumpManager.state.basalDose
        XCTAssertEqual(extended.type, .tempBasal)
        XCTAssertEqual(extended.pumpStartTime, c2)
        XCTAssertTrue(pumpManager.state.unconfirmedTempBasal === pending, "the one before stays pending")
        XCTAssertEqual(pending.snapshot.laterSegmentStart, c2)
        let extendedReport = try XCTUnwrap(
            reports(of: .tempBasal).first { $0.startDate == extended.startDate && $0.unitsPerHour < 0.01 }
        )
        let batches = delegate.batches.count

        // The patch shows zero from C2: the new one, running
        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 121, patchId: 251, start: c2, rate: 0))
        settle()

        XCTAssertTrue(pumpManager.state.basalDose === extended)
        XCTAssertFalse(extended.isFinished)
        XCTAssertTrue(pumpManager.state.unconfirmedTempBasal === pending, "not the pending one")
        XCTAssertEqual(delegate.batches.count, batches)

        // 120: the pending one ran up to C2. 121: the cancel's scheduled segment, 0 s.
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_338), end: c2, rate: 0, delivered: 0)
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 121, patchId: 251, type: .STANDARD, start: c2, end: c2, rate: 0.7, delivered: 0)
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 120 }?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
        XCTAssertTrue(pumpManager.state.basalDose === extended)
        XCTAssertFalse(extended.isFinished)
        XCTAssertFalse(extended.isFinalized)
        XCTAssertEqual(finals(of: extendedReport).count, 0)

        // The new one cancelled 10 min on: its record starts on the start its answer gave
        let c3 = Self.patchTime(399_933_337 + 900)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 122,
            patchId: 251,
            start: c3
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 122, patchId: 251, type: .ABSOLUTE_TEMP, start: c2, end: c3, rate: 0, delivered: 0)
        )
        syncRecords()
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 122 }?.outcome?.hasPrefix("finalized temp basal"), true)

        let zero = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        let identities = Set(zero.compactMap(\.syncIdentifier))
        XCTAssertEqual(identities.count, 2)

        let before = zero.filter { $0.syncIdentifier != extendedReport.syncIdentifier }
        XCTAssertEqual(before.count, 1, "reported once, final")
        XCTAssertEqual(before.first?.isMutable, false)
        XCTAssertEqual(before.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 299, accuracy: 0.001)

        let extendedFinals = finals(of: extendedReport)
        XCTAssertEqual(extendedFinals.count, 1)
        XCTAssertEqual(extendedFinals.first?.startDate, extended.startDate)
        XCTAssertEqual(extendedFinals.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 600, accuracy: 0.001)
    }

    /// A manual 2 h temp basal whose command went unanswered, every record read: not dropped at 60 min - it may run for
    /// another hour. Dropped 15 min past its planned end.
    func testUnansweredTwoHourTempBasalIsNotDroppedAtSixtyMinutes() {
        startUnansweredTempBasal(duration: 2 * Self.hour, automatic: false)
        readTheCancelledTempBasalsRecord()

        advanceClock(by: 61 * Self.minute)
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)

        advanceClock(by: 73 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "14 min past its planned end")

        advanceClock(by: 2 * Self.minute)
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
    }

    /// The same unanswered set, the patch having written a record we cannot read: no time limit - it stays, delivery
    /// uncertain, the link out of reach or not. The patch session ending drops it.
    func testUnansweredTempBasalWaitsForRecordsThatCannotBeReadUntilTheSessionEnds() {
        startUnansweredTempBasal()

        // The patch has written 120
        link.notify("200001" + "7800fb00")
        settle()

        advanceClock(by: 61 * Self.minute)
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 118)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)

        advanceClock(by: 2 * Self.hour)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)

        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertTrue(reports(of: .tempBasal).allSatisfy { $0.unitsPerHour > 0.1 }, "the zero temp basal never reached the host")
    }

    /// The same unanswered set, had the patch run it: a status shows a zero temp basal started after the cancel's
    /// segment - ours. Reported from its start on, and an ordinary running temp basal from there.
    func testUnansweredTempBasalAStatusShowsRunningIsReportedFromItsStart() {
        let sentAt = startUnansweredTempBasal()
        let batches = delegate.batches.count

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 119,
            patchId: 251,
            start: Self.patchTime(399_933_338),
            rate: 0
        ))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)

        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal)
        XCTAssertEqual(confirmed.value, 0)
        XCTAssertEqual(confirmed.pumpStartTime, Self.patchTime(399_933_338))
        XCTAssertGreaterThanOrEqual(confirmed.startDate, sentAt.addingTimeInterval(-MedtrumPumpManager.unansweredStartSlack))
        XCTAssertLessThanOrEqual(confirmed.startDate, Date.now)
        XCTAssertEqual(confirmed.estimatedEndDate.timeIntervalSince(confirmed.startDate), Self.hour, accuracy: 0.001)

        XCTAssertEqual(delegate.batches.count, batches + 1)
        let reported = delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }
        XCTAssertEqual(reported?.isMutable, true)
        XCTAssertEqual(reported?.startDate, confirmed.startDate)
        XCTAssertEqual(reported?.unitsPerHour ?? 1, 0, accuracy: 0.001)
    }

    /// The same unanswered set, had the patch run it for 2 minutes with no status showing it: its record turns up -
    /// a zero temp basal started after the cancel's segment, near when the command went out. Reported once, final.
    func testUnansweredTempBasalItsRecordShowsIsReportedOnceFinal() {
        startUnansweredTempBasal()

        // The patch has written 120
        link.notify("200001" + "7800fb00")
        settle()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 119,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_932_735),
                end: Self.patchTime(399_933_336),
                rate: 0.2,
                delivered: 0.05
            )
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_338),
                end: Self.patchTime(399_933_458),
                rate: 0,
                delivered: 0
            )
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)

        let zero = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        XCTAssertFalse(zero.isEmpty)
        XCTAssertTrue(zero.allSatisfy { !$0.isMutable }, "never reported mutable")
        XCTAssertEqual(Set(zero.compactMap(\.syncIdentifier)).count, 1)
        XCTAssertEqual(zero.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(zero.first?.deliveredUnits ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
    }

    /// The same unanswered set, the patch running it from the very second the cancel's scheduled segment began (a 0 s
    /// STANDARD record, as record 88 in `records-aug.txt`): a status showing it confirms it all the same.
    func testUnansweredTempBasalStartingInTheCancelsSecondIsConfirmedByAStatus() {
        startUnansweredTempBasal()

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 119,
            patchId: 251,
            start: Self.patchTime(399_933_336),
            rate: 0
        ))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal)
        XCTAssertEqual(confirmed.value, 0)
        XCTAssertEqual(confirmed.pumpStartTime, Self.patchTime(399_933_336))
        XCTAssertEqual(delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }?.unitsPerHour, 0)
    }

    /// The same, with no status showing it: its record, starting in the cancel's second, finalizes it
    func testUnansweredTempBasalStartingInTheCancelsSecondIsFinalizedByItsRecord() {
        startUnansweredTempBasal()

        link.notify("200001" + "7800fb00")
        settle()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 119,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_932_735),
                end: Self.patchTime(399_933_336),
                rate: 0.2,
                delivered: 0.05
            )
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_336),
                end: Self.patchTime(399_933_456),
                rate: 0,
                delivered: 0
            )
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let zero = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        XCTAssertEqual(zero.count, 1)
        XCTAssertEqual(zero.first?.isMutable, false)
        XCTAssertEqual(zero.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
    }

    /// 2026-08-02 08:22:41 - 08:22:43 (`user.txt:28394-28402`), patch 237: a notification showing the cancel's
    /// scheduled basal, handled after the new temp basal is registered. It started before the new one did, on the patch
    /// clock: it says nothing of it.
    func testCancelsSegmentShownAfterTheNewTempBasalSaysNothingOfIt() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 118, reservoir: 175.3)
        state.basalDose = runningTempBasal(
            rate: 0.9,
            startedAgo: 5 * Self.minute,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_117_049)
        )
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_117_349))
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "12196a000000010c007700ed00a587ab177c00")
        link.script(CommandType.SET_TEMP_BASAL, fragments: "12186b000000061f007800ed00a687ab179200")
        XCTAssertNil(commandTempBasal(1.55, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writes.last?.encoded(sequence: 0x6B), "0a186b00061f001e009900")
        let running = pumpManager.state.basalDose
        XCTAssertEqual(running.pumpStartTime, Self.patchTime(397_117_350))
        let batches = delegate.batches.count

        link.notify("202800017700ed00a587ab170c2000b10d")
        settle()

        XCTAssertTrue(pumpManager.state.basalDose === running)
        XCTAssertFalse(running.isFinished)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertEqual(delegate.batches.count, batches)
    }

    /// 2026-08-03 03:37:11 - 03:37:17 (`user2.txt` near 35886), patch 237: a manual suspend while 0.6 U/h runs. The
    /// notification right after the answer carries the patch's suspend time: the temp basal ends, and the suspend
    /// starts, there. The resume is dated from the start of the segment the ResumePump answer reports.
    func testManualSuspendIsDatedByThePatchAndTheResumeByItsAnswer() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        let tempBasal = runningTempBasal(
            rate: 0.6,
            startedAgo: 266,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_186_357)
        )
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)
        let skew = pumpManager.state.patchClockSkew

        link.script(
            CommandType.SUSPEND_PUMP,
            .fragments(["071c050000001800"]),
            thenNotify: ["4501133c96ac170302ed00100000000000000000"]
        )
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x05), "071c0500031e6500")
        let suspendedAt = Self.patchTime(397_186_620).addingTimeInterval(-skew)

        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalDose.startDate.timeIntervalSince1970, suspendedAt.timeIntervalSince1970, accuracy: 0.001)

        XCTAssertEqual(delegate.batches.count, 1, "the status reported it; the command adds nothing")
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.suspend, .tempBasal])
        let ended = batch?.events.last?.dose
        XCTAssertEqual(ended?.startDate, tempBasal.startDate)
        XCTAssertEqual(ended?.isMutable, true, "a suspend ends it for good; its record says how much it delivered")
        XCTAssertEqual(ended?.endDate.timeIntervalSince1970 ?? 0, suspendedAt.timeIntervalSince1970, accuracy: 0.001)

        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(link.writes.last?.encoded(sequence: 0x06), "051d06003000")
        let resumedAt = Self.patchTime(397_186_625).addingTimeInterval(-skew)
        let resume = delegate.batches.last?.events.first { $0.dose?.type == .resume }?.dose
        XCTAssertEqual(resume?.startDate.timeIntervalSince1970 ?? 0, min(resumedAt, Date.now).timeIntervalSince1970, accuracy: 0.5)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 515)

        // The scheduled basal the patch then shows: the resume reported already
        let batches = delegate.batches.count
        link.notify("200801010302ed004196ac170c00000402ed00")
        settle()
        XCTAssertEqual(delegate.batches.count, batches)
        XCTAssertEqual(reports(of: .resume).count, 1)
    }

    /// A resume while the driver still takes a temp basal to run (the suspend went unrecorded): the temp basal stopped
    /// at the suspend for good, so it ends at the resume at the latest and waits for its record - not dropped from
    /// what the host holds
    func testResumeEndsATempBasalStillTakenToRun() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        let tempBasal = runningTempBasal(
            rate: 0.6,
            startedAgo: 266,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_186_357)
        )
        state.basalDose = tempBasal
        state.basalState = .suspended
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)
        let skew = pumpManager.state.patchClockSkew

        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        XCTAssertTrue(tempBasal.isFinished)
        XCTAssertTrue(pumpManager.state.awaitingRecord.contains { $0 === tempBasal })

        let resumedAt = min(Self.patchTime(397_186_625).addingTimeInterval(-skew), Date.now)
        let ended = delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }
        XCTAssertEqual(ended?.isMutable, true)
        XCTAssertEqual(ended?.startDate, tempBasal.startDate)
        XCTAssertEqual(ended?.endDate.timeIntervalSince1970 ?? 0, resumedAt.timeIntervalSince1970, accuracy: 0.5)

        // A later replacing batch still holds it
        pumpManager.emitPumpEvents([])
        settle()
        XCTAssertTrue(delegate.batches.last?.events.contains { $0.dose?.syncIdentifier == ended?.syncIdentifier } ?? false)
    }

    /// A status showing a suspend, received before the running temp basal's command went out, says nothing of it: the
    /// temp basal runs on and the basal state stays as it was - not suspended, which would refuse dosing
    func testSuspendShownByAStatusFromBeforeTheTempBasalLeavesItRunning() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        // Its command went out after the status below is received
        var raw = runningTempBasal(rate: 0.6, startedAgo: 0, duration: 30 * Self.minute).rawValue
        raw["sentAt"] = Date.now.addingTimeInterval(Self.minute)
        let tempBasal = UnfinalizedDose(rawValue: raw)!
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)

        link.notify("4501133c96ac170302ed00100000000000000000")
        settle()

        XCTAssertTrue(pumpManager.state.basalDose === tempBasal)
        XCTAssertFalse(tempBasal.isFinished)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertEqual(delegate.batches.count, 0)
    }

    /// A cancel that gets no answer may or may not have stopped the temp basal: it runs on, counted, with delivery
    /// uncertain - until a status shows the scheduled basal since the cancel, which ends it there
    func testUnansweredCancelKeepsTheTempBasalUntilAStatusEndsIt() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 118, reservoir: 175.3)
        let tempBasal = runningTempBasal(
            rate: 0.9,
            startedAgo: 5 * Self.minute,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(397_117_049)
        )
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(397_117_349))
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(1.55, duration: 30 * Self.minute)))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL], "not set over what may still run")
        XCTAssertTrue(pumpManager.state.basalDose === tempBasal)
        XCTAssertFalse(tempBasal.isFinished)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(delegate.batches.count, 0)

        // The scheduled basal since the cancel reached the patch
        link.notify("202800017700ed00a587ab170c2000b10d")
        settle()

        XCTAssertTrue(tempBasal.isFinished)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        let ended = delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }
        XCTAssertEqual(ended?.isMutable, true)
        XCTAssertEqual(
            ended?.endDate.timeIntervalSince1970 ?? 0,
            Self.patchTime(397_117_349).addingTimeInterval(-pumpManager.state.patchClockSkew).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    /// The same unanswered set, every record read - the cursor at the newest record the patch told of before the send -
    /// then the link lost: past its planned end and 15 min more, that is no word on its record, which it would have by
    /// then. Not dropped. Back in reach, the patch says it wrote record 120 - the temp basal's, which finalizes it.
    func testUnansweredTempBasalIsNotDroppedWhileTheLinkIsLostAndItsRecordFinalizesItOnReconnect() {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()

        // The loop's syncs fail: the doses waiting are settled without the link
        advanceClock(by: 76 * Self.minute)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "its record may be written and unread")
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)

        link.notify("200001" + "7800fb00")
        settle()
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_338),
                end: Self.patchTime(399_933_338 + 3600),
                rate: 0,
                delivered: 0
            )
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        let zero = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        XCTAssertEqual(zero.count, 1)
        XCTAssertEqual(zero.first?.isMutable, false)
        XCTAssertEqual(zero.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 3600, accuracy: 0.001)
    }

    /// The same unanswered set, the patch having written record 120 - which comes back unreadable twice, and is
    /// skipped. It could be the temp basal's record: with every other record read, 15 min past its planned end, it is
    /// not dropped - it stays, delivery uncertain, until the patch session ends.
    func testUnansweredTempBasalWhoseRecordMayBeTheOneSkippedIsNotDropped() {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()

        link.notify("200001" + "7800fb00")
        settle()
        let record = PatchBytes.basalRecord(
            sequence: 120,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: Self.patchTime(399_933_338),
            end: Self.patchTime(399_933_338 + 3600),
            rate: 0,
            delivered: 0
        )
        link.script(CommandType.GET_RECORD, .garbled(record))
        link.script(CommandType.GET_RECORD, .garbled(record))
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 120)
        XCTAssertEqual(pumpManager.state.skippedRecordSequences, [120])

        advanceClock(by: 76 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)

        pumpManager.forceDeactivatePatch()
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.skippedRecordSequences, [])
        XCTAssertTrue(reports(of: .tempBasal).allSatisfy { $0.unitsPerHour > 0.1 }, "the zero temp basal never reached the host")
    }

    /// The same unanswered set at 23:35:37 patch-local time (UTC+3), the link lost until a cancel at 00:05:37, answered.
    /// The patch split the temp basal at midnight: record 120 up to midnight, 121 after it. The first is proof it ran,
    /// but only a part: reported from its start on, ended where it ended at the latest - the cancel - and finalized
    /// from our estimate. The second finalizes nothing.
    func testUnansweredTempBasalWhoseRecordEndsAtPatchMidnightIsFinalizedFromOurEstimate() throws {
        let sentAt = startUnansweredTempBasal(patchUTCOffset: 3 * Self.hour)
        readTheCancelledTempBasalsRecord()
        let midnight = Self.patchTime(399_934_800)
        let cancelledAt = Self.patchTime(399_933_337 + 1800)

        advanceClock(by: 30 * Self.minute)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 121,
            patchId: 251,
            start: cancelledAt
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let patchStart = Self.patchTime(399_933_338)
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: patchStart, end: midnight, rate: 0, delivered: 0)
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 121, patchId: 251, type: .ABSOLUTE_TEMP, start: midnight, end: cancelledAt, rate: 0, delivered: 0)
        )
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let records = pumpManager.recordStore.records
        XCTAssertEqual(records.first { $0.id == 120 }?.outcome?.hasPrefix("part of split unconfirmed temp basal"), true)
        XCTAssertEqual(records.first { $0.id == 121 }?.outcome, "unmatched")

        let skew = pumpManager.state.patchClockSkew
        let reported = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 })
        XCTAssertEqual(reported.isMutable, true, "not final from the part")
        XCTAssertGreaterThanOrEqual(reported.startDate, sentAt.addingTimeInterval(-MedtrumPumpManager.unansweredStartSlack))
        XCTAssertLessThanOrEqual(reported.startDate, patchStart.addingTimeInterval(-skew), "from the record's start")
        XCTAssertEqual(finals(of: reported).count, 0)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()

        let final = finals(of: reported)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.startDate, reported.startDate)
        XCTAssertEqual(
            final.first?.endDate.timeIntervalSince1970 ?? 0,
            cancelledAt.addingTimeInterval(-skew).timeIntervalSince1970,
            accuracy: 0.001,
            "up to the cancel - the part up to midnight ends 1462 s in"
        )
    }

    /// The same unanswered set, a status then showing the scheduled basal the cancel before it started (from before
    /// the command): that says nothing of whether the patch runs the temp basal. The next temp basal cancels first.
    func testScheduledBasalFromBeforeTheCommandLeavesTheNextTempBasalToCancelFirst() {
        startUnansweredTempBasal()

        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 119, patchId: 251, start: Self.patchTime(399_933_336), rate: 0.7))
        settle()
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)

        let next = Self.patchTime(399_933_337 + 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 120,
            patchId: 251,
            start: next
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 0.5,
            sequence: 121,
            patchId: 251,
            start: next
        ))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands.suffix(2), [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL])
    }

    /// The same unanswered set, and a basal profile set 30 s later: had the patch run the temp basal, it split it there.
    /// Record 120, of the part before, is proof it ran - but only a part: reported from its start on, finalized from
    /// our estimate up to the cancel. Record 121, of the part after, finalizes nothing.
    func testProfileSetRightAfterAnUnansweredTempBasalLeavesItToOurEstimate() throws {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()
        let profileSetAt = Self.patchTime(399_933_337 + 30)

        XCTAssertNotNil(setBasalProfile(restartingAt: profileSetAt))
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.recordMatchDisabled, true)

        let cancelledAt = Self.patchTime(399_933_337 + 1200)
        advanceClock(by: 20 * Self.minute)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 121,
            patchId: 251,
            start: cancelledAt
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_338),
                end: profileSetAt,
                rate: 0,
                delivered: 0
            )
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 121, patchId: 251, type: .ABSOLUTE_TEMP, start: profileSetAt, end: cancelledAt, rate: 0, delivered: 0)
        )
        syncRecords()

        let records = pumpManager.recordStore.records
        XCTAssertEqual(records.first { $0.id == 120 }?.outcome?.hasPrefix("part of split unconfirmed temp basal"), true)
        XCTAssertEqual(records.first { $0.id == 121 }?.outcome, "unmatched")
        let reported = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 })
        XCTAssertEqual(reported.isMutable, true)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()

        let final = finals(of: reported)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 1200, accuracy: 1.5, "not the 30 s part")
    }

    /// The same, a status then showing the temp basal running since the profile was set: confirmed, it keeps record
    /// matching off - the record of the part after finalizes nothing, our estimate does
    func testProfileSetRightAfterAnUnansweredTempBasalKeepsItsRecordsOffOnceAStatusShowsIt() throws {
        startUnansweredTempBasal()
        readTheCancelledTempBasalsRecord()
        let profileSetAt = Self.patchTime(399_933_337 + 30)
        XCTAssertNotNil(setBasalProfile(restartingAt: profileSetAt))

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 120, patchId: 251, start: profileSetAt, rate: 0))
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(pumpManager.state.basalDose.recordMatchDisabled)
        let reported = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 })

        let cancelledAt = Self.patchTime(399_933_337 + 1200)
        advanceClock(by: 20 * Self.minute)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 121,
            patchId: 251,
            start: cancelledAt
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 120,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_933_338),
                end: profileSetAt,
                rate: 0,
                delivered: 0
            )
        )
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 121, patchId: 251, type: .ABSOLUTE_TEMP, start: profileSetAt, end: cancelledAt, rate: 0, delivered: 0)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 121 }?.outcome?.hasPrefix("part of split temp basal"), true)
        XCTAssertEqual(finals(of: reported).count, 0)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        XCTAssertEqual(finals(of: reported).count, 1)
    }

    /// `user.txt:87370-87380`: 0.2 U/h running, the cancel answered, the set of zero for 60 min not. Returns when
    /// the set went out, about.
    @discardableResult private func startUnansweredTempBasal(
        duration: TimeInterval = MedtrumManagerTestCase.hour,
        automatic: Bool = true,
        patchUTCOffset: TimeInterval? = nil
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
        alignPatchClock(state, patchTime: Self.patchTime(399_933_337))
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
            XCTAssertEqual(link.writes.last?.encoded(sequence: 0x05), "0a1805000600003c005c00")
        }
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 119)

        // What the host is told: the temp basal before ended at the cancel, then the schedule - and nothing of the new one
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.startDate, previous.startDate)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)

        let pending = pumpManager.state.unconfirmedTempBasal
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.value, 0)
        XCTAssertEqual(pending?.snapshot.priorSegmentStart, Self.patchTime(399_933_336))
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal, "the next temp basal cancels first")
        return sentAt
    }

    /// A basal profile set, answered with the segment the patch restarted at `restartingAt`. Returns the schedule set.
    private func setBasalProfile(restartingAt start: Date) -> BasalRateSchedule? {
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

    /// The record of the temp basal the cancel in `startUnansweredTempBasal` ended - the only one written: every record
    /// is read
    private func readTheCancelledTempBasalsRecord() {
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(
                sequence: 119,
                patchId: 251,
                type: .ABSOLUTE_TEMP,
                start: Self.patchTime(399_932_735),
                end: Self.patchTime(399_933_336),
                rate: 0.2,
                delivered: 0.05
            )
        )
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 119)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 119)
    }

    /// The unanswered set of `startUnansweredTempBasal`, every record read, then a status showing - from `notification`
    /// - a segment or a suspend from 10 min after the command, not the temp basal: had it run, it ended by then. It is
    /// dropped 15 min after that.
    private func assertShownSinceAfterTheCommandEndsTheUnansweredTempBasal(
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
    private func startUnansweredTempBasalAfterAStaleSegment() -> Date {
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

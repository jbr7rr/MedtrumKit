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
    /// 0.65 U/h runs - which is a cancel, then a set, then the record the cancel named (built: no log has it)
    func testTempBasalReplacesARunningOne() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 490, reservoir: 119.7)
        let previous = runningTempBasal(
            rate: 0.65,
            startedAgo: 10 * Self.minute,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(396_996_756 - 600)
        )
        state.basalDose = previous
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121907000000010e00eb01ec0094b0a9170300")
        link.script(CommandType.SET_TEMP_BASAL, fragments: "121808000000060000ec01ec0097b0a917f900")
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroTempsPredecessor)

        XCTAssertNil(commandTempBasal(0, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x07), "05190700c500")
        XCTAssertEqual(written(CommandType.SET_TEMP_BASAL)?.encoded(sequence: 0x08), "0a1808000600001e007900")

        // One batch: the old temp basal ended, the new one running. The second or two of scheduled basal
        // the patch ran between the cancel and the set is not reported.
        XCTAssertEqual(delegate.batches.count, 1)
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.replacePendingEvents, true)
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.tempBasal, .tempBasal])

        // Final from its record, the cancel's: 600 s, 0.1 U
        let ended = batch?.events.first?.dose
        XCTAssertEqual(ended?.isMutable, false)
        XCTAssertEqual(ended?.startDate, previous.startDate)
        XCTAssertEqual(ended?.unitsPerHour ?? 0, 0.65, accuracy: 0.001)
        XCTAssertEqual(ended.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(ended?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0, "stored by the host")

        let started = batch?.events.last?.dose
        XCTAssertEqual(started?.isMutable, true)
        XCTAssertEqual(started?.unitsPerHour ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(started.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 30 * Self.minute, accuracy: 0.001)

        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.pumpStartTime, Date(timeIntervalSince1970: 1_785_531_159))
        // 491 from the cancel answer, then 492 from the set's - only 491 is read
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 492)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 491)
    }

    /// The record the cancel of `user.txt:16917` named: the 0.65 U/h temp basal it ended, 10 min long
    private static let recordOfTheZeroTempsPredecessor = PatchBytes.basalRecord(
        sequence: 491,
        patchId: 236,
        type: .ABSOLUTE_TEMP,
        start: patchTime(396_996_756 - 600),
        end: patchTime(396_996_756),
        rate: 0.65,
        delivered: 0.1
    )

    /// A zero duration cancels the running temp basal. No log has one, so the answer is the cancel from
    /// 2026-07-31 22:52:36 (`user.txt:16917`), patch 236, and the record it names is built.
    func testCancellingTheTempBasalGoesBackToTheSchedule() {
        let state = activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 490, reservoir: 119.7)
        let previous = runningTempBasal(
            rate: 0.65,
            startedAgo: 10 * Self.minute,
            duration: 30 * Self.minute,
            pumpStartTime: Self.patchTime(396_996_756 - 600)
        )
        state.basalDose = previous
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121907000000010e00eb01ec0094b0a9170300")
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroTempsPredecessor)

        let commandedAt = Date.now
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD])

        XCTAssertEqual(delegate.batches.count, 1)
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.replacePendingEvents, true)
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.tempBasal, .basal])

        let ended = batch?.events.first?.dose
        XCTAssertEqual(ended?.isMutable, false, "final from its record")
        XCTAssertEqual(ended?.startDate, previous.startDate)
        XCTAssertEqual(ended.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(ended?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 491)

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
    /// wrote: the 0.85 U/h temp basal (944), which the cancel names and is read in the same command - one more round
    /// trip - and the second of scheduled basal between the two commands (945), left to the next sync.
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
        link.script(
            CommandType.GET_RECORD,
            fragments: "276379010000aa2002ff9e75aef7ec00b0030857",
            "276379020fab172b10ab17060011000200110056",
            "276379031fc86ab4b429"
        )

        XCTAssertNil(commandTempBasal(0.6, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x5F), "05195f005400")
        XCTAssertEqual(written(CommandType.SET_TEMP_BASAL)?.encoded(sequence: 0x60), "0a186000060c001e004700")
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 945)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 944)
        XCTAssertEqual(pumpManager.state.basalDose.pumpStartTime, Self.patchTime(397_086_765))

        // One batch: the old one final, the new one running
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [0.85, 0.6])
        let ended = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(ended?.startDate, previous.startDate)
        XCTAssertEqual(delegate.batches.first?.events.last?.dose?.isMutable, true)

        // 944 starts on the patch start the set answered with, to the second: its record. 291 s, 0.1 U - by our
        // estimate it would be 0.05 U.
        let final = finals(of: ended)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(reports(of: .tempBasal).filter { $0.syncIdentifier == ended?.syncIdentifier }.count, 1, "never mutable")
        XCTAssertEqual(final.last?.startDate, previous.startDate)
        XCTAssertEqual(final.last?.unitsPerHour ?? 0, 0.85, accuracy: 0.001)
        XCTAssertEqual(final.last?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(final.last.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 291, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0)
        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized temp basal"), true)

        // 945, the scheduled basal: logged only, by the next sync
        link.script(
            CommandType.GET_RECORD,
            fragments: "27637a010000aa2002ff9e75aef7ec00b1032b37",
            "27637a0210ab172d10ab1701000e0000000c008e",
            "27637a0349cbf5a44c9b"
        )
        syncRecords()

        let records = pumpManager.recordStore.records
        XCTAssertEqual(records.map(\.id), [945, 944])
        XCTAssertNil(records.first?.outcome)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 945)
        XCTAssertEqual(finals(of: ended).count, 1)
        XCTAssertEqual(pumpManager.state.basalDose.type, .tempBasal, "the new one runs on")
    }

    /// 2026-08-01 23:52:45 - 2026-08-02 00:07:42 (`aug12.txt:8590-8784`), patch 236: 0.6 U/h runs across patch-local
    /// midnight (UTC+2), and the patch writes it as two records, 946 up to midnight and 949 after it, with a type-10
    /// record and the TDD between them. The cancel names 949, four past the cursor: all four are read in the command,
    /// and the temp basal is final from both halves - all of its 15 minutes, not the first half's 435 s.
    func testTempBasalAcrossPatchMidnightIsFinalizedFromBothItsRecords() {
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

        // 00:07:39: cancelled - the answer names 949
        link.script(CommandType.CANCEL_TEMP_BASAL, fragments: "121967000000010e00b503ec00ae13ab17b500")
        for fragments in Self.recordsAcrossMidnight {
            link.script(CommandType.GET_RECORD, .fragments(fragments))
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL] + Array(repeating: CommandType.GET_RECORD, count: 4))
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 949)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 949)
        XCTAssertEqual(pumpManager.recordStore.records.map(\.kind), ["BASAL", "TDD", "UNHANDLED", "BASAL"])
        XCTAssertEqual(
            pumpManager.recordStore.records.filter { $0.outcome?.hasPrefix("finalized temp basal") == true }.map(\.id),
            [949, 946]
        )

        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.startDate, tempBasal.startDate)
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 897, accuracy: 0.001)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(finals(of: final).count, 1)
    }

    /// `aug12.txt:8755-8784`: records 946 (0.6 U/h up to midnight), 947 (type 10), 948 (TDD), 949 (0.6 U/h from midnight)
    private static let recordsAcrossMidnight = [
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
    ]

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
        XCTAssertEqual(uncertain.map(\.kind), [.tempBasal])
        XCTAssertEqual(uncertain.first?.cause, .unanswered)
        XCTAssertEqual(uncertain.first?.phase, .notReported)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal, "it may be running: the next temp basal cancels first")

        // The temp basal the cancel ended has its record, read by the sync after the commands; nothing else was written
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
        XCTAssertEqual(uncertain.map(\.phase), [.settled(.neverRan)])
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
        XCTAssertEqual(uncertain.map(\.phase), [.settled(.byRecord)])
        XCTAssertEqual(uncertain.first?.delivered, 0)
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
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 119, patchId: 251, type: .ABSOLUTE_TEMP, start: patchStart, end: cancelledAt, rate: 0, delivered: 0)
        )
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

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
        // The cancel names 121: both are read with it, and neither finalizes it
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
        let cancelSentAt = Date.now
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 121)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 121)

        let records = pumpManager.recordStore.records
        XCTAssertEqual(records.first { $0.id == 120 }?.outcome, "unmatched")
        // Unmatched, or matched to a final not yet stored by the host: either way it finalizes nothing
        XCTAssertNotEqual(records.first { $0.id == 121 }?.outcome?.hasPrefix("finalized"), true)

        // Final at once from our estimate, up to where we saw it end - not where the second record says
        let final = finals(of: reported)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.startDate, sentAt)
        XCTAssertGreaterThanOrEqual(final.first?.endDate ?? .distantPast, cancelSentAt)
        XCTAssertLessThanOrEqual(final.first?.endDate ?? .distantFuture, Date.now)
        XCTAssertEqual(delegate.batches.last?.events.compactMap(\.dose).first?.syncIdentifier, reported.syncIdentifier)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        XCTAssertEqual(finals(of: reported).count, 1)
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
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 122, patchId: 251, type: .ABSOLUTE_TEMP, start: c2, end: c3, rate: 0, delivered: 0)
        )
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
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
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 119)
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
        XCTAssertEqual(uncertain.map(\.phase), [.awaitingRecord], "it ran: final once its record is read")

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
        link.script(CommandType.GET_RECORD, Self.recordOfThe0Point9TempBasal)
        XCTAssertNil(commandTempBasal(1.55, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(written(CommandType.SET_TEMP_BASAL)?.encoded(sequence: 0x6B), "0a186b00061f001e009900")
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
        // The status names 515 the newest record: the temp basal's (514, `records-aug3.txt`) ending at the suspend,
        // then an ALARM - read in the command, once it has its answer
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 514,
            patchId: 237,
            type: .ABSOLUTE_TEMP,
            start: Self.patchTime(397_186_357),
            end: Self.patchTime(397_186_620),
            rate: 0.6,
            delivered: 0.05
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 3, sequence: 515, patchId: 237))
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD, CommandType.GET_RECORD])
        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x05), "071c0500031e6500")
        let suspendedAt = Self.patchTime(397_186_620).addingTimeInterval(-skew)

        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalDose.startDate.timeIntervalSince1970, suspendedAt.timeIntervalSince1970, accuracy: 0.001)

        XCTAssertEqual(delegate.batches.count, 1, "the status reported it; the command adds nothing")
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.tempBasal, .suspend])
        let ended = batch?.events.first?.dose
        XCTAssertEqual(ended?.startDate, tempBasal.startDate)
        XCTAssertEqual(ended?.isMutable, false, "a suspend ends it for good; its record says how much it delivered")
        XCTAssertEqual(ended?.deliveredUnits ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(ended?.endDate.timeIntervalSince1970 ?? 0, suspendedAt.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 515)

        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(written(CommandType.RESUME_PUMP)?.encoded(sequence: 0x06), "051d06003000")
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
    /// at the suspend for good, so it ends at the resume at the latest, final at once from our estimate - no record of
    /// its end is known
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
        XCTAssertTrue(tempBasal.isFinalized)
        XCTAssertEqual(link.writtenCommands, [CommandType.RESUME_PUMP])

        let resumedAt = min(Self.patchTime(397_186_625).addingTimeInterval(-skew), Date.now)
        XCTAssertEqual(delegate.batches.last?.events.map(\.dose?.type), [.tempBasal, .resume])
        let ended = delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }
        XCTAssertEqual(ended?.isMutable, false)
        XCTAssertEqual(ended?.startDate, tempBasal.startDate)
        XCTAssertEqual(ended?.endDate.timeIntervalSince1970 ?? 0, resumedAt.timeIntervalSince1970, accuracy: 0.5)
        // 0.6 U/h for 266 s, by rate × duration
        XCTAssertEqual(ended?.deliveredUnits ?? 0, 0.0, accuracy: 0.001)
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

        // The scheduled basal since the cancel reached the patch: the record it names (119) is read off the queue
        // notifications arrive on, and the temp basal goes out final with the scheduled basal
        link.script(CommandType.GET_RECORD, Self.recordOfThe0Point9TempBasal)
        link.notify("202800017700ed00a587ab170c2000b10d")
        settle()

        XCTAssertTrue(tempBasal.isFinalized)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.last?.events.map(\.dose?.type), [.tempBasal, .basal])
        let ended = delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }
        XCTAssertEqual(ended?.isMutable, false)
        XCTAssertEqual(ended?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(ended.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 119)
    }

    /// The record of the 0.9 U/h temp basal of `user.txt:28394` the cancel there ended: 5 min, built
    private static let recordOfThe0Point9TempBasal = PatchBytes.basalRecord(
        sequence: 119,
        patchId: 237,
        type: .ABSOLUTE_TEMP,
        start: patchTime(397_117_049),
        end: patchTime(397_117_349),
        rate: 0.9,
        delivered: 0.1
    )

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
    /// but only a part: reported from its start on, ended where it ended at the latest - the cancel - and final at once
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
        XCTAssertEqual(reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }.count, 1, "reported once, final")
        XCTAssertGreaterThanOrEqual(reported.startDate, sentAt.addingTimeInterval(-MedtrumPumpManager.unansweredStartSlack))
        XCTAssertLessThanOrEqual(reported.startDate, patchStart.addingTimeInterval(-skew), "from the record's start")

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
        XCTAssertEqual(reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }.count, 1, "reported once, final")

        let final = finals(of: reported)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 1200, accuracy: 1.5, "not the 30 s part")
    }

    /// The same, a status then showing the temp basal running since the profile was set: confirmed, it keeps record
    /// matching off - the records the cancel names finalize nothing, our estimate does, at once
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
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        XCTAssertNotEqual(pumpManager.recordStore.records.first { $0.id == 121 }?.outcome?.hasPrefix("finalized"), true)
        XCTAssertEqual(finals(of: reported).count, 1)

        advanceClock(by: 15 * Self.minute)
        confirmRecordSequence()
        syncRecords()
        XCTAssertEqual(finals(of: reported).count, 1)
    }

    // MARK: - Final as it ends

    /// The record the cancel named times out - one attempt: the temp basal goes out final at once from our estimate,
    /// with the new one. The last status of its segment, 10 min before the cancel, showed 0.1 U delivered (a bolus
    /// paused it): 0.1 U + 1.2 U/h × 10 min = 0.3 U, not its rate × duration of 0.4 U.
    func testTempBasalWhoseRecordCannotBeReadIsFinalizedFromItsLastStatus() {
        let tempBasal = runTempBasalOfOurs()
        notify(
            PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 130, patchId: 251, start: Self.ourStart, rate: 1.2, delivered: 0.1),
            receivedAgo: 10 * Self.minute
        )
        XCTAssertEqual(tempBasal.snapshot.statusDelivery ?? 0, 0.1, accuracy: 0.001)

        let final = replaceItUnread()
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 20 * Self.minute, accuracy: 1)
    }

    /// The same with no status of its segment: its rate × duration, 1.2 U/h × 20 min = 0.4 U
    func testTempBasalWhoseRecordCannotBeReadIsFinalizedFromItsRateAndDuration() {
        runTempBasalOfOurs()

        let final = replaceItUnread()
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
    }

    /// The record the cancel named comes back garbled: it is not asked for again - our estimate stands in, and the
    /// record is left for a sync
    func testTempBasalWhoseRecordComesBackGarbledIsFinalizedFromOurEstimateAfterOneAttempt() {
        runTempBasalOfOurs()
        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, .garbled(recordOfOurTempBasal(delivered: 0.35)))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 130)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.isMutable, false)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
    }

    /// The record the cancel named ends 5 min before the cancel says the temp basal ended: it does not add up to it -
    /// our estimate stands in, not the record's 0.25 U
    func testTempBasalWhoseRecordsDoNotAddUpIsFinalizedFromOurEstimate() {
        runTempBasalOfOurs()
        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131,
            patchId: 251,
            type: .ABSOLUTE_TEMP,
            start: Self.ourStart,
            end: Self.ourEnd.addingTimeInterval(-300),
            rate: 1.2,
            delivered: 0.25
        ))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
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

        let final = replaceItUnread()
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
        // Its one final - sent again with the bolus's if the host had yet to confirm it
        let ended = reports(of: .tempBasal).filter { $0.startDate == tempBasal.startDate && !$0.isMutable }
        XCTAssertFalse(ended.isEmpty)
        XCTAssertTrue(ended.allSatisfy { $0.deliveredUnits == ended.first?.deliveredUnits && $0.endDate == ended.first?.endDate })
        XCTAssertEqual(ended.first?.deliveredUnits ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(ended.first.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 20 * Self.minute, accuracy: 0.001)

        XCTAssertEqual(finals(of: bolus).count, 1)
        XCTAssertEqual(finals(of: bolus).first?.deliveredUnits ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 124)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0)
    }

    /// 2026-08-02 08:22:41 (`user.txt:28394-28402`): the cancel's scheduled basal, shown while the set awaits its answer,
    /// ends the temp basal there - and names its record. The command reads it, then reports the new temp basal in the
    /// same batch: no batch carries the new one before the old one is final, and the old one is never mutable once it
    /// ended.
    func testNewTempBasalNeverGoesOutBeforeTheOldOnesFinalWithTheCancelsSegmentShownMeanwhile() throws {
        let tempBasal = runTempBasalOfOurs()

        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer())
        link.script(CommandType.SET_TEMP_BASAL, .fragments(setAnswer()), thenNotify: [
            PatchBytes.basalNotification(type: .STANDARD, sequence: 131, patchId: 251, start: Self.ourEnd, rate: 0.7),
            "200001" + "8400fb00"
        ])
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        assertNewTempBasalNeverBeforeTheFinal(of: old)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal, .tempBasal])
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
    }

    /// The same order with a batch going out while the record is read - a heartbeat's full status, say: that batch
    /// carries the old temp basal final, from our estimate, with the new one. The record then changes nothing.
    func testNewTempBasalNeverGoesOutBeforeTheOldOnesFinalWithABatchWhileItsRecordIsRead() throws {
        let tempBasal = runTempBasalOfOurs()

        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            pumpManager.emitPumpEvents([])
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate: the batch went out first")
        XCTAssertEqual(finals(of: old).count, 1)
        assertNewTempBasalNeverBeforeTheFinal(of: old)
        XCTAssertNotEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized"), true)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
    }

    /// 2026-10-14 18:21:56 (log 15, patch 270): a heartbeat's full status, its Synchronize on the link ahead of the
    /// record the cancel named, arrives while the command reads it. It shows nothing new - the new temp basal running -
    /// so it hands the host nothing: the old temp basal goes out final from its record, with the new one, in one batch.
    /// The status itself is taken.
    func testFullStatusShowingNothingNewWhileItsRecordIsReadLeavesTheOldTempBasalToItsRecord() throws {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)

        scriptCancelAndSet()
        let batchesDuringRead = Locked<Int?>(nil)
        let syncedByStatus = Locked<Date?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            // Stale, whatever the command's answers made it: only the status moves it now
            pumpManager.state.lastSync = .distantPast
            link.deliverFullStatus(notification: newTempBasalRunning(), duringReconnect: false)
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
            syncedByStatus.value = pumpManager.state.lastSync
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(batchesDuringRead.value, 0, "the status handed the host a batch during the read")
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.5])
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(finals(of: old).count, 1)
        assertNewTempBasalNeverBeforeTheFinal(of: old)
        XCTAssertEqual(delegate.batches.first?.events.last?.dose?.isMutable, true)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
        XCTAssertNotEqual(syncedByStatus.value, .distantPast, "the status was not taken")
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
    }

    /// The same full status, the record the cancel named timing out: our estimate stands in - once, with the new temp
    /// basal after it, from the read's own batch
    func testFullStatusShowingNothingNewWhileItsRecordTimesOutLeavesTheOldTempBasalToTheReadsEstimate() throws {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)

        scriptCancelAndSet()
        let batchesDuringRead = Locked<Int?>(nil)
        link.script(CommandType.GET_RECORD, .timeout) { [unowned self] in
            link.deliverFullStatus(notification: newTempBasalRunning(), duringReconnect: false)
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(batchesDuringRead.value, 0, "the status handed the host a batch during the read")
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.5])
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        XCTAssertEqual(finals(of: old).count, 1)
        assertNewTempBasalNeverBeforeTheFinal(of: old)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
    }

    /// A batch with events of its own still goes out while the record is read - our estimate standing in for the old
    /// temp basal, ahead of them: only an empty refresh waits
    func testBatchWithEventsWhileItsRecordIsReadStillGoesOut() throws {
        let tempBasal = runTempBasalOfOurs()
        let own = NewPumpEvent.replacedPump()

        scriptCancelAndSet()
        let batchesDuringRead = Locked<Int?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            pumpManager.emitPumpEvents([own], unlessTempBasalEndPending: true)
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(batchesDuringRead.value, 1)
        XCTAssertEqual(delegate.batches.first?.events.contains { $0.raw == own.raw }, true)
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate: the batch went out first")
        XCTAssertEqual(finals(of: old).count, 1)
        assertNewTempBasalNeverBeforeTheFinal(of: old)
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

        scriptCancelAndSet()
        let batchesDuringRead = Locked<Int?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            pumpManager.resendUnacknowledgedFinalsIfDue()
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(batchesDuringRead.value, 0, "the resend handed the host a batch during the read")
        XCTAssertEqual(delegate.batches.count, 1)
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        assertNewTempBasalNeverBeforeTheFinal(of: old)
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

        scriptCancelAndSet()
        let batchesDuringRead = Locked<Int?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            pumpManager.raiseCancelledBolus(delivered: 0.3)
            delegate.queue.sync {}
            batchesDuringRead.value = delegate.batches.count
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(bolus.deliveredUnits, 0.3, accuracy: 0.001, "raised")
        XCTAssertEqual(batchesDuringRead.value, 0, "the raise handed the host a batch during the read")
        XCTAssertEqual(delegate.batches.count, 1)
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        assertNewTempBasalNeverBeforeTheFinal(of: old)
        XCTAssertEqual(reports(of: .bolus).filter { $0.startDate == bolus.startDate }.count, 1, "the read's batch carries it")
    }

    /// While the records are read, a heartbeat asks for no full status - its Synchronize would go out on the link
    /// ahead of them - nor for records; once they are, it does again
    func testHeartbeatSyncsNothingWhileTheRecordIsRead() {
        runTempBasalOfOurs()
        pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
        XCTAssertEqual(pumpManager.heartbeatSync(), .full)

        scriptCancelAndSet()
        let duringRead = Locked<MedtrumPumpManager.HeartbeatSync??>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            // Stale, whatever the command's answers made it
            pumpManager.state.lastSync = Date.now.addingTimeInterval(-10 * Self.minute)
            duringRead.value = .some(pumpManager.heartbeatSync())
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
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

        scriptCancelAndSet()
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
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        wait(for: [synced], timeout: 5)
        settle()

        XCTAssertFalse(syncDuringRead.value, "the Synchronize went out while the record was read")
        XCTAssertEqual(
            link.writtenCommands,
            [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SYNCHRONIZE]
        )
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
    }

    /// The patch time, stale, fetched while the command reads the record the cancel named: the same
    func testPatchTimeFetchedDuringTheReadWaitsForIt() throws {
        let tempBasal = runTempBasalOfOurs()

        scriptCancelAndSet()
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
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        wait(for: [fetched], timeout: 5)
        settle()

        XCTAssertFalse(fetchDuringRead.value, "the patch time was asked for while the record was read")
        XCTAssertEqual(
            link.writtenCommands,
            [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD, CommandType.GET_TIME]
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
    func testUnansweredCancelOfATempBasalFinalizedFromOurEstimateIsShownSo() {
        runTempBasalOfOurs()

        link.script(CommandType.CANCEL_TEMP_BASAL, .timeout)
        guard case .uncertainDelivery? = commandTempBasal(0.5, duration: 30 * Self.minute) else {
            XCTFail("Not uncertain")
            return
        }
        settle()

        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(uncertain.map(\.phase), [.settled(.byEstimate)])
        XCTAssertEqual(uncertain.first?.delivered ?? 0, 0.4, accuracy: 0.001, "our estimate")
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
        XCTAssertEqual(finals(of: old).count, 1)
        XCTAssertEqual(delegate.batches.count, batches)
        XCTAssertNotEqual(pumpManager.recordStore.records.first { $0.id == 131 }?.outcome?.hasPrefix("finalized"), true)
    }

    // MARK: - While the records are read

    /// The host has the state before the command reads the record the cancel named: the app killed during the read
    /// comes back with the new temp basal running - 0.5 U/h, not the old 1.2 U/h - and the old one ended at the cancel,
    /// which its first batch reports final from our estimate, with the new one
    func testStateTheHostHasDuringTheReadRestartsWithTheNewTempBasal() throws {
        let tempBasal = runTempBasalOfOurs()
        scriptCancelAndSet()
        let savedDuringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            savedDuringRead.value = delegate.savedState
        }
        let cancelSentAt = Date.now
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        // Killed during the read: what the host saved then is what the app comes back with
        let restored = MedtrumPumpState(rawValue: try XCTUnwrap(savedDuringRead.value, "no state handed over before the read"))
        XCTAssertEqual(restored.basalDose.type, .tempBasal)
        XCTAssertEqual(restored.basalDose.value, 0.5)
        XCTAssertFalse(restored.basalDose.isFinished)
        XCTAssertEqual(restored.basalState, .tempBasal)
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
        XCTAssertEqual(events.map(\.unitsPerHour), [1.2, 0.5])
        XCTAssertEqual(events.first?.isMutable, false)
        XCTAssertEqual(events.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
        XCTAssertEqual(events.last?.isMutable, true)
    }

    /// The cancel's scheduled basal, shown during the read the command does under the command lock, arrives on the queue
    /// statuses do and waits for nothing: it is from before the new temp basal, which runs on - one batch
    func testCancelsSegmentShownDuringTheReadLeavesTheNewTempBasalRunning() throws {
        let tempBasal = runTempBasalOfOurs()
        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 131, patchId: 251, start: Self.ourEnd, rate: 0.7))
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)
        XCTAssertFalse(pumpManager.state.basalDose.isFinished)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.5])
        let old = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(old?.startDate, tempBasal.startDate)
        XCTAssertEqual(old?.isMutable, false)
        XCTAssertEqual(old?.deliveredUnits ?? 0, 0.35, accuracy: 0.001)
        XCTAssertNil(pumpManager.pendingTempBasalEnd)
    }

    /// A bolus asked for while the temp basal command reads the two records the cancel named waits for that command to
    /// settle: no record is read once the bolus went out
    func testBolusAskedForDuringTheReadGoesOutOnceTheTempBasalIsSettled() throws {
        let tempBasal = runTempBasalOfOurs(patchId: 236)
        scriptCancelAndSet(patchId: 236, cancelRecord: 132)
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")

        let bolusDone = expectation(description: "enactBolus")
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 236))) { [unowned self] in
            pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { _ in bolusDone.fulfill() }
            // The time a device gives it to go out
            giveTime { self.link.writtenCommands.contains(CommandType.SET_BOLUS) }
        }
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(patchId: 236, sequence: 132, delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        wait(for: [bolusDone], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [
            CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD, CommandType.GET_RECORD,
            CommandType.SET_BOLUS
        ])
        let old = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate }).first)
        XCTAssertEqual(old.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
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

    /// The record the cancel named times out: the read waits for what is left of its 10 s, not a write's 30 s
    func testReadThatTimesOutTakesNoMoreThanItsBudget() {
        runTempBasalOfOurs()
        link.onTimeout = { [unowned self] waited in advanceClock(by: waited) }

        let final = replaceItUnread()

        XCTAssertLessThanOrEqual(written(CommandType.GET_RECORD)?.timeout ?? .infinity, MedtrumPumpManager.tempBasalEndReadBudget)
        XCTAssertLessThanOrEqual(clockOffset.value, MedtrumPumpManager.tempBasalEndReadBudget)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "by our estimate")
    }

    /// The cancel names 132: 131 takes 11 s to come back, and 132 is not asked for - our estimate stands in. 131 is kept
    /// as any record read is.
    func testReadStopsWhereItsBudgetRunsOutKeepingWhatItRead() {
        runTempBasalOfOurs()
        scriptCancelAndSet(cancelRecord: 132)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 251))) { [unowned self] in
            advanceClock(by: 11)
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
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
        scriptCancelAndSet()

        let started = Date.now
        RecordSyncer.whileRunningForTesting {
            XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        }
        XCTAssertLessThan(Date.now.timeIntervalSince(started), RecordSyncer.inCommandRunWait + 1.5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 130)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.5])
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.isMutable, false)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
    }

    /// A record sync is running as the command would read - the loop's own, which its follow-up started just before:
    /// it stops at its next record, seeing the command, and the read waits the moment that takes
    func testReadWaitsForARecordSyncRunningToStop() {
        runTempBasalOfOurs()
        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))

        let running = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [unowned self] in
            RecordSyncer.whileRunningForTesting {
                running.signal()
                giveTime(timeout: 5) { self.link.writtenCommands.contains(CommandType.SET_TEMP_BASAL) }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        running.wait()
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 131)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
    }

    /// The cancel names 132: 131 comes back with less than a round trip of the budget left, and 132 is not asked for
    /// only to be given up on - our estimate stands in
    func testReadAsksForNoRecordWithLessThanARoundTripOfItsBudgetLeft() {
        runTempBasalOfOurs()
        scriptCancelAndSet(cancelRecord: 132)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 251))) { [unowned self] in
            advanceClock(by: MedtrumPumpManager.tempBasalEndReadBudget - 1)
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
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
        scriptCancelAndSet(cancelRecord: 132)
        let release = DispatchSemaphore(value: 0)
        link.script(CommandType.GET_RECORD, .fragments(PatchBytes.otherRecord(type: 10, sequence: 131, patchId: 251))) { [unowned self] in
            advanceClock(by: MedtrumPumpManager.tempBasalEndReadBudget - 2.5)
            link.holdWriter(until: release)
        }

        let started = Date.now
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        let took = Date.now.timeIntervalSince(started)
        release.signal()
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
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

    /// The host is slow to take the state before the read: the time that takes is not taken from the read's budget
    func testHandOverBeforeTheReadIsNotCountedInItsBudget() {
        runTempBasalOfOurs()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer())
        link.script(CommandType.SET_TEMP_BASAL, .fragments(setAnswer())) { [unowned self] in
            delegate.queue.async { Thread.sleep(forTimeInterval: 1) }
        }
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertGreaterThan(written(CommandType.GET_RECORD)?.timeout ?? 0, MedtrumPumpManager.tempBasalEndReadBudget - 0.5)
    }

    /// A suspend while a temp basal runs, the patch's status of it not in yet: no record of the temp basal's end is
    /// known, nothing is read, and the command does not wait for a busy host to take the state first
    func testSuspendWithNothingToReadDoesNotWaitForTheHost() {
        runTempBasalOfOurs()
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"])) { [unowned self] in
            delegate.queue.async { Thread.sleep(forTimeInterval: 2) }
        }

        let started = Date.now
        XCTAssertNil(commandSuspend())
        let took = Date.now.timeIntervalSince(started)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP])
        XCTAssertLessThan(took, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .suspend])
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.isMutable, false)
    }

    /// The cancel's scheduled basal shown before the set is answered ended the temp basal there: the command still has
    /// the new temp basal in the state the host takes before the read - one handover, one read - and one batch carries
    /// the final, the scheduled basal and the new temp basal. Killed during the read, the app comes back with the new
    /// temp basal running.
    func testStateTheHostHasDuringTheReadHasTheNewTempBasalWithTheCancelsSegmentShownFirst() throws {
        let tempBasal = runTempBasalOfOurs()
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer())
        link.script(CommandType.SET_TEMP_BASAL, .fragments(setAnswer())) { [unowned self] in
            link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 131, patchId: 251, start: Self.ourEnd, rate: 0.7))
        }
        let savedDuringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            savedDuringRead.value = delegate.savedState
        }
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD])
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.7, 0.5])
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.5)

        let restored = MedtrumPumpState(rawValue: try XCTUnwrap(savedDuringRead.value, "no state handed over before the read"))
        XCTAssertEqual(restored.basalDose.type, .tempBasal)
        XCTAssertEqual(restored.basalDose.value, 0.5)
        XCTAssertFalse(restored.basalDose.isFinished)
        XCTAssertEqual(restored.basalState, .tempBasal)
        let ended = try XCTUnwrap(restored.awaitingRecord.first { $0.type == .tempBasal })
        XCTAssertEqual(ended.startDate, tempBasal.startDate)
        XCTAssertTrue(ended.isFinished)
        XCTAssertFalse(ended.isFinalized)

        let host = FakePumpManagerDelegate()
        let restarted = MedtrumPumpManager(state: restored, link: FakeMedtrumLink())
        restarted.delegateQueue = host.queue
        restarted.pumpManagerDelegate = host
        restarted.emitPumpEvents([])
        host.queue.sync {}

        let events = try XCTUnwrap(host.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(events.map(\.unitsPerHour), [1.2, 0.5])
        XCTAssertEqual(events.first?.isMutable, false)
        XCTAssertEqual(events.last?.isMutable, true)
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
        link.script(CommandType.GET_RECORD, .fragments(recordOfOurTempBasal(delivered: 0.35))) { [unowned self] in
            link.onQueue {
                self.pumpManager.handleBaseReset(deliveryStoppedAt: Date.now)
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
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 897, accuracy: 0.001)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(finals(of: final).count, 1)
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
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.1, accuracy: 0.001, "its rate × duration: 0.6 U/h × 897 s")
    }

    /// Where our temp basal started, on the patch clock, and where the cancel ended it 20 min later
    private static let ourStart = patchTime(400_000_000)
    private static let ourEnd = patchTime(400_001_200)

    /// 1.2 U/h of ours, 30 min, running for 20 min, every record read up to `sequence`
    @discardableResult private func runTempBasalOfOurs(patchId: UInt64 = 251, sequence: Int = 130) -> UnfinalizedDose {
        let state = activePatchState(patchId: patchId, scheduledRate: 0.7, sequence: sequence, reservoir: 150)
        let tempBasal = runningTempBasal(rate: 1.2, startedAgo: 20 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.ourStart)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.ourEnd)
        makeManager(state)
        return tempBasal
    }

    /// The cancel of it, answered with the scheduled basal from `ourEnd` and the number of its record
    private func cancelAnswer(patchId: UInt64 = 251, record: Int = 131) -> [String] {
        PatchBytes.segmentAnswer(command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: record, patchId: patchId, start: Self.ourEnd)
    }

    /// The set of 0.5 U/h after it, answered with the scheduled basal's record
    private func setAnswer(patchId: UInt64 = 251, record: Int = 132) -> [String] {
        PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 0.5,
            sequence: record,
            patchId: patchId,
            start: Self.ourEnd.addingTimeInterval(1)
        )
    }

    private func scriptCancelAndSet(patchId: UInt64 = 251, cancelRecord: Int = 131) {
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(patchId: patchId, record: cancelRecord))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(patchId: patchId, record: cancelRecord + 1))
    }

    private func recordOfOurTempBasal(patchId: UInt64 = 251, sequence: Int = 131, delivered: Double) -> [String] {
        PatchBytes.basalRecord(
            sequence: sequence,
            patchId: patchId,
            type: .ABSOLUTE_TEMP,
            start: Self.ourStart,
            end: Self.ourEnd,
            rate: 1.2,
            delivered: delivered
        )
    }

    /// The new temp basal of 0.5 U/h running from just after `ourEnd`, as a status shows it
    private func newTempBasalRunning() -> String {
        PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 132, patchId: 251, start: Self.ourEnd.addingTimeInterval(1), rate: 0.5)
    }

    /// Cancels and replaces it, the record the cancel names timing out. Returns its final.
    private func replaceItUnread(file: StaticString = #filePath, line: UInt = #line) -> DoseEntry? {
        let tempBasal = pumpManager.state.basalDose
        scriptCancelAndSet()
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute), file: file, line: line)
        settle()

        XCTAssertEqual(
            link.writtenCommands,
            [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD],
            "asked for once",
            file: file,
            line: line
        )
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 130, "left for a sync", file: file, line: line)
        XCTAssertEqual(delegate.batches.count, 1, file: file, line: line)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [1.2, 0.5], file: file, line: line)
        XCTAssertEqual(delegate.batches.first?.events.last?.dose?.isMutable, true, file: file, line: line)

        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false, file: file, line: line)
        XCTAssertEqual(final?.startDate, tempBasal.startDate, file: file, line: line)
        return final
    }

    /// The 0.6 U/h temp basal of `testTempBasalAcrossPatchMidnightIsFinalizedFromBothItsRecords`, every record up to 945
    /// read, the patch having written up to 948 - as the loop's full status says
    @discardableResult private func runTempBasalAcrossPatchMidnight() -> UnfinalizedDose {
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
    @discardableResult private func giveTime(timeout: TimeInterval = 1, until condition: () -> Bool) -> Bool {
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
    private func notify(_ hex: String, receivedAgo: TimeInterval) {
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

    /// No batch carries the temp basal of 0.5 U/h before `final` went out, nor the one `final` is of as mutable after
    private func assertNewTempBasalNeverBeforeTheFinal(of final: DoseEntry, file: StaticString = #filePath, line: UInt = #line) {
        let batches = delegate.batches.map { $0.events.compactMap(\.dose) }
        let finalAt = batches.firstIndex { $0.contains { $0.syncIdentifier == final.syncIdentifier && !$0.isMutable } }
        let newAt = batches.firstIndex { $0.contains { $0.type == .tempBasal && $0.unitsPerHour == 0.5 } }
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
            XCTAssertEqual(written(CommandType.SET_TEMP_BASAL)?.encoded(sequence: 0x05), "0a1805000600003c005c00")
        }
        // The cancel names the record of the temp basal it ended, but the set went unanswered: it is not read on that
        // link
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.SET_TEMP_BASAL])
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 119)
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 118)

        // What the host is told: the temp basal before ended at the cancel, final from our estimate - 0.2 U/h × 10 min,
        // floored - then the schedule, and nothing of the new one
        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.startDate, previous.startDate)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.isMutable, false)
        XCTAssertEqual(delegate.batches.first?.events.first?.dose?.deliveredUnits ?? 1, 0, accuracy: 0.001)
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
    private func readTheCancelledTempBasalsRecord() {
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 119)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 119)
    }

    /// The last command of `type` written
    private func written(_ type: UInt8) -> FakeMedtrumLink.Write? {
        link.writes.last { $0.commandType == type }
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

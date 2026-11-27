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
    /// 0.65 U/h runs - which is a cancel, then a set - then, once the command is over, the record the cancel named
    /// (built: no log has it)
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

        // The command's batch: the old temp basal ended where the new one starts, mutable, the new one running. The
        // second or two of scheduled basal the patch ran between the cancel and the set is not reported.
        XCTAssertEqual(delegate.batches.count, 2)
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.replacePendingEvents, true)
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.tempBasal, .tempBasal])
        let open = batch?.events.first?.dose
        XCTAssertEqual(open?.isMutable, true)
        XCTAssertEqual(open?.startDate, previous.startDate)
        XCTAssertEqual(open?.endDate, batch?.events.last?.dose?.startDate, "ended exactly where the new one starts")

        // The read's: final from its record, the cancel's - 0.1 U - ending where the new one starts, which runs on
        XCTAssertEqual(delegate.batches.last?.events.map(\.dose?.type), [.tempBasal, .tempBasal])
        let ended = delegate.batches.last?.events.first?.dose
        XCTAssertEqual(ended?.isMutable, false)
        XCTAssertEqual(ended?.startDate, previous.startDate)
        XCTAssertEqual(ended?.unitsPerHour ?? 0, 0.65, accuracy: 0.001)
        XCTAssertEqual(ended?.endDate, open?.endDate)
        XCTAssertEqual(ended.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 600, accuracy: 1)
        XCTAssertEqual(ended?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0, "stored by the host")
        XCTAssertEqual(delegate.batches.last?.events.last?.dose?.isMutable, true)

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
        XCTAssertEqual(ended.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 600, accuracy: 1)
        XCTAssertEqual(ended?.endDate, batch?.events.last?.dose?.startDate, "ends where the schedule starts")
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
    /// wrote: the 0.85 U/h temp basal (944), which the cancel names and is read once the command is over - one more
    /// round trip, which the command does not wait for - and the second of scheduled basal between the two commands
    /// (945), left to the next sync.
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

        // The command's batch: the old one ended where the new one starts, mutable, the new one running - then the
        // read's, the old one final
        XCTAssertEqual(delegate.batches.count, 2)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.unitsPerHour), [0.85, 0.6])
        let ended = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(ended?.startDate, previous.startDate)
        XCTAssertEqual(ended?.isMutable, true)
        XCTAssertEqual(delegate.batches.first?.events.last?.dose?.isMutable, true)
        XCTAssertEqual(delegate.batches.last?.events.map(\.dose?.unitsPerHour), [0.85, 0.6])

        // 944 starts on the patch start the set answered with, to the second: its record. 291 s, 0.1 U - by our
        // estimate it would be 0.05 U.
        let final = finals(of: ended)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(reports(of: .tempBasal).filter { $0.syncIdentifier == ended?.syncIdentifier }.count, 2, "mutable, then final")
        XCTAssertEqual(final.last?.startDate, previous.startDate)
        XCTAssertEqual(final.last?.unitsPerHour ?? 0, 0.85, accuracy: 0.001)
        XCTAssertEqual(final.last?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(final.last.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 291, accuracy: 1)
        XCTAssertEqual(final.last?.endDate, ended?.endDate, "where the new one starts")
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
        assertOneFinal(of: ended)
        XCTAssertEqual(pumpManager.state.basalDose.type, .tempBasal, "the new one runs on")
    }

    /// 2026-08-01 23:52:45 - 2026-08-02 00:07:42 (`aug12.txt:8590-8784`), patch 236: 0.6 U/h runs across patch-local
    /// midnight (UTC+2), and the patch writes it as two records, 946 up to midnight and 949 after it, with a type-10
    /// record and the TDD between them. The cancel names 949, four past the cursor: all four are read in the command,
    /// and the temp basal is final from both halves - all of its 15 minutes, not the first half's 435 s.
    func testTempBasalAcrossPatchMidnightIsFinalizedFromBothItsRecords() {
        freezesManagerClock = true
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
        XCTAssertEqual(pumpManager.recordStore.records.map(\.kind), ["BASAL", "TDD", "DAILY", "BASAL"])
        XCTAssertEqual(pumpManager.recordStore.records.map(\.label), [nil, nil, "Daily snapshot · UTC+2", nil])
        XCTAssertEqual(
            pumpManager.recordStore.records.filter { $0.outcome?.hasPrefix("finalized temp basal") == true }.map(\.id),
            [949, 946]
        )

        XCTAssertEqual(delegate.batches.count, 1)
        XCTAssertEqual(delegate.batches.first?.events.map(\.dose?.type), [.tempBasal, .basal])
        let final = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(final?.isMutable, false)
        XCTAssertEqual(final?.startDate, tempBasal.startDate)
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 897, accuracy: 1)
        XCTAssertEqual(final?.endDate, delegate.batches.first?.events.last?.dose?.startDate, "ends where the schedule starts")
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        assertOneFinal(of: final)
    }

    /// `aug12.txt:8755-8784`: records 946 (0.6 U/h up to midnight), 947 (type 10), 948 (TDD), 949 (0.6 U/h from midnight)
    static let recordsAcrossMidnight = [
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

        // Up to the cancel at 1537 on the patch clock: 1201 s after the cancel's segment before the unanswered set (336)
        advanceClock(by: 20 * Self.minute + 1)
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
        // The record the cancel names, had the unanswered one run, read after the command: not yet written here
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let pending = try XCTUnwrap(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pending.snapshot.laterSegmentStart, cancelledAt)
        // From the cancel's segment before it went out, on each clock alone
        let basalBefore = try XCTUnwrap(pending.snapshot.basalBefore)
        let basalBeforeOnPatch = try XCTUnwrap(pending.snapshot.basalBeforeOnPatch)
        XCTAssertEqual(
            pumpManager.unconfirmedTempBasalEnd(pending).timeIntervalSince1970,
            basalBefore.addingTimeInterval(cancelledAt.timeIntervalSince(basalBeforeOnPatch)).timeIntervalSince1970,
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

        // The cancel at 1537 on the patch clock: 1201 s after the cancel's segment before the unanswered set (336)
        advanceClock(by: 20 * Self.minute + 1)
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
        // The record's 298 s on the patch clock, which alone moved here: the final ends where the schedule after it starts
        XCTAssertEqual(final.first?.endDate, reports(of: .basal).last?.startDate)
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
        assertOneFinal(of: reported)
    }

    /// A set of zero that went out unanswered 5 min ago, pending, and the next loop asks for zero again: the cancel is
    /// answered with the scheduled basal from C2, the set with a zero temp basal from that same second. Two temp basals
    /// at one rate, told apart by when they started on the patch clock: a status showing zero from C2 is the new one's;
    /// the record of one started before C2 is the pending one's - read in the command, before the set; the new one's
    /// record matches it by its answer's start. Each reaches the host under its own identity, final once.
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
        // 120, the record the cancel names: the pending one ran up to C2 - read in the command, before the set
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_338), end: c2, rate: 0, delivered: 0)
        )
        XCTAssertNil(commandTempBasal(0, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL])
        let extended = pumpManager.state.basalDose
        XCTAssertEqual(extended.type, .tempBasal)
        XCTAssertEqual(extended.pumpStartTime, c2)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, "the one before final from its record")
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 120 }?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
        let extendedReport = try XCTUnwrap(
            reports(of: .tempBasal).first { $0.startDate == extended.startDate && $0.unitsPerHour < 0.01 }
        )
        let batches = delegate.batches.count

        // The patch shows zero from C2: the new one, running
        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 121, patchId: 251, start: c2, rate: 0))
        settle()

        XCTAssertTrue(pumpManager.state.basalDose === extended)
        XCTAssertFalse(extended.isFinished)
        XCTAssertEqual(delegate.batches.count, batches)

        // 121: the cancel's scheduled segment, 0 s
        link.script(
            CommandType.GET_RECORD,
            PatchBytes.basalRecord(sequence: 121, patchId: 251, type: .STANDARD, start: c2, end: c2, rate: 0.7, delivered: 0)
        )
        syncRecords()

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
        // The record's 600 s on the patch clock, which alone moved here: the final ends where the schedule after it starts
        XCTAssertEqual(extendedFinals.first?.endDate, reports(of: .basal).last?.startDate)
        // The pending one final before the new one was first reported: counted, nothing warned of
        let pendingFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.syncIdentifier == before.first?.syncIdentifier } }
        let extendedFirst = delegate.batches.firstIndex { $0.events.contains { $0.dose?.syncIdentifier == extendedReport.syncIdentifier } }
        XCTAssertLessThan(pendingFinal ?? .max, extendedFirst ?? -1)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
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
        let written = pumpManager.state.unconfirmedTempBasal?.snapshot

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
        // When its command was written, as the unconfirmed one had it
        XCTAssertNotNil(written?.writtenAt)
        XCTAssertEqual(confirmed.snapshot.writtenAt, written?.writtenAt)
        XCTAssertEqual(confirmed.snapshot.writtenUptime, written?.writtenUptime)

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
}

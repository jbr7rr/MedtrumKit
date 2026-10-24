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
        XCTAssertEqual(finals(of: ended).count, 1)
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
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 897, accuracy: 1)
        XCTAssertEqual(final?.endDate, delegate.batches.first?.events.last?.dose?.startDate, "ends where the schedule starts")
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
        XCTAssertEqual(finals(of: reported).count, 1)
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

    // MARK: - The temp basal whose command went unanswered, and the ones after it

    /// `startUnansweredTempBasal`, then 1 U/h set - its cancel names 120, the zero temp basal's record had it run, read in
    /// the command before the set: `inCommand` - and answered. Unread there, it is read again after the command:
    /// `afterCommand`
    private func setAfterTheUnansweredTempBasal(
        inCommand: FakeMedtrumLink.Answer,
        afterCommand: FakeMedtrumLink.Answer? = nil,
        patchUTCOffset: TimeInterval? = nil,
        advancingClock: TimeInterval = 0
    ) {
        startUnansweredTempBasal(patchUTCOffset: patchUTCOffset)
        // Our clock up to the cancel, as the patch has it: 301 s after the cancel's segment before the zero one
        advanceClock(by: advancingClock)
        let c1 = Self.patchTime(399_933_337 + 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: c1
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: c1.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, inCommand)
        if let afterCommand {
            link.script(CommandType.GET_RECORD, afterCommand)
        }
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()
    }

    /// Records 120 - 124: the zero temp basal, run from the cancel's second before it up to the cancel `c1`, the second of schedule, the 1 U/h one up to `c2`,
    /// the second of schedule, the 2 U/h one up to `c3`
    private static let c1 = patchTime(399_933_337 + 300)
    private static let c2 = c1.addingTimeInterval(300)
    private static let c3 = c2.addingTimeInterval(300)
    private static let recordOfTheZero = PatchBytes.basalRecord(
        sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: patchTime(399_933_336), end: c1, rate: 0, delivered: 0
    )
    private static let recordOfTheOne = PatchBytes.basalRecord(
        sequence: 122, patchId: 251, type: .ABSOLUTE_TEMP, start: c1.addingTimeInterval(1), end: c2, rate: 1, delivered: 0.1
    )
    private static func secondOfSchedule(_ sequence: Int, at start: Date) -> [String] {
        PatchBytes.basalRecord(sequence: sequence, patchId: 251, type: .STANDARD, start: start, end: start.addingTimeInterval(1), rate: 0.7, delivered: 0)
    }

    /// The 1 U/h one replaced by 2 U/h back to back - its cancel names 122 - the read after the command timing out
    private func replaceTheOneByTwo() {
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: Self.c2
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 2, sequence: 123, patchId: 251, start: Self.c2.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(2, duration: 30 * Self.minute))
        settle()
    }

    /// The cancel ahead of the 1 U/h one names the zero one's record: read in that command, before the set - the zero one
    /// final ahead of the 1 U/h one's first report, counted. The 1 U/h one, cancelled later, goes final from its own.
    func testUnansweredTempBasalsRecordReadBeforeTheNextSetGoesFinalBeforeIt() throws {
        setAfterTheUnansweredTempBasal(inCommand: .fragments(Self.recordOfTheZero), advancingClock: 302)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: Self.c2
        ))
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.unitsPerHour), [1, 0.7])
        XCTAssertEqual(batch.map(\.isMutable), [false, false])
        XCTAssertEqual(batch[0].deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 120 }?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
        assertCountedAheadOfTheOne()
    }

    /// The zero one final from its record, read in the command before the 1 U/h one was set, in a batch ahead of that
    /// one's first report: counted - nothing warned of, Loop's view (the checker, on) has nothing behind its watermark
    private func assertCountedAheadOfTheOne(byRecord: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            Array(link.writtenCommands.prefix(6).suffix(3)),
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL],
            "read between the cancel and the set",
            file: file,
            line: line
        )
        let zeroFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 0 && $0.dose?.isMutable == false } }
        let oneFirst = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 1 } }
        XCTAssertNotNil(zeroFinal, file: file, line: line)
        XCTAssertLessThan(zeroFinal ?? .max, oneFirst ?? -1, "final before the 1 U/h one's first report", file: file, line: line)
        XCTAssertEqual(uncertainDeliveryErrors, 0, "nothing warned of", file: file, line: line)
        XCTAssertFalse(uncertain.contains { $0.phase == .settled(.notCounted) }, file: file, line: line)
        if byRecord {
            XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.byRecord) }, file: file, line: line)
        }
    }

    /// The same with a third, 2 U/h, after the 1 U/h one back to back: the zero one final before either, counted; the
    /// two final from their own records as the 2 U/h one is cancelled
    func testUnansweredTempBasalsRecordReadBeforeTheNextSetGoesFinalBeforeTwoLaterOnes() throws {
        setAfterTheUnansweredTempBasal(inCommand: .fragments(Self.recordOfTheZero), advancingClock: 302)
        advanceClock(by: 300)
        replaceTheOneByTwo()

        advanceClock(by: 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 124, patchId: 251, start: Self.c3
        ))
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(123, at: Self.c2))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 124, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.c2.addingTimeInterval(1), end: Self.c3, rate: 2, delivered: 0.15
        ))
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(batch.map(\.unitsPerHour), [1, 2, 0.7])
        XCTAssertEqual(batch.map(\.isMutable), [false, false, false])
        assertCountedAheadOfTheOne()
    }

    /// The cancel after the unanswered set names its record: read in that command, between the cancel and the set - the
    /// 1 U/h one reported after it, running
    func testUnansweredTempBasalsRecordTheCancelAfterItNamesIsReadBeforeTheSet() throws {
        setAfterTheUnansweredTempBasal(inCommand: .fragments(Self.recordOfTheZero), advancingClock: 302)

        XCTAssertEqual(link.writtenCommands.suffix(3), [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 })
        XCTAssertEqual(zero.isMutable, false)
        XCTAssertTrue(reports(of: .tempBasal).filter { $0.unitsPerHour == 1 }.allSatisfy(\.isMutable), "nothing after it final before it")
        assertCountedAheadOfTheOne()
    }

    /// A status shows the schedule from a segment begun after the unanswered set - it ran 120 s, if at all - and the next
    /// set goes out with no cancel before it: the patch's newest record, 120, is read in that command first, the zero
    /// one final from it ahead of the new one's first report
    func testUnansweredTempBasalsRecordIsReadBeforeASetWithNoCancel() throws {
        startUnansweredTempBasal()
        let ended = Self.patchTime(399_933_337 + 120)
        advanceClock(by: 121)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 120, patchId: 251, start: ended, rate: 0.7))
        settle()
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)

        advanceClock(by: 180)
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: ended, rate: 0, delivered: 0
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL], "no cancel")
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        assertZeroFinalAhead(of: { $0.unitsPerHour == 1 })
    }

    /// Killed during the read in the command - the host has the cancel's outcome, the zero one kept, no set pending: the
    /// next set after the restart, no cancel before it, reads the zero one's record first
    func testRestartDuringTheReadLeavesItToTheNextSet() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1
        ))
        let duringRead = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.GET_RECORD, .timeout) { [unowned self] in
            duringRead.value = delegate.savedState
        }
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        try restart(from: duringRead.value)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertEqual(pumpManager.state.basalState, .active)

        advanceClock(by: 60)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 2, sequence: 121, patchId: 251, start: Self.c1.addingTimeInterval(61)
        ))
        XCTAssertNil(commandTempBasal(2, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL], "no cancel")
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        assertZeroFinalAhead(of: { $0.unitsPerHour == 2 })
    }

    /// A suspend while the unanswered one is kept, the patch's status of it - naming 120 the newest record - in before the
    /// command's answer: the suspend is held back, 120 read in the command, the zero one final from it before the suspend
    /// is reported - counted
    func testSuspendWhileAnUnansweredTempBasalIsKeptReportsItsFinalFirst() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"])) { [unowned self] in
            notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        }
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        assertZeroFinalAhead(of: { $0.type == .suspend })
    }

    /// The same, the record unreadable in the command: the suspend goes out all the same - the zero one's record read
    /// later is behind Loop's watermark, warned of (the (d) path)
    func testSuspendWhileAnUnansweredTempBasalIsKeptGoesOutWithItsRecordUnread() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"])) { [unowned self] in
            notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        }
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(reports(of: .suspend).contains { _ in true }, "reported all the same")

        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
    }

    /// The patch halts on its own while the unanswered one is kept: the suspend is held back until 120, the newest record
    /// the status names, is read off the queue statuses arrive on - the zero one final from it first, counted
    func testHaltWhileAnUnansweredTempBasalIsKeptReportsItsFinalFirst() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        settle()

        XCTAssertEqual(link.writtenCommands.last, CommandType.GET_RECORD)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        assertZeroFinalAhead(of: { $0.type == .suspend })
    }

    /// The patch halts at the end of the zero one's record, 300 s after the cancel's segment: the suspend is dated from the
    /// anchor the zero one is dated by - not through the skew, a second off here - and the zero one ends where it starts,
    /// all of its 300 s, nothing warned of
    func testHaltWhileAnUnansweredTempBasalIsKeptIsDatedFromItsAnchor() throws {
        try assertHaltWhileAnUnansweredTempBasalIsKept(haltedAfter: 300, recordLasting: 300)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        XCTAssertEqual(zero.endDate.timeIntervalSince(zero.startDate), 300, accuracy: 0.5, "all of it")
    }

    /// The suspend 2 s before the zero one's record ends, as the two clocks tell them: fitted before it, silently - a
    /// shortfall no larger than the clocks tell apart
    func testUnansweredTempBasalsRecordEndingSecondsPastTheSuspendIsFittedSilently() throws {
        try assertHaltWhileAnUnansweredTempBasalIsKept(haltedAfter: 298, recordLasting: 300)
    }

    /// The suspend 10 s before the zero one's record ends: fitted before it, compressed - warned of
    func testUnansweredTempBasalsRecordEndingWellPastTheSuspendIsWarnedOf() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.GET_RECORD, Self.zeroFromTheCancel(lasting: 300))
        notifyOnTheManagersClock(Self.halted(at: Self.patchTime(399_933_336 + 290), newestRecord: 120))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
    }

    /// The patch halts `haltedAfter` s after the cancel's segment, the zero one's record `recordLasting` s from it: the
    /// zero one final from it, ending where the suspend starts, before it, nothing warned of
    private func assertHaltWhileAnUnansweredTempBasalIsKept(
        haltedAfter: TimeInterval,
        recordLasting: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.GET_RECORD, Self.zeroFromTheCancel(lasting: recordLasting))
        notifyOnTheManagersClock(Self.halted(at: Self.patchTime(399_933_336).addingTimeInterval(haltedAfter), newestRecord: 120))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, file: file, line: line)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable }, file: file, line: line)
        let suspend = try XCTUnwrap(reports(of: .suspend).first, file: file, line: line)
        XCTAssertEqual(zero.endDate.timeIntervalSince1970, suspend.startDate.timeIntervalSince1970, accuracy: 0.01, file: file, line: line)
        assertZeroFinalAhead(of: { $0.type == .suspend }, file: file, line: line)
    }

    /// The patch halts while the unanswered one is kept, as a resume goes out: the suspend, held back for 120, goes out
    /// ahead of the resume - 120 read in the resume first: the schedule's, not the zero one's - and of the set after it.
    /// Loop stores the suspension.
    func testSuspendHeldForAnUnansweredTempBasalGoesOutBeforeAResumeAndASet() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.RESUME_PUMP, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))) { [unowned self] in
            notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        }
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(120, at: Self.c1))
        XCTAssertNil(commandResume())
        settle()
        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.RESUME_PUMP, CommandType.GET_RECORD])

        advanceClock(by: 60)
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(61)
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        let suspendAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .suspend } }
        let resumeAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .resume } }
        let setAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 1 } }
        XCTAssertNotNil(suspendAt)
        XCTAssertLessThan(suspendAt ?? .max, resumeAt ?? -1, "the suspend ahead of the resume")
        XCTAssertLessThan(resumeAt ?? .max, setAt ?? -1)
    }

    /// The same, 120 the zero one's record: read in the resume before the suspend held back for it goes out - the zero
    /// one final from it first, counted, then the suspend, then the resume. The patch's status of its schedule in during
    /// that read, as on a device a second after the resume's answer: the resume it shows is held with the suspend, not
    /// reported ahead of it.
    func testResumeCommandReadsTheUnansweredOnesRecordBeforeTheHeldSuspend() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.RESUME_PUMP, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))) { [unowned self] in
            notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        }
        link.script(CommandType.GET_RECORD, .fragments(Self.recordOfTheZeroUpToTheSuspend)) { [unowned self] in
            notifyOnTheManagersClock(PatchBytes.basalNotification(
                type: .STANDARD, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1), rate: 0.7
            ))
        }
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.RESUME_PUMP, CommandType.GET_RECORD])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        assertZeroFinalAhead(of: { $0.type == .suspend })
        assertSuspendThenResume()
    }

    /// The patch halts while the unanswered one is kept, the read off the queue statuses arrive on yet to run, and the
    /// user resumes: 120 is read in the resume before it is written - the patch still suspended - and the suspend held
    /// back goes out then. The status of the schedule after the resume's answer reports the resume after it.
    func testResumeCommandReadsTheUnansweredOnesRecordBeforeItIsWritten() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let gate = DispatchSemaphore(value: 0)
        pumpManager.tempBasalEndQueue.async { gate.wait() }
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        advanceClock(by: 2)
        link.script(CommandType.RESUME_PUMP, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2)
        ))) { [unowned self] in
            notifyOnTheManagersClock(PatchBytes.basalNotification(
                type: .STANDARD, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2), rate: 0.7
            ))
        }
        XCTAssertNil(commandResume())
        gate.signal()
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.GET_RECORD, CommandType.RESUME_PUMP])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        assertZeroFinalAhead(of: { $0.type == .suspend })
        assertSuspendThenResume()
    }

    /// The patch halts while the unanswered one is kept, then shows its schedule - resumed - before 120 is read off the
    /// queue statuses arrive on, the link held meanwhile: the resume is held with the suspend - ahead of it, iAPS would
    /// zero the basal before it - and both go out once 120 is read, after the zero one's final, counted
    func testResumeShownBeforeTheUnansweredOnesRecordIsReadIsHeldWithTheSuspend() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let release = DispatchSemaphore(value: 0)
        link.holdWriter(until: release)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        advanceClock(by: 2)
        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .STANDARD, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2), rate: 0.7
        ))
        // Not `settle`: the read waits on the link
        delegate.queue.sync {}
        XCTAssertTrue(reports(of: .resume).isEmpty, "the resume held back with the suspend")
        XCTAssertTrue(reports(of: .suspend).isEmpty, "the suspend still held back")
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)

        release.signal()
        settle()

        XCTAssertEqual(link.writtenCommands.last, CommandType.GET_RECORD)
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        assertZeroFinalAhead(of: { $0.type == .suspend })
        assertSuspendThenResume()
    }

    /// The same, the zero one's record ending 2 s past the suspend as the two clocks tell them, the resume shown 4 s after
    /// the suspend - held with it: the zero one is fitted before the held suspend, not before the resume. Ending past the
    /// suspend, out ahead of it, it would have Loop's watermark past the suspend: never stored.
    func testUnansweredTempBasalsRecordEndingPastAHeldSuspendIsFittedBeforeItNotBeforeTheResume() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let release = DispatchSemaphore(value: 0)
        link.holdWriter(until: release)
        let haltedAt = Self.patchTime(399_933_336 + 298)
        link.script(CommandType.GET_RECORD, Self.zeroFromTheCancel(lasting: 300))
        notifyOnTheManagersClock(Self.halted(at: haltedAt, newestRecord: 120))
        advanceClock(by: 4)
        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .STANDARD, sequence: 120, patchId: 251, start: haltedAt.addingTimeInterval(4), rate: 0.7
        ))
        // Not `settle`: the read waits on the link
        delegate.queue.sync {}
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume, "the resume held with the suspend")

        release.signal()
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        let suspend = try XCTUnwrap(reports(of: .suspend).first)
        XCTAssertEqual(zero.endDate.timeIntervalSince1970, suspend.startDate.timeIntervalSince1970, accuracy: 0.01, "up to the suspend")
        assertZeroFinalAhead(of: { $0.type == .suspend })
        assertSuspendThenResume()
    }

    /// The patch halts while the unanswered one is kept, 120 - the zero one's record - not yet written: nothing to read,
    /// the suspend reported, not held back. A status then names 120 the newest: the resume command reads it before the
    /// resume is written, the zero one final from it ahead of the resume - not left to a sync after it. Behind Loop's
    /// watermark all the same, the suspend reported before it having moved it there: warned of, the (d) path.
    func testResumeCommandReadsTheUnansweredOnesRecordWithTheSuspendReported() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        advanceClock(by: 302)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 119))
        settle()
        XCTAssertEqual(reports(of: .suspend).count, 1, "nothing to read: reported")
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 120)

        advanceClock(by: 2)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        link.script(CommandType.RESUME_PUMP, PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2)
        ))
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.GET_RECORD, CommandType.RESUME_PUMP], "read before the resume")
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        let zeroFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 0 && $0.dose?.type == .tempBasal && $0.dose?.isMutable == false } }
        let resumeAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .resume } }
        XCTAssertNotNil(zeroFinal)
        XCTAssertLessThan(zeroFinal ?? .max, resumeAt ?? -1, "final ahead of the resume")
        XCTAssertEqual(uncertainDeliveryErrors, 1, "behind the reported suspend")
    }

    /// The patch halts while the unanswered one is kept, nothing to read - the suspend reported - then a status shows the
    /// zero one's segment: late - a halted patch runs no temp basal, the halt ended it. Kept, its record to settle it, the
    /// suspend left running: nothing reported. Taken to run over the suspend, it would be dated over the suspension, and
    /// the host's suspend left open - no resume - or closed by one where the patch never resumed. Its record, 120, then
    /// settles it: final from it, at or before the suspend - behind Loop's watermark, which the suspend moved there:
    /// warned of, the (d) path - and nothing reported again. The resume command after reports the resume, in a later
    /// second than the suspend.
    func testUnansweredTempBasalShownAfterAReportedSuspendIsLateAndLeavesItSuspended() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        advanceClock(by: 302)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 119))
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).first, "nothing to read: reported")
        let batches = delegate.batches.count

        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: Self.patchTime(399_933_337), rate: 0
        ))
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
        XCTAssertEqual(pumpManager.state.basalState, .suspended)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "kept, its record to settle it")
        XCTAssertEqual(delegate.batches.count, batches, "nothing reported")

        advanceClock(by: 1)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let zeros = reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }
        XCTAssertEqual(zeros.map(\.isMutable), [false], "reported once, final")
        XCTAssertLessThanOrEqual(try XCTUnwrap(zeros.first?.endDate), suspend.startDate, "at or before the suspend")
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
        XCTAssertEqual(reports(of: .suspend).count, 1, "nothing reported again")

        advanceClock(by: 2)
        link.script(CommandType.RESUME_PUMP, PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.7, sequence: 119, patchId: 251, start: Self.c1.addingTimeInterval(2)
        ))
        XCTAssertNil(commandResume())
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        let resume = try XCTUnwrap(reports(of: .resume).first)
        XCTAssertEqual(reports(of: .resume).count, 1)
        assertResumeInALaterSecond(resume, than: suspend.startDate)
    }

    /// The patch halts while the unanswered one is kept, shows its schedule, and halts again - all before 120 is read off
    /// the queue statuses arrive on, the link held meanwhile: the resume and the second suspend are held behind the first,
    /// and the three go out in order once 120 is read, after the zero one's final
    func testSuspendResumeAndSuspendShownBeforeTheUnansweredOnesRecordIsReadGoOutInOrder() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let release = DispatchSemaphore(value: 0)
        link.holdWriter(until: release)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZeroUpToTheSuspend)
        let reads = link.requestedCommands.filter { $0 == CommandType.GET_RECORD }.count
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        // The read under way - its budget counted from the clock as it is now - and held up on the link: the clock moved
        // on 62 s before, it would find that budget gone
        XCTAssertTrue(giveTime(timeout: 5) { self.link.requestedCommands.filter { $0 == CommandType.GET_RECORD }.count > reads })
        advanceClock(by: 2)
        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .STANDARD, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(2), rate: 0.7
        ))
        advanceClock(by: 60)
        notifyOnTheManagersClock(Self.halted(at: Self.c1.addingTimeInterval(62), newestRecord: 120))
        // Not `settle`: the read waits on the link
        delegate.queue.sync {}
        XCTAssertTrue(reports(of: .suspend).isEmpty, "both suspends held back")
        XCTAssertTrue(reports(of: .resume).isEmpty, "the resume held back with them")
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)

        release.signal()
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        assertZeroFinalAhead(of: { $0.type == .suspend })
        let released = try XCTUnwrap(delegate.batches.first { $0.events.contains { $0.dose?.type == .suspend } })
        let doses = released.events.compactMap(\.dose).filter { $0.type == .suspend || $0.type == .resume }
        XCTAssertEqual(doses.map(\.type), [.suspend, .resume, .suspend], "in one batch, in order")
        XCTAssertEqual(doses.map(\.startDate), doses.map(\.startDate).sorted())
    }

    /// A status shows the zero one over, the next set goes out with no cancel - the zero one's record unread in it - and
    /// then a suspend over that set: the record the patch has newest, 120, is read as the suspend ends the set, no cancel
    /// having named it - the zero one final from it ahead of the set's final in that batch. Loop's watermark passed it
    /// already, as the set was reported running: still warned of, the (d) path.
    func testSuspendOverASetWithNoCancelReadsTheUnansweredOnesRecord() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        let ended = Self.patchTime(399_933_337 + 120)
        advanceClock(by: 121)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 120, patchId: 251, start: ended, rate: 0.7))
        settle()
        advanceClock(by: 180)
        link.script(CommandType.GET_RECORD, .timeout)
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 120, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal?.snapshot.endRecord, "no cancel named its record")

        advanceClock(by: 60)
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"]))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: ended, rate: 0, delivered: 0
        ))
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertEqual(Array(link.writtenCommands.suffix(2)), [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        let batch = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        let zero = batch.firstIndex { $0.unitsPerHour == 0 && $0.type == .tempBasal && !$0.isMutable }
        let set = batch.firstIndex { $0.unitsPerHour == 1 && !$0.isMutable }
        XCTAssertNotNil(zero)
        XCTAssertLessThan(zero ?? .max, set ?? -1, "final ahead of the set's, in start order")
    }

    /// The notification `hex`, received now on the manager's clock - which the scenario moved - not on ours
    private func notifyOnTheManagersClock(_ hex: String) {
        let packet = NotificationPacket()
        packet.totalData = FakeMedtrumLink.bytes(hex)
        var response = packet.parseResponse()
        response.receivedAt = pumpManager.now()
        response.receivedUptime = pumpManager.uptime()
        link.onQueue { self.pumpManager.handleStatus(response, duringReconnect: false, fullSync: false) }
    }

    /// Record 120: the zero one, run from the cancel's segment for 300 s, up to the second before the suspend at `c1`
    private static let recordOfTheZeroUpToTheSuspend = zeroFromTheCancel(lasting: 300)

    /// Record 120: the zero one, run from the cancel's segment for `duration`
    private static func zeroFromTheCancel(lasting duration: TimeInterval) -> [String] {
        PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: patchTime(399_933_336),
            end: patchTime(399_933_336).addingTimeInterval(duration), rate: 0, delivered: 0
        )
    }

    /// A notification of the patch suspended at `at`, naming `newestRecord` its newest record
    private static func halted(at: Date, newestRecord: Int) -> String {
        (Data([PatchState.suspended.rawValue, 0x01, 0x01]) + at.toMedtrumSeconds() + UInt64(newestRecord).toData(length: 2) +
            UInt64(251).toData(length: 2)).hexEncodedString()
    }

    /// The suspend reported, and the resume after it: in a later batch, or after it in the same one - never ahead of it
    private func assertSuspendThenResume(file: StaticString = #filePath, line: UInt = #line) {
        let suspendAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .suspend } }
        let resumeAt = delegate.batches.firstIndex { $0.events.contains { $0.dose?.type == .resume } }
        XCTAssertNotNil(suspendAt, file: file, line: line)
        XCTAssertNotNil(resumeAt, file: file, line: line)
        XCTAssertLessThanOrEqual(suspendAt ?? .max, resumeAt ?? -1, "the suspend ahead of the resume", file: file, line: line)
        if let suspendAt, suspendAt == resumeAt {
            let types = delegate.batches[suspendAt].events.compactMap(\.dose?.type)
            XCTAssertLessThan(
                types.firstIndex(of: .suspend) ?? .max, types.firstIndex(of: .resume) ?? -1, "first in the batch", file: file, line: line
            )
        }
    }

    /// The zero one final from its record in a batch no later than the first carrying a dose `later` picks: counted -
    /// nothing warned of, Loop's view (the checker, on) has nothing behind its watermark
    private func assertZeroFinalAhead(of later: (DoseEntry) -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let zeroFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 0 && $0.dose?.type == .tempBasal && $0.dose?.isMutable == false } }
        let laterFirst = delegate.batches.firstIndex { $0.events.contains { $0.dose.map(later) == true } }
        XCTAssertNotNil(zeroFinal, file: file, line: line)
        XCTAssertNotNil(laterFirst, file: file, line: line)
        XCTAssertLessThanOrEqual(zeroFinal ?? .max, laterFirst ?? -1, file: file, line: line)
        if let zeroFinal, let laterFirst, zeroFinal == laterFirst, let batch = delegate.batches[zeroFinal].events.compactMap(\.dose) as [DoseEntry]? {
            let z = batch.firstIndex { $0.unitsPerHour == 0 && $0.type == .tempBasal } ?? .max
            let l = batch.firstIndex(where: later) ?? -1
            XCTAssertLessThan(z, l, "the final first in the batch", file: file, line: line)
        }
        XCTAssertEqual(uncertainDeliveryErrors, 0, "nothing warned of", file: file, line: line)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.byRecord) }, file: file, line: line)
    }

    /// The cancel ahead of the 1 U/h one names 121: a bolus's record, 120, comes first - read in order and reconciled, its
    /// bolus final from it, not skipped - then the zero one's, before the set
    func testBolusRecordBeforeTheUnansweredTempBasalsIsReadInOrderBeforeTheSet() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        let bolus = UnfinalizedDose(
            units: 1,
            duration: 40,
            activationType: .manualNoRecommendation,
            insulinType: nil,
            startDate: pumpManager.now().addingTimeInterval(-200)
        )
        bolus.noteAnswer(recordSequence: 120, pumpStartTime: Self.patchTime(399_933_437))
        bolus.finish(.cancelled, deliveredUnits: 0.1, endedAt: pumpManager.now().addingTimeInterval(-150))
        pumpManager.state.mutateAwaitingRecord { $0.append(bolus) }

        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 121, patchId: 251, start: Self.c1
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: 120, patchId: 251, start: Self.patchTime(399_933_437), amount: 1, delivered: 0.15
        ))
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 121, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: Self.c1, rate: 0, delivered: 0
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 122, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(
            link.writtenCommands.suffix(4),
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL]
        )
        XCTAssertEqual(link.writes.filter { $0.commandType == CommandType.GET_RECORD }.count, 3, "119, then 120 and 121 in order")
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 121)
        let bolusFinal = try XCTUnwrap(reports(of: .bolus).last { $0.startDate == bolus.startDate && !$0.isMutable })
        XCTAssertEqual(bolusFinal.deliveredUnits ?? 0, 0.15, accuracy: 0.001, "from its record")
        XCTAssertNotEqual(pumpManager.recordStore.records.first { $0.id == 120 }?.outcome, "unmatched")
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 121 }?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
    }

    /// Killed after the read in the command, before the set's write-ahead: the run after has the zero one final from its
    /// record, the cancel's schedule running, no set pending - and reports nothing new of it
    func testRestartBetweenTheReadAndTheSetComesBackWithTheUnansweredOneFinal() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1
        ))
        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        let beforeSet = Locked<PumpManager.RawStateValue?>(nil)
        link.script(CommandType.SET_TEMP_BASAL, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))) { [unowned self] in
            // The last state the host had before the set's write-ahead
            beforeSet.value = delegate.savedStates.last { $0["pendingTempBasal"] == nil }
        }
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        let saved = try XCTUnwrap(beforeSet.value)
        XCTAssertNil(saved["unconfirmedTempBasal"], "final from its record in that state")
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        try restart(from: saved)
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertNil(pumpManager.state.pendingTempBasal)
        XCTAssertEqual(pumpManager.state.basalState, .active)
        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        // Saved with the final, before the cursor moved past its record: read again, it changes nothing
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 119)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 120)
        // At most its final again, until the host confirms it: never running, never another identity
        XCTAssertTrue(
            reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }.allSatisfy { !$0.isMutable && $0.syncIdentifier == zero.syncIdentifier }
        )
    }

    /// The zero one's record unread in the command (the (d) path): the 1 U/h one ended back to back, its records unread past its maximum wait: it does not go final from our estimate
    /// while the zero one before it is unsettled - once its record is read, both go final, in order
    /// The 1 U/h one was reported running before the zero one's record was read: in Loop, the zero one is behind the
    /// watermark all the same - see `assertBehindLoopsWatermark`.
    func testTempBasalAfterAnUnansweredOneWaitsForItBeforeGoingFinalFromOurEstimate() throws {
        checksLoopOrdering = false
        setAfterTheUnansweredTempBasal(inCommand: .timeout, afterCommand: .timeout)
        replaceTheOneByTwo()

        advanceClock(by: MedtrumPumpManager.openTempBasalEndMaximumWait + Self.minute)
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()
        XCTAssertTrue(pumpManager.hasOpenTempBasalEnds, "waits for the zero one")
        XCTAssertTrue(reports(of: .tempBasal).filter { $0.unitsPerHour == 1 }.allSatisfy(\.isMutable))

        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(123, at: Self.c2))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds)
        let zeroFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 0 && $0.dose?.isMutable == false } }
        let oneFinal = delegate.batches.firstIndex { $0.events.contains { $0.dose?.unitsPerHour == 1 && $0.dose?.isMutable == false } }
        XCTAssertLessThanOrEqual(zeroFinal ?? .max, oneFinal ?? -1)
        // V went out mutable before: Loop's fill up to its start passed the zero one, which it may not store - what can't
        // be helped yet (scenario 2): warned of, not counted in the settings; iAPS counts it, final before the others
        assertBehindLoopsWatermark()
    }

    /// The zero one final from its record read in the command: the 1 U/h one, ended back to back, its records unread past
    /// its maximum wait, has nothing before it to wait for - final from our estimate, after the zero one
    func testTempBasalAfterAnUnansweredOneReadInTheCommandGoesFinalFromOurEstimate() throws {
        setAfterTheUnansweredTempBasal(inCommand: .fragments(Self.recordOfTheZero), advancingClock: 302)
        advanceClock(by: 300)
        replaceTheOneByTwo()

        advanceClock(by: MedtrumPumpManager.openTempBasalEndMaximumWait + Self.minute)
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()

        XCTAssertFalse(pumpManager.hasOpenTempBasalEnds, "nothing before it to wait for")
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour == 1 && !$0.isMutable })
        assertCountedAheadOfTheOne()
    }

    /// What can't be helped: the zero one's record unreadable as the 1 U/h one is cancelled - that one goes final, from
    /// our estimate, with the schedule. The zero one's record read later still makes its final, which Loop may not count,
    /// behind those: the host is warned of uncertain delivery, the settings show it not counted.
    func testUnansweredTempBasalsRecordReadAfterALaterOnesFinalIsWarnedOf() throws {
        checksLoopOrdering = false
        setAfterTheUnansweredTempBasal(inCommand: .timeout, afterCommand: .timeout)

        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: Self.c2
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        let errors = uncertainDeliveryErrors

        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && !$0.isMutable }, "reported all the same")
        XCTAssertEqual(uncertainDeliveryErrors, errors + 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
        // Loop's view: behind its watermark
        XCTAssertTrue(LoopOrderingChecker.violations(in: delegate.hostBatches).contains { $0.rule == 6 })
    }

    /// The zero one went final after a later temp basal was reported - Loop's watermark passed it: the host was warned,
    /// once, the settings show it not counted, and Loop's view (`LoopOrderingChecker`) has it behind the watermark
    private func assertBehindLoopsWatermark(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && !$0.isMutable }, "reported all the same", file: file, line: line)
        XCTAssertEqual(uncertainDeliveryErrors, 1, file: file, line: line)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) }, file: file, line: line)
        XCTAssertTrue(LoopOrderingChecker.violations(in: delegate.hostBatches).contains { $0.rule == 6 }, file: file, line: line)
    }

    /// The batch with the 1 U/h one running the host could not store: Loop's watermark is where it was - the zero one's
    /// record read right after goes out with the 1 U/h one, in the next batch, ahead of the fill to its start: counted,
    /// nothing warned of
    func testUnansweredTempBasalsRecordAfterABatchTheHostCouldNotStoreIsNotWarnedOf() throws {
        startUnansweredTempBasal()
        // The 1 U/h one set as the patch says: 301 s after the cancel's segment before the zero one
        advanceClock(by: 302)
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: Self.c1
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: Self.c1.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, .fragments(Self.recordOfTheZero)) { [unowned self] in
            delegate.batchReply = .acknowledge
        }
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertFalse(uncertain.contains { $0.phase == .settled(.notCounted) })
    }

    /// State saved before Loop's watermark was kept, a suspend held back after a temp basal: it counts with its start
    func testLoopWatermarkOfStateSavedBeforeItWasKeptCountsAHeldSuspend() throws {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 118, reservoir: 150)
        let suspendedAt = Date.now.addingTimeInterval(-Self.minute)
        state.heldBasalDoses = [HeldBasalDose(dose: UnfinalizedDose(suspendStartTime: suspendedAt), heldAt: suspendedAt)]
        XCTAssertNil(state.loopWatermark)
        makeManager(state)
        XCTAssertEqual(pumpManager.state.loopWatermark, suspendedAt)
    }

    /// The state read back with no running basal saved - the schedule put in place then never reported: the temp basal
    /// whose command went unanswered after it is dated by its segment, not after that schedule
    func testUnansweredTempBasalIsNotDatedAfterAScheduleNeverReported() throws {
        var raw = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 118, reservoir: 150).rawValue
        raw["basalDose"] = nil
        let state = MedtrumPumpState(rawValue: raw)
        XCTAssertTrue(state.basalDoseIsPlaceholder)
        let patchNow = Self.patchTime(399_933_337)
        state.lastSegmentStart = patchNow.addingTimeInterval(-Self.hour)
        alignPatchClock(state, patchTime: patchNow)
        makeManager(state)

        link.script(CommandType.SET_TEMP_BASAL, .timeout)
        let sentAt = Date.now
        XCTAssertTrue(isUncertainDelivery(commandTempBasal(0, duration: Self.hour)))
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal?.snapshot.basalBefore)

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 118, patchId: 251, start: patchNow.addingTimeInterval(-3), rate: 0))
        settle()

        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal)
        XCTAssertEqual(confirmed.startDate.timeIntervalSince(sentAt), -3, accuracy: 0.5)
    }

    /// The cancel's own segment shown late by a status, our reading of the patch clock an hour behind: it began before the
    /// unanswered set went out - told on each clock alone - so it bounds nothing; the zero one's record is still its own
    func testCancelsSegmentShownLateWithThePatchClockAnHourBehindLeavesTheUnansweredTempBasalsRecordItsOwn() throws {
        startUnansweredTempBasal(patchAhead: -3600)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 119, patchId: 251, start: Self.patchTime(399_933_336), rate: 0.7))
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal?.snapshot.laterSegmentStart)

        link.notify("200001" + "7800fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: Self.patchTime(399_933_456),
            rate: 0, delivered: 0
        ))
        syncRecords()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && !$0.isMutable })
    }

    /// A segment begun 10 min after the set went out, our reading of the patch clock an hour ahead: it is after the
    /// command - told on each clock alone - and bounds the unanswered one there
    func testSegmentShownAfterTheCommandWithThePatchClockAnHourAheadBoundsTheUnansweredTempBasal() throws {
        startUnansweredTempBasal(patchAhead: 3600)
        let later = Self.patchTime(399_933_337 + 600)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 119, patchId: 251, start: later, rate: 0.7))
        settle()
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.snapshot.laterSegmentStart, later)
    }

    /// Killed as the set after an answered cancel awaited its answer, the cancel's answer not parsed - its segment not
    /// known: the next run tells the unanswered one's times through the skew, not from the segment before the cancel -
    /// its record, starting as the set went out, is its own
    func testTakenOverTempBasalWithNoCancelSegmentKnownIsMatchedThroughTheSkew() throws {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 119, reservoir: 150)
        let previous = runningTempBasal(rate: 0.2, startedAgo: 601, duration: 30 * Self.minute, pumpStartTime: Self.patchTime(399_932_735))
        state.basalDose = previous
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.patchTime(399_933_337))
        state.pendingTempBasal = PendingTempBasal(
            unitsPerHour: 0,
            duration: Self.hour,
            automatic: true,
            sentAt: Date.now,
            sequenceAtSend: 119,
            priorSegmentStart: Self.patchTime(399_932_735),
            cancelledAt: Date.now.addingTimeInterval(-1)
        )
        makeManager(state)
        let pending = try XCTUnwrap(pumpManager.state.unconfirmedTempBasal)
        XCTAssertNil(pending.snapshot.basalBeforeOnPatch)

        link.notify("200001" + "7800fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_337), end: Self.patchTime(399_933_457),
            rate: 0, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 120 }?.outcome?.hasPrefix("finalized unconfirmed temp basal"), true)
    }

    /// The zero one's record, 300 s long, read right after the 1 U/h one was set: dated from the cancel's segment it
    /// would run into that one, which the host has running - Loop would trim it and, its watermark past it, lose it. The
    /// zero one is fitted before it instead: no room for all of its 300 s since the cancel here, so into what there is,
    /// its amount kept - warned of. The 1 U/h one survives in Loop; the zero one, after it was reported, is behind
    /// Loop's watermark - the residual - and the only thing Loop's view finds.
    func testUnansweredTempBasalsRecordThatCannotFitBeforeALaterOneIsFittedBeforeIt() throws {
        checksLoopOrdering = false
        let late = PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_337), end: Self.c1, rate: 0, delivered: 0
        )
        // Unread in the command, read right after it: the 1 U/h one reported running by then
        setAfterTheUnansweredTempBasal(inCommand: .timeout, afterCommand: .fragments(late))

        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        let one = try XCTUnwrap(reports(of: .tempBasal).last { $0.unitsPerHour == 1 })
        XCTAssertEqual(zero.endDate, one.startDate, "up to the one the host has, not over it")
        XCTAssertLessThan(zero.startDate, one.startDate)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
        assertTheRunningOneSurvivesInLoop(zeroStart: zero.startDate)
    }

    /// The same, the 1 U/h one set 215 s after the zero one went out: the zero one's 200 s, dated from the cancel's
    /// segment, run 15 s into it - moved to end where it starts, all of it, nothing compressed. Behind Loop's watermark,
    /// reported after it (the residual).
    func testUnansweredTempBasalsRecordDatedIntoALaterOneIsMovedToEndBeforeIt() throws {
        checksLoopOrdering = false
        startUnansweredTempBasal()
        // The patch puts the cancel 230 s after the cancel's segment before the zero one, our clock 215 s: the 15 s the
        // patch's times run into it
        advanceClock(by: 215)
        let c1 = Self.patchTime(399_933_336 + 230)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: c1
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: c1.addingTimeInterval(1)
        ))
        // Unread in the command, read right after it: the 1 U/h one reported running by then
        link.script(CommandType.GET_RECORD, .timeout)
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_366), end: c1,
            rate: 0, delivered: 0
        ))
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        let one = try XCTUnwrap(reports(of: .tempBasal).last { $0.unitsPerHour == 1 })
        XCTAssertEqual(zero.endDate, one.startDate)
        XCTAssertEqual(zero.endDate.timeIntervalSince(zero.startDate), 200, accuracy: 0.001, "all of it")
        XCTAssertEqual(uncertainDeliveryErrors, 1, "behind the watermark only")
        assertTheRunningOneSurvivesInLoop(zeroStart: zero.startDate)
    }

    /// Loop's view of the batches: the running one is not lost - nothing but the zero one, behind the watermark
    private func assertTheRunningOneSurvivesInLoop(zeroStart: Date, file: StaticString = #filePath, line: UInt = #line) {
        let violations = LoopOrderingChecker.violations(in: delegate.hostBatches)
        XCTAssertFalse(violations.contains { $0.message.contains("lost") || $0.rule == 1 || $0.rule == 2 || $0.rule == 3 }, "\(violations)", file: file, line: line)
        XCTAssertTrue(violations.allSatisfy { $0.rule == 6 && $0.message.contains("\(zeroStart)") }, "\(violations)", file: file, line: line)
    }

    /// The zero one's record, starting in the cancel's second, our reading of the patch clock an hour off either way:
    /// matched and dated from the cancel's segment - on each clock alone - not through the skew
    func testUnansweredTempBasalsRecordIsMatchedWithThePatchClockAnHourAhead() throws {
        try assertUnansweredTempBasalsRecordIsMatched(patchAhead: 3600)
    }

    func testUnansweredTempBasalsRecordIsMatchedWithThePatchClockAnHourBehind() throws {
        try assertUnansweredTempBasalsRecordIsMatched(patchAhead: -3600)
    }

    private func assertUnansweredTempBasalsRecordIsMatched(patchAhead: TimeInterval, line: UInt = #line) throws {
        startUnansweredTempBasal(patchAhead: patchAhead)
        let previousEnd = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.2 }?.endDate, line: line)
        link.notify("200001" + "7800fb00")
        settle()

        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: Self.patchTime(399_933_456),
            rate: 0, delivered: 0
        ))
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, line: line)
        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 }, line: line)
        XCTAssertEqual(zero.isMutable, false, line: line)
        XCTAssertEqual(zero.startDate.timeIntervalSince(previousEnd), 0, accuracy: 0.5, "from the cancel's segment", line: line)
        XCTAssertEqual(zero.endDate.timeIntervalSince(zero.startDate), 120, accuracy: 0.5, line: line)
    }

    /// The same shown by a status: confirmed as running from the cancel's segment, not taken for a restart of it
    func testUnansweredTempBasalShownWithThePatchClockAnHourAheadIsConfirmedFromItsStart() throws {
        try assertUnansweredTempBasalShownIsConfirmed(patchAhead: 3600)
    }

    func testUnansweredTempBasalShownWithThePatchClockAnHourBehindIsConfirmedFromItsStart() throws {
        try assertUnansweredTempBasalShownIsConfirmed(patchAhead: -3600)
    }

    private func assertUnansweredTempBasalShownIsConfirmed(patchAhead: TimeInterval, line: UInt = #line) throws {
        startUnansweredTempBasal(patchAhead: patchAhead)
        let previousEnd = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour == 0.2 }?.endDate, line: line)

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: Self.patchTime(399_933_336), rate: 0))
        settle()

        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.type, .tempBasal, line: line)
        XCTAssertFalse(confirmed.recordMatchDisabled, "not a restart of it", line: line)
        // From the cancel's segment, 0 s after it on the patch clock: just after the schedule it started
        XCTAssertEqual(confirmed.startDate.timeIntervalSince(previousEnd), 0.001, accuracy: 0.004, line: line)
    }

    /// The unanswered one confirmed by a status after patch-local midnight - its patch start the restart's, 10 min after
    /// it began - then replaced back to back 20 min on, both clocks moving together: how long the patch ran it is not
    /// told from that patch start - it ran its whole 30 min, our estimate up to the next one's start, not a stop
    /// 10 min before the cancel
    func testTempBasalConfirmedFromARestartIsNotTakenAsStoppedBeforeTheCancel() throws {
        let patchNow = Self.patchTime(399_933_337)
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 119, reservoir: 150)
        let sentAt = Date.now.addingTimeInterval(-30 * Self.minute)
        let pending = UnfinalizedDose(tempRate: 1.2, duration: Self.hour, insulinType: nil, automatic: true, confirmation: .uncertain, startDate: sentAt)
        pending.noteCommand(sentAt: sentAt, uptime: nil, sequence: 119, priorSegmentStart: patchNow.addingTimeInterval(-Self.hour))
        state.unconfirmedTempBasal = pending
        state.basalState = .tempBasal
        state.lastSegmentStart = patchNow.addingTimeInterval(-Self.hour)
        alignPatchClock(state, patchTime: patchNow)
        makeManager(state)

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: patchNow.addingTimeInterval(-20 * Self.minute), rate: 1.2
        ))
        settle()
        let confirmed = pumpManager.state.basalDose
        XCTAssertEqual(confirmed.startDate, sentAt)
        XCTAssertEqual(confirmed.pumpStartTime, patchNow.addingTimeInterval(-20 * Self.minute))

        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: patchNow
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 0.5, sequence: 121, patchId: 251, start: patchNow.addingTimeInterval(1)
        ))
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        let final = try XCTUnwrap(finals(of: reports(of: .tempBasal).first { $0.startDate == sentAt }).first)
        XCTAssertEqual(final.endDate, pumpManager.state.basalDose.startDate, "back to back")
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.6, accuracy: 0.001, "1.2 U/h × 30 min, by our estimate")
    }

    /// The zero one's late record read after a restart, the 1 U/h one final before it in the run before: the host is
    /// warned all the same - what it has final is kept with the state
    func testUnansweredTempBasalsRecordReadLateAfterARestartIsWarnedOf() throws {
        checksLoopOrdering = false
        setAfterTheUnansweredTempBasal(inCommand: .timeout, afterCommand: .timeout)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: Self.c2
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 0, "the host confirmed the finals")

        try restart(from: delegate.savedState)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        link.script(CommandType.GET_RECORD, Self.recordOfTheZero)
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(121, at: Self.c1))
        link.script(CommandType.GET_RECORD, Self.recordOfTheOne)
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
    }

    /// The state read back with no running basal saved - a placeholder schedule from the restart: the zero one's record,
    /// read then, is not cut short at that placeholder's start
    func testUnansweredTempBasalsRecordIsNotCutAtAPlaceholderSchedule() throws {
        startUnansweredTempBasal()
        var saved = try XCTUnwrap(delegate.savedState)
        saved["basalDose"] = nil
        try restart(from: saved)
        XCTAssertTrue(pumpManager.state.basalDoseIsPlaceholder)

        link.notify("200001" + "7800fb00")
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_336), end: Self.c1, rate: 0, delivered: 0
        ))
        syncRecords()

        let zero = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 && !$0.isMutable })
        XCTAssertEqual(zero.endDate.timeIntervalSince(zero.startDate), 301, accuracy: 0.5)
    }

    /// The zero one's record ends at patch-local midnight - a part of it - read in the command before the 1 U/h one is
    /// set: it ended by the cancel, final from our estimate - not put back as the running basal - ahead of the 1 U/h
    /// one's first report
    func testUnansweredTempBasalsSplitRecordReadBeforeTheNextSetIsNotPutBackAsRunning() throws {
        let midnight = Self.patchTime(399_933_337 + 100)
        setAfterTheUnansweredTempBasal(
            inCommand: .fragments(PatchBytes.basalRecord(
                sequence: 120, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.patchTime(399_933_337), end: midnight, rate: 0, delivered: 0
            )),
            patchUTCOffset: 24 * Self.hour - midnight.timeIntervalSince1970.truncatingRemainder(dividingBy: 24 * Self.hour),
            advancingClock: 302
        )

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.value, 1, "the 1 U/h one runs")
        XCTAssertFalse(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && $0.isMutable }, "never reported running")
        XCTAssertTrue(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 && !$0.isMutable })
        assertCountedAheadOfTheOne(byRecord: false)
    }

    /// The unanswered set of `startUnansweredTempBasal`, kept, then two more set and answered - 1 U/h, then 2 U/h, the
    /// first one ended back to back and waiting on its record - and only then a status, late, showing the zero temp
    /// basal's segment: a later segment is known, the status is stale. The 2 U/h one runs on, nothing ended or reported
    /// before the ones the host has.
    func testStaleStatusOfAnUnansweredTempBasalAfterTwoMoreLeavesTheRunningOneRunning() {
        startUnansweredTempBasal()

        let c1 = Self.patchTime(399_933_337 + 300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 120, patchId: 251, start: c1
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1, sequence: 121, patchId: 251, start: c1.addingTimeInterval(1)
        ))
        // The record the cancel names, had the unanswered one run, read in the command and after it: not yet written here
        link.script(CommandType.GET_RECORD, .timeout)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(1, duration: 30 * Self.minute))
        settle()

        let c2 = c1.addingTimeInterval(300)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: 122, patchId: 251, start: c2
        ))
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 2, sequence: 123, patchId: 251, start: c2.addingTimeInterval(1)
        ))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(2, duration: 30 * Self.minute))
        settle()
        let running = pumpManager.state.basalDose
        XCTAssertEqual(running.value, 2)
        let batches = delegate.batches.count

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 123, patchId: 251, start: Self.patchTime(399_933_338), rate: 0))
        settle()

        XCTAssertTrue(pumpManager.state.basalDose === running)
        XCTAssertFalse(running.isFinished)
        XCTAssertEqual(delegate.batches.count, batches)
        XCTAssertTrue(reports(of: .tempBasal).allSatisfy { $0.unitsPerHour > 0.1 }, "the zero temp basal is not reported running")
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
        // then an ALARM. The first is read in the command, once it has its answer: it settles the temp basal, and the
        // ALARM is left to the sync.
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

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
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
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 514)
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, 515)
        XCTAssertEqual(delegate.batches.count, 1)

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
    /// at the suspend for good, so it ends at the resume at the latest, final from its record - 514, written as the patch
    /// suspended, read in the command up to 515, the newest the answer names: it settles it. The schedule after it, not a
    /// resume: no suspend was reported before it.
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
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 514,
            patchId: 237,
            type: .ABSOLUTE_TEMP,
            start: Self.patchTime(397_186_357),
            end: Self.patchTime(397_186_500),
            rate: 0.6,
            delivered: 0,
            endReason: .SUSPEND_MANUAL
        ))
        XCTAssertNil(commandResume())
        settle()

        XCTAssertEqual(pumpManager.state.basalDose.type, .basal)
        XCTAssertTrue(tempBasal.isFinalized)
        XCTAssertEqual(link.writtenCommands, [CommandType.RESUME_PUMP, CommandType.GET_RECORD])

        let resumedAt = min(Self.patchTime(397_186_625).addingTimeInterval(-skew), Date.now)
        XCTAssertEqual(delegate.batches.last?.events.map(\.dose?.type), [.tempBasal, .basal])
        let ended = delegate.batches.last?.events.compactMap(\.dose).first { $0.type == .tempBasal }
        XCTAssertEqual(ended?.isMutable, false)
        XCTAssertEqual(ended?.startDate, tempBasal.startDate)
        XCTAssertEqual(ended?.endDate.timeIntervalSince1970 ?? 0, resumedAt.timeIntervalSince1970, accuracy: 0.5)
        // Not 0.05 U, 0.6 U/h for 266 s by rate × duration to the nearest 0.05 U: what its record says
        XCTAssertEqual(ended?.deliveredUnits ?? 1, 0, accuracy: 0.001)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// Suspended a minute ago, as the host was told: a status shows the schedule from 65 s ago as our clock has it - before
    /// the suspend, the clocks a few seconds apart. The resume is dated in a later second than the suspend, not at it:
    /// iAPS stores both to the second, and oref0 pairs a resume with a suspend only if it is later - in the same second,
    /// the suspend is left open, every temp basal after it zeroed (the checker's rules 7 and 8).
    func testResumeShownFromBeforeTheSuspendIsDatedInALaterSecond() throws {
        let suspend = startSuspendedAMinuteAgo()
        link.notify(PatchBytes.basalNotification(
            type: .STANDARD, sequence: 513, patchId: 237, start: Self.patchTime(397_186_623 - 65), rate: 0.6
        ))
        settle()

        let resume = try XCTUnwrap(reports(of: .resume).first)
        assertResumeInALaterSecond(resume, than: suspend.startDate)
    }

    /// The same, the resume command's answer showing the schedule from before the suspend
    func testResumeAnsweredFromBeforeTheSuspendIsDatedInALaterSecond() throws {
        let suspend = startSuspendedAMinuteAgo()
        link.script(CommandType.RESUME_PUMP, PatchBytes.segmentAnswer(
            command: CommandType.RESUME_PUMP, type: .STANDARD, rate: 0.6, sequence: 513, patchId: 237, start: Self.patchTime(397_186_623 - 65)
        ))
        XCTAssertNil(commandResume())
        settle()

        let resume = try XCTUnwrap(reports(of: .resume).first)
        assertResumeInALaterSecond(resume, than: suspend.startDate)
    }

    /// `resume` in a later second than the suspend of `suspendStart` - as iAPS stores them, to the second, floored: paired
    /// with it by oref0 - a second after it at most
    private func assertResumeInALaterSecond(_ resume: DoseEntry, than suspendStart: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(LoopOrderingChecker.stored(resume.startDate), LoopOrderingChecker.stored(suspendStart), "in a later second", file: file, line: line)
        XCTAssertLessThanOrEqual(resume.startDate.timeIntervalSince(suspendStart), 1, "a second after it at most", file: file, line: line)
    }

    /// Suspended since a minute ago - the host told so in a run before - the patch clock `397_186_623` now
    private func startSuspendedAMinuteAgo() -> UnfinalizedDose {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        let suspend = UnfinalizedDose(suspendStartTime: Date.now.addingTimeInterval(-Self.minute))
        state.basalDose = suspend
        state.basalState = .suspended
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)
        hostSuspendedSince = suspend.startDate
        return suspend
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
        try assertSplitRecordEndsUpToTheCancel(patchAhead: 0)
    }

    /// The same, our reading of the patch clock an hour off either way: its end, up to the cancel, told from the cancel's
    /// segment before it, on each clock alone
    func testUnansweredTempBasalWhoseRecordEndsAtPatchMidnightWithThePatchClockAnHourAhead() throws {
        try assertSplitRecordEndsUpToTheCancel(patchAhead: 3600)
    }

    func testUnansweredTempBasalWhoseRecordEndsAtPatchMidnightWithThePatchClockAnHourBehind() throws {
        try assertSplitRecordEndsUpToTheCancel(patchAhead: -3600)
    }

    private func assertSplitRecordEndsUpToTheCancel(patchAhead: TimeInterval) throws {
        let sentAt = startUnansweredTempBasal(patchUTCOffset: 3 * Self.hour, patchAhead: patchAhead)
        readTheCancelledTempBasalsRecord()
        let midnight = Self.patchTime(399_934_800)
        let cancelledAt = Self.patchTime(399_933_337 + 1800)

        // 1801 s after the cancel's segment before the unanswered set (336)
        advanceClock(by: 30 * Self.minute + 1)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 121,
            patchId: 251,
            start: cancelledAt
        ))
        // The record the cancel names, had the unanswered one run, read after the command: not yet written here
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()

        let patchStart = Self.patchTime(399_933_338)
        let unconfirmed = try XCTUnwrap(pumpManager.state.unconfirmedTempBasal?.snapshot)
        let basalBefore = try XCTUnwrap(unconfirmed.basalBefore)
        let basalBeforeOnPatch = try XCTUnwrap(unconfirmed.basalBeforeOnPatch)
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

        // Told from the cancel's segment before the unanswered set, on each clock alone
        let onOurClock = { (patchTime: Date) in basalBefore.addingTimeInterval(patchTime.timeIntervalSince(basalBeforeOnPatch)) }
        let reported = try XCTUnwrap(reports(of: .tempBasal).first { $0.unitsPerHour < 0.01 })
        XCTAssertEqual(reports(of: .tempBasal).filter { $0.unitsPerHour < 0.01 }.count, 1, "reported once, final")
        XCTAssertGreaterThanOrEqual(reported.startDate, sentAt.addingTimeInterval(-MedtrumPumpManager.unansweredStartSlack))
        XCTAssertEqual(reported.startDate.timeIntervalSince1970, onOurClock(patchStart).timeIntervalSince1970, accuracy: 0.001, "from the record's start")

        let final = finals(of: reported)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.startDate, reported.startDate)
        XCTAssertEqual(
            final.first?.endDate.timeIntervalSince1970 ?? 0,
            onOurClock(cancelledAt).timeIntervalSince1970,
            accuracy: 0.001,
            "up to the cancel - the part up to midnight ends 1462 s in"
        )
        XCTAssertFalse(uncertain.contains { $0.phase == .settled(.notCounted) })
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
        // The record the cancel names, had the unanswered one run, read in the command and again after it: not yet
        // written here
        link.script(CommandType.GET_RECORD, .timeout)
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandTempBasal(0.5, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(
            link.writtenCommands.suffix(4),
            [CommandType.CANCEL_TEMP_BASAL, CommandType.GET_RECORD, CommandType.SET_TEMP_BASAL, CommandType.GET_RECORD]
        )
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
        // 1201 s after the cancel's segment before the unanswered set (336)
        advanceClock(by: 20 * Self.minute + 1)
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.7,
            sequence: 121,
            patchId: 251,
            start: cancelledAt
        ))
        // The record the cancel names, had the unanswered one run, read after the command: not yet written here
        link.script(CommandType.GET_RECORD, .timeout)
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
        XCTAssertFalse(uncertain.contains { $0.phase == .settled(.notCounted) })
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

        XCTAssertEqual(finals(of: bolus).count, 1)
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
        XCTAssertEqual(finals(of: old).count, 1)
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
        XCTAssertEqual(finals(of: old).count, 1)
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
        XCTAssertEqual(finals(of: old).count, 1)
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
        XCTAssertEqual(finals(of: old).count, 1)
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
    func testUnansweredCancelOfATempBasalFinalizedFromOurEstimateIsShownSo() {
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
        XCTAssertEqual(final.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 0, 897, accuracy: 1)
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
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.15, accuracy: 0.001, "its rate × duration: 0.6 U/h × 897 s")
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
        XCTAssertEqual(finals(of: final.first).count, 1)
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

    /// The patch's notification that it halted delivery, in state `state`, naming `newestRecord` - of patch 251 - the
    /// newest record written: with when it halted, `at`, as after a suspend we asked for - or without, nil, as the patch
    /// sends one for a halt of its own (`logs1018/today.txt:9166`)
    private func haltNotification(_ state: PatchState, at: Date?, newestRecord: Int) -> String {
        let storage = UInt64(newestRecord).toData(length: 2) + UInt64(251).toData(length: 2)
        guard let at else {
            return (Data([state.rawValue, 0x00, 0x01]) + storage).hexEncodedString()
        }
        return (Data([state.rawValue, 0x01, 0x01]) + at.toMedtrumSeconds() + storage).hexEncodedString()
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

    /// The cancel only, to the schedule: what follows leaves a gap after the temp basal, which ends final - its records
    /// read in the command
    private func scriptCancel(patchId: UInt64 = 251, cancelRecord: Int = 131) {
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(patchId: patchId, record: cancelRecord))
    }

    private func scriptCancelAndSet(patchId: UInt64 = 251, cancelRecord: Int = 131) {
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(patchId: patchId, record: cancelRecord))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(patchId: patchId, record: cancelRecord + 1))
    }

    private func recordOfOurTempBasal(
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
    private func newTempBasalRunning() -> String {
        PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 132, patchId: 251, start: Self.ourEnd.addingTimeInterval(1), rate: 0.5)
    }

    /// The record of the second of scheduled basal between the cancel and the set, `sequence`
    private func cancelsScheduledSecond(sequence: Int = 132) -> [String] {
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
    private func scheduledBasalRunning() -> String {
        PatchBytes.basalNotification(type: .STANDARD, sequence: 131, patchId: 251, start: Self.ourEnd, rate: 0.7)
    }

    /// Cancels it, the record the cancel names timing out. Returns its final.
    private func cancelItUnread(file: StaticString = #filePath, line: UInt = #line) -> DoseEntry? {
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

    /// No batch carries the scheduled basal after the cancel before `final` went out, nor the one `final` is of as
    /// mutable after
    private func assertScheduledBasalNeverBeforeTheFinal(of final: DoseEntry, file: StaticString = #filePath, line: UInt = #line) {
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
    @discardableResult private func startUnansweredTempBasal(
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

// MARK: - Suspends and resumes kept until the host stores them

extension ManagerTempBasalScenarioTests {
    /// A suspend command, the patch on its schedule: the host takes the state saved with the suspend's batch, and the app
    /// is killed before it stores the suspend - the host "fails" it. Kept with the state, the suspend goes out again with
    /// the next run's first batch, the resume command's, ahead of the resume: never a resume with no suspend before it.
    func testSuspendCommandTheHostDidNotStoreGoesOutAgainAfterARestart() throws {
        startOnTheSchedule()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        XCTAssertNil(commandSuspend())
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).first)
        XCTAssertEqual(pumpManager.state.heldBasalDoses.map(\.dose.type), [.suspend], "kept: the host did not store it")

        try restart(from: delegate.savedState)
        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()

        assertReportedAgain(suspend, aheadOf: .resume)
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty, "stored")
    }

    /// The same, the patch halting on its own: the halt's suspend goes out again ahead of the resume a status shows
    func testHaltTheHostDidNotStoreGoesOutAgainAfterARestart() throws {
        startOnTheSchedule()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.notify(PatchBytes.suspendNotification(suspendedAt: Self.patchTime(397_186_623)))
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).first)

        try restart(from: delegate.savedState)
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 513, patchId: 237, start: Self.patchTime(397_186_683), rate: 0.6))
        settle()

        assertReportedAgain(suspend, aheadOf: .resume)
    }

    /// A resume command, the host failing its batch, the app killed: the resume goes out again with the next run's first
    /// batch, the temp basal's - ahead of it. Lost, the suspend before it would stay open at the host: every temp basal
    /// after it zeroed.
    func testResumeCommandTheHostDidNotStoreGoesOutAgainAfterARestart() throws {
        startSuspendedAMinuteAgo()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()
        let resume = try XCTUnwrap(reports(of: .resume).first)

        try restart(from: delegate.savedState)
        setTempBasalOnTheSchedule()

        assertReportedAgain(resume, aheadOf: .tempBasal)
    }

    /// The same for the resume a status shows
    func testResumeShownTheHostDidNotStoreGoesOutAgainAfterARestart() throws {
        startSuspendedAMinuteAgo()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 513, patchId: 237, start: Self.patchTime(397_186_620), rate: 0.6))
        settle()
        let resume = try XCTUnwrap(reports(of: .resume).first)

        try restart(from: delegate.savedState)
        setTempBasalOnTheSchedule()

        assertReportedAgain(resume, aheadOf: .tempBasal)
    }

    /// The host failing a batch, no restart: the suspend goes out with every batch until the host stores one - here the
    /// resume's, ahead of the resume - and is done with then
    func testSuspendTheHostDidNotStoreGoesOutWithTheNextBatch() throws {
        startOnTheSchedule()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        XCTAssertNil(commandSuspend())
        settle()
        let suspend = try XCTUnwrap(reports(of: .suspend).first)
        XCTAssertEqual(delegate.batches.map(\.stored), [false])

        delegate.batchReply = .acknowledge
        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()

        let carried = try XCTUnwrap(delegate.batches.last?.events.compactMap(\.dose))
        XCTAssertEqual(carried.filter { $0.type == .suspend || $0.type == .resume }.map(\.type), [.suspend, .resume])
        XCTAssertEqual(carried.first { $0.type == .suspend }?.syncIdentifier, suspend.syncIdentifier)
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty)
        XCTAssertNil(delegate.savedState?["heldBasalDoses"])
    }

    /// A suspend and a resume command, the host failing both batches, the app killed - the patch out of reach since: both
    /// go out again, in order, with the first resend of what the host has yet to confirm - the loop's
    /// `ensureCurrentPumpData` - which needs no link, not with the patch's first status
    func testSuspendAndResumeTheHostDidNotStoreGoOutAgainAfterARestartWithNoLink() throws {
        startOnTheSchedule()
        delegate.batchReply = .fail(NSError(domain: "host", code: 1))
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        XCTAssertNil(commandSuspend())
        link.script(CommandType.RESUME_PUMP, fragments: "121d06000000010c000302ed004196ac17c000")
        XCTAssertNil(commandResume())
        settle()
        let kept = try [XCTUnwrap(reports(of: .suspend).first), XCTUnwrap(reports(of: .resume).first)]
        let written = link.writtenCommands.count

        try restart(from: delegate.savedState)
        pumpManager.resendUnacknowledgedFinalsIfDue()
        settle()

        XCTAssertEqual(link.writtenCommands.count, written, "no link")
        let doses = try XCTUnwrap(delegate.batches.first?.events.compactMap(\.dose))
        XCTAssertEqual(doses.map(\.syncIdentifier), kept.map(\.syncIdentifier), "again, in order")
        XCTAssertTrue(pumpManager.state.heldBasalDoses.isEmpty, "stored")

        pumpManager.resendUnacknowledgedFinalsIfDue()
        settle()
        XCTAssertEqual(delegate.batches.count, 1, "nothing left to send")
    }

    // MARK: The temp basal a suspend command ends

    /// A suspend while 1.2 U/h runs, the patch's status of it in a moment after the answer (device 2026-10-20 09:50:01-02,
    /// in the second of the answer - which the command raced, the temp basal finalized from our estimate): waited for, it
    /// ends the temp basal where the patch suspended, its record 131 read in the command - final from it.
    func testSuspendCommandWaitsForItsStatusAndReadsTheTempBasalsRecord() throws {
        let tempBasal = runTempBasalOfOurs()
        let delivered = notifySoonAfterTheSuspend(haltNotification(.suspended, at: Self.ourEnd, newestRecord: 131))
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35, endReason: .SUSPEND_MANUAL))
        XCTAssertNil(commandSuspend())
        wait(for: [delivered], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
        XCTAssertEqual(reports(of: .suspend).count, 1)
        XCTAssertEqual(pumpManager.state.basalDose.type, .suspend)
    }

    /// The same, no status in, a heartbeat naming 131 the newest record instead: the command ends the temp basal itself,
    /// reading up to 131 - final from its record
    func testSuspendCommandReadsUpToTheRecordAHeartbeatNamesAfterIt() throws {
        let tempBasal = runTempBasalOfOurs()
        let delivered = notifySoonAfterTheSuspend(Self.heartbeat(naming: 131))
        link.script(CommandType.GET_RECORD, recordOfOurTempBasal(delivered: 0.35, endReason: .SUSPEND_MANUAL))
        XCTAssertNil(commandSuspend())
        wait(for: [delivered], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.35, accuracy: 0.001, "from its record")
    }

    /// The same, 131 unreadable: our estimate stands in, as before
    func testSuspendCommandWithTheTempBasalsRecordUnreadableFinalizesItFromOurEstimate() throws {
        let tempBasal = runTempBasalOfOurs()
        let delivered = notifySoonAfterTheSuspend(Self.heartbeat(naming: 131))
        link.script(CommandType.GET_RECORD, .timeout)
        XCTAssertNil(commandSuspend())
        wait(for: [delivered], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.4, accuracy: 0.001, "1.2 U/h for 20 min, by our estimate")
    }

    /// Nothing announced within the wait: the suspend - and the temp basal's end, by our estimate - is dated at the
    /// answer, not after the wait: the temp basal's rate counted over it, the patch suspended
    func testSuspendCommandWithNothingAnnouncedIsDatedAtItsAnswer() throws {
        let tempBasal = runTempBasalOfOurs()
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        let sentAt = Date.now
        XCTAssertNil(commandSuspend())
        XCTAssertGreaterThanOrEqual(Date.now.timeIntervalSince(sentAt), MedtrumPumpManager.suspendAnnouncementWait, "waited")
        settle()

        let suspend = try XCTUnwrap(reports(of: .suspend).first)
        XCTAssertLessThan(suspend.startDate.timeIntervalSince(sentAt), 1, "at the answer")
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.endDate, suspend.startDate)
    }

    /// Nothing announced within the wait, record 131 told of before the write and unread: the patch may have ended the
    /// temp basal before, unseen - it did, 5 min ago. 131 is read: final from it, not from our estimate up to the suspend.
    func testSuspendCommandWithNothingAnnouncedReadsTheRecordsUnreadBeforeIt() throws {
        let tempBasal = runTempBasalOfOurs()
        pumpManager.state.currentSequenceNumber = 131
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.ourStart, end: Self.ourEnd.addingTimeInterval(-5 * Self.minute),
            rate: 1.2, delivered: 0.3, endReason: .SUSPEND_LOW_GLUCOSE
        ))
        XCTAssertNil(commandSuspend())
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.3, accuracy: 0.001, "from its record, not 0.4 U by our estimate")
    }

    /// A temp basal past its end - it ran its course, its record 131 told of and unread: no announcement is waited for,
    /// and 131 is read - final from it
    func testSuspendCommandAfterATempBasalRanItsCourseReadsItsRecordWithoutWaiting() throws {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        let tempBasal = runningTempBasal(rate: 1.2, startedAgo: 40 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.ourStart)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        state.currentSequenceNumber = 131
        alignPatchClock(state, patchTime: Self.ourStart.addingTimeInterval(40 * Self.minute))
        makeManager(state)
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        link.script(CommandType.GET_RECORD, PatchBytes.basalRecord(
            sequence: 131, patchId: 251, type: .ABSOLUTE_TEMP, start: Self.ourStart, end: Self.ourStart.addingTimeInterval(30 * Self.minute),
            rate: 1.2, delivered: 0.55, endReason: .SUCCESS
        ))

        let sentAt = Date.now
        XCTAssertNil(commandSuspend())
        XCTAssertLessThan(Date.now.timeIntervalSince(sentAt), MedtrumPumpManager.suspendAnnouncementWait, "not waited")
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SUSPEND_PUMP, CommandType.GET_RECORD])
        let final = try XCTUnwrap(reports(of: .tempBasal).first { $0.startDate == tempBasal.startDate && !$0.isMutable })
        XCTAssertEqual(final.deliveredUnits ?? 0, 0.55, accuracy: 0.001, "from its record, not 0.6 U by our estimate")
    }

    // MARK: After a resume dated ahead

    /// Suspended in this very second: the resume a status shows is dated in the next - up to a second ahead of now. A
    /// halt in that second is dated just after the resume, not at it: at its instant, Loop orders the two either way.
    func testHaltInTheSecondOfAResumeDatedAheadIsDatedJustAfterIt() throws {
        let resume = try resumeDatedAhead()
        link.notify(PatchBytes.suspendNotification(suspendedAt: Self.patchTime(397_186_623)))
        settle()

        let halt = try XCTUnwrap(reports(of: .suspend).last)
        XCTAssertGreaterThan(halt.startDate, resume.startDate)
        XCTAssertEqual(LoopOrderingChecker.stored(halt.startDate), LoopOrderingChecker.stored(resume.startDate), "in its second")
    }

    /// A suspend command in that second: dated after the resume, not at now - before it, oref0 would pair the suspend
    /// before the resume with it as well
    func testSuspendCommandInTheSecondOfAResumeDatedAheadIsDatedAfterIt() throws {
        let resume = try resumeDatedAhead()
        link.script(CommandType.SUSPEND_PUMP, fragments: "071c050000001800")
        XCTAssertNil(commandSuspend())
        settle()

        let suspend = try XCTUnwrap(reports(of: .suspend).last)
        XCTAssertGreaterThan(suspend.startDate, resume.startDate)
    }

    /// A temp basal set in that second starts after the resume, not before it
    func testTempBasalSetInTheSecondOfAResumeDatedAheadStartsAfterIt() throws {
        let resume = try resumeDatedAhead()
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1.2, sequence: 513, patchId: 237, start: Self.patchTime(397_186_623)
        ))
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        settle()

        let tempBasal = try XCTUnwrap(reports(of: .tempBasal).first)
        XCTAssertGreaterThan(tempBasal.startDate, resume.startDate)
    }

    // MARK: The unanswered one shown late

    /// The patch halts while the unanswered one is kept - a segment begun after it, the halt's - then resumes on a command
    /// whose answer tells no segment: a late status of the zero one's segment is late all the same, by that later segment.
    /// Kept, nothing reported. Taken to run from here, it would be dated over the suspension and the resume.
    func testUnansweredTempBasalShownAfterTheResumeOfAReportedSuspendIsLate() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 119))
        settle()
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.snapshot.laterSegmentStart, Self.c1)

        advanceClock(by: 2)
        link.script(CommandType.RESUME_PUMP, PatchBytes.answer(command: CommandType.RESUME_PUMP, body: Data()))
        XCTAssertNil(commandResume())
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        let batches = delegate.batches.count

        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: Self.patchTime(399_933_337), rate: 0
        ))
        settle()

        XCTAssertEqual(pumpManager.state.basalDose.type, .resume)
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal, "kept, its record to settle it")
        XCTAssertEqual(delegate.batches.count, batches, "nothing reported")
        XCTAssertFalse(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 })
    }

    /// The zero one shown late - it ran - and no record read up to past the halt is its, the halt's the schedule's: not
    /// dropped as never run, silently - warned of, shown not counted. Nothing of it is reported.
    func testUnansweredTempBasalShownLateWithNoRecordOfItsIsWarnedOf() throws {
        startUnansweredTempBasal()
        advanceClock(by: 302)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 119))
        settle()
        notifyOnTheManagersClock(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP, sequence: 119, patchId: 251, start: Self.patchTime(399_933_337), rate: 0
        ))
        settle()
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.snapshot.shownRunningFrom, Self.patchTime(399_933_337))

        advanceClock(by: 2)
        notifyOnTheManagersClock(Self.halted(at: Self.c1, newestRecord: 120))
        link.script(CommandType.GET_RECORD, Self.secondOfSchedule(120, at: Self.c1))
        syncRecords()
        XCTAssertNotNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 0)

        advanceClock(by: 16 * Self.minute)
        confirmRecordSequence()
        syncRecords()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertTrue(uncertain.contains { $0.kind == .tempBasal && $0.phase == .settled(.notCounted) })
        XCTAssertFalse(reports(of: .tempBasal).contains { $0.unitsPerHour < 0.01 })
    }

    // MARK: Driving

    /// Patch 237 on its schedule, 0.6 U/h, every record read up to 513, the patch clock `397_186_623` now
    private func startOnTheSchedule() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        makeManager(state)
    }

    /// 1.2 U/h set on the schedule of `startOnTheSchedule`, answered: no cancel before it
    private func setTempBasalOnTheSchedule() {
        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: 1.2, sequence: 515, patchId: 237, start: Self.patchTime(397_186_630)
        ))
        XCTAssertNil(commandTempBasal(1.2, duration: 30 * Self.minute))
        settle()
    }

    /// `dose`, which the host did not store, goes out again in the first batch carrying a dose of `later` - ahead of it
    private func assertReportedAgain(_ dose: DoseEntry, aheadOf later: DoseType, file: StaticString = #filePath, line: UInt = #line) {
        guard let batch = delegate.batches.first(where: { $0.events.contains { $0.dose?.type == later } }) else {
            XCTFail("no batch carries a \(later)", file: file, line: line)
            return
        }
        let doses = batch.events.compactMap(\.dose)
        let again = doses.firstIndex { $0.syncIdentifier == dose.syncIdentifier }
        XCTAssertNotNil(again, "the \(dose.type) of \(dose.startDate) did not go out again", file: file, line: line)
        XCTAssertLessThan(again ?? .max, doses.firstIndex { $0.type == later } ?? -1, "ahead of it", file: file, line: line)
    }

    /// `hex` notified 0.3 s after the suspend command's answer - off the command's thread, as the patch sends it after
    /// its answer: fulfilled once handled
    private func notifySoonAfterTheSuspend(_ hex: String) -> XCTestExpectation {
        let delivered = expectation(description: "notified after the answer")
        let link = link!
        link.script(CommandType.SUSPEND_PUMP, .fragments(["071c050000001800"])) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                link.notify(hex)
                delivered.fulfill()
            }
        }
        return delivered
    }

    /// The patch's heartbeat naming `record` its newest, of patch 251
    private static func heartbeat(naming record: Int) -> String {
        "200001" + (UInt64(record).toData(length: 2) + UInt64(251).toData(length: 2)).hexEncodedString()
    }

    /// Suspended in this second - the host told so in a run before - then a status of the schedule: the resume is dated
    /// in the next second, ahead of now. Returns it.
    private func resumeDatedAhead() throws -> DoseEntry {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 513, reservoir: 143.95)
        // The clock aligned first: the schedule shown from then, before the second after the suspend's
        alignPatchClock(state, patchTime: Self.patchTime(397_186_623))
        let suspendedAt = Date(timeIntervalSinceReferenceDate: Date.now.timeIntervalSinceReferenceDate.rounded(.down))
        state.basalDose = UnfinalizedDose(suspendStartTime: suspendedAt)
        state.basalState = .suspended
        makeManager(state)
        hostSuspendedSince = suspendedAt

        link.notify(PatchBytes.basalNotification(type: .STANDARD, sequence: 513, patchId: 237, start: Self.patchTime(397_186_623), rate: 0.6))
        settle()
        let resume = try XCTUnwrap(reports(of: .resume).first)
        XCTAssertEqual(resume.startDate, suspendedAt.addingTimeInterval(1), "dated ahead, in the next second")
        return resume
    }
}

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
        XCTAssertEqual(finals(of: doses.first).count, 1)

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
        XCTAssertEqual(finals(of: doses.first).count, 1)
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

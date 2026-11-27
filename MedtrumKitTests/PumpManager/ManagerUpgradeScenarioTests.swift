import LoopKit
@testable import MedtrumKit
import XCTest

/// Upgrading from the released driver - the state `fix/better-attempts` (e2bce22) saves - in the middle of a patch: its
/// records written before carry the doses the old build reported, which the host has. None of them is a bolus the host is
/// missing, nor a dose to report again.
final class ManagerUpgradeScenarioTests: MedtrumManagerTestCase {
    private static let patchId: UInt64 = 236
    private static let scheduledRate = 0.6

    /// The newest record the patch has written as the upgraded app first hears from it
    private static let firstStatusRecord = 530

    /// How far the patch clock is ahead of the phone's, as the released driver's state has it: a few seconds, as patches
    /// run (protocol fact C1)
    private var patchClockAhead: TimeInterval = -5

    // MARK: Scenarios

    /// The app upgraded while a temp basal of the old build runs, the patch's last 20 records holding boluses, cancelled
    /// ones too, and temp basals - one at the running rate - the old build reported. The host saves the state before the
    /// patch is heard from. The first status takes the patch up at its newest record: the records up to it are history.
    func testUpgradeMidPatchTakesThePatchUpAtTheFirstStatusRecord() throws {
        let t0 = Date.now
        let tempBasalStart = t0.addingTimeInterval(-10 * Self.minute)
        let legacyTempBasal: [String: Any] = [
            "type": DoseType.tempBasal.rawValue,
            "value": 1.2,
            "startDate": tempBasalStart,
            "estimatedEndDate": tempBasalStart.addingTimeInterval(30 * Self.minute),
            "deliveredUnits": 0.0,
            "insulinType": InsulinType.novolog.rawValue,
            "automatic": true
        ]
        makeManager(MedtrumPumpState(rawValue: try roundTripped(legacyState(
            at: t0,
            basalDose: legacyTempBasal,
            basalState: .tempBasal
        ))))
        // Saved before the patch is heard from: what the old state did not say stays unsaid
        try restart(from: pumpManager.rawState)

        // The patch started it a moment before the old build had its answer
        let patchStart = onPatch(tempBasalStart.addingTimeInterval(-2))
        link.deliverFullStatus(notification: Self.status(
            bolus: (completed: true, delivered: 0.5),
            basal: (type: .ABSOLUTE_TEMP, start: patchStart, rate: 1.2, delivered: 0.2),
            reservoir: 120,
            storage: Self.firstStatusRecord
        ), duringReconnect: true)
        settle()

        XCTAssertEqual(pumpManager.state.sessionStartSequence, Self.firstStatusRecord, "taken up at the first status's record")
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, Self.firstStatusRecord)

        // The last 20 records, read as for a new patch
        let records = backlog(before: t0, through: Self.firstStatusRecord, patchStart: patchStart)
        for record in records {
            link.script(CommandType.GET_RECORD, record)
        }
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, Self.firstStatusRecord)
        XCTAssertEqual(pumpManager.recordStore.records.count, 20)
        XCTAssertEqual(pumpManager.recordStore.records.filter { $0.kind == "BOLUS" }.map(\.outcome), [
            "unmatched",
            "unmatched",
            "unmatched",
            "unmatched",
            "unmatched"
        ])

        // Nothing told, nothing reported again, nothing uncertain
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [])
        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty)
        XCTAssertFalse(pumpManager.state.deliveryIsUncertain)
        XCTAssertTrue(reports(of: .bolus).isEmpty)
        XCTAssertTrue(
            reports(of: .tempBasal).allSatisfy { $0.startDate == tempBasalStart && $0.isMutable },
            "only the running one, as running"
        )
        XCTAssertTrue(pumpManager.state.awaitingRecord.isEmpty)

        // The old build's temp basal carries over, running
        let running = pumpManager.state.basalDose
        XCTAssertEqual(running.type, .tempBasal)
        XCTAssertEqual(running.startDate, tempBasalStart)
        XCTAssertEqual(running.value, 1.2, accuracy: 0.001)
        XCTAssertFalse(running.isFinished)
        XCTAssertEqual(running.pumpStartTime, patchStart)
        XCTAssertEqual(pumpManager.state.basalState, .tempBasal)
    }

    /// The app upgraded while a bolus of the old build delivers - its answer's record number never kept. Its record,
    /// written after the first status, is that bolus's: it finalizes it, nothing the host is missing. An old bolus of the
    /// same amount in the backlog is not taken for it.
    func testUpgradeDuringABolusFinalizesItFromItsRecord() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-20)
        let legacyBolus: [String: Any] = [
            "type": DoseType.bolus.rawValue,
            "value": 1.0,
            "startDate": bolusStart,
            "estimatedEndDate": bolusStart.addingTimeInterval(60),
            "deliveredUnits": 0.3,
            "insulinType": InsulinType.novolog.rawValue,
            "automatic": false
        ]
        let scheduleStart = t0.addingTimeInterval(-Self.hour)
        let legacyBasal = Self.legacyKeys(
            of: UnfinalizedDose(basalRate: Self.scheduledRate, insulinType: .novolog, startDate: scheduleStart).rawValue
        )
        makeManager(MedtrumPumpState(rawValue: try roundTripped(legacyState(
            at: t0,
            bolusDose: legacyBolus,
            basalDose: legacyBasal,
            basalState: .active
        ))))

        let running = try XCTUnwrap(pumpManager.state.bolusDose, "the bolus carries over")
        XCTAssertEqual(running.startDate, bolusStart)
        XCTAssertFalse(running.isFinished)

        // Still delivering as the patch is first heard from
        let patchScheduleStart = onPatch(scheduleStart)
        link.deliverFullStatus(notification: Self.status(
            bolus: (completed: false, delivered: 0.6),
            basal: (type: .STANDARD, start: patchScheduleStart, rate: Self.scheduledRate, delivered: 0.5),
            reservoir: 120,
            storage: Self.firstStatusRecord
        ), duringReconnect: true)
        settle()
        XCTAssertEqual(pumpManager.state.sessionStartSequence, Self.firstStatusRecord)

        // It completes: its record is the next
        link.notify(Self.status(bolus: (completed: true, delivered: 1.0), storage: Self.firstStatusRecord + 1))
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 1)

        // The last 20 records - fillers, and an old 1 U bolus - its record the newest
        let first = Self.firstStatusRecord - 18
        for sequence in first ... Self.firstStatusRecord {
            if sequence == 525 {
                link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
                    sequence: sequence,
                    patchId: Self.patchId,
                    start: onPatch(t0.addingTimeInterval(-30 * Self.minute)),
                    amount: 1.0,
                    delivered: 1.0
                ))
            } else {
                link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 5, sequence: sequence, patchId: Self.patchId))
            }
        }
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: Self.firstStatusRecord + 1,
            patchId: Self.patchId,
            start: onPatch(bolusStart.addingTimeInterval(-2)),
            amount: 1.0,
            delivered: 1.0
        ))
        syncRecords()
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, Self.firstStatusRecord + 1)
        XCTAssertEqual(pumpManager.recordStore.records.first { $0.id == 525 }?.outcome, "unmatched")
        XCTAssertEqual(
            pumpManager.recordStore.records.first { $0.id == Self.firstStatusRecord + 1 }?.outcome,
            "finalized bolus \(bolusStart)"
        )

        // One bolus, the old build's, final from its record
        XCTAssertEqual(Set(reports(of: .bolus).map(\.startDate)), [bolusStart])
        let finals = finals(of: reports(of: .bolus).first)
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals.first?.deliveredUnits ?? 0, 1.0, accuracy: 0.001)
        XCTAssertTrue(pumpManager.state.awaitingRecord.isEmpty)

        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [])
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// The app upgraded while a bolus of the old build delivers, a bolus of the same amount cancelled 30 s before it - its
    /// record in the backlog - and it completes after the first status: its own record, past the session start, finalizes
    /// it. The cancelled one is not taken for it - the patch started it 30 s before the old build had this one's answer -
    /// nor is its own told of as a bolus not counted.
    func testUpgradeDuringABolusTakesNotTheRecordOfOneCancelledBeforeIt() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-20)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)

        // Still delivering as the patch is first heard from
        deliverFirstStatus(bolus: (completed: false, delivered: 0.6), scheduleStart: scheduleStart)
        XCTAssertEqual(pumpManager.state.sessionStartSequence, Self.firstStatusRecord)
        XCTAssertNotNil(pumpManager.state.bolusDose)

        // It completes: its record is the next
        link.notify(Self.status(bolus: (completed: true, delivered: 1.0), storage: Self.firstStatusRecord + 1))
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        let ownStart = onPatch(bolusStart.addingTimeInterval(-2))
        let cancelled = Self.firstStatusRecord
        let own = Self.firstStatusRecord + 1
        scriptBacklog(through: own, bolusRecords: [
            cancelled: (start: ownStart.addingTimeInterval(-30), amount: 1.0, delivered: 0.2),
            own: (start: ownStart, amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, own)
        XCTAssertEqual(outcome(of: cancelled), "unmatched")
        XCTAssertEqual(outcome(of: own), "finalized bolus \(bolusStart)")
        assertFinal(ofTheBolusOf: bolusStart, delivered: 1.0)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// A bolus of the old build ran its course while the app was down - its record written before the first status, in
    /// the backlog, after that of a bolus of the same amount cancelled 30 s before it. Past its deadline, it ends unseen
    /// at the first status - not told of as uncertain, its record still to be read - and the backlog read finalizes it
    /// from its own record, the newest before a record of another kind: nothing told, nothing uncertain.
    func testUpgradeAfterABolusRanItsCourseFinalizesItFromItsOwnRecordInTheBacklog() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-10 * Self.minute)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)

        // The status repeats the last bolus's completion, as every full status does
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)
        XCTAssertNil(pumpManager.state.bolusDose, "past its deadline: over, its end unseen")
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .completionNotSeen)
        XCTAssertEqual(uncertainDeliveryErrors, 0, "its record is still to be read")
        XCTAssertTrue(uncertain.isEmpty)

        let ownStart = onPatch(bolusStart.addingTimeInterval(-2))
        let cancelled = Self.firstStatusRecord - 2
        let own = Self.firstStatusRecord - 1
        scriptBacklog(through: Self.firstStatusRecord, bolusRecords: [
            cancelled: (start: ownStart.addingTimeInterval(-30), amount: 1.0, delivered: 0.2),
            own: (start: ownStart, amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, Self.firstStatusRecord)
        XCTAssertEqual(outcome(of: cancelled), "unmatched")
        XCTAssertEqual(outcome(of: own), "kept for bolus \(bolusStart)", "finalizing it once the newest is read")
        assertFinal(ofTheBolusOf: bolusStart, delivered: 1.0)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// The same, a bolus of the same amount started 6 s before its record's start - cancelled at once, this one started
    /// right after: both within the window its record is looked for in. The newer is its own - the older written first.
    func testUpgradeAfterABolusRanItsCourseTakesTheNewerOfTwoRecordsInItsWindow() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-10 * Self.minute)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)
        XCTAssertNil(pumpManager.state.bolusDose)

        let ownStart = onPatch(bolusStart.addingTimeInterval(-2))
        let cancelled = Self.firstStatusRecord - 1
        let own = Self.firstStatusRecord
        scriptBacklog(through: Self.firstStatusRecord, bolusRecords: [
            cancelled: (start: ownStart.addingTimeInterval(-6), amount: 1.0, delivered: 0.1),
            own: (start: ownStart, amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()

        XCTAssertEqual(outcome(of: cancelled), "kept for bolus \(bolusStart)", "a newer one may follow")
        XCTAssertEqual(outcome(of: own), "finalized bolus \(bolusStart)")
        assertFinal(ofTheBolusOf: bolusStart, delivered: 1.0)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// The same, the newest record - the session start's - out of reach: the one read is kept, but it may be that of a
    /// bolus before, the newest its own. It never finalizes it: our estimate does, in full, its delivery uncertain.
    func testUpgradeAfterABolusRanItsCourseTakesNoRecordKeptWithTheNewestUnread() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-10 * Self.minute)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)

        // Cut short - its own, or another's
        let own = Self.firstStatusRecord - 1
        scriptBacklog(from: Self.firstStatusRecord - 19, through: own, bolusRecords: [
            own: (start: onPatch(bolusStart.addingTimeInterval(-2)), amount: 1.0, delivered: 0.9)
        ])
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, own)
        XCTAssertEqual(outcome(of: own), "kept for bolus \(bolusStart)")
        XCTAssertTrue(finals(of: reports(of: .bolus).first).isEmpty)

        // Waited for its record as long as any dose does
        advanceClock(by: MedtrumPumpManager.awaitingRecordMaximumWait + Self.minute)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()

        assertFinalByEstimate(ofTheBolusOf: bolusStart, delivered: 1.0)
        XCTAssertNil(pumpManager.state.releasedBolusBacklogRecord)
    }

    /// A bolus of the old build completed during the upgrade, the app back before its deadline: the first full status
    /// repeats the last bolus's completion - every full status does, for hours, so it does not end this one. It stays in
    /// progress until its deadline, and ends unseen at the next full status - not told of as uncertain: its record, in
    /// the backlog, finalizes it, read next.
    func testUpgradeAsABolusCompletesWaitsForItsDeadlineThenItsOwnRecord() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-40)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)

        let running = try XCTUnwrap(pumpManager.state.bolusDose, "still in progress: the completion may be the last bolus's")
        XCTAssertFalse(running.isFinished)
        // Not read while it runs
        syncRecords()
        XCTAssertFalse(link.writtenCommands.contains(CommandType.GET_RECORD))

        // Past its deadline, the next full status
        let deadline = running.deliveryDeadline(of: running.snapshot)
        advanceClock(by: deadline.timeIntervalSince(pumpManager.now()) + 1)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .completionNotSeen)
        XCTAssertEqual(uncertainDeliveryErrors, 0, "its record is still to be read")
        XCTAssertTrue(uncertain.isEmpty)

        let own = Self.firstStatusRecord
        scriptBacklog(through: own, bolusRecords: [
            own: (start: onPatch(bolusStart.addingTimeInterval(-2)), amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()

        XCTAssertEqual(outcome(of: own), "finalized bolus \(bolusStart)")
        assertFinal(ofTheBolusOf: bolusStart, delivered: 1.0)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// No status named the newest record yet - a notification showing only the basal segment, its record number with
    /// it: the cursor stays, no record is read until the session start is known. Read before, the records up to it would
    /// never be looked at.
    func testNoRecordIsReadUntilAStatusNamesTheNewestRecord() throws {
        let t0 = Date.now
        let scheduleStart = makeManagerWithReleasedBolus(nil, since: t0, at: t0)
        let patchScheduleStart = onPatch(scheduleStart)

        link.notify(PatchBytes.basalNotification(
            type: .STANDARD,
            sequence: Self.firstStatusRecord,
            patchId: Self.patchId,
            start: patchScheduleStart,
            rate: Self.scheduledRate,
            delivered: 0.5
        ))
        settle()
        XCTAssertNil(pumpManager.state.sessionStartSequence)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 0)

        syncRecords()
        XCTAssertFalse(link.writtenCommands.contains(CommandType.GET_RECORD))

        deliverFirstStatus(bolus: (completed: true, delivered: 0.5), scheduleStart: scheduleStart)
        XCTAssertEqual(pumpManager.state.sessionStartSequence, Self.firstStatusRecord)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, Self.firstStatusRecord)
    }

    /// The state the released driver saves decodes without loss, and saves again as it was: its bolus with when it was
    /// sent - its start - the session start unknown until a status names the newest record, the cursors at 0
    func testReleasedStateDecodesAndSavesAgainAsItWas() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-20)
        let bolus = Self.releasedBolus(1.5, since: bolusStart)
        let tempBasalStart = t0.addingTimeInterval(-10 * Self.minute)
        let tempBasal: [String: Any] = [
            "type": DoseType.tempBasal.rawValue,
            "value": 1.2,
            "startDate": tempBasalStart,
            "estimatedEndDate": tempBasalStart.addingTimeInterval(30 * Self.minute),
            "deliveredUnits": 0.0,
            "insulinType": InsulinType.novolog.rawValue,
            "automatic": true
        ]
        let released = try roundTripped(legacyState(at: t0, bolusDose: bolus, basalDose: tempBasal, basalState: .tempBasal))

        let state = MedtrumPumpState(rawValue: released)
        let running = try XCTUnwrap(state.bolusDose)
        XCTAssertEqual(running.value, 1.5, accuracy: 0.001)
        XCTAssertEqual(running.deliveredUnits, 0.3, accuracy: 0.001)
        XCTAssertEqual(running.confirmation, .confirmed)
        XCTAssertFalse(running.isFinished)
        XCTAssertEqual(running.sentAt, bolusStart, "dated as its answer came: sent then, as far as its record is matched")
        XCTAssertNil(running.snapshot.sequenceAtSend)
        XCTAssertNil(running.recordSequence)
        XCTAssertEqual(state.basalDose.type, .tempBasal)
        XCTAssertNil(state.basalDose.pumpStartTime)
        XCTAssertNil(state.sessionStartSequence, "taken from the next status")
        XCTAssertEqual(state.currentSequenceNumber, 0)
        XCTAssertEqual(state.syncedSequenceNumber, 0)
        XCTAssertNil(state.sequenceConfirmedAt)
        XCTAssertTrue(state.awaitingRecord.isEmpty)
        XCTAssertNil(state.pendingBolus)
        XCTAssertNil(state.unconfirmedTempBasal)
        XCTAssertFalse(state.deliveryIsUncertain)

        let saved = state.rawValue
        XCTAssertNil(saved["sessionStartSequence"], "not saved until known")
        for (key, value) in released where key != "bolusDose" {
            XCTAssertEqual(saved[key] as? NSObject, value as? NSObject, "\(key) saved again as it was")
        }
        XCTAssertEqual(saved["bolusDose"] as? NSDictionary, bolus.merging(["sentAt": bolusStart]) { $1 } as NSDictionary)
    }

    // MARK: Its record past the session start; the newest in the backlog

    /// The app upgraded while a bolus of the old build delivers. It completes after the first status: its record, past
    /// the session start, is its own wherever it starts - here 4 s after its answer came, more than the skew's usual
    /// error. It finalizes it, nothing told.
    func testUpgradeDuringABolusTakesItsRecordPastTheSessionStartStartingAfterItsAnswer() throws {
        assertRecordPastTheSessionStartFinalizes(startingAfterItsAnswer: 4)
    }

    /// The same, the patch clock 8 s ahead, its record starting 10 s after its answer came, skew taken off - the skew
    /// further off, or the patch clock set again from the settings since
    func testUpgradeDuringABolusTakesItsRecordPastTheSessionStartWithTheSkewOff() throws {
        patchClockAhead = 8
        assertRecordPastTheSessionStartFinalizes(startingAfterItsAnswer: 10)
    }

    /// The app upgraded while a bolus of the old build delivers, a bolus of the same amount cancelled at once before it -
    /// its record the newest the first status names. The completion names that record still, its own written a moment
    /// later (device 2026-10-20 00:52:56). Seen delivering, its record is past the session start: the cancelled one's,
    /// read up to the newest named, is not taken for it. It waits for its own, named next, and goes final from it.
    func testUpgradeDuringABolusWaitsPastAStaleCompletionForItsOwnRecord() throws {
        assertStaleCompletionWaitsForItsOwnRecord(seenDelivering: true)
    }

    /// The same, its completion the first the app hears of the patch, taking it up at the cancelled one's record: seen
    /// completing, its record is past the session start just as well
    func testUpgradeAsABolusCompletesWaitsPastItsStaleCompletionForItsOwnRecord() throws {
        assertStaleCompletionWaitsForItsOwnRecord(seenDelivering: false)
    }

    /// A bolus of the old build ran its course while the app was down, its record starting 2.5 s after its answer came:
    /// a bolus of the same amount cancelled at once 4 s before, starting nearer to then. Both in the backlog, the newer is
    /// its own, at what it delivered.
    func testUpgradeAfterABolusRanItsCourseTakesItsOwnRecordOverANearerOneBeforeIt() throws {
        let (bolusStart, cancelled, own) = makeManagerAfterABolusRanItsCourseWithTwoRecords(newest: Self.firstStatusRecord)
        scriptBacklog(through: Self.firstStatusRecord, bolusRecords: [cancelled.sequence: cancelled.record, own.sequence: own.record])
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, Self.firstStatusRecord)
        XCTAssertEqual(outcome(of: cancelled.sequence), "kept for bolus \(bolusStart)", "a newer one may follow")
        XCTAssertEqual(outcome(of: own.sequence), "finalized bolus \(bolusStart)")
        assertFinal(ofTheBolusOf: bolusStart, delivered: 0.95)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// The same, the newest record unread as the app is killed: the record kept for it is saved, and finalizes it once
    /// the newest is read after the restart
    func testUpgradeAfterABolusRanItsCourseKeepsItsBacklogRecordOverARestart() throws {
        let (bolusStart, cancelled, own) = makeManagerAfterABolusRanItsCourseWithTwoRecords(newest: Self.firstStatusRecord - 1)
        scriptBacklog(
            from: Self.firstStatusRecord - 19,
            through: own.sequence,
            bolusRecords: [cancelled.sequence: cancelled.record, own.sequence: own.record]
        )
        link.script(CommandType.GET_RECORD, .timeout)
        syncRecords()
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, own.sequence)
        XCTAssertEqual(outcome(of: own.sequence), "kept for bolus \(bolusStart)")
        XCTAssertEqual(pumpManager.state.releasedBolusBacklogRecord?.sequence, own.sequence)
        XCTAssertTrue(finals(of: reports(of: .bolus).first).isEmpty)

        try restart(from: pumpManager.rawState)
        XCTAssertEqual(pumpManager.state.releasedBolusBacklogRecord?.sequence, own.sequence, "saved")

        link.notify(Self.status(storage: Self.firstStatusRecord))
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 5, sequence: Self.firstStatusRecord, patchId: Self.patchId))
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, Self.firstStatusRecord)
        assertFinal(ofTheBolusOf: bolusStart, delivered: 0.95)
        XCTAssertNil(pumpManager.state.releasedBolusBacklogRecord)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
    }

    /// A bolus of the old build ran its course while the app was down, no record in the backlog its own - none of its
    /// amount in its window. Final by our estimate once its record is overdue, in full - the user told its delivery is
    /// uncertain then, not before.
    func testUpgradeAfterABolusRanItsCourseWithNoRecordOfItGoesFinalByEstimateUncertain() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-10 * Self.minute)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)

        scriptBacklog(through: Self.firstStatusRecord, bolusRecords: [:])
        syncRecords()
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, Self.firstStatusRecord)
        XCTAssertTrue(finals(of: reports(of: .bolus).first).isEmpty)
        XCTAssertEqual(uncertainDeliveryErrors, 0, "its record not overdue yet")
        XCTAssertTrue(uncertain.isEmpty)

        advanceClock(by: MedtrumPumpManager.awaitingRecordMaximumWait + Self.minute)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()

        assertFinalByEstimate(ofTheBolusOf: bolusStart, delivered: 1.0)
    }

    /// No status named the newest record yet, and a temp basal is set over the schedule: the record its answer names -
    /// of the scheduled segment it ended - moves no cursor, and no record is read. Moved, the records up to it would never
    /// be looked at.
    func testNoCommandAnswerMovesTheCursorUntilAStatusNamesTheNewestRecord() throws {
        let t0 = Date.now
        makeManagerWithReleasedBolus(nil, since: t0, at: t0)

        link.script(CommandType.SET_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: 2.1,
            sequence: Self.firstStatusRecord,
            patchId: Self.patchId,
            start: onPatch(t0)
        ))
        XCTAssertNil(commandTempBasal(2.1, duration: 30 * Self.minute))
        settle()
        XCTAssertEqual(pumpManager.state.basalDose.type, .tempBasal)

        XCTAssertNil(pumpManager.state.sessionStartSequence)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 0)
        XCTAssertNil(pumpManager.state.sequenceConfirmedAt)
        syncRecords()
        XCTAssertFalse(link.writtenCommands.contains(CommandType.GET_RECORD))
    }

    // MARK: Rule A's bounds, rule B's gate and window, a final by estimate explaining later records

    /// A bolus of the old build ran its course while the app was down, its own record in the backlog. Before the first
    /// record sync, a bolus of the same amount goes out, its answer lost, and completes: its record is the first past
    /// the session start. That record is the lost-answer bolus's - the old build's bolus wrote its own before the
    /// session start - and the old build's goes final from its own, kept from the backlog.
    func testUpgradeAfterABolusRanItsCourseLeavesALaterLostAnswerBolusItsRecord() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-10 * Self.minute)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .completionNotSeen)

        let lostAnswer = try sendLostAnswerBolus(1.0, completingWithRecord: Self.firstStatusRecord + 1)

        let own = Self.firstStatusRecord - 1
        let lostAnswersRecord = Self.firstStatusRecord + 1
        scriptBacklog(through: lostAnswersRecord, bolusRecords: [
            // Within its window either way the skew is taken
            own: (start: onPatch(bolusStart.addingTimeInterval(3)), amount: 1.0, delivered: 0.95),
            lostAnswersRecord: (start: onPatch(lostAnswer.sentAt.addingTimeInterval(1)), amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, lostAnswersRecord)
        XCTAssertEqual(outcome(of: own), "kept for bolus \(bolusStart)")
        XCTAssertEqual(outcome(of: lostAnswersRecord), "finalized bolus \(lostAnswer.start)")
        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [0.95], "from its own record")
        XCTAssertEqual(finalDelivered(ofTheBolusOf: lostAnswer.start), [1.0], "from its record")
        XCTAssertTrue(pumpManager.state.awaitingRecord.allSatisfy(\.isFinalized))
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [])
        XCTAssertEqual(uncertainDeliveryErrors, 1, "the lost answer, once")
        XCTAssertEqual(uncertain.map(\.cause), [.unanswered])
        XCTAssertEqual(uncertain.first?.phase, .settled(.byRecord))
    }

    /// A bolus of the old build completed as the app was upgraded, its completion the first the app hears of the patch,
    /// its own record the one that completion names - at the session start. A bolus of the same amount goes out, its
    /// answer lost, and completes: its record, past the session start and starting after it went out, is its own, not
    /// taken for the old build's - which goes final from what its completion said, once its record is overdue.
    func testUpgradeAsABolusCompletesLeavesALaterLostAnswerBolusItsRecord() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-20)
        makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        link.notify(Self.status(bolus: (completed: true, delivered: 1.0), storage: Self.firstStatusRecord))
        settle()
        XCTAssertEqual(pumpManager.state.sessionStartSequence, Self.firstStatusRecord)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .completed)

        // Before the old build's bolus's deadline: by when it went out alone, the lost-answer bolus's record could be its
        let lostAnswer = try sendLostAnswerBolus(1.0, completingWithRecord: Self.firstStatusRecord + 1)
        let waiting = try XCTUnwrap(pumpManager.state.awaitingRecord.first { $0.startDate == bolusStart })
        XCTAssertLessThan(lostAnswer.sentAt.addingTimeInterval(1), waiting.deliveryDeadline(of: waiting.snapshot))

        let own = Self.firstStatusRecord
        let lostAnswersRecord = Self.firstStatusRecord + 1
        scriptBacklog(through: lostAnswersRecord, bolusRecords: [
            own: (start: onPatch(bolusStart.addingTimeInterval(-2)), amount: 1.0, delivered: 1.0),
            lostAnswersRecord: (start: onPatch(lostAnswer.sentAt.addingTimeInterval(1)), amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, lostAnswersRecord)
        XCTAssertEqual(outcome(of: own), "unmatched", "at the session start: history")
        XCTAssertEqual(outcome(of: lostAnswersRecord), "finalized bolus \(lostAnswer.start)")
        XCTAssertEqual(finalDelivered(ofTheBolusOf: lostAnswer.start), [1.0])
        XCTAssertEqual(uncertain.first?.phase, .settled(.byRecord))
        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [], "waits for its record")

        advanceClock(by: MedtrumPumpManager.awaitingRecordMaximumWait + Self.minute)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()

        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [1.0], "as its completion said")
        XCTAssertTrue(pumpManager.state.awaitingRecord.allSatisfy(\.isFinalized))
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [])
        XCTAssertEqual(uncertainDeliveryErrors, 1, "the lost answer, once")
        XCTAssertEqual(uncertain.map(\.cause), [.unanswered])
    }

    /// The app upgraded while a bolus of the old build delivers, the first status naming a record two before the newest:
    /// the first record past the session start is a bolus's of the same amount that started 2 min before this one went
    /// out. It is not taken for it: its own, the next, is - at what it delivered. The other is no dose of ours, past
    /// the session start: told of.
    func testUpgradeDuringABolusTakesNoRecordStartingWellBeforeItWentOut() {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-20)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: false, delivered: 0.6), scheduleStart: scheduleStart)

        let before = Self.firstStatusRecord + 1
        let own = Self.firstStatusRecord + 2
        link.notify(Self.status(bolus: (completed: true, delivered: 1.0), storage: own))
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        let beforeStart = onPatch(bolusStart.addingTimeInterval(-2 * Self.minute))
        scriptBacklog(through: own, bolusRecords: [
            before: (start: beforeStart, amount: 1.0, delivered: 1.0),
            own: (start: onPatch(bolusStart.addingTimeInterval(-2)), amount: 1.0, delivered: 0.95)
        ])
        syncRecords()
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, own)
        XCTAssertEqual(outcome(of: before), "unmatched")
        XCTAssertEqual(outcome(of: own), "finalized bolus \(bolusStart)")
        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [0.95], "from its own record")
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [
            "com.nightscout.medtrumkit.bolus-not-counted.\(Int(beforeStart.addingTimeInterval(-patchClockAhead).timeIntervalSince1970))"
        ])
        XCTAssertEqual(uncertainDeliveryErrors, 0)
    }

    /// A bolus of the old build completed as the app was upgraded, its completion the first the app hears of the patch,
    /// its own record at the session start: final from what that completion said once its record is overdue, nothing
    /// told. An hour later a bolus record of the same amount past the session start, no dose of ours waiting on it: not
    /// that bolus's - it starts long past its deadline - but one the host is missing, told of.
    func testUpgradeAsABolusCompletesFinalByEstimateTellsOfALaterBolusOfItsAmount() {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-20)
        makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        link.notify(Self.status(bolus: (completed: true, delivered: 1.0), storage: Self.firstStatusRecord))
        settle()

        scriptBacklog(through: Self.firstStatusRecord, bolusRecords: [
            Self.firstStatusRecord: (start: onPatch(bolusStart.addingTimeInterval(-2)), amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()
        XCTAssertEqual(outcome(of: Self.firstStatusRecord), "unmatched")

        advanceClock(by: MedtrumPumpManager.awaitingRecordMaximumWait + Self.minute)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()
        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [1.0])
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.map(\.datedByItsAnswer), [true])
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [])

        let later = Self.firstStatusRecord + 1
        let laterStart = onPatch(pumpManager.now())
        link.notify(Self.status(storage: later))
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: later,
            patchId: Self.patchId,
            start: laterStart,
            amount: 1.0,
            delivered: 1.0
        ))
        syncRecords()

        XCTAssertEqual(outcome(of: later), "unmatched")
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [
            "com.nightscout.medtrumkit.bolus-not-counted.\(Int(laterStart.addingTimeInterval(-patchClockAhead).timeIntervalSince1970))"
        ])
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.count, 1, "still waiting for its own")
    }

    /// A bolus of the old build ran its course while the app was down: a record of its amount in the backlog starting
    /// 9 s before its answer came, skew taken off - the patch clock 5 s behind - is its own, within its window
    func testUpgradeAfterABolusRanItsCourseTakesABacklogRecordStarting9sBeforeItsAnswer() {
        assertBacklogRecord(startingBeforeItsAnswer: 9, isTaken: true)
    }

    /// The same, the record starting 11 s before: outside its window, not taken - final from our estimate, uncertain
    func testUpgradeAfterABolusRanItsCourseTakesNoBacklogRecordStarting11sBeforeItsAnswer() {
        assertBacklogRecord(startingBeforeItsAnswer: 11, isTaken: false)
    }

    /// The app upgraded while a bolus of the old build delivers, seen delivering by the first status; the link lost, the
    /// next full status - past its deadline, still naming the record the first named - ends it unseen. Seen delivering,
    /// its record is past the session start: a record of its amount in the backlog, in its window - a bolus's cancelled
    /// at once before it - is not taken for it, the newest read though it is. It goes final from its own, named next.
    func testUpgradeDuringABolusEndingUnseenTakesNoBacklogRecord() throws {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-20)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: false, delivered: 0.6), scheduleStart: scheduleStart)

        let running = try XCTUnwrap(pumpManager.state.bolusDose)
        advanceClock(by: running.deliveryDeadline(of: running.snapshot).timeIntervalSince(pumpManager.now()) + 1)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)
        XCTAssertNil(pumpManager.state.bolusDose)
        let ended = try XCTUnwrap(pumpManager.state.awaitingRecord.first).snapshot
        XCTAssertEqual(ended.finishReason, .completionNotSeen)
        XCTAssertNotNil(ended.lastProgressAt)

        let ownStart = onPatch(bolusStart.addingTimeInterval(-2))
        let cancelled = Self.firstStatusRecord
        scriptBacklog(through: cancelled, bolusRecords: [
            cancelled: (start: ownStart.addingTimeInterval(-4), amount: 1.0, delivered: 0.1)
        ])
        syncRecords()
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, cancelled)
        XCTAssertEqual(outcome(of: cancelled), "unmatched")
        XCTAssertNil(pumpManager.state.releasedBolusBacklogRecord)
        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [], "waits for its own")

        let own = Self.firstStatusRecord + 1
        link.notify(Self.status(storage: own))
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: own,
            patchId: Self.patchId,
            start: ownStart,
            amount: 1.0,
            delivered: 1.0
        ))
        syncRecords()

        XCTAssertEqual(outcome(of: own), "finalized bolus \(bolusStart)")
        assertFinal(ofTheBolusOf: bolusStart, delivered: 1.0)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty)
    }

    /// A bolus of the old build ran its course while the app was down, its own record in the backlog; a status names a
    /// record past the session start before the backlog is read - of its amount, starting within its bounds as it ran,
    /// the patch clock set again, say - and no bolus of ours whose answer was lost waits. Its end unseen, its record is in
    /// the backlog: that one is not taken for it, but told of as a bolus the host is missing. It goes final from its own,
    /// kept from the backlog until that record is read.
    func testUpgradeAfterABolusRanItsCourseTakesNoRecordPastTheSessionStart() {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-10 * Self.minute)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .completionNotSeen)

        let own = Self.firstStatusRecord - 1
        let past = Self.firstStatusRecord + 1
        link.notify(Self.status(storage: past))
        settle()

        let pastStart = onPatch(bolusStart.addingTimeInterval(3))
        scriptBacklog(through: past, bolusRecords: [
            own: (start: onPatch(bolusStart.addingTimeInterval(-2)), amount: 1.0, delivered: 0.95),
            past: (start: pastStart, amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, past)
        XCTAssertEqual(outcome(of: own), "kept for bolus \(bolusStart)")
        XCTAssertEqual(outcome(of: past), "unmatched")
        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [0.95], "from its own record")
        XCTAssertTrue(pumpManager.state.awaitingRecord.allSatisfy(\.isFinalized))
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [
            "com.nightscout.medtrumkit.bolus-not-counted.\(Int(pastStart.addingTimeInterval(-patchClockAhead).timeIntervalSince1970))"
        ])
        XCTAssertEqual(uncertainDeliveryErrors, 0)
    }

    /// A bolus of the old build ran its course while the app was down, no record in the backlog its own; a record of its
    /// amount past the session start, claimed by no answer, is read as it waits. Its end unseen, its record is in the
    /// backlog: that one is never possibly its own, kept until it settles - told of at once as a bolus the host is
    /// missing, not taken for it as it goes final by our estimate.
    func testUpgradeAfterABolusRanItsCourseWithNoRecordOfItTellsOfALaterRecordOfItsAmount() {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-10 * Self.minute)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .completionNotSeen)

        let later = Self.firstStatusRecord + 1
        link.notify(Self.status(storage: later))
        settle()

        let laterStart = onPatch(t0.addingTimeInterval(-Self.minute))
        scriptBacklog(through: later, bolusRecords: [
            later: (start: laterStart, amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()
        syncRecords()

        let notCounted =
            "com.nightscout.medtrumkit.bolus-not-counted.\(Int(laterStart.addingTimeInterval(-patchClockAhead).timeIntervalSince1970))"
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, later)
        XCTAssertEqual(outcome(of: later), "unmatched")
        XCTAssertTrue(pumpManager.state.possibleBolusRecords.isEmpty)
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [notCounted])
        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [], "its record not overdue yet")

        advanceClock(by: MedtrumPumpManager.awaitingRecordMaximumWait + Self.minute)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()

        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [1.0])
        XCTAssertTrue(pumpManager.state.awaitingRecord.allSatisfy(\.isFinalized))
        XCTAssertEqual(pumpManager.state.bolusesFinalWithoutRecord.map(\.datedByItsAnswer), [true])
        XCTAssertNil(pumpManager.state.bolusesFinalWithoutRecord.first?.taken, "the record is not its own")
        XCTAssertEqual(
            delegate.alerts.map(\.identifier.alertIdentifier).filter { $0.hasPrefix("com.nightscout.medtrumkit.bolus-") },
            [notCounted]
        )
        XCTAssertEqual(uncertain.map(\.cause), [.endNotSeen])
    }

    // MARK: Helpers

    /// A bolus of the old build ran its course 10 min before the first status, which ends it unseen; the backlog's newest
    /// record, of its amount, starts `lead` before its answer came, skew taken off - all in whole seconds, as the patch
    /// has them. Taken for its own, `isTaken`; else final from our estimate once overdue, uncertain.
    private func assertBacklogRecord(
        startingBeforeItsAnswer lead: TimeInterval,
        isTaken: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let t0 = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        let bolusStart = t0.addingTimeInterval(-10 * Self.minute)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)
        XCTAssertEqual(pumpManager.state.patchClockSkew, patchClockAhead, file: file, line: line)

        let record = Self.firstStatusRecord
        scriptBacklog(through: record, bolusRecords: [
            record: (start: onPatch(bolusStart.addingTimeInterval(-lead)), amount: 1.0, delivered: 0.95)
        ])
        syncRecords()
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, record, file: file, line: line)

        guard !isTaken else {
            XCTAssertEqual(outcome(of: record), "finalized bolus \(bolusStart)", file: file, line: line)
            assertFinal(ofTheBolusOf: bolusStart, delivered: 0.95, file: file, line: line)
            XCTAssertEqual(uncertainDeliveryErrors, 0, file: file, line: line)
            return
        }
        XCTAssertEqual(outcome(of: record), "unmatched", file: file, line: line)
        XCTAssertEqual(finalDelivered(ofTheBolusOf: bolusStart), [], file: file, line: line)

        advanceClock(by: MedtrumPumpManager.awaitingRecordMaximumWait + Self.minute)
        link.onQueue {
            RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self.pumpManager)
        }
        settle()
        assertFinalByEstimate(ofTheBolusOf: bolusStart, delivered: 1.0, file: file, line: line)
    }

    /// A bolus of `units` of this build goes out, its answer lost, and completes in full, the completion naming `record`
    /// the newest. Returns its start, and when it went out.
    private func sendLostAnswerBolus(_ units: Double, completingWithRecord record: Int) throws -> (start: Date, sentAt: Date) {
        // A dose's identity is its start to the second
        advanceClock(by: 1)
        link.script(CommandType.SET_BOLUS, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandBolus(units)))
        settle()
        let running = try XCTUnwrap(pumpManager.state.bolusDose)
        XCTAssertEqual(running.confirmation, .uncertain)
        let sentAt = try XCTUnwrap(running.snapshot.sentAt)

        advanceClock(by: 30)
        link.notify(Self.status(bolus: (completed: true, delivered: units), storage: record))
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        return (running.startDate, sentAt)
    }

    /// What the finals of the bolus of `start` the host was handed said it delivered, in order
    private func finalDelivered(ofTheBolusOf start: Date) -> [Double] {
        finals(of: reports(of: .bolus).first { $0.startDate == start }).map { (($0.deliveredUnits ?? -1) * 100).rounded() / 100 }
    }

    /// A bolus of the old build in flight, seen delivering by the first status, completes after it: its record, the next,
    /// starting `offset` after its answer came on the patch clock, finalizes it - nothing told
    private func assertRecordPastTheSessionStartFinalizes(
        startingAfterItsAnswer offset: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-20)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: false, delivered: 0.6), scheduleStart: scheduleStart)

        let own = Self.firstStatusRecord + 1
        link.notify(Self.status(bolus: (completed: true, delivered: 1.0), storage: own))
        settle()
        XCTAssertNil(pumpManager.state.bolusDose, file: file, line: line)

        scriptBacklog(through: own, bolusRecords: [
            own: (start: onPatch(bolusStart.addingTimeInterval(offset)), amount: 1.0, delivered: 1.0)
        ])
        syncRecords()
        syncRecords()
        syncRecords()

        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, own, file: file, line: line)
        XCTAssertEqual(outcome(of: own), "finalized bolus \(bolusStart)", file: file, line: line)
        assertFinal(ofTheBolusOf: bolusStart, delivered: 1.0, file: file, line: line)
        XCTAssertEqual(uncertainDeliveryErrors, 0, file: file, line: line)
        XCTAssertTrue(uncertain.isEmpty, file: file, line: line)
    }

    /// A bolus of the old build in flight - seen delivering by the first status, if `seenDelivering` - completes, its
    /// completion naming the record before its own: that of a bolus of the same amount cancelled at once before it. It
    /// waits for its own, named next, and goes final from it - nothing told.
    private func assertStaleCompletionWaitsForItsOwnRecord(
        seenDelivering: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let t0 = Date.now
        let bolusStart = t0.addingTimeInterval(-20)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        if seenDelivering {
            deliverFirstStatus(bolus: (completed: false, delivered: 0.6), scheduleStart: scheduleStart)
        }

        let cancelled = Self.firstStatusRecord
        let own = Self.firstStatusRecord + 1
        link.notify(Self.status(bolus: (completed: true, delivered: 1.0), storage: cancelled))
        settle()
        XCTAssertNil(pumpManager.state.bolusDose, file: file, line: line)
        XCTAssertEqual(pumpManager.state.sessionStartSequence, cancelled, file: file, line: line)

        let ownStart = onPatch(bolusStart.addingTimeInterval(-2))
        scriptBacklog(through: cancelled, bolusRecords: [
            cancelled: (start: ownStart.addingTimeInterval(-4), amount: 1.0, delivered: 0.1)
        ])
        syncRecords()
        syncRecords()
        XCTAssertEqual(pumpManager.state.syncedSequenceNumber, cancelled, file: file, line: line)
        XCTAssertEqual(outcome(of: cancelled), "unmatched", file: file, line: line)
        XCTAssertTrue(finals(of: reports(of: .bolus).first).isEmpty, "waits for its own", file: file, line: line)

        // The patch names its own a moment later
        link.notify(Self.status(storage: own))
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
            sequence: own,
            patchId: Self.patchId,
            start: ownStart,
            amount: 1.0,
            delivered: 1.0
        ))
        syncRecords()

        XCTAssertEqual(outcome(of: own), "finalized bolus \(bolusStart)", file: file, line: line)
        assertFinal(ofTheBolusOf: bolusStart, delivered: 1.0, file: file, line: line)
        XCTAssertEqual(uncertainDeliveryErrors, 0, file: file, line: line)
        XCTAssertTrue(uncertain.isEmpty, file: file, line: line)
    }

    /// A manager on the released driver's state, a 1 U bolus of it run its course 10 min before the first status, which
    /// ends it unseen. Its own record - numbered `newest` - starts 2.5 s after its answer came, that of a bolus of the
    /// same amount cancelled at once, the one before, 4 s earlier. Half a second into a second, so that both fall so in
    /// the patch's whole seconds. Returns when the bolus started, and the two records.
    private func makeManagerAfterABolusRanItsCourseWithTwoRecords(newest: Int) -> (
        bolusStart: Date,
        cancelled: (sequence: Int, record: (start: Date, amount: Double, delivered: Double)),
        own: (sequence: Int, record: (start: Date, amount: Double, delivered: Double))
    ) {
        let t0 = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down) + 0.5)
        let bolusStart = t0.addingTimeInterval(-10 * Self.minute)
        let scheduleStart = makeManagerWithReleasedBolus(1.0, since: bolusStart, at: t0)
        deliverFirstStatus(bolus: (completed: true, delivered: 1.0), scheduleStart: scheduleStart)
        XCTAssertNil(pumpManager.state.bolusDose)

        let ownStart = onPatch(bolusStart.addingTimeInterval(2.5))
        return (
            bolusStart,
            (newest - 1, (start: ownStart.addingTimeInterval(-4), amount: 1.0, delivered: 0.1)),
            (newest, (start: ownStart, amount: 1.0, delivered: 0.95))
        )
    }

    /// The old build's bolus of `start`, the only one reported, went final once, at `delivered`, from our estimate - the
    /// user told its delivery is uncertain, its end unseen, and nothing more
    private func assertFinalByEstimate(ofTheBolusOf start: Date, delivered: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(reports(of: .bolus).map(\.startDate)), [start], file: file, line: line)
        let finals = finals(of: reports(of: .bolus).first)
        XCTAssertEqual(finals.count, 1, file: file, line: line)
        XCTAssertEqual(finals.first?.deliveredUnits ?? 0, delivered, accuracy: 0.001, file: file, line: line)
        XCTAssertTrue(pumpManager.state.awaitingRecord.allSatisfy(\.isFinalized), file: file, line: line)
        XCTAssertEqual(uncertainDeliveryErrors, 1, "told its delivery is uncertain", file: file, line: line)
        XCTAssertEqual(uncertain.map { $0.cause }, [.endNotSeen], file: file, line: line)
        XCTAssertFalse(
            delegate.alerts.contains { $0.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted") },
            file: file,
            line: line
        )
    }

    /// A manager on the released driver's state, `units` U of a bolus in flight since `start` - none, nil - the schedule
    /// running since an hour before `t0`. Returns when the schedule started.
    @discardableResult private func makeManagerWithReleasedBolus(_ units: Double?, since start: Date, at t0: Date) -> Date {
        let scheduleStart = t0.addingTimeInterval(-Self.hour)
        let basal = Self.legacyKeys(
            of: UnfinalizedDose(basalRate: Self.scheduledRate, insulinType: .novolog, startDate: scheduleStart).rawValue
        )
        let raw = legacyState(at: t0, bolusDose: units.map { Self.releasedBolus($0, since: start) }, basalDose: basal, basalState: .active)
        makeManager(MedtrumPumpState(rawValue: (try? roundTripped(raw)) ?? raw))
        return scheduleStart
    }

    /// A bolus as the released driver saves it in flight, dated as its answer came
    private static func releasedBolus(_ units: Double, since start: Date) -> [String: Any] {
        [
            "type": DoseType.bolus.rawValue,
            "value": units,
            "startDate": start,
            "estimatedEndDate": start.addingTimeInterval(60),
            "deliveredUnits": 0.3,
            "insulinType": InsulinType.novolog.rawValue,
            "automatic": false
        ]
    }

    /// The first full status the upgraded app has, as it reconnects: the schedule running, the bolus field as given,
    /// naming `firstStatusRecord` the newest record
    private func deliverFirstStatus(bolus: (completed: Bool, delivered: Double), scheduleStart: Date) {
        link.deliverFullStatus(notification: Self.status(
            bolus: bolus,
            basal: (type: .STANDARD, start: onPatch(scheduleStart), rate: Self.scheduledRate, delivered: 0.5),
            reservoir: 120,
            storage: Self.firstStatusRecord
        ), duringReconnect: true)
        settle()
    }

    /// The records from `first` - the 20 up to `newest`, as the first sync reads them, if not given - to `newest`: the
    /// bolus records given, an older 1 U bolus among the rest, and records no dose is matched against
    private func scriptBacklog(
        from first: Int? = nil,
        through newest: Int,
        bolusRecords: [Int: (start: Date, amount: Double, delivered: Double)]
    ) {
        let older = newest - 12
        for sequence in (first ?? newest - 19) ... newest {
            if let bolus = bolusRecords[sequence] {
                link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
                    sequence: sequence,
                    patchId: Self.patchId,
                    start: bolus.start,
                    amount: bolus.amount,
                    delivered: bolus.delivered
                ))
            } else if sequence == older {
                link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(
                    sequence: sequence,
                    patchId: Self.patchId,
                    start: onPatch(Date.now.addingTimeInterval(-40 * Self.minute)),
                    amount: 1.0,
                    delivered: 1.0
                ))
            } else {
                link.script(CommandType.GET_RECORD, PatchBytes.otherRecord(type: 5, sequence: sequence, patchId: Self.patchId))
            }
        }
    }

    private func outcome(of sequence: Int) -> String? {
        pumpManager.recordStore.records.first { $0.id == sequence }?.outcome
    }

    /// The old build's bolus of `start`, the only one reported, went final once, at `delivered`, from its record - and
    /// nothing was told
    private func assertFinal(ofTheBolusOf start: Date, delivered: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(reports(of: .bolus).map(\.startDate)), [start], file: file, line: line)
        let finals = finals(of: reports(of: .bolus).first)
        XCTAssertEqual(finals.count, 1, file: file, line: line)
        XCTAssertEqual(finals.first?.deliveredUnits ?? 0, delivered, accuracy: 0.001, file: file, line: line)
        XCTAssertTrue(pumpManager.state.awaitingRecord.allSatisfy(\.isFinalized), file: file, line: line)
        XCTAssertEqual(delegate.alerts.map(\.identifier.alertIdentifier), [], file: file, line: line)
    }

    // MARK: The released driver's state

    /// The state `fix/better-attempts` saves - every key its `MedtrumPumpState.rawValue` writes, and no other - for an
    /// activated patch, a day in, its session running
    private func legacyState(
        at t0: Date,
        bolusDose: [String: Any]? = nil,
        basalDose: [String: Any],
        basalState: BasalState
    ) -> [String: Any] {
        let activatedAt = t0.addingTimeInterval(-24 * Self.hour)
        var raw: [String: Any] = [
            "isOnboarded": true,
            "lastSync": t0.addingTimeInterval(-3 * Self.minute),
            "insulinType": InsulinType.novolog.rawValue,
            "lowReservoirWarning": 20.0,
            "pumpSN": Data([0x01, 0x02, 0x03, 0x04]),
            "sessionToken": Data([0x05, 0x06, 0x07, 0x08]),
            "backupSessionToken": Data(),
            "patchId": Self.patchId.toData(length: 4),
            "peripheralIdentifier": UUID().uuidString,
            "patchActivatedAt": activatedAt,
            "patchGracePeriodFrom": activatedAt.addingTimeInterval(72 * Self.hour),
            "patchExpiresAt": activatedAt.addingTimeInterval(80 * Self.hour),
            "deviceType": UInt8(80),
            "swVersion": "1.80.88",
            // The patch clock `patchClockAhead` ahead of ours
            "pumpTime": t0.addingTimeInterval(patchClockAhead),
            "pumpTimeSyncedAt": t0,
            "pumpState": PatchState.active.rawValue,
            "patchSessionEnded": false,
            "maxHourlyInsulin": 20.0,
            "maxDailyInsulin": 100.0,
            "basalSchedule": BasalSchedule(entries: [RepeatingScheduleValue(startTime: 0, value: Self.scheduledRate)]).rawValue,
            "initialReservoir": 200.0,
            "basalDose": basalDose,
            "reservoir": 120.0,
            "battery": 2.8,
            "basalState": basalState.rawValue,
            "alarmSetting": AlarmSettings.BeepOnly.rawValue,
            "expiryMode": ExpiryMode.default.rawValue,
            "notificationAfterActivation": 72 * Self.hour,
            "useSilentTones": false
        ]
        raw["bolusDose"] = bolusDose
        return raw
    }

    /// A dose as the released driver saves it: the keys its `UnfinalizedDose.rawValue` writes
    private static func legacyKeys(of raw: [String: Any]) -> [String: Any] {
        let kept: Set<String> = ["type", "value", "startDate", "estimatedEndDate", "deliveredUnits", "insulinType", "automatic"]
        return raw.filter { kept.contains($0.key) }
    }

    /// The patch's 20 records up to `newest`, written before `t0` - before the temp basal it runs since `patchStart`: five
    /// boluses (one cancelled), four temp basals (one at the running rate), two scheduled segments, the rest records no
    /// dose is matched against
    private func backlog(before t0: Date, through newest: Int, patchStart: Date) -> [[String]] {
        let at = { (minutesAgo: Double) in self.onPatch(t0.addingTimeInterval(-minutesAgo * Self.minute)) }
        let bolus = { (sequence: Int, minutesAgo: Double, amount: Double, delivered: Double) in
            PatchBytes.bolusRecord(sequence: sequence, patchId: Self.patchId, start: at(minutesAgo), amount: amount, delivered: delivered)
        }
        let basal = { (sequence: Int, type: BasalType, from: Date, to: Date, rate: Double, delivered: Double) in
            PatchBytes.basalRecord(
                sequence: sequence,
                patchId: Self.patchId,
                type: type,
                start: from,
                end: to,
                rate: rate,
                delivered: delivered
            )
        }

        let first = newest - 19
        var byNumber: [Int: [String]] = [
            first + 1: basal(first + 1, .ABSOLUTE_TEMP, at(180), at(150), 0.8, 0.4),
            first + 2: basal(first + 2, .STANDARD, at(150), at(120), Self.scheduledRate, 0.3),
            first + 3: bolus(first + 3, 110, 1.0, 1.0),
            first + 4: basal(first + 4, .ABSOLUTE_TEMP, at(100), at(70), 1.2, 0.6),
            first + 6: bolus(first + 6, 60, 0.3, 0.3),
            first + 7: bolus(first + 7, 50, 0.5, 0.25),
            first + 8: basal(first + 8, .ABSOLUTE_TEMP, at(40), at(25), 2.0, 0.5),
            first + 14: bolus(first + 14, 20, 0.15, 0.15),
            first + 17: bolus(first + 17, 15, 2.0, 2.0),
            newest: basal(newest, .STANDARD, at(25), patchStart, Self.scheduledRate, 0.15)
        ]
        for sequence in first ... newest where byNumber[sequence] == nil {
            byNumber[sequence] = PatchBytes.otherRecord(type: 5, sequence: sequence, patchId: Self.patchId)
        }
        return (first ... newest).compactMap { byNumber[$0] }
    }

    // MARK: Patch bytes

    /// A notification - or, delivered so, a full status - of the active patch with the fields given, laid out as
    /// `NotificationPacket` reads them. The basal field names `storage` as the newest record, as the patch does.
    private static func status(
        bolus: (completed: Bool, delivered: Double)? = nil,
        basal: (type: BasalType, start: Date, rate: Double, delivered: Double)? = nil,
        reservoir: Double? = nil,
        storage: Int
    ) -> String {
        var mask: UInt16 = MASK_STORAGE
        var fields = Data()
        if let bolus {
            mask |= MASK_NORMAL_BOLUS
            fields += Data([bolus.completed ? 0x81 : 0x01]) + UInt64((bolus.delivered / 0.05).rounded()).toData(length: 2)
        }
        if let basal {
            mask |= MASK_BASAL
            fields += Data([basal.type.rawValue]) + UInt64(storage).toData(length: 2) + patchId.toData(length: 2)
            let rateDelivery = UInt64((basal.delivered / 0.05).rounded()) << 12 | UInt64((basal.rate / 0.05).rounded())
            fields += basal.start.toMedtrumSeconds() + rateDelivery.toData(length: 3)
        }
        if let reservoir {
            mask |= MASK_RESERVOIR
            fields += UInt64((reservoir / 0.05).rounded()).toData(length: 2)
        }
        fields += UInt64(storage).toData(length: 2) + patchId.toData(length: 2)
        return (Data([PatchState.active.rawValue]) + UInt64(mask).toData(length: 2) + fields).hexEncodedString()
    }

    /// `date` as the patch clock has it, in whole seconds
    private static func patchSecond(_ date: Date) -> Date {
        Date.fromMedtrumSeconds(date.toMedtrumSeconds().toUInt64())
    }

    /// `date` on the phone, as the patch clock has it - `patchClockAhead` - in whole seconds
    private func onPatch(_ date: Date) -> Date {
        Self.patchSecond(date.addingTimeInterval(patchClockAhead))
    }

    private func roundTripped(_ raw: [String: Any]) throws -> [String: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}

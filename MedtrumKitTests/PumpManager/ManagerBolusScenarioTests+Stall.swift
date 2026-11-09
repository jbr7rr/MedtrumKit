import LoopKit
@testable import MedtrumKit
import XCTest

/// A running bolus that stops advancing while the patch keeps answering raises one "Bolus delivery stalled" warning - a
/// possible occlusion the patch has not raised (`MedtrumPumpManager.checkBolusStall`). The two timelines are tomacs's
/// replays (jbr7rr/MedtrumKit#224): seconds since the bolus was answered, and the amount a notification carried - nil, one
/// without the bolus field, the patch answering.
extension ManagerBolusScenarioTests {
    /// 2026-10-13 12:06:06, 5.0 U: the patch's pace up to 3.5 U, then one step every 25-40 s against a blocked cannula;
    /// 5.0 U "completed" after 529 s, its occlusion alarm 205 s after that
    static let stalledBolus: [(TimeInterval, Double?)] = [
        (2, 0.1), (6, 0.2), (10, 0.3), (14, 0.4), (18, 0.5), (22, 0.6), (26, 0.7), (30, 0.8), (34, 0.9),
        (38, 1), (42, 1.1), (46, 1.2), (50, 1.3), (51, nil), (54, 1.4), (58, 1.5), (62, 1.6), (66, 1.7),
        (70, 1.8), (74, 1.9), (78, 2), (82, 2.1), (86, 2.2), (90, 2.3), (94, 2.4), (98, 2.5), (102, 2.6),
        (106, 2.7), (110, nil), (111, 2.8), (115, 2.9), (119, 3), (123, 3.1), (127, 3.2), (131, 3.3),
        (135, 3.4), (139, 3.5), (147, nil), (155, nil), (163, nil), (171, nil), (179, 3.6), (187, nil),
        (195, nil), (203, nil), (211, nil), (217, 3.7), (225, nil), (231, nil), (239, nil), (247, nil),
        (253, 3.8), (261, nil), (269, nil), (277, nil), (285, nil), (287, 3.9), (291, nil), (299, nil),
        (307, nil), (315, nil), (319, 4), (327, nil), (335, nil), (343, nil), (349, 4.1), (351, nil),
        (359, nil), (367, nil), (375, nil), (377, 4.2), (385, nil), (393, nil), (401, nil), (403, 4.3),
        (411, nil), (419, nil), (427, 4.4), (435, nil), (443, nil), (449, 4.5), (457, nil), (465, nil),
        (469, 4.6), (471, nil), (479, nil), (487, 4.7), (495, nil), (503, 4.8), (512, nil), (517, 4.9),
        (525, nil), (529, 5)
    ]

    /// 2026-10-12 16:00:23, 5.0 U on a working patch: 198 s, never more than 6 s between steps
    static let normalBolus: [(TimeInterval, Double?)] = [
        (0, nil), (2, 0.1), (6, 0.2), (10, 0.3), (14, 0.4), (18, 0.5), (22, 0.6), (26, 0.7), (30, 0.8),
        (36, 0.9), (36, nil), (38, 1), (42, 1.1), (46, 1.2), (50, 1.3), (54, 1.4), (58, 1.5), (62, 1.6),
        (66, 1.7), (70, 1.8), (74, 1.9), (78, 2), (82, 2.1), (86, 2.2), (90, 2.3), (94, 2.4), (96, nil),
        (98, 2.5), (102, 2.6), (106, 2.7), (110, 2.8), (114, 2.9), (118, 3), (122, 3.1), (126, 3.2),
        (130, 3.3), (134, 3.4), (138, 3.5), (142, 3.6), (146, 3.7), (150, 3.8), (154, 3.9), (156, nil),
        (158, 4), (162, 4.1), (166, 4.2), (170, 4.3), (174, 4.4), (178, 4.5), (182, 4.6), (186, 4.7),
        (190, 4.8), (194, 4.9), (198, 5)
    ]

    private static let stallAlertPrefix = "com.nightscout.medtrumkit.bolus-stalled."

    private var stallAlerts: [Alert] {
        delegate.alerts.filter { $0.identifier.alertIdentifier.hasPrefix(Self.stallAlertPrefix) }
    }

    private var stallRetractions: [Alert.Identifier] {
        delegate.retractedAlerts.filter { $0.alertIdentifier.hasPrefix(Self.stallAlertPrefix) }
    }

    private var stallNote: UncertainDelivery? {
        pumpManager.state.uncertainDeliveries.first { $0.stalledFor != nil }
    }

    /// `units` answered as `record`, running: judged from its answer on
    private func startBolus(_ units: Double, record: Int = 123) {
        let body = UInt64(record).toData(length: 2) + UInt64(236).toData(length: 2) +
            Self.patchTime(397_000_000).toMedtrumSeconds()
        link.script(CommandType.SET_BOLUS, .fragments(PatchBytes.answer(command: CommandType.SET_BOLUS, body: body)))
        XCTAssertNil(commandBolus(units))
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
    }

    private func makeBolusManager() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
    }

    /// A notification of the running bolus having delivered `delivered`, not completed
    private func progressHex(_ delivered: Double) -> String {
        "200200" + "00" + UInt64((delivered / 0.05).rounded()).toData(length: 2).hexEncodedString()
    }

    /// The running bolus has delivered `delivered`, not completed
    private func notifyProgress(_ delivered: Double) {
        link.notify(progressHex(delivered))
        settle()
    }

    /// The running bolus completed at `delivered`
    private func notifyCompletion(_ delivered: Double) {
        link.notify("200200" + "80" + UInt64((delivered / 0.05).rounded()).toData(length: 2).hexEncodedString())
        settle()
    }

    /// A notification without the bolus field: the patch answering, the bolus not advancing
    private func notifyNoProgress() {
        link.notify("200000")
        settle()
    }

    /// Steps of 0.1 U every `every` s, from `from` (not included) to `to`
    private func steps(from: Double, to: Double, every: TimeInterval) {
        var delivered = from
        while delivered < to - 0.001 {
            advanceClock(by: every)
            delivered += 0.1
            notifyProgress(delivered)
        }
    }

    /// Plays `timeline` from the bolus's answer on: returns when, in it, each stall warning came
    private func replay(_ timeline: [(TimeInterval, Double?)]) -> [TimeInterval] {
        var at: TimeInterval = 0
        var warnedAt: [TimeInterval] = []
        for (offset, delivered) in timeline {
            advanceClock(by: offset - at)
            at = offset
            let before = stallAlerts.count
            if let delivered {
                notifyProgress(delivered)
            } else {
                notifyNoProgress()
            }
            if stallAlerts.count > before {
                warnedAt.append(offset)
            }
        }
        return warnedAt
    }

    // MARK: The two replays

    /// The stall of 2026-10-13: the last step at 139 s (3.5 U), the patch answering every 8 s - warned of at 171 s, the
    /// first status past 25 s without a step, nearly ten minutes before the patch's own alarm. Once. Completed in full but
    /// never at the patch's pace again: still warned of - the patch counts all 5 U whether they went in or not. Nothing
    /// it counts changes.
    func testTheStallOfTheIncidentIsWarnedOfOnceBeforeThePatchsAlarm() throws {
        makeBolusManager()
        startBolus(5.0)

        XCTAssertEqual(replay(Self.stalledBolus), [171])
        let alert = try XCTUnwrap(stallAlerts.first)
        XCTAssertEqual(alert.foregroundContent?.title, "Bolus delivery stalled")
        // In the locale the alert is formatted in
        XCTAssertTrue(alert.foregroundContent?.body.contains(3.5.formatted()) == true, alert.foregroundContent?.body ?? "-")
        XCTAssertTrue(alert.foregroundContent?.body.contains("32 s") == true, alert.foregroundContent?.body ?? "-")
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress, "a warning only")
        // No pump event: a retracted warning leaves nothing behind in the history
        XCTAssertTrue(delegate.batches.flatMap(\.events).filter { $0.type == .alarm }.isEmpty)
        XCTAssertNil(NewPumpEvent.alert(type: .bolusStalled(delivered: 3.5, units: 5, stalledFor: 32, sentAt: Date.now)))
        XCTAssertEqual(reports(of: .bolus).last?.programmedUnits ?? 0, 5.0, accuracy: 0.001)

        let note = try XCTUnwrap(stallNote)
        XCTAssertEqual(note.cause, .stalled)
        XCTAssertEqual(note.stalledFor ?? 0, 40, accuracy: 1, "139 s to 179 s, the longest")
        XCTAssertEqual(uncertain.first?.phase, .countedInFull)

        notifyCompletion(5.0)
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(stallAlerts.count, 1)
        XCTAssertEqual(stallRetractions, [], "completed in full, never at the patch's pace again")
        XCTAssertEqual(stallNote?.stallResumed, false)
        XCTAssertEqual(reports(of: .bolus).last?.deliveredUnits ?? 0, 5.0, accuracy: 0.001, "counted as the patch says")
    }

    /// 2026-10-12, 5.0 U on a working patch: never warned of, nothing noted
    func testANormalFiveUnitBolusIsNeverWarnedOf() {
        makeBolusManager()
        startBolus(5.0)

        XCTAssertEqual(replay(Self.normalBolus), [])
        notifyCompletion(5.0)

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertTrue(stallAlerts.isEmpty)
        XCTAssertTrue(stallRetractions.isEmpty)
        XCTAssertTrue(pumpManager.state.uncertainDeliveries.isEmpty)
    }

    // MARK: What it is told by

    /// The patch sends nothing but its steps - as in 2 of 3 boluses in the logs: the step that comes 40 s after the last
    /// closes a gap past the threshold, the link up all along - warned of then, late, but warned of
    func testAStallWithNothingButStepsIsWarnedOfOnTheLateStep() throws {
        makeBolusManager()
        startBolus(2.0)
        steps(from: 0, to: 0.5, every: 4)

        advanceClock(by: 40)
        notifyProgress(0.6)

        XCTAssertEqual(stallAlerts.count, 1)
        XCTAssertTrue(stallAlerts.first?.foregroundContent?.body.contains("past \(0.5.formatted()) U") == true)
        XCTAssertEqual(try XCTUnwrap(stallNote?.stalledFor), 40, accuracy: 1)

        steps(from: 0.6, to: 1.0, every: 30)
        XCTAssertEqual(stallAlerts.count, 1, "once per bolus")
    }

    /// The link gone: a reconnect's status after 40 s - the bolus moved on meanwhile - and later 70 s of nothing at all,
    /// longer than the patch is ever silent on a working link. Neither is the bolus's: never warned of.
    func testALinkGapIsNotAStall() {
        makeBolusManager()
        startBolus(3.0)
        steps(from: 0, to: 0.3, every: 4)

        advanceClock(by: 40)
        link.deliverFullStatus(notification: progressHex(1.0), duringReconnect: true)
        settle()
        steps(from: 1.0, to: 1.4, every: 4)

        advanceClock(by: 70)
        notifyProgress(2.4)
        steps(from: 2.4, to: 2.9, every: 4)
        notifyCompletion(3.0)

        XCTAssertTrue(stallAlerts.isEmpty)
        XCTAssertTrue(pumpManager.state.uncertainDeliveries.isEmpty)
    }

    /// Statuses cut short, or failing validation, every 8 s for 88 s: they tell nothing - not the patch answering. None
    /// warns, and the step after them closes a silence of the link's, not a stall.
    func testAnInvalidStatusIsNoAnswer() {
        makeBolusManager()
        startBolus(2.0)
        steps(from: 0, to: 0.3, every: 4)

        for index in 1 ... 11 {
            advanceClock(by: 8)
            // The bolus field announced, not there - or 55 U, more than a patch holds
            link.notify(index.isMultiple(of: 2) ? "20020000" : "2002004c04")
            settle()
        }
        XCTAssertTrue(stallAlerts.isEmpty, "not the patch answering")

        advanceClock(by: 4)
        notifyProgress(0.4)
        XCTAssertTrue(stallAlerts.isEmpty, "nothing usable heard for 92 s: the link's")
    }

    /// 0.3 U - an SMB - is done before it could stall visibly at the patch's slowest pace: never judged, however late its
    /// completion
    func testASmallSMBIsNeverJudged() {
        makeBolusManager()
        startBolus(0.3)
        notifyProgress(0.1)
        for _ in 1 ... 5 {
            advanceClock(by: 8)
            notifyNoProgress()
        }
        notifyCompletion(0.3)

        XCTAssertTrue(stallAlerts.isEmpty)
        XCTAssertTrue(pumpManager.state.uncertainDeliveries.isEmpty)
    }

    // MARK: How it ends

    /// Stalled for 30 s, then on at the patch's pace and completed in full: delivered slowly - the warning retracted, the
    /// note kept, saying so, with the longest gap
    func testAStallThatGoesOnAtThePatchsPaceToItsEndIsRetractedAndNoted() throws {
        makeBolusManager()
        startBolus(2.0)
        steps(from: 0, to: 0.5, every: 4)
        for _ in 1 ... 4 {
            advanceClock(by: 8)
            notifyNoProgress()
        }
        XCTAssertEqual(stallAlerts.count, 1, "32 s without a step")

        advanceClock(by: 2)
        notifyProgress(0.6)
        steps(from: 0.6, to: 1.9, every: 4)
        advanceClock(by: 4)
        notifyCompletion(2.0)

        XCTAssertEqual(stallAlerts.count, 1)
        XCTAssertEqual(stallRetractions, stallAlerts.map(\.identifier))
        let note = try XCTUnwrap(stallNote)
        XCTAssertTrue(note.stallResumed)
        XCTAssertEqual(note.stalledFor ?? 0, 34, accuracy: 1)
        XCTAssertEqual(uncertain.first?.cause, .stalled)

        let notice = MedtrumKitSettingsViewModel(nil, {}, { _ in }, {}, {}, {}, {}, {}, {}, {}, {})
            .notice(for: note, phase: pumpManager.state.phase(of: note))
        XCTAssertTrue(notice.cause.hasPrefix("Delivered slowly: up to 34 s"), notice.cause)
    }

    /// Stalled, then completed short, at 1.0 of 2.0 U: the patch ended it - the end tells, the warning is retracted. Counted
    /// as what the patch says.
    func testAStallThatEndsShortIsRetracted() {
        makeBolusManager()
        startBolus(2.0)
        steps(from: 0, to: 1.0, every: 4)
        advanceClock(by: 30)
        notifyNoProgress()
        XCTAssertEqual(stallAlerts.count, 1)

        advanceClock(by: 4)
        notifyCompletion(1.0)

        XCTAssertEqual(stallRetractions, stallAlerts.map(\.identifier))
        XCTAssertEqual(stallNote?.stallResumed, false)
        XCTAssertEqual(reports(of: .bolus).last?.deliveredUnits ?? 0, 1.0, accuracy: 0.001)
    }

    /// As 2026-10-13: stalled, "completed" in full, then the patch's own occlusion alarm - the stall's warning is retracted
    /// for it
    func testAnOcclusionAfterAStallRetractsItsWarning() {
        makeBolusManager()
        startBolus(2.0)
        steps(from: 0, to: 1.5, every: 4)
        advanceClock(by: 30)
        notifyNoProgress()
        steps(from: 1.5, to: 1.9, every: 30)
        advanceClock(by: 30)
        notifyCompletion(2.0)
        XCTAssertEqual(stallAlerts.count, 1)
        XCTAssertEqual(stallRetractions, [], "not at the patch's pace")

        advanceClock(by: 205)
        link.notify("600000")
        settle()

        XCTAssertEqual(stallRetractions, stallAlerts.map(\.identifier))
        XCTAssertEqual(
            delegate.alerts.last?.identifier.alertIdentifier,
            MedtrumAlert.occlusionNotification.alert.identifier.alertIdentifier
        )
    }

    /// The patch raised its own occlusion alarm before any stall was seen: the running bolus is not warned of after it,
    /// however long its progress stands still - the patch's alarm tells
    func testNoStallWarningAfterThePatchsOwnAlarm() {
        makeBolusManager()
        startBolus(2.0)
        steps(from: 0, to: 0.5, every: 4)

        advanceClock(by: 4)
        link.notify("600000")
        settle()
        for _ in 1 ... 5 {
            advanceClock(by: 8)
            notifyNoProgress()
        }

        XCTAssertEqual(
            delegate.alerts.map(\.identifier.alertIdentifier),
            [MedtrumAlert.occlusionNotification.alert.identifier.alertIdentifier]
        )
        XCTAssertNotNil(pumpManager.state.bolusDose, "still running as far as is known")
        XCTAssertNil(stallNote, "not noted either")
    }

    /// The patch's own occlusion alarm the first status after a restart - no watch yet when it is handled, the watch
    /// built on that status - then the state back to delivering, the bolus standing still for 40 s: not warned of. The
    /// alarm silences the bolus, not the watch there was.
    func testNoStallWarningAfterThePatchsOwnAlarmSeenBeforeAnyWatch() throws {
        makeBolusManager()
        startBolus(3.0)
        steps(from: 0, to: 0.5, every: 4)

        try restart(from: delegate.savedState)
        pumpManager.state.isConnected = true
        XCTAssertNil(pumpManager.bolusStallWatch)
        advanceClock(by: 4)
        link.notify("600000")
        settle()
        XCTAssertNotNil(pumpManager.bolusStallWatch, "built on the alarm's status")

        advanceClock(by: 4)
        notifyProgress(0.6)
        for _ in 1 ... 5 {
            advanceClock(by: 8)
            notifyNoProgress()
        }

        XCTAssertEqual(
            delegate.alerts.map(\.identifier.alertIdentifier),
            [MedtrumAlert.occlusionNotification.alert.identifier.alertIdentifier]
        )
        XCTAssertNotNil(pumpManager.state.bolusDose, "still running as far as is known")
        XCTAssertNil(stallNote)
    }

    /// Stalled, then past its deadline with no end seen: how it ended is not known - the warning stands, the note tells of
    /// the end not seen, the stall kept with it
    func testAStalledBolusWhoseEndIsNotSeenStaysWarnedOf() throws {
        makeBolusManager()
        startBolus(2.0)
        steps(from: 0, to: 0.5, every: 4)
        advanceClock(by: 30)
        notifyNoProgress()
        XCTAssertEqual(stallAlerts.count, 1)

        advanceClock(by: 7 * Self.minute)
        link.deliverFullStatus(notification: "200000", duringReconnect: false)
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertNil(pumpManager.bolusStallWatch)
        XCTAssertEqual(stallAlerts.count, 1)
        XCTAssertEqual(stallRetractions, [])
        let note = try XCTUnwrap(stallNote)
        XCTAssertEqual(note.cause, .endNotSeen, "the later cause")
        XCTAssertEqual(note.stalledFor ?? 0, 30, accuracy: 1)
    }

    /// Stalled, then the patch deactivated - forced off: over with its patch, the warning is retracted; the note tells of
    /// the session's end, the stall kept with it
    func testADeactivationRetractsTheStallWarning() throws {
        makeBolusManager()
        startBolus(2.0)
        steps(from: 0, to: 0.5, every: 4)
        advanceClock(by: 30)
        notifyNoProgress()
        XCTAssertEqual(stallAlerts.count, 1)

        pumpManager.forceDeactivatePatch()
        settle()

        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertNil(pumpManager.bolusStallWatch)
        XCTAssertEqual(stallRetractions, stallAlerts.map(\.identifier))
        let note = try XCTUnwrap(stallNote)
        XCTAssertEqual(note.cause, .patchDeactivated)
        XCTAssertNotNil(note.stalledFor)
    }

    // MARK: Restarts, and one per bolus

    /// The app restarted mid-bolus: nothing is judged until the patch is heard from again, the restart's gap never - not
    /// the first step after it, 40 s on. A stall after that is warned of.
    func testARestartMidBolusIsNotAStall() throws {
        makeBolusManager()
        startBolus(3.0)
        steps(from: 0, to: 0.5, every: 4)

        try restart(from: delegate.savedState)
        pumpManager.state.isConnected = true
        advanceClock(by: 40)
        link.deliverFullStatus(notification: progressHex(0.6), duringReconnect: true)
        settle()
        advanceClock(by: 4)
        notifyProgress(0.7)
        XCTAssertTrue(stallAlerts.isEmpty, "the restart's gap")
        XCTAssertEqual(pumpManager.state.bolusDose?.snapshot.lastProgressUnits ?? 0, 0.7, accuracy: 0.001)

        for _ in 1 ... 4 {
            advanceClock(by: 8)
            notifyNoProgress()
        }
        XCTAssertEqual(stallAlerts.count, 1, "judged again once heard from")
    }

    /// Two boluses stalled: two warnings, each its own - retracting one leaves the other
    func testEachStalledBolusIsWarnedOfOnItsOwn() {
        makeBolusManager()
        startBolus(1.0)
        steps(from: 0, to: 0.3, every: 4)
        advanceClock(by: 30)
        notifyNoProgress()
        notifyCompletion(1.0)

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)
        startBolus(1.0, record: 124)
        steps(from: 0, to: 0.3, every: 4)
        advanceClock(by: 30)
        notifyNoProgress()

        XCTAssertEqual(stallAlerts.count, 2)
        XCTAssertEqual(Set(stallAlerts.map(\.identifier.alertIdentifier)).count, 2, "one identifier per bolus")
        XCTAssertEqual(pumpManager.state.uncertainDeliveries.filter { $0.cause == .stalled }.count, 2)
    }
}

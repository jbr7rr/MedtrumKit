import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerTempBasalScenarioTests {
    // MARK: - Rates off the patch's steps

    // A rate between two 0.05 U/h steps - Trio rounds its SMB low temps to 0.01 U/h - is floored once, as the command
    // begins: sent, written ahead, matched and reported as the step below (jbr7rr/MedtrumKit#222). Sent as it was, the
    // packet rounded it to the nearest step - more than asked for, maybe - and the patch's own answer and statuses of it
    // were taken for none of ours.

    /// The rate in an event's identity - see `NewPumpEvent.tempBasal`
    func rate(inIdentityOf event: NewPumpEvent?) -> String? {
        event.flatMap { String(data: $0.raw, encoding: .utf8) }?.split(separator: " ").dropFirst().first.map(String.init)
    }

    /// No temp basal running on patch 251, its clock at `ourStart`; the set answered with a temp basal at `answeredRate`
    /// from there, record 131 - or with `then` run as the answer is in
    func scriptSetOffTheSteps(answeredRate: Double, then work: @escaping () -> Void = {}) {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        state.lastSegmentStart = Self.ourStart.addingTimeInterval(-Self.hour)
        alignPatchClock(state, patchTime: Self.ourStart)
        makeManager(state)

        link.script(CommandType.SET_TEMP_BASAL, .fragments(PatchBytes.segmentAnswer(
            command: CommandType.SET_TEMP_BASAL,
            type: .ABSOLUTE_TEMP,
            rate: answeredRate,
            sequence: 131,
            patchId: 251,
            start: Self.ourStart
        )), then: work)
    }

    /// 1.08 U/h, as Trio dev sends it: 21 steps written - 22, the nearest, is more than asked for - and the answer at 21
    /// is the temp basal set, confirmed. Reported, and identified, as 1.05 U/h.
    func testTempBasalOffTheStepsIsSentAsTheStepBelowAndConfirmedByItsAnswer() {
        scriptSetOffTheSteps(answeredRate: 1.05)

        XCTAssertNil(commandTempBasal(1.08, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_TEMP_BASAL])
        XCTAssertEqual(steps(of: written(CommandType.SET_TEMP_BASAL)?.packet), 21)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty, "nothing was uncertain")
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal)
        XCTAssertFalse(pumpManager.status.deliveryIsUncertain)

        XCTAssertEqual(delegate.batches.count, 1)
        let event = delegate.batches.first?.events.first
        XCTAssertEqual(event?.dose?.type, .tempBasal)
        XCTAssertEqual(event?.dose?.unitsPerHour ?? 0, 1.05, accuracy: 1e-9)
        XCTAssertEqual(rate(inIdentityOf: event), "1.05")
        XCTAssertEqual(pumpManager.state.basalDose.value, 1.05, accuracy: 1e-9)
        XCTAssertEqual(pumpManager.state.basalDose.pumpStartTime, Self.ourStart)
    }

    /// The reviewer's case on #224, Trio dev: 0.23 U/h went out as 0.25, the dose kept 0.23, and the next status of the
    /// patch's own temp basal was "none of ours" - an uncertain delivery. Sent as 0.20 now, and the status at 0.20 is it.
    func testTempBasalOffTheStepsIsOursInTheStatusThatShowsIt() {
        scriptSetOffTheSteps(answeredRate: 0.2)

        XCTAssertNil(commandTempBasal(0.23, duration: 30 * Self.minute))
        settle()
        XCTAssertEqual(steps(of: written(CommandType.SET_TEMP_BASAL)?.packet), 4)
        XCTAssertEqual(reports(of: .tempBasal).first?.unitsPerHour ?? 0, 0.2, accuracy: 1e-9)

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 131,
            patchId: 251,
            start: Self.ourStart,
            rate: 0.2,
            delivered: 0.05
        ))
        settle()

        XCTAssertEqual(pumpManager.state.basalDose.snapshot.statusDelivery ?? 0, 0.05, accuracy: 0.001, "its delivery so far noted")
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty, "the segment is ours")
    }

    /// A temp basal set by an older build, which sent the host's rate as it was: 0.23 U/h kept, 0.25 running on the
    /// patch. Its status is still ours - compared in the patch's steps - and the rate it was reported at stays: its
    /// identity never moves.
    func testTempBasalOfAnOlderBuildOffTheStepsIsOursInItsStatus() {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        state.basalDose = runningTempBasal(rate: 0.23, startedAgo: 10 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.ourStart)
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Self.ourStart.addingTimeInterval(10 * Self.minute))
        makeManager(state)

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 130,
            patchId: 251,
            start: Self.ourStart,
            rate: 0.25,
            delivered: 0.05
        ))
        settle()

        XCTAssertEqual(pumpManager.state.basalDose.snapshot.statusDelivery ?? 0, 0.05, accuracy: 0.001, "its delivery so far noted")
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.23, "not floored again")
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertTrue(uncertain.isEmpty, "the segment is ours")
    }

    /// A temp basal whose command went unanswered, written ahead by an older build at the host's rate as it was - 0.23
    /// U/h, sent as 0.25 - the app killed before its answer: kept unconfirmed at 0.23. The status of the patch running it
    /// at 0.25 confirms it - compared in the patch's steps - and it is reported at 0.23, not floored again.
    func testUnconfirmedTempBasalOfAnOlderBuildOffTheStepsIsConfirmedByItsStatus() {
        let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
        alignPatchClock(state, patchTime: Self.ourStart)
        state.pendingTempBasal = PendingTempBasal(
            unitsPerHour: 0.23,
            duration: 30 * Self.minute,
            automatic: true,
            sentAt: Date.now.addingTimeInterval(-5),
            sequenceAtSend: 130,
            priorSegmentStart: Self.ourStart.addingTimeInterval(-Self.hour),
            cancelledAt: nil
        )
        makeManager(state)
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.value, 0.23, "taken over as it was written ahead")

        link.notify(PatchBytes.basalNotification(
            type: .ABSOLUTE_TEMP,
            sequence: 130,
            patchId: 251,
            start: Self.ourStart.addingTimeInterval(-4),
            rate: 0.25
        ))
        settle()

        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, "shown running")
        XCTAssertEqual(pumpManager.state.basalDose.type, .tempBasal)
        XCTAssertEqual(pumpManager.state.basalDose.value, 0.23, "not floored again")
        let reported = delegate.batches.flatMap(\.events).last { $0.dose?.type == .tempBasal }
        XCTAssertEqual(rate(inIdentityOf: reported), "0.23")
    }

    /// Killed as the set of 1.08 U/h awaited its answer: the temp basal taken over is the one written ahead, at 1.05 -
    /// not floored again - and once a status shows it running it is reported at the same rate as the live run; the date
    /// is the takeover's own
    func testTempBasalOffTheStepsTakenOverAfterAKillHasTheRateOfTheLiveOne() throws {
        let atWrite = Locked<PumpManager.RawStateValue?>(nil)
        scriptSetOffTheSteps(answeredRate: 1.05) { [unowned self] in
            atWrite.value = delegate.savedState
        }
        XCTAssertNil(commandTempBasal(1.08, duration: 30 * Self.minute))
        settle()
        let live = try XCTUnwrap(delegate.batches.first?.events.first)

        let saved = try XCTUnwrap(atWrite.value)
        let pending = try XCTUnwrap((saved["pendingTempBasal"] as? PendingTempBasal.RawValue).flatMap(PendingTempBasal.init(rawValue:)))
        XCTAssertEqual(pending.unitsPerHour, 1.05, accuracy: 1e-9, "written ahead as it is sent")

        try restart(from: saved)
        XCTAssertEqual(pumpManager.state.unconfirmedTempBasal?.value ?? 0, 1.05, accuracy: 1e-9)

        link.notify(PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: 131, patchId: 251, start: Self.ourStart, rate: 1.05))
        settle()
        XCTAssertNil(pumpManager.state.unconfirmedTempBasal, "shown running")

        let takenOver = try XCTUnwrap(delegate.batches.flatMap(\.events).last { $0.dose?.type == .tempBasal })
        XCTAssertEqual(takenOver.dose?.unitsPerHour ?? 0, live.dose?.unitsPerHour ?? 1, accuracy: 1e-9)
        XCTAssertEqual(rate(inIdentityOf: takenOver), "1.05")
        XCTAssertEqual(rate(inIdentityOf: takenOver), rate(inIdentityOf: live))
    }

    /// A rate a hair below a step - floating point noise, `0.7 - 0.05` - keeps that step: 13, not 12
    func testTempBasalAHairBelowAStepKeepsIt() {
        let rate = 0.7 - 0.05
        XCTAssertLessThan(rate, 0.65, "the noise this is about")
        scriptSetOffTheSteps(answeredRate: 0.65)

        XCTAssertNil(commandTempBasal(rate, duration: 30 * Self.minute))
        settle()

        XCTAssertEqual(steps(of: written(CommandType.SET_TEMP_BASAL)?.packet), 13)
        XCTAssertEqual(reports(of: .tempBasal).first?.unitsPerHour ?? 0, 0.65, accuracy: 1e-9)
        XCTAssertEqual(uncertainDeliveryErrors, 0)
        XCTAssertEqual(UnfinalizedDose.roundBasalRate(rate), 0.65)
    }

    /// Every rate and bolus amount of the 200U and the 300U patch's tables maps to itself, and is sent as its own steps;
    /// one past the top is capped at it
    func testEveryStepOfThePatchsTablesMapsToItself() {
        // Serial numbers whose model is a 200U (MD0201) and a 300U (MD8301) patch
        for (pumpSN, model, maximumRate) in [(Data([170, 118, 249, 217]), "200U", 25.0), (Data([0, 0, 0, 238]), "300U", 30.0)] {
            let state = activePatchState(patchId: 251, scheduledRate: 0.7, sequence: 130, reservoir: 150)
            state.pumpSN = pumpSN
            makeManager(state)
            XCTAssertTrue(pumpManager.state.pumpName.contains(model), pumpManager.state.pumpName)

            let rates = pumpManager.supportedBasalRates
            XCTAssertEqual(rates.last, maximumRate, model)
            for (index, rate) in rates.enumerated() {
                XCTAssertEqual(pumpManager.roundToSupportedBasalRate(unitsPerHour: rate), rate, "\(model) rate \(rate)")
                XCTAssertEqual(UnfinalizedDose.roundBasalRate(rate), rate, "\(model) rate \(rate)")
                XCTAssertEqual(steps(of: SetTempBasalPacket(rate: rate, duration: 30 * Self.minute)), index, "\(model) rate \(rate)")
            }
            XCTAssertEqual(pumpManager.roundToSupportedBasalRate(unitsPerHour: maximumRate + 1), maximumRate, model)

            for (index, units) in pumpManager.supportedBolusVolumes.enumerated() {
                XCTAssertEqual(pumpManager.roundToSupportedBolusVolume(units: units), units, "\(model) bolus \(units)")
                XCTAssertEqual(steps(of: SetBolusPacket(bolusAmount: units)), index + 1, "\(model) bolus \(units)")
            }
        }
    }
}

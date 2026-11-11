import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerBolusScenarioTests {
    // MARK: - Amounts off the patch's steps

    // An amount between two 0.05 U steps is floored once, as the command begins: sent, written ahead, matched and
    // reported as the step below (jbr7rr/MedtrumKit#222) - never more than asked for. One that floors to none is refused.

    /// Patch 236, its clock where the SetBolus of `user.txt:11229` started record 123
    private func makeManagerForTheBolusOfRecord123() -> Date {
        let patchSentAt = Date.fromMedtrumSeconds(0x17A8_8697)
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)
        return patchSentAt
    }

    /// 0.13 U: 2 steps written - 3, the nearest, is more than asked for - and reported as 0.10 U. Its completion and its
    /// record, both of 0.10 U, are its own: final by its number, nothing miscounted.
    func testBolusOffTheStepsIsSentAsTheStepBelowAndFinalizedByItsRecord() {
        let patchSentAt = makeManagerForTheBolusOfRecord123()

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(0.13))
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertEqual(steps(of: link.writes.first?.packet), 2)
        XCTAssertEqual(pumpManager.state.bolusDose?.recordSequence, 123)
        let started = reports(of: .bolus).first
        XCTAssertEqual(started?.programmedUnits ?? 0, 0.1, accuracy: 1e-9)

        // Completed, 0.10 U, naming record 123 the newest
        link.notify("202211800200040d7b00ec000000000000")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)

        link.script(
            CommandType.GET_RECORD,
            PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: patchSentAt, amount: 0.1, delivered: 0.1)
        )
        syncRecords()

        XCTAssertEqual(pumpManager.recordStore.records.first?.outcome?.hasPrefix("finalized bolus"), true)
        let final = assertOneFinal(of: started)
        XCTAssertEqual(final?.programmedUnits ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(final?.deliveredUnits ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(delegate.alerts.count, 0, "nothing miscounted")
        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertTrue(uncertain.isEmpty, "nothing was uncertain")
    }

    /// Killed as the SetBolus of 0.13 U awaited its answer: the bolus taken over is the one written ahead, 0.10 U - not
    /// floored again - with the identity the live run reported it by
    func testBolusOffTheStepsTakenOverAfterAKillIsTheLiveOne() throws {
        _ = makeManagerForTheBolusOfRecord123()
        let sent = try sendBolus(0.13, .fragments(["0f13280000007b00ec009786a8178900"]))
        XCTAssertNil(sent.error)
        let pending = try XCTUnwrap((sent.atWrite["pendingBolus"] as? PendingBolus.RawValue).flatMap(PendingBolus.init(rawValue:)))
        XCTAssertEqual(pending.units, 0.1, accuracy: 1e-9, "written ahead as it is sent")
        let live = try XCTUnwrap(delegate.batches.first?.events.first)

        try restart(from: sent.atWrite)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let takenOver = try XCTUnwrap(delegate.batches.first?.events.first)

        XCTAssertEqual(takenOver.dose?.programmedUnits ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(takenOver.raw, live.raw)
        XCTAssertEqual(takenOver.dose?.syncIdentifier, live.dose?.syncIdentifier)
    }

    /// 0.03 U floors to none: refused before anything - no write-ahead, no hand-over, no connect, nothing written
    func testBolusBelowTheFirstStepIsRefusedBeforeAnythingIsSent() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))

        let error = commandBolus(0.03)
        settle()

        guard case let .deviceState(cause)? = error, case .isBelowMinimumBolus? = cause as? MedtrumConnectError else {
            XCTFail("Expected isBelowMinimumBolus, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(link.requestedCommands, [])
        XCTAssertEqual(link.connects, 0)
        XCTAssertNil(pumpManager.state.pendingBolus)
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertTrue(delegate.savedStates.allSatisfy { $0["pendingBolus"] == nil }, "never written ahead")
        XCTAssertEqual(delegate.batches.count, 0)
    }

    /// An amount a hair below a step - floating point noise - keeps that step: 0.05 U is sent, not refused
    func testBolusAHairBelowAStepKeepsIt() {
        let units = 0.05 - 1e-12
        _ = makeManagerForTheBolusOfRecord123()

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(units))
        settle()

        XCTAssertEqual(steps(of: link.writes.first?.packet), 1)
        XCTAssertEqual(reports(of: .bolus).first?.programmedUnits ?? 0, 0.05, accuracy: 1e-9)
    }
}

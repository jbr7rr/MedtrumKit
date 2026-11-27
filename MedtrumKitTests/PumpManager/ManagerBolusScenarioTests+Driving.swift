import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerBolusScenarioTests {
    /// 2 U sent, its SetBolus answered with `answer`, a cancel asked for while it waits for the host to take the state -
    /// held up after saving it, the command going on once its bound is up - the CancelBolus answered if `cancelWritten`.
    /// Returns both outcomes.
    func sendBolusCancelledAsItIsOut(
        _ answer: FakeMedtrumLink.Answer,
        cancelWritten: Bool
    ) -> (error: PumpManagerError??, cancel: PumpManagerResult<DoseEntry?>?) {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        pumpManager.dosingHandOverTimeout = 1
        let releaseHost = stallHostAfterSaving("pendingBolus")
        defer { releaseHost() }
        link.script(CommandType.SET_BOLUS, answer)
        if cancelWritten {
            link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        }

        let sent = expectation(description: "enactBolus")
        let error = Locked<PumpManagerError??>(nil)
        pumpManager.enactBolus(units: 2, activationType: .manualNoRecommendation) { outcome in
            error.value = outcome
            sent.fulfill()
        }
        let until = Date.now.addingTimeInterval(5)
        while pumpManager.state.pendingBolus == nil, Date.now < until {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNotNil(pumpManager.state.pendingBolus, "out")
        let cancel = startCancel()
        XCTAssertEqual(pumpManager.state.bolusState, .canceling, "of the bolus out")

        wait(for: [sent], timeout: 10)
        let cancelled = cancel()
        releaseHost()
        settle()
        return (error.value, cancelled)
    }

    /// 2 U answered as record 123, running - `user.txt:11229`
    func startAnsweredBolus() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
    }

    /// Holds the command lock on another thread, as an operation in flight does, until the returned release is called
    func holdCommandLock() -> () -> Void {
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [pumpManager] in
            pumpManager?.withCommandLock {
                held.signal()
                _ = release.wait(timeout: .now() + 30)
            }
        }
        held.wait()
        return { release.signal() }
    }

    /// A cancel asked for now, its outcome waited for by the returned call - 5 s at most
    func startCancel() -> () -> PumpManagerResult<DoseEntry?>? {
        let done = expectation(description: "cancelBolus")
        let result = Locked<PumpManagerResult<DoseEntry?>?>(nil)
        pumpManager.cancelBolus { outcome in
            result.value = outcome
            done.fulfill()
        }
        return { [unowned self] in
            wait(for: [done], timeout: 5)
            return result.value
        }
    }

    /// `user.txt:11229-11295`: 2 U answered as record 123 from patch second 0x17A88697, completed at 2.0 U - waiting on
    /// its record. Returns its first report.
    func completeAnsweredBolus() -> DoseEntry? {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        link.notify("202211802800040d7b00ec000000000000")
        settle()

        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.recordSequence, 123)
        return delegate.batches.first?.events.first?.dose
    }

    /// 2 U answered as record 123 from `patchSentAt` (`user.txt:11229`), cancelled at 0.4 U; the patch's completion of it
    /// lost with the link, so the record number known stays 122. Then 2 U whose SetBolus gets no answer, which the
    /// patch runs to completion as record 124. Returns the first report of each.
    func cancelledThenUnansweredBolus(patchSentAt: Date) throws -> (cancelled: DoseEntry, unanswered: DoseEntry) {
        let state = activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6)
        alignPatchClock(state, patchTime: patchSentAt)
        makeManager(state)

        link.script(CommandType.SET_BOLUS, fragments: "0f13280000007b00ec009786a8178900")
        XCTAssertNil(commandBolus(2.0))
        link.notify("202210000800280d0000000000") // 0.4 U
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        guard case .success? = commandCancelBolus() else {
            XCTFail("Cancel failed")
            throw CancellationError()
        }
        settle()

        let cancelled = try XCTUnwrap(delegate.batches.first?.events.first?.dose)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.deliveredUnits ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 122)

        // A dose's identity is its start to the second
        Thread.sleep(forTimeInterval: 1.05)

        link.script(CommandType.SET_BOLUS, .timeout)
        XCTAssertTrue(isUncertainDelivery(commandBolus(2.0)))
        settle()
        let unanswered = try XCTUnwrap(reports(of: .bolus).first { $0.syncIdentifier != cancelled.syncIdentifier })
        // Gone out with 123, the newest claimed, as the newest known: the number known lags it
        XCTAssertEqual(pumpManager.state.bolusDose?.snapshot.sequenceAtSend, 123)

        // The link back: its completion, 2 U, and the patch at record 124
        advanceClock(by: 3 * Self.minute)
        link.notify("200200802800")
        link.notify("200001" + "7c00ec00")
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.currentSequenceNumber, 124)
        XCTAssertEqual(pumpManager.state.awaitingRecord.count, 2)

        return (cancelled, unanswered)
    }

    /// The SetBolus of 0.3 U of `user.txt:67542` taken over after the app was killed awaiting its answer, reported in
    /// full; past its deadline a full status ends it - `confirmingRecords`: one telling the newest record, 823. `answer`:
    /// what came of its write in the run before - none, or a failure, the host's state still pending. Returns its first
    /// report.
    func takeOverUnansweredBolusAndEndItAtItsDeadline(
        confirmingRecords: Bool = true,
        answer: FakeMedtrumLink.Answer = .timeout
    ) throws -> DoseEntry? {
        makeManager(unansweredBolusState())
        try restart(from: try sendBolus(0.3, answer).atWrite)
        pumpManager.ensureCurrentPumpData(completion: nil)
        settle()
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertNil(started?.deliveredUnits, "counted in full")

        advanceClock(by: 173)
        if confirmingRecords {
            link.deliverFullStatus([
                "2f030301000020ee0d800200800000063703f7ab",
                "2f03030200ca31cc172f20009d092493c917d076",
                "2f030303ab563703f7005ea202009a0827bb"
            ])
        } else {
            link.deliverFullStatus(notification: "200000", duringReconnect: false)
        }
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertNil(delegate.batches.last?.events.last?.dose?.deliveredUnits, "counted in full until its record")
        return started
    }

    /// 2:53 after the SetBolus of `startUnansweredBolus`, past its deadline: the next full status of `user.txt` ends it,
    /// telling the newest record, 823
    func endUnansweredBolusAtItsDeadline() {
        advanceClock(by: 173)
        link.deliverFullStatus([
            "2f030301000020ee0d800200800000063703f7ab",
            "2f03030200ca31cc172f20009d092493c917d076",
            "2f030303ab563703f7005ea202009a0827bb"
        ])
        settle()
        XCTAssertNil(pumpManager.state.bolusDose)
    }

    /// Where the cancel of `cancelTempBasalReadingItsRecords` ends the temp basal of `unansweredBolusState`, on the patch
    /// clock
    private static let unansweredBolusTempBasalEnd = Date.fromMedtrumSeconds(0x17CC_31CA + 200)

    /// The record of the temp basal of `unansweredBolusState`, as the cancel ends it
    func unansweredBolusTempBasalRecord(sequence: Int) -> [String] {
        PatchBytes.basalRecord(
            sequence: sequence,
            patchId: 247,
            type: .ABSOLUTE_TEMP,
            start: Date.fromMedtrumSeconds(0x17CC_31CA),
            end: Self.unansweredBolusTempBasalEnd,
            rate: 2.35,
            delivered: 0.15
        )
    }

    /// The temp basal of `unansweredBolusState` cancelled, the answer naming its record `cancelRecord`: `records`, the
    /// ones past the cursor up to it, are read as it ends
    func cancelTempBasalReadingItsRecords(cancelRecord: Int, _ records: [[String]]) {
        link.script(CommandType.CANCEL_TEMP_BASAL, PatchBytes.segmentAnswer(
            command: CommandType.CANCEL_TEMP_BASAL,
            type: .STANDARD,
            rate: 0.6,
            sequence: cancelRecord,
            patchId: 247,
            start: Self.unansweredBolusTempBasalEnd
        ))
        for record in records {
            link.script(CommandType.GET_RECORD, record)
        }
        XCTAssertNil(commandTempBasal(0, duration: 0))
        settle()
        XCTAssertEqual(link.writtenCommands.filter { $0 == CommandType.GET_RECORD }.count, records.count, "read as it ended")
    }

    /// The state of `user.txt:67525-67555`
    func unansweredBolusState() -> MedtrumPumpState {
        let state = activePatchState(patchId: 247, scheduledRate: 0.6, sequence: 823, reservoir: 123.15)
        state.basalDose = runningTempBasal(
            rate: 2.35,
            startedAgo: 1,
            duration: 30 * Self.minute,
            pumpStartTime: Date.fromMedtrumSeconds(0x17CC_31CA)
        )
        state.basalState = .tempBasal
        alignPatchClock(state, patchTime: Date.fromMedtrumSeconds(0x17CC_31CB))
        return state
    }

    /// The state of `user.txt:67525-67555`, then the SetBolus of 0.3 U that got no answer
    func startUnansweredBolus() {
        makeManager(unansweredBolusState())

        link.script(CommandType.SET_BOLUS, .timeout)

        XCTAssertTrue(isUncertainDelivery(commandBolus(0.3)))
        settle()

        XCTAssertEqual(link.writes.first?.encoded(sequence: 0x06), "09130600010600000500")
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
        XCTAssertEqual(pumpManager.state.bolusDose?.confirmation, .uncertain)

        // Reported running in full, and the host warned once
        XCTAssertEqual(delegate.batches.count, 1)
        let started = delegate.batches.first?.events.first?.dose
        XCTAssertEqual(started?.isMutable, true)
        XCTAssertNil(started?.deliveredUnits)
        XCTAssertEqual(uncertainDeliveryErrors, 1)
        XCTAssertEqual(delegate.errors.count, 1)
        XCTAssertTrue(pumpManager.status.deliveryIsUncertain)
        XCTAssertEqual(delegate.statusUpdates.last?.status.deliveryIsUncertain, true)
    }
}

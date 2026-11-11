import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerBolusScenarioTests {
    // MARK: - Commands queued on the command lock

    /// A bolus asked for while another's SetBolus awaits its answer waits for that command, then finds the first one
    /// running: it is refused without going out, and the first runs on
    func testBolusQueuedBehindAnotherIsRefusedWithoutGoingOut() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75))

        let secondDone = expectation(description: "second bolus")
        let secondResult = Locked<PumpManagerError?>(nil)
        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { error in
                secondResult.value = error
                secondDone.fulfill()
            }
            // Past its checks, and waiting for the lock
            Thread.sleep(forTimeInterval: 0.3)
        }

        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        wait(for: [secondDone], timeout: 5)
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        guard case let .deviceState(error)? = secondResult.value, case .isBolussing? = error as? MedtrumConnectError else {
            XCTFail("The second bolus was not refused as bolusing: \(String(describing: secondResult.value))")
            return
        }
        XCTAssertEqual(pumpManager.state.bolusDose?.value, 0.05)
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
        XCTAssertEqual(reports(of: .bolus).count, 1)
    }

    /// The patch turns a bolus down: nothing of it is in the state, and what is there belongs to others - a cancel
    /// asked for meanwhile, waiting to go out, and a bolus the state has running by then, whatever put it there
    func testRejectedBolusLeavesWhatOtherOperationsHaveInTheState() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75))

        let running = UnfinalizedDose(units: 0.5, duration: 20, activationType: .manualNoRecommendation, insulinType: nil)
        let cancelDone = expectation(description: "cancelBolus")
        link.script(CommandType.SET_BOLUS, .failure(.invalidResponse(code: 8))) { [unowned self] in
            pumpManager.state.bolusDose = running
            pumpManager.cancelBolus { _ in cancelDone.fulfill() }
        }
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")

        let atRejection = Locked<(bolus: UnfinalizedDose?, cancelingSince: Date?)?>(nil)
        let rejected: PumpManagerError?? = completion(of: "enactBolus") { done in
            self.pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { error in
                // The cancel waits for this command: what it finds is what the rejection left
                atRejection.value = (self.pumpManager.state.bolusDose, self.pumpManager.state.cancelingBolusSince)
                done(error)
            }
        }
        wait(for: [cancelDone], timeout: 5)
        settle()

        XCTAssertNotNil(rejected ?? nil, "turned down")
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.CANCEL_BOLUS])
        XCTAssertTrue(atRejection.value?.bolus === running, "the running bolus was taken out of the state")
        XCTAssertNotNil(atRejection.value?.cancelingSince, "the cancel waiting to go out was cleared")
    }

    /// A bolus whose connect fails while another command holds the lock - the first bolus, here - is reported failed at
    /// once, not once that command is over, and leaves the first running
    func testBolusWhoseConnectFailsIsReportedAtOnceAndLeavesTheRunningOne() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.7, sequence: 936, reservoir: 75))

        let secondResult = Locked<PumpManagerError?>(nil)
        let secondReportedDuringTheFirst = Locked(false)
        let secondDone = expectation(description: "second bolus")
        link.script(CommandType.SET_BOLUS, .fragments(["0f1343000000a903ec00f907ab17b300"])) { [unowned self] in
            link.connectError = .failedToConnectToDevice
            let reported = DispatchSemaphore(value: 0)
            pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { error in
                secondResult.value = error
                reported.signal()
                secondDone.fulfill()
            }
            secondReportedDuringTheFirst.value = reported.wait(timeout: .now() + 1) == .success
            link.connectError = nil
        }

        XCTAssertNil(commandBolus(0.05, activationType: .automatic))
        wait(for: [secondDone], timeout: 5)
        settle()

        XCTAssertTrue(secondReportedDuringTheFirst.value, "the failed connect waited for the command holding the lock")
        guard case .communication? = secondResult.value else {
            XCTFail("The second bolus did not fail to connect: \(String(describing: secondResult.value))")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertEqual(pumpManager.state.bolusDose?.value, 0.05)
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
    }

    // MARK: - A cancel waiting for the link

    /// iAPS review 2026-10-26: a cancel waits for the command lock behind another operation - as long as a command may
    /// take - while the bolus it was asked for completes and the loop's next starts, taking the lock first. It shows
    /// `.canceling` only while its own bolus runs, and once it has the link writes nothing: the new bolus runs on and is
    /// finalized by its record.
    func testCancelOfABolusOverByTheTimeItHasTheLinkDoesNotStopTheNextOne() throws {
        startAnsweredBolus()
        let release = holdCommandLock()
        let cancel = startCancel()
        XCTAssertEqual(pumpManager.state.bolusState, .canceling)

        link.notify("202211802800040d7b00ec000000000000") // 2.0 U, complete, record 123
        settle()
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus, "the bolus it was asked for is over")
        XCTAssertNil(pumpManager.state.cancelingBolusSince)

        // The loop's next bolus, ahead of the cancel on the lock
        let next = UnfinalizedDose(units: 0.5, duration: 20, activationType: .automatic, insulinType: nil)
        next.noteAnswer(recordSequence: 124)
        pumpManager.withDoseReportLock { pumpManager.state.bolusDose = next }
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress, "not shown as cancelled")

        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS], "no CancelBolus")
        XCTAssertTrue(pumpManager.state.bolusDose === next)
        XCTAssertFalse(next.isFinished)

        link.notify(Self.completion(delivered: 10, record: 124))
        settle()
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(sequence: 123, patchId: 236, start: Date.now, amount: 2, delivered: 2))
        link.script(CommandType.GET_RECORD, PatchBytes.bolusRecord(sequence: 124, patchId: 236, start: Date.now, amount: 0.5, delivered: 0.45))
        syncRecords()

        let nextFinal = finals(of: reports(of: .bolus).first { $0.programmedUnits == 0.5 })
        XCTAssertFalse(nextFinal.isEmpty)
        XCTAssertEqual(nextFinal.first?.deliveredUnits ?? 0, 0.45, accuracy: 0.001, "by its record, not cancelled")
    }

    /// A cancel waiting for the link while its bolus completes on its own: nothing is written, the bolus ends as
    /// completed - not cancelled - and it succeeds
    func testCancelOfABolusThatCompletedBeforeTheLinkWritesNothing() {
        startAnsweredBolus()
        let release = holdCommandLock()
        let cancel = startCancel()

        link.notify("202211802800040d7b00ec000000000000")
        settle()
        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .completed)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
    }

    /// Two cancels of the same bolus - the host's retry while the first waits: one CancelBolus goes out, the bolus ends
    /// once, and both succeed, whichever runs first
    func testTwoCancelsOfTheSameBolusWriteOneCancel() {
        startAnsweredBolus()
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        let release = holdCommandLock()
        let first = startCancel()
        let second = startCancel()
        XCTAssertEqual(pumpManager.state.bolusState, .canceling)

        release()
        guard case .success? = first(), case .success? = second() else {
            XCTFail("A cancel did not succeed")
            return
        }
        settle()

        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.CANCEL_BOLUS])
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.awaitingRecord.filter { $0.type == .bolus }.count, 1)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .cancelled)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
        XCTAssertNil(pumpManager.state.cancelingBolusSince)
    }

    /// A cancel asked for while the SetBolus waits for the host to take the state - its command out, no dose yet: it
    /// is of that bolus, by when it went out. Answered, the dose registered with it, the cancel stops it.
    func testCancelAskedWhileTheSetBolusIsOutStopsItOnceAnswered() {
        let bolus = sendBolusCancelledAsItIsOut(.fragments(["0f13280000007b00ec009786a8178900"]), cancelWritten: true)
        XCTAssertNil(bolus.error ?? nil)
        guard case .success? = bolus.cancel else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.CANCEL_BOLUS])
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.awaitingRecord.first?.snapshot.finishReason, .cancelled)
    }

    /// The same, the SetBolus turned down: no bolus runs, and the cancel writes nothing
    func testCancelAskedWhileTheSetBolusIsOutWritesNothingOnceItFailed() {
        let bolus = sendBolusCancelledAsItIsOut(.failure(.invalidResponse(code: 8)), cancelWritten: false)
        XCTAssertNotNil(bolus.error ?? nil)
        guard case .success? = bolus.cancel else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS])
        XCTAssertNil(pumpManager.state.bolusDose)
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus)
    }

    /// The same, the SetBolus's answer lost: the bolus may be running, registered with when it went out - the cancel
    /// stops it
    func testCancelAskedWhileTheSetBolusIsOutStopsItWithItsAnswerLost() {
        let bolus = sendBolusCancelledAsItIsOut(.timeout, cancelWritten: true)
        XCTAssertTrue(isUncertainDelivery(bolus.error ?? nil))
        guard case .success? = bolus.cancel else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.SET_BOLUS, CommandType.CANCEL_BOLUS])
        XCTAssertNil(pumpManager.state.bolusDose)
    }

    /// A cancel with no bolus known - none running nor out - is written as before, with none by then either. It shows
    /// no `.canceling`, nor refuses dosing meanwhile: it stops nothing that runs.
    func testCancelWithNoBolusKnownIsWrittenWithNoneRunning() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        link.script(CommandType.CANCEL_BOLUS, fragments: "0714040000004800")
        let release = holdCommandLock()
        let cancel = startCancel()
        XCTAssertEqual(pumpManager.state.bolusState, .noBolus, "not shown cancelling")
        XCTAssertNil(pumpManager.state.cancelingBolusSince)

        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [CommandType.CANCEL_BOLUS])
    }

    /// The same, a bolus out by the time it has the link - its SetBolus waiting on the host: not written
    func testCancelWithNoBolusKnownWritesNothingWithABolusOut() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        let release = holdCommandLock()
        let cancel = startCancel()
        pumpManager.withDoseReportLock {
            pumpManager.state.pendingBolus = PendingBolus(units: 1, sentAt: Date.now, sequenceAtSend: 122, automatic: true)
        }

        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [])
        pumpManager.withDoseReportLock { pumpManager.state.pendingBolus = nil }
    }

    /// The same, a bolus running by the time it has the link: not written, the bolus runs on
    func testCancelWithNoBolusKnownWritesNothingWithABolusRunning() {
        makeManager(activePatchState(patchId: 236, scheduledRate: 0.6, sequence: 122, reservoir: 168.6))
        let release = holdCommandLock()
        let cancel = startCancel()
        let running = UnfinalizedDose(units: 0.5, duration: 20, activationType: .automatic, insulinType: nil)
        pumpManager.withDoseReportLock { pumpManager.state.bolusDose = running }
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)

        release()
        guard case .success? = cancel() else {
            XCTFail("The cancel did not succeed")
            return
        }
        XCTAssertEqual(link.writtenCommands, [])
        XCTAssertTrue(pumpManager.state.bolusDose === running)
        XCTAssertFalse(running.isFinished)
        pumpManager.withDoseReportLock { pumpManager.state.bolusDose = nil }
    }
}

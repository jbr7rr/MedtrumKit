@testable import MedtrumKit
import LoopKit
import XCTest

/// A dose is changed and read on several queues at once - the BLE queue, commands, the host's delegate queue, the
/// record sync. Every transition is one step, and every read of more than one field is one read, so nothing ever sees
/// a dose finished with an amount from before it finished.
final class UnfinalizedDoseConcurrencyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_694_631_000)

    private func makeBolus(value: Double = 2.0, delivered: Double = 0) -> UnfinalizedDose {
        UnfinalizedDose(rawValue: [
            "type": DoseType.bolus.rawValue,
            "value": value,
            "startDate": t0,
            "estimatedEndDate": t0.addingTimeInterval(.minutes(2)),
            "deliveredUnits": delivered,
            "automatic": false
        ])!
    }

    // MARK: - Completion racing progress

    func testCompletionRacingProgressEndsOnTheCompletionAmount() {
        let completed = 2.0
        let dose = makeBolus()
        let inconsistent = Locked(0)
        let finishes = Locked(0)

        DispatchQueue.concurrentPerform(iterations: 3000) { index in
            switch index % 3 {
            case 0 where index == 1500:
                if dose.finish(.completed, deliveredUnits: completed, endedAt: t0.addingTimeInterval(100)) {
                    finishes.mutate { $0 += 1 }
                }
            case 0:
                // always below the completion amount
                dose.updateProgress(delivered: Double(index % 39) * 0.05, at: t0.addingTimeInterval(Double(index) / 100))
            case 1:
                let snapshot = dose.snapshot
                if snapshot.isFinished, snapshot.deliveredUnits != completed {
                    inconsistent.mutate { $0 += 1 }
                }
            default:
                // saved while it finishes: before or after, never half-way
                let raw = dose.rawValue
                if raw["finishedAt"] != nil, raw["deliveredUnits"] as? Double != completed {
                    inconsistent.mutate { $0 += 1 }
                }
            }
        }

        XCTAssertEqual(finishes.value, 1)
        XCTAssertEqual(inconsistent.value, 0, "a finished dose was seen with an amount from before it finished")

        let snapshot = dose.snapshot
        XCTAssertTrue(snapshot.isFinished)
        XCTAssertEqual(snapshot.finishReason, .completed)
        XCTAssertEqual(snapshot.deliveredUnits, completed)
        XCTAssertEqual(snapshot.observedEndDate, t0.addingTimeInterval(100))
    }

    func testProgressAfterTheEndNeverLowersTheAmount() {
        let dose = makeBolus()
        XCTAssertTrue(dose.updateProgress(delivered: 1.2, at: t0.addingTimeInterval(60)).taken)
        XCTAssertTrue(dose.finish(.completed, deliveredUnits: 1.5, endedAt: t0.addingTimeInterval(80)))

        // a notification read before the end, handled after it
        XCTAssertFalse(dose.updateProgress(delivered: 1.3, at: t0.addingTimeInterval(90)).taken)

        let snapshot = dose.snapshot
        XCTAssertEqual(snapshot.deliveredUnits, 1.5)
        XCTAssertEqual(snapshot.lastProgressUnits, 1.2)
        XCTAssertEqual(snapshot.lastProgressAt, t0.addingTimeInterval(60))
    }

    func testProgressAfterACancelRaisesTheAmountUntilTheFinal() {
        let dose = makeBolus()
        dose.updateProgress(delivered: 0.7, at: t0.addingTimeInterval(40))
        XCTAssertTrue(dose.finish(.cancelled, endedAt: t0.addingTimeInterval(45), at: t0.addingTimeInterval(46)))

        // read just before the cancel ended it, handled after: raises the amount, and nothing else
        XCTAssertFalse(dose.updateProgress(delivered: 0.75, at: t0.addingTimeInterval(47)).taken)
        XCTAssertFalse(dose.updateProgress(delivered: 0.6, at: t0.addingTimeInterval(48)).taken)

        var snapshot = dose.snapshot
        XCTAssertEqual(snapshot.deliveredUnits, 0.75)
        XCTAssertEqual(snapshot.lastProgressUnits, 0.7)
        XCTAssertEqual(snapshot.lastProgressAt, t0.addingTimeInterval(40))
        XCTAssertEqual(snapshot.finishReason, .cancelled)
        XCTAssertEqual(snapshot.observedEndDate, t0.addingTimeInterval(45))
        XCTAssertEqual(snapshot.finishedAt, t0.addingTimeInterval(46))
        XCTAssertEqual(dose.fallbackDeliveredUnits, 0.75)

        // the final is fixed with it, and nothing moves it after
        XCTAssertTrue(dose.finalize(deliveredUnits: nil))
        XCTAssertFalse(dose.updateProgress(delivered: 0.8, at: t0.addingTimeInterval(49)).taken)
        snapshot = dose.snapshot
        XCTAssertEqual(snapshot.deliveredUnits, 0.75)
        XCTAssertEqual(snapshot.finalDeliveredUnits, 0.75)
    }

    // MARK: - Ending

    func testCancelAndInterruptionKeepTheLastAmountAndACompletionSetsItsOwn() {
        let cancelled = makeBolus()
        cancelled.updateProgress(delivered: 0.7, at: t0.addingTimeInterval(40))
        XCTAssertTrue(cancelled.finish(.cancelled, endedAt: t0.addingTimeInterval(45)))
        XCTAssertEqual(cancelled.deliveredUnits, 0.7)

        let interrupted = makeBolus()
        interrupted.updateProgress(delivered: 0.7, at: t0.addingTimeInterval(40))
        XCTAssertTrue(interrupted.finish(.interrupted, endedAt: nil))
        XCTAssertEqual(interrupted.deliveredUnits, 0.7)
        XCTAssertNil(interrupted.observedEndDate)

        let completed = makeBolus()
        completed.updateProgress(delivered: 1.9, at: t0.addingTimeInterval(100))
        XCTAssertTrue(completed.finish(.completed, deliveredUnits: 2.0, endedAt: t0.addingTimeInterval(110)))
        XCTAssertEqual(completed.deliveredUnits, 2.0)
    }

    func testACompletionBelowTheProgressSeenKeepsTheProgress() {
        let dose = makeBolus()
        dose.updateProgress(delivered: 1.5, at: t0.addingTimeInterval(90))

        // a stale or cached completion of the same bolus: the amount is cumulative, it can't have delivered less
        XCTAssertTrue(dose.finish(.completed, deliveredUnits: 0.3, endedAt: t0.addingTimeInterval(100)))

        let snapshot = dose.snapshot
        XCTAssertEqual(snapshot.finishReason, .completed)
        XCTAssertEqual(snapshot.deliveredUnits, 1.5)
        XCTAssertEqual(snapshot.observedEndDate, t0.addingTimeInterval(100))
        XCTAssertEqual(dose.fallbackDeliveredUnits, 1.5)

        // its record still says what it says
        XCTAssertTrue(dose.finalize(deliveredUnits: 0.3))
        XCTAssertEqual(dose.finalDeliveredUnits ?? -1, 0.3, accuracy: 0.0001)
    }

    func testTheFirstEndStandsButALaterAmountRaisesIt() {
        let dose = makeBolus()
        dose.updateProgress(delivered: 0.7, at: t0.addingTimeInterval(40))
        XCTAssertTrue(dose.finish(.cancelled, endedAt: t0.addingTimeInterval(45), at: t0.addingTimeInterval(46)))

        // a lower amount from a later end doesn't lower it
        XCTAssertFalse(dose.finish(.interrupted, deliveredUnits: 0.5, endedAt: nil))
        XCTAssertEqual(dose.deliveredUnits, 0.7)

        // the completion of the same bolus, read before the cancel ended it and handled after: its amount counts,
        // the cancel's end stands
        XCTAssertFalse(dose.finish(.completed, deliveredUnits: 0.8, endedAt: t0.addingTimeInterval(120)))

        let snapshot = dose.snapshot
        XCTAssertEqual(snapshot.finishReason, .cancelled)
        XCTAssertEqual(snapshot.deliveredUnits, 0.8)
        XCTAssertEqual(snapshot.observedEndDate, t0.addingTimeInterval(45))
        XCTAssertEqual(snapshot.finishedAt, t0.addingTimeInterval(46))
        XCTAssertEqual(dose.fallbackDeliveredUnits, 0.8)
    }

    func testOnlyOneOfManyRacingEndsWins() {
        let dose = makeBolus()
        let wins = Locked([Double]())

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let amount = Double(index) * 0.01
            if dose.finish(index.isMultiple(of: 2) ? .completed : .cancelled, deliveredUnits: amount, endedAt: nil) {
                wins.mutate { $0.append(amount) }
            }
        }

        XCTAssertEqual(wins.value.count, 1)
        // the winner's end, and the most any of them reported
        let winner = Int((wins.value.first ?? -1) / 0.01 + 0.5)
        XCTAssertEqual(dose.finishReason, winner.isMultiple(of: 2) ? UnfinalizedDose.FinishReason.completed : .cancelled)
        XCTAssertEqual(dose.deliveredUnits, 199 * 0.01)
    }

    func testFinalIsFixedOnce() {
        let dose = makeBolus()
        dose.finish(.cancelled, endedAt: t0.addingTimeInterval(30))
        let wins = Locked([Double]())

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let amount = Double(index) * 0.05
            if dose.finalize(deliveredUnits: amount) {
                wins.mutate { $0.append(amount) }
            }
        }

        XCTAssertEqual(wins.value.count, 1)
        // as rounded for the report
        XCTAssertEqual(dose.finalDeliveredUnits ?? -1, wins.value.first ?? -2, accuracy: 0.0001)
        XCTAssertEqual(dose.finalEndDate, t0.addingTimeInterval(30))
        // a finalized dose doesn't end again either, nor take a late amount
        XCTAssertFalse(dose.finish(.completed, deliveredUnits: 9, endedAt: nil))
        XCTAssertFalse(dose.updateProgress(delivered: 9).taken)
        XCTAssertEqual(dose.deliveredUnits, 0)
        XCTAssertEqual(dose.finishReason, .cancelled)
        XCTAssertEqual(dose.finalDeliveredUnits ?? -1, wins.value.first ?? -2, accuracy: 0.0001)
    }

    func testPatchStartAndRecordMatchOnlyWhileRunning() {
        let tempBasal = UnfinalizedDose(tempRate: 1.0, duration: .minutes(30), insulinType: nil, automatic: true)
        XCTAssertTrue(tempBasal.setPumpStartTime(t0))
        // the first one known stays
        XCTAssertFalse(tempBasal.setPumpStartTime(t0.addingTimeInterval(5)))
        XCTAssertEqual(tempBasal.pumpStartTime, t0)

        let ended = UnfinalizedDose(tempRate: 1.0, duration: .minutes(30), insulinType: nil, automatic: true)
        ended.finish(.cancelled, endedAt: Date.now)
        // a status after the end describes another segment
        XCTAssertFalse(ended.setPumpStartTime(t0))
        XCTAssertNil(ended.pumpStartTime)
        // and a profile change after it doesn't split it: it has its one record
        XCTAssertFalse(ended.disableRecordMatch())
        XCTAssertFalse(ended.recordMatchDisabled)
    }

    // MARK: - Progress reporter

    func testReporterEndsOnTheAmountTheDoseFinishedWith() {
        let completed = 2.0
        let dose = makeBolus(value: 2.0)
        let reporter = MedtrumDoseProgressReporter(dose: dose, reportingQueue: DispatchQueue(label: "reporting"))

        // One observer, reading in order while the dose progresses and finishes on other threads. It is running
        // before the first update (`started`), reads at a bounded pace and keeps a bounded number of readings.
        let isDone = Locked(false)
        let observed = Locked([Double]())
        let started = DispatchSemaphore(value: 0)
        let observer = DispatchGroup()
        observer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var values = [reporter.progress.deliveredUnits]
            started.signal()
            while !isDone.value {
                if values.count < 10000 {
                    values.append(reporter.progress.deliveredUnits)
                }
                usleep(10)
            }
            values.append(reporter.progress.deliveredUnits)
            observed.value = values
            observer.leave()
        }
        started.wait()

        DispatchQueue.concurrentPerform(iterations: 400) { index in
            if index == 200 {
                dose.finish(.completed, deliveredUnits: completed, endedAt: t0.addingTimeInterval(120))
            } else {
                // always below the completion amount, and late ones arrive after the end
                dose.updateProgress(delivered: Double(index) * 0.0045, at: t0.addingTimeInterval(Double(index) / 10))
            }
            reporter.update()
        }
        reporter.update()

        isDone.value = true
        observer.wait()

        let progress = reporter.progress
        XCTAssertEqual(progress.deliveredUnits, completed)
        XCTAssertEqual(progress.percentComplete, 1)
        XCTAssertTrue(progress.isComplete)

        let values = observed.value
        XCTAssertEqual(values.first, 0, "read before the dose progressed")
        XCTAssertEqual(values.last, completed)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "the reported amount went down")
    }

    func testReporterOfACancelledBolusEndsOnItsPartialAmount() {
        let dose = makeBolus(value: 2.0)
        let reporter = MedtrumDoseProgressReporter(dose: dose, reportingQueue: DispatchQueue(label: "reporting"))

        dose.updateProgress(delivered: 0.8, at: t0.addingTimeInterval(40))
        reporter.update()
        XCTAssertEqual(reporter.progress.deliveredUnits, 0.8)
        XCTAssertFalse(reporter.progress.isComplete)

        dose.finish(.cancelled, endedAt: t0.addingTimeInterval(45))
        reporter.update()
        XCTAssertEqual(reporter.progress.deliveredUnits, 0.8)
        XCTAssertEqual(reporter.progress.percentComplete, 0.4, accuracy: 0.0001)
    }

    func testOlderProgressArrivingLateDoesNotLowerTheAmountACancelKeeps() {
        let dose = makeBolus(value: 2.0)
        let reporter = MedtrumDoseProgressReporter(dose: dose, reportingQueue: DispatchQueue(label: "reporting"))

        XCTAssertTrue(dose.updateProgress(delivered: 0.8, at: t0.addingTimeInterval(40)).taken)
        reporter.update()

        // an older update, handled on another queue after the newer one
        XCTAssertFalse(dose.updateProgress(delivered: 0.7, at: t0.addingTimeInterval(41)).taken)
        XCTAssertEqual(dose.snapshot.lastProgressUnits, 0.8)
        XCTAssertEqual(dose.snapshot.lastProgressAt, t0.addingTimeInterval(40))

        dose.finish(.cancelled, endedAt: t0.addingTimeInterval(45))
        reporter.update()
        XCTAssertEqual(reporter.progress.deliveredUnits, 0.8)

        XCTAssertTrue(dose.finalize(deliveredUnits: nil))
        XCTAssertEqual(dose.snapshot.finalDeliveredUnits, 0.8)
    }

    // MARK: - Persistence

    func testEveryFieldSurvivesARoundTripUnderTheSameKeys() throws {
        let tempBasal = try XCTUnwrap(UnfinalizedDose(rawValue: [
            "type": DoseType.tempBasal.rawValue,
            "value": 1.25,
            "startDate": t0,
            "estimatedEndDate": t0.addingTimeInterval(.minutes(30)),
            "deliveredUnits": 0.0,
            "automatic": true
        ]))
        tempBasal.setPumpStartTime(t0.addingTimeInterval(2))
        tempBasal.disableRecordMatch()
        tempBasal.finish(.cancelled, endedAt: t0.addingTimeInterval(.minutes(10)), at: t0.addingTimeInterval(.minutes(11)))
        tempBasal.finalize(deliveredUnits: 0.2, endDate: t0.addingTimeInterval(.minutes(10)))

        let raw = tempBasal.rawValue
        XCTAssertEqual(
            Set(raw.keys),
            [
                "type", "value", "startDate", "estimatedEndDate", "deliveredUnits", "automatic", "pumpStartTime",
                "finishReason", "finishedAt", "observedEndDate", "recordMatchDisabled", "finalDeliveredUnits",
                "finalEndDate", "finalizedAt"
            ]
        )
        XCTAssertEqual(raw["finishReason"] as? String, "cancelled")
        XCTAssertEqual(raw["recordMatchDisabled"] as? Bool, true)

        // through a binary property list, as the host keeps it
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? UnfinalizedDose.RawValue)
        let restored = try XCTUnwrap(UnfinalizedDose(rawValue: decoded))
        XCTAssertEqual(restored.rawValue as NSDictionary, raw as NSDictionary)

        let bolus = makeBolus(value: 2.0)
        bolus.updateProgress(delivered: 0.9, at: t0.addingTimeInterval(50))
        bolus.finish(.completionNotSeen, endedAt: nil, at: t0.addingTimeInterval(300))
        let restoredBolus = try XCTUnwrap(UnfinalizedDose(rawValue: bolus.rawValue))
        XCTAssertEqual(restoredBolus.rawValue as NSDictionary, bolus.rawValue as NSDictionary)
        XCTAssertEqual(restoredBolus.lastProgressUnits, 0.9)
        XCTAssertEqual(restoredBolus.lastProgressAt, t0.addingTimeInterval(50))
        XCTAssertNil(restoredBolus.observedEndDate)
    }
}

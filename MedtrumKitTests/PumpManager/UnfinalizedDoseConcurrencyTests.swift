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

    /// A long temp basal finalized from our estimate: its rate × duration, in 0.05 U steps - 1.5 U/h for 24 h is 36 U,
    /// not the 30 U the table of rates ends at - and to the nearest step
    func testTempBasalEstimateIsNotCappedAtTheHighestRate() {
        let day = UnfinalizedDose(tempRate: 1.5, duration: .minutes(24 * 60), insulinType: nil, automatic: false, startDate: t0)
        let end = t0.addingTimeInterval(.minutes(24 * 60))
        day.finish(.completed, endedAt: end, at: end)
        XCTAssertEqual(day.fallbackDeliveredUnits, 36, accuracy: 0.0001)
        XCTAssertTrue(day.finalize(deliveredUnits: nil, at: end))
        XCTAssertEqual(day.finalEvent?.dose?.deliveredUnits ?? 0, 36, accuracy: 0.0001)

        // 0.6 U/h for 897 s: 0.1495 U
        let short = UnfinalizedDose(tempRate: 0.6, duration: .minutes(30), insulinType: nil, automatic: true, startDate: t0)
        short.finish(.cancelled, endedAt: t0.addingTimeInterval(897), at: t0.addingTimeInterval(897))
        XCTAssertEqual(short.fallbackDeliveredUnits, 0.15, accuracy: 0.0001)
    }

    /// Our estimate of a temp basal whose records were not read: the last status of its segment, and its rate since -
    /// within [what that status showed, rate × duration], in 0.05 U steps - else, or once restarted, rate × duration
    func testTempBasalEstimateGoesFromTheLastStatusOfItsSegment() throws {
        // 1.2 U/h, ended 21 min in: 0.42 U, 0.4 U as rate × duration
        func tempBasal(showing delivered: Double?, at minute: Double) -> UnfinalizedDose {
            let dose = UnfinalizedDose(tempRate: 1.2, duration: .minutes(30), insulinType: nil, automatic: true, startDate: t0)
            if let delivered {
                XCTAssertTrue(dose.noteStatusDelivery(delivered, receivedAt: t0.addingTimeInterval(.minutes(minute))))
            }
            dose.finish(.cancelled, endedAt: t0.addingTimeInterval(.minutes(21)), at: t0.addingTimeInterval(.minutes(21)))
            return dose
        }

        func estimate(_ dose: UnfinalizedDose, restarted: Bool = false) -> (Double, UnfinalizedDose.TempBasalEstimateSource) {
            let estimate = dose.tempBasalEstimate(of: dose.snapshot, restarted: restarted)
            return (estimate.units, estimate.source)
        }

        // 0.1 + 1.2 U/h × 10 min
        XCTAssertEqual(estimate(tempBasal(showing: 0.1, at: 11)).0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(estimate(tempBasal(showing: 0.1, at: 11)).1, .status)
        // 0.35 + 0.12 is past 1.2 U/h × 21 min, 0.42
        XCTAssertEqual(estimate(tempBasal(showing: 0.35, at: 15)).0, 0.4, accuracy: 0.0001)
        // Never below what the status showed
        XCTAssertEqual(estimate(tempBasal(showing: 0.45, at: 20)).0, 0.45, accuracy: 0.0001)
        // 0.05 + 0.15 and 0.05 + 0.12: 0.05 U steps, to the nearest
        XCTAssertEqual(estimate(tempBasal(showing: 0.05, at: 13.5)).0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(estimate(tempBasal(showing: 0.05, at: 15)).0, 0.15, accuracy: 0.0001)
        // No status, or restarted since: rate × duration
        XCTAssertEqual(estimate(tempBasal(showing: nil, at: 0)).0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(estimate(tempBasal(showing: nil, at: 0)).1, .rateTimesDuration)
        XCTAssertEqual(estimate(tempBasal(showing: 0.1, at: 11), restarted: true).0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(estimate(tempBasal(showing: 0.1, at: 11), restarted: true).1, .rateTimesDuration)
        // What finalizes it without a record
        XCTAssertEqual(tempBasal(showing: 0.1, at: 11).fallbackDeliveredUnits, 0.3, accuracy: 0.0001)

        // Only the latest status, and only while it runs; kept through a property list, and absent before it was kept
        let dose = UnfinalizedDose(tempRate: 1.2, duration: .minutes(30), insulinType: nil, automatic: true, startDate: t0)
        XCTAssertTrue(dose.noteStatusDelivery(0.1, receivedAt: t0.addingTimeInterval(.minutes(10))))
        XCTAssertFalse(dose.noteStatusDelivery(0.05, receivedAt: t0.addingTimeInterval(.minutes(5))))
        dose.finish(.cancelled, endedAt: t0.addingTimeInterval(.minutes(20)), at: t0.addingTimeInterval(.minutes(20)))
        XCTAssertFalse(dose.noteStatusDelivery(0.3, receivedAt: t0.addingTimeInterval(.minutes(20))))
        XCTAssertEqual(dose.snapshot.statusDelivery, 0.1)

        let data = try PropertyListSerialization.data(fromPropertyList: dose.rawValue, format: .binary, options: 0)
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? UnfinalizedDose.RawValue)
        let restored = try XCTUnwrap(UnfinalizedDose(rawValue: decoded))
        XCTAssertEqual(restored.snapshot.statusDelivery, 0.1)
        XCTAssertEqual(restored.snapshot.statusDeliveryReceivedAt, t0.addingTimeInterval(.minutes(10)))

        var older = decoded
        older["statusDelivery"] = nil
        older["statusDeliveryReceivedAt"] = nil
        let restoredOlder = try XCTUnwrap(UnfinalizedDose(rawValue: older))
        XCTAssertNil(restoredOlder.snapshot.statusDelivery)
        XCTAssertNil(restoredOlder.snapshot.statusDeliveryReceivedAt)
    }

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

    /// The parts of a running temp basal read as it ran: kept once each, only while it runs, saved with it - a part that
    /// does not decode is left out - and let go of with its final
    func testRecordedPartsAreKeptWhileItRunsSavedAndLetGoOfWithTheFinal() throws {
        let tempBasal = try XCTUnwrap(UnfinalizedDose(rawValue: [
            "type": DoseType.tempBasal.rawValue,
            "value": 0.6,
            "startDate": t0,
            "estimatedEndDate": t0.addingTimeInterval(.minutes(30)),
            "deliveredUnits": 0.0,
            "automatic": true
        ]))
        let first = UnfinalizedDose.RecordedPart(sequence: 946, patchId: 236, start: t0, end: t0.addingTimeInterval(435), delivered: 0.05)
        let second = UnfinalizedDose.RecordedPart(
            sequence: 949,
            patchId: 236,
            start: t0.addingTimeInterval(435),
            end: t0.addingTimeInterval(897),
            delivered: 0.05
        )
        XCTAssertTrue(tempBasal.keepRecordedPart(first))
        XCTAssertFalse(tempBasal.keepRecordedPart(first), "once")
        XCTAssertTrue(tempBasal.keepRecordedPart(second))
        XCTAssertEqual(tempBasal.snapshot.recordedParts, [first, second])

        // through a binary property list, as the host keeps it
        let data = try PropertyListSerialization.data(fromPropertyList: tempBasal.rawValue, format: .binary, options: 0)
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? UnfinalizedDose.RawValue)
        XCTAssertEqual(try XCTUnwrap(UnfinalizedDose(rawValue: decoded)).snapshot.recordedParts, [first, second])

        var garbled = decoded
        var parts = try XCTUnwrap(decoded["recordedParts"] as? [[String: Any]])
        parts[0]["end"] = "not a date"
        garbled["recordedParts"] = parts
        XCTAssertEqual(try XCTUnwrap(UnfinalizedDose(rawValue: garbled)).snapshot.recordedParts, [second])

        var older = decoded
        older["recordedParts"] = nil
        XCTAssertEqual(try XCTUnwrap(UnfinalizedDose(rawValue: older)).snapshot.recordedParts, [])

        tempBasal.finish(.cancelled, endedAt: t0.addingTimeInterval(897), at: t0.addingTimeInterval(900))
        let third = UnfinalizedDose.RecordedPart(sequence: 950, patchId: 236, start: t0, end: t0, delivered: 0)
        XCTAssertFalse(tempBasal.keepRecordedPart(third), "only while it runs")
        XCTAssertTrue(tempBasal.finalize(deliveredUnits: 0.1, endDate: t0.addingTimeInterval(897), at: t0.addingTimeInterval(901)))
        XCTAssertEqual(tempBasal.snapshot.recordedParts, [])
        XCTAssertNil(tempBasal.rawValue["recordedParts"])
    }
}

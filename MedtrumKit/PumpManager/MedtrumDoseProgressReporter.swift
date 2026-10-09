import Foundation
import LoopKit

// Progress follows the delivered amount reported by the patch rather than elapsed time: the patch can deliver slower
// than the estimated rate, and an estimate would complete while the bolus is still running.
// Without updates (e.g. disconnected) it stays at the last reported amount.
//
// The pump manager pushes updates (`update(activeDose:)`) from `notifyStateDidChange`, so the dose and pump state
// are only read on the path that mutates them; `progress` reads the locked snapshot.
//
// Completes only once the pump manager has finalized this dose (no longer `state.bolusDose`):
// confirmed completion and the reconnect path that assumes completion (`checkBolusDone`) report the full amount;
// a cancelled or interrupted bolus stays at its partial amount, and the reporter is torn down on `.noBolus`.
class MedtrumDoseProgressReporter: DoseProgressTimerEstimator {
    // Below 1, so a dose the patch reported as fully delivered doesn't read as complete before the patch confirms it.
    // High enough for the "x of y U" display to round to the full amount.
    private static let maxUnconfirmedPercent = 0.999

    private struct Snapshot: Equatable {
        var deliveredUnits: Double
        var isFinalized: Bool
    }

    private let dose: UnfinalizedDose
    private let units: Double
    private let snapshot: Locked<Snapshot>
    private let reportingQueue: DispatchQueue

    override var progress: DoseProgress {
        let snapshot = self.snapshot.value
        let percent = units > 0 ? min(snapshot.deliveredUnits / units, 1) : 1
        return DoseProgress(
            deliveredUnits: snapshot.deliveredUnits,
            percentComplete: snapshot.isFinalized ? percent : min(percent, Self.maxUnconfirmedPercent)
        )
    }

    // dose must be the pump manager's current `state.bolusDose`
    init(dose: UnfinalizedDose, reportingQueue: DispatchQueue) {
        self.dose = dose
        units = dose.value
        snapshot = Locked(Snapshot(deliveredUnits: dose.deliveredUnits, isFinalized: false))
        self.reportingQueue = reportingQueue

        super.init(reportingQueue: reportingQueue)
    }

    // Called by the pump manager with its current `state.bolusDose`, on the path that mutated it
    func update(activeDose: UnfinalizedDose?) {
        let newSnapshot = Snapshot(deliveredUnits: dose.deliveredUnits, isFinalized: activeDose !== dose)
        var changed = false
        snapshot.mutate { snapshot in
            // a finalized dose doesn't change anymore
            guard !snapshot.isFinalized, snapshot != newSnapshot else { return }
            snapshot = newSnapshot
            changed = true
        }
        guard changed else { return }

        reportingQueue.async { [weak self] in
            self?.notify()
        }
    }

    override func timerParameters() -> (delay: TimeInterval, repeating: TimeInterval) {
        // updates are pushed by the pump manager; the timer required by the base class only re-reports the snapshot
        let interval = TimeInterval.seconds(30)
        return (delay: interval, repeating: interval)
    }
}

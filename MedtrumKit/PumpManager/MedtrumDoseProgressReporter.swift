import Foundation
import LoopKit

// Progress follows the delivered amount reported by the patch rather than elapsed time: the patch can deliver slower
// than the estimated rate, and an estimate would complete while the bolus is still running.
// Without updates (e.g. disconnected) it stays at the last reported amount.
//
// The pump manager pushes updates (`update()`) from `notifyStateDidChange`, so the dose is only read on the path that
// mutates it; `progress` reads the locked snapshot.
//
// Completes once the dose itself is finished (`UnfinalizedDose.isFinished`) - it then waits for its record as the same
// object - rather than once it is no longer `state.bolusDose`: `notifyStateDidChange` runs on several queues, and one
// that read "no bolus" just before a new one started would complete the new one's reporter. It reports the amount the
// dose stopped at: a completion its own, a cancelled or interrupted bolus its partial one. A bolus never registered -
// its command not sent or turned down - never reaches a reporter. The reporter is torn down on `.noBolus`.
class MedtrumDoseProgressReporter: DoseProgressTimerEstimator {
    // Below 1, so a dose the patch reported as fully delivered doesn't read as complete before the patch confirms it.
    // High enough for the "x of y U" display to round to the full amount.
    private static let maxUnconfirmedPercent = 0.999

    private struct Snapshot: Equatable {
        var deliveredUnits: Double
        var isFinished: Bool
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
            percentComplete: snapshot.isFinished ? percent : min(percent, Self.maxUnconfirmedPercent)
        )
    }

    // dose must be the pump manager's current `state.bolusDose`
    init(dose: UnfinalizedDose, reportingQueue: DispatchQueue) {
        self.dose = dose
        units = dose.value
        snapshot = Locked(Snapshot(deliveredUnits: dose.deliveredUnits, isFinished: false))
        self.reportingQueue = reportingQueue

        super.init(reportingQueue: reportingQueue)
    }

    // Called by the pump manager on the path that mutated the dose
    func update() {
        // Both in one read: the amount a dose finished with is set in the same step as the end
        let dose = self.dose.snapshot
        let isFinished = dose.isFinished
        let deliveredUnits = dose.deliveredUnits
        var changed = false
        snapshot.mutate { snapshot in
            // Calls come from several queues, so one that read the dose earlier can arrive last: while it runs the
            // amount only grows. Finished, it is the amount the dose finished with, and doesn't change here anymore.
            let newSnapshot = Snapshot(
                deliveredUnits: isFinished ? deliveredUnits : max(snapshot.deliveredUnits, deliveredUnits),
                isFinished: isFinished
            )
            guard !snapshot.isFinished, snapshot != newSnapshot else { return }
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

import LoopKit
import SwiftUI

/// One dose we are currently tracking, flattened for display next to the patch's own records.
struct TrackedDose: Identifiable {
    let id: String
    let kind: String
    let start: Date
    let detail: String
}

/// Backs the pump records debug screen: what we think is being delivered, next to what the patch says.
///
/// The records themselves come straight from `PumpRecordStore`, which the view observes directly - this
/// only supplies our side of the comparison, refreshed off the pump status observer.
class PumpRecordsViewModel: ObservableObject, PumpManagerStatusObserver {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.pumpRecordsViewModel")

    @Published var doses: [TrackedDose] = []
    @Published var syncedSequence: Int = 0
    @Published var currentSequence: Int = 0
    @Published var isFetching = false
    @Published var fetchError: String?

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private let pumpManager: MedtrumPumpManager?

    init(pumpManager: MedtrumPumpManager?) {
        self.pumpManager = pumpManager

        guard let pumpManager else {
            return
        }

        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    /// How far behind the patch we are. The syncer walks at most a handful of records per sync, so a
    /// backlog here is expected right after adopting a patch rather than a sign of trouble.
    var pendingRecords: Int {
        max(0, currentSequence - syncedSequence)
    }

    /// Reads ten records either side of what is on screen. Debug-only - the driver reads forward from
    /// its own cursor and never revisits.
    func fetchRecords(_ direction: MedtrumPumpManager.RecordFetchDirection) {
        guard let pumpManager, !isFetching else {
            return
        }

        isFetching = true
        fetchError = nil

        pumpManager.fetchRecords(direction) { error in
            DispatchQueue.main.async {
                self.isFetching = false
                self.fetchError = error?.localizedDescription
            }
        }
    }

    func pumpManager(
        _ pumpManager: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            return
        }

        DispatchQueue.main.async {
            self.updateState(pumpManager.state)
        }
    }

    private func updateState(_ state: MedtrumPumpState) {
        syncedSequence = state.syncedSequenceNumber
        currentSequence = state.currentSequenceNumber

        var doses: [TrackedDose] = []

        if let bolus = state.bolusDose {
            doses.append(TrackedDose(
                id: "bolus",
                kind: "BOLUS",
                start: bolus.startDate,
                detail: "requested=\(units(bolus.value)) delivered=\(units(bolus.deliveredUnits)) " +
                    "ends=\(dateFormatter.string(from: bolus.estimatedEndDate))"
            ))
        }

        let basal = state.basalDose
        var detail: String = switch basal.type {
        case .tempBasal:
            "rate=\(units(basal.value))/h ends=\(dateFormatter.string(from: basal.estimatedEndDate))"
        case .basal:
            "rate=\(units(basal.value))/h"
        default:
            "-"
        }

        // Both starts, next to each other: ours is what the dose identity is built from, the patch's is
        // what a record gets matched on, and the gap between them is the skew any time-based matching
        // has to survive.
        detail += " ourStart=\(dateFormatter.string(from: basal.startDate))"

        if let pumpStartTime = basal.pumpStartTime {
            let skew = pumpStartTime.timeIntervalSince(basal.startDate)
            detail += " patchStart=\(dateFormatter.string(from: pumpStartTime))"
            detail += " skew=\(String(format: "%+.1f", skew))s"
        } else {
            detail += " patchStart=-"
        }

        doses.append(TrackedDose(
            id: "basal",
            kind: basal.type.rawValue.uppercased(),
            start: basal.startDate,
            detail: detail
        ))

        // Sent unanswered, not reported until a status or its record shows it ran
        if let pending = state.unconfirmedTempBasal {
            doses.append(TrackedDose(
                id: "unconfirmed-tempbasal",
                kind: "TEMPBASAL (unconfirmed)",
                start: pending.startDate,
                detail: "rate=\(units(pending.value))/h sent=\(pending.sentAt.map { dateFormatter.string(from: $0) } ?? "-")"
            ))
        }

        // Finished, reported as mutable until their record is read - or until they time out. Then final, until the
        // host confirms storing that.
        for dose in state.awaitingRecord {
            let snapshot = dose.snapshot
            var detail = "programmed=\(units(dose.value))" + (dose.type == .tempBasal ? "/h" : "")
            if dose.type == .bolus {
                detail += " delivered=\(units(snapshot.deliveredUnits))"
                detail += " record=\(snapshot.recordSequence.map { "#\($0)" } ?? "-")"
            }
            detail += " \(snapshot.finishReason?.rawValue ?? "-")"
            detail += " ended=\(snapshot.observedEndDate.map { dateFormatter.string(from: $0) } ?? "unseen")"
            detail += " patchStart=\(snapshot.pumpStartTime.map { dateFormatter.string(from: $0) } ?? "-")"
            if snapshot.recordMatchDisabled {
                detail += " noRecordMatch"
            }
            if let finalEndDate = snapshot.finalEndDate {
                detail += " final=\(snapshot.finalDeliveredUnits.map { units($0) } ?? "-")"
                detail += " finalEnd=\(dateFormatter.string(from: finalEndDate))"
            }

            doses.append(TrackedDose(
                id: "awaiting-\(dose.type.rawValue)-\(dose.startDate.timeIntervalSince1970)",
                kind: "\(dose.type.rawValue.uppercased()) (\(snapshot.isFinalized ? "final, unconfirmed" : "awaiting record"))",
                start: dose.startDate,
                detail: detail
            ))
        }

        self.doses = doses
    }

    /// The delivery numbers exactly as the host received them.
    ///
    /// Both are already final here - `delivered` has been through whatever rounding the dose type
    /// applies, so there is nothing to contrast it against. The estimate-versus-reported comparison
    /// belongs on the patch records, where the pump's own figure is the third number.
    func describe(_ dose: EmittedDose) -> String {
        var fields = ["programmed=\(units(dose.programmed))"]

        if let delivered = dose.delivered {
            fields.append("delivered=\(units(delivered))")
        } else {
            // A running dose, or a finished bolus whose end we never saw, has no delivered figure - the
            // host counts the full programmed amount until we finalize it
            fields.append("delivered=pending")
        }

        fields.append("end=\(dateFormatter.string(from: dose.end))")

        return fields.joined(separator: " ")
    }

    private func units(_ value: Double) -> String {
        String(format: "%.2fU", value)
    }
}

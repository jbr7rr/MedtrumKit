import LoopKit
import SwiftUI

/// One dose we are currently tracking, flattened for display next to the patch's own records.
struct TrackedDose: Identifiable {
    let id: String
    let kind: String
    let start: Date
    let detail: String
}

/// Every report the host got of one dose - one identity - oldest first, so the screen can show a dose's
/// life (mutable updates, then the final) as one entry rather than scattered through the list.
struct ReportedDose: Identifiable {
    var id: String { identity }
    let identity: String
    /// Short, stable tag for the identity, to tell reports of the same dose apart in the flat list
    let tag: String
    let reports: [EmittedDose]

    var latest: EmittedDose { reports[reports.count - 1] }
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
    /// The current patch, if its records are kept in a file - the full history the screen offers. Nil, none.
    @Published var historyPatch: UInt64?

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private let pumpManager: MedtrumPumpManager?
    private let showHistory: (UInt64) -> Void

    init(pumpManager: MedtrumPumpManager?, showHistory: @escaping (UInt64) -> Void = { _ in }) {
        self.pumpManager = pumpManager
        self.showHistory = showHistory

        guard let pumpManager else {
            return
        }

        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    /// Opens the full history of the current patch
    func toFullHistory() {
        guard let historyPatch else {
            return
        }
        showHistory(historyPatch)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    /// How far behind the patch we are. The syncer walks at most a handful of records per sync, so a
    /// backlog here is expected right after adopting a patch rather than a sign of trouble.
    var pendingRecords: Int {
        max(0, currentSequence - syncedSequence)
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
        historyPatch = pumpManager?.currentHistoryPatch

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

        // Finished boluses, reported as mutable until their record is read - or until they time out - and temp basals,
        // final as they end. Then final, until the host confirms storing that.
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

    /// The reports grouped by identity, the dose reported most recently first
    func reportedDoses(_ emitted: [EmittedDose]) -> [ReportedDose] {
        var order: [String] = []
        var reports: [String: [EmittedDose]] = [:]

        // `emitted` is newest first: the first sighting of an identity is its latest report
        for dose in emitted {
            if reports[dose.identity] == nil {
                order.append(dose.identity)
            }
            reports[dose.identity, default: []].insert(dose, at: 0)
        }

        return order.map { identity in
            ReportedDose(identity: identity, tag: Self.tag(for: identity), reports: reports[identity] ?? [])
        }
    }

    /// Which report of its dose `dose` was, and of how many in the list, plus the dose's tag
    func position(of dose: EmittedDose, in groups: [ReportedDose]) -> (index: Int, count: Int, tag: String)? {
        guard let group = groups.first(where: { $0.identity == dose.identity }),
              let index = group.reports.firstIndex(where: { $0.id == dose.id })
        else {
            return nil
        }
        return (index + 1, group.reports.count, group.tag)
    }

    /// FNV-1a of the identity, four hex digits: enough to match rows by eye, not a real identity
    private static func tag(for identity: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in identity.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%04x", hash & 0xFFFF)
    }

    /// The delivery numbers exactly as the host received them.
    ///
    /// Both are already final here - `delivered` has been through whatever rounding the dose type
    /// applies.
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

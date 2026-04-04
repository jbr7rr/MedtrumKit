import HealthKit
import LoopKit
import SwiftUI

class PreviousPatchDetailsViewModel: ObservableObject, PatchLifetimeFormatting {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.previousPatchDetailsViewModel")

    @Published var patchStateString: String = PatchState.none.description
    @Published var patchId: String = ""
    @Published var battery: Double = 0
    @Published var activatedAt: String = ""
    @Published var deactivatedAt: String = ""
    @Published var patchLifetime: String = ""
    @Published var reservoirLevel: Double? = nil
    @Published var initialReservoirLevel: Double? = nil

    let reservoirVolumeFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit())
        formatter.numberFormatter.minimumFractionDigits = 0
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    let batteryFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .volt())
        formatter.numberFormatter.minimumFractionDigits = 2
        formatter.numberFormatter.maximumFractionDigits = 2
        return formatter
    }()

    let dateTimeFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    let dateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    private let pumpManager: MedtrumPumpManager?
    init(pumpManager: MedtrumPumpManager?) {
        self.pumpManager = pumpManager

        guard let pumpManager = pumpManager else {
            return
        }

        updateState()
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func batteryText(for voltage: Double) -> String {
        let quantity = HKQuantity(unit: .volt(), doubleValue: voltage)
        return batteryFormatter.string(from: quantity) ?? ""
    }

    func reservoirText(for units: Double) -> String {
        let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: units)
        return reservoirVolumeFormatter.string(from: quantity) ?? ""
    }
}

extension PreviousPatchDetailsViewModel: PumpManagerStatusObserver {
    func pumpManager(
        _: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        updateState()
    }

    internal func updateState() {
        guard let pumpManager = self.pumpManager, let previousPatch = pumpManager.state.previousPatch else {
            return
        }

        DispatchQueue.main.async {
            self.patchStateString = (PatchState(rawValue: previousPatch.lastStateRaw) ?? .none).description
            self.patchId = "\(previousPatch.patchId.toUInt64())"
            self.activatedAt = self.dateTimeFormatter.string(from: previousPatch.activatedAt)
            self.deactivatedAt = self.dateTimeFormatter.string(from: previousPatch.deactivatedAt)
            self.patchLifetime = self.processPatchLifetime(previousPatch.activatedAt, previousPatch.deactivatedAt)
            self.battery = previousPatch.battery
            self.reservoirLevel = previousPatch.reservoirLevel
            self.initialReservoirLevel = previousPatch.initialReservoirLevel
        }
    }
}

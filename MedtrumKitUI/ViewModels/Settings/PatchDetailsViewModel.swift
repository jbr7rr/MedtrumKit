import HealthKit
import LoopKit
import SwiftUI

protocol PatchLifetimeFormatting {}

extension PatchLifetimeFormatting {
    func processPatchLifetime(_ startDate: Date, _ endDate: Date) -> String {
        let lifetime = max(0, endDate.timeIntervalSince(startDate))

        let days = Int(lifetime.days.rounded(.towardZero))
        let hours = Int(lifetime.hours.truncatingRemainder(dividingBy: 24).rounded(.towardZero))
        let minutes = Int(lifetime.minutes.truncatingRemainder(dividingBy: 60).rounded(.towardZero))

        if days > 0 {
            if hours == 0 {
                return [
                    "\(days) \(days == 1 ? LocalizedString("day", comment: "Unit for singular day") : LocalizedString("days", comment: "Unit for plural days"))",
                    "\(minutes) \(minutes == 1 ? LocalizedString("minute", comment: "Unit for singular minute") : LocalizedString("minutes", comment: "Unit for plural minutes"))"
                ].joined(separator: " ")
            }

            return [
                "\(days) \(days == 1 ? LocalizedString("day", comment: "Unit for singular day") : LocalizedString("days", comment: "Unit for plural days"))",
                "\(hours) \(hours == 1 ? LocalizedString("hour", comment: "Unit for singular hour") : LocalizedString("hours", comment: "Unit for plural hours"))"
            ].joined(separator: " ")
        }

        if hours == 0 {
            return "\(minutes) \(minutes == 1 ? LocalizedString("minute", comment: "Unit for singular minute") : LocalizedString("minutes", comment: "Unit for plural minutes"))"
        }

        return [
            "\(hours) \(hours == 1 ? LocalizedString("hour", comment: "Unit for singular hour") : LocalizedString("hours", comment: "Unit for plural hours"))",
            "\(minutes) \(minutes == 1 ? LocalizedString("minute", comment: "Unit for singular minute") : LocalizedString("minutes", comment: "Unit for plural minutes"))"
        ].joined(separator: " ")
    }
}

class PatchDetailsViewModel: ObservableObject, PatchLifetimeFormatting {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.patchDetailsViewModel")

    @Published var patchStateString: String = PatchState.none.description
    @Published var pumpBaseSN: String = ""
    @Published var swVersion: String = ""
    @Published var model: String = ""
    @Published var patchId: String = ""
    @Published var battery: Double = 0
    @Published var reservoirLevel: Double = 0
    @Published var initialReservoirLevel: Double? = nil
    @Published var activatedAt: String = ""
    @Published var patchLifetime: String = ""

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

extension PatchDetailsViewModel: PumpManagerStatusObserver {
    func pumpManager(
        _: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        updateState()
    }

    internal func updateState() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        DispatchQueue.main.async {
            self.patchStateString = pumpManager.state.pumpState.description
            self.model = pumpManager.state.model
            self.swVersion = pumpManager.state.swVersion
            self.pumpBaseSN = pumpManager.state.pumpSN.hexEncodedString().uppercased()
            self.patchId = "\(pumpManager.state.patchId.toUInt64())"
            self.battery = pumpManager.state.battery
            self.reservoirLevel = pumpManager.state.reservoir
            self.initialReservoirLevel = pumpManager.state.initialReservoir

            if let patchActivatedAt = pumpManager.state.patchActivatedAt {
                self.activatedAt = self.dateTimeFormatter.string(from: patchActivatedAt)
                self.patchLifetime = self.processPatchLifetime(patchActivatedAt, Date())
            }
        }
    }
}

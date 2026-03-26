import HealthKit
import LoopKit
import SwiftUI

enum PatchLifecycleState {
    case noPatch
    case active
    case gracePeriod
    case expired
    case expiredBasalOnly
}

class MedtrumKitSettingsViewModel: ObservableObject, PumpManagerStatusObserver {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.settingsViewModel")

    @Published var model: String = ""
    @Published var is300u: Bool = false
    @Published var showPumpTimeSyncWarning = false
    @Published var reservoirLevel: Double = 0
    @Published var maxReservoirLevel: Double = 1
    @Published var pumpTime = Date.distantPast
    @Published var pumpTimeSyncedAt = Date.distantPast
    @Published var patchState: PatchState = .none
    @Published var patchStateString: String = PatchState.none.description
    @Published var basalType: BasalState = .active
    @Published var basalRate: Double = 0
    @Published var insulinType: InsulinType = .novolog
    @Published var lastSync = Date.distantPast
    @Published var patchLifecycleProgress: Double = 0
    @Published var patchLifecycleState: PatchLifecycleState = .noPatch
    @Published var patchActivatedAt: Date? = nil
    @Published var patchExpiresAt: Date? = nil
    @Published var patchGracePeriodFrom: Date? = nil
    @Published var patchGraceTimeout = ""
    @Published var isConnected: Bool = false
    @Published var isReconnecting: Bool = false
    @Published var isUpdatingPumpState = false
    @Published var isUpdatingSuspend = false
    @Published var isUpdatingTempBasal = false
    @Published var showingHeartbeatWarning = false
    @Published var showingDeleteConfirmation = false
    @Published var hasPreviousPatch = false

    public var pumpName: String {
        pumpManager?.state.pumpName ?? "Medtrum Nano"
    }

    let reservoirVolumeFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit())
        formatter.numberFormatter.minimumFractionDigits = 0
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    let basalRateFormatter: NumberFormatter = {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumFractionDigits = 1
        numberFormatter.minimumIntegerDigits = 1
        return numberFormatter
    }()

    let dateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    let dateTimeFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    let timeRemainingFormatter: DateComponentsFormatter = {
        let dateComponentsFormatter = DateComponentsFormatter()
        dateComponentsFormatter.allowedUnits = [.hour, .minute]
        dateComponentsFormatter.unitsStyle = .full
        dateComponentsFormatter.zeroFormattingBehavior = .dropAll
        return dateComponentsFormatter
    }()

    let deactivatePatchAction: () -> Void
    let pumpRemovalAction: () -> Void
    let toSettings: () -> Void
    let toPatchDetails: () -> Void
    let toPreviousPatchDetails: () -> Void
    let toInsulinType: () -> Void
    let pumpActivationAction: (Bool) -> Void
    let activatePatchAction: () -> Void
    private let log = MedtrumLogger(category: "settingsViewModel")
    private let pumpManager: MedtrumPumpManager?
    init(
        _ pumpManager: MedtrumPumpManager?,
        _ deactivatePatchAction: @escaping () -> Void,
        _ pumpActivationAction: @escaping (Bool) -> Void,
        _ toSettings: @escaping () -> Void,
        _ toPatchDetails: @escaping () -> Void,
        _ toPreviousPatchDetails: @escaping () -> Void,
        _ toInsulinType: @escaping () -> Void,
        _ pumpRemovalAction: @escaping () -> Void,
        _ activatePatchAction: @escaping () -> Void
    ) {
        self.pumpManager = pumpManager
        self.deactivatePatchAction = deactivatePatchAction
        self.pumpActivationAction = pumpActivationAction
        self.pumpRemovalAction = pumpRemovalAction
        self.toInsulinType = toInsulinType
        self.toPatchDetails = toPatchDetails
        self.toPreviousPatchDetails = toPreviousPatchDetails
        self.toSettings = toSettings
        self.activatePatchAction = activatePatchAction

        guard let pumpManager = pumpManager else {
            return
        }

        isConnected = pumpManager.bluetooth.isConnected
        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func reservoirText(for units: Double) -> String {
        let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: units)
        return reservoirVolumeFormatter.string(from: quantity) ?? ""
    }

    var patchLifecycleDays: Int? {
        guard patchLifecycleState == .active, let patchGracePeriodFrom else {
            return nil
        }

        return Int((patchGracePeriodFrom.timeIntervalSince1970 - Date.now.timeIntervalSince1970).days.rounded(.towardZero))
    }

    var patchLifecycleHours: Int? {
        guard patchLifecycleState == .active, let patchGracePeriodFrom else {
            return nil
        }

        return Int(
            (patchGracePeriodFrom.timeIntervalSince1970 - Date.now.timeIntervalSince1970).hours
                .truncatingRemainder(dividingBy: 24).rounded(.towardZero)
        )
    }

    var patchLifecycleMinutes: Int? {
        guard patchLifecycleState == .active, let patchGracePeriodFrom else {
            return nil
        }

        return Int(
            (patchGracePeriodFrom.timeIntervalSince1970 - Date.now.timeIntervalSince1970).minutes
                .truncatingRemainder(dividingBy: 60).rounded(.towardZero)
        )
    }

    func syncData() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        isUpdatingPumpState = true
        pumpManager.syncPumpData { _ in
            DispatchQueue.main.async {
                self.isUpdatingPumpState = false
            }
        }
    }

    func didChangeInsulinType(_ newType: InsulinType?) {
        guard let type = newType else {
            return
        }

        pumpManager?.state.insulinType = type
        pumpManager?.notifyStateDidChange()
        insulinType = type
    }

    func stopUsingMedtrum() {
        guard let pumpManager = self.pumpManager else {
            pumpRemovalAction()
            return
        }

        pumpManager.notifyDelegateOfDeactivation {
            DispatchQueue.main.async {
                self.pumpRemovalAction()
            }
        }
    }

    func getLogs() -> [URL] {
        if let pumpManager = self.pumpManager {
            log.info(pumpManager.state.debugDescription)
        }
        return log.getDebugLogs()
    }

    func toPumpActivation() {
        guard let pumpManager = self.pumpManager else {
            pumpActivationAction(false)
            return
        }

        let alreadyPrimed = pumpManager.state.pumpState.rawValue >= PatchState.primed.rawValue
        pumpActivationAction(alreadyPrimed)
    }

    func suspendResumeButtonPressed() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        isUpdatingSuspend = true
        if basalType == .suspended {
            pumpManager.resumeDelivery { error in
                DispatchQueue.main.async {
                    self.isUpdatingSuspend = false
                }

                if let error = error {
                    self.log.error("Failed to resume delivery: \(error)")
                }
            }

        } else {
            pumpManager.suspendDelivery { error in
                DispatchQueue.main.async {
                    self.isUpdatingSuspend = false
                }

                if let error = error {
                    self.log.error("Failed to suspend delivery: \(error)")
                }
            }
        }
    }

    func stopTempBasal() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        isUpdatingTempBasal = true
        pumpManager.enactTempBasal(unitsPerHour: 0, for: 0) { error in
            DispatchQueue.main.async {
                self.isUpdatingTempBasal = false
            }

            if let error = error {
                self.log.error("Failed to stop temp basal: \(error)")
            }
        }
    }

    func checkConnection() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        if !pumpManager.bluetooth.isConnected {
            // Reconnect to patch
            isReconnecting = true
            pumpManager.bluetooth.ensureConnected { _ in
                DispatchQueue.main.async {
                    self.isReconnecting = false
                }
            }
            return
        } else {
            // Disconnect from patch
            pumpManager.bluetooth.disconnect()
            return
        }
    }

    func syncPumpTime() {
        guard let pumpManager = pumpManager else {
            return
        }

        isUpdatingPumpState = true
        pumpManager.bluetooth.ensureConnected { error in
            if error != nil {
                await MainActor.run {
                    self.isUpdatingPumpState = false
                }
                return
            }

            await StateSyncer.syncTime(pumpManager: pumpManager)
            await MainActor.run {
                self.isUpdatingPumpState = false
            }
        }
    }
}

extension MedtrumKitSettingsViewModel {
    func pumpManager(
        _ pumpManager: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            return
        }

        DispatchQueue.main.async {
            self.isConnected = pumpManager.bluetooth.isConnected
            self.updateState(pumpManager.state)
        }
    }

    private func updateState(_ state: MedtrumPumpState) {
        model = state.model
        switch model {
        case "MD8301":
            is300u = true
            maxReservoirLevel = 300
        default:
            is300u = false
            maxReservoirLevel = 200
        }

        showPumpTimeSyncWarning = state.shouldShowTimeWarning()
        patchState = state.pumpState
        patchStateString = state.pumpState.description
        pumpTime = state.pumpTime
        pumpTimeSyncedAt = state.pumpTimeSyncedAt
        reservoirLevel = state.reservoir
        basalType = state.basalState
        basalRate = basalType == .tempBasal ? (state.tempBasalUnits ?? state.currentBaseBasalRate) : state.currentBaseBasalRate
        lastSync = state.lastSync
        patchActivatedAt = state.patchActivatedAt
        patchGracePeriodFrom = state.patchGracePeriodFrom
        patchExpiresAt = state.patchExpiresAt
        hasPreviousPatch = state.previousPatch != nil

        if !state.patchId.isEmpty, let patchActivatedAt, let patchGracePeriodFrom, let patchExpiresAt {
            let totalLifetime = patchGracePeriodFrom.timeIntervalSince(patchActivatedAt)
            let progress = Date.now.timeIntervalSince1970 - patchActivatedAt.timeIntervalSince1970

            patchLifecycleProgress = min(progress / totalLifetime, 1)
            patchLifecycleState = getLifecycleState(state: state)

            if patchLifecycleState == .gracePeriod {
                let timeRemaining = patchExpiresAt.timeIntervalSinceNow
                patchGraceTimeout = timeRemainingFormatter.string(from: timeRemaining) ?? ""
            }
        } else {
            patchLifecycleState = .noPatch
        }

        if let insulinType = state.insulinType {
            self.insulinType = insulinType
        }
    }

    private func getLifecycleState(state: MedtrumPumpState) -> PatchLifecycleState {
        if patchLifecycleProgress < 1 {
            return .active
        }

        if let patchExpiresAt, Date.now > patchExpiresAt {
            return state.expirationTimer == 0 ? .expiredBasalOnly : .expired
        }

        return .gracePeriod
    }
}

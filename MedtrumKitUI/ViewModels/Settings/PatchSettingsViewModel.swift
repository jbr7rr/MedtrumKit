import LoopKit

class PatchSettingsViewModel: ObservableObject {
    @Published var maxHourlyInsulin: Double = 0 {
        didSet { checkDirtyState() }
    }

    @Published var maxDailyInsulin: Double = 0 {
        didSet { checkDirtyState() }
    }

    @Published var alarmSettings = Double(AlarmSettings.BeepOnly.rawValue) {
        didSet { checkDirtyState() }
    }

    @Published var expirationTimer: Double = 1 {
        didSet { checkDirtyState() }
    }

    @Published var notificationAfterActivation: Double = 70 {
        didSet { checkDirtyState() }
    }

    @Published var lowReservoirNotification: Double = 0 {
        didSet { checkDirtyState() }
    }

    @Published var isDirty: Bool = false
    @Published var is300u: Bool = false
    @Published var isUpdating = false
    @Published var noActivePatch = false
    @Published var errorMessage: String = ""

    let updatePatch: Bool
    let nextStep: (() -> Void)?

    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.patchSettingsViewModel")
    private let pumpManager: MedtrumPumpManager?
    init(_ pumpManager: MedtrumPumpManager?, updatePatch: Bool, nextStep: (() -> Void)?) {
        self.pumpManager = pumpManager
        self.updatePatch = updatePatch
        self.nextStep = nextStep

        guard let pumpManager = pumpManager else {
            return
        }

        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    var alarmOptions: [Double] {
        // Hide all options with light & vibrations
        // This feature is discontinued
        Array(6 ... 7).map({ Double($0) })
    }

    func save() {
        guard let pumpManager = pumpManager else {
            return
        }

        pumpManager.state.maxHourlyInsulin = maxHourlyInsulin
        pumpManager.state.maxDailyInsulin = maxDailyInsulin
        pumpManager.state.alarmSetting = AlarmSettings(rawValue: UInt8(alarmSettings)) ?? .None
        pumpManager.state.expirationTimer = UInt8(expirationTimer)
        pumpManager.state.notificationAfterActivation = .hours(notificationAfterActivation)

        if lowReservoirNotification == 0 {
            pumpManager.state.lowReservoirWarning = nil
        } else {
            pumpManager.state.lowReservoirWarning = lowReservoirNotification
        }

        pumpManager.notifyStateDidChange()

        NotificationManager.activatePatchExpiredNotification(after: .hours(notificationAfterActivation))

        guard updatePatch, !noActivePatch else {
            nextStep?()
            return
        }

        isUpdating = true
        pumpManager.updatePatchSettings { result in
            DispatchQueue.main.async {
                self.isUpdating = false
                switch result {
                case let .failure(error):
                    self.errorMessage = error.localizedDescription
                    return
                case .success:
                    self.nextStep?()
                    return
                }
            }
        }
    }

    func checkDirtyState() {
        guard let pumpManager = pumpManager else {
            return
        }

        DispatchQueue.main.async {
            self.isDirty = (
                pumpManager.state.maxDailyInsulin != self.maxDailyInsulin ||
                    pumpManager.state.maxHourlyInsulin != self.maxHourlyInsulin ||
                    pumpManager.state.alarmSetting.rawValue != UInt8(self.alarmSettings) ||
                    pumpManager.state.expirationTimer != UInt8(self.expirationTimer) ||
                    pumpManager.state.notificationAfterActivation.hours != self.notificationAfterActivation ||
                    (pumpManager.state.lowReservoirWarning ?? 0) != self.lowReservoirNotification
            )
        }
    }
}

extension PatchSettingsViewModel: PumpManagerStatusObserver {
    func pumpManager(
        _ pumpManager: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            return
        }

        updateState(pumpManager.state)
    }

    func updateState(_ state: MedtrumPumpState) {
        DispatchQueue.main.async {
            self.noActivePatch = state.patchId.isEmpty
            self.maxHourlyInsulin = state.maxHourlyInsulin
            self.maxDailyInsulin = state.maxDailyInsulin
            self.alarmSettings = Double(state.alarmSetting.rawValue)
            self.expirationTimer = Double(state.expirationTimer)
            self.notificationAfterActivation = state.notificationAfterActivation.hours
            self.lowReservoirNotification = state.lowReservoirWarning ?? 0

            if state.pumpSN.isEmpty {
                // If no serial number is available, we should show the options that are supported by both 200u & 300u
                self.is300u = false
            } else {
                self.is300u = state.pumpName.contains("300U")
            }
        }
    }
}

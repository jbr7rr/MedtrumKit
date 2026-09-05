import LoopKit

enum PatchPrimingStatus: Equatable {
    case connecting
    case notConnected
    case patchNotFilled
    case readyToPrime
    case priming
    case failed(message: String)

    var title: String {
        switch self {
        case .connecting:
            return String(localized: "Connecting to the pump base...", comment: "Priming status while connecting")
        case .notConnected:
            return String(localized: "No connection to the pump base", comment: "Priming status without a connection")
        case .patchNotFilled:
            return String(localized: "Patch is not filled yet", comment: "Priming status while the patch is not filled")
        case .readyToPrime:
            return String(localized: "Patch is filled and ready", comment: "Priming status when the patch can be primed")
        case .priming:
            return String(localized: "Priming...", comment: "Priming status while priming runs")
        case .failed:
            return String(localized: "Priming could not be started", comment: "Priming status after a failure")
        }
    }

    var detail: String? {
        guard case let .failed(message) = self else {
            return nil
        }

        return message
    }

    var isFailure: Bool {
        if case .failed = self {
            return true
        }

        return false
    }

    var showsRetry: Bool {
        self == .notConnected
    }
}

class PatchPrimingViewModel: ObservableObject {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.primingView")
    private let logger = MedtrumLogger(category: "PatchPrimingViewModel")

    @Published var isPriming = false
    @Published var primeProgress: Double = 0
    @Published var primingError = ""
    @Published var is300u = false
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var patchState: PatchState = .none

    @Published var reservoirLevel: Double?

    let reservoirVolumeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.roundingMode = .floor
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    func reservoirText(for units: Double) -> String {
        reservoirVolumeFormatter.string(from: units as NSNumber) ?? ""
    }

    var status: PatchPrimingStatus {
        if isPriming {
            return .priming
        }

        if !primingError.isEmpty {
            return .failed(message: primingError)
        }

        #if targetEnvironment(simulator)
            return .readyToPrime
        #else
            if isConnecting {
                return .connecting
            }

            if !isConnected {
                return .notConnected
            }

            return patchState == .filled ? .readyToPrime : .patchNotFilled
        #endif
    }

    var canStartPriming: Bool {
        #if targetEnvironment(simulator)
            return !isPriming
        #else
            return !isPriming && isConnected && patchState == .filled
        #endif
    }

    private let nextStep: () -> Void
    let previousStep: () -> Void
    private let done: () -> Void
    private let pumpManager: MedtrumPumpManager?
    init(
        _ pumpManager: MedtrumPumpManager?,
        _ nextStep: @escaping () -> Void,
        _ previousStep: @escaping () -> Void,
        _ done: @escaping () -> Void
    ) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep
        self.previousStep = previousStep
        self.done = done

        guard let pumpManager = self.pumpManager else {
            return
        }

        is300u = pumpManager.state.pumpName.contains("300U")
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func connect() {
        #if targetEnvironment(simulator)
            isConnected = true
        #else
            guard let pumpManager = self.pumpManager, !isConnecting, !isPriming else {
                return
            }

            if pumpManager.state.sessionToken.isEmpty {
                logger.info("No session token yet, generating one before connecting")
                pumpManager.state.sessionToken = Crypto.genSessionToken()
                pumpManager.notifyStateDidChange()
            }

            isConnecting = true
            pumpManager.bluetooth.ensureConnected { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self else {
                        return
                    }

                    self.isConnecting = false

                    if let error = error {
                        self.logger.warning("Failed to connect to pump base: \(error.errorDescription ?? "EMPTY")")
                        self.isConnected = false
                        return
                    }

                    self.updateState()
                }
            }
        #endif
    }

    func startPrime() {
        #if targetEnvironment(simulator)
            pumpManager?.state.sessionToken = Crypto.genSessionToken()
            pumpManager?.state.pumpState = .primed
            pumpManager?.notifyStateDidChange()
            nextStep()
        #else
            guard let pumpManager = self.pumpManager else {
                nextStep()
                return
            }

            isPriming = true
            primingError = ""
            pumpManager.primePatch { result in
                if case let .failure(error) = result {
                    DispatchQueue.main.async {
                        self.primingError = error.description
                        self.isPriming = false
                    }
                    return
                }

                if pumpManager.state.pumpState.rawValue >= PatchState.primed.rawValue {
                    DispatchQueue.main.async {
                        self.nextStep()
                    }
                    return
                }

                // Command send succesfully, now we have to wait till primeProgress has reached PatchState.primed or PatchState.active
            }
        #endif
    }

    private func updateState() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        isConnected = pumpManager.state.isConnected
        reservoirLevel = isConnected ? pumpManager.state.reservoir : nil

        let newPatchState = pumpManager.state.pumpState
        if newPatchState != patchState {
            patchState = newPatchState
            primingError = ""
        }
    }
}

extension PatchPrimingViewModel: PumpManagerStatusObserver {
    func pumpManager(
        _ pumpManager: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        #if targetEnvironment(simulator)
            DispatchQueue.main.async {
                self.isPriming = false
            }
        #else
            guard let pumpManager = self.pumpManager else {
                return
            }

            DispatchQueue.main.async {
                self.updateState()
                self.primeProgress = Double(pumpManager.state.primeProgress) / 240

                if pumpManager.state.pumpState.rawValue > PatchState.priming.rawValue,
                   pumpManager.state.pumpState.rawValue < PatchState.active.rawValue
                {
                    pumpManager.removeStatusObserver(self)
                    self.nextStep()
                } else if pumpManager.state.pumpState.rawValue >= PatchState.active.rawValue {
                    // Patch already activated, ready to jump to settings
                    pumpManager.removeStatusObserver(self)
                    self.done()
                }
            }
        #endif
    }
}

class DeactivatePatchViewModel: ObservableObject {
    @Published var isDeactivating = false
    @Published var deactivationError = ""
    @Published var is300u = false

    private let nextStep: () -> Void
    private let pumpManager: MedtrumPumpManager?
    init(_ pumpManager: MedtrumPumpManager?, _ nextStep: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep

        guard let pumpManager = self.pumpManager else {
            return
        }

        is300u = pumpManager.state.pumpName.contains("300U")
    }

    func forceDeactivate() {
        AuthorizeBiometrics.authenticate { success in
            guard success else {
                DispatchQueue.main.async {
                    self.deactivationError = LocalizedString("Authentication failure", comment: "auth failed")
                }
                return
            }

            DispatchQueue.main.async {
                self.pumpManager?.forceDeactivatePatch()
                self.nextStep()
            }
        }
    }

    func deactivate() {
        #if targetEnvironment(simulator)
            AuthorizeBiometrics.authenticate { success in
                DispatchQueue.main.async {
                    guard success else {
                        self.deactivationError = LocalizedString("Authentication failure", comment: "auth failed")
                        return
                    }

                    if let pumpManager = self.pumpManager {
                        pumpManager.state.previousPatch = PreviousPatch(
                            patchId: pumpManager.state.patchId,
                            lastStateRaw: pumpManager.state.pumpState.rawValue,
                            lastSyncAt: pumpManager.state.lastSync,
                            battery: pumpManager.state.battery,
                            activatedAt: pumpManager.state.patchActivatedAt ?? Date.distantPast,
                            deactivatedAt: Date.now,
                            initialReservoirLevel: pumpManager.state.initialReservoir,
                            reservoirLevel: pumpManager.state.reservoir
                        )

                        pumpManager.state.patchId = Data()
                        pumpManager.state.sessionToken = Data()
                        pumpManager.state.pumpState = .none
                        pumpManager.notifyStateDidChange()
                    }

                    self.nextStep()
                }
            }
        #else
            guard let pumpManager = self.pumpManager else {
                nextStep()
                return
            }

            isDeactivating = true
            deactivationError = ""

            AuthorizeBiometrics.authenticate { success in
                guard success else {
                    DispatchQueue.main.async {
                        self.deactivationError = LocalizedString("Authentication failure", comment: "auth failed")
                    }
                    return
                }

                pumpManager.deactivatePatch { result in
                    DispatchQueue.main.async {
                        self.isDeactivating = false

                        if case let .failure(error) = result {
                            self.deactivationError = error.localizedDescription
                            return
                        }

                        self.nextStep()
                    }
                }
            }
        #endif
    }
}

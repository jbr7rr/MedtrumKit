//
//  PatchActivationViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 05/04/2025.
//

class PatchActivationViewModel : ObservableObject {
    
    @Published var isActivating: Bool = false
    @Published var activationError: String = ""
    
    private let pumpManager: MedtrumPumpManager?
    private let nextStep: () -> Void
    init(_ pumpManager: MedtrumPumpManager?, _ nextStep: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep
    }
    
    func activate() {
#if targetEnvironment(simulator)
        if let pumpManager = pumpManager {
            // Add some mock data
            pumpManager.state.patchId = Data([1,2,3,4])
            pumpManager.state.reservoir = 200
            pumpManager.state.battery = 2.5
            pumpManager.state.patchActivatedAt = Date.now
            pumpManager.state.patchExpiresAt = Date.now.addingTimeInterval(.days(3))
            pumpManager.state.lastSync = Date.now
            pumpManager.notifyStateDidChange()
        }
        
        nextStep()
#else
        guard let pumpManager = self.pumpManager else {
            nextStep()
            return
        }
        
        isActivating = true
        activationError = ""
        pumpManager.activatePatch { result in
            DispatchQueue.main.async {
                self.isActivating = false
                
                if case .failure(let error) = result {
                    self.activationError = error.localizedDescription
                    return
                }
                
                self.nextStep()
            }
        }
#endif
    }
}

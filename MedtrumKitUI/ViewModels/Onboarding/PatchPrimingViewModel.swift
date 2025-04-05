//
//  PatchPrimingViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 05/04/2025.
//

class PatchPrimingViewModel: ObservableObject {
    
    @Published var isPriming = false
    @Published var primingError = ""
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
    
    func startPrime() {
#if targetEnvironment(simulator)
        pumpManager?.state.sessionToken = Crypto.genSessionToken()
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
            DispatchQueue.main.async {
                self.isPriming = false
                
                if case .failure(let error) = result {
                    self.primingError = error.localizedDescription
                    return
                }
                
                self.nextStep()
            }
        }
#endif
    }
}

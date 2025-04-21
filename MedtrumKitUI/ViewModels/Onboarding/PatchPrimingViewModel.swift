//
//  PatchPrimingViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 05/04/2025.
//

import LoopKit

class PatchPrimingViewModel: ObservableObject {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.primingView")
    
    @Published var isPriming = false
    @Published var primeProgress: Double = 0
    @Published var primingError = ""
    @Published var is300u = false
    
    private let nextStep: () -> Void
    private let done: () -> Void
    private let pumpManager: MedtrumPumpManager?
    init(_ pumpManager: MedtrumPumpManager?, _ nextStep: @escaping () -> Void, _ done: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep
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
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    self.primingError = error.localizedDescription
                    self.isPriming = false
                }
                return
            }
            
            // Command send succesfully, now we have to wait till primeProgress has reached value 150
        }
#endif
    }
}

extension PatchPrimingViewModel : PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didUpdate status: LoopKit.PumpManagerStatus, oldStatus: LoopKit.PumpManagerStatus) {
        
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            return
        }
        
        DispatchQueue.main.async {
            self.primeProgress = Double(pumpManager.state.primeProgress) / 240
        
            // 39B36926
            if pumpManager.state.pumpState.rawValue > PatchState.priming.rawValue, pumpManager.state.pumpState.rawValue < PatchState.active.rawValue {
                self.nextStep()
            } else if pumpManager.state.pumpState.rawValue >= PatchState.active.rawValue {
                // Patch already activated, ready to jump to settings
                self.done()
            }
        }
    }
}

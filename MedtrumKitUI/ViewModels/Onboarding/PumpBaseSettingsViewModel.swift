//
//  PumpBaseSettingsViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 05/04/2025.
//

class PumpBaseSettingsViewModel: ObservableObject {
    @Published var is300u = false
    @Published var serialNumber: String = ""
    @Published var errorMessage: String = ""
    
    private let pumpManager: MedtrumPumpManager?
    private let nextStep: () -> Void
    init(_ pumpManager: MedtrumPumpManager?, _ nextStep: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep
        
        guard let pumpManager = pumpManager else {
            return
        }
        
        self.serialNumber = pumpManager.state.pumpSN.hexEncodedString().uppercased()
        self.is300u = pumpManager.state.pumpName.contains("300U")
    }
    
    func saveAndConnect() {
        guard serialNumber.count == 8 else {
            errorMessage = "Serial Number is too short"
            return
        }
        
        guard let snData = Data(hex: serialNumber), snData.count == 4 else {
            errorMessage = "Serial Number is invalid hex format"
            return
        }

#if targetEnvironment(simulator)
        nextStep()
#else
        
        guard let pumpManager = pumpManager else {
            errorMessage = "Failed to connect to pump"
            return
        }
        
        errorMessage = ""
        
        pumpManager.state.isOnboarded = true
        pumpManager.state.pumpSN = snData
        pumpManager.notifyStateDidChange()
        nextStep()
#endif
    }
}

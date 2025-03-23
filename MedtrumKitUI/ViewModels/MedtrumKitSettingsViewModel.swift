//
//  MedtrumKitSettingsViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 23/03/2025.
//

import LoopKit
import HealthKit

class MedtrumKitSettingsViewModel: ObservableObject {
    @Published var imageName: String = ""
    @Published var reservoirLevel: Double = 0
    
    let reservoirVolumeFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit())
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter
    }()
    
    private let pumpManager: MedtrumPumpManager?
    init(pumpManager: MedtrumPumpManager?) {
        self.pumpManager = pumpManager
        
        guard let pumpManager = pumpManager else {
            return
        }
        
        updateState(pumpManager.state)
    }
    
    func reservoirText(for units: Double) -> String {
        let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: units)
        return reservoirVolumeFormatter.string(from: quantity, for: .internationalUnit()) ?? ""
    }
    
    private func updateState(_ state: MedtrumPumpState) {
        switch state.model {
        case "MD8301":
            self.imageName = "nano300"
            break
        default:
            self.imageName = "nano200"
            break
        }
        
        self.reservoirLevel = state.reservoir
    }
    
}

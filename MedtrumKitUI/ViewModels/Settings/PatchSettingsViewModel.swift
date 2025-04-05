//
//  PatchSettingsViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 01/04/2025.
//

import LoopKit

class PatchSettingsViewModel: ObservableObject {
    @Published var maxHourlyInsulin: Double = 0
    @Published var maxDailyInsulin: Double = 0
    @Published var alarmSettings: Double = Double(AlarmSettings.None.rawValue)
    @Published var expirationTimer: Double = 1
    
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.patchSettingsViewModel")
    private let pumpManager: MedtrumPumpManager?
    init(_ pumpManager: MedtrumPumpManager?) {
        self.pumpManager = pumpManager
        
        guard let pumpManager = pumpManager else {
            return
        }
        
        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }
    
    var alarmOptions: [Double] {
        // Hide all options with light
        // This feature is discontinued
        return Array(4...7).map({ Double($0 ) })
    }
    
    func save() {
        guard let pumpManager = pumpManager else {
            return
        }
        
        pumpManager.state.maxHourlyInsulin = maxHourlyInsulin
        pumpManager.state.maxDailyInsulin = maxDailyInsulin
        pumpManager.state.alarmSetting = AlarmSettings(rawValue: UInt8(alarmSettings)) ?? .None
        pumpManager.state.expirationTimer = UInt8(expirationTimer)
        pumpManager.notifyStateDidChange()
    }
}

extension PatchSettingsViewModel: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didUpdate status: LoopKit.PumpManagerStatus, oldStatus: LoopKit.PumpManagerStatus) {
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            return
        }
        
        updateState(pumpManager.state)
    }
    
    func updateState(_ state: MedtrumPumpState) {
        self.maxHourlyInsulin = state.maxHourlyInsulin
        self.maxDailyInsulin = state.maxDailyInsulin
        self.alarmSettings = Double(state.alarmSetting.rawValue)
        self.expirationTimer = Double(state.expirationTimer)
    }
}

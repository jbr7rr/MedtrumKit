//
//  PatchSettingsViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 01/04/2025.
//

import LoopKit

class PatchSettingsViewModel: ObservableObject {
    @Published var maxHourlyInsulin: Double = 0 {
        didSet { checkDirtyState() }
    }
    @Published var maxDailyInsulin: Double = 0 {
        didSet { checkDirtyState() }
    }
    @Published var alarmSettings: Double = Double(AlarmSettings.None.rawValue) {
        didSet { checkDirtyState() }
    }
    @Published var expirationTimer: Double = 1 {
        didSet { checkDirtyState() }
    }
    @Published var isDirty: Bool = false
    
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
    
    func checkDirtyState() {
        guard let pumpManager = pumpManager else {
            return
        }
        
        DispatchQueue.main.async {
            self.isDirty = (
                pumpManager.state.maxDailyInsulin != self.maxDailyInsulin ||
                pumpManager.state.maxHourlyInsulin != self.maxHourlyInsulin ||
                pumpManager.state.alarmSetting.rawValue != UInt8(self.alarmSettings) ||
                pumpManager.state.expirationTimer != UInt8(self.expirationTimer))
        }
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
        DispatchQueue.main.async {
            self.maxHourlyInsulin = state.maxHourlyInsulin
            self.maxDailyInsulin = state.maxDailyInsulin
            self.alarmSettings = Double(state.alarmSetting.rawValue)
            self.expirationTimer = Double(state.expirationTimer)
        }
    }
}

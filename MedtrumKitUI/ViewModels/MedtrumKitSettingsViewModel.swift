//
//  MedtrumKitSettingsViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 23/03/2025.
//

import LoopKit
import HealthKit
import SwiftUI

enum PatchLifecycleState {
    case noPatch
    case active
    case expired
}

class MedtrumKitSettingsViewModel: ObservableObject, PumpManagerStatusObserver {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.settingsViewModel")
    
    @Published var model: String = ""
    @Published var imageName: String = ""
    @Published var reservoirLevel: Double = 0
    @Published var maxReservoirLevel: Double = 1
    @Published var basalType: BasalState = .active
    @Published var insulinType: InsulinType = .novolog
    @Published var lastSync: Date = Date.distantPast
    @Published var patchLifecycleProgress: Double = 0
    @Published var patchState: PatchLifecycleState = .noPatch
    @Published var patchActivatedAt: Date = Date.distantPast
    @Published var patchExpiresAt: Date = Date.distantFuture
    @Published var isUpdatingPumpState = false
    @Published var showingDeleteConfirmation = false
    
    let reservoirVolumeFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit())
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter
    }()
    
    let basalRateFormatter: NumberFormatter = {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumFractionDigits = 1
        numberFormatter.minimumIntegerDigits = 1
        return numberFormatter
    }()
    
    let dateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()
    
    let dateTimeFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
    
    private let log = MedtrumLogger(category: "settingsViewModel")
    private let pumpManager: MedtrumPumpManager?
    init(pumpManager: MedtrumPumpManager?) {
        self.pumpManager = pumpManager
        
        guard let pumpManager = pumpManager else {
            return
        }
        
        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }
    
    func reservoirText(for units: Double) -> String {
        let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: units)
        return reservoirVolumeFormatter.string(from: quantity, for: .internationalUnit()) ?? ""
    }
    
    var basalRate: Double {
        if let tempBasal = pumpManager?.state.tempBasalUnits {
            return tempBasal
        }
        
        return pumpManager?.currentBaseBasalRate ?? 0
    }
    
    var patchLifecycleDays: Int? {
        guard self.patchState == .active else {
            return nil
        }
        
        return Int((Date.now.timeIntervalSince1970 - self.patchActivatedAt.timeIntervalSince1970).days)
    }
    
    var patchLifecycleHours: Int? {
        guard self.patchState == .active else {
            return nil
        }
        
        return Int((Date.now.timeIntervalSince1970 - self.patchActivatedAt.timeIntervalSince1970).hours.truncatingRemainder(dividingBy: 24))
    }
    
    var patchLifecycleMinutes: Int? {
        guard self.patchState == .active else {
            return nil
        }
        
        return Int((Date.now.timeIntervalSince1970 - self.patchActivatedAt.timeIntervalSince1970).minutes.truncatingRemainder(dividingBy: 60))
    }
    
    func syncData() {
        guard let pumpManager = self.pumpManager else {
            return
        }
        
        self.isUpdatingPumpState = true
        pumpManager.syncPumpData { _ in
            DispatchQueue.main.async {
                self.isUpdatingPumpState = false
            }
        }
    }
    
    func didChangeInsulinType(_ newType: InsulinType?) {
        guard let type = newType else {
            return
        }
        
        self.pumpManager?.state.insulinType = type
        self.pumpManager?.notifyStateDidChange()
        self.insulinType = type
    }
    
    func stopUsingMedtrum() {
        self.pumpManager?.notifyDelegateOfDeactivation {
//            DispatchQueue.main.async {
//                self.didFinish?()
//            }
        }
    }
    
    func getLogs() -> [URL] {
        if let pumpManager = self.pumpManager {
            log.info(pumpManager.state.debugDescription)
        }
        return log.getDebugLogs()
    }
    
}

extension MedtrumKitSettingsViewModel {
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didUpdate status: LoopKit.PumpManagerStatus, oldStatus: LoopKit.PumpManagerStatus) {
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            return
        }
        
        DispatchQueue.main.async {
            self.updateState(pumpManager.state)
        }
    }
    
    private func updateState(_ state: MedtrumPumpState) {
        switch state.model {
        case "MD8301":
            self.imageName = "nano300"
            self.maxReservoirLevel = 300
            break
        default:
            self.imageName = "nano200"
            self.maxReservoirLevel = 200
            break
        }
        
        self.model = state.pumpName
        self.reservoirLevel = state.reservoir
        self.basalType = state.basalState
        self.lastSync = state.lastSync
        self.patchActivatedAt = state.patchActivatedAt
        
        if !state.patchId.isEmpty {
            self.patchLifecycleProgress = min((Date.now.timeIntervalSince1970 - state.patchActivatedAt.timeIntervalSince1970) / TimeInterval(days: 3), 1)
            self.patchState = self.patchLifecycleProgress == 1 ? .expired : .active
            self.patchExpiresAt = self.patchActivatedAt.addingTimeInterval(TimeInterval(days: 3))
        } else {
            self.patchState = .noPatch
        }
        
        if let insulinType = state.insulinType {
            self.insulinType = insulinType
        }
    }
}

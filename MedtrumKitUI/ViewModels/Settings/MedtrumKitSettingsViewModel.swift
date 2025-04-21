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
    
    @Published var pumpBaseSN: String = ""
    @Published var pumpName: String = ""
    @Published var model: String = ""
    @Published var patchId: UInt64 = 0
    @Published var is300u: Bool = false
    @Published var usingContinuousMode = false
    @Published var reservoirLevel: Double = 0
    @Published var battery: Double = 0
    @Published var maxReservoirLevel: Double = 1
    @Published var patchState: PatchState = .none
    @Published var patchStateString: String = PatchState.none.description
    @Published var basalType: BasalState = .active
    @Published var insulinType: InsulinType = .novolog
    @Published var lastSync: Date = Date.distantPast
    @Published var patchLifecycleProgress: Double = 0
    @Published var patchLifecycleState: PatchLifecycleState = .noPatch
    @Published var patchActivatedAt: Date = Date.distantPast
    @Published var patchExpiresAt: Date = Date.distantFuture
    @Published var isConnected: Bool = false
    @Published var isReconnecting: Bool = false
    @Published var isUpdatingPumpState = false
    @Published var showingDeleteConfirmation = false
    
    public let patchSettingsViewModel: PatchSettingsViewModel
    
    let reservoirVolumeFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit())
        formatter.numberFormatter.minimumFractionDigits = 0
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()
    
    let batteryFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit())
        formatter.numberFormatter.minimumFractionDigits = 2
        formatter.numberFormatter.maximumFractionDigits = 2
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
    
    let deactivatePatchAction: () -> Void
    let pumpRemovalAction: () -> Void
    let pumpActivationAction: (Bool) -> Void
    private let log = MedtrumLogger(category: "settingsViewModel")
    private let pumpManager: MedtrumPumpManager?
    init(_ pumpManager: MedtrumPumpManager?, _ deactivatePatchAction: @escaping () -> Void, _ pumpActivationAction: @escaping (Bool) -> Void, _ pumpRemovalAction: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.patchSettingsViewModel = PatchSettingsViewModel(pumpManager, updatePatch: true, nextStep: nil)
        self.deactivatePatchAction = deactivatePatchAction
        self.pumpActivationAction = pumpActivationAction
        self.pumpRemovalAction = pumpRemovalAction
        
        guard let pumpManager = pumpManager else {
            return
        }
        
        self.isConnected = pumpManager.bluetooth.isConnected
        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }
    
    deinit {
        pumpManager?.removeStatusObserver(self)
    }
    
    func reservoirText(for units: Double) -> String {
        let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: units)
        return reservoirVolumeFormatter.string(from: quantity, for: .internationalUnit()) ?? ""
    }
    
    func batteryText(for voltage: Double) -> String {
        let quantity = HKQuantity(unit: .volt(), doubleValue: voltage)
        return batteryFormatter.string(from: quantity, for: .volt()) ?? ""
    }
    
    var basalRate: Double {
        if let tempBasal = pumpManager?.state.tempBasalUnits {
            return tempBasal
        }
        
        return pumpManager?.currentBaseBasalRate ?? 0
    }
    
    var patchLifecycleDays: Int? {
        guard self.patchLifecycleState == .active else {
            return nil
        }
        
        return Int((Date.now.timeIntervalSince1970 - self.patchActivatedAt.timeIntervalSince1970).days.rounded(.toNearestOrEven))
    }
    
    var patchLifecycleHours: Int? {
        guard self.patchLifecycleState == .active else {
            return nil
        }
        
        return Int((Date.now.timeIntervalSince1970 - self.patchActivatedAt.timeIntervalSince1970).hours.truncatingRemainder(dividingBy: 24).rounded(.toNearestOrEven))
    }
    
    var patchLifecycleMinutes: Int? {
        guard self.patchLifecycleState == .active else {
            return nil
        }
        
        return Int((Date.now.timeIntervalSince1970 - self.patchActivatedAt.timeIntervalSince1970).minutes.truncatingRemainder(dividingBy: 60).rounded(.toNearestOrEven))
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
        guard let pumpManager = self.pumpManager else {
            self.pumpRemovalAction()
            return
        }
        
        pumpManager.notifyDelegateOfDeactivation {
            DispatchQueue.main.async {
                self.pumpRemovalAction()
            }
        }
    }
    
    func getLogs() -> [URL] {
        if let pumpManager = self.pumpManager {
            log.info(pumpManager.state.debugDescription)
        }
        return log.getDebugLogs()
    }
    
    func toPumpActivation() {
        guard let pumpManager = self.pumpManager else {
            self.pumpActivationAction(false)
            return
        }
        
        let alreadyPrimed = pumpManager.state.pumpState.rawValue >= PatchState.primed.rawValue
        self.pumpActivationAction(alreadyPrimed)
    }
    
    func toggleConnection() {
        // TODO: 
    }
}

extension MedtrumKitSettingsViewModel {
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didUpdate status: LoopKit.PumpManagerStatus, oldStatus: LoopKit.PumpManagerStatus) {
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            return
        }
        
        DispatchQueue.main.async {
            self.isConnected = pumpManager.bluetooth.isConnected
            self.updateState(pumpManager.state)
        }
    }
    
    private func updateState(_ state: MedtrumPumpState) {
        self.model = state.model
        switch self.model {
        case "MD8301":
            self.is300u = true
            self.maxReservoirLevel = 300
            break
        default:
            self.is300u = false
            self.maxReservoirLevel = 200
            break
        }
        
        self.pumpBaseSN = state.pumpSN.hexEncodedString().uppercased()
        self.pumpName = state.pumpName
        self.patchId = state.patchId.toUInt64()
        self.usingContinuousMode = state.usingContinuousMode
        self.patchState = state.pumpState
        self.patchStateString = state.pumpState.description
        self.reservoirLevel = state.reservoir
        self.basalType = state.basalState
        self.lastSync = state.lastSync
        self.patchActivatedAt = state.patchActivatedAt
        self.battery = state.battery
        
        if !state.patchId.isEmpty {
            self.patchLifecycleProgress = min((Date.now.timeIntervalSince1970 - state.patchActivatedAt.timeIntervalSince1970) / TimeInterval(days: 3), 1)
            self.patchLifecycleState = self.patchLifecycleProgress == 1 ? .expired : .active
            self.patchExpiresAt = self.patchActivatedAt.addingTimeInterval(TimeInterval(days: 3))
        } else {
            self.patchLifecycleState = .noPatch
        }
        
        if let insulinType = state.insulinType {
            self.insulinType = insulinType
        }
    }
}

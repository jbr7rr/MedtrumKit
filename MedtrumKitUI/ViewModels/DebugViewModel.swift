//
//  DebugViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 13/03/2025.
//

import CoreBluetooth
import LoopKit

class DebugViewModel: ObservableObject {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.debugviewmodel")
    
    @Published var pumpBaseSN = ""
    @Published var hasPumpBaseSN: Bool
    @Published var isPresentingPumpBaseSN = false
    
    private let log = MedtrumLogger(category: "DebugView")
    private var pumpManager: MedtrumPumpManager?
    
    var foundPeripheral: CBPeripheral?

    init(_ pumpManager: MedtrumPumpManager? = nil) {
        self.pumpManager = pumpManager
        
        guard let pumpManager = self.pumpManager else {
            self.hasPumpBaseSN = false
            return
        }
        
        self.hasPumpBaseSN = pumpManager.state.pumpSN.count == 4
        self.pumpBaseSN = pumpManager.state.pumpSN.hexEncodedString()
        
        pumpManager.addStatusObserver(self, queue: processQueue)
    }
    
    func setPumpBase() {
        self.isPresentingPumpBaseSN = true
    }
    
    func setPumpBaseAction() {
        guard let pumpManager = self.pumpManager else {
            self.log.error("No pump manager available")
            return
        }
        
        guard self.pumpBaseSN.count == 8, let sn = Data(hex: self.pumpBaseSN) else {
            self.log.error("Invalid pump base SN")
            return
        }
        
        pumpManager.state.pumpSN = sn
        pumpManager.notifyStateDidChange()
    }
    
    func prime() {
        guard let pumpManager = self.pumpManager else {
            self.log.error("No pump manager available")
            return
        }
        
        pumpManager.primePatch { result in
            if case .failure = result {
                return
            }
            
            
        }
    }
    
    func activate() {
        guard let pumpManager = self.pumpManager else {
            self.log.error("No pump manager available")
            return
        }
        
        pumpManager.activatePatch { result in
            
        }
    }
    
    func connect() {
        guard let pumpManager = self.pumpManager else {
            self.log.error("No pump manager available")
            return
        }
        
        pumpManager.bluetooth.ensureConnected { result in
            switch result {
            case .failure(let error):
                self.log.error(error.localizedDescription)
                return
            case .success:
                self.log.info("Connected")
                // TODO: Continue journey here
            }
        }
    }
    
    func getLogs() -> [URL] {
        log.getDebugLogs()
    }
}

extension DebugViewModel : PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didUpdate status: LoopKit.PumpManagerStatus, oldStatus: LoopKit.PumpManagerStatus) {
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            self.log.error("Couldnt cast pumpManager")
            return
        }
        
        DispatchQueue.main.async {
            self.hasPumpBaseSN = pumpManager.state.pumpSN.count == 4
        }
    }
}

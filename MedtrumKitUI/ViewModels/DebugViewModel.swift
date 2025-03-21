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
        
        //sessionToken: 2466528379
        print(pumpManager.state.sessionToken.hexEncodedString())
        print(Crypto.genKey(Data(pumpManager.state.pumpSN.reversed())).toInt64())
        
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
        
        // 4A12d828
        
        pumpManager.state.pumpSN = sn
        pumpManager.notifyStateDidChange()
    }
    
    func prime() {
        guard let pumpManager = self.pumpManager else {
            self.log.error("No pump manager available")
            return
        }
        
        pumpManager.primePatchPump { result in
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
        
        pumpManager.activatePatchPump { result in
            
        }
    }
    
    func connect() {
        guard let pumpManager = self.pumpManager else {
            self.log.error("No pump manager available")
            return
        }
        
        guard let peripheral = self.foundPeripheral else {
            self.log.error("No peripheral found to connect to")
            return
        }
        
        pumpManager.connect(peripheral: peripheral) { result in
            switch result {
            case .failure(let error):
                self.log.error(error.errorDescription ?? "")
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

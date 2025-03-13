//
//  DebugViewModel.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 13/03/2025.
//

import CoreBluetooth

class DebugViewModel: ObservableObject {
    
    @Published var messageScanAlert = ""
    @Published var isPresentingScanAlert = false
    
    private let log = MedtrumLogger(category: "DebugView")
    private var pumpManager: MedtrumPumpManager?
    
    var foundPeripheral: CBPeripheral?

    init(_ pumpManager: MedtrumPumpManager? = nil) {
        self.pumpManager = pumpManager
    }
    
    func scan() {
        guard let pumpManager = self.pumpManager else {
            self.log.error("No pump manager available")
            return
        }
        
        pumpManager.startScan { result in
            switch result {
            case .failure(let error):
                self.log.error(error.toString())
                return
            case .success(let peripheral, let pumpSN, let deviceType, let version):
                self.foundPeripheral = peripheral
                self.log.info("Found pump \(pumpSN) (\(deviceType)), version \(version)")
                self.messageScanAlert = "Do you want to connect to: \(pumpSN) (\(peripheral.identifier.uuidString))"
                self.isPresentingScanAlert = true
            }
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
                self.log.error(error.toString())
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

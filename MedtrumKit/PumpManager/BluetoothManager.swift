//
//  BluetoothManager.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

import CoreBluetooth

class BluetoothManager: NSObject, CBCentralManagerDelegate {
    public var pumpManager: MedtrumPumpManager?
    
    let log = MedtrumLogger(category: "BluetoothManager")
    
    var manager: CBCentralManager!
    let managerQueue = DispatchQueue(label: "com.nightscout.MedtrumKit.bluetoothManagerQueue", qos: .unspecified)
    
    private var peripheral: CBPeripheral?
    private var peripheralManager: PeripheralManager?
    
    var scanCompletion: ((MedtrumScanResult) -> Void)?
    var connectCompletion: ((MedtrumConnectResult) -> Void)?
    
    override init() {
        super.init()
        
        managerQueue.sync {
            self.manager = CBCentralManager(delegate: self, queue: managerQueue)
        }
    }
    
    func startScan(_ completion: @escaping (_ result: MedtrumScanResult) -> Void) {
        guard manager.state == .poweredOn else {
            completion(.failure(error: .invalidBluetoothState(state: manager.state)))
            return
        }

        guard !manager.isScanning else {
            completion(.failure(error: .alreadyScanning))
            return
        }

        scanCompletion = completion
        manager.scanForPeripherals(withServices: [])
        
        log.info("Started scanning")
    }
    
    func connect(peripheral: CBPeripheral, _ completion: @escaping (MedtrumConnectResult) -> Void) {
        if manager.isScanning {
            manager.stopScan()
            scanCompletion = nil
        }
        
        log.info("Connecting to \(peripheral)")
        
        connectCompletion = completion
        manager.connect(peripheral)
    }
    
    func ensureConnected(_ completionAsync: @escaping (MedtrumConnectResult) async -> Void) {
        let completion = { (_ result: MedtrumConnectResult) -> Void in
            Task {
                await completionAsync(result)
            }
        }
        
        if let peripheral = peripheral, peripheral.state == .connected {
            // We are connected and ready to continue
            completion(.success)
            return
        }
        
        if let peripheral = peripheral {
            // We've the peripheral reference to a previous connection
            // Just try to reconnect
            self.connect(peripheral: peripheral, completion)
            return
        }
        
        guard let pumpSNState = self.pumpManager?.state.pumpSN else {
            self.log.error("No pump serial number found")
            completion(.failure(error: .failedToFindDevice))
            return
        }
        
        // We are disconnected and have no reference to the previous connection
        // Start to scan for patch and reconnect the long way
        self.startScan { result in
            switch result {
            case .failure(let error):
                self.log.error("Error during scanning: \(error.errorDescription ?? "")")
                self.manager.stopScan()
                completion(.failure(error: .failedToFindDevice))
                break
                
            case .success(let peripheral, let pumpSN, let deviceType, let version):
                guard pumpSN == pumpSNState else {
                    // Other patch pump found. IGNORE
                    return
                }
                
                self.connect(peripheral: peripheral, completion)
                break
            }
        }
    }
    
    func write(_ packet: any MedtrumBasePacketProtocol) async -> MedtrumWriteResult<Any> {
        guard let peripheralManager else {
            return .failure(error: .noManager)
        }
        
        return await peripheralManager.writePacket(packet)
    }
}

extension BluetoothManager {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("\(String(describing: central.state.rawValue))")
    }

    func centralManager(_: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi _: NSNumber) {
        guard let deviceName = peripheral.name, !deviceName.isEmpty else {
            return
        }
        
        // TODO: Need to validate if the device name is always MT
        log.info("Found device: \(deviceName), \(advertisementData)!")
        guard deviceName == "MT" else {
            return
        }
        
        // TODO: Validate processing advertismentData for Serial Number
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey]
        guard let manufacturerData = manufacturerData as? Data, manufacturerData.count >= 5 else {
            log.warning("No ManufacturerData or too short - " + advertisementData.keys.joined(separator: ", "))
            return
        }
        
        scanCompletion?(.success(peripheral: peripheral, pumpSN: manufacturerData[0...4], deviceType: manufacturerData[4], version: manufacturerData[5]))
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("Connected to pump: \(peripheral.name ?? "<NO_NAME>")!")
        
        guard let completion = connectCompletion, let pumpManager = pumpManager else {
            return
        }
        
        self.peripheral = peripheral
        peripheralManager = PeripheralManager(peripheral, self, pumpManager, completion)
        peripheral.discoverServices([PeripheralManager.SERVICE_UUID])
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.info("Device disconnected, name: \(peripheral.name ?? "<NO_NAME>")")
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.info("Device connect error, name: \(peripheral.name ?? "<NO_NAME>"), error: \(error!.localizedDescription)")
    }
}

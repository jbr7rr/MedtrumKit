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
    
    private var peripheralManager: PeripheralManager?
    
    var scanCompletion: ((ScanResult) -> Void)?
    var connectCompletion: ((ConnectResult) -> Void)?
    
    override init() {
        super.init()
        
        managerQueue.sync {
            self.manager = CBCentralManager(delegate: self, queue: managerQueue)
        }
    }
    
    func startScan(_ completion: @escaping (_ result: ScanResult) -> Void) {
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
    
    func connect(peripheral: CBPeripheral, _ completion: @escaping (ConnectResult) -> Void) {
        if manager.isScanning {
            manager.stopScan()
            scanCompletion = nil
        }
        
        log.info("Connecting to \(peripheral)")
        
        connectCompletion = completion
        manager.connect(peripheral)
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

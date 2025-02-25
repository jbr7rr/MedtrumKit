//
//  PeripheralManager.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

import CoreBluetooth

class PeripheralManager : NSObject {
    private let log = MedtrumLogger(category: "PeripheralManager")
    
    private let connectedDevice: CBPeripheral
    private let bluetoothManager: BluetoothManager
    private let pumpManager: MedtrumPumpManager
    private var completion: ((ConnectResult) -> Void)?
    
    public static let SERVICE_UUID = CBUUID(string: "669A9001-0008-968F-E311-6050405558B3")
    private static let READ_UUID = CBUUID(string: "669a9120-0008-968f-e311-6050405558b3")
    private var readCharacteristic: CBCharacteristic!
    private static let WRITE_UUID = CBUUID(string: "669a9101-0008-968f-e311-6050405558b3")
    private var writeCharacteristic: CBCharacteristic!
    private static let CONFIG_UUID = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")
    private var configCharacteristic: CBCharacteristic!
    
    public init(_ peripheral: CBPeripheral, _ bluetoothManager: BluetoothManager, _ pumpManager: MedtrumPumpManager,_ completion: @escaping (ConnectResult) -> Void) {
        self.connectedDevice = peripheral
        self.bluetoothManager = bluetoothManager
        self.pumpManager = pumpManager
        self.completion = completion
        
        super.init()
        
        peripheral.delegate = self
    }
}

extension PeripheralManager : CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            log.error("\(error!.localizedDescription)")
            completion?(.failure(error: .failedToDiscoverServices(localizedError: error?.localizedDescription ?? "")))
            return
        }
        
        let service = peripheral.services?.first(where: { $0.uuid == PeripheralManager.SERVICE_UUID })
        guard let service = service else {
            let localizedError = "No Metrum service found - " + (peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "No services discovered")
            log.error(localizedError)
            completion?(.failure(error: .failedToDiscoverServices(localizedError: localizedError)))
            return
        }
        
        peripheral.discoverCharacteristics([PeripheralManager.READ_UUID, PeripheralManager.WRITE_UUID, PeripheralManager.CONFIG_UUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            log.error("\(error!.localizedDescription)")
            completion?(.failure(error: .failedToDiscoverCharacteristics(localizedError: error?.localizedDescription ?? "")))
            return
        }
        
        let service = peripheral.services!.first(where: { $0.uuid == PeripheralManager.SERVICE_UUID })!
        self.readCharacteristic = service.characteristics?.first(where: { $0.uuid == PeripheralManager.READ_UUID })
        self.writeCharacteristic = service.characteristics?.first(where: { $0.uuid == PeripheralManager.WRITE_UUID })
        self.configCharacteristic = service.characteristics?.first(where: { $0.uuid == PeripheralManager.CONFIG_UUID })
        
        guard (self.readCharacteristic != nil), (self.writeCharacteristic != nil), (self.configCharacteristic != nil) else {
            let localizedError = "Failed to discover read, write or config characteristic - " + (service.characteristics?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "No characteristics discovered")
            
            log.error(localizedError)
            completion?(.failure(error: .failedToDiscoverCharacteristics(localizedError: localizedError)))
            return
        }
        
        // Subscribe on all characteristics with notifying abilities
        service.characteristics?.forEach { characteristic in
            guard characteristic.properties.contains(.notify) else {
                return
            }
            
            peripheral.setNotifyValue(true, for: characteristic)
        }
        
        log.info("Notify enabled and ready to start auth flow!")
        // TODO: Send AuthPacket
        
    }
}

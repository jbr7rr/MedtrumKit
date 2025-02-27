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
    private var completion: ((MedtrumConnectResult) -> Void)?
    
    public static let SERVICE_UUID = CBUUID(string: "669A9001-0008-968F-E311-6050405558B3")
    private static let READ_UUID = CBUUID(string: "669a9120-0008-968f-e311-6050405558b3")
    private var readCharacteristic: CBCharacteristic!
    private static let WRITE_UUID = CBUUID(string: "669a9101-0008-968f-e311-6050405558b3")
    private var writeCharacteristic: CBCharacteristic!
    private static let CONFIG_UUID = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")
    private var configCharacteristic: CBCharacteristic!
    
    private var writeSequence: UInt8 = 0
    private var readPacket: ReadPacket?
    
    private var writeQueue: Dictionary<UInt8, CheckedContinuation<MedtrumWriteResult, any Error>> = [:]
    private var writeTimeoutTask: Task<(), Never>?
    private let writeSemaphore = DispatchSemaphore(value: 1)
    
    public init(_ peripheral: CBPeripheral, _ bluetoothManager: BluetoothManager, _ pumpManager: MedtrumPumpManager,_ completion: @escaping (MedtrumConnectResult) -> Void) {
        self.connectedDevice = peripheral
        self.bluetoothManager = bluetoothManager
        self.pumpManager = pumpManager
        self.completion = completion
        
        super.init()
        
        peripheral.delegate = self
    }
    
    func writePacket(_ packet: any MedtrumBasePacket) async throws -> MedtrumWriteResult {
        return try await withCheckedThrowingContinuation { continuation in
            // Wait for the other write to complete...
            self.writeSemaphore.wait()
            
            writeQueue[packet.commandType] = continuation
            
            let packages = WritePacket.encode(packet, sequenceNumber: self.writeSequence)
            self.writeSequence = UInt8(self.writeSequence + 1)
            
            for package in packages {
                self.connectedDevice.writeValue(package, for: self.writeCharacteristic, type: .withResponse)
            }
            
            self.writeTimeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(.seconds(5)) * 1_000_000_000)
                    guard let queueItem = self.writeQueue[packet.commandType] else {
                        // We did what we must!
                        return
                    }
                    
                    // We hit a timeout...
                    self.bluetoothManager.manager.cancelPeripheralConnection(self.connectedDevice)
                    queueItem.resume(returning: .failure(error: .timeout))
                    
                    self.writeQueue[packet.commandType] = nil
                    self.writeTimeoutTask = nil
                    self.writeSemaphore.signal()
                } catch {
                    // Task was cancelled because message has been received
                }
            }
        }
        
    }
}

extension PeripheralManager {
    
    // Connect step 1
    private func doAuthorize() async {
        do {
            let authData = try await writePacket(
                AuthorizePacket(pumpSN: self.pumpManager.state.pumpSN, sessionToken: self.pumpManager.state.sessionToken)
            )
            
            switch authData {
            case .failure(let error):
                log.error("Failed to complete authorization flow: \(error.toString())")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.toString())))
                break
                
            case .success(let data):
                let authResponse = AuthorizePacket.parseResponse(data: data)
                pumpManager.state.deviceType = authResponse.deviceType
                pumpManager.state.swVersion = authResponse.swVersion
                
                await getDeviceType()
            }
        } catch {
            let localizedError = "Failed to write authorization packet: \(error.localizedDescription)"
            log.error(localizedError)
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: localizedError)))
        }
    }
    
    // Connect step 2
    private func getDeviceType() async {
        do {
            let deviceTypeData = try await writePacket(GetDeviceTypePacket())
            
            switch deviceTypeData {
            case .failure(let error):
                log.error("Failed to get device type: \(error.toString())")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.toString())))
                break
                
            case .success(let data):
                await getTime()
            }
        } catch {
            let localizedError = "Failed to write GetDeviceType packet: \(error.localizedDescription)"
            log.error(localizedError)
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: localizedError)))
        }
    }
    
    // Connect step 3
    private func getTime() async {
        do {
            let timeData = try await writePacket(GetTimePacket())
            
            switch timeData {
            case .failure(let error):
                log.error("Failed to get time: \(error.toString())")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.toString())))
                break
                
            case .success(let data):
                let timeResponse = GetTimePacket.parseResponse(data: data)
                
                // Allow 10sec time drift
                if abs(Date.now.timeIntervalSince1970 - timeResponse.time.timeIntervalSince1970) < .seconds(10) {
                    pumpManager.state.pumpTime = timeResponse.time
                    pumpManager.state.pumpTimeSyncedAt = Date.now
                    
                    await synchronize()
                } else {
                    await setTime()
                }
            }
        } catch {
            let localizedError = "Failed to write GetTime packet: \(error.localizedDescription)"
            log.error(localizedError)
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: localizedError)))
        }
    }
    
    // Connect step 3.1 -> Fix timedrift
    private func setTime() async {
        do {
            let timeData = try await writePacket(SetTimePacket())
            
            switch timeData {
            case .failure(let error):
                log.error("Failed to set time: \(error.toString())")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.toString())))
                break
                
            case .success(let data):
                log.info("Successfully set time")
                await setTimeZone()
            }
        } catch {
            let localizedError = "Failed to write SetTime packet: \(error.localizedDescription)"
            log.error(localizedError)
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: localizedError)))
        }
    }
    
    // Connect step 3.2 -> Fix timezone
    private func setTimeZone() async {
        do {
            let timeZoneData = try await writePacket(SetTimeZonePacket())
            
            switch timeZoneData {
            case .failure(let error):
                log.error("Failed to set time: \(error.toString())")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.toString())))
                break
                
            case .success(let data):
                log.info("Successfully set time")
                
                pumpManager.state.pumpTime = Date.now
                pumpManager.state.pumpTimeSyncedAt = Date.now
                
                await synchronize()
            }
        } catch {
            let localizedError = "Failed to write SetTime packet: \(error.localizedDescription)"
            log.error(localizedError)
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: localizedError)))
        }
    }
    
    // Connect step 4
    private func synchronize() async {
        do {
            let syncData = try await writePacket(SynchronizePacket())
            
            switch syncData {
            case .failure(let error):
                log.error("Failed to synchronize: \(error.toString())")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.toString())))
                break
                
            case .success(let data):
                let syncResponse = SynchronizePacket.parseResponse(data: Data(data))
                pumpManager.state.pumpState = syncResponse.state
                
                await subscribe()
            }
        } catch {
            let localizedError = "Failed to write Synchronize packet: \(error.localizedDescription)"
            log.error(localizedError)
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: localizedError)))
        }
    }
    
    // Connect step 5 (last)
    private func subscribe() async {
        do {
            let subscribeData = try await writePacket(SubscribePacket())
            
            switch subscribeData {
            case .failure(let error):
                log.error("Failed to subscribe: \(error.toString())")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.toString())))
                break
                
            case .success(let data):
                log.info("Connected to pump!")
                completion?(.success)
            }
        } catch {
            let localizedError = "Failed to write Synchronize packet: \(error.localizedDescription)"
            log.error(localizedError)
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: localizedError)))
        }
    }
}

extension PeripheralManager : CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log.error("\(error.localizedDescription)")
            completion?(.failure(error: .failedToDiscoverServices(localizedError: error.localizedDescription)))
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
        if let error = error {
            log.error("\(error.localizedDescription)")
            completion?(.failure(error: .failedToDiscoverCharacteristics(localizedError: error.localizedDescription)))
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
        
        Task {
            self.log.info("Notify enabled and ready to start auth flow!")
            await doAuthorize()
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("\(error.localizedDescription)")
            if let connectCompletion = self.completion {
                connectCompletion(.failure(error: .failedToEnableNotify(localizedError: error.localizedDescription)))
            }
            return
        }
        
        guard let data = characteristic.value else {
            return
        }
        
        if peripheral.identifier.uuidString == PeripheralManager.READ_UUID.uuidString {
            // TODO: Handle state notification
            return
        }
        
        if peripheral.identifier.uuidString != PeripheralManager.WRITE_UUID.uuidString {
            // Ensure only write characteristic is processed futher on
            return
        }
        
        // Processing data
        if let readPacket = self.readPacket {
            readPacket.addData(data)
        } else {
            readPacket = ReadPacket(data)
        }
        
        guard let readPacket = readPacket, readPacket.isComplete else {
            // Wait for more data
            return
        }
        
        guard let writeCallback = writeQueue[readPacket.commandType] else {
            // Timeout is hit...
            self.writeSemaphore.signal()
            return
        }
        
        writeCallback.resume(returning: .success(data: readPacket.totalData))
        writeQueue[readPacket.commandType] = nil
        self.writeSemaphore.signal()
    }
}

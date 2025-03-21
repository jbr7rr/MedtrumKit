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
    
    private var writeSequence: UInt8 = 0
    private var currentPacket: (any MedtrumBasePacketProtocol)?
    private var synchronizePacket: SynchronizePacket?
    
    private var writeQueue: Dictionary<UInt8, CheckedContinuation<MedtrumWriteResult<Any>, Never>> = [:]
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
    
    func writePacket(_ packet: any MedtrumBasePacketProtocol) async -> MedtrumWriteResult<Any> {
        return await withCheckedContinuation { continuation in
            // Wait for the other write to complete...
            self.writeSemaphore.wait()
            
            writeQueue[packet.commandType] = continuation
            currentPacket = packet
            
            let packages = packet.encode(sequenceNumber: self.writeSequence)
            self.writeSequence = UInt8(self.writeSequence + 1)
            
            for package in packages {
                self.log.info("Writing data: \(package.hexEncodedString())")
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
        let authData = await writePacket(
            AuthorizePacket(pumpSN: self.pumpManager.state.pumpSN, sessionToken: self.pumpManager.state.sessionToken)
        )
        
        switch authData {
        case .failure(let error):
            log.error("Failed to complete authorization flow: \(error.errorDescription ?? "")")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.errorDescription ?? "")))
            break
            
        case .success(let data):
            guard let authResponse = data as? AuthorizeResponse else {
                log.error("Failed to complete authorization flow: invalid response")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: "invalid response")))
                return
            }
            
            pumpManager.state.deviceType = authResponse.deviceType
            pumpManager.state.swVersion = authResponse.swVersion
            
            await getTime()
        }
    }
    
    // Connect step 2
    private func getTime() async {
        let timeData = await writePacket(GetTimePacket())
        
        switch timeData {
        case .failure(let error):
            log.error("Failed to get time: \(error.errorDescription ?? "")")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.errorDescription ?? "")))
            break
            
        case .success(let data):
            guard let timeResponse = data as? GetTimePacketResponse else {
                log.error("Failed to get time: invalid response")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: "invalid response")))
                return
            }
            
            // Allow 10sec time drift
            if abs(Date.now.timeIntervalSince1970 - timeResponse.time.timeIntervalSince1970) < .seconds(10) {
                pumpManager.state.pumpTime = timeResponse.time
                pumpManager.state.pumpTimeSyncedAt = Date.now
                
                await synchronize()
            } else {
                await setTime()
            }
        }
    }
    
    // Connect step 2.1 -> Fix timedrift
    private func setTime() async {
        let timeData = await writePacket(SetTimePacket(date: Date.now))
        
        switch timeData {
        case .failure(let error):
            log.error("Failed to set time: \(error.errorDescription ?? "")")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.errorDescription ?? "")))
            break
            
        case .success:
            log.info("Successfully set time")
            await setTimeZone()
        }
    }
    
    // Connect step 2.2 -> Fix timezone
    private func setTimeZone() async {
        let timeZoneData = await writePacket(SetTimeZonePacket(date: Date.now, timeZone: TimeZone.current))
        
        switch timeZoneData {
        case .failure(let error):
            log.error("Failed to set time: \(error.errorDescription ?? "")")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.errorDescription ?? "")))
            break
            
        case .success:
            log.info("Successfully set time")
            
            pumpManager.state.pumpTime = Date.now
            pumpManager.state.pumpTimeSyncedAt = Date.now
            
            await synchronize()
        }
    }
    
    // Connect step 3
    private func synchronize() async {
        let syncData = await writePacket(SynchronizePacket())
        
        switch syncData {
        case .failure(let error):
            log.error("Failed to synchronize: \(error.errorDescription ?? "")")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.errorDescription ?? "")))
            break
            
        case .success(let data):
            guard let syncResponse = data as? SynchronizePacketResponse else {
                log.error("Failed to Synchronize packet: invalid response")
                completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: "invalid response")))
                return
            }

            self.parseStateUpdate(syncResponse)
            await subscribe()
        }
    }
    
    // Connect step 4 (last)
    private func subscribe() async {
        let subscribeData = await writePacket(SubscribePacket())
        
        switch subscribeData {
        case .failure(let error):
            log.error("Failed to subscribe: \(error.errorDescription ?? "")")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.errorDescription ?? "")))
            break
            
        case .success:
            log.info("Connected to pump!")
            completion?(.success)
        }
    }
    
    private func parseStateUpdate(_ syncResponse: SynchronizePacketResponse) {
        // TEMP
        do {
            self.log.info("State update: \(try JSONEncoder().encode(syncResponse))")
        } catch {
            self.log.warning("State update: Failed to encode JSON")
        }
        
        pumpManager.state.pumpState = syncResponse.state
        
        if let reservoir = syncResponse.reservoir {
            pumpManager.state.reservoir = reservoir
        }
        
        if let basal = syncResponse.basal {
            pumpManager.state.isTempBasalInProgress = basal.type == .ABSOLUTE_TEMP || basal.type == .RELATIVE_TEMP
        }
        
        pumpManager.notifyStateDidChange()
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
        
        peripheral.discoverCharacteristics([PeripheralManager.READ_UUID, PeripheralManager.WRITE_UUID], for: service)
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
        
        guard (self.readCharacteristic != nil), (self.writeCharacteristic != nil) else {
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
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error as? CBATTError {
            self.log.error("CBATTError: \(error.localizedDescription), code:\(error.errorCode)")
            return
        }
        self.log.info("didWriteValueFor -> error: \(error?.localizedDescription ?? "No error") \(error.debugDescription)")
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
            if self.synchronizePacket == nil {
                self.synchronizePacket = SynchronizePacket()
            }
            guard var packet = self.synchronizePacket else {
                return
            }
            
            packet.decode(data)
            
            guard packet.isComplete else {
                self.log.warning("Data no complete yet...")
                return
            }
            
            guard !packet.failed else {
                self.log.error("Failed to process update...")
                self.synchronizePacket = nil
                return
            }

            self.parseStateUpdate(packet.parseResponse())
            return
        }
        
        guard peripheral.identifier.uuidString == PeripheralManager.WRITE_UUID.uuidString else {
            // Ensure only write characteristic is processed futher on
            self.log.error("Received data on wrong characteristic - \(peripheral.identifier.uuidString) -> \(data.hexEncodedString())")
            return
        }
        
        // Processing data
        guard var packet = self.currentPacket else {
            // No packet available to validate against
            return
        }
        
        packet.decode(data)
        self.currentPacket = packet

        guard packet.isComplete else {
            // Wait for more data
            return
        }
        
        guard let writeCallback = writeQueue[packet.commandType] else {
            // Timeout is hit...
            self.currentPacket = nil
            self.writeSemaphore.signal()
            return
        }
        
        if packet.failed {
            writeCallback.resume(returning: .failure(error: .invalidResponse))
        } else {
            writeCallback.resume(returning: .success(data: packet.parseResponse()))
        }
        
        
        self.writeQueue[packet.commandType] = nil
        self.currentPacket = nil
        self.writeSemaphore.signal()
    }
}

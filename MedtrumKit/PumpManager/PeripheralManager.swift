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
    private var readCharacteristic: CBCharacteristic?
    private static let WRITE_UUID = CBUUID(string: "669a9101-0008-968f-e311-6050405558b3")
    private var writeCharacteristic: CBCharacteristic?
    
    private var writeSequence: UInt8 = 0
    private var currentPacket: (any MedtrumBasePacketProtocol)?
    
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
            
            guard let writeCharacteristic = self.writeCharacteristic else {
                log.error("No write characteristic found... Device might be disconnected...")
                continuation.resume(returning: .failure(error: .noWriteCharacteristic))
                return
            }
            
            writeQueue[packet.commandType] = continuation
            currentPacket = packet
            
            let packages = packet.encode(sequenceNumber: self.writeSequence)
            self.writeSequence = UInt8(self.writeSequence + 1)
            
            for package in packages {
                self.log.debug("Writing data: \(package.hexEncodedString())")
                self.connectedDevice.writeValue(package, for: writeCharacteristic, type: .withResponse)
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
            log.error("Failed to complete authorization flow: \(error.localizedDescription)")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription)))
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
            log.error("Failed to get time: \(error.localizedDescription)")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription)))
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
                self.log.info("Time drift detected, resetting time")
                await setTime()
            }
        }
    }
    
    // Connect step 2.1 -> Fix timedrift
    private func setTime() async {
        let timeData = await writePacket(SetTimePacket(date: Date.now))
        
        switch timeData {
        case .failure(let error):
            log.error("Failed to set time: \(error.localizedDescription)")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription)))
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
            log.error("Failed to set time: \(error.localizedDescription)")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription)))
            break
            
        case .success:
            log.info("Successfully set timezone")
            
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
            log.error("Failed to synchronize: \(error.localizedDescription)")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription)))
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
            log.error("Failed to subscribe: \(error.localizedDescription)")
            completion?(.failure(error: .failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription)))
            break
            
        case .success:
            log.info("Connected to pump!")
            completion?(.success)
        }
    }
    
    private func parseStateUpdate(_ syncResponse: SynchronizePacketResponse) {
        // TEMP
        do {
            self.log.info("State update: \(String(data: try JSONEncoder().encode(syncResponse), encoding: .utf8) ?? "")")
        } catch {
            self.log.warning("State update: Failed to encode JSON")
        }
        
        pumpManager.state.pumpState = syncResponse.state
        
        if let reservoir = syncResponse.reservoir {
            pumpManager.state.reservoir = reservoir
        }
        
        if let basal = syncResponse.basal {
            switch basal.type {
            case .ABSOLUTE_TEMP, .RELATIVE_TEMP:
                pumpManager.state.basalState = .tempBasal
                break
                
            case .SUSPEND_LOW_GLUCOSE, .SUSPEND_PREDICT_LOW_GLUCOSE, .SUSPEND_AUTO, .SUSPEND_MORE_THAN_MAX_PER_HOUR, .SUSPEND_MORE_THAN_MAX_PER_DAY, .SUSPEND_MANUAL, .SUSPEND_KEY_LOST, .STOP_OCCLUSION, .STOP_EXPIRED, .STOP_EMPTY, .STOP_PATCH_FAULT, .STOP_PATCH_FAULT2, .STOP_BASE_FAULT, .STOP_DISCARD, .STOP_BATTERY_EMPTY, .STOP:
                pumpManager.state.basalState = .suspended
                break
                
            default:
                pumpManager.state.basalState = .active
                break
            }
        }
        
        if let battery = syncResponse.battery {
            pumpManager.state.battery = battery.voltageB
        }
        
        if let primeProgress = syncResponse.primeProgress {
            pumpManager.state.primeProgress = primeProgress
        }
        
        if let bolus = syncResponse.bolus {
            pumpManager.updateBolusProgress(delivered: bolus.delivered, completed: bolus.completed)
        }
        
        pumpManager.state.lastSync = Date.now
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
            guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                return
            }
            
            self.log.info("Enable notify for: \(characteristic.uuid.uuidString)")
            peripheral.setNotifyValue(true, for: characteristic)
        }
        
        Task {
            self.log.debug("Notify enabled and ready to start auth flow!")
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
        
        if characteristic.uuid.uuidString.lowercased() == PeripheralManager.READ_UUID.uuidString.lowercased() {
            guard data[1] != 0x00 else {
                // Ignore all ping messages from patch pomp
                return
            }

            self.log.debug("READ -> Got data: \(data.hexEncodedString())")
            
            var packet = NotificationPacket()
            packet.decode(data)

            self.parseStateUpdate(packet.parseResponse())
            return
        }
        
        // Processing data
        guard var packet = self.currentPacket else {
            self.log.warning("No packet available...")
            // No packet available to validate against
            return
        }
        
        self.log.debug("Got data: \(data.hexEncodedString())")
        packet.decode(data)
        self.currentPacket = packet

        guard packet.isComplete else {
            self.log.warning("Data no complete yet...")
            // Wait for more data
            return
        }
        
        guard let writeCallback = writeQueue[packet.commandType] else {
            // Timeout is hit...
            self.currentPacket = nil
            self.writeSemaphore.signal()
            return
        }
        
        if packet.responseCode == 16384 {
            // Need to skip to packet
            return
        }
        
        if packet.responseCode != 0 {
            // Examples for invalid codes:
            // 7 -> Invalid authorization: propably wrong session token used
            // 8 -> Invalid state: The patch is not in state 32 (active), which is required for that command
            writeCallback.resume(returning: .failure(error: .invalidResponse(code: packet.responseCode)))
        } else if packet.failed {
            writeCallback.resume(returning: .failure(error: .invalidData))
        } else {
            writeCallback.resume(returning: .success(data: packet.parseResponse()))
        }
        
        
        self.writeQueue[packet.commandType] = nil
        self.currentPacket = nil
        self.writeSemaphore.signal()
    }
}

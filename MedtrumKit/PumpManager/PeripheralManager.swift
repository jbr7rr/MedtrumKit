import CoreBluetooth

class PeripheralManager: NSObject {
    private let log = MedtrumLogger(category: "PeripheralManager")

    private let peripheral: CBPeripheral
    private weak var bluetoothManager: BluetoothManager?
    private weak var pumpManager: MedtrumPumpManager?
    private var completion: ((MedtrumConnectError?) -> Void)?

    private var readCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?

    // access is serialized by the semaphore inside writePacket
    private var writeSequence: UInt8 = 0

    /// Guards the four fields below. writePacket runs on the caller's thread while the response
    /// arrives on the central manager's queue, so every access to them is cross-thread. Never
    /// held across `writeQ.wait()`, `peripheral.writeValue` or `leave()`.
    private let stateLock = NSLock()

    /* access must be serialized with stateLock */
    private var currentPacket: (any MedtrumBasePacketProtocol)?
    private var currentSequence: UInt8 = 0
    private var writeQueue: MedtrumKitDispatchGroup?
    private var writeResponse: MedtrumWriteResult<Any>?
    private var isInvalidated = false
    private var isReadyStorage = false
    /* end */

    private let semaphore = DispatchSemaphore(value: 1)

    /* access must be serialized with stateLock, prevents concurrent `considerFullSync` runs */
    private var isFullSyncInFlight = false

    public init(
        _ peripheral: CBPeripheral,
        _ bluetoothManager: BluetoothManager,
        _ pumpManager: MedtrumPumpManager,
        _ completion: @escaping (MedtrumConnectError?) -> Void
    ) {
        self.peripheral = peripheral
        self.bluetoothManager = bluetoothManager
        self.pumpManager = pumpManager
        self.completion = completion

        super.init()

        peripheral.delegate = self
    }

    func cleanup() {
        stateLock.lock()
        isInvalidated = true
        let queue = writeQueue
        writeQueue = nil
        currentPacket = nil
        stateLock.unlock()

        // outside the lock: leave() takes a lock of its own, and it wakes writePacket, which
        // immediately wants ours.
        queue?.leave()
    }

    private func disconnectIfActive() {
        bluetoothManager?.disconnect(ifCurrent: self)
    }

    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isReadyStorage
    }

    private var isInvalidatedLocked: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isInvalidated
    }

    func writePacket(_ packet: any MedtrumBasePacketProtocol) -> MedtrumWriteResult<Any> {
        guard let characteristic = writeCharacteristic else {
            log.error("No write characteristic found... Device might be disconnected...")
            return .failure(error: .noWriteCharacteristic)
        }

        semaphore.wait()
        defer {
            semaphore.signal()
        }

        let writeQ = MedtrumKitDispatchGroup()
        writeQ.enter()

        stateLock.lock()
        guard !isInvalidated else {
            stateLock.unlock()
            // Balance the enter above: the group has to be entered before it is published, or
            // cleanup could leave() it first and this write would then wait out its full timeout.
            writeQ.leave()
            return .failure(error: .noManager)
        }
        writeQueue = writeQ
        currentPacket = packet
        currentSequence = writeSequence
        stateLock.unlock()

        let packages = packet.encode(sequenceNumber: writeSequence)
        writeSequence = UInt8(writeSequence + 1)
        if writeSequence >= 254 {
            writeSequence = 0
        }

        for package in packages {
            log.debug("Writing data: \(package.hexEncodedString())")
            peripheral.writeValue(package, for: characteristic, type: .withResponse)
        }

        // Wait for response or timeout timer...
        _ = writeQ.wait(timeout: .now() + .seconds(30))

        // Tear down as one step: on timeout the delegate may still be mid-flight, and this is
        // what tells it the command is no longer current.
        stateLock.lock()
        let response = writeResponse
        writeQueue = nil
        currentPacket = nil
        writeResponse = nil
        stateLock.unlock()

        guard let response = response else {
            log.warning("Timeout has been reached...")
            return .failure(error: .timeout)
        }

        return response
    }
}

extension PeripheralManager {
    // Connect step 1
    private func doAuthorize(useBackupToken: Bool = false) {
        guard let pumpManager else {
            return
        }

        let token = !useBackupToken ? pumpManager.state.sessionToken : pumpManager.state.backupSessionToken
        let authData = writePacket(
            AuthorizePacket(pumpSN: pumpManager.state.pumpSN, sessionToken: token)
        )

        switch authData {
        case let .failure(error):
            if !useBackupToken {
                log.warning("Failed to complete authorization flow, falling back to backup token")
                doAuthorize(useBackupToken: true)
                return
            }

            log.error("Failed to complete authorization flow: \(error.localizedDescription)")
            disconnectIfActive()
            completion?(.failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription))

        case let .success(data):
            guard let authResponse = data as? AuthorizeResponse else {
                log.error("Failed to complete authorization flow: invalid response")
                disconnectIfActive()
                completion?(.failedToCompleteAuthorizationFlow(localizedError: "invalid response"))
                return
            }

            pumpManager.state.deviceType = authResponse.deviceType
            pumpManager.state.swVersion = authResponse.swVersion

            synchronize()
        }
    }

    // Connect step 2
    private func synchronize() {
        let syncData = writePacket(SynchronizePacket())

        switch syncData {
        case let .failure(error):
            log.error("Failed to synchronize: \(error.localizedDescription)")
            disconnectIfActive()
            completion?(.failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription))

        case let .success(data):
            guard let syncResponse = data as? SynchronizePacketResponse else {
                log.error("Failed to Synchronize packet: invalid response")
                disconnectIfActive()
                completion?(.failedToCompleteAuthorizationFlow(localizedError: "invalid response"))
                return
            }

            parseStateUpdate(syncResponse, duringReconnect: true, fullSync: true)
            subscribe()
        }
    }

    // Connect step 4 (last)
    private func subscribe() {
        let subscribeData = writePacket(SubscribePacket())

        switch subscribeData {
        case let .failure(error):
            log.error("Failed to subscribe: \(error.localizedDescription)")
            disconnectIfActive()
            completion?(.failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription))

        case .success:
            guard !isInvalidatedLocked else {
                return
            }

            log.info("Connected to pump!")

            stateLock.lock()
            isReadyStorage = true
            stateLock.unlock()

            pumpManager?.state.isConnected = true
            pumpManager?.notifyStateDidChange()
            completion?(nil)
        }
    }

    private func parseStateUpdate(_ syncResponse: SynchronizePacketResponse, duringReconnect: Bool, fullSync: Bool) {
        guard let pumpManager else {
            return
        }

        guard !isInvalidatedLocked else {
            return
        }

        // TEMP
        do {
            log.info("State update: \(String(data: try JSONEncoder().encode(syncResponse), encoding: .utf8) ?? "")")
        } catch {
            log.warning("State update: Failed to encode JSON - \(error)")
        }

        StateSyncer.sync(
            syncResponse: syncResponse,
            state: pumpManager.state,
            pumpManager: pumpManager,
            duringReconnect: duringReconnect,
            fullSync: fullSync
        )

        pumpManager.issueHeartbeatIfNeeded()
    }
}

extension PeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log.error("\(error.localizedDescription)")
            disconnectIfActive()
            completion?(.failedToDiscoverServices(localizedError: error.localizedDescription))
            return
        }

        let service = peripheral.services?.first(where: { $0.uuid == CBUUID.SERVICE_UUID })
        guard let service = service else {
            let localizedError = "No Medtrum service found - " +
                (peripheral.services?.map(\.uuid.uuidString).joined(separator: ", ") ?? "No services discovered")
            log.error(localizedError)
            disconnectIfActive()
            completion?(.failedToDiscoverServices(localizedError: localizedError))
            return
        }

        peripheral.discoverCharacteristics([CBUUID.READ_UUID, CBUUID.WRITE_UUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log.error("\(error.localizedDescription)")
            disconnectIfActive()
            completion?(.failedToDiscoverCharacteristics(localizedError: error.localizedDescription))
            return
        }

        readCharacteristic = service.characteristics?.first(where: { $0.uuid == CBUUID.READ_UUID })
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == CBUUID.WRITE_UUID })

        guard readCharacteristic != nil, writeCharacteristic != nil else {
            let localizedError = "Failed to discover read, write or config characteristic - " +
                (service.characteristics?.map(\.uuid.uuidString).joined(separator: ", ") ?? "No characteristics discovered")

            log.error(localizedError)
            disconnectIfActive()
            completion?(.failedToDiscoverCharacteristics(localizedError: localizedError))
            return
        }

        // Subscribe on all characteristics with notifying abilities
        service.characteristics?.forEach { characteristic in
            guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                return
            }

            self.log.debug("Enable notify for: \(characteristic.uuid.uuidString)")
            peripheral.setNotifyValue(true, for: characteristic)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }

            self.log.debug("Notify enabled and ready to start auth flow!")
            doAuthorize()
        }
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("Got error from didUpdateValueFor: \(error.localizedDescription)")
            if let connectCompletion = completion {
                connectCompletion(.failedToEnableNotify(localizedError: error.localizedDescription))
            }
            return
        }

        guard let data = characteristic.value, !data.isEmpty else {
            log.warning(
                "No usable data in didUpdateValueFor - characteristic: \(characteristic.uuid.uuidString), " +
                    "data: \(characteristic.value?.hexEncodedString() ?? "nil")"
            )
            return
        }

        if characteristic.uuid == CBUUID.READ_UUID {
            handleHeartbeat(data: data)

            considerFullSync()
            return
        }

        // Processing data
        log.debug("Got data: \(data.hexEncodedString())")

        stateLock.lock()
        let sequence = currentSequence
        let pending = currentPacket
        stateLock.unlock()

        guard var packet = pending else {
            log.warning("No packet available...")
            return
        }

        // Byte 2 echoes the sequence number of the command this is a response to, on every
        // fragment. It has to be checked on all of them, not just the first: decode() validates
        // a continuation fragment for ordering and CRC only, so a late fragment of an abandoned
        // command would otherwise be appended to whatever packet is now in flight - with a valid
        // CRC and a matching fragment index, so nothing downstream would notice.
        if data.count > 2, data[2] != sequence {
            log.warning("Ignoring response for sequence \(data[2]), waiting on \(sequence)")
            return
        }

        packet.decode(data)

        stateLock.lock()
        guard currentSequence == sequence, writeQueue != nil else {
            // writePacket timed out while we were decoding, and may already have started
            // another command. This response is no longer anybody's.
            stateLock.unlock()
            log.warning("Discarding response for sequence \(sequence), no longer the current command")
            return
        }
        currentPacket = packet
        stateLock.unlock()

        guard packet.isComplete else {
            log.debug("Waiting for more data...")
            return
        }

        if packet.responseCode == 16384 {
            // Need to skip to packet
            log.debug("Skipping this message - data: \(packet.totalData.hexEncodedString())")
            return
        }

        let response: MedtrumWriteResult<Any>
        if packet.responseCode != 0 {
            // Examples for invalid codes:
            // 7 -> Invalid authorization: propably wrong session token used
            // 8 -> Invalid state: The patch is not in state 32 (active), which is required for that command
            log.error("Invalid responseCode: \(packet.responseCode)")
            response = .failure(error: .invalidResponse(code: packet.responseCode))
        } else if packet.failed {
            log.error("Failed to parse message, either wrong command type or CRC check failed...")
            response = .failure(error: .invalidData)
        } else if !packet.hasEnoughData {
            let message =
                "Packet has too little data - expected: \(packet.mimimumDataSize), data: \(packet.totalData.hexEncodedString())"
            log.error(message)

            response = .failure(error: .invalidData)
        } else {
            response = .success(data: packet.parseResponse())
        }

        stateLock.lock()
        guard currentSequence == sequence, let writeCallback = writeQueue else {
            // Timed out between decoding and parsing; writePacket has already given up
            stateLock.unlock()
            return
        }
        writeResponse = response
        writeQueue = nil
        currentPacket = nil
        stateLock.unlock()

        // Outside the lock, and last: this hands writePacket the fields we just finished with.
        writeCallback.leave()
    }

    private func handleHeartbeat(data: Data) {
        log.debug("READ -> Got data: \(data.hexEncodedString())")

        let packet = NotificationPacket()
        // not a command response: no header, no CRC
        packet.totalData = data

        guard packet.hasEnoughData else {
            log.error("Heartbeat notification too short to parse: \(data.hexEncodedString())")
            return
        }

        parseStateUpdate(packet.parseResponse(), duringReconnect: false, fullSync: false)
    }

    private func considerFullSync() {
        guard let pumpManager else {
            return
        }

        let age = Date.now.timeIntervalSince(pumpManager.state.lastSync)
        guard age > MedtrumPumpManager.heartbeatSyncFreshnessInterval else {
            return
        }

        guard pumpManager.state.bolusState == .noBolus else {
            log.debug("Skipping sync, pump is currently bolusing")
            return
        }

        stateLock.lock()
        guard !isFullSyncInFlight else {
            stateLock.unlock()
            return
        }
        isFullSyncInFlight = true
        stateLock.unlock()

        // Do the full sync off the loop's critical path.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.stateLock.lock()
                self.isFullSyncInFlight = false
                self.stateLock.unlock()
            }

            let response = self.writePacket(SynchronizePacket())
            switch response {
            case let .failure(error):
                self.log.error("Failed to get synchronize: \(error.localizedDescription)")
                return

            case let .success(data):
                guard let syncResponse = data as? SynchronizePacketResponse else {
                    self.log.error("Failed to Synchronize packet: invalid response")
                    return
                }

                self.parseStateUpdate(syncResponse, duringReconnect: false, fullSync: true)

                if let pumpManager = self.pumpManager {
                    StateSyncer.fetchPatchTimeIfStale(pumpManager: pumpManager)
                }
            }
        }
    }
}

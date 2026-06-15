import CoreBluetooth

class PeripheralManager: NSObject {
    private let log = MedtrumLogger(category: "PeripheralManager")
    private let queue = DispatchQueue(label: "org.nightscout.MedtrumKit.message-queue")

    private let peripheral: CBPeripheral
    private let bluetoothManager: BluetoothManager
    private let pumpManager: MedtrumPumpManager
    private var completion: ((MedtrumConnectError?) -> Void)?

    private var readCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?

    private var writeSequence: UInt8 = 0
    private var currentPacket: (any MedtrumBasePacketProtocol)?

    private var writeQueue: MedtrumKitDispatchGroup?
    private var writeResponse: MedtrumWriteResult<Any>?
    private let semaphore = DispatchSemaphore(value: 1)

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
        if let queue = writeQueue {
            queue.leave()
            writeQueue = nil
        }
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
        writeQueue = writeQ
        currentPacket = packet

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
        writeQueue = nil

        guard let response = writeResponse else {
            log.warning("Timeout has been reached...")
            return .failure(error: .timeout)
        }

        writeResponse = nil
        return response
    }
}

extension PeripheralManager {
    /// Auth was rejected because of a wrong session token. Only `7` is
    /// documented ("invalid authorization"). We intentionally do NOT act on other
    /// codes (e.g. 32) - their meaning is undocumented and 32 collides with the
    /// value of the active patch state, so treating it as a token error would be a
    /// guess. The empty-token case is handled separately, before sending auth.
    private static func isAuthTokenRejection(_ error: MedtrumWriteError) -> Bool {
        if case let .invalidResponse(code) = error {
            return code == 7
        }
        return false
    }

    // Connect step 1
    private func doAuthorize(triedBackup: Bool = false) {
        // An empty active token can never authorize. If we have a backup (e.g. the
        // token was cleared when the previous patch ended), use it rather than
        // sending an empty request - this avoids depending on whatever code the
        // patch returns for an empty token.
        if !triedBackup, pumpManager.state.sessionToken.isEmpty,
           pumpManager.restoreBackupSessionToken(reason: "auth: active token empty, using backup")
        {
            pumpManager.notifyStateDidChange()
        }

        let authData = writePacket(
            AuthorizePacket(pumpSN: pumpManager.state.pumpSN, sessionToken: pumpManager.state.sessionToken)
        )

        switch authData {
        case let .failure(error):
            // Wrong token (code 7). The patch still responded, so the connection is
            // up: try the backup token once on the same connection before giving up.
            // This recovers patches whose active token was cleared/replaced (e.g.
            // force-deactivate) while the patch is still bound to the previous one.
            if !triedBackup, Self.isAuthTokenRejection(error),
               pumpManager.restoreBackupSessionToken(reason: "auth rejected: \(error.errorDescription)")
            {
                pumpManager.notifyStateDidChange()
                log.info("Authorization rejected (\(error.errorDescription)); retrying with backup session token")
                doAuthorize(triedBackup: true)
                return
            }

            log.error("Failed to complete authorization flow: \(error.localizedDescription)")
            bluetoothManager.disconnect()
            completion?(.failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription))

        case let .success(data):
            guard let authResponse = data as? AuthorizeResponse else {
                log.error("Failed to complete authorization flow: invalid response")
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
            bluetoothManager.disconnect()
            completion?(.failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription))

        case let .success(data):
            guard let syncResponse = data as? SynchronizePacketResponse else {
                log.error("Failed to Synchronize packet: invalid response")
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
            bluetoothManager.disconnect()
            completion?(.failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription))

        case .success:
            log.info("Connected to pump!")

            pumpManager.state.isConnected = false
            pumpManager.notifyStateDidChange()
            completion?(nil)
        }
    }

    private func parseStateUpdate(_ syncResponse: SynchronizePacketResponse, duringReconnect: Bool, fullSync: Bool) {
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
    }
}

extension PeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log.error("\(error.localizedDescription)")
            completion?(.failedToDiscoverServices(localizedError: error.localizedDescription))
            return
        }

        let service = peripheral.services?.first(where: { $0.uuid == CBUUID.SERVICE_UUID })
        guard let service = service else {
            let localizedError = "No Medtrum service found - " +
                (peripheral.services?.map(\.uuid.uuidString).joined(separator: ", ") ?? "No services discovered")
            log.error(localizedError)
            completion?(.failedToDiscoverServices(localizedError: localizedError))
            return
        }

        peripheral.discoverCharacteristics([CBUUID.READ_UUID, CBUUID.WRITE_UUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log.error("\(error.localizedDescription)")
            completion?(.failedToDiscoverCharacteristics(localizedError: error.localizedDescription))
            return
        }

        readCharacteristic = service.characteristics?.first(where: { $0.uuid == CBUUID.READ_UUID })
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == CBUUID.WRITE_UUID })

        guard readCharacteristic != nil, writeCharacteristic != nil else {
            let localizedError = "Failed to discover read, write or config characteristic - " +
                (service.characteristics?.map(\.uuid.uuidString).joined(separator: ", ") ?? "No characteristics discovered")

            log.error(localizedError)
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

        guard let data = characteristic.value else {
            log.warning("No data in didUpdateValueFor - characteristic: \(characteristic.uuid.uuidString)")
            return
        }

        if characteristic.uuid == CBUUID.READ_UUID {
            guard data[1] != 0x00 else {
                // Ignore all ping messages from patch pomp
                return
            }

            handleHeartbeat(data: data)
            return
        }

        // Processing data
        log.debug("Got data: \(data.hexEncodedString())")
        guard var packet = currentPacket else {
            log.warning("No packet available...")
            return
        }

        packet.decode(data)
        currentPacket = packet

        guard packet.isComplete else {
            log.debug("Waiting for more data...")
            return
        }

        guard let writeCallback = writeQueue else {
            // Timeout is hit...
            currentPacket = nil
            return
        }

        if packet.responseCode == 16384 {
            // Need to skip to packet
            log.debug("Skipping this message - data: \(packet.totalData.hexEncodedString())")
            return
        }

        if packet.responseCode != 0 {
            // Examples for invalid codes:
            // 7 -> Invalid authorization: propably wrong session token used
            // 8 -> Invalid state: The patch is not in state 32 (active), which is required for that command
            log.error("Invalid responseCode: \(packet.responseCode)")
            writeResponse = .failure(error: .invalidResponse(code: packet.responseCode))
        } else if packet.failed {
            log.error("Failed to parse message, either wrong command type or CRC check failed...")
            writeResponse = .failure(error: .invalidData)
        } else {
            if !packet.hasEnoughData {
                let message =
                    "Packet has too little data - expected: \(packet.mimimumDataSize), data: \(packet.totalData.hexEncodedString())"
                log.error(message)

                writeResponse = .failure(error: .invalidData)
            } else {
                writeResponse = .success(data: packet.parseResponse())
            }
        }

        writeCallback.leave()
        writeQueue = nil
        currentPacket = nil
    }

    private func handleHeartbeat(data: Data) {
        var data = data

        log.debug("READ -> Got data: \(data.hexEncodedString())")
        data.append(0x00) // Little CRC hack. The notification lacks the CRC value, thus add an empty value there

        var packet = NotificationPacket()
        packet.decode(data)

        guard Date.now.timeIntervalSince(pumpManager.state.lastSync) > .minutes(2.5) else {
            parseStateUpdate(packet.parseResponse(), duringReconnect: false, fullSync: false)
            return
        }

        guard pumpManager.state.bolusState == .noBolus else {
            parseStateUpdate(packet.parseResponse(), duringReconnect: false, fullSync: false)
            log.warning("Skipping sync, pump is currently bolusing")
            return
        }

        // Do full sync (only every 3min)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }

            let response = self.writePacket(SynchronizePacket())
            StateSyncer.fetchPatchTime(pumpManager: self.pumpManager)

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
            }
        }
    }
}

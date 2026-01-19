import CoreBluetooth

class PeripheralManager: NSObject {
    private let log = MedtrumLogger(category: "PeripheralManager")
    private let queue = DispatchQueue(label: "org.nightscout.MedtrumKit.message-queue")

    private let connectedDevice: CBPeripheral
    private let bluetoothManager: BluetoothManager
    private let pumpManager: MedtrumPumpManager
    private var completion: ((MedtrumConnectError?) -> Void)?

    public static let SERVICE_UUID = CBUUID(string: "669A9001-0008-968F-E311-6050405558B3")
    private static let READ_UUID = CBUUID(string: "669a9120-0008-968f-e311-6050405558b3")
    private var readCharacteristic: CBCharacteristic?
    private static let WRITE_UUID = CBUUID(string: "669a9101-0008-968f-e311-6050405558b3")
    private var writeCharacteristic: CBCharacteristic?

    private var writeSequence: UInt8 = 0
    private var currentPacket: (any MedtrumBasePacketProtocol)?

    private var writeQueue: AsyncStream<MedtrumWriteResult<Any>>.Continuation?
    private var writeTimeoutTask: Task<Void, Never>?

    public init(
        _ peripheral: CBPeripheral,
        _ bluetoothManager: BluetoothManager,
        _ pumpManager: MedtrumPumpManager,
        _ completion: @escaping (MedtrumConnectError?) -> Void
    ) {
        connectedDevice = peripheral
        self.bluetoothManager = bluetoothManager
        self.pumpManager = pumpManager
        self.completion = completion

        super.init()

        peripheral.delegate = self
    }

    deinit {
        if let queue = writeQueue {
            queue.yield(.failure(error: .noData))
            queue.finish()
            writeQueue = nil
        }

        if let timeout = writeTimeoutTask {
            timeout.cancel()
            writeTimeoutTask = nil
        }
    }

    func writePacket(_ packet: any MedtrumBasePacketProtocol) async -> MedtrumWriteResult<Any> {
        guard writeQueue == nil else {
            log.error("A command is already running")
            return .failure(error: .alreadyRunning)
        }

        guard let writeCharacteristic = self.writeCharacteristic else {
            log.error("No write characteristic found... Device might be disconnected...")
            return .failure(error: .noWriteCharacteristic)
        }

        let stream = AsyncStream<MedtrumWriteResult<Any>> { continuation in
            self.writeQueue = continuation
            self.write(packet, for: writeCharacteristic)
        }

        // Now we wait for a response or we return timeout
        for await value in stream {
            return value
        }

        return .failure(error: .noData)
    }

    private func write(_ packet: any MedtrumBasePacketProtocol, for characteristic: CBCharacteristic) {
        currentPacket = packet

        let packages = packet.encode(sequenceNumber: writeSequence)
        writeSequence = UInt8(writeSequence + 1)
        if writeSequence >= 254 {
            writeSequence = 0
        }

        for package in packages {
            log.debug("Writing data: \(package.hexEncodedString())")
            connectedDevice.writeValue(package, for: characteristic, type: .withResponse)
        }

        writeTimeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(.seconds(30)) * 1_000_000_000)
                guard let stream = self.writeQueue else {
                    // We did what we must!
                    return
                }

                // By not sending a yield, we trigger a timeout error in writePacket
                log.warning("Timeout has been reached...")

                stream.yield(.failure(error: .timeout))
                stream.finish()
                self.writeQueue = nil
                self.writeTimeoutTask = nil
            } catch {
                // Task was cancelled because message has been received
            }
        }
    }
}

extension PeripheralManager {
    // Connect step 1
    private func doAuthorize() async {
        let authData = await writePacket(
            AuthorizePacket(pumpSN: pumpManager.state.pumpSN, sessionToken: pumpManager.state.sessionToken)
        )

        switch authData {
        case let .failure(error):
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

            await synchronize()
        }
    }

    // Connect step 2
    private func synchronize() async {
        let syncData = await writePacket(SynchronizePacket())

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

            parseStateUpdate(syncResponse)
            await subscribe()
        }
    }

    // Connect step 4 (last)
    private func subscribe() async {
        let subscribeData = await writePacket(SubscribePacket())

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

    private func parseStateUpdate(_ syncResponse: SynchronizePacketResponse) {
        // TEMP
        do {
            log.info("State update: \(String(data: try JSONEncoder().encode(syncResponse), encoding: .utf8) ?? "")")
        } catch {
            log.warning("State update: Failed to encode JSON - \(error)")
        }

        StateSyncer.sync(
            syncResponse: syncResponse,
            state: pumpManager.state,
            pumpManager: pumpManager
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

        let service = peripheral.services?.first(where: { $0.uuid == PeripheralManager.SERVICE_UUID })
        guard let service = service else {
            let localizedError = "No Medtrum service found - " +
                (peripheral.services?.map(\.uuid.uuidString).joined(separator: ", ") ?? "No services discovered")
            log.error(localizedError)
            completion?(.failedToDiscoverServices(localizedError: localizedError))
            return
        }

        peripheral.discoverCharacteristics([PeripheralManager.READ_UUID, PeripheralManager.WRITE_UUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log.error("\(error.localizedDescription)")
            completion?(.failedToDiscoverCharacteristics(localizedError: error.localizedDescription))
            return
        }

        let service = peripheral.services!.first(where: { $0.uuid == PeripheralManager.SERVICE_UUID })!
        readCharacteristic = service.characteristics?.first(where: { $0.uuid == PeripheralManager.READ_UUID })
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == PeripheralManager.WRITE_UUID })

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

        Task {
            self.log.debug("Notify enabled and ready to start auth flow!")
            await doAuthorize()
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

        guard var data = characteristic.value else {
            log.warning("No data in didUpdateValueFor - characteristic: \(characteristic.uuid.uuidString)")
            return
        }

        queue.async {
            if characteristic.uuid.uuidString.lowercased() == PeripheralManager.READ_UUID.uuidString.lowercased() {
                guard data[1] != 0x00 else {
                    // Ignore all ping messages from patch pomp
                    return
                }

                self.log.debug("READ -> Got data: \(data.hexEncodedString())")
                data.append(0x00) // Little CRC hack. The notification lacks the CRC value, thus add an empty value there

                var packet = NotificationPacket()
                packet.decode(data)

                self.parseStateUpdate(packet.parseResponse())
                return
            }

            // Processing data
            self.log.debug("Got data: \(data.hexEncodedString())")
            guard var packet = self.currentPacket else {
                self.log.warning("No packet available...")
                return
            }

            packet.decode(data)
            self.currentPacket = packet

            guard packet.isComplete else {
                self.log.debug("Waiting for more data...")
                return
            }

            guard let writeCallback = self.writeQueue else {
                // Timeout is hit...
                self.currentPacket = nil
                return
            }

            if packet.responseCode == 16384 {
                // Need to skip to packet
                self.log.debug("Skipping this message - data: \(packet.totalData.hexEncodedString())")
                return
            }

            self.writeTimeoutTask?.cancel()
            self.writeTimeoutTask = nil

            if packet.responseCode != 0 {
                // Examples for invalid codes:
                // 7 -> Invalid authorization: propably wrong session token used
                // 8 -> Invalid state: The patch is not in state 32 (active), which is required for that command
                self.log.error("Invalid responseCode: \(packet.responseCode)")
                writeCallback.yield(.failure(error: .invalidResponse(code: packet.responseCode)))
            } else if packet.failed {
                self.log.error("Failed to parse message, either wrong command type or CRC check failed...")
                writeCallback.yield(.failure(error: .invalidData))
            } else {
                if !packet.hasEnoughData {
                    let message =
                        "Packet has too little data - expected: \(packet.mimimumDataSize), data: \(packet.totalData.hexEncodedString())"
                    self.log.error(message)

                    writeCallback.yield(.failure(error: .invalidData))
                } else {
                    writeCallback.yield(.success(data: packet.parseResponse()))
                }
            }

            writeCallback.finish()
            self.writeQueue = nil
            self.currentPacket = nil
        }
    }
}

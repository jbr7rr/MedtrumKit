import CoreBluetooth

class BluetoothManager: NSObject, CBCentralManagerDelegate {
    public var pumpManager: MedtrumPumpManager?

    let logger = MedtrumLogger(category: "BluetoothManager")

    var manager: CBCentralManager!
    let managerQueue = DispatchQueue(label: "com.nightscout.MedtrumKit.bluetoothManagerQueue", qos: .unspecified)

    private var peripheral: CBPeripheral?
    private var peripheralManager: PeripheralManager?

    var scanCompletion: ((MedtrumScanResult) -> Void)?
    var connectCompletion: ((MedtrumConnectError?) -> Void)?
    var connectionTimeout: Task<Void, Never>?

    public var isConnected: Bool {
        if let peripheral = peripheral, peripheral.state == .connected {
            return true
        }

        return false
    }

    override init() {
        super.init()

        managerQueue.sync {
            self.manager = CBCentralManager(
                delegate: self,
                queue: managerQueue,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "com.nightscout.MedtrumKit.bluetoothManager"]
            )
        }
    }

    func startScan(_ completion: @escaping (_ result: MedtrumScanResult) -> Void) {
        if let pumpManager = self.pumpManager, pumpManager.state.pumpSN.isEmpty {
            completion(.failure(error: .noSerialNumberAvailable))
            return
        }
        guard manager.state == .poweredOn else {
            completion(.failure(error: .invalidBluetoothState(state: manager.state)))
            return
        }

        if !manager.isScanning {
            manager.stopScan()
        }

        scanCompletion = completion
        manager.scanForPeripherals(withServices: [])

        logger.info("Started scanning")
        // TODO: Add scan timeout - 15s?
    }

    private func connect(peripheral: CBPeripheral) {
        if manager.isScanning {
            manager.stopScan()
            scanCompletion = nil
        }

        logger.info("Connecting to \(peripheral)")

        self.peripheral = peripheral
        manager.connect(peripheral)
    }

    func ensureConnected(_ completionAsync: @escaping (MedtrumConnectError?) async -> Void) {
        guard connectCompletion == nil else {
            logger.error("EnsureConnected is already running...")
            Task {
                await completionAsync(.failedToConnectToDevice)
            }
            return
        }

        connectCompletion = { (_ result: MedtrumConnectError?) -> Void in
            Task {
                self.connectCompletion = nil
                self.connectionTimeout?.cancel()
                self.connectionTimeout = nil
                
                await completionAsync(result)
            }
        }

        if let peripheral = peripheral, peripheral.state == .connected {
            logger.debug("Already connect!")
            connectCompletion?(nil)
            return
        }

        if let peripheral = peripheral {
            // We've the peripheral reference to a previous connection
            // Just try to reconnect
            startTimeout(seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        let connectedDevices = manager.retrieveConnectedPeripherals(withServices: [PeripheralManager.SERVICE_UUID])
        if let peripheral = connectedDevices.first(where: { $0.name == "MT" }) {
            // Phone is already connected, but the app is not
            connect(peripheral: peripheral)
            return
        }

        guard var pumpSNState = pumpManager?.state.pumpSN else {
            logger.error("No pump serial number found")
            connectCompletion?(.failedToFindDevice)
            return
        }

        pumpSNState = Data(pumpSNState.reversed())

        // We are disconnected and have no reference to the previous connection
        // Start to scan for patch and reconnect the long way
        startScan { result in
            switch result {
            case let .failure(error):
                self.logger.error("Error during scanning: \(error.localizedDescription)")
                self.manager.stopScan()
                self.connectCompletion?(.failedToFindDevice)

            case let .success(peripheral, pumpSN, _, _):
                guard pumpSN == pumpSNState else {
                    // Other patch pump found. IGNORE
                    return
                }

                self.connect(peripheral: peripheral)
            }
        }
    }

    func startTimeout(seconds: TimeInterval) {
        connectionTimeout = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard let connectionCallback = self.connectCompletion else {
                    // This is amazing, we've done what we must and continue our live :)
                    return
                }

                if let peripheral = self.peripheral, peripheral.state == .connected {
                    // This is amazing, we've done what we must and continue our live :)
                    return
                }

                self.logger.error("Failed to connect: Timeout reached...")

                connectionCallback(.failedToConnectToDevice)
                self.connectCompletion = nil
            } catch {}
        }
    }

    func write(_ packet: any MedtrumBasePacketProtocol) async -> MedtrumWriteResult<Any> {
        guard let peripheralManager else {
            return .failure(error: .noManager)
        }

        return await peripheralManager.writePacket(packet)
    }

    func disconnect() {
        if let peripheral = self.peripheral, peripheral.state == .connected {
            manager.cancelPeripheralConnection(peripheral)
        }
    }

    func clearPeripheral() {
        peripheral = nil
        peripheralManager = nil
    }
}

extension BluetoothManager {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("\(String(describing: central.state.rawValue))")

        if central.state == .poweredOn, !isConnected, pumpManager?.state.pumpState == .active {
            ensureConnected { error in
                if let error = error {
                    self.logger.error("Failed to auto reconnect on boot: \(error)")
                }
            }
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty, name == "MT" else {
            return
        }

        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey]
        guard let manufacturerData = manufacturerData as? Data, manufacturerData.count >= 7 else {
            logger.warning("No ManufacturerData or too short - " + advertisementData.keys.joined(separator: ", "))

            // Simulator bypass
            scanCompletion?(
                .success(
                    peripheral: peripheral,
                    pumpSN: Data([0x4A, 0x12, 0xD8, 0x28]),
                    deviceType: 1,
                    version: 1
                )
            )
            return
        }

        // Index:
        // 0 & 1 -> Manufacturer ID
        // 2-5 -> PumpSN
        // 6 -> Device type
        // 7 -> Version
        scanCompletion?(
            .success(
                peripheral: peripheral,
                pumpSN: manufacturerData[2 ..< 6],
                deviceType: manufacturerData[6],
                version: manufacturerData[7]
            )
        )
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to pump: \(peripheral.name ?? "<NO_NAME>")!")

        guard let pumpManager = pumpManager else {
            logger.warning("No pumpManager...")
            return
        }
        guard let completion = connectCompletion else {
            logger.warning("No connectCompletion...")
            return
        }

        connectionTimeout?.cancel()

        self.peripheral = peripheral
        peripheralManager = PeripheralManager(peripheral, self, pumpManager, completion)
        peripheral.discoverServices([PeripheralManager.SERVICE_UUID])
    }

    func centralManager(_ centralManager: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let peripheral = peripherals.first else {
            logger.warning("No restored peripherals!")
            return
        }

        guard let pumpManager = pumpManager else {
            logger.warning("Couldnt restore state, since no pumpManager is available...")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == PeripheralManager.SERVICE_UUID }) else {
            logger.warning("Couldnt restore state, since no service is available...")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        logger.info("Restoring state to: \(peripheral.identifier.uuidString)")
        let peripheralManager = PeripheralManager(peripheral, self, pumpManager) { reconnectResult in
            if let error = reconnectResult {
                self.logger.warning("Couldnt reconnect to pump: \(error)")
                return
            }

            self.logger.info("Reconnected to patch using restored state!")
        }

        self.peripheral = peripheral
        self.peripheralManager = peripheralManager

        peripheralManager.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("Device disconnected, name: \(peripheral.name ?? "<NO_NAME>"), error: \(error?.localizedDescription ?? "No error")")

        if let pumpManager = self.pumpManager {
            pumpManager.state.isConnected = false
            pumpManager.checkBolusDone()
            pumpManager.notifyStateDidChange()
        }

        if peripheralManager != nil {
            peripheralManager = nil
        }

        connectCompletion = nil
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.info("Device connect error, name: \(peripheral.name ?? "<NO_NAME>"), error: \(error?.localizedDescription ?? "No error")")

        guard let pumpManager = self.pumpManager else {
            return
        }

        pumpManager.state.isConnected = false
        pumpManager.notifyStateDidChange()
    }
}

import CoreBluetooth

class BluetoothManager: NSObject, CBCentralManagerDelegate {
    public var pumpManager: MedtrumPumpManager?

    let logger = MedtrumLogger(category: "BluetoothManager")

    var manager: CBCentralManager!
    let managerQueue = DispatchQueue(label: "com.nightscout.MedtrumKit.bluetoothManagerQueue", qos: .unspecified)

    private var peripheral: CBPeripheral?
    private var peripheralManager: PeripheralManager?
    private var forcedDisconnect: Bool = false

    private var scanCompletion: ((MedtrumScanResult) -> Void)?

    private var attempt: ConnectAttempt?

    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?

    // MUST NOT be called from within managerQueue - deadlock
    public var isConnected: Bool {
        managerQueue.sync { isConnectedOnQueue }
    }

    /// a live link alone is not yet a usable session
    private var isConnectedOnQueue: Bool {
        if let peripheral = peripheral, peripheral.state == .connected, peripheralManager?.isReady == true {
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

    private func startScan(_ completion: @escaping (_ result: MedtrumScanResult) -> Void) {
        if let pumpManager = self.pumpManager, pumpManager.state.pumpSN.isEmpty {
            completion(.failure(error: .noSerialNumberAvailable))
            return
        }
        guard manager.state == .poweredOn else {
            completion(.failure(error: .invalidBluetoothState(state: manager.state)))
            return
        }

        if manager.isScanning {
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

        // cancelling a pending connect does not always produce a didDisconnect
        forcedDisconnect = false

        self.peripheral = peripheral

        // a connect from an earlier attempt can still be pending
        guard peripheral.state != .connecting else {
            logger.info("Connect already pending, waiting on it")
            return
        }

        logger.info("Connecting to \(peripheral)")
        manager.connect(peripheral)
    }

    /// anything that mutates connection state must check this.
    private func isCurrent(_ candidate: CBPeripheral) -> Bool {
        candidate.identifier == peripheral?.identifier
    }

    /// Disconnects only if `manager` is still the one driving the link
    func disconnect(ifCurrent candidate: PeripheralManager) {
        managerQueue.async {
            guard self.peripheralManager === candidate else {
                return
            }

            self.disconnectOnQueue(force: false)
        }
    }

    /// Hands a result to a caller. Never on the current thread: completions issue blocking BLE
    /// writes: from the main thread that freezes the UI for up to 30s per packet (syncPumpTime
    /// sends three), and from managerQueue - which every caller of this is now on - it would
    /// deadlock outright, since that is the queue the response has to be delivered on.
    private func report(_ error: MedtrumConnectError?, to completion: @escaping (MedtrumConnectError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(error)
        }
    }

    /// Reports `attempt` to everyone waiting on it, if nobody has yet. Must be called on
    /// `managerQueue`.
    private func finish(_ attempt: ConnectAttempt, _ error: MedtrumConnectError?) {
        guard attempt.claim() else {
            return
        }

        if self.attempt === attempt {
            self.attempt = nil
        }

        if error == nil {
            reconnectAttempts = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            rememberPeripheral()
        } else {
            scheduleReconnect()
        }

        for completion in attempt.completions {
            report(error, to: completion)
        }
    }

    private func rememberPeripheral() {
        guard let pumpManager, let peripheral, pumpManager.state.peripheralIdentifier != peripheral.identifier else {
            return
        }

        pumpManager.state.peripheralIdentifier = peripheral.identifier
        pumpManager.notifyStateDidChange()
    }

    /// Must be called on `managerQueue`.
    private func scheduleReconnect() {
        // `ensureConnectedOnQueue` can retrieve the peripheral from stored identifier
        guard peripheral != nil || pumpManager?.state.peripheralIdentifier != nil else {
            // otherwise we would be retrying a scan, which doesn't work in the background
            return
        }

        let seconds: TimeInterval = reconnectAttempts == 0
            ? 0
            : min(TimeInterval(1 << min(reconnectAttempts, 6)), 60)
        reconnectAttempts += 1

        logger.info("Scheduling reconnect #\(reconnectAttempts) in \(Int(seconds))s")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                if Task.isCancelled {
                    return
                }
            }

            guard let self else {
                return
            }

            managerQueue.async {
                guard self.attempt == nil,
                      !self.isConnectedOnQueue,
                      self.peripheral != nil || self.pumpManager?.state.peripheralIdentifier != nil
                else {
                    return
                }

                self.ensureConnectedOnQueue { error in
                    if let error = error {
                        self.logger.warning("Failed to auto-reconnect: \(error)")
                    }
                }
            }
        }
    }

    func ensureConnected(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        managerQueue.async {
            self.ensureConnectedOnQueue(completion)
        }
    }

    private func ensureConnectedOnQueue(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        // Wait on the connect already in flight instead of failing. A connect owns the link for as
        // long as auth, synchronize and subscribe take, and anything the loop or the user asks for
        // in that window used to be turned away outright - a bolus issued in the same second as a
        // reconnect would fail while the link it needed came up moments later.
        if let inFlight = attempt {
            logger.debug("EnsureConnected is already running, waiting on it")
            inFlight.addCompletion(completion)
            return
        }

        let attempt = ConnectAttempt(completion)
        self.attempt = attempt

        if isConnectedOnQueue {
            logger.debug("Already connect!")
            finish(attempt, nil)
            return
        }

        if let peripheral = peripheral, peripheral.state == .connected {
            logger.warning("Connected but the session is not ready, dropping the link to rebuild it")
            startTimeout(attempt, seconds: .seconds(15))
            manager.cancelPeripheralConnection(peripheral)
            return
        }

        if let peripheral = peripheral {
            // We've the peripheral reference to a previous connection
            // Just try to reconnect
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        // We lost the reference but know which device we are paired with. Ask CoreBluetooth for it
        // back rather than scanning: a connect to a known peripheral is honoured in the background
        // (and stays pending until the pump is in range again), while a scan only ever discovers
        // anything while the app is in the foreground.
        if manager.state == .poweredOn,
           let identifier = pumpManager?.state.peripheralIdentifier,
           let peripheral = manager.retrievePeripherals(withIdentifiers: [identifier]).first
        {
            logger.info("Retrieved known peripheral \(identifier), reconnecting")
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        let connectedDevices = manager.retrieveConnectedPeripherals(withServices: [CBUUID.SERVICE_UUID])
        if let peripheral = connectedDevices.first(where: { $0.name == "MT" }) {
            // Phone is already connected, but the app is not
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        guard var pumpSNState = pumpManager?.state.pumpSN else {
            logger.error("No pump serial number found")
            finish(attempt, .failedToFindDevice)
            return
        }

        pumpSNState = Data(pumpSNState.reversed())

        // We are disconnected and have no reference to the previous connection
        // Start to scan for patch and reconnect the long way
        startTimeout(attempt, seconds: .seconds(15))
        startScan { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .failure(error):
                self.logger.error("Error during scanning: \(error.localizedDescription)")
                self.manager.stopScan()
                self.finish(attempt, .failedToFindDevice)

            case let .success(peripheral, pumpSN, _, _):
                guard pumpSN == pumpSNState else {
                    // Other patch pump found. IGNORE
                    return
                }

                self.connect(peripheral: peripheral)
            }
        }
    }

    /// Arms the deadline for `attempt`, replacing any deadline already on it. Called at each point
    /// the connect flow makes progress, so the allowance for waking up suspended starts over.
    private func startTimeout(_ attempt: ConnectAttempt, seconds: TimeInterval) {
        attempt.remainingExtensions = ConnectAttempt.maxExtensions
        armTimeout(attempt, seconds: seconds)
    }

    private func armTimeout(_ attempt: ConnectAttempt, seconds: TimeInterval) {
        attempt.timeout?.cancel()
        attempt.armedAt = .now
        attempt.timeoutGeneration &+= 1
        let generation = attempt.timeoutGeneration

        attempt.timeout = Task { [weak self, weak attempt] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            } catch {
                // Cancelled, because the attempt was reported before we woke
                return
            }

            guard let self else {
                return
            }

            managerQueue.async { [weak self, weak attempt] in
                // is this still the attempt in flight? Covers being superseded by a re-arm, and waking a moment before cancellation landed.
                guard let self, let attempt, self.attempt === attempt,
                      attempt.timeoutGeneration == generation
                else {
                    return
                }

                // `Task.sleep` is frozen while iOS has the app suspended, so waking far past the budget
                // means we were asleep for most of it rather than waiting on a pump that never answered
                // - and we typically wake because the connection we were waiting for just arrived. Give
                // the attempt the budget it never got instead of failing a connect that may be landing
                // in this very instant. Bounded, so a phone that keeps suspending still terminates.
                let elapsed = Date.now.timeIntervalSince(attempt.armedAt)
                if elapsed > seconds * 2, attempt.remainingExtensions > 0 {
                    attempt.remainingExtensions -= 1
                    self.logger
                        .warning(
                            "Timeout woke after \(Int(elapsed))s of a \(Int(seconds))s budget - app was suspended, re-arming"
                        )
                    self.armTimeout(attempt, seconds: seconds)
                    return
                }

                // Don't skip this just because the peripheral is connected by now: the link coming up
                // is not the same as being ready, since auth, synchronize and subscribe still follow.
                // Skipping would leave the attempt in flight with nothing to clear it, wedging every
                // later ensureConnected. didConnect re-arms us on a longer budget.
                self.logger.error("Failed to connect: Timeout reached...")

                if self.manager.isScanning {
                    self.manager.stopScan()
                    self.scanCompletion = nil
                }

                self.finish(attempt, .failedToConnectToDevice)
            }
        }
    }

    func write(_ packet: any MedtrumBasePacketProtocol) -> MedtrumWriteResult<Any> {
        // Only the lookup is serialised. writePacket blocks for up to 30s waiting for a response
        // that is delivered on managerQueue, so it must not be holding the queue while it waits.
        guard let peripheralManager = managerQueue.sync(execute: { self.peripheralManager }) else {
            return .failure(error: .noManager)
        }

        return peripheralManager.writePacket(packet)
    }

    func disconnect(force: Bool = false) {
        managerQueue.async {
            self.disconnectOnQueue(force: force)
        }
    }

    private func disconnectOnQueue(force: Bool) {
        // forcedDisconnect is set to true only here, normal disconnects should not abort the force disconnect
        if force {
            forcedDisconnect = true
        }

        // both .connected AND .connecting
        if let peripheral, peripheral.state != .disconnected {
            manager.cancelPeripheralConnection(peripheral)
        }

        if force {
            clearPeripheralOnQueue()
        }
    }

    /// Forgets the device entirely - used when the patch is deactivated and when the pump base is
    /// swapped for another one. It also drops the stored identifier, so the next connect has to
    /// find the base by scanning, which is fine: both of those are foreground activities.
    func clearPeripheral() {
        managerQueue.async {
            self.clearPeripheralOnQueue()
        }
    }

    private func clearPeripheralOnQueue() {
        if manager.isScanning {
            manager.stopScan()
        }
        scanCompletion = nil

        pumpManager?.state.isConnected = false

        peripheral = nil
        // didDisconnectPeripheral returns early on a forced disconnect, so this is the only place
        // the forced path can invalidate the manager - releasing it is not enough, its auth/sync
        // worker holds its own reference and would keep writing to pumpManager.state.
        peripheralManager?.cleanup()
        peripheralManager = nil

        if pumpManager?.state.peripheralIdentifier != nil {
            pumpManager?.state.peripheralIdentifier = nil
            pumpManager?.notifyStateDidChange()
        }

        if let attempt = attempt {
            finish(attempt, .failedToFindDevice)
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
    }
}

extension BluetoothManager {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("\(String(describing: central.state.rawValue))")

        guard central.state == .poweredOn else {
            return
        }

        guard attempt == nil else {
            // Somebody is already connecting and owns the attempt. Installing ours over it would
            // strand that caller - they would never be called back at all.
            logger.info("Powered on while a connect attempt is in flight, leaving it be")
            return
        }

        if let peripheral = self.peripheral {
            logger.info("Reconnecting to restored state...")

            let attempt = ConnectAttempt { [weak self] (error: MedtrumConnectError?) in
                if let error = error {
                    self?.logger.error("Failed to restore state: \(error)")
                } else {
                    self?.logger.info("Restored state!")
                }
            }
            self.attempt = attempt

            // Without this the restore path has no deadline at all: a connect that never completes
            // leaves the attempt in flight for good, and every later ensureConnected fails.
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        if !isConnectedOnQueue, pumpManager?.state.pumpState == .active {
            ensureConnectedOnQueue { error in
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
            // Simulator bypass -> 200u
            scanCompletion?(
                .success(
                    peripheral: peripheral,
                    pumpSN: Data([0x28, 0xD8, 0x12, 0x4A]),
                    deviceType: 1,
                    version: 1
                )
            )
            // Simulator bypass -> 300u
            scanCompletion?(
                .success(
                    peripheral: peripheral,
                    pumpSN: Data([0x14, 0x16, 0xDF, 0x52]),
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

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to pump: \(peripheral.name ?? "<NO_NAME>")!")

        if forcedDisconnect {
            logger.info("Dropping a connection that landed after a forced disconnect")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        guard isCurrent(peripheral) else {
            logger.info("Dropping a connection for a peripheral we are not driving")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        // A real reconnect passes through didDisconnect first, which cleans the manager up - so a
        // ready session here means this callback is a duplicate.
        if peripheralManager?.isReady == true {
            logger.info("Ignoring duplicate didConnect - session already established")
            return
        }

        // This guard drops the link rather than just returning. `peripheral` is already set at this
        // point, so bailing out would leave a live peripheral with no PeripheralManager behind it:
        // the next ensureConnected reports "Already connect!" while every write fails with
        // .noManager, and nothing clears that until the link happens to drop on its own.
        guard let pumpManager = pumpManager else {
            logger.warning("No pumpManager...")
            disconnectOnQueue(force: true)
            return
        }

        // The attempt this belongs to already gave up - typically its deadline fired while the app
        // was suspended, in the same instant the link finally came up. Do not throw the connection
        // away: reconnecting to a known peripheral is the only thing that works while backgrounded,
        // and dropping it here strands us on the scan path, which does not. Nobody is waiting on
        // the result any more, so adopt it under an attempt of our own and finish the flow.
        let attempt: ConnectAttempt
        if let inFlight = self.attempt {
            attempt = inFlight
        } else {
            logger.info("No connectCompletion, adopting the connection anyway")

            attempt = ConnectAttempt { [weak self] (error: MedtrumConnectError?) in
                if let error = error {
                    self?.logger.error("Failed to complete adopted connection: \(error)")
                } else {
                    self?.logger.info("Adopted connection is ready")
                }
            }
            self.attempt = attempt
        }

        forcedDisconnect = false

        self.peripheral = peripheral

        peripheralManager?.cleanup()
        peripheralManager = PeripheralManager(peripheral, self, pumpManager) { [weak self] error in
            // Called from two queues: the CBPeripheralDelegate callbacks report discovery failures
            // on managerQueue, while the auth flow runs on a global worker and reports from there.
            // Land both on managerQueue, since that is where finish reads and clears the attempt.
            self?.managerQueue.async {
                self?.finish(attempt, error)
            }
        }

        // The link is up but the flow is not done - auth, synchronize and subscribe still have to
        // run, and each of those is a writePacket with its own 30s timeout. Re-arm on a budget that
        // covers all of them, so a stalled flow still reports back instead of hanging the caller.
        startTimeout(attempt, seconds: .seconds(150))

        peripheral.discoverServices([CBUUID.SERVICE_UUID])
    }

    func centralManager(_ centralManager: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let peripheral = peripherals.first else {
            logger.warning("No restored peripherals!")
            return
        }

        if peripheral.services?.first(where: { $0.uuid == CBUUID.SERVICE_UUID }) == nil {
            logger.warning("Couldnt restore state, since no service is available...")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        self.peripheral = peripheral
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger
            .info(
                "Device disconnected, name: \(peripheral.name ?? "<NO_NAME>"), error: \(error?.localizedDescription ?? "No error")"
            )

        guard isCurrent(peripheral) else {
            logger.info("Ignoring disconnect for a peripheral we are not driving")
            return
        }

        if forcedDisconnect {
            forcedDisconnect = false
            return
        }

        if let pumpManager = self.pumpManager {
            pumpManager.state.isConnected = false
            pumpManager.notifyStateDidChange()
        }

        if let peripheralManager = peripheralManager {
            peripheralManager.cleanup()
            self.peripheralManager = nil
        }

        if let attempt = attempt {
            logger.info("Disconnected during the connect sequence")
            finish(attempt, .failedToConnectToDevice)
        } else {
            scheduleReconnect()
        }
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger
            .info(
                "Device connect error, name: \(peripheral.name ?? "<NO_NAME>"), error: \(error?.localizedDescription ?? "No error")"
            )

        guard isCurrent(peripheral) else {
            logger.info("Ignoring connect error for a peripheral we are not driving")
            return
        }

        if let pumpManager = self.pumpManager {
            pumpManager.state.isConnected = false
            pumpManager.notifyStateDidChange()
        }

        // The attempt is over, so report it now. Leaving it to the timeout means the caller waits
        // out the full budget for a failure we already know about.
        if let attempt = attempt {
            finish(attempt, .failedToConnectToDevice)
        }
    }
}

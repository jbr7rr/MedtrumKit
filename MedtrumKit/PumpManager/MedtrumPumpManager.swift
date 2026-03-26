import CoreBluetooth
import HealthKit
import LoopKit

public class MedtrumPumpManager: DeviceManager {
    public static let pluginIdentifier = "Medtrum"
    public var localizedTitle: String {
        LocalizedString("Medtrum TouchCare Nano", comment: "Generic title of the Medtrum pump manager")
    }

    public let managerIdentifier: String = "Medtrum"

    private let log = MedtrumLogger(category: "MedtrumPumpManager")

    public let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    public var state: MedtrumPumpState
    var oldState: MedtrumPumpState
    public var rawState: PumpManager.RawStateValue {
        state.rawValue
    }

    let bluetooth: BluetoothManager
    init(state: MedtrumPumpState) {
        self.state = state
        oldState = MedtrumPumpState(rawValue: state.rawValue)
        bluetooth = BluetoothManager()

        bluetooth.pumpManager = self
    }

    public required convenience init?(rawState: RawStateValue) {
        self.init(state: MedtrumPumpState(rawValue: rawState))
    }

    public var isOnboarded: Bool {
        state.isOnboarded
    }

    public static var onboardingMaximumBasalScheduleEntryCount: Int {
        48
    }

    public static var onboardingSupportedBasalRates: [Double] {
        // During onboard, we assume 300u -> 0.00-30U/hr
        // 0 U/hr is a supported scheduled basal rate
        (0 ... 600).map { Double($0) / 20 }
    }

    public static var onboardingSupportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U
        // 0 is not a supported bolus volume
        (1 ... 600).map { Double($0) / 20 }
    }

    public static var onboardingSupportedMaximumBolusVolumes: [Double] {
        MedtrumPumpManager.onboardingSupportedBolusVolumes
    }

    public var delegateQueue: DispatchQueue! {
        get {
            pumpDelegate.queue
        }
        set {
            pumpDelegate.queue = newValue
        }
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        // We do support rounding down to 0.00u
        supportedBolusVolumes.last(where: { $0 <= units }) ?? 0
    }

    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        supportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    public var supportedBasalRates: [Double] {
        guard !state.pumpSN.isEmpty else {
            return MedtrumPumpManager.onboardingSupportedBasalRates
        }

        // 300U -> 0.05-30U
        // 200U -> 0.05-25U
        return state.pumpName.contains("300U") ? MedtrumPumpManager.onboardingSupportedBasalRates : (0 ... 500)
            .map { Double($0) / 20 }
    }

    public var supportedBolusVolumes: [Double] {
        MedtrumPumpManager.onboardingSupportedBolusVolumes
    }

    public var supportedMaximumBolusVolumes: [Double] {
        MedtrumPumpManager.onboardingSupportedBolusVolumes
    }

    public var maximumBasalScheduleEntryCount: Int {
        MedtrumPumpManager.onboardingMaximumBasalScheduleEntryCount
    }

    public var minimumBasalScheduleEntryDuration: TimeInterval {
        TimeInterval(minutes: 30)
    }

    public var debugDescription: String {
        state.debugDescription
    }

    public func acknowledgeAlert(alertIdentifier _: LoopKit.Alert.AlertIdentifier, completion: @escaping ((any Error)?) -> Void) {
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? {
        nil
    }

    public func getSounds() -> [LoopKit.Alert.Sound] {
        []
    }

    public var pumpManagerDelegate: LoopKit.PumpManagerDelegate? {
        get {
            pumpDelegate.delegate
        }
        set {
            pumpDelegate.delegate = newValue
        }
    }

    private func device(_ state: MedtrumPumpState) -> HKDevice {
        HKDevice(
            name: state.pumpName,
            manufacturer: "Medtrum",
            model: state.model,
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: state.swVersion,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
    }
}

public extension MedtrumPumpManager {
    var pumpRecordsBasalProfileStartEvents: Bool {
        false
    }

    var pumpReservoirCapacity: Double {
        state.model == "MD8301" ? 300 : 200
    }

    var lastSync: Date? {
        state.lastSync
    }

    var status: PumpManagerStatus {
        self.status(state)
    }

    private func status(_ state: MedtrumPumpState) -> PumpManagerStatus {
        PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(state),
            pumpBatteryChargeRemaining: nil, // Patch pumps do not need to report back battery status
            basalDeliveryState: state.basalDeliveryState,
            bolusState: bolusState(state.bolusState),
            insulinType: state.insulinType
        )
    }

    private func bolusState(_ bolusState: BolusState) -> PumpManagerStatus.BolusState {
        switch bolusState {
        case .noBolus:
            return .noBolus
        case .canceling:
            return .canceling
        case .inProgress:
            if let dose = state.doseEntry?.toDoseEntry(isMutable: true) {
                return .inProgress(dose)
            }

            return .noBolus
        }
    }

    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        guard let activatedAt = state.patchActivatedAt,
              Date.now.timeIntervalSince(state.lastSync) > .minutes(4) ||
              Date.now.timeIntervalSince(activatedAt) < .minutes(4)
        else {
            log.warning("Skipping status update -> data is fresh: \(Date.now.timeIntervalSince(state.lastSync)) sec")
            completion?(nil)
            return
        }

        guard state.pumpState.rawValue >= PatchState.active.rawValue else {
            log.error("(ensureCurrentPumpData) patch not in active state yet")
            completion?(nil)
            return
        }

        syncPumpData(completion: completion)
    }

    func syncPumpData(completion: ((Date?) -> Void)?) {
        log.info("Sync pump data")

        #if targetEnvironment(simulator)
            pumpDelegate.notify { delegate in
                self.state.reservoir = Double(Int.random(in: 10 ..< 200))
                if self.state.initialReservoir == nil {
                    self.state.initialReservoir = self.state.reservoir
                }

                delegate?.pumpManager(self, didReadReservoirValue: self.state.reservoir, at: Date.now) { _ in }

                self.state.lastSync = Date.now
                self.notifyStateDidChange()

                completion?(nil)
            }
            return
        #endif

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion?(nil)
                return
            }

            let syncResult = await self.bluetooth.write(SynchronizePacket())
            await StateSyncer.timeSync(pumpManager: self)

            switch syncResult {
            case let .failure(error):
                self.log.error("Failed to write: \(error.localizedDescription)")
                completion?(nil)
                return

            case let .success(data):
                guard let syncResponse = data as? SynchronizePacketResponse else {
                    self.log.error("Invalid response data...")
                    completion?(nil)
                    return
                }

                do {
                    self.log.info("Manual sync: \(String(data: try JSONEncoder().encode(syncResponse), encoding: .utf8) ?? "")")
                } catch {
                    self.log.warning("State update: Failed to encode JSON")
                }

                self.state.lastSync = Date.now
                self.notifyStateDidChange()

                StateSyncer.sync(
                    syncResponse: syncResponse,
                    state: self.state,
                    pumpManager: self,
                    duringReconnect: false
                )

                self.pumpDelegate.notify { delegate in
                    delegate?.pumpManager(
                        self,
                        didReadReservoirValue: self.state.reservoir.rounded(toPlaces: 1),
                        at: self.state.lastSync
                    ) { result in
                        switch result {
                        case let .failure(error):
                            self.handlePumpDelegateError(method: "didReadReservoirValue", error)
                        case .success:
                            break
                        }
                    }
                }

                completion?(Date.now)
            }
        }
    }

    func setMustProvideBLEHeartbeat(_: Bool) {}

    func createBolusProgressReporter(reportingOn: DispatchQueue) -> (any LoopKit.DoseProgressReporter)? {
        if let doseEntry = state.doseEntry {
            return MedtrumDoseProgressReporter(
                pumpManager: self,
                dose: doseEntry,
                reportingQueue: reportingOn
            )
        }

        return nil
    }

    func estimatedDuration(toBolus units: Double) -> TimeInterval {
        // 1.5 unit per minute
        units / 1.5 * TimeInterval(minutes: 1)
    }

    func enactBolus(
        units: Double,
        activationType: LoopKit.BolusActivationType,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        guard state.bolusState == .noBolus else {
            log.error("Pump is in bolus state...")
            completion(.deviceState(MedtrumConnectError.isBolussing))
            return
        }

        let duration = estimatedDuration(toBolus: units)
        log.info("Enact bolus - \(units)U, \(duration)sec")

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                self.resetBolusState()

                completion(.communication(error))
                return
            }

            let bolusPacket = SetBolusPacket(bolusAmount: units)
            let writeResult = await self.bluetooth.write(bolusPacket)

            if case let .failure(error) = writeResult {
                self.log.error("Failed to write: \(error.localizedDescription)")
                self.resetBolusState()

                completion(.communication(error))
                return
            }

            let doseEntry = UnfinalizedDose(
                units: units,
                duration: duration,
                activationType: activationType,
                insulinType: self.state.insulinType
            )

            self.pumpDelegate.notify { delegate in
                guard let delegate = delegate else {
                    self.log.error("Dose could not be reported -> Missing delegate")
                    return
                }

                let dose = doseEntry.toDoseEntry(isMutable: true)
                let event = NewPumpEvent.bolus(
                    dose: dose,
                    units: dose.programmedUnits,
                    date: dose.startDate
                )
                delegate.pumpManager(
                    self,
                    hasNewPumpEvents: [event],
                    lastReconciliation: self.state.lastSync,
                    replacePendingEvents: false,
                ) { error in
                    if let error = error {
                        self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                    }
                }
            }

            self.state.doseEntry = doseEntry
            self.state.bolusState = .inProgress
            self.notifyStateDidChange()

            completion(nil)
        }
    }

    private func resetBolusState() {
        state.bolusState = .noBolus
        state.doseEntry = nil
        notifyStateDidChange()
    }

    func cancelBolus(completion: @escaping (LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) -> Void) {
        log.info("Cancelling bolus...")

        let oldBolusState = state.bolusState
        state.bolusState = .canceling
        notifyStateDidChange()

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                self.state.bolusState = oldBolusState
                self.notifyStateDidChange()

                completion(.failure(.communication(error)))
                return
            }

            let packet = CancelBolusPacket()
            let result = await self.bluetooth.write(packet)

            if case let .failure(error) = result {
                self.log.error("Failed to cancel bolus: \(error.localizedDescription)")
                self.state.bolusState = oldBolusState
                self.notifyStateDidChange()

                completion(.failure(.communication(error)))
                return
            }

            self.log.info("Bolus cancelled!")
            self.state.bolusState = .noBolus
            self.notifyStateDidChange()

            guard let doseEntry = self.state.doseEntry else {
                completion(.success(nil))
                return
            }

            let dose = doseEntry.toDoseEntry()
            var events = [NewPumpEvent.bolus(dose: dose, units: dose.deliveredUnits ?? 0, date: dose.startDate)]
            if let tempBasalEvent = self.getTempBasalEvent(endDate: Date.now) {
                events.append(tempBasalEvent)
            }

            self.state.doseEntry = nil
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: events,
                    lastReconciliation: self.state.lastSync,
                    replacePendingEvents: true,
                ) { error in
                    if let error = error {
                        self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                    }
                }
            }

            self.notifyStateDidChange()
            completion(.success(nil))
        }
    }

    func enactTempBasal(
        unitsPerHour: Double,
        for duration: TimeInterval,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        log.info("Setting temp basal at \(unitsPerHour)U/hr for \(duration) seconds...")

        guard state.bolusState == .noBolus else {
            log.error("Pump is in bolus state...")
            completion(.deviceState(MedtrumConnectError.isBolussing))
            return
        }

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(.communication(error))
                return
            }

            if case .tempBasal = self.state.basalState {
                // Need to cancel temp basal first before setting temp basal
                let cancelPacket = CancelTempBasalPacket()
                let cancelResult = await self.bluetooth.write(cancelPacket)

                if case let .failure(error) = cancelResult {
                    self.log.error("Failed to cancel temp basal: \(error.localizedDescription)")
                    completion(.communication(error))
                    return
                }

                self.log.info("Cancelled temp basal!")
            }

            if duration < .ulpOfOne {
                // Need to cancel temp basal, but is already cancelled
                // Only need to report back to algorithm
                let startDate = Date.now
                var events = [
                    NewPumpEvent.basal(
                        dose: DoseEntry.basal(
                            rate: self.state.currentBaseBasalRate,
                            insulinType: self.state.insulinType,
                            startDate: startDate
                        ),
                        date: startDate
                    )
                ]

                if let tempBasalEvent = self.getTempBasalEvent(endDate: Date.now) {
                    events.append(tempBasalEvent)
                }

                self.state.lastSync = Date.now
                self.state.basalState = .active
                self.state.basalStateSince = Date.now
                self.state.tempBasalUnits = nil
                self.state.tempBasalDuration = nil
                self.notifyStateDidChange()

                self.pumpDelegate.notify { delegate in
                    delegate?.pumpManager(
                        self,
                        hasNewPumpEvents: events,
                        lastReconciliation: self.state.lastSync,
                        replacePendingEvents: true,
                    ) { error in
                        if let error = error {
                            self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                        }
                    }
                }

                completion(nil)
                return
            }

            let packet = SetTempBasalPacket(rate: unitsPerHour, duration: duration)
            let tempBasalResult = await self.bluetooth.write(packet)

            if case let .failure(error) = tempBasalResult {
                self.log.error("Failed to set temp basal: \(error.localizedDescription)")
                completion(.communication(error))
                return
            }

            self.log.info("Set temp basal!")

            let startDate = Date.now
            var events = [
                NewPumpEvent.tempBasal(
                    dose: DoseEntry.tempBasal(
                        absoluteUnit: unitsPerHour,
                        duration: duration,
                        insulinType: self.state.insulinType,
                        startDate: startDate
                    ),
                    date: startDate
                )
            ]

            if let tempBasalEvent = self.getTempBasalEvent(endDate: Date.now) {
                events.append(tempBasalEvent)
            }

            self.state.basalState = .tempBasal
            self.state.basalStateSince = startDate
            self.state.tempBasalUnits = unitsPerHour
            self.state.tempBasalDuration = duration
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: events,
                    lastReconciliation: self.state.lastSync,
                    replacePendingEvents: true,
                ) { error in
                    if let error = error {
                        self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                    }
                }
            }

            completion(nil)
        }
    }

    func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        log.info("Suspending delivery...")

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error)
                return
            }

            // TODO: suspend needs to have configurable duration
            let packet = SuspendPumpPacket(duration: .minutes(120))
            let result = await self.bluetooth.write(packet)

            if case let .failure(error) = result {
                self.log.error("Failed to suspend delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            self.log.info("Delivery suspended for 120min!")

            let start = Date.now
            var events = [NewPumpEvent.suspend(dose: DoseEntry.suspend(suspendDate: start))]
            if let tempBasalEvent = self.getTempBasalEvent(endDate: start) {
                events.append(tempBasalEvent)
            }

            self.state.basalState = .suspended
            self.state.basalStateSince = Date.now
            self.state.tempBasalUnits = nil
            self.state.tempBasalDuration = nil
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: events,
                    lastReconciliation: self.state.lastSync,
                    replacePendingEvents: true,
                ) { error in
                    if let error = error {
                        self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                    }
                }
            }

            completion(nil)
        }
    }

    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        log.info("Suspending delivery...")

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error)
                return
            }

            let packet = ResumePumpPacket()
            let response = await self.bluetooth.write(packet)

            if case let .failure(error) = response {
                self.log.error("Failed to resume delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            self.log.info("Resumed delivery!")

            let start = Date.now
            let events = [
                NewPumpEvent.resume(
                    dose: DoseEntry.resume(insulinType: self.state.insulinType, resumeDate: start),
                    date: start
                ),
                NewPumpEvent.basal(
                    dose: DoseEntry.basal(
                        rate: self.state.currentBaseBasalRate,
                        insulinType: self.state.insulinType,
                        startDate: start
                    ),
                    date: start
                )
            ]

            self.state.basalState = .active
            self.state.basalStateSince = Date.now
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: events,
                    lastReconciliation: self.state.lastSync,
                    replacePendingEvents: true,
                ) { error in
                    if let error = error {
                        self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                    }
                }
            }

            completion(nil)
        }
    }

    func syncBasalRateSchedule(
        items: [LoopKit.RepeatingScheduleValue<Double>],
        completion: @escaping (Result<LoopKit.BasalRateSchedule, any Error>) -> Void
    ) {
        log.info("Sync-ing basal schedule...")
        guard let basalSchedule = DailyValueSchedule<Double>(dailyItems: items) else {
            completion(.failure(NSError(domain: "Basal schedule is empty...", code: -1)))
            return
        }

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            let schedule = BasalSchedule(entries: items)
            let packet = SetBasalProfilePacket(basalProfile: schedule.toData())
            let result = await self.bluetooth.write(packet)

            if case let .failure(error) = result {
                self.log.error("Failed to sync basal schedule: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            self.state.basalSchedule = schedule
            self.log.info("Basal schedule sync complete!")

            let dose = DoseEntry.basal(rate: self.state.currentBaseBasalRate, insulinType: self.state.insulinType)
            var events = [NewPumpEvent.basal(dose: dose)]
            if let tempBasalEvent = self.getTempBasalEvent() {
                events.append(tempBasalEvent)
            }

            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: [],
                    lastReconciliation: self.state.lastSync,
                    replacePendingEvents: true,
                ) { error in
                    if let error = error {
                        self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                    }
                }
            }

            completion(.success(basalSchedule))
        }
    }

    func syncDeliveryLimits(
        limits: LoopKit.DeliveryLimits,
        completion: @escaping (Result<LoopKit.DeliveryLimits, any Error>) -> Void
    ) {
        log.warning("Skipping sync delivery limits (not supported by Medtrum)")
        completion(.success(limits))
    }

    func primePatch(_ completion: @escaping (MedtrumPrimePatchResult) -> Void) {
        log.info("Start priming patch...")

        if state.pumpSN.isEmpty {
            // Need to scan for pump base first
            log.warning("No pump base known yet...")
            completion(.failure(error: .noKnownPumpBase))
            return
        }

        if state.sessionToken.isEmpty {
            log.debug("Refreshing session token...")

            // Patch has been disabled and thus a new session token is needed
            state.sessionToken = Crypto.genSessionToken()
            notifyStateDidChange()
        }

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure(reason: error.errorDescription ?? "EMPTY")))
                return
            }

            guard self.state.pumpState.rawValue < PatchState.priming.rawValue else {
                self.log.info("Patch already activated!")
                completion(.success)
                return
            }

            let packet = PrimePacket()
            let primeResult = await self.bluetooth.write(packet)
            if case let .failure(error) = primeResult {
                self.log.error("Failed to start priming pump: \(error)")
                completion(.failure(error: .unknownError(reason: error)))
                return
            }

            self.log.info("Priming has started!")
            completion(.success)
        }
    }

    func activatePatch(_ completion: @escaping (MedtrumActivatePatchResult) -> Void) {
        log.info("Activate patch pump...")

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure(reason: error.errorDescription ?? "EMPTY")))
                return
            }

            guard self.state.pumpState.rawValue < PatchState.active.rawValue else {
                self.log.info("Patch already activated!")
                completion(.success)
                return
            }

            await StateSyncer.syncTime(pumpManager: self)

            let packet = ActivatePacket(
                expirationTimer: self.state.expirationTimer,
                alarmSetting: self.state.alarmSetting,
                hourlyMaxInsulin: self.state.maxHourlyInsulin,
                dailyMaxInsulin: self.state.maxDailyInsulin,
                currentTDD: 0,
                basalProfile: self.state.basalSchedule.toData()
            )
            let result = await self.bluetooth.write(packet)
            switch result {
            case let .failure(error):
                self.log.error("Failed to activate pump: \(error)")
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return

            case let .success(data):
                guard let data = data as? ActivatePacketResponse else {
                    self.log.error("Failed to parse response...")
                    completion(.failure(error: .unknownError(reason: "Failed to parse response...")))
                    return
                }

                if self.state.expirationTimer == 1 {
                    NotificationManager.activatePatchExpiredNotification(after: self.state.notificationAfterActivation)
                }

                let start = Date.now
                let events = [
                    NewPumpEvent.replacedPump(date: start),
                    NewPumpEvent.resume(
                        dose: DoseEntry.resume(insulinType: self.state.insulinType, resumeDate: start),
                        date: start
                    ),
                    NewPumpEvent.basal(
                        dose: DoseEntry.basal(
                            rate: self.state.currentBaseBasalRate,
                            insulinType: self.state.insulinType,
                            startDate: start
                        ),
                        date: start
                    )
                ]

                self.state.initialReservoir = nil
                self.state.patchId = data.patchId
                self.state.patchActivatedAt = Date.now
                self.state.lastSync = Date.now
                self.notifyStateDidChange()

                self.pumpDelegate.notify { delegate in
                    delegate?.pumpManager(
                        self,
                        hasNewPumpEvents: events,
                        lastReconciliation: self.state.lastSync,
                        replacePendingEvents: true,
                    ) { error in
                        if let error = error {
                            self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                        }
                    }
                    delegate?.pumpManagerPumpWasReplaced(self)
                }

                self.log.info("Patch activated!")
                completion(.success)
                return
            }
        }
    }

    func deactivatePatch(_ completion: @escaping (MedtrumDeactivatePatchResult) -> Void) {
        log.info("Deactivate patch pump...")

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }

            let package = StopPatchPacket()
            let result = await self.bluetooth.write(package)
            if case let .failure(error) = result {
                self.log.error("Failed to deactivate pump: \(error)")
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return
            }

            self.state.previousPatch = PreviousPatch(
                patchId: self.state.patchId,
                lastStateRaw: self.state.pumpState.rawValue,
                lastSyncAt: self.state.lastSync,
                battery: self.state.battery,
                activatedAt: self.state.patchActivatedAt ?? Date.distantPast,
                deactivatedAt: Date.now,
                initialReservoirLevel: self.state.initialReservoir,
                reservoirLevel: self.state.reservoir
            )

            var events = [NewPumpEvent.suspend(dose: DoseEntry.suspend())]
            if let tempBasalEvent = self.getTempBasalEvent(endDate: Date.now) {
                events.append(tempBasalEvent)
            }

            self.state.patchId = Data()
            self.state.pumpState = .none
            self.state.sessionToken = Data()
            self.state.lastSync = Date.now
            self.state.basalState = .active
            self.state.basalStateSince = Date.now
            self.state.tempBasalUnits = nil
            self.state.tempBasalDuration = nil
            self.notifyStateDidChange()

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: events,
                    lastReconciliation: self.state.lastSync,
                    replacePendingEvents: true,
                ) { error in
                    if let error = error {
                        self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                    }
                }
            }

            self.log.info("Patch deactivated")
            completion(.success)
        }
    }

    func forceDeactivatePatch() {
        var events = [NewPumpEvent.suspend(dose: DoseEntry.suspend())]
        if let tempBasalEvent = getTempBasalEvent(endDate: Date.now) {
            events.append(tempBasalEvent)
        }

        state.previousPatch = PreviousPatch(
            patchId: state.patchId,
            lastStateRaw: state.pumpState.rawValue,
            lastSyncAt: state.lastSync,
            battery: state.battery,
            activatedAt: state.patchActivatedAt ?? Date.distantPast,
            deactivatedAt: Date.now,
            initialReservoirLevel: state.initialReservoir,
            reservoirLevel: state.reservoir
        )

        state.patchId = Data()
        state.pumpState = .none
        state.sessionToken = Data()
        state.lastSync = Date.now
        state.basalState = .active
        state.basalStateSince = Date.now
        state.tempBasalUnits = nil
        state.tempBasalDuration = nil
        notifyStateDidChange()

        pumpDelegate.notify { delegate in
            delegate?.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: true,
            ) { error in
                if let error = error {
                    self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                }
            }
        }
    }

    func updatePatchSettings(completion: @escaping (MedtrumUpdatePatchResult) -> Void) {
        log.info("Update patch settings...")

        bluetooth.ensureConnected { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }

            let package = SetPatchPacket(
                alarmSettings: self.state.alarmSetting,
                hourlyMaxInsulin: self.state.maxHourlyInsulin,
                dailyMaxInsulin: self.state.maxDailyInsulin,
                expirationTimer: self.state.expirationTimer
            )
            let result = await self.bluetooth.write(package)
            if case let .failure(error) = result {
                self.log.error("Failed to update settings: \(error)")
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return
            }

            self.log.info("Patch settings updated!")
            completion(.success)
        }
    }

    func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    func notifyStateDidChange() {
        DispatchQueue.main.async {
            let status = self.status(self.state)
            let oldStatus = self.status(self.oldState)

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManagerDidUpdateState(self)
                delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            self.statusObservers.forEach { observer in
                observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            self.oldState = MedtrumPumpState(rawValue: self.state.rawValue)
        }
    }

    func updateBolusProgress(delivered: Double, completed: Bool, useEstimatedEndDate: Bool) {
        guard let doseEntry = state.doseEntry else {
            return
        }

        doseEntry.deliveredUnits = delivered

        if !completed {
            notifyStateDidChange()
            return
        }

        state.bolusState = .noBolus
        let dose = doseEntry.toDoseEntry(useEstimatedEndDate: useEstimatedEndDate)
        var events = [
            NewPumpEvent.bolus(
                dose: dose,
                units: dose.programmedUnits,
                date: dose.startDate
            )
        ]
        if let tempBasalEvent = getTempBasalEvent() {
            events.append(tempBasalEvent)
        }

        state.doseEntry = nil
        state.lastSync = Date.now
        notifyStateDidChange()

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                return
            }

            delegate.pumpManager(
                self,
                didReadReservoirValue: self.state.reservoir.rounded(toPlaces: 1),
                at: self.state.lastSync
            ) { result in
                switch result {
                case let .failure(error):
                    self.handlePumpDelegateError(method: "didReadReservoirValue", error)
                case .success:
                    break
                }
            }
            delegate.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: true
            ) { error in
                if let error = error {
                    self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                }
            }
        }
    }

    func checkBolusDone() {
        guard let doseEntry = state.doseEntry else {
            // No bolus was in progress during disconnect
            return
        }

        log.warning("Bolus was not completed... \(doseEntry.deliveredUnits) U of the \(doseEntry.value) U")

        // We assume the bolus has completed, but did not receive completed event
        // due to being disconnected for too long
        doseEntry.deliveredUnits = doseEntry.value
        let dose = doseEntry.toDoseEntry(useEstimatedEndDate: true)
        var events = [
            NewPumpEvent.bolus(
                dose: dose,
                units: dose.programmedUnits,
                date: dose.startDate
            )
        ]
        if let tempBasalEvent = getTempBasalEvent() {
            events.append(tempBasalEvent)
        }

        state.bolusState = .noBolus
        state.lastSync = Date.now
        state.doseEntry = nil
        notifyStateDidChange()

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
            delegate.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: true
            ) { error in
                if let error = error {
                    self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                }
            }
        }
    }

    private func handlePumpDelegateError(method: String, _ error: Error, _ function: String = #function, _ line: Int = #line) {
        let logLine = "Received pump delegate error in \(method): \(error) at \(function):\(line)"
        log.error(logLine)
        logDeviceCommunication(logLine, type: .error)
    }

    internal func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        // Not dispatching here; if delegate queue is blocked, timestamps will be delayed
        pumpManagerDelegate?.deviceManager(
            self,
            logEventForDeviceIdentifier: state.pumpSN.hexEncodedString(),
            type: type,
            message: message,
            completion: nil
        )
    }

    private func getTempBasalEvent(endDate: Date? = nil) -> NewPumpEvent? {
        guard state.basalState == .tempBasal,
              let unitsPerHour = state.tempBasalUnits,
              let duration = state.tempBasalDuration
        else {
            return nil
        }

        return NewPumpEvent.tempBasal(
            dose: DoseEntry.tempBasal(
                absoluteUnit: unitsPerHour,
                duration: duration,
                insulinType: state.insulinType,
                startDate: state.basalStateSince,
                endDate: endDate
            ),
            date: state.basalStateSince
        )
    }
}

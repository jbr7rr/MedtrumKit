import HealthKit
import CoreBluetooth
import LoopKit

public class MedtrumPumpManager: DeviceManager {
    public static let pluginIdentifier = "Medtrum"
    public let localizedTitle = LocalizedString("Medtrum", comment: "Generic title of the Medtrum pump manager")
    public let managerIdentifier: String = "MedtrumKit"

    private let log = MedtrumLogger(category: "MedtrumPumpManager")
    
    public let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()
    
    var state: MedtrumPumpState
    var oldState: MedtrumPumpState
    public var rawState: PumpManager.RawStateValue {
        state.rawValue
    }
    
    private var doseReporter: MedtrumDoseProgressReporter?
    private var doseEntry: UnfinalizedDose?
    
    let bluetooth: BluetoothManager

    init(state: MedtrumPumpState) {
        self.state = state
        self.oldState = MedtrumPumpState(rawValue: state.rawValue)
        self.bluetooth = BluetoothManager()
        
        self.bluetooth.pumpManager = self
    }
    
    public required convenience init?(rawState: RawStateValue) {
        self.init(state: MedtrumPumpState(rawValue: rawState))
    }

    public var isOnboarded: Bool {
        self.state.isOnboarded
    }

    public static var onboardingMaximumBasalScheduleEntryCount: Int {
        48
    }

    public static var onboardingSupportedBasalRates: [Double] {
        // 0.05 units for rates between 0.00-25U/hr
        // 0 U/hr is a supported scheduled basal rate
        (1 ... 500).map { Double($0) / 20 }
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

    public var supportedBasalRates: [Double] {
        MedtrumPumpManager.onboardingSupportedBasalRates
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
        ""
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
    
    private let basalIntervals: [TimeInterval] = Array(0 ..< 24).map({ TimeInterval(60 * 60 * $0) })
    private var currentBaseBasalRate: Double {
        guard !state.basalSchedule.entries.isEmpty else {
            // Prevent crash if basalSchedule isnt set
            return 0
        }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)

        let index = (basalIntervals.firstIndex(where: { $0 > nowTimeInterval }) ?? 24) - 1
        return state.basalSchedule.entries.indices.contains(index) ? state.basalSchedule.entries[index].rate : 0
    }
}

public extension MedtrumPumpManager {
    var pumpRecordsBasalProfileStartEvents: Bool {
        false
    }
    
    var pumpReservoirCapacity: Double {
        self.state.reservoir
    }
    
    var lastSync: Date? {
        self.state.lastSync
    }
    
    var status: PumpManagerStatus {
        self.status(state)
    }
    
    private func status(_ state: MedtrumPumpState) -> PumpManagerStatus {
        let bolusState: LoopKit.PumpManagerStatus.BolusState
        switch state.bolusState {
        case .noBolus:
            bolusState = .noBolus
            break
        case .canceling:
            bolusState = .canceling
            break
        case .inProgress:
            if let dose = doseEntry?.toDoseEntry() {
                bolusState = .inProgress(dose)
            } else {
                bolusState = .noBolus
            }
            break
        }
        
        return PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(state),
            pumpBatteryChargeRemaining: nil, // Patch pumps do not need to report back battery status
            basalDeliveryState: state.basalDeliveryState,
            bolusState: bolusState,
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
            if let dose = doseEntry?.toDoseEntry() {
                return .inProgress(dose)
            }

            return .noBolus
        }
    }
    
    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        guard Date.now.timeIntervalSince(state.lastSync) > .minutes(4) else {
            self.log.warning("Skipping status update -> data is fresh: \(Date.now.timeIntervalSince(state.lastSync)) sec")
            completion?(state.lastSync)
            return
        }
        
        self.log.info("Sync pump data")
        
        self.bluetooth.ensureConnected { connectionResult in
            if case .failure(let error) = connectionResult {
                self.log.error("Failed to connect: \(error.errorDescription ?? "")")
                completion?(nil)
                return
            }
            
            let syncPacket = SynchronizePacket()
            let syncResult = await self.bluetooth.write(syncPacket)
            
            switch syncResult {
            case .failure(let error):
                self.log.error("Failed to write: \(error.localizedDescription)")
                completion?(nil)
                return
                
            case .success(let data):
                guard let syncResponse = data as? SynchronizePacketResponse else {
                    self.log.error("Invalid response data...")
                    completion?(nil)
                    return
                }
                
                self.state.pumpState = syncResponse.state
                
                if let reservoir = syncResponse.reservoir {
                    self.state.reservoir = reservoir
                    
                    self.pumpDelegate.notify { delegate in
                        delegate?.pumpManager(self, didReadReservoirValue: self.state.reservoir, at: Date.now) { _ in }
                    }
                }
                
                if let basal = syncResponse.basal {
                    switch basal.type {
                    case .ABSOLUTE_TEMP, .RELATIVE_TEMP:
                        self.state.basalState = .tempBasal
                        break
                        
                    case .SUSPEND_LOW_GLUCOSE, .SUSPEND_PREDICT_LOW_GLUCOSE, .SUSPEND_AUTO, .SUSPEND_MORE_THAN_MAX_PER_HOUR, .SUSPEND_MORE_THAN_MAX_PER_DAY, .SUSPEND_MANUAL, .SUSPEND_KEY_LOST, .STOP_OCCLUSION, .STOP_EXPIRED, .STOP_EMPTY, .STOP_PATCH_FAULT, .STOP_PATCH_FAULT2, .STOP_BASE_FAULT, .STOP_DISCARD, .STOP_BATTERY_EMPTY, .STOP:
                        self.state.basalState = .suspended
                        break
                        
                    default:
                        self.state.basalState = .active
                        break
                    }
                }
                
                if let battery = syncResponse.battery {
                    self.state.battery = battery.voltageB
                }
                
                self.state.lastSync = Date.now
                self.notifyStateDidChange()
                completion?(Date.now)
            }
        }
    }
    
    func setMustProvideBLEHeartbeat(_: Bool) {}
    
    func createBolusProgressReporter(reportingOn _: DispatchQueue) -> (any LoopKit.DoseProgressReporter)? {
        doseReporter
    }
    
    func estimatedDuration(toBolus units: Double) -> TimeInterval {
        // 1 unit per minute
        units * TimeInterval(minutes: 1)
    }
    
    func startScan(_ callback: @escaping (MedtrumScanResult) -> Void) {
        bluetooth.startScan(callback)
    }
    
    func enactBolus(units: Double, activationType: LoopKit.BolusActivationType, completion: @escaping (LoopKit.PumpManagerError?) -> Void) {
        let duration = self.estimatedDuration(toBolus: units)
        self.log.info("Enact bolus - \(units)U, \(duration)sec")
        
        guard let insulinType = state.insulinType else {
            self.log.error("Insulin type is nil...")
            completion(.configuration(.none))
            return
        }
        
        self.bluetooth.ensureConnected { connectionResult in
            if case .failure(let error) = connectionResult {
                self.log.error("Failed to connect: \(error.errorDescription ?? "")")
                self.resetBolusState()
                
                completion(.communication(error))
                return
            }
            
            let bolusPacket = SetBolusPacket(bolusAmount: units)
            let writeResult = await self.bluetooth.write(bolusPacket)
            
            if case .failure(let error) = writeResult {
                self.log.error("Failed to write: \(error.localizedDescription)")
                self.resetBolusState()
                
                completion(.communication(error))
                return
            }
            
            self.doseEntry = UnfinalizedDose(
                units: units,
                duration: duration,
                activationType: activationType,
                insulinType: insulinType
            )
            
            self.doseReporter = MedtrumDoseProgressReporter(total: units)
            self.state.bolusState = .inProgress
            self.notifyStateDidChange()
            
            completion(nil)
        }
    }
    
    private func resetBolusState() {
        self.state.bolusState = .noBolus
        self.doseReporter = nil
        self.doseEntry = nil
        self.notifyStateDidChange()
    }
    
    func cancelBolus(completion: @escaping (LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) -> Void) {
        self.log.info("Cancelling bolus...")
        
        let oldBolusState = self.state.bolusState
        self.state.bolusState = .canceling
        self.notifyStateDidChange()
        
        self.bluetooth.ensureConnected { connectionResult in
            if case .failure(let error) = connectionResult {
                self.log.error("Failed to connect: \(error.errorDescription ?? "")")
                self.state.bolusState = oldBolusState
                self.notifyStateDidChange()
                
                completion(.failure(.communication(error)))
                return
            }
            
            let packet = CancelBolusPacket()
            let result = await self.bluetooth.write(packet)
            
            if case .failure(let error) = result {
                self.log.error("Failed to cancel bolus: \(error.errorDescription ?? "")")
                self.state.bolusState = oldBolusState
                self.notifyStateDidChange()
                
                completion(.failure(.communication(error)))
                return
            }
            
            self.log.info("Bolus cancelled!")
            self.state.bolusState = .noBolus
            self.notifyStateDidChange()
            
            guard let doseEntry = self.doseEntry else {
                completion(.success(nil))
                return
            }
            
            let dose = doseEntry.toDoseEntry()
            self.doseEntry = nil
            self.doseReporter = nil

            guard let dose = dose else {
                completion(.success(nil))
                return
            }
            
            self.pumpDelegate.notify { delegate in
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: [NewPumpEvent.bolus(dose: dose, units: dose.deliveredUnits ?? 0, date: dose.startDate)],
                    lastReconciliation: Date.now,
                    completion: { _ in }
                )
            }

            self.notifyStateDidChange()
            completion(.success(nil))
        }
    }
    
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (LoopKit.PumpManagerError?) -> Void) {
        self.log.info("Setting temp basal at \(unitsPerHour)U/hr for \(duration) seconds...")
        
        self.bluetooth.ensureConnected { connectionResult in
            if case .failure(let error) = connectionResult {
                self.log.error("Failed to connect: \(error.errorDescription ?? "")")
                completion(.communication(error))
                return
            }
            
            if case .tempBasal = self.state.basalState {
                // Need to cancel temp basal first before setting temp basal
                let cancelPacket = CancelTempBasalPacket()
                let cancelResult = await self.bluetooth.write(cancelPacket)
                
                if case .failure(let error) = cancelResult {
                    self.log.error("Failed to cancel temp basal: \(error.errorDescription ?? "")")
                    completion(.communication(error))
                    return
                }
                
                self.state.basalState = .active
                self.state.basalStateSince = Date.now
                self.log.info("Cancelled temp basal!")
            }
            
            if duration < .ulpOfOne {
                // Need to cancel temp basal, but is already cancelled
                // Only need to report back to algorithm
                if let insulinType = self.state.insulinType {
                    let dose = DoseEntry.basal(rate: self.currentBaseBasalRate, insulinType: insulinType)
                    self.pumpDelegate.notify { delegate in
                        delegate?.pumpManager(
                            self,
                            hasNewPumpEvents: [NewPumpEvent.basal(dose: dose)],
                            lastReconciliation: Date.now,
                            completion: { _ in }
                        )
                    }
                } else {
                    self.log.warning("No insulinType available...")
                }
                
                self.notifyStateDidChange()
                completion(nil)
                return
            }
            
            let packet = SetTempBasalPacket(rate: unitsPerHour, duration: duration)
            let tempBasalResult = await self.bluetooth.write(packet)
            
            if case .failure(let error) = tempBasalResult {
                self.log.error("Failed to set temp basal: \(error.errorDescription ?? "")")
                completion(.communication(error))
                return
            }
            
            self.log.info("Set temp basal!")
            self.state.basalState = .tempBasal
            self.state.basalStateSince = Date.now
            self.state.tempBasalUnits = unitsPerHour
            self.state.tempBasalDuration = duration
            
            if let insulinType = self.state.insulinType {
                let dose = DoseEntry.tempBasal(absoluteUnit: unitsPerHour, duration: duration, insulinType: insulinType)
                self.pumpDelegate.notify { delegate in
                    delegate?.pumpManager(
                        self,
                        hasNewPumpEvents: [NewPumpEvent.tempBasal(dose: dose, units: unitsPerHour, duration: duration)],
                        lastReconciliation: Date.now,
                        completion: { _ in }
                    )
                }
            } else {
                self.log.warning("No insulinType available...")
            }
            
            self.notifyStateDidChange()
            completion(nil)
            
        }
    }
    
    func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        self.log.info("Suspending delivery...")
        
        self.bluetooth.ensureConnected { connectionResult in
            if case .failure(let error) = connectionResult {
                self.log.error("Failed to connect: \(error.errorDescription ?? "")")
                completion(error)
                return
            }
            
            // TODO: suspend needs to have configurable duration
            let packet = SuspendPumpPacket(duration: .minutes(120))
            let result = await self.bluetooth.write(packet)
            
            if case .failure(let error) = result {
                self.log.error("Failed to suspend delivery: \(error.errorDescription ?? "")")
                completion(error)
                return
            }
            
            self.log.info("Delivery suspended for 120min!")
            
            let dose = DoseEntry.suspend()
            self.pumpDelegate.notify { delegate in
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: [NewPumpEvent.suspend(dose: dose)],
                    lastReconciliation: Date.now,
                    completion: { _ in }
                )
            }
            
            self.state.basalState = .suspended
            self.state.basalStateSince = Date.now
            self.notifyStateDidChange()
            
            completion(nil)
        }
    }
    
    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        self.log.info("Suspending delivery...")
        
        self.bluetooth.ensureConnected { connectionResult in
            if case .failure(let error) = connectionResult {
                self.log.error("Failed to connect: \(error.errorDescription ?? "")")
                completion(error)
                return
            }
            
            let packet = ResumePumpPacket()
            let response = await self.bluetooth.write(packet)
            
            if case .failure(let error) = response {
                self.log.error("Failed to resume delivery: \(error.errorDescription ?? "")")
                completion(error)
                return
            }
            
            self.log.info("Resumed delivery!")
            
            if let insulinType = self.state.insulinType {
                let dose = DoseEntry.resume(insulinType: insulinType)
                self.pumpDelegate.notify { delegate in
                    delegate?.pumpManager(
                        self,
                        hasNewPumpEvents: [NewPumpEvent.resume(dose: dose)],
                        lastReconciliation: Date.now,
                        completion: { _ in }
                    )
                }
            } else {
                self.log.warning("No insulinType available...")
            }
            
            self.state.basalState = .active
            self.state.basalStateSince = Date.now
            self.notifyStateDidChange()
            
            completion(nil)
        }
    }
    
    func syncBasalRateSchedule(
        items: [LoopKit.RepeatingScheduleValue<Double>],
        completion: @escaping (Result<LoopKit.BasalRateSchedule, any Error>) -> Void
    ) {
        self.log.info("Sync-ing basal schedule...")
        guard let basalSchedule = DailyValueSchedule<Double>(dailyItems: items) else {
            completion(.failure(NSError(domain: "Basal schedule is empty...", code: -1)))
            return
        }
        
        self.bluetooth.ensureConnected { connectionResult in
            if case .failure(let error) = connectionResult {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            let schedule = BasalSchedule(entries: items)
            let packet = SetBasalProfilePacket(basalProfile: schedule.toData())
            let result = await self.bluetooth.write(packet)
            
            if case .failure(let error) = result {
                self.log.error("Failed to sync basal schedule: \(error.errorDescription ?? "")")
                completion(.failure(error))
                return
            }
            
            self.log.info("Basal schedule sync complete!")
            
            self.state.basalSchedule = schedule
            self.notifyStateDidChange()
            
            if let insulinType = self.state.insulinType {
                let dose = DoseEntry.basal(rate: self.currentBaseBasalRate, insulinType: insulinType)
                self.pumpDelegate.notify { delegate in
                    delegate?.pumpManager(
                        self,
                        hasNewPumpEvents: [NewPumpEvent.basal(dose: dose)],
                        lastReconciliation: Date.now,
                        completion: { _ in }
                    )
                }
            } else {
                self.log.warning("No insulinType available...")
            }

            completion(.success(basalSchedule))
        }
    }
    
    func syncDeliveryLimits(
        limits _: LoopKit.DeliveryLimits,
        completion: @escaping (Result<LoopKit.DeliveryLimits, any Error>) -> Void
    ) {
        self.log.warning("Skipping sync delivery limits (not supported by Medtrum). Limits are always -> maxBolus: 30u, maxBasal: 25u/hr")
        completion(.success(
            DeliveryLimits(
                maximumBasalRate: HKQuantity(
                    unit: HKUnit.internationalUnit().unitDivided(by: .hour()),
                    doubleValue: 25
                ),
                maximumBolus: HKQuantity(
                    unit: .internationalUnit(),
                    doubleValue: 30
                ))
            )
        )
    }
    
    func primePatchPump(_ completion: @escaping (MedtrumPrimePatchResult) -> Void) {
        self.log.info("Start priming patch pump")
        guard self.state.patchId.isEmpty else {
            self.log.error("Old patch pump needs to be deactivated first...")
            completion(.failure(error: .needToDeactivateFirst))
            return
        }
        
        if self.state.pumpSN.isEmpty {
            // Need to scan for pump base first
            self.log.warning("No pump base known yet...")
            completion(.failure(error: .noKnownPumpBase))
            return
        }
        
        //2466528379 -> 7b3c0493
        self.state.sessionToken = Data([0x7b, 0x3c, 0x04, 0x93]) //Crypto.genSessionToken()
        self.notifyStateDidChange()
        
        self.bluetooth.ensureConnected { connectionResult in
            if case .failure(let error) = connectionResult {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }
            
            let packet = PrimePacket()
            let primeResult = await self.bluetooth.write(packet)
            if case .failure(let error) = primeResult {
                self.log.error("Failed to start priming pump: \(error)")
                completion(.failure(error: .unknownError(reason: error.errorDescription ?? "")))
                return
            }
            
            self.log.info("Priming has started!")
            completion(.success)
        }
    }
    
    func activatePatchPump(_ completion: @escaping (MedtrumActivatePatchResult) -> Void) {
        self.log.info("Activate patch pump...")
        self.bluetooth.ensureConnected { connectionResult in
            if case .failure(let error) = connectionResult {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }
            
            let packet = ActivatePacket(
                expirationTimer: 1,
                alarmSetting: .BeepOnly,
                hourlyMaxInsulin: 40,
                dailyMaxInsulin: 180,
                currentTDD: 0,
                basalProfile: self.state.basalSchedule.toData()
            )
            let result = await self.bluetooth.write(packet)
            if case .failure(let error) = result {
                self.log.error("Failed to activate pump: \(error)")
                completion(.failure(error: .unknownError(reason: error.errorDescription ?? "")))
                return
            }
            
            if case .success(let data) = result, let data = data as? ActivatePacketResponse {
                self.state.patchId = data.patchId
                self.log.info("Patch activated!")
                completion(.success)
                return
            }
            
            self.log.error("Failed to parse response...")
            completion(.failure(error: .unknownError(reason: "Failed to parse response...")))
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
}

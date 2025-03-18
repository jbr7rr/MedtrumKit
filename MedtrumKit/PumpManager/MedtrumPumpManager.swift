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
    
    private let bluetooth: BluetoothManager

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

    private func device() -> HKDevice {
        HKDevice(
            name: "NONE",
            manufacturer: "Medtrum",
            model: "NONE",
            hardwareVersion: "NONE",
            firmwareVersion: "NONE",
            softwareVersion: "",
            localIdentifier: "NONE",
            udiDeviceIdentifier: nil
        )
    }
}

public extension MedtrumPumpManager {
    var pumpRecordsBasalProfileStartEvents: Bool {
        false
    }
    
    var pumpReservoirCapacity: Double {
        0
    }
    
    var lastSync: Date? {
        nil
    }
    
    var status: PumpManagerStatus {
        self.status(state)
    }
    
    private func status(_ state: MedtrumPumpState) -> PumpManagerStatus {
        return PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(),
            pumpBatteryChargeRemaining: 0,
            basalDeliveryState: .none,
            bolusState: LoopKit.PumpManagerStatus.BolusState.noBolus,
            insulinType: nil
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
        completion?(nil)
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
    
    func connect(peripheral: CBPeripheral, completion: @escaping (MedtrumConnectResult) -> Void) {
        bluetooth.connect(peripheral: peripheral, completion)
    }
    
    func enactBolus(units: Double, activationType: LoopKit.BolusActivationType, completion: @escaping (LoopKit.PumpManagerError?) -> Void) {
        let duration = self.estimatedDuration(toBolus: units)
        self.log.info("Enact bolus - \(units)U, \(duration)sec")
        
        guard let insulinType = state.insulinType else {
            log.error("Insulin type is nil...")
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
            
            switch writeResult {
            case .failure(let error):
                self.log.error("Failed to write: \(error.localizedDescription)")
                self.resetBolusState()
                
                completion(.communication(error))
                return
                
            case .success:
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
                return
            }
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
            switch connectionResult {
            case .failure(let error):
                self.log.warning("Failed to connect: \(error.errorDescription ?? "")")
                self.state.bolusState = oldBolusState
                self.notifyStateDidChange()
                return
                
            case .success:
                let packet = CancelBolusPacket()
                let result = await self.bluetooth.write(packet)
                
                switch result {
                case .failure(let error):
                    self.log.warning("Failed to cancel bolus: \(error.errorDescription ?? "")")
                    self.state.bolusState = oldBolusState
                    self.notifyStateDidChange()
                    return
                    
                case .success:
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
        }
        completion(.failure(.deviceState(nil)))
    }
    
    func enactTempBasal(unitsPerHour _: Double, for _: TimeInterval, completion: @escaping (LoopKit.PumpManagerError?) -> Void) {
        completion(.deviceState(nil))
    }
    
    func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        completion(NSError(domain: "NOT IMPLEMENTED", code: -1))
    }
    
    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        completion(NSError(domain: "NOT IMPLEMENTED", code: -1))
    }
    
    func syncBasalRateSchedule(
        items _: [LoopKit.RepeatingScheduleValue<Double>],
        completion: @escaping (Result<LoopKit.BasalRateSchedule, any Error>) -> Void
    ) {
        completion(.failure(NSError(domain: "NOT IMPLEMENTED", code: -1)))
    }
    
    func syncDeliveryLimits(
        limits _: LoopKit.DeliveryLimits,
        completion: @escaping (Result<LoopKit.DeliveryLimits, any Error>) -> Void
    ) {
        completion(.failure(NSError(domain: "NOT IMPLEMENTED", code: -1)))
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

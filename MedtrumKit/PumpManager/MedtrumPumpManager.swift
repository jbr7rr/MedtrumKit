import HealthKit
import CoreBluetooth
import LoopKit
import os.log

public class MedtrumPumpManager: DeviceManager {
    public static let pluginIdentifier = "Medtrum"
    public let localizedTitle = LocalizedString("Medtrum", comment: "Generic title of the Medtrum pump manager")
    public let managerIdentifier: String = "MedtrumKit"

    private let log = MedtrumLogger(category: "MedtrumPumpManager")
    public let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    
    var state: MedtrumPumpState
    public var rawState: PumpManager.RawStateValue {
        state.rawValue
    }
    
    private let bluetooth: BluetoothManager

    init(state: MedtrumPumpState) {
        self.state = state
        self.bluetooth = BluetoothManager()
        
        self.bluetooth.pumpManager = self
    }
    
    public required convenience init?(rawState: RawStateValue) {
        self.init(state: MedtrumPumpState(rawValue: rawState))
    }

    public var isOnboarded: Bool {
        false
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

    var status: LoopKit.PumpManagerStatus {
        PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(),
            pumpBatteryChargeRemaining: 0,
            basalDeliveryState: .none,
            bolusState: LoopKit.PumpManagerStatus.BolusState.noBolus,
            insulinType: nil
        )
    }

    func addStatusObserver(_: any LoopKit.PumpManagerStatusObserver, queue _: DispatchQueue) {}

    func removeStatusObserver(_: any LoopKit.PumpManagerStatusObserver) {}

    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        completion?(nil)
    }

    func setMustProvideBLEHeartbeat(_: Bool) {}

    func createBolusProgressReporter(reportingOn _: DispatchQueue) -> (any LoopKit.DoseProgressReporter)? {
        nil
    }

    func estimatedDuration(toBolus _: Double) -> TimeInterval {
        TimeInterval(0)
    }
    
    func startScan(_ callback: @escaping (MedtrumScanResult) -> Void) {
        bluetooth.startScan(callback)
    }
    
    func connect(peripheral: CBPeripheral, completion: @escaping (MedtrumConnectResult) -> Void) {
        bluetooth.connect(peripheral: peripheral, completion)
    }

    func enactBolus(
        units _: Double,
        activationType _: LoopKit.BolusActivationType,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        completion(.communication(nil))
    }

    func cancelBolus(completion: @escaping (LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) -> Void) {
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
}

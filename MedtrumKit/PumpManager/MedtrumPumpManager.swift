import CoreBluetooth
import UIKit
import HealthKit
import LoopKit

public class MedtrumPumpManager: DeviceManager {
    public static let pluginIdentifier = "Medtrum"
    public let localizedTitle: String = "Medtrum Nano"

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
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appMovedToBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appMovedToForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        bluetooth.pumpManager = self
    }

    /// background sync, doesn't lock loops
    static let heartbeatSyncFreshnessInterval: TimeInterval = .minutes(2.5)

    /// start of the loop, try to avoid syncs
    static let loopSyncFreshnessInterval: TimeInterval = .minutes(4.5)

    static let patchTimeRefreshInterval: TimeInterval = .minutes(30)

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
    
    private var mustProvideBLEHeartbeat = false
    private var lastHeartbeat: Date = .distantPast

    private static let heartbeatInterval: TimeInterval = .minutes(1)

    func issueHeartbeatIfNeeded() {
        guard mustProvideBLEHeartbeat,
              Date.now.timeIntervalSince(lastHeartbeat) > Self.heartbeatInterval
        else {
            return
        }

        lastHeartbeat = Date.now
        log.info("Firing BLE heartbeat")

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.error("Heartbeat fire could not be reported -> Missing delegate")
                return
            }

            delegate.pumpManagerBLEHeartbeatDidFire(self)
        }
    }

    private let backgroundTask = BackgroundTask()
    @objc func appMovedToBackground() {
        if state.useSilentTones {
            log.info("Starting silent tones")
            backgroundTask.startBackgroundTask()
        }
    }

    @objc func appMovedToForeground() {
        backgroundTask.stopBackgroundTask()
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
            bolusState: state.bolusDeliveryState,
            insulinType: state.insulinType
        )
    }

    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        let age = Date.now.timeIntervalSince(state.lastSync)

        guard let activatedAt = state.patchActivatedAt,
              age > Self.loopSyncFreshnessInterval ||
              Date.now.timeIntervalSince(activatedAt) < .minutes(4)
        else {
            log.info("Skipping status update -> data is fresh or not active: \(Int(age)) sec")
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

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion?(nil)
                return
            }

            let syncResult = self.bluetooth.write(SynchronizePacket())
            StateSyncer.fetchPatchTimeIfStale(pumpManager: self)

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

                StateSyncer.sync(
                    syncResponse: syncResponse,
                    state: self.state,
                    pumpManager: self,
                    duringReconnect: false,
                    fullSync: true
                )

                completion?(Date.now)
            }
        }
    }

    func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        self.mustProvideBLEHeartbeat = mustProvideBLEHeartbeat
    }

    func createBolusProgressReporter(reportingOn: DispatchQueue) -> (any LoopKit.DoseProgressReporter)? {
        if let doseEntry = state.bolusDose {
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

        guard state.basalState != .suspended else {
            log.error("Pump is suspended...")
            completion(.deviceState(MedtrumConnectError.isSuspended))
            return
        }

        let duration = estimatedDuration(toBolus: units)
        log.info("Enact bolus - \(units)U, \(duration)sec")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                self.resetBolusState()

                completion(.communication(error))
                return
            }

            let writeResult = self.bluetooth.write(SetBolusPacket(bolusAmount: units))
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

            let events = [NewPumpEvent.bolus(unfinalizedDose: doseEntry)]
            self.emitPumpEvents(events, replacePendingEvents: false)

            self.state.bolusDose = doseEntry
            self.notifyStateDidChange()

            completion(nil)
        }
    }

    private func resetBolusState() {
        state.bolusDose = nil
        state.cancelingBolusSince = nil
        notifyStateDidChange()
    }

    func cancelBolus(completion: @escaping (LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) -> Void) {
        log.info("Cancelling bolus...")

        state.cancelingBolusSince = Date.now
        notifyStateDidChange()

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                self.state.cancelingBolusSince = nil
                self.notifyStateDidChange()

                completion(.failure(.communication(error)))
                return
            }

            let result = self.bluetooth.write(CancelBolusPacket())
            if case let .failure(error) = result {
                self.log.error("Failed to cancel bolus: \(error.localizedDescription)")
                self.state.cancelingBolusSince = nil
                self.notifyStateDidChange()

                completion(.failure(.communication(error)))
                return
            }

            self.log.info("Bolus cancelled!")

            guard let doseEntry = self.state.bolusDose else {
                self.state.cancelingBolusSince = nil
                self.notifyStateDidChange()

                completion(.success(nil))
                return
            }

            let dose = doseEntry.toDoseEntry()
            var events = self.runningTempBasal()
            events.append(NewPumpEvent.bolus(dose: dose))

            self.state.bolusDose = nil
            self.state.cancelingBolusSince = nil
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.emitPumpEvents(events)

            completion(.success(nil))
        }
    }

    func enactTempBasal(
        unitsPerHour: Double,
        for duration: TimeInterval,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        enactTempBasal(unitsPerHour: unitsPerHour, duration: duration, automatic: true, completion: completion)
    }

    func enactTempBasal(
        unitsPerHour: Double,
        duration: TimeInterval,
        automatic: Bool,
        completion: @escaping (LoopKit.PumpManagerError?) -> Void
    ) {
        log.info("Setting temp basal at \(unitsPerHour)U/hr for \(duration)s")

        guard state.bolusState == .noBolus else {
            log.error("Pump is in bolus state...")
            completion(.deviceState(MedtrumConnectError.isBolussing))
            return
        }

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(.communication(error))
                return
            }

            if self.state.basalState == .tempBasal {
                // Need to cancel temp basal first before setting temp basal
                let cancelResult = self.bluetooth.write(CancelTempBasalPacket())
                if case let .failure(error) = cancelResult {
                    self.log.error("Failed to cancel temp basal: \(error.localizedDescription)")
                    completion(.communication(error))
                    return
                }

                self.state.basalState = .active
                self.log.info("Cancelled temp basal!")
            }

            if duration < .ulpOfOne {
                // Need to cancel temp basal, but is already cancelled
                // Only need to report back to algorithm
                self.reportScheduledBasal()

                completion(nil)
                return
            }

            let packet = SetTempBasalPacket(rate: unitsPerHour, duration: duration)
            let tempBasalResult = self.bluetooth.write(packet)

            if case let .failure(error) = tempBasalResult {
                self.log.error("Failed to set temp basal: \(error.localizedDescription)")

                // the cancel already succeeded, but new TBR failed - the patch is running the scheduled basal now
                self.reportScheduledBasal()

                completion(.communication(error))
                return
            }

            self.log.info("Set temp basal!")

            let tempBasalDose = UnfinalizedDose(
                tempRate: unitsPerHour,
                duration: duration,
                insulinType: self.state.insulinType,
                automatic: automatic
            )
            var events = self.finalizedTempBasal(endedAt: Date.now)
            events.append(NewPumpEvent.tempBasal(dose: tempBasalDose.toDoseEntry(isMutable: true)))

            self.state.basalDose = tempBasalDose
            self.state.basalState = .tempBasal
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.emitPumpEvents(events)

            completion(nil)
        }
    }

    private func reportScheduledBasal() {
        let now = Date.now
        var events = finalizedTempBasal(endedAt: now)

        let basalDose = UnfinalizedDose(
            basalRate: state.currentBaseBasalRate,
            insulinType: state.insulinType,
            startDate: now
        )

        events.append(NewPumpEvent.basal(dose: basalDose.toDoseEntry()))

        state.basalDose = basalDose
        state.lastSync = Date.now
        notifyStateDidChange()

        emitPumpEvents(events)
    }

    func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        suspendPatch(duration: .minutes(120), completion: completion)
    }

    func suspendPatch(duration: TimeInterval, completion: @escaping ((any Error)?) -> Void) {
        log.info("Suspending delivery...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error)
                return
            }

            let result = self.bluetooth.write(SuspendPumpPacket(duration: duration))
            if case let .failure(error) = result {
                self.log.error("Failed to suspend delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            let start = Date.now
            let basalDose = UnfinalizedDose(suspendStartTime: start)

            var events = self.finalizedTempBasal(endedAt: start)
            events.append(NewPumpEvent.suspend(dose: basalDose.toDoseEntry()))

            self.state.basalDose = basalDose
            self.state.basalState = .suspended
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.emitPumpEvents(events)

            self.log.info("Delivery suspended for \(duration.minutes) min!")
            completion(nil)
        }
    }

    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        log.info("Resuming delivery...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error)
                return
            }

            let response = self.bluetooth.write(ResumePumpPacket())
            if case let .failure(error) = response {
                self.log.error("Failed to resume delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            self.log.info("Resumed delivery!")

            let resumeDose = UnfinalizedDose(
                resumeStartTime: Date.now,
                insulinType: self.state.insulinType
            )

            var events = self.runningTempBasal()
            events.append(NewPumpEvent.resume(dose: resumeDose.toDoseEntry()))

            self.state.basalDose = resumeDose
            self.state.basalState = .active
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.emitPumpEvents(events)

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

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            let schedule = BasalSchedule(entries: items)
            let packet = SetBasalProfilePacket(basalProfile: schedule.toData())
            let result = self.bluetooth.write(packet)

            if case let .failure(error) = result {
                self.log.error("Failed to sync basal schedule: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            self.state.basalSchedule = schedule
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.log.info("Basal schedule sync complete!")

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

            let primeResult = self.bluetooth.write(PrimePacket())
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

            StateSyncer.syncTime(pumpManager: self)

            let packet = ActivatePacket(
                expirationTimer: self.state.expiryMode.timer,
                alarmSetting: self.state.alarmSetting,
                hourlyMaxInsulin: self.state.maxHourlyInsulin,
                dailyMaxInsulin: self.state.maxDailyInsulin,
                currentTDD: 0,
                basalProfile: self.state.basalSchedule.toData()
            )
            let result = self.bluetooth.write(packet)
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

                if self.state.expiryMode == .default {
                    self.emitAlert(alertType: .patchExpiredNotification(after: self.state.notificationAfterActivation))
                }

                let start = Date.now
                let resumeDose = UnfinalizedDose(
                    resumeStartTime: start,
                    insulinType: self.state.insulinType
                )
                let events = [
                    NewPumpEvent.replacedPump(date: start),
                    NewPumpEvent.resume(dose: resumeDose.toDoseEntry())
                ]

                self.state.initialReservoir = nil
                self.state.patchId = data.patchId
                self.state.patchActivatedAt = Date.now
                self.state.basalDose = resumeDose
                self.state.lastSync = Date.now
                self.notifyStateDidChange()

                self.emitPumpEvents(events)

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

            let result = self.bluetooth.write(StopPatchPacket())
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

            let suspendStart = Date.now
            let suspendDose = UnfinalizedDose(suspendStartTime: suspendStart)

            var events = self.finalizedTempBasal(endedAt: suspendStart)
            events.append(contentsOf: self.finalizeInterruptedBolus())
            events.append(NewPumpEvent.suspend(dose: suspendDose.toDoseEntry()))

            self.state.patchId = Data()
            self.state.pumpState = .none
            self.state.backupSessionToken = self.state.sessionToken
            self.state.sessionToken = Data()
            self.state.lastSync = Date.now
            self.state.basalDose = suspendDose
            self.notifyStateDidChange()

            self.emitPumpEvents(events)

            self.log.info("Patch deactivated")
            completion(.success)

            self.bluetooth.disconnect(force: true)
        }
    }

    func forceDeactivatePatch() {
        log.info("Force deactivating patch...")

        let suspendDose = UnfinalizedDose(suspendStartTime: Date.now)

        var events = finalizedTempBasal(endedAt: Date.now)
        events.append(contentsOf: finalizeInterruptedBolus())
        events.append(NewPumpEvent.suspend(dose: suspendDose.toDoseEntry()))

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
        state.backupSessionToken = state.sessionToken
        state.sessionToken = Data()
        state.lastSync = Date.now
        state.basalDose = suspendDose
        notifyStateDidChange()

        emitPumpEvents(events)

        bluetooth.disconnect(force: true)
    }

    func clearAlert(alertType: AlertType, completion: @escaping (Bool) -> Void) {
        log.info("Clearing alert - alertType: \(alertType.rawValue)")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(false)
                return
            }

            let clearAlertResult = self.bluetooth.write(ClearAlertPacket(alertType: alertType))
            if case let .failure(error) = clearAlertResult {
                self.log.error("Failed to clear alert: \(error)")
                completion(false)
                return
            }

            let resumeResult = self.bluetooth.write(ResumePumpPacket())
            if case let .failure(error) = resumeResult {
                self.log.error("Failed to resume patch: \(error)")
                completion(false)
                return
            }

            self.syncPumpData { _ in
                self.log.info("Alert cleared!")
                completion(true)
            }
        }
    }

    func updatePatchSettings(completion: @escaping (MedtrumUpdatePatchResult) -> Void) {
        log.info("Update patch settings...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }

            let package = SetPatchPacket(
                alarmSettings: self.state.alarmSetting,
                hourlyMaxInsulin: self.state.maxHourlyInsulin,
                dailyMaxInsulin: self.state.maxDailyInsulin,
                expirationTimer: self.state.expiryMode.timer
            )
            let result = self.bluetooth.write(package)
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

    internal func emitAlert(alertType: MedtrumAlert) {
        pumpDelegate.notify { delegate in
            delegate?.issueAlert(alertType.alert)

            if let pumpEvent = NewPumpEvent.alert(type: alertType) {
                delegate?.pumpManager(
                    self,
                    hasNewPumpEvents: [pumpEvent],
                    lastReconciliation: self.state.lastSync,
                    replacePendingEvents: false,
                    completion: { error in
                        if let error = error {
                            self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                        }
                    }
                )
            }
        }
    }

    func updateBolusProgress(delivered: Double, completed: Bool, useEstimatedEndDate: Bool) {
        guard let doseEntry = state.bolusDose else {
            return
        }

        doseEntry.deliveredUnits = delivered

        if !completed {
            return
        }

        let dose = doseEntry.toDoseEntry(useEstimatedEndDate: useEstimatedEndDate)
        var events = runningTempBasal()
        events.append(NewPumpEvent.bolus(dose: dose))

        state.bolusDose = nil
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
        }

        emitPumpEvents(events)
    }

    func checkBolusDone() {
        guard let doseEntry = state.bolusDose else {
            // No bolus was in progress during disconnect
            return
        }

        log.warning("Bolus was not completed... \(doseEntry.deliveredUnits) U of the \(doseEntry.value) U")

        // We assume the bolus has completed, but did not receive completed event
        // due to being disconnected for too long
        doseEntry.deliveredUnits = doseEntry.value
        let dose = doseEntry.toDoseEntry(useEstimatedEndDate: true)
        var events = runningTempBasal()
        events.append(NewPumpEvent.bolus(dose: dose))

        state.lastSync = Date.now
        state.bolusDose = nil
        notifyStateDidChange()

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
        }

        emitPumpEvents(events)
    }

    private func finalizeInterruptedBolus() -> [NewPumpEvent] {
        guard let doseEntry = state.bolusDose else {
            return []
        }

        log.warning(
            "Patch deactivated during a bolus... \(doseEntry.deliveredUnits) U of the \(doseEntry.value) U"
        )

        let dose = doseEntry.toDoseEntry()
        state.bolusDose = nil

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
        }

        return [NewPumpEvent.bolus(dose: dose)]
    }

    private func ensureConnectedAndActive(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        guard state.pumpState.rawValue >= PatchState.active.rawValue else {
            log.warning("No active patch, failing immediately")
            completion(.failedToFindDevice)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                completion(.failedToFindDevice)
                return
            }

            self.bluetooth.ensureConnected(completion)
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

    /// The current temp basal (if any), reported as still running
    private func runningTempBasal() -> [NewPumpEvent] {
        guard state.basalDose.type == .tempBasal else {
            return []
        }

        return [NewPumpEvent.tempBasal(dose: state.basalDose.toDoseEntry(isMutable: true))]
    }

    /// The current temp basal (if any), finalized as having stopped at `endedAt`
    private func finalizedTempBasal(endedAt: Date) -> [NewPumpEvent] {
        guard state.basalDose.type == .tempBasal else {
            return []
        }

        return [NewPumpEvent.tempBasal(dose: state.basalDose.toDoseEntry(isMutable: false, endDate: endedAt))]
    }

    func emitReservoirLevel() {
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(
                self,
                didReadReservoirValue: self.state.reservoir.rounded(toPlaces: 1),
                at: Date.now
            ) { result in
                switch result {
                case let .failure(error):
                    self.handlePumpDelegateError(method: "didReadReservoirValue", error)
                case .success:
                    break
                }
            }
        }
    }

    func emitPumpEvents(_ events: [NewPumpEvent], replacePendingEvents: Bool = true) {
        var events = events

        // With `replacePendingEvents` the host drops every mutable dose it holds.
        // Anything still in flight has to be in here, otherwise it disappears from
        // the host's history until we report it again later.
        if replacePendingEvents {
            if let bolusDose = state.bolusDose, !events.contains(where: { $0.type == .bolus }) {
                events.append(NewPumpEvent.bolus(unfinalizedDose: bolusDose))
            }

            if !events.contains(where: { $0.type == .tempBasal }) {
                events.append(contentsOf: runningTempBasal())
            }
        }

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: replacePendingEvents
            ) { error in
                if let error = error {
                    self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                }
            }
        }
    }
}

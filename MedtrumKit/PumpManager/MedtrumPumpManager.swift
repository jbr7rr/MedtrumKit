import CoreBluetooth
import HealthKit
import LoopKit
import UIKit

public class MedtrumPumpManager: DeviceManager {
    public static let pluginIdentifier = "Medtrum"
    public let localizedTitle: String = "Medtrum Nano"

    public let managerIdentifier: String = "Medtrum"

    private let log = MedtrumLogger(category: "MedtrumPumpManager")

    public let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()
    private let bolusProgressReporters = Locked(WeakSet<MedtrumDoseProgressReporter>())

    /// Orders what the host is told about the doses. Held while a dose is registered or ended and reported, while a
    /// batch is put together and handed to the delegate queue (`emitPumpEvents`), from the moment a dose is finalized
    /// until its final has been handed over, and while a confirmation takes finals off `awaitingRecord`. So no batch
    /// carries a dose as mutable after its final, nor leaves out one still running or waiting.
    ///
    /// Recursive: the ending paths emit while holding it. Never held across a BLE write. A dose's own lock is a leaf
    /// taken under it, never the other way around.
    private let doseReportLock = NSRecursiveLock()

    /// The identities of doses finalized lately: a mutable report of one built before its final can still be on its
    /// way after the host confirmed the final. Only under `doseReportLock`.
    private var finalizedIdentities: [Data: Date] = [:]
    private static let finalizedIdentityRetention: TimeInterval = .hours(1)

    /// A temp basal that ended, reported once its records are read - see `TempBasalEnd`. Only under `doseReportLock`.
    private var pendingTempBasalEndStorage: TempBasalEnd?

    /// The completion of the bolus sent and not yet answered - see `noteCompletionWithNoBolusRunning`. Only under
    /// `doseReportLock`.
    private var earlyBolusCompletion: EarlyBolusCompletion?

    /// A bolus whose command went unanswered in an earlier run, the host not yet warned of it - see
    /// `reportBolusFromLastRun`. Only under `doseReportLock`.
    private var bolusFromLastRun: UnfinalizedDose?

    /// Where the records of a temp basal a notification ended are read: not the queue statuses arrive on, which the
    /// answers have to reach
    let tempBasalEndQueue = DispatchQueue(label: "com.nightscout.MedtrumKit.tempBasalEnd")

    /// When a batch last carried the finals the host has yet to confirm. Only under `doseReportLock`.
    private var lastFinalsSentAt = Date.distantPast
    /// Without a batch for a while - no patch, or the host could not store the last one - the unconfirmed finals are
    /// sent on their own, this often at most
    private static let unconfirmedFinalsResendInterval: TimeInterval = .minutes(1)
    /// A host that never confirms would have the finals pile up for good: one fixed this long ago is given up on
    static let unconfirmedFinalMaximumAge: TimeInterval = .hours(24)

    /// Commands in flight, by when they started: the record sync yields to them - see `isCommandActive`
    private let activeCommands = Locked([UUID: Date]())
    /// `ensureConnected` can orphan its completion; a command not finished this long after it connected no longer counts
    private static let commandActivityTimeout: TimeInterval = .minutes(3)

    /// One operation on the patch at a time. A command holds it from its first write until it settled what it changed:
    /// a temp basal it ended reported final, its records read. A record read holds it for that one record, and never
    /// waits for it. Taken only on the threads commands and reads block on - never on the queue answers and statuses
    /// arrive on, nor on the delegate queue. Recursive: the stop command reads the last records under it.
    private let commandLock = NSRecursiveLock()

    /// The clock the record fallbacks and a bolus's deadline go by. Only tests move it.
    var now: () -> Date = { Date.now }
    /// The monotonic clock, which a change of the wall clock does not move and which counts sleep
    /// (`TimeInterval.continuousUptime`): commands and the record counter's tellings are stamped on it, as statuses are
    /// (`SynchronizePacketResponse.receivedUptime`). Only tests move it.
    var uptime: () -> TimeInterval = { .continuousUptime }

    public var state: MedtrumPumpState
    var oldState: MedtrumPumpState

    /// Records read off the patch, for the debug screen. Not part of `state` - see `PumpRecordStore`.
    public let recordStore = PumpRecordStore()
    public var rawState: PumpManager.RawStateValue {
        state.rawValue
    }

    private let logDeviceIdentifierLock = NSLock()
    private var logDeviceIdentifierStorage = ""

    /// for host-app logging
    var logDeviceIdentifier: String {
        logDeviceIdentifierLock.withLock { logDeviceIdentifierStorage }
    }

    private func refreshLogDeviceIdentifier() {
        let identifier = state.pumpSN.hexEncodedString()
        logDeviceIdentifierLock.withLock { logDeviceIdentifierStorage = identifier }
    }

    /// What every command goes over - the `BluetoothManager`, unless a test injected its own
    var link: MedtrumLink!

    /// For the UI, which scans, pairs and shows the connection state. Nil when a test injected the link.
    var bluetooth: BluetoothManager! {
        link as? BluetoothManager
    }

    init(state: MedtrumPumpState) {
        self.state = state
        oldState = MedtrumPumpState(rawValue: state.rawValue)
        link = BluetoothManager(knownPeripheralIdentifier: state.peripheralIdentifier)
        refreshLogDeviceIdentifier()

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

        // Before the link can hand it a status: one synced against a state without the bolus
        takeOverPendingBolus()
        link.pumpManager = self
        MedtrumLogger.pumpManager = self
    }

    /// Drives the manager over `link` instead of CoreBluetooth - for tests. Creates no central manager
    /// and registers nothing global: no app lifecycle observers, and `MedtrumLogger` keeps no reference.
    init(state: MedtrumPumpState, link: MedtrumLink) {
        self.state = state
        oldState = MedtrumPumpState(rawValue: state.rawValue)
        self.link = link
        refreshLogDeviceIdentifier()

        takeOverPendingBolus()
        link.pumpManager = self
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        log.info("MedtrumPumpManager deallocated")
    }

    public func forgetBluetoothManager() {
        link?.pumpManager = nil
        link = nil
    }

    /// background sync, doesn't lock loops
    static let heartbeatSyncFreshnessInterval: TimeInterval = .minutes(2.5)

    /// start of the loop, try to avoid syncs
    static let loopSyncFreshnessInterval: TimeInterval = .minutes(4.5)

    /// background sync for a bolus past its deadline: sooner than the freshness interval, but not on every heartbeat -
    /// a full status may still show it delivering
    static let overdueBolusSyncInterval: TimeInterval = .minutes(1)

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

    /// While the patch is being stopped on request, the states it reports are not a base reset
    private(set) var isDeactivatingPatch = false

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

    /// A status from the patch: a notification it pushed, or the answer to a Synchronize the link sent
    /// while connecting or to keep the session fresh
    func handleStatus(_ syncResponse: SynchronizePacketResponse, duringReconnect: Bool, fullSync: Bool) {
        // Told of before anything the status does to it
        reportBolusFromLastRun()

        StateSyncer.sync(
            syncResponse: syncResponse,
            state: state,
            pumpManager: self,
            duringReconnect: duringReconnect,
            fullSync: fullSync
        )

        issueHeartbeatIfNeeded()
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
            insulinType: state.insulinType,
            deliveryIsUncertain: state.deliveryIsUncertain
        )
    }

    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        // Need neither the link nor a patch
        reportBolusFromLastRun()
        resendUnacknowledgedFinalsIfDue()

        let age = Date.now.timeIntervalSince(state.lastSync)

        // Fresh or not, a bolus past its deadline is settled by a full status
        guard let activatedAt = state.patchActivatedAt,
              age > Self.loopSyncFreshnessInterval ||
              Date.now.timeIntervalSince(activatedAt) < .minutes(4) ||
              isRunningBolusOverdue
        else {
            log.info("Skipping status update -> data is fresh or not active: \(Int(age)) sec")
            completion?(nil)
            return
        }

        guard !state.pumpState.isSetup else {
            log.error("(ensureCurrentPumpData) patch not in active state yet")
            completion?(nil)
            return
        }

        syncPumpData { syncedAt in
            // The patch out of reach: the doses waiting on its records must not wait for good
            if syncedAt == nil {
                RecordSyncer.finalizeOverdueDosesUnread(pumpManager: self)
            }
            completion?(syncedAt)
        }
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

        // Not counted as a command: the record sync below runs inside it, and would otherwise yield to it
        ensureConnectedAndActive(isCommand: false) { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion?(nil)
                return
            }

            // Between commands: not ahead of the records a command reads, a temp basal's it ended
            guard let syncResult = self.betweenCommands({ self.link.write(SynchronizePacket()) }) else {
                completion?(nil)
                return
            }
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

                // A few records before the loop hears back, so it sees the doses they finalize; the rest after
                RecordSyncer.syncRecords(pumpManager: self, trigger: .loopSync)

                completion?(Date.now)

                if self.state.syncedSequenceNumber < self.state.currentSequenceNumber {
                    RecordSyncer.syncRecords(pumpManager: self, trigger: .fullSync)
                }
            }
        }
    }

    func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        self.mustProvideBLEHeartbeat = mustProvideBLEHeartbeat
    }

    func createBolusProgressReporter(reportingOn: DispatchQueue) -> (any LoopKit.DoseProgressReporter)? {
        guard let doseEntry = state.bolusDose else {
            return nil
        }

        let reporter = MedtrumDoseProgressReporter(dose: doseEntry, reportingQueue: reportingOn)
        bolusProgressReporters.mutate { reporters in
            reporters.cleanupDeallocatedElements()
            _ = reporters.insert(reporter)
        }

        // An update pushed between creating it and registering it would not reach it until the next one
        reporter.update()
        return reporter
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

        // Until the SetBolus is answered nothing of this bolus is in the state but `pendingBolus`: its error paths leave
        // the rest alone - what is there is another operation's, a bolus running or a cancel waiting to go out
        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(.communication(error))
                return
            }

            // Again holding the command lock: a bolus or a suspend may have gone out while this one waited for it
            guard self.state.bolusState == .noBolus else {
                self.log.error("Pump is in bolus state...")
                completion(.deviceState(MedtrumConnectError.isBolussing))
                return
            }

            guard self.state.basalState != .suspended else {
                self.log.error("Pump is suspended...")
                completion(.deviceState(MedtrumConnectError.isSuspended))
                return
            }

            let sentAt = Date.now
            let sentUptime = self.uptime()
            // The newest record known, or claimed: every number an answer gave is an earlier bolus's, below this one's
            // own - see `MedtrumPumpState.answeredBolusRecords`. The known one lags a claimed one whose completion was lost.
            let sequenceAtSend = max(self.state.currentSequenceNumber, self.state.answeredBolusRecords.max() ?? 0)

            // On disk before it goes out: killed before its answer, the app comes back with it - see `pendingBolus`
            self.doseReportLock.withLock { self.earlyBolusCompletion = nil }
            self.state.pendingBolus = PendingBolus(
                units: units,
                sentAt: sentAt,
                sequenceAtSend: sequenceAtSend,
                automatic: activationType.isAutomatic
            )
            self.handOverState(before: "writing the bolus")

            let writeResult = self.link.write(SetBolusPacket(bolusAmount: units))
            let outcome = MedtrumCommandOutcome(writeResult)

            var writeError: MedtrumWriteError?
            if case let .failure(error) = writeResult {
                writeError = error
            }

            // Never left the phone, or turned down: nothing to report
            guard outcome == .accepted || outcome == .unknown else {
                self.log.error("Failed to write (\(outcome)): \(writeError?.localizedDescription ?? "-")")
                // On disk before the command fails: killed after it, the app must not come back with a bolus that never
                // ran
                self.state.pendingBolus = nil
                if let early = self.doseReportLock.withLock({ () -> EarlyBolusCompletion? in
                    defer { self.earlyBolusCompletion = nil }
                    return self.earlyBolusCompletion
                }) {
                    self.log.error(
                        "A completion of \(early.delivered) U, record \(early.record.map { "#\($0)" } ?? "-"), came " +
                            "while the bolus that failed was sent: dropped"
                    )
                }
                self.handOverState(before: "failing the bolus")
                completion(.communication(writeError))
                return
            }

            // Unanswered, the patch may be delivering it: running and counted in full until a notification shows it
            // delivering or its deadline passes, and never sent again. Dated from when it went out, as one taken over
            // after a kill is (`takeOverPendingBolus`): one identity, whichever run reports it.
            let doseEntry = UnfinalizedDose(
                units: units,
                duration: duration,
                activationType: activationType,
                insulinType: self.state.insulinType,
                confirmation: outcome == .unknown ? .uncertain : .confirmed,
                startDate: sentAt
            )
            doseEntry.noteCommand(sentAt: sentAt, uptime: sentUptime, sequence: sequenceAtSend)

            if case let .success(data) = writeResult, let response = data as? SetBolusResponse {
                self.noteBolusAnswer(response, of: doseEntry)
            }

            // Running and reported in one step - see `doseReportLock` - and no longer pending: the state the host saves
            // as it takes the report has the one, not the other. A completion that came before the answer is taken now.
            let early = self.doseReportLock.withLock { () -> EarlyBolusCompletion? in
                self.state.bolusDose = doseEntry
                self.state.pendingBolus = nil
                self.emitPumpEvents([NewPumpEvent.bolus(unfinalizedDose: doseEntry)], replacePendingEvents: false)
                defer { self.earlyBolusCompletion = nil }
                return self.earlyBolusCompletion
            }
            self.notifyStateDidChange()

            // Over before its answer came. Unanswered, it stays uncertain - counted in full, and warned of - whatever
            // came meanwhile: its record settles it.
            if let early {
                if outcome == .accepted {
                    self.completeBolusEarly(doseEntry, early)
                } else {
                    self.log.warning(
                        "A completion of \(early.delivered) U, record \(early.record.map { "#\($0)" } ?? "-"), came " +
                            "before the bolus went unanswered: counted in full until its record"
                    )
                }
            }

            guard outcome == .accepted else {
                self.log.error(
                    "Bolus of \(units) U went out unanswered (\(writeError?.localizedDescription ?? "-")): it may be " +
                        "delivering. Counted in full until the patch shows it, or its record says otherwise - not sent again"
                )
                self.warnOfUncertainBolus(doseEntry)
                completion(.uncertainDelivery)
                return
            }

            completion(nil)
        }
    }

    /// The answer to SetBolus names the record the patch allocated for the bolus, and when it started it - unless it
    /// is another patch's answer, which says nothing of ours: its record is then looked for near when it went out
    private func noteBolusAnswer(_ response: SetBolusResponse, of dose: UnfinalizedDose) {
        guard let recordSequence = response.recordSequence, let patchId = response.patchId,
              let startTime = response.startTime
        else {
            log.warning("Set bolus answer carries no record, its record is looked for near when it went out")
            return
        }

        guard patchId == state.patchId.toUInt64() & 0xFFFF else {
            log.error(
                "Set bolus answered for patch \(patchId), this is \(state.patchId.toUInt64()) - " +
                    "its record is looked for near when it went out"
            )
            return
        }

        dose.noteAnswer(recordSequence: recordSequence, pumpStartTime: startTime)
        noteAnsweredBolusRecord(recordSequence)
        log.info("Bolus is record #\(recordSequence), patch start \(startTime)")
    }

    /// See `MedtrumPumpState.answeredBolusRecords`. Kept while its record may still be read: past the cursor, or within
    /// a run behind it - a restart reads again from the cursor as saved.
    private func noteAnsweredBolusRecord(_ sequence: Int) {
        doseReportLock.withLock {
            let oldest = state.syncedSequenceNumber - RecordSyncer.Trigger.beforeStop.maxRecords
            state.answeredBolusRecords = Array(
                (state.answeredBolusRecords.filter { $0 > oldest } + [sequence]).suffix(Self.answeredBolusRecordsKept)
            )
        }
    }

    /// Records that cannot be read for long pile them up: past this many, the oldest go
    private static let answeredBolusRecordsKept = 50

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

            let result = self.link.write(CancelBolusPacket())
            if case let .failure(error) = result {
                self.log.error("Failed to cancel bolus: \(error.localizedDescription)")
                self.state.cancelingBolusSince = nil
                self.notifyStateDidChange()

                completion(.failure(.communication(error)))
                return
            }

            self.log.info("Bolus cancelled!")

            // Ended at the last amount the patch reported, and off the running bolus in one step - only if it still is
            // the running one: a completion seen meanwhile ended it already. The completion the patch sends after the
            // cancel raises the amount (`raiseCancelledBolus`), its record fixes it.
            let ended = self.doseReportLock.withLock { () -> Bool in
                guard let doseEntry = self.state.bolusDose, !doseEntry.isFinished else {
                    return false
                }

                var events = self.runningTempBasal()
                events.append(contentsOf: self.awaitRecord(doseEntry, .cancelled, endedAt: Date.now))
                self.state.bolusDose = nil
                self.state.cancelingBolusSince = nil
                self.state.lastSync = Date.now
                self.emitPumpEvents(events)
                return true
            }

            if !ended {
                self.state.cancelingBolusSince = nil
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

        // A suspended patch runs no temp basal
        guard state.basalState != .suspended else {
            log.error("Pump is suspended...")
            completion(.deviceState(MedtrumConnectError.isSuspended))
            return
        }

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(.communication(error))
                return
            }

            // Again holding the command lock: a bolus may have gone out while this waited for it, and the patch is not
            // sent a temp basal while one runs
            guard self.state.bolusState == .noBolus else {
                self.log.error("Pump is in bolus state...")
                completion(.deviceState(MedtrumConnectError.isBolussing))
                return
            }

            // The status of the reconnect may have found it suspended
            guard self.state.basalState != .suspended else {
                self.log.error("Pump is suspended...")
                completion(.deviceState(MedtrumConnectError.isSuspended))
                return
            }

            // When the temp basal so far ended, if a cancel ended it - and the answer, which names the record the patch
            // wrote for it
            var cancelledAt: Date?
            var cancelAnswer: CancelTempBasalPacketResponse?

            if self.state.basalState == .tempBasal {
                // Need to cancel temp basal first before setting temp basal
                let cancelSentAt = Date.now
                let cancelResult = self.link.write(CancelTempBasalPacket())
                if case let .failure(error) = cancelResult {
                    // Unanswered, the patch may have stopped it: it stays running, counted, until a status says
                    let outcome = MedtrumCommandOutcome(error)
                    self.log.error("Failed to cancel temp basal (\(outcome)): \(error.localizedDescription)")
                    if outcome == .unknown {
                        self.noteUnansweredCancel(sentAt: cancelSentAt)
                        completion(.uncertainDelivery)
                    } else {
                        completion(.communication(error))
                    }
                    return
                }
                cancelledAt = Date.now

                // Cancelling ends the temp basal, which is exactly when the patch writes its record -
                // so this response carries the number of the record it just wrote for it
                if case let .success(data) = cancelResult, let response = data as? CancelTempBasalPacketResponse {
                    self.adoptRecordSequence(response.basalSequence, from: "Cancel temp basal")
                    self.noteAnsweredSegment(startingAt: response.basalStartTime)
                    cancelAnswer = response
                }

                self.state.basalState = .active
                self.log.info("Cancelled temp basal!")
            }

            if duration < .ulpOfOne {
                // Need to cancel temp basal, but is already cancelled
                // Only need to report back to algorithm
                self.reportScheduledBasal(endedBy: cancelAnswer)

                completion(nil)
                return
            }

            let sentAt = Date.now
            let sentUptime = self.uptime()
            let sequenceAtSend = self.state.currentSequenceNumber
            let priorSegmentStart = self.doseReportLock.withLock { self.state.lastSegmentStart }

            let packet = SetTempBasalPacket(rate: unitsPerHour, duration: duration)
            let tempBasalResult = self.link.write(packet)
            let outcome = MedtrumCommandOutcome(tempBasalResult)

            if case let .failure(error) = tempBasalResult, outcome != .unknown {
                self.log.error("Failed to set temp basal (\(outcome)): \(error.localizedDescription)")

                // the cancel already succeeded, but new TBR failed - the patch is running the scheduled basal now
                self.reportScheduledBasal(endedBy: cancelAnswer)

                completion(.communication(error))
                return
            }

            // The response describes the segment that just started. The sequence in it belongs to the segment this
            // one replaced, not to this one.
            var response: SetTempBasalResponse?
            if case let .success(data) = tempBasalResult {
                response = data as? SetTempBasalResponse
            }
            if let response {
                self.adoptRecordSequence(response.basalSequence, from: "Set temp basal")
                self.noteAnsweredSegment(startingAt: response.basalStartTime)
            }

            // Only the segment we asked for is ours: anything else, or no answer at all, and the patch may or may not
            // be running it
            guard let response, RecordSyncer.isCommandedTempBasal(response, rate: unitsPerHour) else {
                if let response {
                    self.log.error(
                        "Set temp basal answered with a \(response.basalType) segment at \(response.basalValue) U/h " +
                            "from \(response.basalStartTime), not the temp basal of \(unitsPerHour) U/h we set"
                    )
                }

                // Kept before the batch below goes out, so the state saved with it has it
                self.keepUnconfirmedTempBasal(
                    UnfinalizedDose(
                        tempRate: unitsPerHour,
                        duration: duration,
                        insulinType: self.state.insulinType,
                        automatic: automatic,
                        confirmation: .uncertain,
                        startDate: sentAt
                    ),
                    sentAt: sentAt,
                    sentUptime: sentUptime,
                    sequenceAtSend: sequenceAtSend,
                    priorSegmentStart: priorSegmentStart
                )

                // What the host was told stands: the temp basal before ended at the cancel, then the schedule. With
                // the set unanswered the link may be gone: its record is not read now - our estimate stands in, and a
                // sync reads the record later, changing nothing.
                if let cancelledAt, self.state.basalDose.type == .tempBasal {
                    self.reportScheduledBasal(tempBasalEndedAt: cancelledAt, endedBy: outcome == .unknown ? nil : cancelAnswer)
                }

                completion(.uncertainDelivery)
                return
            }

            self.log.info("Set temp basal!")

            let tempBasalDose = UnfinalizedDose(
                tempRate: unitsPerHour,
                duration: duration,
                insulinType: self.state.insulinType,
                automatic: automatic
            )
            tempBasalDose.noteCommand(sentAt: sentAt, uptime: sentUptime, sequence: sequenceAtSend)

            // The patch's own clock, where its records start
            tempBasalDose.setPumpStartTime(response.basalStartTime)
            let skew = response.basalStartTime.timeIntervalSince(tempBasalDose.startDate)
            self.log.info("Temp basal patch start \(response.basalStartTime) (skew \(String(format: "%+.1f", skew))s)")

            // The old one ends where the new one starts, final - from the record the cancel named - and both go out in
            // one batch
            self.replaceRunningBasal(endedBy: cancelAnswer) {
                self.state.basalState = .tempBasal
                self.state.lastSync = Date.now
                return (tempBasalDose, NewPumpEvent.tempBasal(dose: tempBasalDose.toDoseEntry(isMutable: true)))
            }
            self.notifyStateDidChange()

            completion(nil)
        }
    }

    /// `tempBasalEndedAt`: when the temp basal running so far stopped. `endedBy`: the answer to the cancel that stopped
    /// it, which names its record.
    private func reportScheduledBasal(tempBasalEndedAt: Date = Date.now, endedBy cancel: CancelTempBasalPacketResponse? = nil) {
        replaceRunningBasal(endedBy: cancel) {
            let basalDose = UnfinalizedDose(
                basalRate: state.currentBaseBasalRate,
                insulinType: state.insulinType,
                startDate: tempBasalEndedAt
            )
            state.lastSync = Date.now
            return (basalDose, NewPumpEvent.basal(dose: basalDose.toDoseEntry()))
        }
        notifyStateDidChange()
    }

    /// The basal `change` returns takes over from the running one, and both go out in one batch: a temp basal running
    /// till then ends where the new basal starts, final - from its records, read right here up to the one the cancel
    /// that ended it named (`endedBy`), else from our estimate. `change` runs under `doseReportLock`, sets the rest of
    /// the state the batch is saved with, and returns the new basal and its report - nil to change nothing. A command's
    /// path, holding `commandLock`: no other command comes between its answer and these reads, which block on the link
    /// for `tempBasalEndReadBudget` at most. The host has the state before they start - handed over first, outside that
    /// budget (`stateHandOverTimeout`): killed during them, the app comes back with the new basal running and the temp
    /// basal ended, finalized then from our estimate.
    private func replaceRunningBasal(
        endedBy cancel: CancelTempBasalPacketResponse? = nil,
        _ change: () -> (dose: UnfinalizedDose, event: NewPumpEvent)?
    ) {
        doseReportLock.withLock {
            guard let next = change() else {
                return
            }

            // A temp basal a status ended meanwhile - the cancel's scheduled basal, shown while the set awaited its
            // answer, or the suspend the patch announced - goes out final from the records it names, and the new basal
            // after it, in the same batch: the state handed over before they are read has the new basal running
            let running = state.basalDose
            if let pending = pendingTempBasalEndStorage, running.type != .tempBasal || running.isFinished {
                pending.then.append(next.event)
                state.basalDose = next.dose
                return
            }

            let ending = beginTempBasalEnd(
                endedAt: next.dose.startDate,
                patchEnd: cancel?.basalStartTime,
                lastRecord: cancel.map { Int($0.basalSequence) },
                then: [next.event]
            )
            state.basalDose = next.dose
            if !ending {
                emitPumpEvents([next.event])
            }
        }

        guard let ending = pendingTempBasalEnd else {
            return
        }

        // Nothing to hand over for when nothing will be read: the batch settling it saves the state with it
        if RecordSyncer.wouldRead(ending, pumpManager: self) {
            handOverState(before: "reading the records")
        }
        RecordSyncer.finishTempBasalEnd(
            pumpManager: self,
            inCommandUntil: now().addingTimeInterval(Self.tempBasalEndReadBudget)
        )
    }

    /// Hands the state to the host, and waits until it has it - `stateHandOverTimeout` at most: a command is about to
    /// read the records of the temp basal it ended, a round trip or more on the link, and only then does the batch go
    /// out that saves the state with it - or to write a bolus, which a kill before its answer must not lose, or to fail
    /// one, which a kill after must not bring back. Best effort: a host slower than that is not waited for. Not holding
    /// `doseReportLock`, nor on the delegate queue.
    private func handOverState(before action: String) {
        let handedOver = DispatchSemaphore(value: 0)
        pumpDelegate.notify { delegate in
            delegate?.pumpManagerDidUpdateState(self)
            handedOver.signal()
        }

        if handedOver.wait(timeout: .now() + Self.stateHandOverTimeout) == .timedOut {
            log.warning("The host did not take the state within \(Int(Self.stateHandOverTimeout)) s, \(action) anyway")
        }
    }

    /// How long a command waits for the host to take the state before it reads records, or writes or fails a bolus
    private static let stateHandOverTimeout: TimeInterval = 3

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

            let result = self.link.write(SuspendPumpPacket(duration: duration))
            if case let .failure(error) = result {
                self.log.error("Failed to suspend delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            // The patch announces the suspend right away, with its exact time, and that status usually beats this:
            // it dated the suspend and ended the temp basal there already - its records are read here. Otherwise now,
            // as near as we know, and the temp basal is finalized from our estimate: no record of its end is known.
            let start = Date.now
            self.replaceRunningBasal {
                // Before the batch: the state saved with it is suspended
                self.state.basalState = .suspended
                self.state.lastSync = Date.now

                guard self.state.basalDose.type != .suspend else {
                    return nil
                }

                let basalDose = UnfinalizedDose(suspendStartTime: start)
                return (basalDose, NewPumpEvent.suspend(dose: basalDose.toDoseEntry()))
            }
            self.notifyStateDidChange()

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

            let response = self.link.write(ResumePumpPacket())
            if case let .failure(error) = response {
                self.log.error("Failed to resume delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            self.log.info("Resumed delivery!")

            // The answer carries the segment the patch resumed with, started at the resume on its clock
            var segmentStart: Date?
            if case let .success(data) = response, let answer = data as? ResumePumpPacketResponse,
               let start = answer.basalStartTime
            {
                segmentStart = start
                if let sequence = answer.basalSequence {
                    self.adoptRecordSequence(sequence, from: "Resume")
                }
                self.noteAnsweredSegment(startingAt: start)
            }

            // Read and replaced in one step - see `doseReportLock`. A status showing the scheduled basal may have
            // reported the resume already.
            self.replaceRunningBasal {
                // Before the batch: the state saved with it is resumed
                self.state.basalState = .active
                self.state.lastSync = Date.now

                guard self.state.basalDose.type == .suspend || self.state.basalDose.type == .tempBasal else {
                    return nil
                }

                let resumedAt = segmentStart.map {
                    self.patchTimeOnOurClock($0, notBefore: self.state.basalDose.startDate, notAfter: Date.now)
                } ?? Date.now
                let resumeDose = UnfinalizedDose(resumeStartTime: resumedAt, insulinType: self.state.insulinType)

                // A temp basal still taken to run stopped at the suspend for good (the patch resumes the schedule):
                // ended at the resume at the latest, final from our estimate - no record of its end is known
                return (resumeDose, NewPumpEvent.resume(dose: resumeDose.toDoseEntry()))
            }
            self.notifyStateDidChange()

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
            let result = self.link.write(packet)

            if case let .failure(error) = result {
                self.log.error("Failed to sync basal schedule: \(error.localizedDescription)")
                // Unanswered, the patch may have set it all the same - and split the temp basal running
                if MedtrumCommandOutcome(error) == .unknown, self.disableRecordMatchOfRunningTempBasal(unanswered: true) {
                    self.notifyStateDidChange()
                }
                completion(.failure(error))
                return
            }

            self.disableRecordMatchOfRunningTempBasal()

            self.state.basalSchedule = schedule
            self.state.lastSync = Date.now
            self.notifyStateDidChange()

            self.log.info("Basal schedule sync complete!")

            completion(.success(basalSchedule))
        }
    }

    /// The patch restarts a running temp basal in a new segment on a profile change, so it ends up with a record per
    /// segment, and the amount its statuses show restarts: it is finalized from our estimate, its rate × duration. The
    /// same for the unconfirmed temp basal, which the patch may be running - a record of a part of it would finalize it
    /// with that part. `unanswered`: the profile command went out and no answer came back. Returns whether it applied.
    @discardableResult private func disableRecordMatchOfRunningTempBasal(unanswered: Bool = false) -> Bool {
        doseReportLock.withLock { () -> Bool in
            let candidates = [state.basalDose, state.unconfirmedTempBasal].compactMap { $0 }
            var applied = false

            for tempBasal in candidates where tempBasal.type == .tempBasal && tempBasal.disableRecordMatch() {
                applied = true
                log.warning(
                    "Basal profile \(unanswered ? "sent unanswered" : "set") during the temp basal of " +
                        "\(tempBasal.startDate)\(tempBasal === state.unconfirmedTempBasal ? ", whose command went unanswered" : ""), " +
                        "the patch \(unanswered ? "may have split" : "split") it into segments: it will be finalized " +
                        "from our estimate, its rate × duration, not from its records"
                )
            }

            return applied
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

        link.ensureConnected { error in
            // Reported at once, not once the operation holding the lock is over
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure(reason: error.errorDescription ?? "EMPTY")))
                return
            }

            guard self.lockCommandLock() else {
                completion(.failure(error: .connectionFailure(reason: "another operation held the patch")))
                return
            }
            defer { self.commandLock.unlock() }

            guard !self.state.pumpState.isTerminated else {
                self.log.error("Cannot prime, patch session is over: \(self.state.pumpState.description)")
                completion(.failure(error: .patchNotPrimeable(state: self.state.pumpState)))
                return
            }

            guard self.state.pumpState.isBeforePriming else {
                self.log.info("Patch is already priming or primed!")
                completion(.success)
                return
            }

            guard self.state.pumpState == .filled else {
                self.log.warning("Patch is not filled yet, refusing to prime. State: \(self.state.pumpState)")
                completion(.failure(error: .patchNotFilled(state: self.state.pumpState)))
                return
            }

            let primeResult = self.link.write(PrimePacket())
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

        link.ensureConnected { error in
            // Reported at once, not once the operation holding the lock is over
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure(reason: error.errorDescription ?? "EMPTY")))
                return
            }

            guard self.lockCommandLock() else {
                completion(.failure(error: .connectionFailure(reason: "another operation held the patch")))
                return
            }
            defer { self.commandLock.unlock() }

            guard !self.state.pumpState.isTerminated else {
                self.log.error("Cannot activate, patch session is over: \(self.state.pumpState.description)")
                completion(.failure(error: .patchNotActivatable(state: self.state.pumpState)))
                return
            }

            guard !self.state.pumpState.isRunning else {
                // The patch activated, but its answer was lost: the session it starts is not started yet
                if self.state.patchSessionEnded {
                    // Its id is not taken from what the connect synced, which can be stale with no session: the first
                    // status after this sets it, and payloads are not checked against an id until then. It may have
                    // suspended since - the connect synced its status, and notifications keep it current while connected.
                    self.log.warning("Patch already activated, but its session was not started - starting it")
                    let start = Date.now
                    // It activated before now: at the start time the connect synced, if that is the new patch's. The
                    // previous patch's - kept since, or synced before it disconnected - is from before its deactivation.
                    let activatedAt: Date
                    if let syncedActivation = self.state.patchActivatedAt,
                       let deactivatedAt = self.state.previousPatch?.deactivatedAt,
                       syncedActivation > deactivatedAt, syncedActivation <= start
                    {
                        activatedAt = syncedActivation
                    } else {
                        activatedAt = start
                    }
                    self.startPatchSession(
                        patchId: Data(),
                        at: start,
                        activatedAt: activatedAt,
                        isDelivering: self.state.pumpState.isDelivering
                    )
                }

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
            let result = self.link.write(packet)
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

                let start = Date.now
                self.startPatchSession(patchId: data.patchId, at: start, activatedAt: start, isDelivering: true)

                self.log.info("Patch activated!")
                completion(.success)
                return
            }
        }
    }

    func deactivatePatch(_ completion: @escaping (MedtrumDeactivatePatchResult) -> Void) {
        log.info("Deactivate patch pump...")

        // The sync that runs as part of connecting can find that the base has reset, and end the
        // session before we get to stop it - see `handleBaseReset`. It also drops the link, which
        // usually fails the connect. Either way the patch is no longer active.
        let hadActivePatch = !state.pumpState.isSetup
        let sessionEndedWhileConnecting = { hadActivePatch && self.state.pumpState.isSetup }

        link.ensureConnected { error in
            if sessionEndedWhileConnecting() {
                self.log.info("Patch session already ended while connecting, nothing left to deactivate")
                completion(.success)
                return
            }

            // Reported at once, not once the operation holding the lock is over
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(.failure(error: .connectionFailure))
                return
            }

            guard self.lockCommandLock() else {
                completion(.failure(error: .connectionFailure))
                return
            }
            defer { self.commandLock.unlock() }

            // Or while it waited for the operation ahead of it
            if sessionEndedWhileConnecting() {
                self.log.info("Patch session ended while waiting to deactivate, nothing left to deactivate")
                completion(.success)
                return
            }

            self.isDeactivatingPatch = true
            defer { self.isDeactivatingPatch = false }

            // The last chance to read this session's records: what is not read now is finalized from our estimate
            RecordSyncer.syncRecords(pumpManager: self, trigger: .beforeStop)

            let result = self.link.write(StopPatchPacket())
            if case let .failure(error) = result {
                self.log.error("Failed to deactivate pump: \(error)")
                completion(.failure(error: .unknownError(reason: error.localizedDescription)))
                return
            }

            // Connected: the connect synced the patch's status, and its notifications have kept it current since
            self.endPatchSession(at: Date.now, statusIsCurrent: true, disconnect: false)

            self.log.info("Patch deactivated")
            completion(.success)

            self.link.disconnect(force: true)
        }
    }

    func forceDeactivatePatch() {
        log.info("Force deactivating patch...")
        endPatchSession(at: Date.now, statusIsCurrent: false)
    }

    /// The base rebooted underneath an activated patch: it came back as a blank, never activated
    /// patch and is not delivering anything. The session cannot be resumed, so it ends here.
    func handleBaseReset(deliveryStoppedAt: Date) {
        log.error("Pump base has reset, patch session is lost - delivery stopped at \(deliveryStoppedAt)")

        // A terminated patch has already raised its own alert, and was not delivering anyway
        let wasRunning = state.pumpState.isRunning

        // What the patch did last is as of the last status of it, before the base went down
        endPatchSession(at: deliveryStoppedAt, statusIsCurrent: false)

        if wasRunning {
            emitAlert(alertType: .baseResetNotification)
        }
    }

    /// The new patch delivers on its schedule from `start` - unless it is not delivering: then the suspend reported stays
    /// outstanding, for the first status that shows it delivering to resume. Its expiry counts from `activatedAt`.
    private func startPatchSession(patchId: Data, at start: Date, activatedAt: Date, isDelivering: Bool) {
        if state.expiryMode == .default {
            // Issued now, due a set time after the activation
            let delay = max(0, state.notificationAfterActivation - start.timeIntervalSince(activatedAt))
            emitAlert(alertType: .patchExpiredNotification(after: delay))
        }

        // From the finals until they are handed over - see `doseReportLock`
        doseReportLock.withLock {
            var events: [NewPumpEvent] = []
            if !state.patchSessionEnded {
                // The previous patch was replaced without deactivating it - it fell off, or was swapped outside the app.
                // When it stopped is unknown, so it is taken to have delivered until `start`: a temp basal or a bolus in
                // flight ends there, and the schedule runs from there. No suspend: a host can take one with a resume at
                // the same time as never ending.
                log.warning("Previous patch session was not ended, ending its delivery at activation")
                events.append(contentsOf: finalizedTempBasal(endedAt: start))
                events.append(contentsOf: finalizeInterruptedBolus())
            }
            // Normally none left: the previous session finalized its doses when it ended
            events.append(contentsOf: finalizeAllAwaitingDoses(because: "a new patch was activated"))
            dropUnconfirmedTempBasal(because: "a new patch was activated")

            events.append(NewPumpEvent.replacedPump(date: start))
            if isDelivering {
                let resumeDose = UnfinalizedDose(
                    resumeStartTime: start,
                    insulinType: state.insulinType
                )
                if state.basalDose.type == .suspend {
                    // Only a suspend that was reported gets a resume: a host can take one without it as suspended before it
                    events.append(NewPumpEvent.resume(dose: resumeDose.toDoseEntry()))
                } else if !state.patchSessionEnded {
                    let basalDose = UnfinalizedDose(
                        basalRate: state.currentBaseBasalRate,
                        insulinType: state.insulinType,
                        startDate: start
                    )
                    events.append(NewPumpEvent.basal(dose: basalDose.toDoseEntry()))
                }

                state.basalDose = resumeDose
                // What commands check: the old patch may have left it suspended or running a temp basal, and it would
                // stay so until the first status that shows the new patch's basal
                state.basalState = .active
            } else {
                // A resume now would count the time until the patch resumes as delivered. The suspend outstanding - the
                // old session's, or one the status that showed it suspended recorded - stays, for the first status that
                // shows it delivering to resume.
                state.basalState = .suspended
            }

            state.patchSessionEnded = false
            state.initialReservoir = nil
            state.patchId = patchId
            // Record numbers restart with the patch
            state.resetRecordSequence()
            state.lastSegmentStart = nil
            recordStore.clear()
            state.patchActivatedAt = activatedAt
            state.lastSync = Date.now
            notifyStateDidChange()

            emitPumpEvents(events)
        }
    }

    /// The one place a patch session ends: deactivation, a forced deactivation, and a base reset. Its records are out
    /// of reach from here on, so everything still running or waiting on a record is finalized now, from our estimate.
    /// Delivery stopped at `deliveryStoppedAt`, unless it is known to have stopped already - `statusIsCurrent`: the
    /// patch's state as last reported is its state now.
    private func endPatchSession(at deliveryStoppedAt: Date, statusIsCurrent: Bool, disconnect: Bool = true) {
        // From the finals until they are handed over - see `doseReportLock`
        doseReportLock.lock()
        defer { doseReportLock.unlock() }

        // Delivery cannot have stopped before the running dose began
        let stoppedAt = max(deliveryStoppedAt, state.basalDose.startDate)

        // Ended already - a force after a deactivation, or no session started since: the previous patch is recorded
        if !state.patchSessionEnded {
            state.previousPatch = PreviousPatch(
                patchId: state.patchId,
                lastStateRaw: state.pumpState.rawValue,
                lastSyncAt: state.lastSync,
                battery: state.battery,
                activatedAt: state.patchActivatedAt ?? Date.distantPast,
                deactivatedAt: stoppedAt,
                initialReservoirLevel: state.initialReservoir,
                reservoirLevel: state.reservoir
            )
        }

        // Suspended already - by the patch halting, or by a suspend - its suspend was reported then. A second, later one
        // would have a host that keeps only the last count the time between the two as delivered. That holds only while
        // the patch can't have resumed: a suspend can end on its own, unseen while out of range, so it takes a state the
        // patch never leaves, one it never delivered in or no longer does, or a current one that shows it not delivering.
        // Otherwise the suspend is reported now.
        let hasStopped = state.basalDose.type == .suspend &&
            (state.pumpState.isTerminated || state.pumpState.isSetup || (statusIsCurrent && !state.pumpState.isDelivering))

        var events = finalizedTempBasal(endedAt: stoppedAt)
        events.append(contentsOf: finalizeInterruptedBolus())
        events.append(contentsOf: finalizeAllAwaitingDoses(because: "the patch session ended"))
        if !hasStopped {
            let suspendDose = UnfinalizedDose(suspendStartTime: stoppedAt)
            events.append(NewPumpEvent.suspend(dose: suspendDose.toDoseEntry()))
            state.basalDose = suspendDose
        }
        dropUnconfirmedTempBasal(because: "the patch session ended")

        state.patchId = Data()
        state.resetRecordSequence()
        state.lastSegmentStart = nil
        recordStore.clear()
        state.pumpState = .none
        state.backupSessionToken = state.sessionToken
        state.sessionToken = Data()
        state.initialReservoir = nil
        state.patchSessionEnded = true
        state.lastSync = Date.now
        state.basalState = .suspended
        notifyStateDidChange()

        emitPumpEvents(events)

        if disconnect {
            link.disconnect(force: true)
        }
    }

    func clearAlert(alertType: AlertType, completion: @escaping (Bool) -> Void) {
        log.info("Clearing alert - alertType: \(alertType.rawValue)")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect to pump: \(error)")
                completion(false)
                return
            }

            let clearAlertResult = self.link.write(ClearAlertPacket(alertType: alertType))
            if case let .failure(error) = clearAlertResult {
                self.log.error("Failed to clear alert: \(error)")
                completion(false)
                return
            }

            let resumeResult = self.link.write(ResumePumpPacket())
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
            let result = self.link.write(package)
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
        refreshLogDeviceIdentifier()

        // synchronously, on the path that mutated the bolus dose
        for reporter in bolusProgressReporters.value {
            reporter.update()
        }

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

    /// `completed: false` in a status received at `receivedAt`: the running bolus has delivered this much so far.
    /// Never from a status received before its command went out, nor from a full status for one whose command went
    /// unanswered - a full status never confirms that one. A notification's does: the patch is delivering it.
    func updateBolusProgress(delivered: Double, fullSync: Bool, receivedAt: Date, receivedUptime: TimeInterval) {
        let outcome = doseReportLock.withLock { () -> (dose: UnfinalizedDose, confirmed: Bool)? in
            guard let doseEntry = state.bolusDose else {
                return nil
            }

            let running = doseEntry.snapshot
            guard !running.isFinished,
                  !Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime),
                  !(fullSync && running.confirmation == .uncertain)
            else {
                return nil
            }

            let progress = doseEntry.updateProgress(delivered: delivered)
            return progress.taken ? (doseEntry, progress.confirmed) : nil
        }

        if let outcome, outcome.confirmed {
            log.info("The patch reports delivering the bolus of \(outcome.dose.startDate) whose command went unanswered: confirmed")
        }
    }

    /// A completion notification received at `receivedAt`: a notification carries the field only while a bolus runs,
    /// so it is the running bolus's own, with what it delivered - a tiny one included, which completes before any
    /// progress. A full status's completion is not this: it repeats the last bolus's for hours. Returns whether the
    /// running bolus took it.
    @discardableResult func completeBolus(
        delivered: Double,
        receivedAt: Date,
        receivedUptime: TimeInterval,
        endedAt: Date? = nil
    ) -> Bool {
        let completed = doseReportLock.withLock { () -> Bool in
            guard let doseEntry = state.bolusDose else {
                return false
            }

            let running = doseEntry.snapshot
            guard !running.isFinished,
                  !Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime)
            else {
                return false
            }

            if running.confirmation == .uncertain {
                log.info("The patch reports completing the bolus of \(doseEntry.startDate) whose command went unanswered")
            }

            var events = runningTempBasal()
            events.append(contentsOf: awaitRecord(doseEntry, .completed, deliveredUnits: delivered, endedAt: endedAt ?? Date.now))
            state.bolusDose = nil
            state.lastSync = Date.now
            emitPumpEvents(events)
            return true
        }

        guard completed else {
            return false
        }

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

        return true
    }

    struct EarlyBolusCompletion {
        let delivered: Double
        /// The newest record the notification names, if it does: the bolus's own, written as it completed
        let record: Int?
        let receivedAt: Date
        let receivedUptime: TimeInterval
    }

    /// A completion notification with no bolus running to take it, received at `receivedAt`, naming `record` as the
    /// newest if it does. The bolus sent and not yet answered's - the patch delivers a small one before it answers -
    /// if the record is past every one known when it went out, or no cancelled bolus is there to take it: kept for it,
    /// taken once it runs (`completeBolusEarly`). Otherwise the completion of the bolus a cancel just ended
    /// (`raiseCancelledBolus`).
    func noteCompletionWithNoBolusRunning(delivered: Double, record: Int?, receivedAt: Date, receivedUptime: TimeInterval) {
        let registeredSince = doseReportLock.withLock { () -> Bool in
            // Registered since `completeBolus` looked: its answer, handled on this queue, woke the command meanwhile
            guard state.bolusDose == nil else {
                return true
            }

            if let pending = state.pendingBolus, isCompletion(record: record, of: pending) {
                log.info(
                    "Completion of \(delivered) U, record \(record.map { "#\($0)" } ?? "-"), before the answer to the " +
                        "bolus of \(pending.units) U sent at \(pending.sentAt): kept for it"
                )
                earlyBolusCompletion = EarlyBolusCompletion(
                    delivered: delivered,
                    record: record,
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                )
                return false
            }

            raiseCancelledBolus(delivered: delivered)
            return false
        }

        if registeredSince, !completeBolus(delivered: delivered, receivedAt: receivedAt, receivedUptime: receivedUptime) {
            raiseCancelledBolus(delivered: delivered)
        }
    }

    /// Whether a completion naming `record`, if it does, is that of the bolus `pending` - sent, not yet answered: past
    /// every record known when it went out, no earlier bolus's. Unless one a cancel ended moments ago went unanswered,
    /// its number unknown; with no record, unless one a cancel ended moments ago is there to take it.
    private func isCompletion(record: Int?, of pending: PendingBolus) -> Bool {
        let cancelled = recentlyCancelledBolus()
        guard let record else {
            return cancelled == nil
        }
        return record > pending.sequenceAtSend && (cancelled.map { $0.snapshot.recordSequence != nil } ?? true)
    }

    /// `dose`, just registered, completed before its answer came - as `early` says, unless it is not its completion: it
    /// names another record than the answer gave, says more was delivered than it was for, or came before it went out.
    /// Then it is a cancelled bolus's, if any. Returns whether it ended `dose`.
    @discardableResult private func completeBolusEarly(_ dose: UnfinalizedDose, _ early: EarlyBolusCompletion) -> Bool {
        // Its completion came again since, and ended it
        guard !dose.snapshot.isFinished else {
            return true
        }

        var notIts: String?
        if let record = early.record, let answered = dose.snapshot.recordSequence, record != answered {
            notIts = "it names record #\(record), the bolus is #\(answered)"
        } else if early.delivered > dose.value + Self.bolusCompletionTolerance {
            notIts = "the bolus was for \(dose.value) U"
        } else if !completeBolus(
            delivered: early.delivered,
            receivedAt: early.receivedAt,
            receivedUptime: early.receivedUptime,
            endedAt: early.receivedAt
        ) {
            notIts = "it came before the bolus went out"
        }

        guard let notIts else {
            log.info("The bolus of \(dose.startDate) completed before its answer came: \(early.delivered) U")
            return true
        }

        log.warning("The completion of \(early.delivered) U before the answer is not the bolus of \(dose.startDate)'s: \(notIts)")
        raiseCancelledBolus(delivered: early.delivered)
        return false
    }

    /// Half a 0.05 U step
    private static let bolusCompletionTolerance = 0.025

    /// The bolus a cancel ended moments ago, still waiting on its record - its completion is yet to come
    private func recentlyCancelledBolus() -> UnfinalizedDose? {
        let cutoff = Date.now.addingTimeInterval(-Self.cancelledBolusCompletionWindow)
        return state.awaitingRecord.last(where: { dose in
            let snapshot = dose.snapshot
            return dose.type == .bolus && snapshot.finishReason == .cancelled && !snapshot.isFinalized &&
                (snapshot.finishedAt ?? .distantPast) > cutoff
        })
    }

    /// A completion notification with no bolus running to take it: the patch's completion of the bolus a cancel just
    /// ended, with what it really delivered. Raises the amount the cancel kept, never lowers it.
    func raiseCancelledBolus(delivered: Double) {
        doseReportLock.withLock {
            guard let cancelled = recentlyCancelledBolus() else {
                return
            }

            // Logged whatever it says, 0 U included: what the patch itself says the cancelled bolus delivered
            let kept = cancelled.deliveredUnits
            let raised = cancelled.raiseAfterEnd(to: delivered)
            log.info(
                "Completion of \(delivered) U after the cancel of the bolus of \(cancelled.startDate), record " +
                    "\(cancelled.snapshot.recordSequence.map { "#\($0)" } ?? "-"): " +
                    (raised ? "raising its amount from \(kept) U" : "keeping its \(kept) U")
            )
            guard raised else {
                return
            }
            // A temp basal's records being read: their batch carries it, waiting on its record
            emitPumpEvents([], unlessTempBasalEndPending: true)
        }
    }

    /// The completion the patch sends after a cancel comes within a second or so
    private static let cancelledBolusCompletionWindow: TimeInterval = .minutes(2)

    /// A full status received at `receivedAt`, past the running bolus's deadline: it is over, and we never saw how it
    /// ended - the link was lost. Counted in full until its record says otherwise.
    func checkBolusDone(receivedAt: Date, receivedUptime: TimeInterval) {
        let ended = doseReportLock.withLock { () -> UnfinalizedDose.State? in
            guard let doseEntry = state.bolusDose else {
                return nil
            }

            let running = doseEntry.snapshot
            guard !running.isFinished, now() >= doseEntry.deliveryDeadline(of: running),
                  !Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime)
            else {
                return nil
            }

            var events = runningTempBasal()
            events.append(contentsOf: awaitRecord(doseEntry, .completionNotSeen, endedAt: nil))
            state.bolusDose = nil
            state.lastSync = Date.now
            emitPumpEvents(events)
            return running
        }

        guard let ended else {
            return
        }

        if ended.confirmation == .uncertain {
            log.warning(
                "The bolus whose command went unanswered is past its deadline, last reported \(ended.deliveredUnits) U: " +
                    "counted in full until its record says otherwise"
            )
        } else {
            log.warning("Bolus ended unseen... last reported \(ended.deliveredUnits) U, counted in full until its record")
        }

        notifyStateDidChange()

        // One whose command went unanswered was warned of then
        guard ended.confirmation == .confirmed else {
            return
        }

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
        }
    }

    enum HeartbeatSync {
        /// A full status, then the records
        case full
        /// The records doses are waiting on only
        case records
    }

    /// What a heartbeat syncs, if anything: a full status when the last one is stale, or when a running bolus is past
    /// its deadline - only a full status settles it, and dosing is refused until then, so it does not wait for the
    /// loop. Otherwise the records doses wait on, once the patch has written them - not while a bolus runs.
    internal func heartbeatSync() -> HeartbeatSync? {
        // Its records are being read, on the link: a full status's Synchronize would go out ahead of them, eating into
        // their budget. The next heartbeat syncs instead.
        if let ending = pendingTempBasalEnd {
            log.debug("Skipping sync, the records of the temp basal of \(ending.dose.startDate) are being read")
            return nil
        }

        let age = Date.now.timeIntervalSince(state.lastSync)
        let isBolusOverdue = isRunningBolusOverdue
        let isFullSyncDue = age > Self.heartbeatSyncFreshnessInterval ||
            (isBolusOverdue && age > Self.overdueBolusSyncInterval)

        guard isFullSyncDue || hasPendingRecordWork else {
            return nil
        }

        guard state.bolusState == .noBolus || (isBolusOverdue && isFullSyncDue) else {
            log.debug("Skipping sync, pump is currently bolusing")
            return nil
        }

        return isFullSyncDue ? .full : .records
    }

    /// A running bolus past its deadline - a full status settles it
    internal var isRunningBolusOverdue: Bool {
        guard let doseEntry = state.bolusDose else {
            return false
        }
        let running = doseEntry.snapshot
        return !running.isFinished && now() >= doseEntry.deliveryDeadline(of: running)
    }

    /// Tells the host that `dose` may or may not have been delivered - once, and saved with the state
    private func warnOfUncertainBolus(_ dose: UnfinalizedDose) {
        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            guard dose.noteUncertaintyReported() else {
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
            self.notifyStateDidChange()
        }
    }

    /// In a new run's state, a SetBolus still pending went out and the app was gone before its answer: the patch may be
    /// delivering it. It runs from here on as a bolus whose command went unanswered does (`enactBolus`), dated from when
    /// it went out - its deadline and the window its record is looked for in count from then. Not if its dose was
    /// registered: the state was saved as it was, read in part before. The host is told of it, and warned, as soon as it
    /// can be - and so of one whose command went unanswered in the last run that it was never warned of
    /// (`reportBolusFromLastRun`).
    private func takeOverPendingBolus() {
        doseReportLock.withLock {
            if let pending = state.pendingBolus {
                state.pendingBolus = nil

                let registered = ([state.bolusDose].compactMap { $0 } + state.awaitingRecord).contains { dose in
                    dose.type == .bolus && dose.sentAt == pending.sentAt
                }
                if registered {
                    log.info("The bolus of \(pending.units) U sent at \(pending.sentAt) was registered already")
                } else if let running = state.bolusDose {
                    log.error(
                        "The bolus of \(pending.units) U sent at \(pending.sentAt) is pending, with the bolus of " +
                            "\(running.startDate) running - keeping that one"
                    )
                } else {
                    let dose = UnfinalizedDose(
                        units: pending.units,
                        duration: estimatedDuration(toBolus: pending.units),
                        activationType: pending.automatic ? .automatic : .manualNoRecommendation,
                        insulinType: state.insulinType,
                        confirmation: .uncertain,
                        startDate: pending.sentAt
                    )
                    dose.noteCommand(sentAt: pending.sentAt, uptime: nil, sequence: pending.sequenceAtSend)

                    // Answered, the state saved before its dose was registered: its answer, kept for its record, is
                    // the one past `sequenceAtSend` - every number claimed before it went out is at or below that, and
                    // commands go one at a time. The latest, should there be more.
                    if let answered = state.answeredBolusRecords.last(where: { $0 > pending.sequenceAtSend }) {
                        dose.noteAnswer(recordSequence: answered)
                        log.info("The bolus of \(pending.units) U sent at \(pending.sentAt) was answered as record #\(answered)")
                    }

                    state.bolusDose = dose
                    log.error(
                        "The app stopped while the bolus of \(pending.units) U sent at \(pending.sentAt) awaited its " +
                            "answer: it may be delivering. Counted in full until the patch shows it, or its record says " +
                            "otherwise - not sent again"
                    )
                }
            }

            if let bolus = state.bolusDose {
                let running = bolus.snapshot
                if running.confirmation == .uncertain, !running.isFinished, !running.uncertaintyReported {
                    bolusFromLastRun = bolus
                }
            }
        }
    }

    /// Reports `bolusFromLastRun` running, counted in full, and warns the host of it - once there is a host to tell:
    /// on the loop's first sync or the first status of this run, whichever comes first. From then on it is the running
    /// bolus, reported as any.
    internal func reportBolusFromLastRun() {
        guard pumpDelegate.delegate != nil else {
            return
        }

        let dose = doseReportLock.withLock { () -> UnfinalizedDose? in
            guard let dose = bolusFromLastRun else {
                return nil
            }
            bolusFromLastRun = nil

            let running = dose.snapshot
            if state.bolusDose === dose, !running.isFinished {
                emitPumpEvents([NewPumpEvent.bolus(dose: dose.doseEntry(of: running, isMutable: true))], replacePendingEvents: false)
            }
            return dose
        }

        guard let dose else {
            return
        }

        notifyStateDidChange()
        warnOfUncertainBolus(dose)
    }

    /// Takes the record number out of a command response.
    ///
    /// Every command that ends a basal segment answers with the record the patch wrote for it. Adopting
    /// it keeps the counter current between syncs - otherwise it only moves when a status notification
    /// happens to arrive, and the record view sits behind the patch until then.
    private func adoptRecordSequence(_ sequence: Double, from command: String) {
        let sequence = Int(sequence)

        guard sequence >= state.currentSequenceNumber else {
            return
        }

        if sequence > state.currentSequenceNumber {
            log.debug("\(command) wrote record #\(sequence)")
            state.currentSequenceNumber = sequence
        }

        // Written just now, as the command ended a segment: the newest record the patch has
        state.sequenceConfirmedAt = now()
        noteRecordSequenceConfirmedInThisRun(at: now(), uptime: uptime())
    }

    /// A status received at `receivedAt` (`receivedUptime`) says `currentSequenceNumber` is the newest record the patch
    /// has written
    internal func noteRecordSequenceConfirmed(receivedAt: Date, receivedUptime: TimeInterval) {
        let confirmedAt = now().addingTimeInterval(receivedAt.timeIntervalSinceNow)
        state.sequenceConfirmedAt = max(state.sequenceConfirmedAt ?? confirmedAt, confirmedAt)
        noteRecordSequenceConfirmedInThisRun(at: confirmedAt, uptime: receivedUptime)
    }

    private func noteRecordSequenceConfirmedInThisRun(at confirmedAt: Date, uptime confirmedUptime: TimeInterval) {
        guard (state.sequenceConfirmedInThisRun?.uptime ?? -.infinity) < confirmedUptime else {
            return
        }
        state.sequenceConfirmedInThisRun = (at: confirmedAt, uptime: confirmedUptime)
    }

    private func finalizeInterruptedBolus() -> [NewPumpEvent] {
        guard let doseEntry = state.bolusDose else {
            return []
        }

        log.warning(
            "Patch session ended during a bolus... \(doseEntry.deliveredUnits) U of the \(doseEntry.value) U"
        )

        state.bolusDose = nil

        // Final at once: its record can no longer be read. At the last amount reported - one the patch never
        // confirmed counts in full.
        guard doseEntry.finish(.interrupted, endedAt: nil, at: now()), let event = finalize(doseEntry, deliveredUnits: nil)
        else {
            return []
        }

        // One whose command went unanswered was warned of then
        if doseEntry.confirmation == .confirmed {
            pumpDelegate.notify { delegate in
                guard let delegate = delegate else {
                    self.log.warning("No pump delegate, not notifying...")
                    return
                }

                delegate.pumpManager(self, didError: .uncertainDelivery)
            }
        }

        return [event]
    }

    /// `isCommand`: counted as a command from here until `completion` returns, so a record sync neither starts nor
    /// carries on while it runs - see `isCommandActive` - and run holding `commandLock`, once connected. A failed connect
    /// is reported without it.
    private func ensureConnectedAndActive(isCommand: Bool = true, _ completion: @escaping (MedtrumConnectError?) -> Void) {
        guard !state.pumpState.isSetup else {
            log.warning("No active patch, failing immediately")
            completion(.failedToFindDevice)
            return
        }

        let command = isCommand ? beginCommand() : nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                completion(.failedToFindDevice)
                return
            }

            self.link.ensureConnected { error in
                if let command {
                    self.commandConnected(command)
                }

                // Command bodies run synchronously inside the completion (their writes block)
                defer {
                    if let command {
                        self.endCommand(command)
                    }
                }

                // A connect that failed is reported at once, not once the operation holding the lock is over
                guard isCommand, error == nil else {
                    completion(error)
                    return
                }

                guard self.withCommandLock({ completion(error) }) else {
                    completion(.failedToConnectToDevice)
                    return
                }
            }
        }
    }

    /// Runs `body` holding `commandLock` - waiting for the operation holding it to end, as long as a command may take.
    /// Returns false, not having run it, if it does not end by then. Never on the queue answers or statuses arrive on.
    @discardableResult internal func withCommandLock(_ body: () -> Void) -> Bool {
        guard lockCommandLock() else {
            return false
        }
        defer { commandLock.unlock() }

        body()
        return true
    }

    /// Takes `commandLock` as `withCommandLock` does - the caller unlocks it - for the commands that do not go through
    /// `ensureConnectedAndActive`: priming, activating and stopping a patch
    private func lockCommandLock() -> Bool {
        guard commandLock.lock(before: Date.now.addingTimeInterval(Self.commandActivityTimeout)) else {
            log.error("Another operation has held the patch for \(Int(Self.commandActivityTimeout / 60)) min, giving up")
            return false
        }
        return true
    }

    /// Runs `body` holding `commandLock` if no other operation holds it - nil, not having run it, if one does
    internal func withCommandLockIfFree<T>(_ body: () -> T) -> T? {
        guard commandLock.try() else {
            return nil
        }
        defer { commandLock.unlock() }

        return body()
    }

    /// Runs `write` holding `commandLock` - a status or the patch time, asked for between commands: the records a command
    /// reads, a temp basal's it ended, are not held up by it, and it is answered after them. Nil, not having run it, if
    /// the operation holding the patch does not end as long as a command may take. Never on the queue answers or
    /// statuses arrive on.
    internal func betweenCommands<T>(_ write: () -> T) -> T? {
        guard lockCommandLock() else {
            return nil
        }
        defer { commandLock.unlock() }

        return write()
    }

    private func beginCommand() -> UUID {
        let command = UUID()
        let startedAt = Date.now
        activeCommands.mutate { commands in
            commands = commands.filter { startedAt.timeIntervalSince($0.value) < Self.commandActivityTimeout }
            commands[command] = startedAt
        }
        return command
    }

    /// The activity timeout counts from here: a slow reconnect must not use up the time of the command waiting on it
    private func commandConnected(_ command: UUID) {
        let connectedAt = Date.now
        activeCommands.mutate { commands in
            commands[command] = connectedAt
        }
    }

    private func endCommand(_ command: UUID) {
        activeCommands.mutate { commands in
            commands[command] = nil
        }
    }

    /// A command is between asking to connect and its last response. The record sync yields to it: its reads share
    /// the link, and would hold up a bolus or temp basal for as long as they take.
    internal var isCommandActive: Bool {
        let checkedAt = Date.now
        return activeCommands.value.contains { checkedAt.timeIntervalSince($0.value) < Self.commandActivityTimeout }
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
            logEventForDeviceIdentifier: logDeviceIdentifier,
            type: type,
            message: message,
            completion: nil
        )
    }

    /// The current temp basal (if any), reported as still running
    private func runningTempBasal() -> [NewPumpEvent] {
        let dose = state.basalDose
        let running = dose.snapshot
        guard dose.type == .tempBasal, !running.isFinished else {
            return []
        }

        return [NewPumpEvent.tempBasal(dose: dose.doseEntry(of: running, isMutable: true))]
    }

    /// The current temp basal (if any), finalized at once from our estimate as having stopped at `endedAt` - for the end
    /// of a patch session, when its records can no longer be read. Only under `doseReportLock`; the caller emits it.
    private func finalizedTempBasal(endedAt: Date) -> [NewPumpEvent] {
        let dose = state.basalDose
        guard dose.type == .tempBasal, dose.finish(.interrupted, endedAt: endedAt, at: now()) else {
            return []
        }

        return estimateFinal(dose, because: "the patch session ended").map { [$0] } ?? []
    }

    /// The current temp basal (if any) stopped at `endedAt`, finalized at once from our estimate - where its records
    /// cannot be read on the way: a status showing the temp basal whose command went unanswered ran. The caller
    /// replaces `state.basalDose` and emits. Only under `doseReportLock`.
    private func endTempBasalFromEstimate(endedAt: Date, because reason: String) -> [NewPumpEvent] {
        let dose = state.basalDose
        guard dose.type == .tempBasal,
              dose.finish(endedAt >= dose.estimatedEndDate ? .completed : .cancelled, endedAt: endedAt, at: now())
        else {
            return []
        }

        return estimateFinal(dose, because: reason).map { [$0] } ?? []
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

    /// Hands `events` to the host, with every final it has yet to confirm and - with `replacePendingEvents` - every dose
    /// still mutable: the host drops every mutable dose it holds that a replacing batch leaves out.
    ///
    /// Every batch has the state saved first, in the same delegate call: otherwise the host could store it and the app
    /// be killed before the state is saved - a final would come back unfinalized, and a dose the host holds mutable
    /// would be unknown to the restored state and purged by its next replacing batch.
    ///
    /// No temp basal goes out mutable once it ended: the host moves past one as soon as anything after it is stored,
    /// and its final would be lost. One whose records are being read goes out final from our estimate, with what
    /// followed it - see `TempBasalEnd`. So does one waiting on its record in state saved by an earlier build.
    ///
    /// `unlessTempBasalEndPending`: a batch with no events of its own - a full status's, a resend of finals, a raised
    /// cancelled bolus - is not handed over at all while such records are read. The batch the read ends with replaces
    /// pending events, carrying every final and every dose still in flight, and the temp basal final from its records
    /// rather than from our estimate.
    func emitPumpEvents(_ events: [NewPumpEvent], replacePendingEvents: Bool = true, unlessTempBasalEndPending: Bool = false) {
        // The batch is built off `awaitingRecord` and handed to the delegate queue in one go - see `doseReportLock`
        doseReportLock.lock()
        defer { doseReportLock.unlock() }

        if unlessTempBasalEndPending, events.isEmpty, let ending = pendingTempBasalEndStorage {
            log.debug("Not reporting a refresh while the records of the temp basal of \(ending.dose.startDate) are read")
            return
        }

        var events = events
        if let ending = pendingTempBasalEndStorage {
            pendingTempBasalEndStorage = nil
            let final = estimateFinal(ending.dose, because: "a batch went out before its records were read")
            events = (final.map { [$0] } ?? []) + ending.then + events
        }
        for dose in state.awaitingRecord where dose.type == .tempBasal && !dose.isFinalized {
            estimateFinal(dose, because: "it was saved waiting on its record")
        }

        dropExpiredFinals()
        // Each dose read once, and with it whether it has a final - which can't appear meanwhile, see `finalize`
        let snapshots = state.awaitingRecord.map { (dose: $0, snapshot: $0.snapshot) }
        let finals = snapshots.filter(\.snapshot.isFinalized).map(\.dose)
        let finalEvents = snapshots.compactMap { $0.dose.fixedFinalEvent(of: $0.snapshot) }
        let finalized = Set(finalEvents.map(\.raw)).union(finalizedIdentities.keys)

        // A mutable report of a dose finalized since the caller built it: it would change a finalized dose after all
        events = events.filter { event in
            guard event.dose?.isMutable == true, finalized.contains(event.raw) else {
                return true
            }

            log.warning("Dropping a mutable report of the \(event.title) of \(event.date), it is finalized already")
            return false
        }

        var identities = Set(events.map(\.raw))
        func appendIfMissing(_ event: NewPumpEvent) {
            guard identities.insert(event.raw).inserted else {
                return
            }
            events.append(event)
        }

        // Finals the host has yet to confirm go out with every batch until it does, the same final every time
        finalEvents.forEach(appendIfMissing)

        // With `replacePendingEvents` the host drops every mutable dose it holds. Anything still in flight has to be in
        // here: the running bolus and temp basal, and every dose still waiting on its record.
        if replacePendingEvents {
            if let bolusDose = state.bolusDose {
                let bolus = bolusDose.snapshot
                if !bolus.isFinished {
                    appendIfMissing(NewPumpEvent.bolus(dose: bolusDose.doseEntry(of: bolus, isMutable: true)))
                }
            }

            runningTempBasal().forEach(appendIfMissing)

            for (dose, snapshot) in snapshots where !snapshot.isFinalized {
                if let event = NewPumpEvent.finishedDose(dose, entry: dose.doseEntry(of: snapshot, isMutable: true)) {
                    appendIfMissing(event)
                }
            }
        }

        if !finals.isEmpty {
            lastFinalsSentAt = Date.now
        }

        recordStore.store(emitted: events.compactMap(EmittedDose.init))

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                // The finals stay, and go out with the next batch
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManagerDidUpdateState(self)

            delegate.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: replacePendingEvents
            ) { error in
                if let error = error {
                    // The finals stay, and go out with the next batch
                    self.handlePumpDelegateError(method: "hasNewPumpEvents", error)
                    return
                }

                self.acknowledgeFinals(finals)
            }
        }
    }

    // MARK: - Doses awaiting their record

    /// How long a finished dose waits for its record, once every record the patch has written has been read
    internal static let awaitingRecordTimeout: TimeInterval = .minutes(15)

    /// How long a finished dose waits for its record at most, read up or not
    internal static let awaitingRecordMaximumWait: TimeInterval = .minutes(60)

    /// How far from when its command went out, on the patch clock, the record of a dose whose answer was lost may start
    internal static let recordMatchWindow: TimeInterval = 60

    /// How much earlier than when its command went out an unanswered temp basal is dated from the start its segment or
    /// record shows: the skew is known to a few seconds only
    internal static let unansweredStartSlack: TimeInterval = 5

    /// A status received before the command of the dose it is checked against went out says nothing of that dose: the
    /// monotonic clock where both are known (one run of the app), the wall clock otherwise
    internal static func statusPredatesCommand(
        of dose: UnfinalizedDose.State,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> Bool {
        if let sentUptime = dose.sentUptime {
            return receivedUptime < sentUptime
        }
        if let sentAt = dose.sentAt {
            return receivedAt < sentAt
        }
        return false
    }

    /// A time on the patch clock as ours - by the skew of the last reading - bounded to `[notBefore, notAfter]`
    internal func patchTimeOnOurClock(_ patchTime: Date, notBefore: Date, notAfter: Date) -> Date {
        max(min(patchTime.addingTimeInterval(-state.patchClockSkew), notAfter), notBefore)
    }

    /// For a change of the running basal that goes with ending a temp basal - see `beginTempBasalEnd`
    internal func withDoseReportLock<T>(_ body: () -> T) -> T {
        doseReportLock.withLock(body)
    }

    /// The patch restarts a temp basal running at patch-local midnight: two records, and the amount its statuses show
    /// starts over
    internal static func crossesPatchMidnight(from start: Date, to end: Date, utcOffset: TimeInterval) -> Bool {
        let day: TimeInterval = .hours(24)
        let localStart = start.timeIntervalSince1970 + utcOffset
        let nextMidnight = (floor(localStart / day) + 1) * day
        return end.timeIntervalSince1970 + utcOffset > nextMidnight
    }

    /// A bolus stopped running: from now on it waits for its record, and is reported as mutable until then. Returns
    /// that interim report - nothing, if the dose has been finalized already. The dose object itself moves over, so a
    /// progress reporter holding it sees it finished.
    internal func awaitRecord(
        _ dose: UnfinalizedDose,
        _ reason: UnfinalizedDose.FinishReason,
        deliveredUnits: Double? = nil,
        endedAt: Date?
    ) -> [NewPumpEvent] {
        doseReportLock.withLock { () -> [NewPumpEvent] in
            let endedNow = dose.finish(reason, deliveredUnits: deliveredUnits, endedAt: endedAt, at: now())
            let ended = dose.snapshot

            guard !ended.isFinalized else {
                log.warning("The \(dose.type.rawValue) of \(dose.startDate) is finalized already, not awaiting its record")
                return []
            }

            if endedNow {
                log.info(
                    "\(dose.type.rawValue) of \(dose.startDate) \(reason.rawValue), awaiting its record - " +
                        "delivered \(ended.deliveredUnits) U, ended \(endedAt.map { "\($0)" } ?? "unseen"), " +
                        "record \(ended.recordSequence.map { "#\($0)" } ?? "-"), patch start \(ended.pumpStartTime.map { "\($0)" } ?? "-")"
                )
            } else {
                log.info(
                    "\(dose.type.rawValue) of \(dose.startDate) \(reason.rawValue), but it ended already " +
                        "(\(ended.finishReason?.rawValue ?? "-")) - keeping that end, delivered \(ended.deliveredUnits) U"
                )
            }

            state.mutateAwaitingRecord { doses in
                guard !doses.contains(where: { $0 === dose }) else {
                    return
                }
                doses.append(dose)
            }

            return NewPumpEvent.finishedDose(dose, entry: dose.doseEntry(of: ended, isMutable: true)).map { [$0] } ?? []
        }
    }

    /// Fixes the final report of `dose` - once: nil if it has one already - and keeps it in `awaitingRecord`, to go out
    /// with every batch until the host confirms storing it. Only under `doseReportLock`; the caller hands the final
    /// over before letting go of it. `deliveredUnits`: the record's amount, or nil for our own estimate.
    private func finalize(_ dose: UnfinalizedDose, deliveredUnits: Double?, endDate: Date? = nil) -> NewPumpEvent? {
        guard dose.finalize(deliveredUnits: deliveredUnits, endDate: endDate, at: now()) else {
            log.warning("The \(dose.type.rawValue) of \(dose.startDate) is finalized already, not reporting it again")
            return nil
        }

        state.mutateAwaitingRecord { doses in
            guard !doses.contains(where: { $0 === dose }) else {
                return
            }
            doses.append(dose)
        }

        guard let event = dose.finalEvent else {
            return nil
        }

        finalizedIdentities = finalizedIdentities.filter { Date.now.timeIntervalSince($0.value) < Self.finalizedIdentityRetention }
        finalizedIdentities[event.raw] = Date.now
        return event
    }

    /// Finalizes `dose` and hands the final to the host at once. Only under `doseReportLock`.
    private func emitFinal(_ dose: UnfinalizedDose, deliveredUnits: Double, endDate: Date? = nil) {
        guard let event = finalize(dose, deliveredUnits: deliveredUnits, endDate: endDate) else {
            return
        }
        emitPumpEvents([event])
    }

    /// Applies one record read off the patch: finalizes the bolus waiting on it, if any - by the number its command's
    /// answer gave it, or one whose answer was lost by when its command went out - or the temp basal whose command went
    /// unanswered it shows ran. A temp basal of ours was finalized as it ended (`TempBasalEnd`). Only finalizes: the
    /// identity of a dose never moves. Returns what it did, for the record screen.
    internal func reconcile(_ response: GetRecordResponse) -> String? {
        switch response.record {
        case let .bolus(record):
            guard record.type == .NORMAL else {
                log.warning("Record \(response.sequence): \(record.type) bolus, we only deliver normal boluses")
                return "not a normal bolus"
            }

            return doseReportLock.withLock { () -> String in
                let skew = state.patchClockSkew
                let waiting = state.awaitingRecord.filter { $0.type == .bolus && !$0.isFinalized }
                // A number a SetBolus answer gave is that bolus's record - see `MedtrumPumpState.answeredBolusRecords`:
                // never that of one whose answer was lost
                let claimed = state.answeredBolusRecords.contains(response.sequence)
                // Whether this record can be that of `dose`, whose answer was lost: unclaimed, at its amount, numbered
                // past the newest known when its command went out, starting near then
                let couldBeOf = { (dose: UnfinalizedDose, nearItsCommand: Bool) -> Bool in
                    let snapshot = dose.snapshot
                    guard !claimed, snapshot.recordSequence == nil, let sentAt = snapshot.sentAt else {
                        return false
                    }
                    return response.sequence > snapshot.sequenceAtSend ?? 0 &&
                        RecordSyncer.steps(record.normalAmount) == RecordSyncer.steps(dose.value) &&
                        (!nearItsCommand ||
                            abs(record.startTime.timeIntervalSince(sentAt.addingTimeInterval(skew))) <= Self.recordMatchWindow)
                }
                // Whatever it finalizes, a bolus whose command went unanswered this record could be of may have run -
                // see `unansweredBolusNeverRan`
                for dose in unansweredBoluses where couldBeOf(dose, true) {
                    dose.notePossibleRecord(response.sequence)
                }

                let dose: UnfinalizedDose
                if let numbered = waiting.first(where: { $0.recordSequence == response.sequence }) {
                    // Its record by the number alone: a start or amount other than ours is only worth a look
                    let answeredStart = numbered.snapshot.pumpStartTime
                    let startDiffers = answeredStart.map {
                        abs(record.startTime.timeIntervalSince($0)) > RecordSyncer.bolusStartTolerance
                    } ?? false
                    if startDiffers || RecordSyncer.steps(record.normalAmount) != RecordSyncer.steps(numbered.value) {
                        log.warning(
                            "Record \(response.sequence) of the bolus of \(numbered.startDate) is of \(record.normalAmount) U " +
                                "from \(record.startTime), where we asked for \(numbered.value) U and its answer said " +
                                "\(answeredStart.map { "\($0)" } ?? "-") - finalizing it with it, by its number"
                        )
                    }
                    dose = numbered
                } else if claimed {
                    log.info("Record \(response.sequence) is that of a bolus of ours finalized already, matching nothing")
                    return "answered bolus finalized already"
                } else if let unanswered = waiting.first(where: { couldBeOf($0, true) }) {
                    dose = unanswered
                } else {
                    log.info(
                        "Record \(response.sequence): bolus of \(record.normalAmount) U at \(record.startTime) " +
                            "matches no dose of ours, not imported"
                    )
                    // Ours by its amount, should the patch clock be further off than we think
                    for dose in unansweredBoluses where couldBeOf(dose, false) {
                        dose.notePossibleRecord(response.sequence)
                    }
                    return "unmatched"
                }

                let matched = dose.snapshot
                log.info(
                    "Record \(response.sequence) finalizes the bolus of \(dose.startDate) " +
                        "(\(matched.finishReason?.rawValue ?? "-")): delivered \(record.normalDelivered) U of \(dose.value) U, " +
                        "last reported \(matched.deliveredUnits) U"
                )

                emitFinal(dose, deliveredUnits: record.normalDelivered)
                return "finalized bolus \(dose.startDate)"
            }

        case let .basal(record):
            if record.endReason?.isSuspendedByPump() == true {
                log.info("Record \(response.sequence): \(record.type) segment ended by \(record.endReason.map { "\($0)" } ?? "-")")
            }

            // The scheduled basal between a cancel and a set, and the like: nothing of ours waits on it
            guard record.type.isTempBasal() else {
                return nil
            }

            guard record.type == .ABSOLUTE_TEMP else {
                log.info("Record \(response.sequence): \(record.type) segment, we only set absolute temp basals - not ours")
                return "not an absolute temp basal"
            }

            return doseReportLock.withLock { () -> String in
                // A temp basal of ours is final from its end on - from its records, read as it ended, or our estimate:
                // read again, or later, its record changes nothing
                if let dose = state.awaitingRecord.first(where: { dose in
                    guard dose.type == .tempBasal, let pumpStartTime = dose.pumpStartTime else {
                        return false
                    }
                    return abs(record.startTime.timeIntervalSince(pumpStartTime)) <= RecordSyncer.tempBasalStartTolerance
                }) {
                    log.info("Record \(response.sequence) is that of the temp basal of \(dose.startDate), final already")
                    return "temp basal finalized already"
                }

                if let outcome = keepPartOfRunningTempBasal(record, response: response) {
                    return outcome
                }

                if let outcome = finalizeUnconfirmedTempBasal(from: record, sequence: response.sequence) {
                    return outcome
                }

                log.info(
                    "Record \(response.sequence): temp basal of \(record.rate) U/h at \(record.startTime) matches no " +
                        "dose of ours, not imported"
                )
                return "unmatched"
            }

        case .invalid,
             .tdd,
             .truncated,
             .unhandled:
            return nil
        }
    }

    /// `record` is of a part of the temp basal still running: of this patch, at its rate, starting on its patch start
    /// or where the part kept before it ended. The patch wrote it as it restarted the segment - at patch-local midnight,
    /// on a profile change made elsewhere - or ended it unseen so far: its end, once seen, has to meet the last part.
    /// Kept on the dose, to be summed with the parts read as it ends (`tempBasalParts`); nothing is reported. Only under
    /// `doseReportLock`.
    private func keepPartOfRunningTempBasal(_ record: BasalRecord, response: GetRecordResponse) -> String? {
        let dose = state.basalDose
        let running = dose.snapshot
        let tolerance = RecordSyncer.tempBasalStartTolerance
        guard dose.type == .tempBasal, !running.isFinished, !running.recordMatchDisabled,
              let pumpStartTime = running.pumpStartTime,
              RecordSyncer.isSamePatch(response.patchId, state.patchId.toUInt64()),
              RecordSyncer.steps(record.rate) == RecordSyncer.steps(dose.value)
        else {
            return nil
        }

        if running.recordedParts.contains(where: { $0.sequence == response.sequence }) {
            log.info("Record \(response.sequence) is a part of the running temp basal of \(dose.startDate), kept already")
            return "part of running temp basal \(dose.startDate)"
        }

        let partStart = running.recordedParts.last?.end ?? pumpStartTime
        guard abs(record.startTime.timeIntervalSince(partStart)) <= tolerance, record.endTime > record.startTime else {
            return nil
        }

        let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
        let part = UnfinalizedDose.RecordedPart(
            sequence: response.sequence,
            patchId: response.patchId & 0xFFFF,
            start: record.startTime,
            end: record.endTime,
            delivered: record.delivered
        )
        guard dose.keepRecordedPart(part) else {
            return nil
        }

        log.info(
            "Record \(response.sequence) is a part of the running temp basal of \(dose.startDate), from \(record.startTime) " +
                "to \(record.endTime)\(Self.isPatchMidnight(record.endTime, utcOffset: utcOffset) ? " (patch-local midnight)" : ""), " +
                "delivered \(record.delivered) U: kept, to be summed with the rest as it ends"
        )
        return "part of running temp basal \(dose.startDate)"
    }

    /// Finalizes, from our own estimate, the doses whose record is overdue - see `RecordSyncer.fallbackRule` - and drops
    /// a temp basal whose command went unanswered that nothing showed ran. Returns how many.
    @discardableResult internal func finalizeOverdueAwaitingDoses() -> Int {
        let checkedAt = now()

        return doseReportLock.withLock { () -> Int in
            var settled = 0

            // Only with every record read, counted from when it ended at the latest: a temp basal the patch may still
            // run has no record yet, and records that cannot be read - or were skipped - say nothing: it stays,
            // delivery uncertain
            if let pending = state.unconfirmedTempBasal, !mayHaveSkippedRecord(of: pending) {
                let end = unconfirmedTempBasalEnd(pending)
                if RecordSyncer.fallbackRule(since: end, caughtUp: isCaughtUp(after: end), now: checkedAt) == .noRecord {
                    dropUnconfirmedTempBasal(
                        because: "no status showed it running and \(RecordSyncer.FallbackRule.noRecord.description) at the latest"
                    )
                    settled += 1
                }
            }

            let overdue = state.awaitingRecord.compactMap { dose -> (dose: UnfinalizedDose, rule: RecordSyncer.FallbackRule)? in
                let snapshot = dose.snapshot
                guard !snapshot.isFinalized, let finishedAt = snapshot.finishedAt,
                      let rule = RecordSyncer.fallbackRule(since: finishedAt, caughtUp: isCaughtUp(after: finishedAt), now: checkedAt)
                else {
                    return nil
                }
                return (dose, rule)
            }

            guard !overdue.isEmpty else {
                return settled
            }

            let events = finalizeFromEstimate(overdue.map(\.dose)) { dose in
                overdue.first { $0.dose === dose }?.rule.description ?? "-"
            }
            emitPumpEvents(events)
            return settled + overdue.count
        }
    }

    /// Final reports, from our own estimate, of every dose still waiting on its record - the records are out of reach.
    /// Only under `doseReportLock`; the caller emits them.
    private func finalizeAllAwaitingDoses(because reason: String) -> [NewPumpEvent] {
        finalizeFromEstimate(state.awaitingRecord.filter { !$0.isFinalized }) { _ in reason }
    }

    /// Final reports from our own estimate. Only under `doseReportLock`; the caller emits them. A bolus whose command
    /// went unanswered, counted in full without its record, is one the host is told was counted as delivered.
    private func finalizeFromEstimate(_ doses: [UnfinalizedDose], because reason: (UnfinalizedDose) -> String) -> [NewPumpEvent] {
        var events: [NewPumpEvent] = []

        for dose in doses {
            if dose.type == .tempBasal {
                events.append(contentsOf: estimateFinal(dose, because: reason(dose)).map { [$0] } ?? [])
                continue
            }

            let neverRan = unansweredBolusNeverRan(dose)
            guard let event = finalize(dose, deliveredUnits: neverRan ? 0 : nil) else {
                continue
            }

            let final = dose.snapshot
            log.warning(
                "Finalized the \(dose.type.rawValue) of \(dose.startDate) (\(final.finishReason?.rawValue ?? "-")) " +
                    "without its record, \(reason(dose)): \(final.finalDeliveredUnits ?? 0) U delivered, by our estimate"
            )

            if dose.type == .bolus, final.confirmation == .uncertain, dose.countsInFull(final), !neverRan {
                emitAlert(alertType: .bolusCountedAsDelivered(units: dose.value))
            }

            events.append(event)
        }

        return events
    }

    /// The host stored a batch: the finals it carried need not go out again
    private func acknowledgeFinals(_ finals: [UnfinalizedDose]) {
        guard !finals.isEmpty else {
            return
        }

        var acknowledged = 0
        doseReportLock.withLock {
            state.mutateAwaitingRecord { doses in
                let before = doses.count
                doses.removeAll { dose in dose.isFinalized && finals.contains { $0 === dose } }
                acknowledged = before - doses.count
            }
        }

        guard acknowledged > 0 else {
            return
        }

        log.info("The host stored \(acknowledged) final report(s), done with those doses")
        notifyStateDidChange()
    }

    /// A final the host has not confirmed in time to matter anymore, counted from when it was fixed
    internal static func isUnconfirmedFinalExpired(_ dose: UnfinalizedDose, now: Date = Date.now) -> Bool {
        let final = dose.snapshot
        guard let endDate = final.finalEndDate else {
            return false
        }
        return now.timeIntervalSince(final.finalizedAt ?? endDate) > unconfirmedFinalMaximumAge
    }

    /// Takes the expired finals off `awaitingRecord`. Only under `doseReportLock`.
    private func dropExpiredFinals() {
        let checkedAt = now()
        var expired: [UnfinalizedDose] = []

        state.mutateAwaitingRecord { doses in
            expired = doses.filter { Self.isUnconfirmedFinalExpired($0, now: checkedAt) }
            doses.removeAll { Self.isUnconfirmedFinalExpired($0, now: checkedAt) }
        }

        for dose in expired {
            log.error("The host never confirmed the final of the \(dose.type.rawValue) of \(dose.startDate), giving up on it")
        }
    }

    /// Finals the host has not confirmed, and no batch has carried for a while. Only under `doseReportLock`.
    private var isUnconfirmedFinalsResendDue: Bool {
        Date.now.timeIntervalSince(lastFinalsSentAt) >= Self.unconfirmedFinalsResendInterval &&
            state.awaitingRecord.contains(where: \.isFinalized)
    }

    /// Sends the finals the host has yet to confirm again, if no batch carried them for a while. Needs neither the link
    /// nor a patch.
    internal func resendUnacknowledgedFinalsIfDue() {
        doseReportLock.withLock {
            guard isUnconfirmedFinalsResendDue else {
                return
            }

            log.warning("The host has not confirmed \(state.awaitingRecord.filter(\.isFinalized).count) final report(s), sending them again")
            // A temp basal's records being read: their batch carries every final
            emitPumpEvents([], replacePendingEvents: false, unlessTempBasalEndPending: true)
        }
    }

    /// Doses wait on records the patch has written already, or past their timeout - or finals are due to go out again
    internal var hasPendingRecordWork: Bool {
        if doseReportLock.withLock({ isUnconfirmedFinalsResendDue }) {
            return true
        }

        var waitingSince = state.awaitingRecord.compactMap { dose -> Date? in
            let snapshot = dose.snapshot
            return snapshot.isFinalized ? nil : snapshot.finishedAt
        }
        if let pending = state.unconfirmedTempBasal {
            waitingSince.append(unconfirmedTempBasalEnd(pending))
        }

        guard !waitingSince.isEmpty else {
            return false
        }

        let checkedAt = now()
        return state.syncedSequenceNumber < state.currentSequenceNumber || waitingSince.contains {
            RecordSyncer.fallbackRule(since: $0, caughtUp: isCaughtUp(after: $0), now: checkedAt) != nil
        }
    }

    /// Every record the patch has written by `end` has been read: the cursor is at the newest record it told us of, and
    /// it told us so after `end` - when a dose ended, and its record was written. A number told before says nothing of
    /// that record: the cursor at it, with the link lost since, is not caught up.
    internal func isCaughtUp(after end: Date) -> Bool {
        guard let confirmedAt = state.sequenceConfirmedAt else {
            return false
        }
        return state.syncedSequenceNumber >= state.currentSequenceNumber && confirmedAt > end
    }

    /// The boluses whose command went unanswered, never seen delivering - running, or waiting on their record. Only
    /// under `doseReportLock`.
    private var unansweredBoluses: [UnfinalizedDose] {
        ([state.bolusDose].compactMap { $0 } + state.awaitingRecord).filter { dose in
            let snapshot = dose.snapshot
            return dose.type == .bolus && snapshot.confirmation == .uncertain && snapshot.recordSequence == nil &&
                !snapshot.isFinalized
        }
    }

    /// Record `sequence` was read off the patch - asked for as `requested`, of this patch (`isOurs`) - and applied: see
    /// `UnfinalizedDose.State.recordsReadThrough`
    internal func noteRecordRead(_ sequence: Int, requested: Int, isOurs: Bool) {
        guard isOurs, sequence == requested else {
            return
        }
        doseReportLock.withLock {
            for dose in unansweredBoluses {
                dose.noteRecordRead(sequence)
            }
        }
    }

    /// Whether `dose`, a bolus whose command went unanswered that ran its course unseen, never ran: past its deadline its
    /// record was written, had it run - and the patch told its newest record since, every one numbered past the newest
    /// known when the command went out was read up to there, and none could be its. A bolus is left without a record
    /// only if cancelled before it was written: one cancelled, or cut off, may have run. Why it may have is logged. Only
    /// under `doseReportLock`. A number an answer gave is never this one's - see `MedtrumPumpState.answeredBolusRecords`.
    private func unansweredBolusNeverRan(_ dose: UnfinalizedDose) -> Bool {
        let snapshot = dose.snapshot
        guard dose.type == .bolus, snapshot.confirmation == .uncertain, snapshot.recordSequence == nil else {
            return false
        }

        let deadline = dose.deliveryDeadline(of: snapshot)
        let mayHaveRun: String
        if snapshot.finishReason != .completionNotSeen {
            mayHaveRun = "it was \(snapshot.finishReason?.rawValue ?? "not ended")"
        } else if snapshot.sequenceAtSend == nil {
            mayHaveRun = "the record known when it went out was not kept"
        } else if now() < deadline {
            mayHaveRun = "it is not past its deadline"
        } else if !sequenceConfirmed(after: deadline, of: snapshot) {
            mayHaveRun = "the patch has not told its newest record since its deadline"
        } else if let through = snapshot.recordsReadThrough ?? snapshot.sequenceAtSend, through < state.currentSequenceNumber {
            mayHaveRun = "records \(through + 1)...\(state.currentSequenceNumber) were not all read in order, it may be one of them"
        } else if let possible = snapshot.possibleRecord {
            mayHaveRun = "record \(possible) could be its"
        } else {
            log.warning(
                "The bolus of \(dose.startDate) whose command went unanswered never ran: no record past " +
                    "\(snapshot.sequenceAtSend.map(String.init) ?? "-") up to \(state.currentSequenceNumber) is its - 0 U"
            )
            return true
        }

        log.warning("The bolus of \(dose.startDate) whose command went unanswered may have run, \(mayHaveRun): counted in full")
        return false
    }

    /// The patch told its newest record after `deadline`, for the bolus `snapshot` is of. Sent in this run, by the
    /// monotonic clock: a change of the wall clock can't put a telling from before it went out past its deadline. Sent
    /// in an earlier run - another boot, maybe, whose monotonic clock is not ours - only a telling of this run counts, all
    /// of it after the bolus went out.
    private func sequenceConfirmed(after deadline: Date, of snapshot: UnfinalizedDose.State) -> Bool {
        guard let confirmed = state.sequenceConfirmedInThisRun else {
            return false
        }
        if let sentUptime = snapshot.sentUptime, let sentAt = snapshot.sentAt {
            return confirmed.uptime > sentUptime + deadline.timeIntervalSince(sentAt)
        }
        return confirmed.at > deadline
    }

    /// The record sync gave up on record `sequence`, unreadable: kept if it could be the unconfirmed temp basal's
    internal func noteSkippedRecord(_ sequence: Int) {
        doseReportLock.withLock {
            guard let pending = state.unconfirmedTempBasal, sequence > pending.snapshot.sequenceAtSend ?? 0 else {
                return
            }
            log.warning("Record \(sequence) was skipped, and could be that of the temp basal whose command went unanswered")
            state.skippedRecordSequences.append(sequence)
        }
    }

    /// A record numbered past the newest one known when its command went out was skipped: it could be its record
    private func mayHaveSkippedRecord(of pending: UnfinalizedDose) -> Bool {
        let sequenceAtSend = pending.snapshot.sequenceAtSend ?? 0
        return state.skippedRecordSequences.contains { $0 > sequenceAtSend }
    }

    // MARK: - Temp basal ends

    /// A temp basal of ours that ended, and what followed it. The patch writes its record as it ends - a record per
    /// part, where it restarted it at patch-local midnight or on a profile change - and names the last: the answer to
    /// the cancel, the record number a status of the scheduled basal or of a suspend shows. Read right away, they make
    /// its final (`RecordSyncer.finishTempBasalEnd`), and the two go out in one batch: the host takes basal doses as final in
    /// order, and moves past a temp basal still mutable as soon as anything after it is stored - its final would be
    /// lost. A batch going out before that carries them out with our estimate (`emitPumpEvents`).
    final class TempBasalEnd {
        let dose: UnfinalizedDose
        /// Where its last record ends, on the patch clock: where the segment after it started
        let patchEnd: Date?
        /// The number of its last record
        let lastRecord: Int?
        /// What followed it - a command that changes the basal again before it is settled adds its own, under
        /// `doseReportLock`
        var then: [NewPumpEvent]

        init(dose: UnfinalizedDose, patchEnd: Date?, lastRecord: Int?, then: [NewPumpEvent]) {
            self.dose = dose
            self.patchEnd = patchEnd
            self.lastRecord = lastRecord
            self.then = then
        }
    }

    internal var pendingTempBasalEnd: TempBasalEnd? {
        doseReportLock.withLock { pendingTempBasalEndStorage }
    }

    /// At most this many records are read for a temp basal as it ends - its parts and a bolus or two: a backlog is left
    /// to the record sync, and our estimate stands in
    internal static let tempBasalEndMaxRecords = 8

    /// How long the records of a temp basal as it ends may take to read, all of them: the command that ended it - and the
    /// loop waiting on it - is held up meanwhile. Past it, our estimate stands in.
    internal static let tempBasalEndReadBudget: TimeInterval = 10

    /// No record is asked for with less of that budget left than a round trip takes
    internal static let tempBasalEndRecordReadMinimum: TimeInterval = 1.5

    /// The running temp basal, if any, stopped at `endedAt` - its last record `lastRecord`, ending at `patchEnd` on the
    /// patch clock, where known - and `then` follows it: neither goes out before its final, see `TempBasalEnd`. It is
    /// kept in `awaitingRecord` meanwhile, so that a restart finalizes it from our estimate. The caller replaces
    /// `state.basalDose`, then has it finished. Returns false when no temp basal was running: the caller reports `then`
    /// itself. Only under `doseReportLock`.
    internal func beginTempBasalEnd(endedAt: Date, patchEnd: Date?, lastRecord: Int?, then events: [NewPumpEvent]) -> Bool {
        doseReportLock.withLock { () -> Bool in
            let dose = state.basalDose
            guard dose.type == .tempBasal, !dose.isFinished else {
                return false
            }

            // One that ended before, its records still unread, goes out first
            if pendingTempBasalEndStorage != nil {
                emitPumpEvents([])
            }

            dose.finish(endedAt >= dose.estimatedEndDate ? .completed : .cancelled, endedAt: endedAt, at: now())
            state.mutateAwaitingRecord { doses in
                guard !doses.contains(where: { $0 === dose }) else {
                    return
                }
                doses.append(dose)
            }
            pendingTempBasalEndStorage = TempBasalEnd(dose: dose, patchEnd: patchEnd, lastRecord: lastRecord, then: events)

            log.info(
                "Temp basal of \(dose.startDate) ended at \(endedAt), reported once its records up to " +
                    "\(lastRecord.map { "#\($0)" } ?? "-") are read"
            )
            return true
        }
    }

    /// Reads the records of the temp basal whose end is pending and reports it final, with what followed it - on this
    /// thread, which may block on the link: a full status's. Only if no other operation holds `commandLock`: returns
    /// false, having read nothing, if one does. See `RecordSyncer.finishTempBasalEnd`.
    func finishPendingTempBasalEndIfFree() -> Bool {
        withCommandLockIfFree {
            RecordSyncer.finishTempBasalEnd(pumpManager: self)
        } != nil
    }

    /// The same, off the queue statuses arrive on - once no command is in flight: one that changes the basal finishes it
    /// first, on its own path - and holding `commandLock`, as a command does
    func finishPendingTempBasalEndSoon() {
        tempBasalEndQueue.async { [weak self] in
            guard let self else {
                return
            }

            let deadline = Date.now.addingTimeInterval(Self.commandActivityTimeout)
            while self.isCommandActive, Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }

            let read = self.withCommandLock {
                RecordSyncer.finishTempBasalEnd(pumpManager: self)
            }
            if !read, let ending = self.pendingTempBasalEnd {
                _ = self.settleTempBasalEnd(ending, records: [], unread: "another operation held the patch")
            }
        }
    }

    /// Fixes the final of the temp basal of `ending` - from `records`, read in one go up to its last record, if they
    /// add up to it; else from our estimate, `unread` saying why not all could be read - and reports it with what
    /// followed it. Returns the outcome for each record it was finalized from, for the record screen. Nothing, if a
    /// batch carried it out meanwhile.
    internal func settleTempBasalEnd(_ ending: TempBasalEnd, records: [GetRecordResponse], unread: String?) -> [Int: String] {
        doseReportLock.withLock { () -> [Int: String] in
            guard pendingTempBasalEndStorage === ending else {
                return [:]
            }
            pendingTempBasalEndStorage = nil

            let dose = ending.dose
            var events: [NewPumpEvent] = []
            var outcomes: [Int: String] = [:]

            if unread == nil, let parts = tempBasalParts(of: dose, in: records, endingAt: ending.patchEnd) {
                log.info(
                    "Record(s) \(parts.sequences.map(String.init).joined(separator: ", ")) finalize the temp basal of " +
                        "\(dose.startDate): \(String(format: "%.1f", parts.duration / 60)) min, delivered " +
                        "\(parts.delivered) U by its records - we observed the end at " +
                        "\(dose.observedEndDate.map { "\($0)" } ?? "-")"
                )
                // Our start, the patch's duration: the identity stays on our clock
                if let final = finalize(dose, deliveredUnits: parts.delivered, endDate: dose.startDate.addingTimeInterval(parts.duration)) {
                    events.append(final)
                }
                for sequence in parts.sequences {
                    outcomes[sequence] = "finalized temp basal \(dose.startDate)"
                }
            } else if let final = estimateFinal(dose, because: unread ?? "its records do not add up") {
                events.append(final)
            }

            emitPumpEvents(events + ending.then)
            return outcomes
        }
    }

    /// What `records` show a temp basal of ours delivered, and for how long: its ABSOLUTE_TEMP parts at its rate - the
    /// ones kept as it ran (`keepPartOfRunningTempBasal`), then the ones read now - the first starting on its patch
    /// start, each where the one before ended, all of this patch, the last where it ended (`patchEnd`) or ran its
    /// course. Nil, the reason logged, if they don't add up.
    private func tempBasalParts(
        of dose: UnfinalizedDose,
        in records: [GetRecordResponse],
        endingAt patchEnd: Date?
    ) -> (delivered: Double, duration: TimeInterval, sequences: [Int])? {
        let tolerance = RecordSyncer.tempBasalStartTolerance
        let snapshot = dose.snapshot
        guard !snapshot.recordMatchDisabled, let pumpStartTime = snapshot.pumpStartTime else {
            log.info(
                "The temp basal of \(dose.startDate) is not taken from its records: " +
                    (snapshot.recordMatchDisabled ? "they do not start where its patch start says" : "no patch start")
            )
            return nil
        }

        let patchId = state.patchId.toUInt64()
        var parts: [UnfinalizedDose.RecordedPart] = []
        for kept in snapshot.recordedParts {
            let partStart = parts.last?.end ?? pumpStartTime
            guard RecordSyncer.isSamePatch(kept.patchId, patchId), abs(kept.start.timeIntervalSince(partStart)) <= tolerance else {
                log.warning(
                    "Record \(kept.sequence), a part of the temp basal of \(dose.startDate) read as it ran, is of patch " +
                        "\(kept.patchId) from \(kept.start): not where the part before it ended (\(partStart)), or not this patch"
                )
                return nil
            }
            parts.append(kept)
        }

        for response in records where !parts.contains(where: { $0.sequence == response.sequence }) {
            guard case let .basal(record) = response.record, record.type == .ABSOLUTE_TEMP,
                  RecordSyncer.steps(record.rate) == RecordSyncer.steps(dose.value)
            else {
                continue
            }

            let part = UnfinalizedDose.RecordedPart(
                sequence: response.sequence,
                patchId: response.patchId & 0xFFFF,
                start: record.startTime,
                end: record.endTime,
                delivered: record.delivered
            )
            if let previous = parts.last {
                guard abs(record.startTime.timeIntervalSince(previous.end)) <= tolerance else {
                    log.warning(
                        "Record \(response.sequence) of a temp basal at its rate starts at \(record.startTime), not where " +
                            "the part of the temp basal of \(dose.startDate) before it ended (\(previous.end))"
                    )
                    return nil
                }
                parts.append(part)
            } else if abs(record.startTime.timeIntervalSince(pumpStartTime)) <= tolerance {
                parts.append(part)
            }
        }

        guard let first = parts.first, let last = parts.last else {
            log.warning("No record read starts where the temp basal of \(dose.startDate) did (\(pumpStartTime))")
            return nil
        }

        let ranItsCourse = pumpStartTime.addingTimeInterval(dose.estimatedEndDate.timeIntervalSince(dose.startDate))
        guard patchEnd.map({ abs(last.end.timeIntervalSince($0)) <= tolerance }) ?? true ||
            abs(last.end.timeIntervalSince(ranItsCourse)) <= tolerance
        else {
            log.warning(
                "The records of the temp basal of \(dose.startDate) end at \(last.end), not where it ended " +
                    "(\(patchEnd.map { "\($0)" } ?? "-"))"
            )
            return nil
        }

        let delivered = parts.reduce(0) { $0 + $1.delivered }
        return (delivered.rounded(toPlaces: 2), last.end.timeIntervalSince(first.start), parts.map(\.sequence))
    }

    /// Fixes the final of a finished temp basal from our estimate - see `UnfinalizedDose.tempBasalEstimate`, its rate ×
    /// duration if it ran across patch-local midnight - and logs what it is based on. Only under `doseReportLock`; the
    /// caller hands the final over.
    @discardableResult private func estimateFinal(_ dose: UnfinalizedDose, because reason: String) -> NewPumpEvent? {
        let snapshot = dose.snapshot
        guard !snapshot.isFinalized else {
            return nil
        }

        let skew = state.patchClockSkew
        let start = snapshot.pumpStartTime ?? dose.startDate.addingTimeInterval(skew)
        let end = dose.tempBasalEnd(of: snapshot).addingTimeInterval(skew)
        let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
        let restarted = Self.crossesPatchMidnight(from: start, to: end, utcOffset: utcOffset)
        let estimate = dose.tempBasalEstimate(of: snapshot, restarted: restarted)

        guard let event = finalize(dose, deliveredUnits: estimate.units) else {
            return nil
        }

        log.warning(
            "Finalized the temp basal of \(dose.startDate) (\(snapshot.finishReason?.rawValue ?? "-")) without its records, " +
                "\(reason): \(estimate.units) U by our estimate, from its \(estimate.source.rawValue)" +
                (restarted ? " - it ran across patch-local midnight" : "")
        )
        return event
    }

    // MARK: - Temp basal whose command went unanswered

    /// A temp basal whose command went out unanswered - or was answered with another segment - is kept here, unreported:
    /// the patch may or may not run it, and nothing reported may be taken back. A status showing it settles it as
    /// running (`followTempBasalSegment`), its record as a final (`finalizeUnconfirmedTempBasal`) - a record of a part
    /// of it, split at midnight or by a profile change, as running or ended, finalized from our estimate. With neither,
    /// it is dropped as never run once every record the patch told of 15 min past when it ended at the latest was read
    /// (`unconfirmedTempBasalEnd`, `isCaughtUp`, `finalizeOverdueAwaitingDoses`), none that could be its skipped - and
    /// with the patch session. There is no time limit beyond that: while the records cannot be read, or one that could
    /// be its was skipped, it stays and delivery stays uncertain.
    private func keepUnconfirmedTempBasal(
        _ dose: UnfinalizedDose,
        sentAt: Date,
        sentUptime: TimeInterval,
        sequenceAtSend: Int,
        priorSegmentStart: Date?
    ) {
        dose.noteCommand(sentAt: sentAt, uptime: sentUptime, sequence: sequenceAtSend, priorSegmentStart: priorSegmentStart)

        doseReportLock.withLock {
            if let superseded = state.unconfirmedTempBasal {
                log.warning("The unconfirmed temp basal of \(superseded.value) U/h sent \(superseded.sentAt.map { "\($0)" } ?? "-") is superseded")
            }
            state.unconfirmedTempBasal = dose
            // Those skipped before were written before it went out
            state.skippedRecordSequences = []
            // The patch may be running it: the next temp basal cancels first
            state.basalState = .tempBasal
        }

        log.error(
            "Temp basal of \(dose.value) U/h went out unanswered: kept unreported until a status shows it running, or its " +
                "record turns up"
        )
        notifyStateDidChange()
    }

    /// The patch answered a later command - a cancel, a set, a resume - with the segment it started then: a segment of
    /// the unconfirmed temp basal started before it, and ended by then
    private func noteAnsweredSegment(startingAt start: Date) {
        doseReportLock.withLock {
            noteSegmentStart(start)
            state.unconfirmedTempBasal?.noteLaterSegment(startingAt: start)
        }
    }

    /// When the unconfirmed temp basal ended at the latest, if it ran at all: its planned end, or the start of a segment
    /// known to have begun after its command went out (`laterSegmentStart`), on our clock. Its record is written then,
    /// so the wait for it counts from there.
    internal func unconfirmedTempBasalEnd(_ pending: UnfinalizedDose) -> Date {
        guard let later = pending.snapshot.laterSegmentStart else {
            return pending.estimatedEndDate
        }
        return patchTimeOnOurClock(later, notBefore: pending.startDate, notAfter: pending.estimatedEndDate)
    }

    /// A status received at `receivedAt` shows a segment - or a suspend - that started at `start` on the patch clock, and
    /// is not the unconfirmed temp basal's. Started after its command went out, on the patch clock (through the skew,
    /// with `unansweredStartSlack` for it), it began after that command: the temp basal, if it ran at all, ended by
    /// then. Started later than the last segment known when the command went out is not enough: that one can be
    /// stale - a midnight restart we never heard of starts between the two. Returns whether no unconfirmed temp basal
    /// may still run past this segment's start - none is kept, or this one ended it.
    @discardableResult internal func noteSegmentAfterUnconfirmedTempBasal(
        startingAt start: Date,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard let pending = state.unconfirmedTempBasal else {
                return true
            }

            let unconfirmed = pending.snapshot
            let sentOnPatchClock = (unconfirmed.sentAt ?? pending.startDate)
                .addingTimeInterval(state.patchClockSkew + Self.unansweredStartSlack)
            guard let prior = unconfirmed.priorSegmentStart, start > prior, start > sentOnPatchClock,
                  !Self.statusPredatesCommand(of: unconfirmed, receivedAt: receivedAt, receivedUptime: receivedUptime)
            else {
                return false
            }

            if unconfirmed.laterSegmentStart.map({ start < $0 }) ?? true {
                log.info("A segment from \(start) began after the unconfirmed temp basal's command: it ended by then, if it ran")
            }
            pending.noteLaterSegment(startingAt: start)
            return true
        }
    }

    /// A segment the patch reported, from a status or an answer - see `MedtrumPumpState.lastSegmentStart`. Only under
    /// `doseReportLock`, which orders it against the command that reads it.
    internal func noteSegmentStart(_ start: Date) {
        state.lastSegmentStart = max(state.lastSegmentStart ?? start, start)
    }

    /// Drops the unconfirmed temp basal, never reported. Only under `doseReportLock`.
    private func dropUnconfirmedTempBasal(because reason: String) {
        guard let dose = state.unconfirmedTempBasal else {
            return
        }

        log.warning("Dropping the temp basal of \(dose.value) U/h whose command went unanswered, \(reason)")
        state.unconfirmedTempBasal = nil
    }

    /// A status received at `receivedAt` shows a temp basal segment, `basal`: one of ours whose cancel went unanswered
    /// still runs; one whose command went unanswered, started since the last segment known before it, runs - reported
    /// from its start on. Any other temp segment is not ours: it changes nothing, but may end the unconfirmed one.
    internal func followTempBasalSegment(_ basal: BasalData, fullSync: Bool, receivedAt: Date, receivedUptime: TimeInterval) {
        doseReportLock.withLock {
            let dose = state.basalDose
            let running = dose.snapshot
            let isOurRate = basal.type == .ABSOLUTE_TEMP && abs(basal.rate - dose.value) <= 0.01

            if dose.type == .tempBasal, !running.isFinished {
                if let pumpStartTime = running.pumpStartTime {
                    if isOurRate, abs(basal.startTime.timeIntervalSince(pumpStartTime)) <= RecordSyncer.tempBasalStartTolerance {
                        // What it delivered so far: our estimate of it goes from here, should its records not be read
                        dose.noteStatusDelivery(basal.delivery, receivedAt: receivedAt)

                        if fullSync, let stopUnansweredAt = running.stopUnansweredAt, receivedAt > stopUnansweredAt,
                           dose.clearStopUnanswered()
                        {
                            log.info("A full status shows the temp basal of \(dose.startDate) still running after its unanswered cancel")
                        }
                        return
                    }
                } else if isOurRate, dose.setPumpStartTime(basal.startTime) {
                    // Saved by a build that did not keep the answer's
                    log.info("Adopted patch start \(basal.startTime) for the running temp basal")
                    dose.noteStatusDelivery(basal.delivery, receivedAt: receivedAt)
                    return
                }
            }

            guard let pending = state.unconfirmedTempBasal else {
                if dose.type == .tempBasal {
                    let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
                    if isOurRate, !running.isFinished, let pumpStartTime = running.pumpStartTime,
                       basal.startTime > pumpStartTime,
                       Self.isPatchMidnight(basal.startTime, utcOffset: utcOffset) || running.recordMatchDisabled
                    {
                        // The patch restarts the running segment at patch-local midnight, and on a basal profile change
                        log.info(
                            "Status shows the temp basal of \(dose.startDate) restarted by the patch at \(basal.startTime) " +
                                "(patch-local midnight or a profile change), still running"
                        )
                    } else {
                        log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime), not our temp basal")
                    }
                }
                return
            }

            if !confirmUnconfirmedTempBasal(pending, shownBy: basal, receivedAt: receivedAt) {
                noteSegmentAfterUnconfirmedTempBasal(startingAt: basal.startTime, receivedAt: receivedAt, receivedUptime: receivedUptime)
            }
        }
    }

    /// The segment a status shows is the unconfirmed temp basal's: at its rate, started no earlier than the last segment
    /// known before its command went out (and before one a later command started) - on the patch clock, exactly. It
    /// runs: reported from its start on - or, the segment a restart of it, from its command on, and finalized from our
    /// estimate. Only under `doseReportLock`.
    /// The same second counts: the patch can start the temp basal in the second the cancel's STANDARD began, and a
    /// segment of another type starting then can only be the one that replaced it. Returns whether it was the one.
    private func confirmUnconfirmedTempBasal(
        _ pending: UnfinalizedDose,
        shownBy basal: BasalData,
        receivedAt: Date
    ) -> Bool {
        let unconfirmed = pending.snapshot
        guard basal.type == .ABSOLUTE_TEMP, abs(basal.rate - pending.value) <= 0.01,
              let prior = unconfirmed.priorSegmentStart, basal.startTime >= prior,
              unconfirmed.laterSegmentStart.map({ basal.startTime < $0 }) ?? true
        else {
            log.info(
                "Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime): not the temp basal " +
                    "whose command went unanswered"
            )
            return false
        }

        let sentAt = unconfirmed.sentAt ?? pending.startDate
        // Started well after the command, the segment is a restart of it - at patch-local midnight, on a profile
        // change - not its first: it ran from the command on, and its first record ends at the restart
        let restarted = basal.startTime.timeIntervalSince(sentAt.addingTimeInterval(state.patchClockSkew)) > Self.recordMatchWindow
        let start = restarted ? sentAt : patchTimeOnOurClock(
            basal.startTime,
            notBefore: sentAt.addingTimeInterval(-Self.unansweredStartSlack),
            notAfter: receivedAt
        )
        let tempBasalDose = UnfinalizedDose(
            tempRate: pending.value,
            duration: pending.estimatedEndDate.timeIntervalSince(pending.startDate),
            insulinType: pending.insulinType,
            automatic: pending.automatic,
            startDate: start
        )
        tempBasalDose.noteCommand(sentAt: sentAt, uptime: unconfirmed.sentUptime, sequence: unconfirmed.sequenceAtSend ?? 0)
        tempBasalDose.setPumpStartTime(basal.startTime)

        if restarted || unconfirmed.recordMatchDisabled {
            // A record of a part would finalize it with that part
            tempBasalDose.disableRecordMatch()
            log.warning(
                "Status shows the temp basal of \(pending.value) U/h whose command went unanswered running since " +
                    "\(basal.startTime), \(restarted ? "a restart of it" : "split by a profile change"): reported from " +
                    "\(start) on, finalized from our estimate, not from its records"
            )
        } else {
            log.info(
                "Status shows the temp basal of \(pending.value) U/h whose command went unanswered running since " +
                    "\(basal.startTime): reported from \(start) on"
            )
        }

        var events = endTempBasalFromEstimate(endedAt: start, because: "the temp basal whose command went unanswered replaced it")
        events.append(NewPumpEvent.tempBasal(dose: tempBasalDose.toDoseEntry(isMutable: true)))

        state.unconfirmedTempBasal = nil
        state.basalDose = tempBasalDose
        state.basalState = .tempBasal
        state.lastSync = Date.now
        emitPumpEvents(events)
        return true
    }

    /// `record` is the unconfirmed temp basal's: at its rate, started near when its command went out, between the
    /// segments known before (the same second counts, as for a status) and after it. It ran: reported once, final from
    /// its record - unless the record is only a part of it (`runSplitUnconfirmedTempBasal`). Only under
    /// `doseReportLock`.
    private func finalizeUnconfirmedTempBasal(from record: BasalRecord, sequence: Int) -> String? {
        guard let pending = state.unconfirmedTempBasal else {
            return nil
        }

        let unconfirmed = pending.snapshot
        let sentAt = unconfirmed.sentAt ?? pending.startDate
        guard RecordSyncer.steps(record.rate) == RecordSyncer.steps(pending.value),
              abs(record.startTime.timeIntervalSince(sentAt.addingTimeInterval(state.patchClockSkew))) <= Self.recordMatchWindow,
              unconfirmed.priorSegmentStart.map({ record.startTime >= $0 }) ?? true,
              unconfirmed.laterSegmentStart.map({ record.startTime < $0 }) ?? true
        else {
            return nil
        }

        let start = patchTimeOnOurClock(record.startTime, notBefore: sentAt.addingTimeInterval(-Self.unansweredStartSlack), notAfter: Date.now)
        let tempBasalDose = UnfinalizedDose(
            tempRate: pending.value,
            duration: pending.estimatedEndDate.timeIntervalSince(pending.startDate),
            insulinType: pending.insulinType,
            automatic: pending.automatic,
            startDate: start
        )
        tempBasalDose.noteCommand(sentAt: sentAt, uptime: nil, sequence: unconfirmed.sequenceAtSend ?? 0)
        tempBasalDose.setPumpStartTime(record.startTime)

        let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
        if unconfirmed.recordMatchDisabled || Self.isPatchMidnight(record.endTime, utcOffset: utcOffset) {
            return runSplitUnconfirmedTempBasal(pending, as: tempBasalDose, shownBy: record, sequence: sequence)
        }

        let endDate = start.addingTimeInterval(record.duration)
        tempBasalDose.finish(endDate >= tempBasalDose.estimatedEndDate ? .completed : .cancelled, endedAt: endDate, at: now())
        state.unconfirmedTempBasal = nil

        log.info(
            "Record \(sequence) is the temp basal of \(pending.value) U/h whose command went unanswered: it ran " +
                "\(String(format: "%.1f", record.duration / 60)) min from \(record.startTime), delivered \(record.delivered) U"
        )
        emitFinal(tempBasalDose, deliveredUnits: record.delivered, endDate: endDate)
        return "finalized unconfirmed temp basal \(start)"
    }

    /// `record`, the unconfirmed temp basal's, ends where the patch split it - at patch-local midnight, or on a profile
    /// change: only a part of it, but proof it ran. It is reported from the record's start on, and no record finalizes
    /// it: it runs until it ended at the latest (`unconfirmedTempBasalEnd`) - final at once from our estimate if that
    /// has passed. Only under `doseReportLock`.
    private func runSplitUnconfirmedTempBasal(
        _ pending: UnfinalizedDose,
        as tempBasalDose: UnfinalizedDose,
        shownBy record: BasalRecord,
        sequence: Int
    ) -> String {
        tempBasalDose.disableRecordMatch()
        let end = unconfirmedTempBasalEnd(pending)
        state.unconfirmedTempBasal = nil

        log.warning(
            "Record \(sequence) is a part of the temp basal of \(pending.value) U/h whose command went unanswered, from " +
                "\(record.startTime) to \(record.endTime) where the patch split it: it ran - reported from " +
                "\(tempBasalDose.startDate) on, finalized from our estimate, not from its records"
        )

        var events: [NewPumpEvent]
        if end <= now() {
            tempBasalDose.finish(end >= tempBasalDose.estimatedEndDate ? .completed : .cancelled, endedAt: end, at: now())
            events = estimateFinal(tempBasalDose, because: "only a part of it has a record").map { [$0] } ?? []
        } else {
            events = endTempBasalFromEstimate(
                endedAt: tempBasalDose.startDate,
                because: "the temp basal whose command went unanswered replaced it"
            )
            events.append(NewPumpEvent.tempBasal(dose: tempBasalDose.toDoseEntry(isMutable: true)))
            state.basalDose = tempBasalDose
            state.basalState = .tempBasal
        }

        state.lastSync = Date.now
        emitPumpEvents(events)
        return "part of split unconfirmed temp basal \(tempBasalDose.startDate)"
    }

    /// The patch splits a temp basal at patch-local midnight: a record of it ending then is a part
    internal static func isPatchMidnight(_ time: Date, utcOffset: TimeInterval) -> Bool {
        (time.timeIntervalSince1970 + utcOffset).truncatingRemainder(dividingBy: .hours(24)) == 0
    }

    /// A cancel of the running temp basal went out at `sentAt` and no answer came back: the patch may have stopped it.
    /// It stays running and counted until a status says otherwise.
    private func noteUnansweredCancel(sentAt: Date) {
        guard state.basalDose.markStopUnanswered(at: sentAt) else {
            return
        }

        log.warning("The cancel of the temp basal of \(state.basalDose.startDate) went unanswered, it may have stopped")
        notifyStateDidChange()
    }
}

private extension EmittedDose {
    /// Events without a dose - alerts, patch replacement - carry no delivery and are skipped.
    init?(_ event: NewPumpEvent) {
        guard let dose = event.dose else {
            return nil
        }

        self.init(
            emittedAt: Date.now,
            kind: dose.type.rawValue.uppercased(),
            start: dose.startDate,
            end: dose.endDate,
            identity: dose.syncIdentifier ?? "-",
            isMutable: dose.isMutable,
            programmed: dose.programmedUnits,
            delivered: dose.deliveredUnits
        )
    }
}

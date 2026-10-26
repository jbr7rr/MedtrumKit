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

    /// That temp basal, restored with the state of the run before - killed during its read - and its records not asked
    /// for in this run yet: read on its first status, for the patch session it was restored with, when this run began -
    /// see `takeOverTempBasalEndFromLastRun`. Only under `doseReportLock`.
    private var tempBasalEndFromLastRun: (ending: TempBasalEnd, patchId: Data, restoredAt: Date)?

    /// That temp basal, its records to read once the bolus running as it ended is over - see `readsTempBasalEndAfterBolus`.
    /// Only under `doseReportLock`.
    private var tempBasalEndAwaitingBolus: TempBasalEnd?

    /// The temp basal a command is cancelling - see `isCancelInFlight` - and the schedule a status showed meanwhile, set
    /// aside should the cancel fail (`setAsideForTheCancel`). Only under `doseReportLock`.
    private var tempBasalCancelInFlight: UnfinalizedDose?
    private var scheduleSetAsideForTheCancel: (basal: BasalData, receivedAt: Date, receivedUptime: TimeInterval)?

    /// What the batches handed over make Loop's watermark - see `LoopWatermark`. Only under `doseReportLock`.
    private var loopWatermarkModel = LoopWatermark()

    /// A bolus ran as the records of the temp basals ended open were to be read: read once it is over - see
    /// `readOpenTempBasalEndsSoon`. Only under `doseReportLock`.
    private var openTempBasalEndReadAwaitsBolus = false

    /// How long after a temp basal ended back to back its records are read, at the earliest - see
    /// `readOpenTempBasalEndsSoon`: the loop's bolus, right behind the temp basal, has the link first. Only tests change it.
    var openTempBasalEndReadDelay: TimeInterval = 5

    /// How long a command waits for the host to take the state before it writes a bolus or a temp basal - see
    /// `handOverState`. Well past the 3 s a host can take as it saves (device 2026-10-23 21:43, a bolus of 2.05 U).
    /// Only tests change it.
    var dosingHandOverTimeout: TimeInterval = 10

    /// The completion of the bolus sent and not yet answered - see `noteCompletionWithNoBolusRunning`. Only under
    /// `doseReportLock`.
    private var earlyBolusCompletion: EarlyBolusCompletion?

    /// A bolus whose command went unanswered in an earlier run, the host not yet warned of it - see
    /// `reportBolusFromLastRun`. Only under `doseReportLock`.
    private var bolusFromLastRun: UnfinalizedDose?

    /// The temp basal segments none of ours is that the host was warned of in this run, by their start on the patch
    /// clock - see `noteSegmentOfNoTempBasalOfOurs`. Only under `doseReportLock`.
    private var unknownTempBasalSegments: Set<Date> = []

    /// The held back doses (`MedtrumPumpState.heldBasalDoses`) a batch on its way to the host carries - one it has yet to
    /// answer. Only under `doseReportLock`.
    private var heldInFlight: [UnfinalizedDose] = []

    /// Where the records of a temp basal a notification ended are read: not the queue statuses arrive on, which the
    /// answers have to reach
    let tempBasalEndQueue = DispatchQueue(label: "com.nightscout.MedtrumKit.tempBasalEnd")

    /// No read queued on `tempBasalEndQueue` runs any more - see `stopBackgroundReads`
    private let backgroundReadsStopped = Locked(false)

    /// When a batch last carried the finals the host has yet to confirm. Only under `doseReportLock`.
    private var lastFinalsSentAt = Date.distantPast
    /// Without a batch for a while - no patch, or the host could not store the last one - the unconfirmed finals are
    /// sent on their own, this often at most
    private static let unconfirmedFinalsResendInterval: TimeInterval = .minutes(1)
    /// A host that never confirms would have the finals pile up for good: one fixed this long ago is given up on
    static let unconfirmedFinalMaximumAge: TimeInterval = .hours(24)

    /// Held back from every batch until the records of the temp basal whose command went unanswered are read - see
    /// `holdForUnconfirmedRead`. Only under `doseReportLock`.
    private var heldForUnconfirmedRead: [UnfinalizedDose] = []

    /// Statuses handled, and how many showed the patch halted - see `requestStatusAfterHalt`
    private let statusesHandled = Locked(0)
    private let haltsSeen = Locked(0)

    /// Commands in flight, by when they started: the record sync yields to them - see `isCommandActive`
    private let activeCommands = Locked([UUID: Date]())
    /// When the last command ended, on the manager's clock - see `isRightAfterACommand`
    private let lastCommandEndedAt = Locked(Date.distantPast)
    /// The loop's own sync (`syncPumpData`) until it hears back, a patch time fetch (`fetchPatchTimeIfStale`) in
    /// progress, and every operation waiting for `commandLock` (`lockCommandLock`) - a deactivation, a full status: not
    /// all commands, they wait for the link all the same - see `readsLongerAsTempBasalEnds`. By when each began: one
    /// not over within `loopWaitExpiry` - its connect's completion orphaned - no longer counts, as for `activeCommands`
    private let loopWaits = Locked([UUID: Date]())
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
    var uptime: () -> TimeInterval = { .continuousUptime } {
        didSet {
            state.monotonicClock = uptime
        }
    }

    public var state: MedtrumPumpState {
        didSet {
            state.doseLock = doseReportLock
        }
    }
    var oldState: MedtrumPumpState

    /// Records read off the patch, for the debug screen. Not part of `state` - see `PumpRecordStore`.
    public let recordStore = PumpRecordStore()
    /// Saved in one step with what changes the doses together: a dose that took over from another, and what is held
    /// back with the one it ended (`MedtrumPumpState.heldBasalDoses`), are never saved half-way. Nothing holds
    /// `doseReportLock` across a write on the link, or waits under it for the delegate queue or the main queue.
    ///
    /// The host's read, which it saves: a bolus or a temp basal pending in what it reads is on its way to its disk -
    /// noted for the command waiting to write it (`handOverPendingDose`). The manager's own reads take `state.rawValue`.
    public var rawState: PumpManager.RawStateValue {
        doseReportLock.withLock {
            if state.pendingBolus != nil || state.pendingTempBasal != nil {
                pendingDoseHandedOut = true
            }
            return state.rawValue
        }
    }

    /// The host read the state with the bolus or the temp basal now pending in it (`rawState`), since it was set - see
    /// `handOverPendingDose`. Only under `doseReportLock`.
    private var pendingDoseHandedOut = false

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
        state.doseLock = doseReportLock
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

        // Before the link can hand it a status: one synced against a state without the bolus, or the temp basal
        takeOverPendingBolus()
        takeOverPendingTempBasal()
        takeOverTempBasalEndFromLastRun()
        noteFinalsFromLastRun()
        link.pumpManager = self
        MedtrumLogger.pumpManager = self
    }

    /// Drives the manager over `link` instead of CoreBluetooth - for tests. Creates no central manager
    /// and registers nothing global: no app lifecycle observers, and `MedtrumLogger` keeps no reference.
    init(state: MedtrumPumpState, link: MedtrumLink) {
        self.state = state
        state.doseLock = doseReportLock
        oldState = MedtrumPumpState(rawValue: state.rawValue)
        self.link = link
        refreshLogDeviceIdentifier()

        takeOverPendingBolus()
        takeOverPendingTempBasal()
        takeOverTempBasalEndFromLastRun()
        noteFinalsFromLastRun()
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

        // Not counted as a command: the record sync below runs inside it, and would otherwise yield to it. Waiting all
        // the same, until it hears back: a temp basal's records read meanwhile take no longer than as with a command
        let waiting = loopBeginsWaiting()
        ensureConnectedAndActive(isCommand: false) { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                self.loopHearsBack(waiting, nil, completion)
                return
            }

            // Between commands: not ahead of the records a command reads, a temp basal's it ended
            guard let syncResult = self.betweenCommands({ self.link.write(SynchronizePacket()) }) else {
                self.loopHearsBack(waiting, nil, completion)
                return
            }
            StateSyncer.fetchPatchTimeIfStale(pumpManager: self)

            switch syncResult {
            case let .failure(error):
                self.log.error("Failed to write: \(error.localizedDescription)")
                self.loopHearsBack(waiting, nil, completion)
                return

            case let .success(data):
                guard let syncResponse = data as? SynchronizePacketResponse else {
                    self.log.error("Invalid response data...")
                    self.loopHearsBack(waiting, nil, completion)
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

                self.loopHearsBack(waiting, Date.now, completion)

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

            // A halt shown from here on - as the command waits for the host, say - and the bolus is not written
            let haltsBefore = self.haltsSeen.value

            guard self.state.basalState != .suspended else {
                self.log.error("Pump is suspended...")
                completion(.deviceState(MedtrumConnectError.isSuspended))
                return
            }

            // A temp basal whose records are read as it ended, its read not begun - the one restored after a restart,
            // the connect's status leaving it to the queue, which waits on this command: read first, as a command that
            // ends one reads it, within the same budget. The bolus's batch would take it out from our estimate.
            if self.pendingTempBasalEnd != nil {
                // One a halt ended, naming no record: named first
                self.askForTheRecordOfTheWaitingEnd()
                RecordSyncer.finishTempBasalEnd(
                    pumpManager: self,
                    inCommandUntil: self.now().addingTimeInterval(Self.tempBasalEndReadBudget)
                )
            }

            let sentAt = Date.now
            let sentUptime = self.uptime()
            // The newest record known, or claimed: every number an answer gave is an earlier bolus's, below this one's
            // own - see `MedtrumPumpState.answeredBolusRecords`. The known one lags a claimed one whose completion was lost.
            let sequenceAtSend = max(self.state.currentSequenceNumber, self.state.answeredBolusRecords.max() ?? 0)

            // On disk before it goes out: killed before its answer, the app comes back with it - see `pendingBolus`
            self.doseReportLock.withLock {
                self.earlyBolusCompletion = nil
                self.state.pendingBolus = PendingBolus(
                    units: units,
                    sentAt: sentAt,
                    sequenceAtSend: sequenceAtSend,
                    automatic: activationType.isAutomatic
                )
                self.pendingDoseHandedOut = false
            }
            // Not written unless the host has it: killed after the write, the app would come back without it
            guard self.handOverPendingDose(
                "the bolus of \(units) U",
                until: .now() + self.dosingHandOverTimeout,
                orElse: {
                    self.state.pendingBolus = nil
                    if let early = self.earlyBolusCompletion {
                        self.log.error(
                            "A completion of \(early.delivered) U, record \(early.record.map { "#\($0)" } ?? "-"), came " +
                                "while the bolus that is not written waited for the host: dropped"
                        )
                    }
                    self.earlyBolusCompletion = nil
                }
            ) else {
                self.log.warning(
                    "The host did not take the state within \(Int(self.dosingHandOverTimeout)) s, nor read it: the bolus of " +
                        "\(units) U is not written, it fails - not delivered"
                )
                self.notifyStateDidChange()
                completion(.deviceState(MedtrumConnectError.stateNotSaved(tempBasalCancelled: false)))
                return
            }

            // The patch showed itself halted as the command waited: not written - off the state the host has, which has it
            // pending, before the command fails
            let halted = self.doseReportLock.withLock { () -> (halted: Bool, early: EarlyBolusCompletion?) in
                guard self.haltedSince(haltsBefore) else {
                    return (false, nil)
                }
                self.state.pendingBolus = nil
                defer { self.earlyBolusCompletion = nil }
                return (true, self.earlyBolusCompletion)
            }
            if halted.halted {
                self.log.error("The patch showed a halt as the bolus of \(units) U waited for the host: not written, it fails")
                if let early = halted.early {
                    self.log.error(
                        "A completion of \(early.delivered) U, record \(early.record.map { "#\($0)" } ?? "-"), came " +
                            "while the bolus that is not written waited for the host: dropped"
                    )
                }
                self.handOverState(before: "failing the bolus")
                completion(.deviceState(MedtrumConnectError.isSuspended))
                return
            }

            // When it is written - after the wait for the host, which `sentAt`, its identity, is from before: a status
            // received before then says nothing of it (`statusPredatesCommand`)
            let writtenAt = Date.now
            let writtenUptime = self.uptime()
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
                if let early = self.doseReportLock.withLock({ () -> EarlyBolusCompletion? in
                    self.state.pendingBolus = nil
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
            doseEntry.noteWritten(at: writtenAt, uptime: writtenUptime)

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
                self.doseReportLock.withLock {
                    self.noteUncertainDelivery(.bolus, .unanswered, of: doseEntry)
                }
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

    /// Cancels the bolus running now - the one whose SetBolus is out, if none runs yet - and that one only: the cancel
    /// waits for the command lock, as long as a command may take, and that bolus may be over by then, a new one running
    /// - the loop's, once the old one's end showed no bolus. Written then, the cancel would stop the new one. So once it
    /// has the link it cancels only if the bolus it was asked for still runs (`MedtrumPumpState.isOfTheRunningBolus`);
    /// otherwise there is nothing to cancel, and it succeeds writing nothing. A second cancel of the same bolus - a retry
    /// the host offers - finds it ended by the first, whichever runs first. Asked for with no bolus known - none running
    /// nor out - it is written as before only if none is by then.
    func cancelBolus(completion: @escaping (LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) -> Void) {
        log.info("Cancelling bolus...")

        let cancel = doseReportLock.withLock { state.beginBolusCancel() }
        notifyStateDidChange()

        let finish = { (result: LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) in
            self.doseReportLock.withLock { self.state.endBolusCancel(cancel) }
            self.notifyStateDidChange()
            completion(result)
        }

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                finish(.failure(.communication(error)))
                return
            }

            // Holding the command lock: no bolus starts from here on until this is over
            guard self.doseReportLock.withLock({ self.state.isOfTheRunningBolus(cancel) }) else {
                let target = cancel.dose.map { "of \($0.startDate)" } ??
                    cancel.pendingSentAt.map { "sent at \($0)" } ?? "none known"
                self.log.info("The bolus this cancel was asked for (\(target)) is over, or another runs: nothing to cancel, not writing it")
                finish(.success(nil))
                return
            }

            let result = self.link.write(CancelBolusPacket())
            if case let .failure(error) = result {
                self.log.error("Failed to cancel bolus: \(error.localizedDescription)")
                finish(.failure(.communication(error)))
                return
            }

            self.log.info("Bolus cancelled!")

            // Ended at the last amount the patch reported, and off the running bolus in one step - only if it still is
            // the running one: a completion seen meanwhile ended it already. The completion the patch sends after the
            // cancel raises the amount (`raiseCancelledBolus`), its record fixes it.
            self.doseReportLock.withLock {
                guard let doseEntry = self.state.bolusDose, !doseEntry.isFinished,
                      cancel.dose.map({ $0 === doseEntry }) ?? true,
                      cancel.pendingSentAt.map({ $0 == doseEntry.sentAt }) ?? true
                else {
                    return
                }

                var events = self.runningTempBasal()
                events.append(contentsOf: self.awaitRecord(doseEntry, .cancelled, endedAt: Date.now))
                self.state.bolusDose = nil
                self.state.lastSync = Date.now
                self.emitBolusEvents(events)
            }

            finish(.success(nil))
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

            // A halt shown from here on leaves the patch's basal in doubt - see `requestStatusAfterHalt`
            let haltsBefore = self.haltsSeen.value

            // The status of the reconnect may have found it suspended
            guard self.state.basalState != .suspended else {
                self.log.error("Pump is suspended...")
                completion(.deviceState(MedtrumConnectError.isSuspended))
                return
            }

            // When the temp basal so far ended, if a cancel ended it - and the answer, which names the record the patch
            // wrote for it
            var cancelledAt: Date?
            var cancelSentAt: Date?
            var cancelAnswer: CancelTempBasalPacketResponse?

            defer {
                self.doseReportLock.withLock {
                    self.tempBasalCancelInFlight = nil
                    self.scheduleSetAsideForTheCancel = nil
                }
            }

            // The set is not written unless the host takes the state with it pending (`handOverPendingDose`): one that
            // can't take it now is not sent the cancel either - the command fails with nothing sent, the temp basal
            // running runs on, not the schedule till the next loop (and the loop's bolus after it, which the failed set
            // stops). One wait for the command: the set's counts from here, but never less than a hand-over takes.
            var handOverDeadline: DispatchTime?
            if self.state.basalState == .tempBasal, duration >= .ulpOfOne {
                let deadline = DispatchTime.now() + self.dosingHandOverTimeout
                guard self.handOverState(until: deadline) else {
                    self.log.warning(
                        "The host did not take the state within \(Int(self.dosingHandOverTimeout)) s: the temp basal of " +
                            "\(unitsPerHour) U/h is not set, it fails - nothing sent, the temp basal running runs on"
                    )
                    completion(.deviceState(MedtrumConnectError.stateNotSaved(tempBasalCancelled: false)))
                    return
                }
                handOverDeadline = deadline

                // Halted meanwhile: the status that showed it ended the temp basal running - nothing to cancel, nor set
                guard !self.doseReportLock.withLock({ self.haltedSince(haltsBefore) }) else {
                    self.log.error(
                        "The patch showed a halt as the command waited for the host: the temp basal of \(unitsPerHour) " +
                            "U/h is not set, it fails - nothing sent"
                    )
                    completion(.deviceState(MedtrumConnectError.isSuspended))
                    return
                }
            }

            // The temp basal the cancel ends, if one goes out
            var cancelling: UnfinalizedDose?

            if self.state.basalState == .tempBasal {
                // From here on this command reports what follows the temp basal running, whatever its outcome: the scheduled
                // basal a status shows meanwhile is the cancel's own - see `isCancelInFlight`
                cancelling = self.state.basalDose
                self.doseReportLock.withLock { self.tempBasalCancelInFlight = cancelling }

                // Need to cancel temp basal first before setting temp basal - dated on the manager's clock, as everything this
                // command dates: the same as ours, but for tests that move it
                let sentAt = self.now()
                cancelSentAt = sentAt
                let cancelResult = self.link.write(CancelTempBasalPacket())
                if case let .failure(error) = cancelResult {
                    // Unanswered, the patch may have stopped it: it stays running, counted, until a status says
                    let outcome = MedtrumCommandOutcome(error)
                    self.log.error("Failed to cancel temp basal (\(outcome)): \(error.localizedDescription)")
                    if outcome == .unknown {
                        self.noteUnansweredCancel(sentAt: sentAt)
                    }
                    // The schedule a status showed meanwhile is not the command's to report after all
                    self.takeScheduleSetAsideForTheCancel()
                    completion(outcome == .unknown ? .uncertainDelivery : .communication(error))
                    return
                }
                // On the manager's clock, as the schedule after it: the same as ours, but for tests that move it
                cancelledAt = self.now()

                // Cancelling ends the temp basal, which is exactly when the patch writes its record -
                // so this response carries the number of the record it just wrote for it
                if case let .success(data) = cancelResult, let response = data as? CancelTempBasalPacketResponse {
                    self.adoptRecordSequence(response.basalSequence, from: "Cancel temp basal")
                    self.noteAnsweredSegment(startingAt: response.basalStartTime)
                    cancelAnswer = response
                    // Had the temp basal whose command went unanswered run, this is its record: read it early, ahead of
                    // the finals of the ones after it - see `lastRecordOfOpenTempBasalEnds`
                    self.doseReportLock.withLock {
                        self.state.unconfirmedTempBasal?.noteEndRecord(Int(response.basalSequence))
                    }
                }

                // Not if a status ended it meanwhile - showing the patch halted, between the answer and here
                self.doseReportLock.withLock {
                    if self.state.basalDose === cancelling {
                        self.state.basalState = .active
                    }
                }
                self.log.info("Cancelled temp basal!")
            }

            if duration < .ulpOfOne {
                // Need to cancel temp basal, but is already cancelled
                // Only need to report back to algorithm - unless a status showed the patch halted meanwhile: it tells
                guard self.reportScheduleUnlessHalted(
                    endedAt: nil,
                    endedBy: cancelAnswer,
                    sentAt: cancelSentAt,
                    cancelled: cancelling,
                    haltsBefore: haltsBefore,
                    before: "completing the cancel"
                ) || cancelledAt != nil else {
                    completion(.deviceState(MedtrumConnectError.isSuspended))
                    return
                }

                completion(nil)
                return
            }

            // The temp basal whose command went unanswered, kept: had it run, the cancel's answer names its record. Read
            // now, before the set: final from it ahead of the new one's first report, which takes Loop's watermark past it
            if let cancelAnswer {
                self.readUnconfirmedTempBasalsRecords(through: Int(cancelAnswer.basalSequence))
            } else if cancelledAt == nil {
                // No cancel went out - a status showed a segment begun after its command, or the run before was killed
                // during this read: its record, if written, is no later than the newest the patch has
                self.readUnconfirmedTempBasalsRecords(through: self.state.currentSequenceNumber)
            }
            // A suspend held back for those records goes out ahead of anything this command reports
            self.releaseHeldForUnconfirmedRead()

            let sentAt = self.now()
            let sentUptime = self.uptime()
            let sequenceAtSend = self.state.currentSequenceNumber

            // On disk before it goes out: killed before its answer, the app comes back with it - see `pendingTempBasal`
            let priorSegmentStart = self.doseReportLock.withLock { () -> Date? in
                let priorSegmentStart = self.state.lastSegmentStart
                self.state.pendingTempBasal = PendingTempBasal(
                    unitsPerHour: unitsPerHour,
                    duration: duration,
                    automatic: automatic,
                    sentAt: sentAt,
                    sequenceAtSend: sequenceAtSend,
                    priorSegmentStart: priorSegmentStart,
                    cancelledAt: cancelledAt,
                    cancelSegmentStart: cancelledAt.flatMap { at in
                        cancelAnswer.flatMap {
                            self.cancelSegmentOnPatch(at: at, cancel: $0, cancelSentAt: cancelSentAt, tempBasal: self.state.basalDose)
                        }
                    }
                )
                self.pendingDoseHandedOut = false
                return priorSegmentStart
            }
            // Not written unless the host has it, as a bolus: killed after the write, the app would come back with the patch
            // running a temp basal it has no dose of, uncounted. The cancel that went out first stands: the scheduled basal
            // from it, reported as when the set fails.
            let deadline = max(handOverDeadline ?? .now() + self.dosingHandOverTimeout, .now() + Self.stateHandOverTimeout)
            guard self.handOverPendingDose("the temp basal of \(unitsPerHour) U/h", until: deadline, orElse: {
                self.state.pendingTempBasal = nil
            }) else {
                self.log.warning(
                    "The host did not take the state in time, nor read it: the temp basal of \(unitsPerHour) U/h is not " +
                        "written, it fails" + (cancelledAt != nil ? " - the temp basal before was cancelled" : "")
                )
                if let cancelledAt {
                    self.failSetAfterCancel(
                        cancelledAt: cancelledAt,
                        cancelAnswer: cancelAnswer,
                        cancelSentAt: cancelSentAt,
                        cancelled: cancelling,
                        haltsBefore: haltsBefore
                    )
                } else {
                    self.notifyStateDidChange()
                }
                completion(.deviceState(MedtrumConnectError.stateNotSaved(tempBasalCancelled: cancelledAt != nil)))
                return
            }

            // A status showed the patch halted since the command began - during the cancel, the reads, the wait for the
            // host: not written, off the state the host has, which has it pending. What follows the cancel, if one went
            // out, the status tells.
            let haltedMeanwhile = self.doseReportLock.withLock { () -> Bool in
                guard self.haltedSince(haltsBefore, cancelling: cancelling) else {
                    return false
                }
                self.state.pendingTempBasal = nil
                return true
            }
            if haltedMeanwhile {
                self.log.error(
                    "The patch showed a halt as the command ran: the temp basal of \(unitsPerHour) U/h is not written, it " +
                        "fails" + (cancelledAt != nil ? " - the temp basal before was cancelled" : "")
                )
                if let cancelledAt {
                    self.failSetAfterCancel(
                        cancelledAt: cancelledAt,
                        cancelAnswer: cancelAnswer,
                        cancelSentAt: cancelSentAt,
                        cancelled: cancelling,
                        haltsBefore: haltsBefore
                    )
                } else {
                    self.handOverState(before: "failing the temp basal")
                }
                completion(.deviceState(MedtrumConnectError.isSuspended))
                return
            }

            // When it is written, after the wait for the host - see `enactBolus`
            let writtenAt = self.now()
            let writtenUptime = self.uptime()
            let packet = SetTempBasalPacket(rate: unitsPerHour, duration: duration)
            let tempBasalResult = self.link.write(packet)
            // Held back meanwhile - the patch halted as the set went out: out ahead of what the answer reports
            self.releaseHeldForUnconfirmedRead()
            let outcome = MedtrumCommandOutcome(tempBasalResult)

            if case let .failure(error) = tempBasalResult, outcome != .unknown {
                self.log.error("Failed to set temp basal (\(outcome)): \(error.localizedDescription)")

                // Never sent, or turned down: the patch runs what it did before the set. The scheduled basal, if the
                // cancel ended a temp basal - reported, nothing pending in the state saved with it. With no cancel nothing
                // changed: a temp basal still running runs on. Off the saved state before the command fails either way:
                // killed after it, the app must not come back with a temp basal that never ran.
                if let cancelledAt {
                    self.failSetAfterCancel(
                        cancelledAt: cancelledAt,
                        cancelAnswer: cancelAnswer,
                        cancelSentAt: cancelSentAt,
                        cancelled: cancelling,
                        haltsBefore: haltsBefore
                    )
                } else {
                    self.doseReportLock.withLock { self.state.pendingTempBasal = nil }
                    self.handOverState(before: "failing the temp basal")
                }

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
                let unconfirmed = UnfinalizedDose(
                    tempRate: unitsPerHour,
                    duration: duration,
                    insulinType: self.state.insulinType,
                    automatic: automatic,
                    confirmation: .uncertain,
                    startDate: sentAt
                )
                unconfirmed.noteWritten(at: writtenAt, uptime: writtenUptime)
                self.keepUnconfirmedTempBasal(
                    unconfirmed,
                    sentAt: sentAt,
                    sentUptime: sentUptime,
                    sequenceAtSend: sequenceAtSend,
                    priorSegmentStart: priorSegmentStart,
                    // The schedule from the cancel, reported right after: else what ran as it went out - with where it began
                    // on the patch clock, if known
                    basalBefore: cancelledAt ?? self.reportedBasalStart,
                    basalBeforeOnPatch: cancelledAt.map { at in
                        cancelAnswer.flatMap {
                            self.cancelSegmentOnPatch(at: at, cancel: $0, cancelSentAt: cancelSentAt, tempBasal: self.state.basalDose)
                        }
                    } ?? self.reportedBasalPatchStart
                )

                // What the host was told stands: the temp basal before ended at the cancel, then the schedule. With
                // the set unanswered the link may be gone: its record is not read now - our estimate stands in, and a
                // sync reads the record later, changing nothing.
                if let cancelledAt, self.state.basalDose.type == .tempBasal {
                    self.reportScheduledBasal(
                        tempBasalEndedAt: cancelledAt,
                        endedBy: cancelAnswer,
                        sentAt: cancelSentAt,
                        readsRecords: outcome != .unknown
                    )
                }

                completion(.uncertainDelivery)
                return
            }

            self.log.info("Set temp basal!")

            // Never before a resume dated up to a second ahead - see `earliestAfter`
            let tempBasalDose = UnfinalizedDose(
                tempRate: unitsPerHour,
                duration: duration,
                insulinType: self.state.insulinType,
                automatic: automatic,
                startDate: max(self.now(), Self.earliestAfter(self.state.basalDose))
            )
            tempBasalDose.noteCommand(sentAt: sentAt, uptime: sentUptime, sequence: sequenceAtSend)
            tempBasalDose.noteWritten(at: writtenAt, uptime: writtenUptime)

            // The patch's own clock, where its records start
            tempBasalDose.setPumpStartTime(response.basalStartTime)
            let skew = response.basalStartTime.timeIntervalSince(tempBasalDose.startDate)
            self.log.info("Temp basal patch start \(response.basalStartTime) (skew \(String(format: "%+.1f", skew))s)")

            // The old one ends where the new one starts, and both go out in one batch: the old one mutable until its
            // records - the one the cancel named - are read, after this command
            self.replaceRunningBasal(endedBy: cancelAnswer, sentAt: cancelSentAt) {
                self.state.basalState = .tempBasal
                self.state.lastSync = Date.now
                return (tempBasalDose, NewPumpEvent.tempBasal(dose: tempBasalDose.toDoseEntry(isMutable: true)))
            }
            self.notifyStateDidChange()
            self.requestStatusAfterHalt(seenSince: haltsBefore)

            completion(nil)
        }
    }

    /// A status showed the patch halted while the command ran - `haltsBefore` counted as it began - and the command
    /// leaves a temp basal reported running: the set's answer said it started, the halt that the patch may not run it.
    /// The status after shows which, and ends it if halted - dated when it is received, a halt telling no time of its
    /// own: a full status is asked for right after the command, once, not left to the next heartbeat's - unless another
    /// status arrives first, which tells the same. Off the command's thread, once it is over, holding the command lock.
    private func requestStatusAfterHalt(seenSince haltsBefore: Int) {
        guard haltsSeen.value != haltsBefore else {
            return
        }
        let running = state.basalDose
        guard running.type == .tempBasal, !running.isFinished else {
            return
        }
        let statusesBefore = statusesHandled.value
        log.info("The patch showed a halt during the command, the temp basal of \(running.startDate) reported running: asking for its status")

        tempBasalEndQueue.async { [weak self] in
            guard let self else {
                return
            }

            let deadline = Date.now.addingTimeInterval(Self.commandActivityTimeout)
            while self.isCommandActive, Date.now < deadline, !self.backgroundReadsStopped.value {
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard !self.backgroundReadsStopped.value else {
                return
            }
            guard self.statusesHandled.value == statusesBefore else {
                self.log.info("A status arrived since the halt: not asking for another")
                return
            }

            guard let result = self.betweenCommands({ self.link.write(SynchronizePacket()) }) else {
                return
            }
            guard case let .success(data) = result, let response = data as? SynchronizePacketResponse else {
                self.log.warning("The status asked for after the halt did not come: the next one tells")
                return
            }
            self.handleStatus(response, duringReconnect: false, fullSync: true)
            self.notifyStateDidChange()
        }
    }

    /// Whether a status showed the patch halted since the command began - `haltsBefore` counted then - or it is taken to
    /// be suspended, or `cancelling`, the temp basal the command cancelled, is no longer the basal running: a status
    /// ended it. What the command was to write next is not written then, nor the schedule from its cancel reported - the
    /// suspend that status reported would be left open, no resume after it (`requestStatusAfterHalt`). Only under
    /// `doseReportLock`.
    private func haltedSince(_ haltsBefore: Int, cancelling: UnfinalizedDose? = nil) -> Bool {
        haltsSeen.value != haltsBefore || state.basalState == .suspended || state.basalDose.type == .suspend ||
            cancelling.map { state.basalDose !== $0 } == true
    }

    /// A status is handled - showing the patch halted, `halted`
    internal func noteStatusHandled(halted: Bool) {
        statusesHandled.mutate { $0 += 1 }
        if halted {
            haltsSeen.mutate { $0 += 1 }
        }
    }

    /// `tempBasalEndedAt`: when the temp basal running so far stopped. `endedBy`: the answer to the cancel that stopped
    /// it, which names its record.
    /// `sentAt`: when that cancel went out. `readsRecords`: records may be read on the way - the one the cancel named, and
    /// those of temp basals ended open before - not after a command that went unanswered: the link may be gone. The
    /// cancel's answer still tells where the patch ended it. `unless`: checked in the step that reports it, under
    /// `doseReportLock` - true, nothing is reported, nothing pending. Returns whether it was reported.
    @discardableResult private func reportScheduledBasal(
        tempBasalEndedAt: Date? = nil,
        endedBy cancel: CancelTempBasalPacketResponse? = nil,
        sentAt cancelSentAt: Date? = nil,
        readsRecords: Bool = true,
        unless notReported: (() -> Bool)? = nil
    ) -> Bool {
        let tempBasalEndedAt = tempBasalEndedAt ?? now()
        var reported = false
        replaceRunningBasal(endedBy: cancel, sentAt: cancelSentAt, readsRecords: readsRecords) {
            if let notReported, notReported() {
                state.pendingTempBasal = nil
                return nil
            }
            reported = true
            let basalDose = UnfinalizedDose(
                basalRate: state.currentBaseBasalRate,
                insulinType: state.insulinType,
                startDate: tempBasalEndedAt
            )
            // Its start on the patch clock - what this one is told from, skew-free - the same instant on both clocks: the
            // temp basal it ends still the running one
            if let cancel,
               let onPatch = cancelSegmentOnPatch(
                   at: basalDose.startDate,
                   cancel: cancel,
                   cancelSentAt: cancelSentAt,
                   tempBasal: state.basalDose
               )
            {
                basalDose.setPumpStartTime(onPatch)
            }
            state.lastSync = Date.now
            return (basalDose, NewPumpEvent.basal(dose: basalDose.toDoseEntry()))
        }
        notifyStateDidChange()
        return reported
    }

    /// The set of a command that cancelled `cancelled`, the temp basal running, at `cancelledAt` failed - not written, or
    /// never sent: the patch runs its schedule from the cancel, reported - unless a status showed it halted meanwhile
    /// (`haltsBefore` counted as the command began), or ended `cancelled` otherwise: see `reportScheduleUnlessHalted`.
    /// Nothing pending either way.
    private func failSetAfterCancel(
        cancelledAt: Date,
        cancelAnswer: CancelTempBasalPacketResponse?,
        cancelSentAt: Date?,
        cancelled: UnfinalizedDose?,
        haltsBefore: Int
    ) {
        reportScheduleUnlessHalted(
            endedAt: cancelledAt,
            endedBy: cancelAnswer,
            sentAt: cancelSentAt,
            cancelled: cancelled,
            haltsBefore: haltsBefore,
            before: "failing the temp basal"
        )
    }

    /// The schedule from the cancel of `cancelled`, if one went out, at `endedAt` (now, if nil): reported - unless a status
    /// showed the patch halted since the command began (`haltsBefore` counted then), or ended `cancelled` otherwise
    /// (`haltedSince`), checked in the step that would report it: its end is then that status's, what the patch runs the
    /// status after it tells, asked for if `cancelled` still runs (`requestStatusAfterHalt`) - a schedule from the cancel
    /// would come dated behind the suspend that status reported, leaving it open. Nothing pending either way, the state
    /// handed over before `action`. Returns whether it was reported.
    @discardableResult private func reportScheduleUnlessHalted(
        endedAt: Date?,
        endedBy cancelAnswer: CancelTempBasalPacketResponse?,
        sentAt cancelSentAt: Date?,
        cancelled: UnfinalizedDose?,
        haltsBefore: Int,
        before action: String
    ) -> Bool {
        let halted = { self.haltedSince(haltsBefore, cancelling: cancelled) }
        if !doseReportLock.withLock(halted),
           reportScheduledBasal(tempBasalEndedAt: endedAt, endedBy: cancelAnswer, sentAt: cancelSentAt, unless: halted)
        {
            return true
        }
        log.warning(
            "A status showed the patch halted, or ended the temp basal cancelled, while the command ran: the scheduled " +
                "basal is not reported from the cancel - the status tells"
        )
        doseReportLock.withLock { state.pendingTempBasal = nil }
        handOverState(before: action)
        requestStatusAfterHalt(seenSince: haltsBefore)
        return false
    }

    /// The basal `change` returns takes over from the running one, and both go out in one batch. `change` runs under
    /// `doseReportLock`, sets the rest of the state the batch is saved with, and returns the new basal and its report -
    /// nil to change nothing. The temp basal whose set is pending, if any, is settled by the change: no longer pending
    /// once the new basal is in place.
    ///
    /// A temp basal running till then that the new one replaces back to back - the new one starting before the old one
    /// was to end - ends open where the new one starts: reported ended, and mutable, its records read after this command
    /// (`readOpenTempBasalEndsSoon`). Nothing comes between the two for the host to fill.
    ///
    /// Any other end of a temp basal - a cancel to the schedule, a suspend, a resume, one that ran its course before the
    /// next - leaves a gap after it, or a dose of another kind: it ends final, and every temp basal ended open before it
    /// with it - from their records, read right here up to the one the cancel that ended it named (`endedBy`), else from
    /// our estimate. A command's path, holding `commandLock`: no other command comes between its answer and these reads,
    /// which block on the link for `tempBasalEndReadBudget` at most. The host has the state before they start - handed
    /// over first, outside that budget (`stateHandOverTimeout`): killed during them, the app comes back with the new
    /// basal running and the temp basal ended, its records read on the first link (`takeOverTempBasalEndFromLastRun`).
    /// So too before the full status asked for a temp basal a halt ended naming no record (`askForTheRecordOfTheWaitingEnd`),
    /// whose status may have its records read right away: the app comes back waiting on it, the new basal running.
    /// With no cancel, `lastRecord` is the record the patch wrote as the command ended it, where known: a suspend's, a
    /// resume's - read in the same way.
    private func replaceRunningBasal(
        endedBy cancel: CancelTempBasalPacketResponse? = nil,
        sentAt cancelSentAt: Date? = nil,
        lastRecord: Int? = nil,
        readsRecords: Bool = true,
        _ change: () -> (dose: UnfinalizedDose, event: NewPumpEvent)?
    ) {
        let endedOpen = doseReportLock.withLock { () -> Bool in
            guard let next = change() else {
                return false
            }

            // A temp basal a status ended meanwhile - the suspend the patch announced, say - goes out final from the
            // records it names, and the new basal after it, in the same batch: the state handed over before they are
            // read has the new basal running
            let running = state.basalDose
            if let pending = pendingTempBasalEndStorage, running.type != .tempBasal || running.isFinished {
                hold(next, after: pending)
                state.basalDose = next.dose
                state.pendingTempBasal = nil
                return false
            }

            // A resume behind a suspend held back since the reads before it
            if running.type != .tempBasal || running.isFinished, holdWithHeldSuspend(next.dose) {
                state.basalDose = next.dose
                state.pendingTempBasal = nil
                return false
            }

            // The patch ran the old one for less time than we did up to the cancel: it had stopped it before, unseen, and
            // ran the schedule since - that gap is the host's to fill. Told on each clock alone, skew-free.
            let stoppedAt = running.type == .tempBasal ? cancel.flatMap { cancel in
                cancelSentAt.flatMap { stopBeforeCancel(of: running, patchEnd: cancel.basalStartTime, cancelSentAt: $0) }
            } : nil
            let stoppedBefore = stoppedAt != nil

            if next.dose.type == .tempBasal, running.type == .tempBasal, !running.isFinished,
               next.dose.startDate <= running.estimatedEndDate, !stoppedBefore
            {
                endOpen(running, at: next.dose.startDate, patchEnd: cancel?.basalStartTime, lastRecord: cancel.map { Int($0.basalSequence) })
                state.basalDose = next.dose
                state.pendingTempBasal = nil
                // Those that can be settled without their records go final now, the oldest first - the rest mutable,
                // ended where the next one starts
                let finals = settleOpenTempBasalEnds()
                let open = openTempBasalEnds.compactMap { NewPumpEvent.finishedDose($0, entry: $0.toDoseEntry(isMutable: true)) }
                emitPumpEvents(finals + open + [next.event])
                return true
            }

            let ending = beginTempBasalEnd(
                endedAt: stoppedAt ?? next.dose.startDate,
                patchEnd: cancel?.basalStartTime,
                lastRecord: readsRecords ? cancel.map { Int($0.basalSequence) } ?? lastRecord : nil,
                readsOpenEnds: readsRecords,
                then: next
            )
            state.basalDose = next.dose
            state.pendingTempBasal = nil
            if !ending {
                keepUntilStored(next.dose)
                emitPumpEvents([next.event])
            }
            return false
        }

        if endedOpen {
            readOpenTempBasalEndsSoon()
            return
        }

        guard let ending = pendingTempBasalEnd else {
            // The record a cancel named for the temp basal whose command went unanswered, read after the command
            if let record = lastRecordOfOpenTempBasalEnds, record > state.syncedSequenceNumber {
                readOpenTempBasalEndsSoon()
            }
            return
        }

        // Ended by a halt whose status named no record: named here, not with what this command did held behind it - the
        // state handed over first, its status may have the records read at once. Not after a command that went
        // unanswered: the link may be gone, and the ask would only wait out its timeout.
        var handedOver = false
        if readsRecords, ending.awaitsRecord {
            handOverState(before: "asking for the status that names the records")
            handedOver = true
            askForTheRecordOfTheWaitingEnd()
        }

        // Nothing to hand over for when nothing will be read: the batch settling it saves the state with it
        if !handedOver, RecordSyncer.wouldRead(ending, pumpManager: self) {
            handOverState(before: "reading the records")
        }
        RecordSyncer.finishTempBasalEnd(
            pumpManager: self,
            inCommandUntil: now().addingTimeInterval(Self.tempBasalEndReadBudget)
        )
    }

    /// Hands the state to the host, and waits until it has it - `stateHandOverTimeout` at most: a command is about to
    /// read the records of the temp basal it ended, a round trip or more on the link, and only then does the batch go
    /// out that saves the state with it - or to fail a bolus or a temp basal, which a kill after must not bring back.
    /// Best effort: a host slower than that is not waited for, and that is logged. Not holding `doseReportLock`, nor on
    /// the delegate queue.
    private func handOverState(before action: String) {
        guard handOverState(until: .now() + Self.stateHandOverTimeout) else {
            log.warning("The host did not take the state within \(Int(Self.stateHandOverTimeout)) s, \(action) anyway")
            return
        }
    }

    /// Hands the state to the host, and waits until it has it - until `deadline` at most. Returns whether it did. Not
    /// holding `doseReportLock`, nor on the delegate queue.
    private func handOverState(until deadline: DispatchTime) -> Bool {
        let handedOver = DispatchSemaphore(value: 0)
        pumpDelegate.notify { delegate in
            delegate?.pumpManagerDidUpdateState(self)
            handedOver.signal()
        }
        return handedOver.wait(timeout: deadline) == .success
    }

    /// Hands the state to the host with `dose`, a bolus or a temp basal, pending in it - about to be written - and waits
    /// until it has it, until `deadline` at most (`dosingHandOverTimeout`): a kill after the write, before the host saved
    /// the state with it pending, would leave the next run with no dose of it - its record matching nothing of ours,
    /// what it delivered missing at the host (device 2026-10-23 15:42, the host's queue stalled 80 s). Returns whether
    /// it is written.
    ///
    /// The host saves the state as it reads it (`rawState`), and only then is it done - its log, its status updates
    /// after (device: the stall was its logging). So past the deadline, under `doseReportLock`, which its read takes:
    /// read by the host with `dose` pending, it is on its way to its disk - the host writes what it read right after -
    /// and written all the same, logged. Not read: `notWritten` takes it off the state, in the same step - no read from
    /// then on has it pending - and the caller fails it, and logs it. Not on the delegate queue.
    private func handOverPendingDose(_ dose: String, until deadline: DispatchTime, orElse notWritten: () -> Void) -> Bool {
        // How long it waits - the bound of the command, what is left of it - for the log
        let start = DispatchTime.now()
        let waits = deadline > start ? Double(deadline.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 : 0
        if handOverState(until: deadline) {
            return true
        }
        return doseReportLock.withLock { () -> Bool in
            guard pendingDoseHandedOut else {
                notWritten()
                return false
            }
            log.warning(
                "The host did not take the state within \(Int(waits.rounded())) s, but read it with \(dose) pending - " +
                    "saving it: written"
            )
            return true
        }
    }

    /// How long a command waits for the host to take the state before it reads records, or fails a bolus or a temp basal
    private static let stateHandOverTimeout: TimeInterval = 3

    /// How far apart a temp basal's end on the patch clock - taken to ours through the skew - and where we saw it end
    /// may be and still be the same: the skew is known to a few seconds only (`unansweredStartSlack`), and an answer
    /// takes a second or two to come back. Further apart, the patch had stopped it earlier: the gap is the schedule's.
    internal static let patchEndTolerance: TimeInterval = unansweredStartSlack

    /// No final ends this close to its start by an end we worked out: it would be dropped by the host as 0-duration, and
    /// what it delivered with it - our observed end stands instead
    internal static let shortestComputedDuration: TimeInterval = 1

    /// Where the patch had stopped `dose` before our cancel went out at `cancelSentAt`, on our clock - nil if it ran it up
    /// to the cancel, as far as we can tell. Told on each clock alone, so a wrong skew does not move it: how long the
    /// patch ran it (from its patch start to `patchEnd`, the start of the segment the cancel's answer reports) against how
    /// long we had it running when the cancel went out (from its answer). Short of that by more than `patchEndTolerance`,
    /// it was stopped then. Without a patch start, or one not of its first segment (`firstSegmentUncertain`), nothing is
    /// told.
    private func stopBeforeCancel(of dose: UnfinalizedDose, patchEnd: Date, cancelSentAt: Date, logging: Bool = true) -> Date? {
        let running = dose.snapshot
        // Its patch start a later segment's, or its start not the patch's on our clock: nothing to tell it from
        guard let pumpStartTime = running.pumpStartTime, !running.firstSegmentUncertain else {
            return nil
        }
        let patchElapsed = max(0, patchEnd.timeIntervalSince(pumpStartTime))
        // From its answer: short of the patch's by the round trip - never a stop that was not
        let ourElapsed = cancelSentAt.timeIntervalSince(dose.startDate)
        guard patchElapsed < ourElapsed - Self.patchEndTolerance else {
            return nil
        }
        guard patchElapsed >= Self.shortestComputedDuration else {
            guard logging else {
                return nil
            }
            log.warning(
                "The cancel of the temp basal of \(dose.startDate) says the patch ran it \(Int(patchElapsed)) s: not ended " +
                    "on that, it would end where it started - where we saw it end instead"
            )
            return nil
        }
        let stoppedAt = dose.startDate.addingTimeInterval(patchElapsed)
        if logging {
            log.warning(
                "The cancel of the temp basal of \(dose.startDate) says the patch ran it \(Int(patchElapsed)) s, we had it " +
                    "running \(Int(ourElapsed)) s: the patch had stopped it at \(stoppedAt) - it ends there, the schedule ran since"
            )
        }
        return stoppedAt
    }

    /// The patch time of `ourTime` - the cancel's answer, or the schedule after it, dated at it - for an anchor: the
    /// instant `cancel` ended `tempBasal` on both clocks. Its segment began at `basalStartTime` on the patch clock: there
    /// on ours too, the cancel going out as the patch ended it - unless the patch had stopped it before, at
    /// `stopBeforeCancel` on ours: then `ourTime` is that much later on the patch clock as well.
    /// Not a temp basal running - the reported schedule, a temp basal kept unconfirmed that never ran - the cancel ended
    /// nothing: its segment still the one running, `ourTime` is as far past its start on both clocks. A segment the patch
    /// began since is the cancel's own. Nil, the running one's patch start unknown: no anchor - the skew stands in.
    private func cancelSegmentOnPatch(
        at ourTime: Date,
        cancel: CancelTempBasalPacketResponse,
        cancelSentAt: Date?,
        tempBasal: UnfinalizedDose
    ) -> Date? {
        guard tempBasal.type == .tempBasal else {
            guard let runningOnPatch = tempBasal.pumpStartTime else {
                return nil
            }
            guard cancel.basalStartTime == runningOnPatch else {
                return cancel.basalStartTime
            }
            return runningOnPatch.addingTimeInterval(ourTime.timeIntervalSince(tempBasal.startDate))
        }
        guard let cancelSentAt,
              let stoppedAt = stopBeforeCancel(of: tempBasal, patchEnd: cancel.basalStartTime, cancelSentAt: cancelSentAt, logging: false)
        else {
            return cancel.basalStartTime
        }
        return cancel.basalStartTime.addingTimeInterval(ourTime.timeIntervalSince(stoppedAt))
    }

    /// `patchTime`, where the patch ended `dose`, for an anchor at `ourTime`: only if `ourTime` is that same instant on our
    /// clock, told skew-free from its patch start (`endOnOurClock`, not bounded). Nil otherwise: the skew is all there
    /// is, and an anchor through it would tell nothing more.
    internal func patchTimePaired(with ourTime: Date, endOf dose: UnfinalizedDose, at patchTime: Date) -> Date? {
        let running = dose.snapshot
        guard dose.type == .tempBasal, let pumpStartTime = running.pumpStartTime, !running.firstSegmentUncertain,
              dose.startDate.addingTimeInterval(max(0, patchTime.timeIntervalSince(pumpStartTime))) == ourTime
        else {
            return nil
        }
        return patchTime
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

            let sequenceBefore = self.state.currentSequenceNumber
            let result = self.link.write(SuspendPumpPacket(duration: duration))
            if case let .failure(error) = result {
                self.log.error("Failed to suspend delivery: \(error.localizedDescription)")
                completion(error)
                return
            }
            // As near as we know, not after the wait below
            let start = self.now()

            // The patch announces the suspend right away, with its exact time, and that status usually beats this:
            // it dated the suspend and ended the temp basal there already - its records are read here. A temp basal of
            // ours still running, it is waited for a moment. Otherwise at the answer - the temp basal's records read up
            // to the newest record the patch told of since the write, the one it wrote as it ended it, or the records
            // before the write still unread; from our estimate if there are none, or they cannot be read.
            let endRecord = self.awaitSuspendAnnouncement(after: sequenceBefore)
            // The temp basal whose command went unanswered, kept: its record, if written, read before the suspend is
            // reported - Loop fills up to a suspend, its watermark past the unanswered one. A suspend the status
            // reported is held back meanwhile (`holdForUnconfirmedRead`).
            self.readUnconfirmedTempBasalsRecords(through: self.state.currentSequenceNumber)
            self.releaseHeldForUnconfirmedRead()
            self.replaceRunningBasal(lastRecord: endRecord) {
                // Before the batch: the state saved with it is suspended
                self.state.basalState = .suspended
                self.state.lastSync = Date.now

                guard self.state.basalDose.type != .suspend else {
                    return nil
                }

                // Never before a resume dated up to a second ahead - see `earliestAfter`
                let basalDose = UnfinalizedDose(suspendStartTime: max(start, Self.earliestAfter(self.state.basalDose)))
                return (basalDose, NewPumpEvent.suspend(dose: basalDose.toDoseEntry()))
            }
            self.notifyStateDidChange()

            self.log.info("Delivery suspended for \(duration.minutes) min!")
            completion(nil)
        }
    }

    /// The patch, told to suspend, announces it right after its answer: a status with when it suspended, naming the
    /// newest record - the one it wrote for the temp basal it ended (device log 2026-10-20 09:50:02, in the second of the
    /// answer). With a temp basal of ours still running it is waited for, `suspendAnnouncementWait` at most: the status
    /// then ends the temp basal itself, where the patch suspended, its records read in the command - or a heartbeat
    /// names a newer record than `sequenceBefore`, the newest known as the command went out. Returns that record, the
    /// last of the temp basal's to read. With none told, `sequenceBefore` if records up to it are unread: the patch may
    /// have ended the temp basal unseen before the write - it ran its course, say, then not waited for - its record among
    /// them. Nil - none running, a status ended it, or nothing to read.
    private func awaitSuspendAnnouncement(after sequenceBefore: Int) -> Int? {
        let deadline = Date.now.addingTimeInterval(Self.suspendAnnouncementWait)
        while true {
            let (running, pastItsEnd, newest, synced) = doseReportLock.withLock { () -> (Bool, Bool, Int, Int) in
                let dose = state.basalDose
                return (
                    dose.type == .tempBasal && !dose.isFinished,
                    now() >= dose.estimatedEndDate,
                    state.currentSequenceNumber,
                    state.syncedSequenceNumber
                )
            }
            guard running else {
                return nil
            }
            if newest > sequenceBefore {
                return newest
            }
            let unread = sequenceBefore > synced ? sequenceBefore : nil
            if pastItsEnd {
                return unread
            }
            guard Date.now < deadline else {
                let known = unread.map { "reading the records up to \($0)" } ?? "no record of the temp basal's end is known"
                log.info("No status announced the suspend within \(Int(Self.suspendAnnouncementWait)) s: \(known)")
                return unread
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// How long a suspend command waits for the patch to announce it, a temp basal of ours running - see
    /// `awaitSuspendAnnouncement`
    internal static let suspendAnnouncementWait: TimeInterval = 2

    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        log.info("Resuming delivery...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error)
                return
            }

            // A suspend held back for the records of the temp basal whose command went unanswered goes out first, those
            // records read before, as a suspend command does: the unanswered one final from its own ahead of the suspend
            // - Loop fills up to it, its watermark past the unanswered one. Before the resume is written: the patch still
            // suspended, its record written at the halt, and no status of its schedule comes during the reads - the one it
            // sends a second after the resume would, its resume then held back with the suspend (`holdWithHeldSuspend`).
            self.releaseHeldAfterUnconfirmedRead()

            let response = self.link.write(ResumePumpPacket())
            if case let .failure(error) = response {
                self.log.error("Failed to resume delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            self.log.info("Resumed delivery!")

            // The answer carries the segment the patch resumed with, started at the resume on its clock - and the newest
            // record: a temp basal still taken to run has its record among those, written as the patch suspended
            var segmentStart: Date?
            var newestRecord: Int?
            if case let .success(data) = response, let answer = data as? ResumePumpPacketResponse,
               let start = answer.basalStartTime
            {
                segmentStart = start
                if let sequence = answer.basalSequence {
                    self.adoptRecordSequence(sequence, from: "Resume")
                    newestRecord = self.state.currentSequenceNumber
                }
                self.noteAnsweredSegment(startingAt: start)
            }

            // The same for a suspend a halt seen during the write held back - after the resume, Loop would have its
            // watermark past it, and never store the suspension. A resume a status reported during those reads is held
            // with it (`holdWithHeldSuspend`), out after it.
            self.releaseHeldAfterUnconfirmedRead()

            // Read and replaced in one step - see `doseReportLock`. A status showing the scheduled basal may have
            // reported the resume already - or held it back, behind a suspend held since.
            self.replaceRunningBasal(lastRecord: newestRecord) {
                // Before the batch: the state saved with it is resumed
                self.state.basalState = .active
                self.state.lastSync = Date.now

                guard self.state.basalDose.type == .suspend || self.state.basalDose.type == .tempBasal else {
                    return nil
                }

                var resumedAt = segmentStart.map {
                    self.endOnOurClock(of: self.state.basalDose, patchTime: $0, notAfter: self.now())
                } ?? self.now()
                // In a later second than the suspend at the earliest - see `earliestResume`
                if self.state.basalDose.type == .suspend {
                    resumedAt = max(resumedAt, Self.earliestResume(after: self.state.basalDose.startDate))
                }

                // A temp basal still taken to run stopped at the suspend for good (the patch resumes the schedule):
                // ended at the resume at the latest, final from its record - read up to the newest the answer named -
                // else from our estimate. The schedule follows it, not a resume: with no suspend reported before it,
                // iAPS would take the patch to have been suspended since before its history (`holdWithHeldSuspend`).
                let tookTempBasalToRun = self.state.basalDose.type == .tempBasal
                let resumeDose = tookTempBasalToRun
                    ? UnfinalizedDose(basalRate: self.state.currentBaseBasalRate, insulinType: self.state.insulinType, startDate: resumedAt)
                    : UnfinalizedDose(resumeStartTime: resumedAt, insulinType: self.state.insulinType)
                // Its start on the patch clock, where it is the same instant as on ours
                if let segmentStart, let paired = self.patchTimePaired(with: resumedAt, endOf: self.state.basalDose, at: segmentStart) {
                    resumeDose.setPumpStartTime(paired)
                }

                return (
                    resumeDose,
                    tookTempBasalToRun ? NewPumpEvent.basal(dose: resumeDose.toDoseEntry()) : NewPumpEvent.resume(dose: resumeDose.toDoseEntry())
                )
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

            // The temp basal a halt ended, naming no record, has it named first - read with the rest, not taken out from
            // our estimate as the session ends. Before the deactivation is under way: the status may tell of a base reset
            // instead, which ends the session as any status's would (`handleBaseReset`) - nothing left to deactivate then.
            self.askForTheRecordOfTheWaitingEnd()
            if sessionEndedWhileConnecting() {
                self.log.info("Patch session ended with the status asked for, nothing left to deactivate")
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
            self.endPatchSession(deliveryStoppedAt: Date.now, statusIsCurrent: true, disconnect: false)

            self.log.info("Patch deactivated")
            completion(.success)

            self.link.disconnect(force: true)
        }
    }

    func forceDeactivatePatch() {
        log.info("Force deactivating patch...")
        endPatchSession(deliveryStoppedAt: Date.now, statusIsCurrent: false)
    }

    /// The base rebooted underneath an activated patch: it came back as a blank, never activated
    /// patch and is not delivering anything. The session cannot be resumed, so it ends here.
    func handleBaseReset(deliveryStoppedAt: Date) {
        log.error("Pump base has reset, patch session is lost - delivery stopped at \(deliveryStoppedAt)")

        // A terminated patch has already raised its own alert, and was not delivering anyway
        let wasRunning = state.pumpState.isRunning

        // What the patch did last is as of the last status of it, before the base went down
        endPatchSession(deliveryStoppedAt: deliveryStoppedAt, statusIsCurrent: false)

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
            let sessionWasEnded = state.patchSessionEnded
            var events: [NewPumpEvent] = []
            if !sessionWasEnded {
                // The previous patch was replaced without deactivating it - it fell off, or was swapped outside the app.
                // When it stopped is unknown, so it is taken to have delivered until `start`: a temp basal or a bolus in
                // flight ends there - the bolus warned of as uncertain - and the schedule runs from there. No suspend: a
                // host can take one with a resume at the same time as never ending. Ended, the session finalized all of
                // this then: what is here since is the new patch's - sent after an activation whose answer was lost.
                log.warning("Previous patch session was not ended, ending its delivery at activation")
                releaseHeldForTheSessionEnd()
                events.append(contentsOf: finalizedTempBasal(endedAt: start))
                events.append(contentsOf: finalizeInterruptedBolus())
                events.append(contentsOf: finalizeAllAwaitingDoses(because: "a new patch was activated"))
                dropUnconfirmedTempBasal(because: "a new patch was activated")
            }

            events.append(NewPumpEvent.replacedPump(date: start))
            if isDelivering {
                // A resume in a later second than the suspend - see `earliestResume`
                let resumeStart = state.basalDose.type == .suspend ? max(start, Self.earliestResume(after: state.basalDose.startDate)) : start
                let resumeDose = UnfinalizedDose(resumeStartTime: resumeStart, insulinType: state.insulinType)
                if state.basalDose.type == .suspend {
                    // Only a suspend that was reported gets a resume: a host can take one without it as suspended before it
                    events.append(NewPumpEvent.resume(dose: resumeDose.toDoseEntry()))
                    state.basalDose = resumeDose
                    keepUntilStored(resumeDose)
                } else if !sessionWasEnded {
                    let basalDose = UnfinalizedDose(
                        basalRate: state.currentBaseBasalRate,
                        insulinType: state.insulinType,
                        startDate: start
                    )
                    events.append(NewPumpEvent.basal(dose: basalDose.toDoseEntry()))
                    state.basalDose = basalDose
                } else if state.basalDose.type != .tempBasal {
                    // Nothing to report: the first activation, or a status of the new patch showed it delivering already
                    state.basalDose = resumeDose
                    state.basalDoseIsPlaceholder = true
                }

                // What commands check: the old patch may have left it suspended or running a temp basal, and it would
                // stay so until the first status that shows the new patch's basal. A temp basal a status of the new patch
                // showed running, its activation's answer lost, stays.
                state.basalState = state.basalDose.type == .tempBasal ? .tempBasal : .active
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
            if !sessionWasEnded {
                // Every dose of the previous session is final: none left to settle what is not
                state.settleOrphanedUncertainDeliveries(at: now())
            }
            notifyStateDidChange()

            emitPumpEvents(events)
        }
    }

    /// The one place a patch session ends: deactivation, a forced deactivation, and a base reset. Its records are out
    /// of reach from here on, so everything still running or waiting on a record is finalized now, from our estimate.
    /// Delivery stopped at `deliveryStoppedAt`, unless it is known to have stopped already - `statusIsCurrent`: the
    /// patch's state as last reported is its state now.
    private func endPatchSession(deliveryStoppedAt: Date, statusIsCurrent: Bool, disconnect: Bool = true) {
        // From the finals until they are handed over - see `doseReportLock`
        doseReportLock.lock()
        defer { doseReportLock.unlock() }

        // Delivery cannot have stopped before the running dose began - nor at a resume's instant, see `earliestAfter`
        let stoppedAt = max(deliveryStoppedAt, Self.earliestAfter(state.basalDose))

        // Suspended already - by the patch halting, or by a suspend - its suspend was reported then, and stands while the
        // patch can't have resumed: in a state it never leaves, one it never delivered in or no longer does, or a current
        // one that shows it not delivering. Nothing more is reported then. Otherwise it may have resumed unseen - a
        // suspend ends on its own, out of range too - and the suspend is reported now.
        let hasStopped = state.basalDose.type == .suspend &&
            (state.pumpState.isTerminated || state.pumpState.isSetup || (statusIsCurrent && !state.pumpState.isDelivering))

        // A suspend held back for the records of the temp basal whose command went unanswered - out of reach now - goes
        // out with this batch, ahead of what it reports: never behind a suspend or a resume after it
        releaseHeldForTheSessionEnd()

        var events = finalizedTempBasal(endedAt: stoppedAt)
        events.append(contentsOf: finalizeInterruptedBolus())
        events.append(contentsOf: finalizeAllAwaitingDoses(because: "the patch session ended"))
        if !hasStopped {
            var suspendStart = stoppedAt
            if state.basalDose.type == .suspend {
                // Never over the open suspend: oref0 pairs each suspend with the first resume after it - the next
                // patch's for both - and zeroes the time from this one to it twice: IOB too low. That one is resumed
                // first, where the patch was last known suspended - its last status showing it so, else just after it
                // began - in a later second than it (`earliestResume`); what it delivered from there to this suspend
                // counted as scheduled, IOB overstated at most. Not at `lastSync`: a command's answer since - a basal
                // profile's - would date it past a resume unseen, and zero what the patch delivered from there. This
                // one in a later second still.
                let suspended = state.basalDose.startDate
                let knownSuspendedUntil = state.pumpState.isDelivering ? suspended :
                    min(state.lastShownNotDeliveringAt ?? suspended, stoppedAt)
                let resumeDose = UnfinalizedDose(
                    resumeStartTime: max(knownSuspendedUntil, Self.earliestResume(after: suspended)),
                    insulinType: state.insulinType
                )
                events.append(NewPumpEvent.resume(dose: resumeDose.toDoseEntry()))
                state.basalDose = resumeDose
                keepUntilStored(resumeDose)
                suspendStart = max(stoppedAt, Self.earliestResume(after: resumeDose.startDate))
            }
            let suspendDose = UnfinalizedDose(suspendStartTime: suspendStart)
            events.append(NewPumpEvent.suspend(dose: suspendDose.toDoseEntry()))
            state.basalDose = suspendDose
            keepUntilStored(suspendDose)
        }
        dropUnconfirmedTempBasal(because: "the patch session ended")

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
        // What commands check, until the next patch's session starts
        state.basalState = .suspended
        // Every dose of the session is final: none left to settle what is not
        state.settleOrphanedUncertainDeliveries(at: now())
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
        readTempBasalEndAfterBolus()
        readOpenTempBasalEndsAfterBolus()

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

            // Not `rawState`: that is the host's read
            self.oldState = MedtrumPumpState(rawValue: self.doseReportLock.withLock { self.state.rawValue })
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
            emitBolusEvents(events)
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

            raiseCancelledBolus(delivered: delivered, record: record)
            return false
        }

        if registeredSince, !completeBolus(delivered: delivered, receivedAt: receivedAt, receivedUptime: receivedUptime) {
            raiseCancelledBolus(delivered: delivered, record: record)
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
        raiseCancelledBolus(delivered: early.delivered, record: early.record)
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

    /// A completion notification with no bolus running to take it, naming `record` as the newest if it does: the
    /// patch's completion of the bolus a cancel just ended, with what it really delivered. Raises the amount the cancel
    /// kept, never lowers it. One whose command went unanswered is confirmed by it - counted as that, no longer in full -
    /// only if it is provably its: it names a record past every one known or claimed when it went out, no earlier bolus's
    /// answer claimed, and no other bolus is out to be its (`isCompletion`, for one not yet answered). Its warning of
    /// uncertain delivery stands; its record settles it.
    func raiseCancelledBolus(delivered: Double, record: Int? = nil) {
        doseReportLock.withLock {
            guard let cancelled = recentlyCancelledBolus() else {
                return
            }

            // Logged whatever it says, 0 U included: what the patch itself says the cancelled bolus delivered
            let ended = cancelled.snapshot
            let kept = ended.deliveredUnits
            let isItsOwn = ended.confirmation == .uncertain && state.pendingBolus == nil && record.map { record in
                record > ended.sequenceAtSend ?? .max && !state.answeredBolusRecords.contains(record)
            } == true
            let changed = isItsOwn ? cancelled.confirmAfterEnd(delivered: delivered) : cancelled.raiseAfterEnd(to: delivered)
            log.info(
                "Completion of \(delivered) U after the cancel of the bolus of \(cancelled.startDate), record " +
                    "\(ended.recordSequence.map { "#\($0)" } ?? "-"): " +
                    (cancelled.deliveredUnits > kept ? "raising its amount from \(kept) U" : "keeping its \(kept) U") +
                    (isItsOwn ? " - it names #\(record ?? 0), its own: its command unanswered, counted as that, not in " +
                        "full, until its record" : "")
            )
            guard changed else {
                return
            }
            // A temp basal's records being read: their batch carries it, waiting on its record
            emitPumpEvents([], unlessTempBasalEndPending: true)
        }
    }

    /// The completion the patch sends after a cancel comes within a second or so
    private static let cancelledBolusCompletionWindow: TimeInterval = .minutes(2)

    /// A full status received at `receivedAt` that shows no bolus delivering - its bolus field the last one's, completed,
    /// having delivered `delivered` - and names `newestRecord` the newest record written. Past the record the answer to
    /// the running bolus gave it, the patch wrote that record: the bolus is over, and the last one completed is it. Its
    /// completion notification was lost - the link dropped: it ends here, at that amount, how it ended unseen, rather
    /// than at its deadline, refusing commands until then. Its record, read by the sync, finalizes it. Only for a bolus
    /// with that number: the bolus field carries none of its own, and repeats the last bolus's for hours. Returns whether
    /// it ended it.
    @discardableResult func completeBolusByItsRecord(
        delivered: Double,
        newestRecord: Int,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> Bool {
        let completed = doseReportLock.withLock { () -> Bool in
            guard let doseEntry = state.bolusDose else {
                return false
            }

            let running = doseEntry.snapshot
            guard !running.isFinished, let recordSequence = running.recordSequence, newestRecord >= recordSequence,
                  !Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime)
            else {
                return false
            }

            guard delivered <= doseEntry.value + Self.bolusCompletionTolerance else {
                log.warning(
                    "A full status names record #\(newestRecord), past the bolus of \(doseEntry.startDate)'s #\(recordSequence), " +
                        "and a bolus of \(delivered) U completed - more than it was for: left to its deadline"
                )
                return false
            }

            log.warning(
                "A full status names record #\(newestRecord): the bolus of \(doseEntry.startDate), #\(recordSequence), is " +
                    "over, its completion not seen - \(delivered) U, as the status says, until its record"
            )
            var events = runningTempBasal()
            events.append(contentsOf: awaitRecord(doseEntry, .completed, deliveredUnits: delivered, endedAt: nil))
            state.bolusDose = nil
            state.lastSync = Date.now
            emitBolusEvents(events)
            return true
        }

        if completed {
            notifyStateDidChange()
        }
        return completed
    }

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
            noteUncertainDelivery(.bolus, .endNotSeen, of: doseEntry)
            state.bolusDose = nil
            state.lastSync = Date.now
            emitBolusEvents(events)
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
            // Ended by a halt whose status named no record: a full status names it - asked for now, not left to the
            // freshness interval, its records read as it comes in (`namesRecordOfTempBasalEnd`). Not with a bolus
            // running: its end comes first.
            guard ending.awaitsRecord, state.bolusState == .noBolus else {
                log.debug("Skipping sync, the records of the temp basal of \(ending.dose.startDate) are being read")
                return nil
            }
            log.info("Asking for a full status: it names the record of the temp basal of \(ending.dose.startDate) that ended")
            return .full
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
    /// it went out - its deadline and the window its record is looked for in count from then. Or it never went out: the
    /// host took the state too late for it to be written, and the app was gone before it took the next (`handOverState`)
    /// - the same state on disk. Its records tell: none its, it is final at 0 U (`unansweredBolusNeverRan`); if they
    /// can't, counted in full - never less than may have been delivered. Not if its dose was
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
                    noteUncertainDelivery(.bolus, .appRestarted, of: dose)
                    log.error(
                        "The app stopped while the bolus of \(pending.units) U sent at \(pending.sentAt) awaited its " +
                            "answer, or before the host took the state for it to be written: it may be delivering. Counted " +
                            "in full until the patch shows it, or its record says otherwise - not sent again"
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
            // A temp basal restored waiting on its read (`takeOverTempBasalEndFromLastRun`) goes out with it from our
            // estimate, unread: with this bolus running, its records are not read before it is over (`RecordSyncer
            // .wouldRead`) - and the host is to be warned of the bolus now, needing no link
            if state.bolusDose === dose, !running.isFinished {
                emitPumpEvents([NewPumpEvent.bolus(dose: dose.doseEntry(of: running, isMutable: true))], replacePendingEvents: false)
            }
            // The app gone before it was noted, or by a build that did not note it
            noteUncertainDelivery(.bolus, .unanswered, of: dose)
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
        guard doseEntry.finish(.interrupted, endedAt: nil, at: now()) else {
            return []
        }
        noteUncertainDelivery(.bolus, .patchDeactivated, of: doseEntry)
        guard let event = finalize(doseEntry, deliveredUnits: nil, .byEstimate) else {
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
    /// `waits`: counted as waiting meanwhile (`lockCommandLock`) - not the read of a temp basal's end, which the
    /// operation ahead of it may be doing itself.
    @discardableResult internal func withCommandLock(waits: Bool = true, _ body: () -> Void) -> Bool {
        guard lockCommandLock(waits: waits) else {
            return false
        }
        defer { commandLock.unlock() }

        body()
        return true
    }

    /// Takes `commandLock` as `withCommandLock` does - the caller unlocks it - for the commands that do not go through
    /// `ensureConnectedAndActive`: priming, activating and stopping a patch
    private func lockCommandLock(waits: Bool = true) -> Bool {
        // Waiting: the records a temp basal's end has read meanwhile take no longer than with a command waiting
        let lock = { self.commandLock.lock(before: Date.now.addingTimeInterval(Self.commandActivityTimeout)) }
        guard waits ? whileTheLoopWaits(lock) : lock() else {
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
        lastCommandEndedAt.value = now()
    }

    /// A command ended within `openTempBasalEndReadDelay` of `checkedAt`: the loop's bolus right behind it has the link
    /// first. A wall clock set back since - the age negative - holds nothing off.
    private func isRightAfterACommand(at checkedAt: Date) -> Bool {
        let age = checkedAt.timeIntervalSince(lastCommandEndedAt.value)
        return age >= 0 && age < openTempBasalEndReadDelay
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

        return openTempBasalEndsFromEstimate(because: "the patch session ended") +
            (estimateFinal(dose, because: "the patch session ended").map { [$0] } ?? [])
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

        return openTempBasalEndsFromEstimate(because: reason) + (estimateFinal(dose, because: reason).map { [$0] } ?? [])
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

    /// `events`, a bolus's end - with the temp basal running, if any - handed to the host: with a temp basal's records
    /// read as it ended (`TempBasalEnd`), in the batch that read ends with, after what followed it, rather than taking
    /// it out from our estimate now. Its records are read once no bolus runs (`RecordSyncer.wouldRead`): this one over,
    /// nothing holds them up any longer - the halt and the completion in one status (device 2026-10-22 20:18:59), a
    /// cancel of the bolus, a full status that ends it. Loop's watermark goes by basal doses only (`LoopWatermark`):
    /// the bolus waits no longer than the read, and nothing is lost meanwhile - it waits on its record, and every
    /// replacing batch carries it. Only under `doseReportLock`.
    private func emitBolusEvents(_ events: [NewPumpEvent]) {
        guard let ending = pendingTempBasalEndStorage else {
            emitPumpEvents(events)
            return
        }
        log.info("Reporting the bolus with the temp basal of \(ending.dose.startDate), once its records are read")
        // Finals only, the same every time. A mutable report held would be stale by then - the patch's completion after
        // a cancel raises the bolus meanwhile - and win over the dose as it is: the batch the read ends with replaces
        // pending events, every dose still in flight in it from what it is then.
        ending.bolusReports += events.filter { $0.dose?.isMutable == false }
    }

    /// Hands `events` to the host, with every final it has yet to confirm and - with `replacePendingEvents` - every dose
    /// still mutable: the host drops every mutable dose it holds that a replacing batch leaves out.
    ///
    /// Every batch has the state saved first, in the same delegate call: otherwise the host could store it and the app
    /// be killed before the state is saved - a final would come back unfinalized, and a dose the host holds mutable
    /// would be unknown to the restored state and purged by its next replacing batch.
    ///
    /// A temp basal goes out mutable once it ended only as one ended open, the next one starting where it ended (see
    /// `openTempBasalEnds`): the host moves past one as soon as anything immutable after it is stored, and its final would
    /// be lost. One whose records are being read as it ends goes out final from our estimate, with what followed it, and
    /// every one ended open before it - see `TempBasalEnd`. So does one waiting on its record in state saved as such a
    /// read went on that is not read again (`takeOverTempBasalEndFromLastRun`), or by an earlier build, with those ended
    /// open before it.
    ///
    /// `unlessTempBasalEndPending`: a batch with no events of its own - a full status's, a resend of finals, a raised
    /// cancelled bolus - is not handed over at all while such records are read. The batch the read ends with replaces
    /// pending events, carrying every final and every dose still in flight, and the temp basal final from its records
    /// rather than from our estimate. Temp basals ended open hold up nothing: a batch carries them mutable. Nor does a
    /// bolus's end go out ahead of that read - see `emitBolusEvents`.
    func emitPumpEvents(_ events: [NewPumpEvent], replacePendingEvents: Bool = true, unlessTempBasalEndPending: Bool = false) {
        // The batch is built off `awaitingRecord` and handed to the delegate queue in one go - see `doseReportLock`
        doseReportLock.lock()
        defer { doseReportLock.unlock() }

        if unlessTempBasalEndPending, events.isEmpty, let ending = pendingTempBasalEndStorage {
            log.debug("Not reporting a refresh while the records of the temp basal of \(ending.dose.startDate) are read")
            return
        }

        // Temp basals ended open that their rules settle now - read past, past `openTempBasalEndMaximumWait` - go final
        // with any batch, not only a record sync's
        var events = settleOpenTempBasalEnds() + events
        if let ending = pendingTempBasalEndStorage {
            pendingTempBasalEndStorage = nil
            // Those ended open before it first - see `finalize`
            let reason = "a batch went out before its records were read"
            let finals = openTempBasalEndsFromEstimate(because: reason) + [estimateFinal(ending.dose, because: reason)].compactMap { $0 }
            events = finals + ending.then + ending.bolusReports + events
        }
        // Waiting on its record, none of the above, nor ended open: saved as its records were read and not to be read
        // again - see `takeOverTempBasalEndFromLastRun` - or by an earlier build
        var fromLastRun: [NewPumpEvent] = []
        let unread = state.awaitingRecord.filter { dose in
            let snapshot = dose.snapshot
            return dose.type == .tempBasal && !snapshot.isFinalized && !snapshot.endedOpen
        }.sorted { $0.startDate < $1.startDate }
        for dose in unread {
            if let final = estimateFinal(dose, because: "it was saved waiting on its record") {
                fromLastRun.append(final)
            }
        }
        // What followed a temp basal whose records were being read, the host yet to confirm storing it - in this batch
        // with that temp basal's final, if it carried it out just now; else held back as the run before ended, or by a
        // batch the host could not store: after that final - which goes out again with it, until the host confirms
        // both. Its final went out first: no batch goes out while those records are read without carrying it. So too
        // every suspend and resume reported, until the host confirms storing it (`keepUntilStored`): ahead of what this
        // batch reports, in the order they came.
        dropExpiredFinals()
        // Not the suspend held back until the records of the temp basal whose command went unanswered are read
        let held = keptBasalDoses
        let inThisBatch = Set(events.map(\.raw))
        let heldBefore = held.compactMap { dose in Self.heldEvent(of: dose).map { (dose: dose, event: $0) } }
            .filter { !inThisBatch.contains($0.event.raw) }
        // Again as the batch that carried it awaits its answer, as a matter of course; again after one the host could not
        // store, or from the run before - worth a warning
        let resent = heldBefore.filter { held in !heldInFlight.contains { $0 === held.dose } }
        let describe = { (held: [(dose: UnfinalizedDose, event: NewPumpEvent)]) in
            held.map { "\($0.event.title) at \($0.event.date)" }.joined(separator: ", ")
        }
        if !resent.isEmpty {
            log.warning("Reporting again what the host has yet to confirm storing: \(describe(resent))")
        } else if !heldBefore.isEmpty {
            log.debug("Reporting with this batch what the host has yet to confirm storing: \(describe(heldBefore))")
        }
        heldInFlight += held.filter { dose in !heldInFlight.contains { $0 === dose } }
        events = fromLastRun + heldBefore.map(\.event) + events
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

        if !finals.isEmpty || !held.isEmpty {
            lastFinalsSentAt = Date.now
        }

        recordStore.store(emitted: events.compactMap(EmittedDose.init))

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                // The finals stay, and go out with the next batch
                self.log.warning("No pump delegate, not notifying...")
                self.notInFlight(held)
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
                    self.notInFlight(held)
                    return
                }

                // Stored: what the host does with it moves Loop's watermark
                self.doseReportLock.withLock {
                    self.loopWatermarkModel.store(events, replacePendingEvents: replacePendingEvents)
                    self.state.loopWatermark = self.loopWatermarkModel.date
                }
                self.acknowledgeHeld(held)
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

    /// A status received before the command of the dose it is checked against went out - was written, past the wait
    /// for the host (`UnfinalizedDose.State.writtenAt`) - says nothing of that dose: the monotonic clock where both are
    /// known (one run of the app), the wall clock otherwise
    internal static func statusPredatesCommand(
        of dose: UnfinalizedDose.State,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> Bool {
        if let sentUptime = dose.writtenUptime ?? dose.sentUptime {
            return receivedUptime < sentUptime
        }
        if let sentAt = dose.writtenAt ?? dose.sentAt {
            return receivedAt < sentAt
        }
        return false
    }

    /// A time on the patch clock as ours - by the skew of the last reading - bounded to `[notBefore, notAfter]`
    /// Where `dose`, running, ended, the patch saying it ended at `patchTime` on its clock: from its start, as long as the
    /// patch ran it from its patch start - skew-free - where that is its first segment; through the skew otherwise. No
    /// later than `notAfter`, no earlier than its start.
    internal func endOnOurClock(of dose: UnfinalizedDose, patchTime: Date, notAfter: Date) -> Date {
        let running = dose.snapshot
        guard dose.type == .tempBasal, let pumpStartTime = running.pumpStartTime, !running.firstSegmentUncertain else {
            return patchTimeOnOurClock(patchTime, notBefore: dose.startDate, notAfter: notAfter)
        }
        let ended = dose.startDate.addingTimeInterval(max(0, patchTime.timeIntervalSince(pumpStartTime)))
        return max(min(ended, notAfter), dose.startDate)
    }

    /// Where the patch, suspending at `patchTime`, ended `dose`, the running basal, on our clock: a temp basal as
    /// `endOnOurClock` tells it. Another kind - the schedule - from the anchor the temp basal whose command went
    /// unanswered, kept, is dated by (`basalBefore`, `basalBeforeOnPatch`), so that the two agree to the second; else
    /// from its own patch start, paired with its start; through the skew otherwise. Between its start and `notAfter` -
    /// strictly after a resume: at its instant, Loop orders the two either way, and may close this suspend with it.
    internal func suspendOnOurClock(of dose: UnfinalizedDose, patchTime: Date, notAfter: Date) -> Date {
        guard dose.type != .tempBasal else {
            return endOnOurClock(of: dose, patchTime: patchTime, notAfter: notAfter)
        }
        let earliest = Self.earliestAfter(dose)
        let unconfirmed = state.unconfirmedTempBasal?.snapshot
        let anchor: (ours: Date, patch: Date)?
        if let basalBefore = unconfirmed?.basalBefore, let onPatch = unconfirmed?.basalBeforeOnPatch {
            anchor = (basalBefore, onPatch)
        } else if let pumpStartTime = dose.snapshot.pumpStartTime {
            anchor = (dose.startDate, pumpStartTime)
        } else {
            anchor = nil
        }
        guard let anchor else {
            return patchTimeOnOurClock(patchTime, notBefore: earliest, notAfter: notAfter)
        }
        let suspended = anchor.ours.addingTimeInterval(patchTime.timeIntervalSince(anchor.patch))
        return max(min(suspended, notAfter), earliest)
    }

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

    /// The settings screen keeps this many of them, the oldest settled going first
    static let uncertainDeliveriesKept = 20

    /// `dose` became uncertain, as `kind` - for the settings screen, see `UncertainDelivery`. Once per dose and kind: the
    /// first cause stays. Only under `doseReportLock`.
    internal func noteUncertainDelivery(_ kind: UncertainDelivery.Kind, _ cause: UncertainDelivery.Cause, of dose: UnfinalizedDose) {
        // Final, nothing would settle it
        guard !dose.isFinalized else {
            return
        }

        let key = UncertainDelivery.DoseKey(dose)
        let delivery = UncertainDelivery(
            kind: kind,
            cause: cause,
            sentAt: key.sentAt,
            amount: dose.value,
            duration: dose.type == .tempBasal ? dose.estimatedEndDate.timeIntervalSince(dose.startDate) : nil,
            notedAt: now()
        )
        state.mutateUncertainDeliveries { deliveries in
            guard !deliveries.contains(where: { $0.kind == kind && $0.isOf(key) && !$0.isSettled }) else {
                return
            }
            deliveries.append(delivery)
            while deliveries.count > Self.uncertainDeliveriesKept {
                deliveries.remove(at: deliveries.firstIndex(where: \.isSettled) ?? 0)
            }
        }
    }

    /// The uncertain deliveries of `dose` not settled yet are, as `outcome` - with its final, if it has one. Only under
    /// `doseReportLock`.
    private func settleUncertainDeliveries(of dose: UnfinalizedDose, _ outcome: UncertainDelivery.Outcome) {
        let key = UncertainDelivery.DoseKey(dose)
        let final = dose.snapshot
        let settledAt = now()
        state.mutateUncertainDeliveries { deliveries in
            for index in deliveries.indices where !deliveries[index].isSettled && deliveries[index].isOf(key) {
                deliveries[index].outcome = outcome
                deliveries[index].settledAt = settledAt
                switch outcome {
                case .byRecord, .byEstimate:
                    deliveries[index].delivered = final.finalDeliveredUnits
                    deliveries[index].record = outcome == .byRecord && dose.type == .bolus ? final.recordSequence : nil
                case .neverRan:
                    deliveries[index].delivered = 0
                case .notConfirmed, .final, .untracked, .notCounted:
                    break
                }
            }
        }
    }

    /// The user is done with the settled ones
    public func clearSettledUncertainDeliveries() {
        doseReportLock.withLock {
            state.mutateUncertainDeliveries { $0.removeAll(where: \.isSettled) }
        }
        notifyStateDidChange()
    }

    /// Fixes the final report of `dose` - once: nil if it has one already - and keeps it in `awaitingRecord`, to go out
    /// with every batch until the host confirms storing it. Only under `doseReportLock`; the caller hands the final
    /// over before letting go of it. `deliveredUnits`: the record's amount, or nil for our own estimate. `outcome`: how,
    /// for the uncertain deliveries of it.
    private func finalize(
        _ dose: UnfinalizedDose,
        deliveredUnits: Double?,
        endDate: Date? = nil,
        _ outcome: UncertainDelivery.Outcome
    ) -> NewPumpEvent? {
        // Basal doses go final in order: a temp basal ended open before this one goes final first, from our estimate if
        // nothing settled it yet - its final goes out with this one's, as every final the host has yet to confirm
        if dose.type == .tempBasal, !dose.isFinalized {
            for earlier in openTempBasalEnds where earlier !== dose && earlier.startDate < dose.startDate {
                estimateFinal(earlier, because: "the temp basal of \(dose.startDate) after it goes final")
            }
        }

        guard dose.finalize(deliveredUnits: deliveredUnits, endDate: endDate, at: now()) else {
            log.warning("The \(dose.type.rawValue) of \(dose.startDate) is finalized already, not reporting it again")
            return nil
        }

        settleUncertainDeliveries(of: dose, outcome)

        if dose.type == .bolus {
            let final = dose.snapshot
            let taken = settlePossibleBolusRecords(after: dose, outcome)
            // Its record may come after all, matching no dose then: it is this one's. Kept with a possible record taken
            // for its own all the same, with it: that one may have been another bolus's, at its amount - its own still to
            // come, telling of it (`explain`).
            if outcome == .byEstimate, let sentAt = final.sentAt {
                state.bolusesFinalWithoutRecord = Array(
                    (state.bolusesFinalWithoutRecord + [
                        BolusFinalWithoutRecord(
                            units: dose.value,
                            delivered: final.finalDeliveredUnits ?? dose.value,
                            sentAt: sentAt,
                            pumpStartTime: final.pumpStartTime,
                            recordSequence: final.recordSequence,
                            taken: taken
                        )
                    ]).suffix(Self.bolusesFinalWithoutRecordKept)
                )
            }
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

    /// Finalizes `dose`, a bolus, and hands the final to the host at once - behind the records of a temp basal read as it
    /// ended, if any are, as a bolus's end (`emitBolusEvents`): one read on a record sync as a status ends it, say. Only
    /// under `doseReportLock`.
    private func emitFinal(_ dose: UnfinalizedDose, deliveredUnits: Double, endDate: Date? = nil) {
        guard let event = finalize(dose, deliveredUnits: deliveredUnits, endDate: endDate, .byRecord) else {
            return
        }
        emitBolusEvents([event])
    }

    /// Applies one record read off the patch: finalizes the bolus waiting on it, if any - by the number its command's
    /// answer gave it, or one whose answer was lost by when its command went out - or the temp basal whose command went
    /// unanswered it shows ran. A temp basal of ours that ended back to back is finalized by its records
    /// (`openTempBasalEnds`); any other was finalized as it ended (`TempBasalEnd`). Only finalizes: the identity of a dose
    /// never moves. Returns what it did, for the record screen.
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
                    // Final from our estimate, its record unread till now: what it delivered may not be what the host has
                    if let index = state.bolusesFinalWithoutRecord.firstIndex(where: { $0.recordSequence == response.sequence }) {
                        let final = state.bolusesFinalWithoutRecord.remove(at: index)
                        log.info(
                            "Record \(response.sequence) is that of the bolus of \(final.units) U sent at \(final.sentAt), final " +
                                "from our estimate already"
                        )
                        explain(response.sequence, delivered: record.normalDelivered, from: record.startTime, by: final)
                    } else {
                        log.info("Record \(response.sequence) is that of a bolus of ours finalized already, matching nothing")
                    }
                    return "answered bolus finalized already"
                } else if let shifted = waiting.first(where: { isRecordPastItsTakenNumber(record, response.sequence, of: $0) }) {
                    // Its answered start to the second: no other bolus starts there. One whose answer was lost that it
                    // could be the record of has it noted as a possible one (above) - counted in full until its own.
                    if let other = waiting.first(where: { $0 !== shifted && couldBeOf($0, true) }) {
                        log.warning(
                            "Record \(response.sequence) could also be that of the bolus of \(other.startDate) whose answer " +
                                "was lost: taken for the bolus of \(shifted.startDate), whose answered start it has"
                        )
                    }
                    log.info(
                        "Record \(response.sequence) is that of the bolus of \(shifted.startDate), the record its answer named " +
                            "#\(shifted.recordSequence ?? 0) one of another kind: at its answered start, of its amount"
                    )
                    // Claimed as an answered number is: never taken for another bolus, read again
                    noteAnsweredBolusRecord(response.sequence)
                    dose = shifted
                } else if let unanswered = waiting.first(where: { couldBeOf($0, true) }) {
                    // Claimed as an answered number is: read again, it is no other bolus's, nor one the host is missing
                    noteAnsweredBolusRecord(response.sequence)
                    dose = unanswered
                } else {
                    log.info(
                        "Record \(response.sequence): bolus of \(record.normalAmount) U at \(record.startTime) " +
                            "matches no dose of ours, not imported"
                    )
                    // Ours by its amount, should the patch clock be further off than we think - one whose answer was
                    // lost, its progress or completion seen since included: its record is looked for all the same
                    var possiblyOurs = false
                    for dose in bolusesWithoutTheirAnsweredRecord where couldBeOf(dose, false) {
                        if dose.snapshot.confirmation == .uncertain {
                            dose.notePossibleRecord(response.sequence)
                        }
                        possiblyOurs = true
                    }
                    warnOfBolusNotCounted(record, response.sequence, possiblyOurs: possiblyOurs)
                    return "unmatched"
                }

                // Kept as possibly that of a bolus whose answer was lost, read again now that it is near enough to be its:
                // settled here - not told of as no bolus of ours as the bolus goes final
                state.possibleBolusRecords.removeAll { $0.sequence == response.sequence }

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
                // A part of a temp basal of ours that ended back to back, mutable until its records are read
                if let outcome = keepPartOfOpenTempBasal(record, response: response) {
                    return outcome
                }

                // Any other temp basal of ours is final from its end on - from its records, read as it ended, or our
                // estimate: read again, or later, its record changes nothing
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

                if let finalized = finalizeUnconfirmedTempBasal(from: record, sequence: response.sequence) {
                    emitPumpEvents(finalized.events)
                    return finalized.outcome
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

    /// Bolus `record`, numbered `sequence`, of this patch, matches no dose of ours: not imported - it may be one the host
    /// has after all, which would count twice - but what it delivered may be missing at the host for good. A bolus
    /// written as the app was killed before the host saved it pending, say, or another app's. Looked at once per record
    /// (`MedtrumPumpState.unmatchedBolusRecords`) - not if written before this state took up the patch
    /// (`sessionStartSequence`). One a bolus of ours whose answer was lost could be (`possiblyOurs`), waiting on its
    /// record, is kept until that one settles (`settlePossibleBolusRecords`); any other is told of now
    /// (`tellOfBolusRecord`). Only under `doseReportLock`.
    private func warnOfBolusNotCounted(_ record: BolusRecord, _ sequence: Int, possiblyOurs: Bool) {
        guard !state.unmatchedBolusRecords.contains(sequence) else {
            return
        }
        guard sequence > state.sessionStartSequence else {
            log.info("Record \(sequence) was written before the patch was taken up, at #\(state.sessionStartSequence): not told of")
            return
        }
        state.unmatchedBolusRecords = Array((state.unmatchedBolusRecords + [sequence]).suffix(Self.unmatchedBolusRecordsKept))

        let unmatched = PossibleBolusRecord(
            sequence: sequence,
            amount: record.normalAmount,
            delivered: record.normalDelivered,
            startTime: record.startTime
        )
        guard !possiblyOurs else {
            log.info(
                "Record \(sequence) could be that of a bolus of ours whose answer was lost, waiting on its record: " +
                    "looked at again as it settles"
            )
            state.possibleBolusRecords = Array((state.possibleBolusRecords + [unmatched]).suffix(Self.unmatchedBolusRecordsKept))
            return
        }
        tellOfBolusRecord(unmatched)
    }

    /// `unmatched`, a bolus record no dose of ours waits on, nor could: the record of a bolus of ours that went final
    /// from our estimate (`bolusesFinalWithoutRecord`) - by the number its answer named; else at its amount, delivering
    /// no more, starting where its answer said, or near when it went out, its answer lost (`recordMatchWindow`, as for
    /// any) - what it delivered compared with what the host has (`explain`), each entry explaining one record. Any
    /// other is a bolus the host is missing: the user is told to add it, unless it delivered nothing
    /// (`tellOfBolusNotCounted`). Only under `doseReportLock`.
    private func tellOfBolusRecord(_ unmatched: PossibleBolusRecord) {
        let skew = state.patchClockSkew
        if let index = state.bolusesFinalWithoutRecord.firstIndex(where: { final in
            if let recordSequence = final.recordSequence, recordSequence == unmatched.sequence {
                return true
            }
            guard RecordSyncer.steps(unmatched.amount) == RecordSyncer.steps(final.units),
                  RecordSyncer.steps(unmatched.delivered) <= RecordSyncer.steps(final.units)
            else {
                return false
            }
            if let pumpStartTime = final.pumpStartTime {
                return abs(unmatched.startTime.timeIntervalSince(pumpStartTime)) <= RecordSyncer.bolusStartTolerance
            }
            return abs(unmatched.startTime.timeIntervalSince(final.sentAt.addingTimeInterval(skew))) <= Self.recordMatchWindow
        }) {
            let final = state.bolusesFinalWithoutRecord.remove(at: index)
            log.info(
                "Record \(unmatched.sequence) is that of the bolus of \(final.units) U sent at \(final.sentAt), final from our " +
                    "estimate already"
            )
            explain(unmatched.sequence, delivered: unmatched.delivered, from: unmatched.startTime, by: final)
            return
        }

        tellOfBolusNotCounted(unmatched)
    }

    /// Record `sequence`, starting at `startTime` on the patch clock, delivered `delivered`, is that of the bolus of
    /// `final`, final from our estimate: compared with what the host has (`compare`). A possible record taken for its own
    /// as it went final (`BolusFinalWithoutRecord.taken`) was another bolus's, then - one the host is missing: told of,
    /// not looked up against these again (`tellOfBolusNotCounted`), once - the entry explains one record. Its own
    /// delivering what the taken one did, it was compared as that one was taken: nothing more. Only under
    /// `doseReportLock`.
    private func explain(_ sequence: Int, delivered: Double, from startTime: Date, by final: BolusFinalWithoutRecord) {
        if let taken = final.taken, RecordSyncer.steps(taken.delivered) == RecordSyncer.steps(delivered) {
            log.info(
                "Record \(sequence): \(delivered) U delivered, as record \(taken.sequence) taken for it - compared as that one " +
                    "was taken"
            )
        } else {
            compare(final.delivered, withItsRecord: delivered, from: startTime, sequence)
        }
        guard let taken = final.taken else {
            return
        }
        log.warning(
            "Record \(taken.sequence), taken for that of the bolus sent at \(final.sentAt) as it went final, is another " +
                "bolus's: its own is \(sequence)"
        )
        tellOfBolusNotCounted(taken)
    }

    /// `unmatched`, a bolus record, is a bolus the host is missing: the user is told to add it, unless it delivered
    /// nothing. Only under `doseReportLock`.
    private func tellOfBolusNotCounted(_ unmatched: PossibleBolusRecord) {
        let skew = state.patchClockSkew
        guard RecordSyncer.steps(unmatched.delivered) > 0 else {
            log.info("Record \(unmatched.sequence) delivered nothing: not told of")
            return
        }
        let startedAt = unmatched.startTime.addingTimeInterval(-skew)
        log.warning(
            "Record \(unmatched.sequence): a bolus of \(unmatched.delivered) U delivered from \(startedAt) that the host has " +
                "no dose of - the user is told to add it"
        )
        emitAlert(alertType: .bolusNotCounted(units: unmatched.delivered, at: startedAt))
    }

    /// A bolus of ours final from our estimate, `counted` - what the host has - and its record, numbered `sequence`,
    /// starting at `startTime` on the patch clock, read after all: delivered `delivered`. Further apart than a step -
    /// the progress last reported rounds - the host has it wrong for good, its final fixed: the user is told - to add
    /// what is missing, or that insulin on board is overstated. Only under `doseReportLock`.
    private func compare(_ counted: Double, withItsRecord delivered: Double, from startTime: Date, _ sequence: Int) {
        let apart = RecordSyncer.steps(delivered) - RecordSyncer.steps(counted)
        guard abs(apart) > 1 else {
            log.info("Record \(sequence): \(delivered) U delivered, \(counted) U counted - not told of")
            return
        }
        let startedAt = startTime.addingTimeInterval(-state.patchClockSkew)
        log.warning(
            "Record \(sequence): the bolus of \(startedAt) delivered \(delivered) U, the host has \(counted) U from our " +
                "estimate - " + (apart > 0 ? "the user is told to add the rest" : "insulin on board overstated, the user is told")
        )
        emitAlert(alertType: .bolusMiscounted(counted: counted, delivered: delivered, at: startedAt))
    }

    /// `dose`, a bolus, went final - `outcome`. The bolus records kept as possibly those of one whose answer was lost
    /// (`MedtrumPumpState.possibleBolusRecords`): one that could be `dose`'s, final from our estimate, is taken for its
    /// record, what it delivered compared with what the host has (`compare`) - read again, nothing more is done - and
    /// returned, kept with `dose`'s entry (`BolusFinalWithoutRecord.taken`). Any other that no bolus still waiting on its
    /// record could be is told of now (`tellOfBolusRecord`) - `dose` final from its own record, or never run. Only under
    /// `doseReportLock`.
    private func settlePossibleBolusRecords(
        after dose: UnfinalizedDose,
        _ outcome: UncertainDelivery.Outcome
    ) -> PossibleBolusRecord? {
        guard !state.possibleBolusRecords.isEmpty else {
            return nil
        }
        // Its answer lost - unanswered, or confirmed since by its progress or completion: no record named
        let couldBe = { (possible: PossibleBolusRecord, dose: UnfinalizedDose) -> Bool in
            let snapshot = dose.snapshot
            return dose.type == .bolus && snapshot.recordSequence == nil &&
                possible.sequence > snapshot.sequenceAtSend ?? 0 &&
                RecordSyncer.steps(possible.amount) == RecordSyncer.steps(dose.value)
        }

        let final = dose.snapshot
        var taken: PossibleBolusRecord?
        var kept: [PossibleBolusRecord] = []
        for possible in state.possibleBolusRecords {
            if taken == nil, outcome == .byEstimate, couldBe(possible, dose) {
                taken = possible
                log.info(
                    "Record \(possible.sequence), possibly that of the bolus of \(dose.startDate) whose answer was lost, " +
                        "final from our estimate: taken for its record"
                )
                compare(final.finalDeliveredUnits ?? dose.value, withItsRecord: possible.delivered, from: possible.startTime, possible.sequence)
            } else if bolusesWithoutTheirAnsweredRecord.contains(where: { $0 !== dose && couldBe(possible, $0) }) {
                kept.append(possible)
            } else {
                log.info("Record \(possible.sequence) is no bolus of ours that waits on its record after all")
                tellOfBolusRecord(possible)
            }
        }
        state.possibleBolusRecords = kept
        return taken
    }

    /// The latest boluses final from our estimate kept for their record, and the unmatched bolus records looked at: a
    /// patch session's worth, and some
    private static let bolusesFinalWithoutRecordKept = 50
    private static let unmatchedBolusRecordsKept = 50

    /// Record `response`, of another kind than a bolus's, came back at the number the answer to a bolus of ours named:
    /// the patch wrote it as the bolus ran - an alarm, say (device 2026-10-22 13:52, #1606 a low-reservoir alarm, the
    /// bolus #1607) - and the bolus's own comes after it. Kept with the bolus - see `UnfinalizedDose.State
    /// .answeredRecordTaken` - the two may be read in different runs. For every record read, whatever takes it - the
    /// temp basal it settles, as it ends, takes it before `reconcile` would (`RecordSyncer.apply`). Unreadable records
    /// never get here (`RecordSyncer.readOnce`): one that is the bolus's own, unparsed, does not make it taken.
    internal func noteAnsweredBolusRecordTaken(by response: GetRecordResponse) {
        switch response.record {
        case .basal,
             .tdd,
             .unhandled:
            break
        case .bolus,
             .invalid,
             .truncated:
            return
        }
        doseReportLock.withLock {
            for dose in state.awaitingRecord + [state.bolusDose].compactMap({ $0 })
                where dose.type == .bolus && dose.recordSequence == response.sequence
            {
                guard dose.noteAnsweredRecordTaken() else {
                    continue
                }
                log.warning(
                    "Record \(response.sequence), the one the answer to the bolus of \(dose.startDate) named, is no bolus " +
                        "record: the bolus's own is numbered after it, matched by its answered start"
                )
            }
        }
    }

    /// Whether bolus `record`, numbered `sequence`, is that of `dose`, whose answered number came back as a record of
    /// another kind (`noteAnsweredBolusRecordTaken`): numbered past it, starting on its answered patch start, for its
    /// amount, delivering no more. Unclaimed - the caller checks. Only under `doseReportLock`.
    private func isRecordPastItsTakenNumber(_ record: BolusRecord, _ sequence: Int, of dose: UnfinalizedDose) -> Bool {
        let snapshot = dose.snapshot
        guard snapshot.answeredRecordTaken, let answered = snapshot.recordSequence, sequence > answered,
              let answeredStart = snapshot.pumpStartTime
        else {
            return false
        }
        return abs(record.startTime.timeIntervalSince(answeredStart)) <= RecordSyncer.bolusStartTolerance &&
            RecordSyncer.steps(record.normalAmount) == RecordSyncer.steps(dose.value) &&
            RecordSyncer.steps(record.normalDelivered) <= RecordSyncer.steps(dose.value)
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
                    if let shownFrom = pending.snapshot.shownRunningFrom {
                        dropUnconfirmedTempBasalShownRunning(pending, from: shownFrom)
                    } else {
                        dropUnconfirmedTempBasal(
                            because: "no status showed it running and \(RecordSyncer.FallbackRule.noRecord.description) at the latest",
                            neverRan: true
                        )
                    }
                    settled += 1
                }
            }

            // Ended open: the oldest first, as their own rules say
            let open = settleOpenTempBasalEnds()

            // Not the temp basal whose records are read as it ended: its read is bounded on its own - see `TempBasalEnd`
            let reading = pendingTempBasalEndStorage?.dose
            let overdue = state.awaitingRecord.compactMap { dose -> (dose: UnfinalizedDose, rule: RecordSyncer.FallbackRule)? in
                let snapshot = dose.snapshot
                guard !snapshot.isFinalized, !snapshot.endedOpen, dose !== reading, let finishedAt = snapshot.finishedAt,
                      let rule = RecordSyncer.fallbackRule(since: finishedAt, caughtUp: isCaughtUp(after: finishedAt), now: checkedAt)
                else {
                    return nil
                }
                return (dose, rule)
            }

            guard !overdue.isEmpty || !open.isEmpty else {
                return settled
            }

            let events = open + finalizeFromEstimate(overdue.map(\.dose)) { dose in
                overdue.first { $0.dose === dose }?.rule.description ?? "-"
            }
            emitPumpEvents(events)
            return settled + open.count + overdue.count
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
            guard let event = finalize(dose, deliveredUnits: neverRan ? 0 : nil, neverRan ? .neverRan : .byEstimate) else {
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

        // What was held back after a temp basal, the same - counted from when it was held - and never before that
        // temp basal's final: fixed from our estimate only after a restart, it may be newer. Kept while a temp basal
        // started before it waits on the host.
        let tempBasals = state.awaitingRecord.filter { $0.type == .tempBasal }
        let expiredHeld = state.heldBasalDoses.filter { held in
            checkedAt.timeIntervalSince(held.heldAt) > Self.unconfirmedFinalMaximumAge &&
                !tempBasals.contains { $0.startDate <= held.dose.startDate }
        }.map(\.dose)
        guard !expiredHeld.isEmpty else {
            return
        }
        state.heldBasalDoses.removeAll { held in expiredHeld.contains { $0 === held.dose } }
        heldInFlight.removeAll { dose in expiredHeld.contains { $0 === dose } }
        for dose in expiredHeld {
            log.error("The host never confirmed storing the \(dose.type.rawValue) of \(dose.startDate), giving up on it")
        }
    }

    /// Finals the host has not confirmed, and no batch has carried for a while - or suspends and resumes kept until it
    /// stores them (`keepUntilStored`), not those held for the records of the temp basal whose command went unanswered:
    /// after a restart, with the patch out of reach, they would wait for its first status. Only under `doseReportLock`.
    private var isUnconfirmedFinalsResendDue: Bool {
        Date.now.timeIntervalSince(lastFinalsSentAt) >= Self.unconfirmedFinalsResendInterval &&
            (state.awaitingRecord.contains(where: \.isFinalized) || !keptBasalDoses.isEmpty)
    }

    /// The doses held back that go out with any batch: not those held for the records of the temp basal whose command
    /// went unanswered. Only under `doseReportLock`.
    private var keptBasalDoses: [UnfinalizedDose] {
        state.heldBasalDoses.map(\.dose).filter { dose in !heldForUnconfirmedRead.contains { $0 === dose } }
    }

    /// Sends the finals the host has yet to confirm again, if no batch carried them for a while. Needs neither the link
    /// nor a patch.
    internal func resendUnacknowledgedFinalsIfDue() {
        doseReportLock.withLock {
            // The temp basal restored waiting on its read, no status since the restart to read it on: not waited on
            // for good - its final goes out from our estimate, what was held behind it with it
            if let restored = tempBasalEndFromLastRun,
               now().timeIntervalSince(restored.restoredAt) >= Self.tempBasalEndFromLastRunLinkWait
            {
                giveUpOnTempBasalEndFromLastRun(restored.ending)
            }

            guard isUnconfirmedFinalsResendDue else {
                return
            }

            log.warning(
                "The host has not confirmed \(state.awaitingRecord.filter(\.isFinalized).count) final report(s) and " +
                    "\(keptBasalDoses.count) suspend(s) or resume(s), sending them again"
            )
            // A temp basal's records being read: their batch carries every final
            emitPumpEvents([], replacePendingEvents: false, unlessTempBasalEndPending: true)
        }
    }

    /// Doses wait on records the patch has written already, or past their timeout - or finals are due to go out again -
    /// or the patch told of records past the cursor, no dose waiting on them. Not a temp basal ended back to back moments
    /// ago (`awaitsItsReadAfterTheCommand`), nor records a command told of moments ago (`isRightAfterACommand`): the
    /// heartbeat naming them comes a second or two after the command, and its sync would take the link from the loop's
    /// bolus right behind it.
    internal var hasPendingRecordWork: Bool {
        if doseReportLock.withLock({ isUnconfirmedFinalsResendDue }) {
            return true
        }

        let checkedAt = now()
        // Records no dose waits on - those a temp basal's read left to the sync, say: read with a heartbeat, within the
        // sync's cooldown, not with the next full sync only, which every command's answer puts off making the status
        // fresh (device 2026-10-20 13:35-13:41: 679 left to the sync by one suspend still unread at the next, whose
        // read took 5 records rather than 2 - the kill came during it)
        if state.syncedSequenceNumber < state.currentSequenceNumber, !isRightAfterACommand(at: checkedAt) {
            return true
        }

        let waitingSince = recordWaits(at: checkedAt)
        guard !waitingSince.isEmpty else {
            return false
        }

        return state.syncedSequenceNumber < state.currentSequenceNumber || waitingSince.contains {
            RecordSyncer.fallbackRule(since: $0, caughtUp: isCaughtUp(after: $0), now: checkedAt) != nil
        }
    }

    /// The newest record the answer of a dose waiting on it named - a bolus's - nil, none
    internal var newestRecordNamedForAwaitingDose: Int? {
        doseReportLock.withLock {
            state.awaitingRecord.filter { !$0.isFinalized }.compactMap(\.recordSequence).max()
        }
    }

    /// Doses wait on records the patch has written already - see `hasPendingRecordWork`
    internal var awaitsRecordsWritten: Bool {
        state.syncedSequenceNumber < state.currentSequenceNumber && !recordWaits(at: now()).isEmpty
    }

    /// When each dose waiting on its record ended - that temp basals ended back to back moments ago wait on no sync
    private func recordWaits(at checkedAt: Date) -> [Date] {
        var waitingSince = state.awaitingRecord.compactMap { dose -> Date? in
            let snapshot = dose.snapshot
            return snapshot.isFinalized || awaitsItsReadAfterTheCommand(snapshot, at: checkedAt) ? nil : snapshot.finishedAt
        }
        if let pending = state.unconfirmedTempBasal {
            waitingSince.append(unconfirmedTempBasalEnd(pending))
        }
        return waitingSince
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

    /// The boluses whose answer was lost - or named no record of this patch - not final: running, or waiting on their
    /// record, which is looked for by when they went out. Seen delivering since or not. Only under `doseReportLock`.
    private var bolusesWithoutTheirAnsweredRecord: [UnfinalizedDose] {
        ([state.bolusDose].compactMap { $0 } + state.awaitingRecord).filter { dose in
            let snapshot = dose.snapshot
            return dose.type == .bolus && snapshot.recordSequence == nil && !snapshot.isFinalized
        }
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
    /// lost. A batch going out before that carries them out with our estimate (`emitPumpEvents`). Every temp basal ended
    /// open before it (`openTempBasalEnds`) goes final with it. A temp basal a new one replaced back to back is not one of
    /// these: it ends open itself.
    final class TempBasalEnd {
        let dose: UnfinalizedDose
        /// Where its last record ends, on the patch clock: where the segment after it started
        let patchEnd: Date?
        /// The number of its last record - named by a status after the one that ended it, where that one named none
        /// (`awaitsRecord`)
        var lastRecord: Int? {
            named.value.lastRecord
        }

        /// Ended by a status that named no record - a halt's, cut short (device 2026-10-26 10:08:55): the newest record
        /// the next status names is its last, the patch writes it as it ends it - see `namesRecordOfTempBasalEnd`. Until
        /// then its records are not read, nor is it settled from our estimate - for `tempBasalEndRecordWait` at most.
        var awaitsRecord: Bool {
            named.value.awaits
        }

        /// When the status that ended it, naming no record, was received, on the monotonic clock: one received before
        /// says nothing of its record. Nil, restored after a restart: every status of this run came after it.
        let awaitsAfterUptime: TimeInterval?

        private let named: Locked<(lastRecord: Int?, awaits: Bool)>
        /// No record of its own end known, those of the temp basals ended open before it are read all the same - unless
        /// the command that ended it went unanswered: the link may be gone
        let readsOpenEnds: Bool
        /// What followed it - a command that changes the basal again before it is settled adds its own, under
        /// `doseReportLock` (`hold`)
        var then: [NewPumpEvent] = []
        /// The finals of a bolus that came meanwhile, out after `then`, in the same batch - its end, mutable, goes out
        /// from the dose as it is then (`emitBolusEvents`). Under `doseReportLock`.
        var bolusReports: [NewPumpEvent] = []

        init(
            dose: UnfinalizedDose,
            patchEnd: Date?,
            lastRecord: Int?,
            readsOpenEnds: Bool = true,
            awaitsRecord: Bool = false,
            awaitsAfterUptime: TimeInterval? = nil
        ) {
            self.dose = dose
            self.patchEnd = patchEnd
            named = Locked((lastRecord, awaitsRecord && lastRecord == nil))
            self.readsOpenEnds = readsOpenEnds
            self.awaitsAfterUptime = awaitsAfterUptime
        }

        /// A status names `record` its last. Under `doseReportLock`.
        fileprivate func name(_ record: Int) {
            named.value = (record, false)
        }
    }

    internal var pendingTempBasalEnd: TempBasalEnd? {
        doseReportLock.withLock { pendingTempBasalEndStorage }
    }

    /// At most this many records are read for a temp basal as it ends - its parts and a bolus or two: a backlog is left
    /// to the record sync, and our estimate stands in
    internal static let tempBasalEndMaxRecords = 8

    /// How long one record may take to come back as a temp basal ends: 4 to 9 s on a slow link (a fragment every 1.3 s
    /// or so, device logs 2026-10). A link that does not answer by then is not waited on any longer.
    internal static let tempBasalEndRecordTimeout: TimeInterval = 10

    /// How long the records of a temp basal as it ends may take to read, all of them: the command that ended it - and the
    /// loop waiting on it - is held up meanwhile. Two records' worth, for one whose parts the patch split at midnight, or
    /// with a bolus's record ahead of its own: the reading stops as soon as the ones read settle it. Past it, our
    /// estimate stands in.
    internal static let tempBasalEndReadBudget: TimeInterval = 2 * tempBasalEndRecordTimeout

    /// The same, read off a command, the patch suspended - halted or told to - and no command waiting for the link
    /// (`readsLongerAsTempBasalEnds`): nothing the loop sends can deliver meanwhile, nor is held up, and the host has
    /// the temp basal delivering through the suspension until its final - IOB overstated, never understated. A slow
    /// link takes 4 to 7 s a record (device 2026-10-22 20:18:59-20:19:20: four in 21 s, past `tempBasalEndReadBudget`).
    /// Checked before each record: a command come meanwhile waits for the one in flight at most, as within the budget.
    internal static let tempBasalEndSuspendedReadBudget: TimeInterval = 6 * tempBasalEndRecordTimeout

    /// Whether the records of a temp basal as it ends may take `tempBasalEndSuspendedReadBudget` to read
    internal var readsLongerAsTempBasalEnds: Bool {
        doseReportLock.withLock { state.basalDose.type == .suspend } && !isCommandActive && !isLoopWaiting
    }

    /// Something waits for the link (`loopWaits`). One waiting `loopWaitExpiry` or longer is dropped, with a warning.
    private var isLoopWaiting: Bool {
        let checkedAt = Date.now
        var expired = 0
        let waits = loopWaits.mutate { waits in
            let before = waits.count
            waits = waits.filter { checkedAt.timeIntervalSince($0.value) < Self.loopWaitExpiry }
            expired = before - waits.count
        }
        if expired > 0 {
            log.warning("\(expired) wait(s) for the link not over within \(Int(Self.loopWaitExpiry)) s, no longer counted")
        }
        return !waits.isEmpty
    }

    /// See `loopWaits`: as long as a command may take. Only tests change it.
    internal static var loopWaitExpiry: TimeInterval = commandActivityTimeout

    /// Runs `body` - the loop's sync, a patch time fetch, waiting for the link - counted in `loopWaits` meanwhile: a
    /// temp basal's records read as it ends take no longer than `tempBasalEndReadBudget` - the loop's background task
    /// is some 30 s, and iAPS waits on the sync with no timeout of its own
    internal func whileTheLoopWaits<T>(_ body: () -> T) -> T {
        let waiting = loopBeginsWaiting()
        defer { loopWaits.mutate { $0[waiting] = nil } }
        return body()
    }

    /// The loop's sync begins waiting for the link (`whileTheLoopWaits`) - until `loopHearsBack` with the token returned
    internal func loopBeginsWaiting() -> UUID {
        let waiting = UUID()
        let beganAt = Date.now
        loopWaits.mutate { $0[waiting] = beganAt }
        return waiting
    }

    /// The loop's sync of `waiting` is answered: no longer waiting
    private func loopHearsBack(_ waiting: UUID, _ date: Date?, _ completion: ((Date?) -> Void)?) {
        loopWaits.mutate { $0[waiting] = nil }
        completion?(date)
    }

    /// No record is asked for with less of that budget left than a round trip takes
    internal static let tempBasalEndRecordReadMinimum: TimeInterval = 1.5

    /// The running temp basal, if any, stopped at `endedAt` - its last record `lastRecord`, ending at `patchEnd` on the
    /// patch clock, where known - and `next` follows it: neither goes out before its final, see `TempBasalEnd`. It is
    /// kept in `awaitingRecord` meanwhile, its last record and patch end with it - and `next` in `heldBasalDoses`: a run
    /// killed during the read has the next one read them on its first link, `next` reported after its final all the
    /// same (`takeOverTempBasalEndFromLastRun`). `awaitsRecordAfter`, no last record known: a status received after
    /// then - the status that ended it - names it, see `TempBasalEnd.awaitsRecord`. The caller replaces `state.basalDose` with `next`, then has it finished. Returns
    /// false when no temp basal was running: the caller reports `next` itself. Only under `doseReportLock`.
    internal func beginTempBasalEnd(
        endedAt: Date,
        patchEnd: Date?,
        lastRecord: Int?,
        readsOpenEnds: Bool = true,
        awaitsRecordAfter receivedUptime: TimeInterval? = nil,
        then next: (dose: UnfinalizedDose, event: NewPumpEvent)
    ) -> Bool {
        doseReportLock.withLock { () -> Bool in
            let dose = state.basalDose
            guard dose.type == .tempBasal, !dose.isFinished else {
                return false
            }

            // One that ended before, its records still unread, goes out first - from our estimate. So too one restored
            // after a restart (`takeOverTempBasalEndFromLastRun`) that the first status of this run - a halt over the
            // temp basal set after it, say - ends another before reading it, though its records are no later than the
            // new one's: rare, a restart in the read of a set's cancel and a halt while the app was gone, and the
            // estimate is what any restart gave before
            if pendingTempBasalEndStorage != nil {
                emitPumpEvents([])
            }

            dose.finish(endedAt >= dose.estimatedEndDate ? .completed : .cancelled, endedAt: endedAt, at: now())
            // Saved with it: a restart before its final reads them after all - or waits for the status that names them
            let awaitsRecord = receivedUptime != nil && lastRecord == nil
            if let lastRecord {
                dose.noteEndRead(lastRecord: lastRecord, patchEnd: patchEnd)
            } else if awaitsRecord {
                dose.noteEndAwaitsRecord(patchEnd: patchEnd)
            }
            state.mutateAwaitingRecord { doses in
                guard !doses.contains(where: { $0 === dose }) else {
                    return
                }
                doses.append(dose)
            }
            let ending = TempBasalEnd(
                dose: dose,
                patchEnd: patchEnd,
                lastRecord: lastRecord,
                readsOpenEnds: readsOpenEnds,
                awaitsRecord: awaitsRecord,
                awaitsAfterUptime: receivedUptime
            )
            pendingTempBasalEndStorage = ending
            hold(next, after: ending)

            if awaitsRecord {
                log.info(
                    "Temp basal of \(dose.startDate) ended at \(endedAt), its status naming no record: reported once its " +
                        "records up to the one the next status names are read, \(Int(Self.tempBasalEndRecordWait)) s at most"
                )
                boundTheWaitForItsRecord(ending, after: Self.tempBasalEndRecordWait)
            } else {
                log.info(
                    "Temp basal of \(dose.startDate) ended at \(endedAt), reported once its records up to " +
                        "\(lastRecord.map { "#\($0)" } ?? "-") are read"
                )
            }
            return true
        }
    }

    /// A status received at `receivedUptime` names `newest` the newest record of the patch `patchId` has written: the
    /// temp basal a halt ended with no record named (`TempBasalEnd.awaitsRecord`), if one waits, has it for its last -
    /// written as the patch ended it, it is that one or one before - saved with it, as one named so from the start.
    /// Returns whether one did: the caller has its records read, as for one this status ended. Not for another patch,
    /// nor once the session ended. Nor from a status received before the one that ended it, handled after it - a full
    /// status's thread against the notifications' - nor one naming no record past those read: from before the patch wrote
    /// its record. It waits on then.
    internal func namesRecordOfTempBasalEnd(_ newest: Int, patchId: UInt64, receivedUptime: TimeInterval) -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard let ending = pendingTempBasalEndStorage, ending.awaitsRecord, !state.patchSessionEnded,
                  !state.patchId.isEmpty, RecordSyncer.isSamePatch(patchId, state.patchId.toUInt64())
            else {
                return false
            }
            guard newest > state.syncedSequenceNumber, ending.awaitsAfterUptime.map({ receivedUptime >= $0 }) ?? true else {
                log.info(
                    "A status names record #\(newest), from before the temp basal of \(ending.dose.startDate) ended - " +
                        "read up to #\(state.syncedSequenceNumber): waiting on for one that names its record"
                )
                return false
            }
            ending.name(newest)
            ending.dose.noteEndRead(lastRecord: newest, patchEnd: ending.patchEnd)
            log.info("A status names record #\(newest): the records of the temp basal of \(ending.dose.startDate) are read up to it")
            return true
        }
    }

    /// The temp basal whose end waits for a status to name its record (`TempBasalEnd.awaitsRecord`), on a command's thread
    /// holding `commandLock` - a command that changes the basal behind it, a bolus, the deactivation: a full status is
    /// asked for here, its storage naming it (`namesRecordOfTempBasalEnd`), and the command reads it, as one named from
    /// the start. Not left to the heartbeat: what the command reports would be held behind it meanwhile - a temp basal so
    /// is not saved with the state (`hold`) - and the deactivation would report it from our estimate. Returns whether it
    /// is named now.
    @discardableResult internal func askForTheRecordOfTheWaitingEnd() -> Bool {
        guard let ending = pendingTempBasalEnd, ending.awaitsRecord else {
            return false
        }
        log.info("Asking for a full status in the command: it names the record of the temp basal of \(ending.dose.startDate)")

        let result = link.write(SynchronizePacket(), timeout: Self.tempBasalEndRecordTimeout)
        guard case let .success(data) = result, let response = data as? SynchronizePacketResponse else {
            log.warning("The full status asked for did not come: the temp basal of \(ending.dose.startDate) waits on")
            return false
        }
        handleStatus(response, duringReconnect: false, fullSync: true)
        return !ending.awaitsRecord
    }

    /// `ending` waits for a status to name its last record (`TempBasalEnd.awaitsRecord`) - not for good: none by `delay`
    /// from now, the link likely gone, its final goes out from our estimate, what followed it with it. Only under
    /// `doseReportLock`.
    private func boundTheWaitForItsRecord(_ ending: TempBasalEnd, after delay: TimeInterval) {
        tempBasalEndQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.backgroundReadsStopped.value else {
                return
            }
            self.doseReportLock.withLock {
                guard self.pendingTempBasalEndStorage === ending, ending.awaitsRecord else {
                    return
                }
                _ = self.settleTempBasalEnd(
                    ending,
                    records: [],
                    unread: "no status named its record within \(Int(Self.tempBasalEndRecordWait)) s of its end"
                )
            }
        }
    }

    /// How long the temp basal a halt ended waits for a status to name its record (`TempBasalEnd.awaitsRecord`): the full
    /// status a heartbeat asks for at once names it (`heartbeatSync`) - 3 s later on the device, 2026-10-26 10:08:58.
    /// Past that, the link likely gone, our estimate stands in: the host has the temp basal delivering through the halt
    /// meanwhile, as when the restart's read waits for the link (`tempBasalEndFromLastRunLinkWait`). On the wall clock;
    /// only tests change it.
    internal static var tempBasalEndRecordWait: TimeInterval = tempBasalEndFromLastRunLinkWait

    /// In a new run's state, a temp basal whose records were being read as it ended (`TempBasalEnd`), the app gone
    /// before its final: its last record saved with it (`UnfinalizedDose.State.endReadLastRecord`), it waits on its
    /// read again - on the first status of this run, as one a status ended (`readsTempBasalEndFromLastRun`), or the
    /// command that comes first - what was held back after it held behind its final as before, and nothing reported
    /// meanwhile: the host has it as the run before left it. Our estimate stands in if that read fails, if the patch
    /// session is not the one it was saved with by then, if no status comes within `tempBasalEndFromLastRunLinkWait` of
    /// the restart, and before any batch that goes out first - as in the run that ended it. Not one with no last record
    /// known - unless it waits for a status to name it (`TempBasalEnd.awaitsRecord`): it waits on here, what is left of
    /// `tempBasalEndRecordWait` - one saved by an earlier build, one that ended `tempBasalEndFromLastRunLinkWait` ago or more, nor one whose
    /// record is overdue: from our estimate with the first batch, as before (`emitPumpEvents`).
    ///
    /// The restart used to finalize it from our estimate at once - its end was kept in memory only, and the first batch
    /// of the new run needs no link that way, and carries its final ahead of what followed it, which Loop's watermark
    /// requires. Waiting for the link puts that order at no risk: no batch goes out meanwhile without its final, and what
    /// followed it is saved until the host stores it (`heldBasalDoses`). The wait is bounded, as the read is.
    private func takeOverTempBasalEndFromLastRun() {
        doseReportLock.withLock {
            guard !state.patchId.isEmpty, !state.patchSessionEnded else {
                return
            }
            let checkedAt = now()
            let waiting = state.awaitingRecord.filter { dose in
                let ended = dose.snapshot
                guard dose.type == .tempBasal, !ended.isFinalized, !ended.endedOpen,
                      ended.endReadLastRecord != nil || ended.endReadAwaitsRecord, let finishedAt = ended.finishedAt
                else {
                    return false
                }
                // Not one that ended `tempBasalEndFromLastRunLinkWait` ago or more: restarts one after the other - a
                // crash loop - would otherwise each wait it out again, the suspend held behind it kept from the host
                // for good. A wall clock set back since - the age negative - restores nothing either.
                let age = checkedAt.timeIntervalSince(finishedAt)
                guard age >= 0, age < Self.tempBasalEndFromLastRunLinkWait else {
                    return false
                }
                return RecordSyncer.fallbackRule(since: finishedAt, caughtUp: isCaughtUp(after: finishedAt), now: checkedAt) == nil
            }
            // One at a time in a run: any other is an older one's, from our estimate ahead of it
            guard let dose = waiting.max(by: { $0.startDate < $1.startDate }), let finishedAt = dose.snapshot.finishedAt else {
                return
            }
            let lastRecord = dose.snapshot.endReadLastRecord

            let ending = TempBasalEnd(
                dose: dose,
                patchEnd: dose.snapshot.endReadPatchEnd,
                lastRecord: lastRecord,
                awaitsRecord: dose.snapshot.endReadAwaitsRecord
            )
            // What followed it, held back - as `hold` had it, as it ended or after: in this batch with its final, after
            // it. Not a suspend or resume kept from before (`keepUntilStored`) that is dated at its start or later - its
            // first, of what followed it, would have its final end there.
            ending.then = state.heldBasalDoses.filter { $0.heldAt >= finishedAt && $0.dose.startDate >= dose.startDate }
                .map(\.dose).compactMap(Self.heldEvent(of:))
            pendingTempBasalEndStorage = ending
            tempBasalEndFromLastRun = (ending, state.patchId, checkedAt)
            if let lastRecord {
                log.info(
                    "The temp basal of \(dose.startDate) was saved as its records up to #\(lastRecord) were read: read on the " +
                        "first link, \(ending.then.count) dose(s) held back behind its final"
                )
            } else {
                log.info(
                    "The temp basal of \(dose.startDate) was saved waiting for a status to name its record: read once one " +
                        "does, \(ending.then.count) dose(s) held back behind its final"
                )
                // What is left of the wait it began with - the restart's own bound, below, ends with the first status
                let waited = max(0, checkedAt.timeIntervalSince(finishedAt))
                boundTheWaitForItsRecord(ending, after: max(0, Self.tempBasalEndRecordWait - waited))
            }

            // At the bound, the loop's next run maybe minutes off - the patch out of reach, no status comes
            tempBasalEndQueue.asyncAfter(deadline: .now() + Self.tempBasalEndFromLastRunCheckDelay) { [weak self] in
                guard let self, !self.backgroundReadsStopped.value else {
                    return
                }
                self.doseReportLock.withLock {
                    self.giveUpOnTempBasalEndFromLastRun(ending)
                }
            }
        }
    }

    /// The temp basal restored waiting on its read (`takeOverTempBasalEndFromLastRun`), `ending`, no read of it begun
    /// within `tempBasalEndFromLastRunLinkWait` of the restart: not waited on for good - its final goes out from our
    /// estimate, what was held behind it with it. Only under `doseReportLock`.
    private func giveUpOnTempBasalEndFromLastRun(_ ending: TempBasalEnd) {
        guard tempBasalEndFromLastRun?.ending === ending else {
            return
        }
        tempBasalEndFromLastRun = nil
        _ = settleTempBasalEnd(
            ending,
            records: [],
            unread: "no status came within \(Int(Self.tempBasalEndFromLastRunLinkWait)) s of the restart to read them on"
        )
    }

    /// A read of the records of `ending` begins: the temp basal restored waiting on its read, if that is it, is the
    /// read's from here on - not given up on meanwhile (`giveUpOnTempBasalEndFromLastRun`). A command that came first
    /// reads it so, with no status of this run before it.
    internal func noteTempBasalEndReadBegins(_ ending: TempBasalEnd) {
        doseReportLock.withLock {
            if tempBasalEndFromLastRun?.ending === ending {
                tempBasalEndFromLastRun = nil
            }
            // Nor waited on for the bolus's end any longer (`readsTempBasalEndAfterBolus`): its bound is moot
            if tempBasalEndAwaitingBolus === ending {
                tempBasalEndAwaitingBolus = nil
            }
        }
    }

    /// No status within this long of a restart, the temp basal restored waiting on its read goes final from our
    /// estimate - see `takeOverTempBasalEndFromLastRun`. The patch is back within seconds of a relaunch in reach (device
    /// log 2026-10-20 13:38:37, its status 2 s later). Past that it may be out of reach for long - and the suspend held
    /// behind it, which the host would otherwise have again within `unconfirmedFinalsResendInterval`, is worth more
    /// than the record: kept from the host, it has the temp basal deliver through the suspension, an error growing by
    /// the minute, while our estimate is off by the temp basal's rate × the age of its last status at most. Checked
    /// as it runs out, on a timer set at the restart (`tempBasalEndFromLastRunCheckDelay`) - and where the finals the
    /// host has yet to confirm are sent again, which needs no link (`resendUnacknowledgedFinalsIfDue`): the loop's
    /// every run. Nor is one restored that ended this long ago: a run before waited it out already.
    internal static let tempBasalEndFromLastRunLinkWait: TimeInterval = unconfirmedFinalsResendInterval

    /// When that timer fires after the restart, on the wall clock: `tempBasalEndFromLastRunLinkWait`. Only tests change
    /// it, their manager's clock moved on instead.
    internal static var tempBasalEndFromLastRunCheckDelay: TimeInterval = tempBasalEndFromLastRunLinkWait

    /// A status of the patch: the temp basal restored waiting on its read (`takeOverTempBasalEndFromLastRun`), if
    /// any, is read now, as one this status ended - returns true, the caller has it read. Once: it is the read's from
    /// here on. One restored for another patch session goes final from our estimate.
    internal func readsTempBasalEndFromLastRun() -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard let restored = tempBasalEndFromLastRun else {
                return false
            }
            tempBasalEndFromLastRun = nil
            guard pendingTempBasalEndStorage === restored.ending else {
                return false
            }
            guard state.patchId == restored.patchId, !state.patchSessionEnded else {
                _ = settleTempBasalEnd(restored.ending, records: [], unread: "the patch session ended")
                return false
            }
            return true
        }
    }

    /// `next`, of a status - the resume the patch shows - follows the temp basal whose records are read as it ended, if
    /// any is: held back behind its final, as a command's is (`replaceRunningBasal`), rather than taking it out with our
    /// estimate. Returns whether it was. Only under `doseReportLock`.
    internal func holdBehindTempBasalEnd(_ next: (dose: UnfinalizedDose, event: NewPumpEvent)) -> Bool {
        guard let pending = pendingTempBasalEndStorage else {
            return false
        }
        hold(next, after: pending)
        return true
    }

    /// `next` follows the temp basal of `ending`, its report held back until that one's final goes out - and its dose
    /// saved until the host confirms storing it, unless it is a temp basal: see `MedtrumPumpState.heldBasalDoses`.
    /// Only under `doseReportLock`.
    private func hold(_ next: (dose: UnfinalizedDose, event: NewPumpEvent), after ending: TempBasalEnd) {
        ending.then.append(next.event)
        // A temp basal is not saved here: killed before the final, the next run rebuilds `then` from `heldBasalDoses`
        // only (`takeOverTempBasalEndFromLastRun`) - a set held behind the read, a halt after it moving `basalDose` on,
        // is then reported by nothing. The read's budget at most of a temp basal, seconds on the patch: left so. Behind
        // an end waiting for its record the command names it first (`askForTheRecordOfTheWaitingEnd`) - held longer only
        // if that status does not come.
        guard next.dose.type != .tempBasal else {
            return
        }
        state.heldBasalDoses.append(HeldBasalDose(dose: next.dose, heldAt: now()))
    }

    /// `dose`, a suspend or a resume about to go out, is saved with the state until the host confirms storing a batch
    /// that carried it (`MedtrumPumpState.heldBasalDoses`) - every batch until then carries it again, in the order they
    /// came. Handed over once, it is lost to a kill between the state saved with its batch, which has it reported, and
    /// the host storing it - iAPS stores in a task of its own. A suspend lost, the resume after it - the next patch's,
    /// say - is one with none before it: iAPS takes the patch to have been suspended since before its history, and
    /// with `suspend_zeros_iob` zeroes every temp basal before the resume, and the scheduled basal from 8 h back. A
    /// resume lost leaves the suspend open: every temp basal after it zeroed. IOB far too low either way. Of another
    /// kind, nothing is kept. Only under `doseReportLock`.
    internal func keepUntilStored(_ dose: UnfinalizedDose) {
        guard dose.type == .suspend || dose.type == .resume, !state.heldBasalDoses.contains(where: { $0.dose === dose }) else {
            return
        }
        state.heldBasalDoses.append(HeldBasalDose(dose: dose, heldAt: now()))
    }

    /// The host stored a batch: the held back doses it carried need not go out again - as `acknowledgeFinals`
    private func acknowledgeHeld(_ held: [UnfinalizedDose]) {
        guard !held.isEmpty else {
            return
        }

        let acknowledged = doseReportLock.withLock { () -> Int in
            heldInFlight.removeAll { dose in held.contains { $0 === dose } }
            let before = state.heldBasalDoses.count
            state.heldBasalDoses.removeAll { heldDose in held.contains { $0 === heldDose.dose } }
            return before - state.heldBasalDoses.count
        }

        if acknowledged > 0 {
            notifyStateDidChange()
        }
    }

    /// A batch carrying `held` was not stored: going out again, they are sent again
    private func notInFlight(_ held: [UnfinalizedDose]) {
        guard !held.isEmpty else {
            return
        }
        doseReportLock.withLock {
            heldInFlight.removeAll { dose in held.contains { $0 === dose } }
        }
    }

    /// The report of a dose held back after a temp basal - see `MedtrumPumpState.heldBasalDoses` - as it was first built
    private static func heldEvent(of dose: UnfinalizedDose) -> NewPumpEvent? {
        switch dose.type {
        case .suspend:
            return NewPumpEvent.suspend(dose: dose.toDoseEntry())
        case .resume:
            return NewPumpEvent.resume(dose: dose.toDoseEntry())
        case .basal:
            return NewPumpEvent.basal(dose: dose.toDoseEntry())
        case .bolus,
             .tempBasal:
            return nil
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
            while self.isCommandActive, Date.now < deadline, !self.backgroundReadsStopped.value {
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard !self.backgroundReadsStopped.value else {
                return
            }

            // Not counted as waiting: a record sync ahead of it may be reading these very records
            let read = self.withCommandLock(waits: false) {
                RecordSyncer.finishTempBasalEnd(pumpManager: self)
            }
            if !read, let ending = self.pendingTempBasalEnd {
                _ = self.settleTempBasalEnd(ending, records: [], unread: "another operation held the patch")
            }
        }
    }

    /// `ending`, read off a command - a halt's, say - with a bolus running: no record is read while it runs
    /// (`RecordSyncer.wouldRead`), and the patch, halted, ends it moments later, its completion in a notification of its
    /// own. Read once it is over - its end held behind the read meanwhile (`emitBolusEvents`) - rather than taking it out
    /// from our estimate now. Not for good: past `tempBasalEndBolusWait` with the bolus still running - the link lost,
    /// its end unseen - our estimate stands in, what followed it with it. A full status past its deadline ends it, the
    /// session's end takes the temp basal out with it. Returns whether it waits.
    internal func readsTempBasalEndAfterBolus(_ ending: TempBasalEnd) -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard pendingTempBasalEndStorage === ending, let bolus = state.bolusDose, !bolus.isFinished,
                  lastRecordToRead(for: ending) != nil
            else {
                return false
            }
            guard tempBasalEndAwaitingBolus !== ending else {
                return true
            }
            tempBasalEndAwaitingBolus = ending
            log.info("A bolus is running: the records of the temp basal of \(ending.dose.startDate) are read once it is over")

            tempBasalEndQueue.asyncAfter(deadline: .now() + Self.tempBasalEndBolusWait) { [weak self] in
                guard let self, !self.backgroundReadsStopped.value else {
                    return
                }
                self.doseReportLock.withLock {
                    guard self.tempBasalEndAwaitingBolus === ending else {
                        return
                    }
                    self.tempBasalEndAwaitingBolus = nil
                    _ = self.settleTempBasalEnd(
                        ending,
                        records: [],
                        unread: "the bolus running as it ended was not over within \(Int(Self.tempBasalEndBolusWait)) s"
                    )
                }
            }
            return true
        }
    }

    /// How long the records of a temp basal that ended with a bolus running wait for it to be over: a halt ends it,
    /// its completion follows within seconds - and the host has no suspend meanwhile, as when the restart's read waits
    /// for the link (`tempBasalEndFromLastRunLinkWait`). On the wall clock; only tests change it.
    internal static var tempBasalEndBolusWait: TimeInterval = tempBasalEndFromLastRunLinkWait

    /// The bolus a temp basal's records waited for is over (`readsTempBasalEndAfterBolus`): read them now
    private func readTempBasalEndAfterBolus() {
        let due = doseReportLock.withLock { () -> Bool in
            guard let ending = tempBasalEndAwaitingBolus, state.bolusDose.map(\.isFinished) ?? true else {
                return false
            }
            tempBasalEndAwaitingBolus = nil
            return pendingTempBasalEndStorage === ending
        }
        if due {
            finishPendingTempBasalEndSoon()
        }
    }

    /// Fixes the final of the temp basal of `ending` - from `records`, read in one go up to its last record, if they
    /// add up to it; else from our estimate, `unread` saying why not all could be read - and reports it with what
    /// followed it. Every temp basal ended open before it goes final first, in the same batch: from `records` where they
    /// add up to it, else from our estimate - see `openTempBasalEnds`. Returns the outcome for each record a temp basal
    /// was finalized from, for the record screen. Nothing, if a batch carried it out meanwhile.
    internal func settleTempBasalEnd(_ ending: TempBasalEnd, records: [GetRecordResponse], unread: String?) -> [Int: String] {
        doseReportLock.withLock { () -> [Int: String] in
            guard pendingTempBasalEndStorage === ending else {
                return [:]
            }
            pendingTempBasalEndStorage = nil
            if tempBasalEndFromLastRun?.ending === ending {
                tempBasalEndFromLastRun = nil
            }
            if tempBasalEndAwaitingBolus === ending {
                tempBasalEndAwaitingBolus = nil
            }

            let dose = ending.dose
            var events: [NewPumpEvent] = []
            var outcomes: [Int: String] = [:]

            // The temp basal whose command went unanswered started before all of them: its record among these goes final
            // first, in this batch - after theirs, the host would take it as behind them, and drop it
            if state.unconfirmedTempBasal != nil {
                let patchId = state.patchId.toUInt64()
                for response in records.sorted(by: { $0.sequence < $1.sequence })
                    where RecordSyncer.isSamePatch(response.patchId, patchId)
                {
                    guard case let .basal(record) = response.record, record.type == .ABSOLUTE_TEMP,
                          let finalized = finalizeUnconfirmedTempBasal(from: record, sequence: response.sequence, ending: true)
                    else {
                        continue
                    }
                    events += finalized.events
                    outcomes[response.sequence] = finalized.outcome
                    break
                }
            }

            for open in openTempBasalEnds {
                if let parts = openTempBasalParts(of: open, in: records, logging: true) {
                    if let final = finalizeOpen(open, from: parts) {
                        events.append(final)
                    }
                    for sequence in parts.sequences {
                        outcomes[sequence] = "finalized temp basal \(open.startDate)"
                    }
                } else if let final = estimateFinal(
                    open,
                    because: unread ?? "its records do not add up, and the temp basal of \(dose.startDate) after it ended"
                ) {
                    events.append(final)
                }
            }

            if unread == nil, let lastRecord = ending.lastRecord,
               let parts = tempBasalParts(of: dose, in: records, endingAt: ending.patchEnd, through: lastRecord)
            {
                log.info(
                    "Record(s) \(parts.sequences.map(String.init).joined(separator: ", ")) finalize the temp basal of " +
                        "\(dose.startDate): \(String(format: "%.1f", parts.duration / 60)) min on the patch, delivered " +
                        "\(parts.delivered) U by its records - ended at \(dose.observedEndDate.map { "\($0)" } ?? "-"), " +
                        "where what followed it starts"
                )
                // The amount the patch's, the end ours, where what followed it starts: nothing between the two for the
                // host to fill, nor to trim off it - unless the patch had stopped it well before, see `recordedEnd`
                let recorded = recordedEnd(of: dose, parts, in: records, before: ending.then.first?.date)
                if recorded != nil, let next = ending.then.first?.date {
                    // It ended elsewhere than where what followed it is dated: that one's patch start pairs with nothing
                    for following in [state.basalDose] + state.heldBasalDoses.map(\.dose)
                        where following.type != .tempBasal && following.startDate == next
                    {
                        following.forgetPumpStartTime()
                    }
                }
                if let final = finalize(dose, deliveredUnits: parts.delivered, endDate: recorded, .byRecord) {
                    events.append(final)
                }
                for sequence in parts.sequences {
                    outcomes[sequence] = "finalized temp basal \(dose.startDate)"
                }
            } else if let final = estimateFinal(
                dose,
                because: unread ?? (ending.lastRecord == nil ? "no record of its end is known" : "its records do not add up")
            ) {
                events.append(final)
            }

            emitPumpEvents(events + ending.then + ending.bolusReports)
            return outcomes
        }
    }

    /// The last record to read for the temp basal of `ending`: its own - else, no record of its end known and the command
    /// that ended it answered, the newest one a temp basal ended open before it waits on. Nil, none.
    internal func lastRecordToRead(for ending: TempBasalEnd) -> Int? {
        if let last = ending.lastRecord {
            return last
        }
        // Its own named by a status yet to come: those ended open before it are read with it then
        guard ending.readsOpenEnds, !ending.awaitsRecord else {
            return nil
        }
        // The temp basal whose command went unanswered, kept, with no cancel's answer naming its record - a set with no
        // cancel before it went out since: its record, if written, is no later than the newest the patch has
        let unconfirmed = doseReportLock.withLock { () -> Int? in
            guard let pending = state.unconfirmedTempBasal, pending.snapshot.endRecord == nil else {
                return nil
            }
            return state.currentSequenceNumber
        }
        return [lastRecordOfOpenTempBasalEnds, unconfirmed].compactMap { $0 }.max()
    }

    /// Where a temp basal finalized from its records `parts` ends: where we saw it end - what followed it starts there -
    /// unless its records end more than `patchEndTolerance` before that: the patch had stopped it then, unseen, and ran
    /// the schedule since, which the host fills the gap with - nil, where we saw it. A halt the patch announced without
    /// its time is not that: nothing ran after it, and the suspend after it is dated as it was seen.
    private func recordedEnd(
        of dose: UnfinalizedDose,
        _ parts: (delivered: Double, duration: TimeInterval, sequences: [Int], end: Date),
        in records: [GetRecordResponse],
        before next: Date?
    ) -> Date? {
        // Its parts from a patch start not its first segment's: they tell nothing of where it ended on our clock
        guard parts.duration >= Self.shortestComputedDuration, !dose.snapshot.firstSegmentUncertain else {
            return nil
        }
        let recorded = dose.startDate.addingTimeInterval(parts.duration)
        let observed = dose.tempBasalEnd(of: dose.snapshot)
        // Longer than where we took it to end - early, from the cancel's answer: the record wins, short of what follows
        if recorded.timeIntervalSince(observed) > Self.patchEndTolerance {
            let end = next.map { min(recorded, $0) } ?? recorded
            log.warning(
                "The records of the temp basal of \(dose.startDate) run \(Int(recorded.timeIntervalSince(observed))) s past " +
                    "where we took it to end, \(observed): it ends at \(end)"
            )
            return end
        }
        guard observed.timeIntervalSince(recorded) > Self.patchEndTolerance else {
            return nil
        }
        if let last = records.first(where: { $0.sequence == parts.sequences.last }), case let .basal(record) = last.record,
           record.endReason?.isSuspendedByPump() == true
        {
            return nil
        }
        log.warning(
            "The records of the temp basal of \(dose.startDate) end at \(recorded) on our clock, \(Int(observed.timeIntervalSince(recorded))) s " +
                "before we saw it end: the patch had stopped it then - it ends there, and the schedule ran since"
        )
        return recorded
    }

    /// Whether `records`, read in order so far, settle the temp basal of `ending` before its last record: its parts add
    /// up - see `tempBasalParts` - and the last of them is shown to be where it ended - and so every temp basal ended
    /// open before it (`openTempBasalParts`). Where it ended on the patch clock is known: the last part ends there. It is
    /// not - a halt the patch announced without its time, as it does: the last part is one the halt ended, by its end
    /// reason. A part ending where the patch split it, at patch-local midnight, ends with success, and a part after it
    /// may follow: without a known end, nothing short of that settles it - it is read up to its last record. The
    /// records after them are left to the record sync.
    internal func settlesTempBasalEnd(_ ending: TempBasalEnd, records: [GetRecordResponse]) -> Bool {
        doseReportLock.withLock { () -> Bool in
            guard openTempBasalEnds.allSatisfy({ openTempBasalParts(of: $0, in: records) != nil }) else {
                return false
            }
            // No record of its own end known, read for those ended open before it only: they settle it
            guard let lastRecord = ending.lastRecord else {
                return true
            }
            guard let parts = tempBasalParts(of: ending.dose, in: records, endingAt: ending.patchEnd, through: lastRecord, logging: false)
            else {
                return false
            }

            if let patchEnd = ending.patchEnd {
                return abs(parts.end.timeIntervalSince(patchEnd)) <= RecordSyncer.tempBasalStartTolerance
            }

            guard let last = records.first(where: { $0.sequence == parts.sequences.last }),
                  case let .basal(record) = last.record
            else {
                return false
            }
            return record.endReason?.isSuspendedByPump() == true
        }
    }

    /// What `records` show a temp basal of ours delivered, and for how long: its ABSOLUTE_TEMP parts at its rate - the
    /// ones kept as it ran (`keepPartOfRunningTempBasal`), then the ones read now - the first starting on its patch
    /// start, each where the one before ended, all of this patch, the last where it ended (`patchEnd`) or ran its
    /// course. Nil, the reason logged if `logging`, if they don't add up.
    private func tempBasalParts(
        of dose: UnfinalizedDose,
        in records: [GetRecordResponse],
        endingAt patchEnd: Date?,
        through lastRecord: Int? = nil,
        logging: Bool = true
    ) -> (delivered: Double, duration: TimeInterval, sequences: [Int], end: Date)? {
        let tolerance = RecordSyncer.tempBasalStartTolerance
        let snapshot = dose.snapshot
        let log = logging ? self.log : nil
        guard !snapshot.recordMatchDisabled, let pumpStartTime = snapshot.pumpStartTime else {
            log?.info(
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
                log?.warning(
                    "Record \(kept.sequence), a part of the temp basal of \(dose.startDate) read as it ran, is of patch " +
                        "\(kept.patchId) from \(kept.start): not where the part before it ended (\(partStart)), or not this patch"
                )
                return nil
            }
            parts.append(kept)
        }

        for response in records where !parts.contains(where: { $0.sequence == response.sequence }) {
            // Where it ended, its parts are all in: a record after - of the next one, at the same rate, say - is not one
            if let patchEnd, let last = parts.last, abs(last.end.timeIntervalSince(patchEnd)) <= tolerance {
                break
            }
            // Nor is one numbered past its last
            if let lastRecord, response.sequence > lastRecord {
                continue
            }
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
                    log?.warning(
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
            log?.warning("No record read starts where the temp basal of \(dose.startDate) did (\(pumpStartTime))")
            return nil
        }

        let ranItsCourse = pumpStartTime.addingTimeInterval(dose.estimatedEndDate.timeIntervalSince(dose.startDate))
        guard patchEnd.map({ abs(last.end.timeIntervalSince($0)) <= tolerance }) ?? true ||
            abs(last.end.timeIntervalSince(ranItsCourse)) <= tolerance
        else {
            log?.warning(
                "The records of the temp basal of \(dose.startDate) end at \(last.end), not where it ended " +
                    "(\(patchEnd.map { "\($0)" } ?? "-"))"
            )
            return nil
        }

        let delivered = parts.reduce(0) { $0 + $1.delivered }
        return (delivered.rounded(toPlaces: 2), last.end.timeIntervalSince(first.start), parts.map(\.sequence), last.end)
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
        // Ended open: delivering up to the cancel, where the patch says it ended - not up to the next one's start
        var until: Date?
        if snapshot.endedOpen, !snapshot.firstSegmentUncertain, let patchEnd = snapshot.patchEndTime,
           let pumpStartTime = snapshot.pumpStartTime
        {
            // How long the patch ran it, from our start: skew-free
            until = dose.startDate.addingTimeInterval(max(0, patchEnd.timeIntervalSince(pumpStartTime)))
        }
        let estimate = dose.tempBasalEstimate(of: snapshot, restarted: restarted, until: until)

        guard let event = finalize(dose, deliveredUnits: estimate.units, .byEstimate) else {
            return nil
        }

        log.warning(
            "Finalized the temp basal of \(dose.startDate) (\(snapshot.finishReason?.rawValue ?? "-")) without its records, " +
                "\(reason): \(estimate.units) U by our estimate, from its \(estimate.source.rawValue)" +
                (restarted ? " - it ran across patch-local midnight" : "")
        )
        return event
    }

    // MARK: - Temp basals ended back to back

    /// A temp basal of ours that a new one replaced back to back ends open: the host is told it ended where the new one
    /// started - exactly there, the same instant, so it has nothing to fill between the two - mutable until its records
    /// are read. Loop takes basal doses as final in order, and moves past a temp basal still mutable once anything
    /// immutable after it is stored - a temp basal's final, the scheduled basal it fills a gap with, a suspend: so these
    /// go final in order, the oldest first, in the batch that carries the next or an earlier one - never one before an
    /// older one (`finalize`). Every replacing batch carries those not final yet, mutable (`emitPumpEvents`).
    ///
    /// Their records are read once the command is over (`readOpenTempBasalEndsSoon`), or by any record sync: each one
    /// read is kept on the temp basal it is a part of, which goes final from them once they add up to where it ended -
    /// in its end where the next one started, the amount the patch's (`settleOpenTempBasalEnds`). From our estimate once
    /// its last record is read past without that, once it cannot be told by its records at all, after
    /// `openTempBasalEndMaximumWait` - or before anything that leaves a gap or a dose of another kind after them goes out:
    /// a temp basal that ends with one reads their records with its own, and they go final with it
    /// (`settleTempBasalEnd`). The patch session ending finalizes them with everything else.
    ///
    /// Saved with the doses: a restart reads them as ever. Only under `doseReportLock`.
    private var openTempBasalEnds: [UnfinalizedDose] {
        state.awaitingRecord.filter { dose in
            let ended = dose.snapshot
            return dose.type == .tempBasal && ended.endedOpen && !ended.isFinalized
        }.sorted { $0.startDate < $1.startDate }
    }

    /// Whether any temp basal ended open is waiting on its records
    internal var hasOpenTempBasalEnds: Bool {
        doseReportLock.withLock { !openTempBasalEnds.isEmpty }
    }

    /// Whether `ended`, a temp basal ended open within `openTempBasalEndReadDelay` of `checkedAt`, has its first read
    /// still to come from the command that ended it (`readOpenTempBasalEndsSoon`) - the loop's bolus right behind it
    /// first. Past that, any sync reads it, its other bounds as ever.
    private func awaitsItsReadAfterTheCommand(_ ended: UnfinalizedDose.State, at checkedAt: Date) -> Bool {
        guard ended.endedOpen, !ended.isFinalized, let finishedAt = ended.finishedAt else {
            return false
        }
        // The read it waits for goes by the monotonic clock: a wall clock set back since - the age negative - excludes
        // nothing
        let age = checkedAt.timeIntervalSince(finishedAt)
        return age >= 0 && age < openTempBasalEndReadDelay
    }

    /// How long a temp basal ended open waits for its records at most, read or not: its final is not put off further
    internal static let openTempBasalEndMaximumWait: TimeInterval = awaitingRecordTimeout

    /// `dose`, the running temp basal, ended open at `endedAt` - see `openTempBasalEnds` - its last record `lastRecord`,
    /// ending at `patchEnd` on the patch clock, where known. The caller replaces `state.basalDose`. Only under
    /// `doseReportLock`.
    private func endOpen(_ dose: UnfinalizedDose, at endedAt: Date, patchEnd: Date?, lastRecord: Int?) {
        guard dose.endOpen(at: endedAt, patchEnd: patchEnd, endRecord: lastRecord, at: now()) else {
            return
        }
        state.mutateAwaitingRecord { doses in
            guard !doses.contains(where: { $0 === dose }) else {
                return
            }
            doses.append(dose)
        }

        log.info(
            "Temp basal of \(dose.startDate) ended at \(endedAt), where the next one started: reported ended and mutable until " +
                "its records up to \(lastRecord.map { "#\($0)" } ?? "-") are read"
        )
    }

    /// Whether `dose`, ended open, can be told by its records at all: a patch start to begin at, where it ended on the
    /// patch clock, its last record named
    private static func isReadable(_ ended: UnfinalizedDose.State) -> Bool {
        !ended.recordMatchDisabled && ended.pumpStartTime != nil && ended.patchEndTime != nil && ended.endRecord != nil
    }

    /// What the records of `dose`, ended open - the parts kept on it, and `records` - show it delivered: nil if they do
    /// not add up to where it ended, or it can't be told by its records - see `tempBasalParts`
    private func openTempBasalParts(
        of dose: UnfinalizedDose,
        in records: [GetRecordResponse] = [],
        logging: Bool = false
    ) -> (delivered: Double, duration: TimeInterval, sequences: [Int], end: Date)? {
        let ended = dose.snapshot
        guard Self.isReadable(ended), let patchEnd = ended.patchEndTime else {
            return nil
        }
        guard let parts = tempBasalParts(of: dose, in: records, endingAt: patchEnd, through: ended.endRecord, logging: logging),
              abs(parts.end.timeIntervalSince(patchEnd)) <= RecordSyncer.tempBasalStartTolerance
        else {
            return nil
        }
        return parts
    }

    /// Fixes the final of `dose`, ended open, from `parts` of its records: what they delivered, its end where the next one
    /// started. Only under `doseReportLock`; the caller hands the final over.
    private func finalizeOpen(
        _ dose: UnfinalizedDose,
        from parts: (delivered: Double, duration: TimeInterval, sequences: [Int], end: Date)
    ) -> NewPumpEvent? {
        let ended = dose.snapshot
        log.info(
            "Record(s) \(parts.sequences.map(String.init).joined(separator: ", ")) finalize the temp basal of " +
                "\(dose.startDate) that ended back to back: \(String(format: "%.1f", parts.duration / 60)) min on the patch, " +
                "delivered \(parts.delivered) U by its records - ended at \(ended.observedEndDate.map { "\($0)" } ?? "-"), " +
                "where the next one started"
        )

        // Its records end well before the next one started - more than a cancel, the hand-over and a set take: the patch
        // had stopped it before, which the cancel's answer did not tell. It ends where they do: the host fills the
        // schedule up to the next one's start, exactly - which still starts past everything final.
        let recorded = dose.startDate.addingTimeInterval(parts.duration)
        if let next = ended.observedEndDate, parts.duration >= Self.shortestComputedDuration, !ended.firstSegmentUncertain,
           next.timeIntervalSince(recorded) > Self.openRecordShortfallTolerance
        {
            log.warning(
                "The records of the temp basal of \(dose.startDate) end \(Int(next.timeIntervalSince(recorded))) s before the " +
                    "next one started: the patch had stopped it - it ends at \(recorded), the schedule after it"
            )
            return finalize(dose, deliveredUnits: parts.delivered, endDate: recorded, .byRecord)
        }
        return finalize(dose, deliveredUnits: parts.delivered, .byRecord)
    }

    /// How much sooner than the next one's start the records of a temp basal ended back to back may end, and it still
    /// have run up to the cancel: the cancel's answer (2 to 4 s on a slow link), the hand-over of the state before the set
    /// (3 s at most as a rule), the set's round trip (4 to 9 s, one record's worth), and a second of each clock's
    /// rounding. A host slower to take the state (up to `dosingHandOverTimeout`) can take it past: the temp basal then
    /// ends where its records do, the schedule after it - as the patch ran it, waiting for the set.
    internal static let openRecordShortfallTolerance: TimeInterval = 20

    /// Finalizes the temp basals ended open that can be, the oldest first, up to the first that has to wait - see
    /// `openTempBasalEnds` - every record up to `readThrough` read, or the cursor's. Returns their finals. Only under
    /// `doseReportLock`; the caller hands them over.
    private func settleOpenTempBasalEnds(readThrough: Int? = nil) -> [NewPumpEvent] {
        let readUpTo = max(state.syncedSequenceNumber, readThrough ?? 0)
        let checkedAt = now()
        var events: [NewPumpEvent] = []

        for dose in openTempBasalEnds {
            if let parts = openTempBasalParts(of: dose) {
                if let final = finalizeOpen(dose, from: parts) {
                    events.append(final)
                }
                continue
            }

            let ended = dose.snapshot
            let reason: String
            if !Self.isReadable(ended) {
                if ended.recordMatchDisabled {
                    reason = "its records do not start where its patch start says"
                } else if ended.pumpStartTime == nil {
                    reason = "its patch start is not known, its records can't be told"
                } else {
                    reason = "no record of its end is known"
                }
            } else if let endRecord = ended.endRecord, endRecord <= readUpTo {
                // Logged, why not
                _ = openTempBasalParts(of: dose, logging: true)
                reason = "its records up to \(endRecord) were read, and do not add up to it"
            } else if let finishedAt = ended.finishedAt,
                      checkedAt.timeIntervalSince(finishedAt) >= Self.openTempBasalEndMaximumWait
            {
                reason = "its records were not read within \(Int(Self.openTempBasalEndMaximumWait / 60)) min of its end"
            } else {
                break
            }

            // A temp basal whose command went unanswered, started before it, still unsettled: its final - from a record
            // read later - would go out behind this one's, which the host may then drop. This one waits for it, up to
            // `awaitingRecordMaximumWait`.
            if let pending = state.unconfirmedTempBasal, pending.startDate < dose.startDate, let finishedAt = ended.finishedAt,
               checkedAt.timeIntervalSince(finishedAt) < Self.awaitingRecordMaximumWait
            {
                log.info(
                    "The temp basal of \(dose.startDate) would go final from our estimate, \(reason) - it waits for the one of " +
                        "\(pending.value) U/h whose command went unanswered before it"
                )
                break
            }

            if let final = estimateFinal(dose, because: reason) {
                events.append(final)
            }
        }

        return events
    }

    /// The finals of every temp basal ended open, from our estimate, the oldest first - for a temp basal after them that
    /// goes final so, its records not read on the way. Only under `doseReportLock`; the caller hands them over.
    private func openTempBasalEndsFromEstimate(because reason: String) -> [NewPumpEvent] {
        openTempBasalEnds.compactMap { estimateFinal($0, because: reason) }
    }

    /// Record sync: every record up to `sequence` was read, or given up on - the temp basals ended open that this settles
    /// go final, and out. Before the cursor moves past it.
    internal func settleOpenTempBasalEndsRead(through sequence: Int) {
        doseReportLock.withLock {
            let events = settleOpenTempBasalEnds(readThrough: sequence)
            if !events.isEmpty {
                emitPumpEvents(events)
            }
        }
    }

    /// `record` is of a part of a temp basal of ours that ended open: of this patch, at its rate, starting on its patch
    /// start or where the part kept before it ended. Kept on it - and the temp basals ended open settled, it among them
    /// if its parts now add up to where it ended. Only under `doseReportLock`.
    private func keepPartOfOpenTempBasal(_ record: BasalRecord, response: GetRecordResponse) -> String? {
        guard RecordSyncer.isSamePatch(response.patchId, state.patchId.toUInt64()) else {
            return nil
        }

        let tolerance = RecordSyncer.tempBasalStartTolerance
        for dose in openTempBasalEnds {
            let ended = dose.snapshot
            // Its own records only: numbered up to its last, and none once they reach where it ended - the next one's, at
            // the same rate, may start right there
            guard !ended.recordMatchDisabled, let pumpStartTime = ended.pumpStartTime,
                  RecordSyncer.steps(record.rate) == RecordSyncer.steps(dose.value),
                  ended.endRecord.map({ response.sequence <= $0 }) ?? true
            else {
                continue
            }

            if ended.recordedParts.contains(where: { $0.sequence == response.sequence }) {
                log.info("Record \(response.sequence) is a part of the ended temp basal of \(dose.startDate), kept already")
                return "part of ended temp basal \(dose.startDate)"
            }

            let partStart = ended.recordedParts.last?.end ?? pumpStartTime
            let complete = ended.patchEndTime.map { abs(partStart.timeIntervalSince($0)) <= tolerance && !ended.recordedParts.isEmpty } ?? false
            guard !complete, abs(record.startTime.timeIntervalSince(partStart)) <= tolerance, record.endTime > record.startTime else {
                continue
            }

            let part = UnfinalizedDose.RecordedPart(
                sequence: response.sequence,
                patchId: response.patchId & 0xFFFF,
                start: record.startTime,
                end: record.endTime,
                delivered: record.delivered
            )
            guard dose.keepRecordedPart(part) else {
                continue
            }

            log.info(
                "Record \(response.sequence) is a part of the temp basal of \(dose.startDate) that ended back to back, from " +
                    "\(record.startTime) to \(record.endTime), delivered \(record.delivered) U: kept"
            )

            let events = settleOpenTempBasalEnds(readThrough: response.sequence)
            if !events.isEmpty {
                emitPumpEvents(events)
            }
            return dose.isFinalized ? "finalized temp basal \(dose.startDate)" : "part of ended temp basal \(dose.startDate)"
        }

        return nil
    }

    /// A suspend `dose` a status shows, following the running basal - not a temp basal of ours - while the temp basal
    /// whose command went unanswered is kept and the patch has records past the cursor: its own, if it ran. Reported
    /// now, the suspend has Loop fill up to its start - its watermark past the unanswered one, whose final after it Loop
    /// would not count. Held instead: saved with the state (`heldBasalDoses`) - a restart reports it after all - and left
    /// out of every batch until those records are read, off the queue statuses arrive on once no command is in flight
    /// (a suspend or a resume command reads them itself), then reported - or at once ahead of a set that comes first, or
    /// of anything else a status reports (`releaseHeldForUnconfirmedRead`). A resume after it is held with it
    /// (`holdWithHeldSuspend`), and so is another suspend: neither goes out ahead of it. Unread, it is reported all the
    /// same. The host has no suspend meanwhile - IOB only ever overstated: up to `commandActivityTimeout` waiting for a
    /// command in flight, the wait for the command lock after it, and `tempBasalEndReadBudget` for the reads - some 6 min
    /// at worst, behind a stuck command. Returns false, nothing held: the caller reports it. Only under `doseReportLock`.
    internal func holdForUnconfirmedRead(_ dose: UnfinalizedDose) -> Bool {
        // Behind one held already: released with it, by what releases that one
        if !heldForUnconfirmedRead.isEmpty {
            holdWithTheHeld(dose)
            return true
        }
        guard state.unconfirmedTempBasal != nil, state.currentSequenceNumber > state.syncedSequenceNumber,
              pendingTempBasalEndStorage == nil, state.bolusDose == nil
        else {
            return false
        }
        log.info("Holding the suspend of \(dose.startDate) back until the records of the temp basal whose command went unanswered are read")
        state.heldBasalDoses.append(HeldBasalDose(dose: dose, heldAt: now()))
        heldForUnconfirmedRead.append(dose)

        tempBasalEndQueue.async { [weak self] in
            guard let self else {
                return
            }
            let deadline = Date.now.addingTimeInterval(Self.commandActivityTimeout)
            while self.isCommandActive, Date.now < deadline, !self.backgroundReadsStopped.value {
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard !self.backgroundReadsStopped.value else {
                return
            }
            let held = self.doseReportLock.withLock { !self.heldForUnconfirmedRead.isEmpty }
            guard held else {
                return
            }
            self.withCommandLock {
                RecordSyncer.readInCommand(
                    pumpManager: self,
                    through: self.state.currentSequenceNumber,
                    until: self.now().addingTimeInterval(Self.tempBasalEndReadBudget),
                    of: "the temp basal whose command went unanswered, a suspend held back"
                )
            }
            self.releaseHeldForUnconfirmedRead()
        }
        return true
    }

    /// A resume `dose` - a status's, or a command's - while a suspend is held back by `holdForUnconfirmedRead`: held with
    /// it, reported after it in the batch that releases them. Out ahead of it, iAPS would take the patch to have been
    /// suspended since before its history (oref0 `iob/history`: the earliest resume before the earliest suspend) - and
    /// with `suspend_zeros_iob` zero every temp basal before the resume, and the scheduled basal from 8 h back: IOB far
    /// too low. Loop makes nothing of a resume alone, then pairs it with the suspend - but has neither meanwhile, as iAPS:
    /// IOB only ever overstated. Returns false, nothing held: the caller reports it. Only under `doseReportLock`.
    internal func holdWithHeldSuspend(_ dose: UnfinalizedDose) -> Bool {
        guard dose.type == .resume, !heldForUnconfirmedRead.isEmpty else {
            return false
        }
        holdWithTheHeld(dose)
        return true
    }

    /// `dose` held back after those `holdForUnconfirmedRead` holds, released with them - from when the first was held: it
    /// goes for good no earlier than they do (`dropExpiredFinals`). Only under `doseReportLock`.
    private func holdWithTheHeld(_ dose: UnfinalizedDose) {
        log.info("Holding the \(dose.type.rawValue) of \(dose.startDate) back with the suspend held for the records of the temp basal whose command went unanswered")
        let first = heldForUnconfirmedRead.first
        let heldAt = state.heldBasalDoses.first { $0.dose === first }?.heldAt ?? now()
        state.heldBasalDoses.append(HeldBasalDose(dose: dose, heldAt: heldAt))
        heldForUnconfirmedRead.append(dose)
    }

    /// The suspend held back by `holdForUnconfirmedRead`, if any - in a command - reported once the records of the temp
    /// basal whose command went unanswered are read, as a suspend command reads them, or not to be. Read whether held
    /// back or not - a suspend reported, the hold refused (a bolus running at the halt, say): the unanswered one final
    /// from its own ahead of the resume, not left to a sync after it. Nothing to read - none kept, or read up - nothing is.
    private func releaseHeldAfterUnconfirmedRead() {
        readUnconfirmedTempBasalsRecords(through: state.currentSequenceNumber)
        releaseHeldForUnconfirmedRead()
    }

    /// The suspend held back by `holdForUnconfirmedRead`, if any, reported - with what was held with it, in order - its
    /// records read, or not to be: before a set, a resume command, or anything else a status reports goes out
    internal func releaseHeldForUnconfirmedRead() {
        let released = doseReportLock.withLock { () -> Bool in
            guard !heldForUnconfirmedRead.isEmpty else {
                return false
            }
            heldForUnconfirmedRead = []
            return true
        }
        guard released else {
            return
        }
        emitPumpEvents([])
        notifyStateDidChange()
    }

    /// The patch session ends: the records the suspend held back by `holdForUnconfirmedRead` waits on are out of reach.
    /// It is no longer held back - nor what was held with it: the batch the session's end hands over carries them, ahead
    /// of the suspend or the resume it reports. Only under `doseReportLock`.
    private func releaseHeldForTheSessionEnd() {
        guard !heldForUnconfirmedRead.isEmpty else {
            return
        }
        log.info("The patch session ends: what was held back for the records of the temp basal whose command went unanswered goes out now")
        heldForUnconfirmedRead = []
    }

    /// The records up to `last` - the one the cancel ahead of a set named, else the newest the patch has - read in the
    /// command, in order from the cursor, before the set, the suspend or the resume is reported: the temp basal whose
    /// command went unanswered, kept, goes final from its own - or is dropped, or split - in a batch ahead of that
    /// report. A temp basal reported running, or a suspend - Loop fills up to its start - has Loop's watermark past the
    /// unanswered one: final behind it, Loop would not count it (`warnIfBehindWhatIsFinal`). Only with no other basal of
    /// ours waiting on its end - nothing else the reads would settle out of turn - and no bolus running. The host has the
    /// state first: killed during the reads, the app comes back with the cancel's outcome and the unanswered one kept, no
    /// set pending. Unread - the link slow, the budget spent - the set goes out all the same, and the record is read
    /// after the command, as before.
    private func readUnconfirmedTempBasalsRecords(through last: Int) {
        let due = doseReportLock.withLock { () -> Bool in
            let running = state.basalDose
            return state.unconfirmedTempBasal != nil && pendingTempBasalEndStorage == nil
                && (running.type != .tempBasal || running.isFinished) && state.bolusDose == nil
                && last > state.syncedSequenceNumber
        }
        guard due else {
            return
        }

        handOverState(before: "reading the records of the temp basal whose command went unanswered")
        RecordSyncer.readInCommand(
            pumpManager: self,
            through: last,
            until: now().addingTimeInterval(Self.tempBasalEndReadBudget),
            of: "the temp basal whose command went unanswered"
        )
    }

    /// The newest record the temp basals ended open wait on: the last one of the latest. Nil, none waits.
    internal var lastRecordOfOpenTempBasalEnds: Int? {
        doseReportLock.withLock {
            (openTempBasalEnds + [state.unconfirmedTempBasal].compactMap { $0 }).compactMap { $0.snapshot.endRecord }.max()
        }
    }

    /// Reads the records of the temp basals ended open (`openTempBasalEnds`), up to the newest one they wait on, off the
    /// command's thread: `openTempBasalEndReadDelay` from now, once no command is in flight - the loop's bolus, right behind
    /// the temp basal that ended the last of them, has the link first, and is held up by no record. As a record sync
    /// does: not while a bolus runs, and yielding to a command between two records - what is not read now, a later sync
    /// reads.
    private func readOpenTempBasalEndsSoon(after delay: TimeInterval? = nil) {
        let delay = delay ?? openTempBasalEndReadDelay
        let read = { [weak self] in
            guard let self else {
                return
            }

            let deadline = Date.now.addingTimeInterval(Self.commandActivityTimeout)
            while self.isCommandActive, Date.now < deadline, !self.backgroundReadsStopped.value {
                Thread.sleep(forTimeInterval: 0.2)
            }

            guard !self.backgroundReadsStopped.value, let through = self.lastRecordOfOpenTempBasalEnds else {
                return
            }
            // No record is read while a bolus runs: once it is over (`notifyStateDidChange`)
            let bolusRuns = self.doseReportLock.withLock { () -> Bool in
                guard self.state.bolusDose != nil else {
                    return false
                }
                self.openTempBasalEndReadAwaitsBolus = true
                return true
            }
            guard !bolusRuns else {
                self.log.info("A bolus is running: the records of the temp basals ended back to back are read once it is over")
                return
            }
            RecordSyncer.syncRecords(pumpManager: self, trigger: .tempBasalEnds, through: through)
        }

        if delay > 0 {
            tempBasalEndQueue.asyncAfter(deadline: .now() + delay, execute: read)
        } else {
            tempBasalEndQueue.async(execute: read)
        }
    }

    /// Loop's watermark as the state was saved - see `MedtrumPumpState.loopWatermark` - or, saved before it was kept, as
    /// the finals the host has yet to confirm make it: the rest is not known
    private func noteFinalsFromLastRun() {
        doseReportLock.withLock {
            if state.loopWatermark == nil {
                // A held suspend counts with its start: Loop has it from there, ended by what follows
                let finals = state.awaitingRecord.filter { $0.type == .tempBasal }.compactMap(\.finalEndDate)
                let suspends = state.heldBasalDoses.filter { $0.dose.type == .suspend }.map(\.dose.startDate)
                state.loopWatermark = (finals + suspends).max()
            }
            loopWatermarkModel = LoopWatermark(date: state.loopWatermark)
        }
    }

    /// For tests: the reads queued on `tempBasalEndQueue` - after a delay, behind a command or a bolus - give up, and none
    /// starts from here on: none outlives the scenario that queued it, into the record sync's run state of the next
    func stopBackgroundReads() {
        backgroundReadsStopped.value = true
        tempBasalEndQueue.sync {}
    }

    /// The bolus a read of the temp basals ended open waited for is over: read them now, once
    private func readOpenTempBasalEndsAfterBolus() {
        let due = doseReportLock.withLock { () -> Bool in
            // A temp basal's records read as it ended - a halt with the bolus's completion: theirs read with them
            guard openTempBasalEndReadAwaitsBolus, state.bolusDose == nil, pendingTempBasalEndStorage == nil else {
                return false
            }
            openTempBasalEndReadAwaitsBolus = false
            return lastRecordOfOpenTempBasalEnds.map { $0 > state.syncedSequenceNumber } ?? false
        }
        if due {
            readOpenTempBasalEndsSoon(after: 0)
        }
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
        sentUptime: TimeInterval?,
        sequenceAtSend: Int,
        priorSegmentStart: Date?,
        basalBefore: Date?,
        basalBeforeOnPatch: Date?
    ) {
        dose.noteCommand(
            sentAt: sentAt,
            uptime: sentUptime,
            sequence: sequenceAtSend,
            priorSegmentStart: priorSegmentStart,
            basalBefore: basalBefore,
            basalBeforeOnPatch: basalBeforeOnPatch
        )

        doseReportLock.withLock {
            keepUnconfirmed(dose, .unanswered)
        }

        log.error(
            "Temp basal of \(dose.value) U/h went out unanswered: kept unreported until a status shows it running, or its " +
                "record turns up"
        )
        notifyStateDidChange()
    }

    /// `dose`, its command noted, is the unconfirmed temp basal from now on - uncertain for `cause` - and no longer
    /// pending: after it is kept, as `rawValue` reads them. Only under `doseReportLock`.
    private func keepUnconfirmed(_ dose: UnfinalizedDose, _ cause: UncertainDelivery.Cause) {
        if let superseded = state.unconfirmedTempBasal {
            log.warning("The unconfirmed temp basal of \(superseded.value) U/h sent \(superseded.sentAt.map { "\($0)" } ?? "-") is superseded")
            settleUncertainDeliveries(of: superseded, .notConfirmed)
        }
        state.unconfirmedTempBasal = dose
        state.pendingTempBasal = nil
        noteUncertainDelivery(.tempBasal, cause, of: dose)
        // Those skipped before were written before it went out
        state.skippedRecordSequences = []
        // The patch may be running it: the next temp basal cancels first
        state.basalState = .tempBasal
    }

    /// In a new run's state, a SetTempBasal still pending went out and the app was gone before its answer: the patch may
    /// be running it. Kept from here on as one whose command went unanswered is (`keepUnconfirmedTempBasal`) - unreported
    /// until a status or its record shows it ran, dropped if every record shows it never did - dated from when it went
    /// out. The temp basal the cancel before it ended, still running in the state, ends at that cancel, final from our
    /// estimate as with any set gone unanswered - the scheduled basal after it held back for the first batch
    /// (`heldBasalDoses`). Not if its dose was registered: the state was saved as it was, read in part before.
    private func takeOverPendingTempBasal() {
        doseReportLock.withLock {
            guard let pending = state.pendingTempBasal else {
                return
            }

            let registered = ([state.basalDose, state.unconfirmedTempBasal].compactMap { $0 } + state.awaitingRecord).contains { dose in
                dose.type == .tempBasal && dose.sentAt == pending.sentAt
            }
            guard !registered else {
                log.info("The temp basal of \(pending.unitsPerHour) U/h sent at \(pending.sentAt) was registered already")
                state.pendingTempBasal = nil
                return
            }

            let running = state.basalDose
            if let cancelledAt = pending.cancelledAt, running.type == .tempBasal, !running.isFinished,
               running.startDate < pending.sentAt
            {
                // Kept with its final until the host confirms it: the first batch carries it
                _ = endTempBasalFromEstimate(
                    endedAt: cancelledAt,
                    because: "the app stopped while the temp basal set after its cancel awaited its answer"
                )
                let scheduled = UnfinalizedDose(
                    basalRate: state.currentBaseBasalRate,
                    insulinType: state.insulinType,
                    startDate: cancelledAt
                )
                state.heldBasalDoses.append(HeldBasalDose(dose: scheduled, heldAt: now()))
                state.basalDose = scheduled
            }

            let dose = UnfinalizedDose(
                tempRate: pending.unitsPerHour,
                duration: pending.duration,
                insulinType: state.insulinType,
                automatic: pending.automatic,
                confirmation: .uncertain,
                startDate: pending.sentAt
            )
            dose.noteCommand(
                sentAt: pending.sentAt,
                uptime: nil,
                sequence: pending.sequenceAtSend,
                priorSegmentStart: pending.priorSegmentStart,
                basalBefore: pending.cancelledAt ?? reportedBasalStart,
                // The cancel's segment, as its answer said - else the running basal's own
                basalBeforeOnPatch: pending.cancelledAt != nil ? pending.cancelSegmentStart : reportedBasalPatchStart
            )
            keepUnconfirmed(dose, .appRestarted)
            log.error(
                "The app stopped while the temp basal of \(pending.unitsPerHour) U/h sent at \(pending.sentAt) awaited its " +
                    "answer: it may be running. Kept unreported until a status shows it running, or its record turns up"
            )
        }
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
        let unconfirmed = pending.snapshot
        guard let later = unconfirmed.laterSegmentStart else {
            return pending.estimatedEndDate
        }
        // From the basal before it, on each clock alone - see `unansweredStartOffset` - else through the skew
        guard let basalBefore = unconfirmed.basalBefore, let onPatch = unconfirmed.basalBeforeOnPatch else {
            return patchTimeOnOurClock(later, notBefore: pending.startDate, notAfter: pending.estimatedEndDate)
        }
        let end = basalBefore.addingTimeInterval(later.timeIntervalSince(onPatch))
        return max(min(end, pending.estimatedEndDate), pending.startDate)
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
            // Begun after its command went out - was written, past the wait for the host - by more than the slack, told
            // skew-free where it can be
            let writtenAt = unconfirmed.writtenAt ?? unconfirmed.sentAt ?? pending.startDate
            let afterTheCommand = unansweredStartOffset(of: unconfirmed, sentAt: writtenAt, patchTime: start) > Self.unansweredStartSlack
            guard let prior = unconfirmed.priorSegmentStart, start > prior, afterTheCommand,
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

    /// A command is cancelling `dose`, the temp basal running: from the cancel on it reports what follows it - the
    /// temp basal it sets after it, back to back, or the scheduled basal, whatever the outcome - so the scheduled basal a
    /// status shows meanwhile, the second or so between the cancel and the set, is not taken as its end. Only under
    /// `doseReportLock`.
    internal func isCancelInFlight(of dose: UnfinalizedDose) -> Bool {
        tempBasalCancelInFlight === dose
    }

    /// A status received at `receivedAt` showed the schedule from `basal`'s start while the cancel was in flight: set
    /// aside, the latest only, should the cancel fail - see `takeScheduleSetAsideForTheCancel`. Only under `doseReportLock`.
    internal func setAsideForTheCancel(_ basal: BasalData, receivedAt: Date, receivedUptime: TimeInterval) {
        scheduleSetAsideForTheCancel = (basal, receivedAt, receivedUptime)
    }

    /// The cancel failed: no longer in flight, and the schedule a status showed meanwhile, if any, is taken as any status's
    /// - it may have been the patch's own, or the cancel's with its answer lost. On the command's thread.
    private func takeScheduleSetAsideForTheCancel() {
        let setAside = doseReportLock.withLock { () -> (basal: BasalData, receivedAt: Date, receivedUptime: TimeInterval)? in
            tempBasalCancelInFlight = nil
            defer { scheduleSetAsideForTheCancel = nil }
            return scheduleSetAsideForTheCancel
        }
        guard let setAside else {
            return
        }
        StateSyncer.replayScheduleSetAside(
            setAside.basal,
            receivedAt: setAside.receivedAt,
            receivedUptime: setAside.receivedUptime,
            pumpManager: self
        )
    }

    /// A segment the patch reported, from a status or an answer - see `MedtrumPumpState.lastSegmentStart`. Only under
    /// `doseReportLock`, which orders it against the command that reads it.
    internal func noteSegmentStart(_ start: Date) {
        state.lastSegmentStart = max(state.lastSegmentStart ?? start, start)
    }

    /// Drops the unconfirmed temp basal, never reported. Only under `doseReportLock`.
    private func dropUnconfirmedTempBasal(because reason: String, neverRan: Bool = false) {
        guard let dose = state.unconfirmedTempBasal else {
            return
        }

        log.warning("Dropping the temp basal of \(dose.value) U/h whose command went unanswered, \(reason)")
        settleUncertainDeliveries(of: dose, neverRan ? .neverRan : .notConfirmed)
        state.unconfirmedTempBasal = nil
    }

    /// `pending`, the unconfirmed temp basal, a status showed running from `shownFrom` - late, over by then - and every
    /// record since it ended was read, none its: it ran, how long and what it delivered unknown. Not dropped as never
    /// run, silently: the host is warned of uncertain delivery, and the settings show it not counted. Not reported from
    /// our estimate either: its record, authoritative, matched nothing - an estimate, dated over a span the status and
    /// what ended it bound at best, would go out behind what the host has after it, a suspend say: Loop would not count
    /// it, and iAPS would count it over what the host already has there. Only under `doseReportLock`.
    private func dropUnconfirmedTempBasalShownRunning(_ pending: UnfinalizedDose, from shownFrom: Date) {
        log.error(
            "The temp basal of \(pending.value) U/h whose command went unanswered ran - a status showed it from \(shownFrom) " +
                "- and no record read since it ended is its: what it delivered is not counted"
        )
        let key = UncertainDelivery.DoseKey(pending)
        state.mutateUncertainDeliveries { deliveries in
            for index in deliveries.indices where deliveries[index].kind == .tempBasal && deliveries[index].isOf(key) &&
                !deliveries[index].isSettled
            {
                deliveries[index].outcome = .notCounted
                deliveries[index].settledAt = now()
            }
        }
        state.unconfirmedTempBasal = nil
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(self, didError: .uncertainDelivery)
        }
    }

    /// A status received at `receivedAt` shows a temp basal segment, `basal`: one of ours whose cancel went unanswered
    /// still runs; one whose command went unanswered, started since the last segment known before it, runs - reported
    /// from its start on. Any other temp segment is not ours: it changes nothing, but may end the unconfirmed one.
    internal func followTempBasalSegment(_ basal: BasalData, fullSync: Bool, receivedAt: Date, receivedUptime: TimeInterval) {
        doseReportLock.withLock {
            let dose = state.basalDose
            let running = dose.snapshot

            // A temp basal runs: the next one cancels first. In one step with the dose a command set - not over the
            // suspend one just recorded, as a status from before it lands: commands would go to a suspended patch.
            if dose.type != .suspend {
                state.basalState = .tempBasal
            }
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
                    // Saved by a build that did not keep the answer's: a later segment's, maybe
                    dose.markFirstSegmentUncertain()
                    log.info("Adopted patch start \(basal.startTime) for the running temp basal")
                    dose.noteStatusDelivery(basal.delivery, receivedAt: receivedAt)
                    return
                }
            }

            guard let pending = state.unconfirmedTempBasal else {
                let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
                if dose.type == .tempBasal, isOurRate, !running.isFinished, let pumpStartTime = running.pumpStartTime,
                   basal.startTime > pumpStartTime,
                   Self.isPatchMidnight(basal.startTime, utcOffset: utcOffset) || running.recordMatchDisabled
                {
                    // The patch restarts the running segment at patch-local midnight, and on a basal profile change
                    log.info(
                        "Status shows the temp basal of \(dose.startDate) restarted by the patch at \(basal.startTime) " +
                            "(patch-local midnight or a profile change), still running"
                    )
                } else if dose.type == .tempBasal, isOurRate, !running.isFinished {
                    log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime), not our temp basal")
                } else {
                    noteSegmentOfNoTempBasalOfOurs(basal, receivedAt: receivedAt, receivedUptime: receivedUptime)
                }
                return
            }

            if !confirmUnconfirmedTempBasal(pending, shownBy: basal, receivedAt: receivedAt) {
                noteSegmentAfterUnconfirmedTempBasal(startingAt: basal.startTime, receivedAt: receivedAt, receivedUptime: receivedUptime)
            }
        }
    }

    /// A status received at `receivedAt` shows a temp basal segment, `basal`, with no unconfirmed temp basal kept, that is
    /// not the one of ours running: unless it is the one whose set is out (`pendingTempBasal`), one of ours that ended
    /// (`awaitingRecord`), or older than a segment known since - stale - the patch runs a temp basal the driver has no dose
    /// of. One set as the app was gone before it was saved, say. What it delivers is counted nowhere: the host is warned
    /// of uncertain delivery, once per segment, and the settings say so. Only under `doseReportLock`.
    private func noteSegmentOfNoTempBasalOfOurs(_ basal: BasalData, receivedAt: Date, receivedUptime: TimeInterval) {
        let tolerance = RecordSyncer.tempBasalStartTolerance
        let running = state.basalDose.snapshot

        // The old patch's, heard from after its session ended - or a patch whose session has not started: none of its
        // temp basals are this session's to count
        guard !state.patchSessionEnded, !state.patchId.isEmpty,
              UInt64(basal.patchId) & 0xFFFF == state.patchId.toUInt64() & 0xFFFF
        else {
            log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime) of patch \(basal.patchId), no session's of ours")
            return
        }
        if let pending = state.pendingTempBasal, RecordSyncer.steps(basal.rate) == RecordSyncer.steps(pending.unitsPerHour) {
            log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime): the temp basal being set")
            return
        }
        // Received before the running basal was put in place - a suspend or a schedule one a command just set has no
        // command time of its own - on the monotonic clock, which a change of the wall clock does not move: one put in
        // place in an earlier run, no status of this run is before. Or older than a segment known since: stale.
        let predatesRunningBasal = running.sentAt == nil && state.basalDoseSince.map { receivedUptime < $0 } == true
        if Self.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime) ||
            predatesRunningBasal || state.lastSegmentStart.map({ basal.startTime < $0 }) == true
        {
            log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime), from before the latest one known")
            return
        }
        if state.awaitingRecord.contains(where: { dose in
            dose.type == .tempBasal && dose.pumpStartTime.map { abs(basal.startTime.timeIntervalSince($0)) <= tolerance } == true
        }) {
            log.info("Status shows a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime): a temp basal of ours that ended")
            return
        }

        log.error(
            "Status shows the patch running a \(basal.type) segment at \(basal.rate) U/h from \(basal.startTime) that is none " +
                "of ours: what it delivers is not counted"
        )
        guard !unknownTempBasalSegments.contains(basal.startTime) else {
            return
        }
        unknownTempBasalSegments.insert(basal.startTime)

        let start = patchTimeOnOurClock(basal.startTime, notBefore: .distantPast, notAfter: receivedAt)
        var delivery = UncertainDelivery(
            kind: .tempBasal,
            cause: .unknownSegment,
            sentAt: start,
            amount: basal.rate,
            notedAt: now()
        )
        // Nothing of ours settles it
        delivery.outcome = .notCounted
        delivery.settledAt = now()
        state.mutateUncertainDeliveries { deliveries in
            guard !deliveries.contains(where: { $0.cause == .unknownSegment && abs($0.sentAt.timeIntervalSince(start)) < 60 }) else {
                return
            }
            deliveries.append(delivery)
            while deliveries.count > Self.uncertainDeliveriesKept {
                deliveries.remove(at: deliveries.firstIndex(where: \.isSettled) ?? 0)
            }
        }

        pumpDelegate.notify { delegate in
            guard let delegate = delegate else {
                self.log.warning("No pump delegate, not notifying...")
                return
            }

            delegate.pumpManager(self, didError: .uncertainDelivery)
        }
    }

    /// The segment a status shows is the unconfirmed temp basal's: at its rate, started no earlier than the last segment
    /// known before its command went out (and before one a later command started) - on the patch clock, exactly. It
    /// runs: reported from its start on - or, the segment a restart of it, from its command on, and finalized from our
    /// estimate. Only under `doseReportLock`.
    /// The same second counts: the patch can start the temp basal in the second the cancel's STANDARD began, and a
    /// segment of another type starting then can only be the one that replaced it. A late status of it - a later
    /// segment known since, a later command's - changes nothing: its record settles it. Returns whether it was the one.
    private func confirmUnconfirmedTempBasal(
        _ pending: UnfinalizedDose,
        shownBy basal: BasalData,
        receivedAt: Date
    ) -> Bool {
        let unconfirmed = pending.snapshot
        // A segment known to have begun since it - a later command's - and this status says nothing of what runs now: it
        // is late, a notification of before, and running from here the temp basal would end the one running now
        let isStale = state.lastSegmentStart.map { basal.startTime < $0 } == true
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

        // Its segment, but late: it ran, and ended by the segment known since - its record settles it, kept as it is.
        // Shown so: should no record turn out to be its, it is not dropped as never run (`finalizeOverdueAwaitingDoses`).
        guard !isStale else {
            log.warning(
                "Status shows the segment of the temp basal of \(pending.value) U/h whose command went unanswered, from " +
                    "\(basal.startTime) - late, a later segment is known: it ran, its record settles it"
            )
            pending.noteShownRunning(from: basal.startTime)
            return true
        }
        // The same over a suspend: a halted patch runs no temp basal - the segment began before the halt, which ended it.
        // Taken to run from here, it would be dated over the suspension, its record clamped to its start. And the same
        // with a segment known to have begun after it (`laterSegmentStart`), its own start before that one: ended by
        // then - a halt's, say, the patch resumed since by a command whose answer told no segment of its own.
        guard state.basalDose.type != .suspend, unconfirmed.laterSegmentStart == nil else {
            log.warning(
                "Status shows the segment of the temp basal of \(pending.value) U/h whose command went unanswered, from " +
                    "\(basal.startTime) - late, " +
                    (state.basalDose.type == .suspend ? "the patch suspended since" : "a segment begun after it is known") +
                    ": it ran, its record settles it"
            )
            pending.noteShownRunning(from: basal.startTime)
            return true
        }

        let sentAt = unconfirmed.sentAt ?? pending.startDate
        // Started well after the command, the segment is a restart of it - at patch-local midnight, on a profile
        // change - not its first: it ran from the command on, and its first record ends at the restart
        let restarted = unansweredStartOffset(of: unconfirmed, sentAt: sentAt, patchTime: basal.startTime) > Self.recordMatchWindow
        let start = restarted ? sentAt : unansweredStart(of: unconfirmed, sentAt: sentAt, patchTime: basal.startTime, notAfter: receivedAt)
        let tempBasalDose = UnfinalizedDose(
            tempRate: pending.value,
            duration: pending.estimatedEndDate.timeIntervalSince(pending.startDate),
            insulinType: pending.insulinType,
            automatic: pending.automatic,
            startDate: start
        )
        tempBasalDose.noteCommand(sentAt: sentAt, uptime: unconfirmed.sentUptime, sequence: unconfirmed.sequenceAtSend ?? 0)
        if let writtenAt = unconfirmed.writtenAt {
            tempBasalDose.noteWritten(at: writtenAt, uptime: unconfirmed.writtenUptime)
        }
        tempBasalDose.setPumpStartTime(basal.startTime)
        // Dated from a status, its start within the match window of its command: nothing to time a stop from
        tempBasalDose.markFirstSegmentUncertain()

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
    /// `ending`: in the read of a temp basal's end that leaves a gap - see `settleTempBasalEnd` - the basal after it in
    /// place: it ended by now, if it ran - it is never put back as running.
    private func finalizeUnconfirmedTempBasal(
        from record: BasalRecord,
        sequence: Int,
        ending: Bool = false
    ) -> (outcome: String, events: [NewPumpEvent])? {
        guard let pending = state.unconfirmedTempBasal else {
            return nil
        }

        let unconfirmed = pending.snapshot
        let sentAt = unconfirmed.sentAt ?? pending.startDate
        guard RecordSyncer.steps(record.rate) == RecordSyncer.steps(pending.value),
              abs(unansweredStartOffset(of: unconfirmed, sentAt: sentAt, patchTime: record.startTime)) <= Self.recordMatchWindow,
              unconfirmed.priorSegmentStart.map({ record.startTime >= $0 }) ?? true,
              unconfirmed.laterSegmentStart.map({ record.startTime < $0 }) ?? true
        else {
            return nil
        }

        let span = unansweredSpan(of: unconfirmed, sentAt: sentAt, patchTime: record.startTime, notAfter: now(), lasting: record.duration)
        let start = span.start
        let tempBasalDose = UnfinalizedDose(
            tempRate: pending.value,
            duration: pending.estimatedEndDate.timeIntervalSince(pending.startDate),
            insulinType: pending.insulinType,
            automatic: pending.automatic,
            startDate: start
        )
        tempBasalDose.noteCommand(sentAt: sentAt, uptime: nil, sequence: unconfirmed.sequenceAtSend ?? 0)
        // On the wall clock alone, as its command's
        if let writtenAt = unconfirmed.writtenAt {
            tempBasalDose.noteWritten(at: writtenAt, uptime: nil)
        }
        tempBasalDose.setPumpStartTime(record.startTime)

        let utcOffset = state.patchUTCOffset ?? TimeInterval(TimeZone.current.secondsFromGMT())
        if unconfirmed.recordMatchDisabled || Self.isPatchMidnight(record.endTime, utcOffset: utcOffset) {
            return runSplitUnconfirmedTempBasal(pending, as: tempBasalDose, shownBy: record, sequence: sequence, endedBy: ending ? now() : nil)
        }

        let endDate = span.end
        tempBasalDose.finish(endDate >= tempBasalDose.estimatedEndDate ? .completed : .cancelled, endedAt: endDate, at: now())
        state.unconfirmedTempBasal = nil

        log.info(
            "Record \(sequence) is the temp basal of \(pending.value) U/h whose command went unanswered: it ran " +
                "\(String(format: "%.1f", record.duration / 60)) min from \(record.startTime), delivered \(record.delivered) U"
        )
        let events = finalize(tempBasalDose, deliveredUnits: record.delivered, endDate: endDate, .byRecord).map { [$0] } ?? []
        if span.compressed {
            // All of its amount in less time than it ran: counted so by iAPS, maybe not by Loop
            warnNotCounted(
                tempBasalDose,
                because: "fitted into \(Int(endDate.timeIntervalSince(start))) s before a basal dose the host has, after running " +
                    "\(Int(record.duration)) s"
            )
        } else {
            warnIfBehindWhatIsFinal(tempBasalDose)
        }
        return ("finalized unconfirmed temp basal \(start)", events)
    }

    /// `dose`, the temp basal whose command went unanswered, is reported only now, starting before Loop's watermark - a
    /// later temp basal reported meanwhile, say, its gap since the one before filled final up to its start (see
    /// `LoopWatermark`). Loop stores no basal dose starting before it: it may never count this one. iAPS does. The host
    /// is warned of uncertain delivery, and the settings show it not counted. Only under `doseReportLock`.
    private func warnIfBehindWhatIsFinal(_ dose: UnfinalizedDose) {
        guard let watermark = state.loopWatermark, dose.startDate < watermark else {
            return
        }
        warnNotCounted(dose, because: "starting before Loop's watermark, \(watermark)")
    }

    /// The host is warned that `dose`, the temp basal whose command went unanswered, may not be counted, `reason` - and the
    /// settings show it not counted. Only under `doseReportLock`.
    private func warnNotCounted(_ dose: UnfinalizedDose, because reason: String) {
        log.error(
            "The temp basal of \(dose.value) U/h whose command went unanswered, from \(dose.startDate), is reported only now, " +
                "\(reason): the host may not count it"
        )
        let key = UncertainDelivery.DoseKey(dose)
        state.mutateUncertainDeliveries { deliveries in
            for index in deliveries.indices where deliveries[index].kind == .tempBasal && deliveries[index].isOf(key) {
                deliveries[index].outcome = .notCounted
            }
        }
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(self, didError: .uncertainDelivery)
        }
    }

    /// `record`, the unconfirmed temp basal's, ends where the patch split it - at patch-local midnight, or on a profile
    /// change: only a part of it, but proof it ran. It is reported from the record's start on, and no record finalizes
    /// it: it runs until it ended at the latest (`unconfirmedTempBasalEnd`) - final at once from our estimate if that
    /// has passed. Only under `doseReportLock`.
    private func runSplitUnconfirmedTempBasal(
        _ pending: UnfinalizedDose,
        as tempBasalDose: UnfinalizedDose,
        shownBy record: BasalRecord,
        sequence: Int,
        endedBy latest: Date? = nil
    ) -> (outcome: String, events: [NewPumpEvent]) {
        tempBasalDose.disableRecordMatch()
        tempBasalDose.markFirstSegmentUncertain()
        // Ended by `latest`, and never past the start of a basal dose the host has after it
        let nextStart = reportedBasalDoses.filter { $0.startDate > tempBasalDose.startDate }.map(\.startDate).min()
        let end = [unconfirmedTempBasalEnd(pending), latest, nextStart].compactMap { $0 }.min() ?? unconfirmedTempBasalEnd(pending)
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
            warnIfBehindWhatIsFinal(tempBasalDose)
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
        return ("part of split unconfirmed temp basal \(tempBasalDose.startDate)", events)
    }

    /// How much later than its command went out `patchTime` is, of the temp basal of `unconfirmed` whose command went
    /// unanswered - told on each clock alone where the basal before it is known on both (`basalBefore`,
    /// `basalBeforeOnPatch`): from there to `patchTime` on the patch clock, less from there to its command on ours.
    /// Through the skew otherwise.
    private func unansweredStartOffset(of unconfirmed: UnfinalizedDose.State, sentAt: Date, patchTime: Date) -> TimeInterval {
        guard let basalBefore = unconfirmed.basalBefore, let onPatch = unconfirmed.basalBeforeOnPatch else {
            return patchTime.timeIntervalSince(sentAt.addingTimeInterval(state.patchClockSkew))
        }
        return patchTime.timeIntervalSince(onPatch) - sentAt.timeIntervalSince(basalBefore)
    }

    /// When the temp basal of `unconfirmed` whose command went unanswered started, on our clock, its segment or record
    /// starting at `patchTime`: from the basal before it as `unansweredStartOffset` tells it, else through the skew -
    /// within `unansweredStartFloor` and `notAfter`, and before anything the host has after it
    private func unansweredStart(of unconfirmed: UnfinalizedDose.State, sentAt: Date, patchTime: Date, notAfter: Date) -> Date {
        unansweredSpan(of: unconfirmed, sentAt: sentAt, patchTime: patchTime, notAfter: notAfter, lasting: 0).start
    }

    /// Where the temp basal of `unconfirmed` whose command went unanswered ran, `duration` long from `patchTime` on the
    /// patch clock, on ours: `unansweredStart`, and its end - never over a basal dose the host has that came after its
    /// command: the host would trim that one to its start, and move its watermark past it - Loop then loses the running
    /// temp basal. Dated into one, it is moved earlier to end where that one starts; with no room for all of it since
    /// `unansweredStartFloor`, it is fitted into what there is, its amount kept - `compressed`. A status shows it running
    /// now (`duration` 0): just before such a dose, if at all after it.
    private func unansweredSpan(
        of unconfirmed: UnfinalizedDose.State,
        sentAt: Date,
        patchTime: Date,
        notAfter: Date,
        lasting duration: TimeInterval
    ) -> (start: Date, end: Date, compressed: Bool) {
        let floor = unansweredStartFloor(of: unconfirmed, sentAt: sentAt)
        var start: Date
        if let basalBefore = unconfirmed.basalBefore, let onPatch = unconfirmed.basalBeforeOnPatch {
            start = max(min(basalBefore.addingTimeInterval(patchTime.timeIntervalSince(onPatch)), notAfter), floor)
        } else {
            start = patchTimeOnOurClock(patchTime, notBefore: floor, notAfter: notAfter)
        }

        // The first thing the host has that came after its command
        guard let later = reportedBasalDoses.filter({ $0.startDate > floor }).map(\.startDate).min(),
              start.addingTimeInterval(duration) > later
        else {
            return (start, start.addingTimeInterval(duration), false)
        }

        guard duration >= Self.shortestComputedDuration else {
            start = max(floor, min(start, later.addingTimeInterval(-Self.afterFinal)))
            return (start, start, false)
        }
        let room = later.timeIntervalSince(floor)
        guard room < duration else {
            return (later.addingTimeInterval(-duration), later, false)
        }
        // Short by no more than the two clocks tell apart: fitted, its amount kept, nothing the host would miss
        guard duration - room > Self.patchEndTolerance else {
            return (floor, later, false)
        }
        return (floor, later, true)
    }

    /// The basal doses the host has: the running one unless a placeholder, those waiting on their record or final, and
    /// the suspends and resumes held back - the host gets them all the same, after what goes out meanwhile: a resume
    /// held with its suspend the running one, that suspend bounds the temp basal before it, not the resume
    private var reportedBasalDoses: [UnfinalizedDose] {
        (state.basalDoseIsPlaceholder ? [] : [state.basalDose]) + state.awaitingRecord.filter { $0.type != .bolus } +
            state.heldBasalDoses.map(\.dose).filter { $0.type == .suspend || $0.type == .resume }
    }

    /// Where the running basal of `reportedBasalStart` began on the patch clock, where known - the segment the cancel, the
    /// resume or the status that put it in place showed
    private var reportedBasalPatchStart: Date? {
        reportedBasalStart != nil ? state.basalDose.pumpStartTime : nil
    }

    /// The start of the running basal, if it is of another kind than a temp basal and the host was told of it - not a
    /// placeholder (`MedtrumPumpState.basalDoseIsPlaceholder`)
    private var reportedBasalStart: Date? {
        state.basalDose.type != .tempBasal && !state.basalDoseIsPlaceholder ? state.basalDose.startDate : nil
    }

    /// How far after a dose of another basal kind a temp basal is dated at the earliest, when its start would be the same
    /// instant: just after, the order unmistakable
    private static let afterFinal: TimeInterval = 0.001

    /// The earliest a basal dose following `dose`, the running one, is dated: just after it if it is a resume - one may
    /// be dated up to a second ahead (`earliestResume`), and a suspend or a temp basal dated before it, or at its instant,
    /// would have oref0 pair the suspend before it with it as well, or Loop order the two either way. Its start otherwise.
    internal static func earliestAfter(_ dose: UnfinalizedDose) -> Date {
        dose.type == .resume ? dose.startDate.addingTimeInterval(afterFinal) : dose.startDate
    }

    /// The earliest a resume of the suspend started at `suspendStart` is dated: the next whole second. iAPS stores pump
    /// events to the second, floored (`PumpHistoryEvent`, `truncatedToSecond`), and oref0 pairs a resume with a suspend
    /// only if it is strictly later (`iob/history`): in the suspend's second, the suspend is left open - every temp basal
    /// after it zeroed, up to now. At most a second after the patch resumed: for Loop, a second more of the suspension.
    internal static func earliestResume(after suspendStart: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: suspendStart.timeIntervalSinceReferenceDate.rounded(.down) + 1)
    }

    /// How early a temp basal whose command went out at `sentAt` unanswered may be dated: `unansweredStartSlack` before
    /// then - but after the basal the host was told ran when it went out (`UnfinalizedDose.State.basalBefore`), the
    /// scheduled basal from the cancel before it, say, final: the host would take the temp basal as starting before something final, and pass it by - or, starting
    /// at the same instant, order the two either way. Only under `doseReportLock`.
    private func unansweredStartFloor(of unconfirmed: UnfinalizedDose.State, sentAt: Date) -> Date {
        let floor = sentAt.addingTimeInterval(-Self.unansweredStartSlack)
        if let basalBefore = unconfirmed.basalBefore {
            return max(floor, basalBefore.addingTimeInterval(Self.afterFinal))
        }
        // Saved by a build that did not keep it: the basal running now, if it is the one from then, reported
        let running = state.basalDose
        guard running.type != .tempBasal, !state.basalDoseIsPlaceholder, running.startDate <= sentAt else {
            return floor
        }
        return max(floor, running.startDate.addingTimeInterval(Self.afterFinal))
    }

    /// The patch splits a temp basal at patch-local midnight: a record of it ending then is a part
    internal static func isPatchMidnight(_ time: Date, utcOffset: TimeInterval) -> Bool {
        (time.timeIntervalSince1970 + utcOffset).truncatingRemainder(dividingBy: .hours(24)) == 0
    }

    /// A cancel of the running temp basal went out at `sentAt` and no answer came back: the patch may have stopped it.
    /// It stays running and counted until a status says otherwise.
    private func noteUnansweredCancel(sentAt: Date) {
        // Marked and noted together: a status finalizing it in between would leave the note unsettled
        let marked = doseReportLock.withLock { () -> Bool in
            guard state.basalDose.markStopUnanswered(at: sentAt) else {
                return false
            }
            noteUncertainDelivery(.tempBasalCancel, .unanswered, of: state.basalDose)
            return true
        }
        guard marked else {
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

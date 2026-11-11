import CoreBluetooth
import HealthKit
import LoopKit
import UIKit

public class MedtrumPumpManager: DeviceManager {
    public static let pluginIdentifier = "Medtrum"
    public let localizedTitle: String = "Medtrum Nano"

    public let managerIdentifier: String = "Medtrum"

    let log = MedtrumLogger(category: "MedtrumPumpManager")

    public let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()
    let bolusProgressReporters = Locked(WeakSet<MedtrumDoseProgressReporter>())

    /// Orders what the host is told about the doses. Held while a dose is registered or ended and reported, while a
    /// batch is put together and handed to the delegate queue (`emitPumpEvents`), from the moment a dose is finalized
    /// until its final has been handed over, and while a confirmation takes finals off `awaitingRecord`. So no batch
    /// carries a dose as mutable after its final, nor leaves out one still running or waiting.
    ///
    /// Recursive: the ending paths emit while holding it. Never held across a BLE write. A dose's own lock is a leaf
    /// taken under it, never the other way around.
    let doseReportLock = NSRecursiveLock()

    /// The identities of doses finalized lately: a mutable report of one built before its final can still be on its
    /// way after the host confirmed the final. Only under `doseReportLock`.
    var finalizedIdentities: [Data: Date] = [:]
    static let finalizedIdentityRetention: TimeInterval = .hours(1)

    /// A temp basal that ended, reported once its records are read - see `TempBasalEnd`. Only under `doseReportLock`.
    var pendingTempBasalEndStorage: TempBasalEnd?

    /// That temp basal, restored with the state of the run before - killed during its read - and its records not asked
    /// for in this run yet: read on its first status, for the patch session it was restored with, when this run began -
    /// see `takeOverTempBasalEndFromLastRun`. Only under `doseReportLock`.
    var tempBasalEndFromLastRun: (ending: TempBasalEnd, patchId: Data, restoredAt: Date)?

    /// That temp basal, its records to read once the bolus running as it ended is over - see `readsTempBasalEndAfterBolus`.
    /// Only under `doseReportLock`.
    var tempBasalEndAwaitingBolus: TempBasalEnd?

    /// The temp basal a command is cancelling - see `isCancelInFlight` - and the schedule a status showed meanwhile, set
    /// aside should the cancel fail (`setAsideForTheCancel`). Only under `doseReportLock`.
    var tempBasalCancelInFlight: UnfinalizedDose?
    var scheduleSetAsideForTheCancel: (basal: BasalData, receivedAt: Date, receivedUptime: TimeInterval)?

    /// What the batches handed over make Loop's watermark - see `LoopWatermark`. Only under `doseReportLock`.
    var loopWatermarkModel = LoopWatermark()

    /// A bolus ran as the records of the temp basals ended open were to be read: read once it is over - see
    /// `readOpenTempBasalEndsSoon`. Only under `doseReportLock`.
    var openTempBasalEndReadAwaitsBolus = false

    /// How long after a temp basal ended back to back its records are read, at the earliest - see
    /// `readOpenTempBasalEndsSoon`: the loop's bolus, right behind the temp basal, has the link first. Only tests change it.
    var openTempBasalEndReadDelay: TimeInterval = 5

    /// How long a command waits for the host to take the state before it writes a bolus or a temp basal - see
    /// `handOverState`. Well past the 3 s a host can take as it saves (device 2026-10-23 21:43, a bolus of 2.05 U).
    /// Only tests change it.
    var dosingHandOverTimeout: TimeInterval = 10

    /// The completion of the bolus sent and not yet answered - see `noteCompletionWithNoBolusRunning`. Only under
    /// `doseReportLock`.
    var earlyBolusCompletion: EarlyBolusCompletion?

    /// A bolus whose command went unanswered in an earlier run, the host not yet warned of it - see
    /// `reportBolusFromLastRun`. Only under `doseReportLock`.
    var bolusFromLastRun: UnfinalizedDose?

    /// What the stall check keeps of the running bolus - see `checkBolusStall`. Never saved. Only under `doseReportLock`.
    var bolusStallWatch: BolusStallWatch?

    /// The bolus the patch's own alarm, or its session's end, came for - by its `sentAt`, the pending one's if it was not
    /// answered yet: not warned of as stalled from there on, whichever watch judges it - one built after the alarm, on
    /// the first status after a restart or once a step confirms it, too (`retractBolusStallAlerts`). Never saved. Only
    /// under `doseReportLock`.
    var bolusStallSilencedSentAt: Date?

    /// The temp basal segments none of ours is that the host was warned of in this run, by their start on the patch
    /// clock - see `noteSegmentOfNoTempBasalOfOurs`. Only under `doseReportLock`.
    var unknownTempBasalSegments: Set<Date> = []

    /// The held back doses (`MedtrumPumpState.heldBasalDoses`) a batch on its way to the host carries - one it has yet to
    /// answer. Only under `doseReportLock`.
    var heldInFlight: [UnfinalizedDose] = []

    /// Where the records of a temp basal a notification ended are read: not the queue statuses arrive on, which the
    /// answers have to reach
    let tempBasalEndQueue = DispatchQueue(label: "com.nightscout.MedtrumKit.tempBasalEnd")

    /// No read queued on `tempBasalEndQueue` runs any more - see `stopBackgroundReads`
    let backgroundReadsStopped = Locked(false)

    /// When a batch last carried the finals the host has yet to confirm. Only under `doseReportLock`.
    var lastFinalsSentAt = Date.distantPast
    /// Without a batch for a while - no patch, or the host could not store the last one - the unconfirmed finals are
    /// sent on their own, this often at most
    static let unconfirmedFinalsResendInterval: TimeInterval = .minutes(1)
    /// A host that never confirms would have the finals pile up for good: one fixed this long ago is given up on
    static let unconfirmedFinalMaximumAge: TimeInterval = .hours(24)

    /// Held back from every batch until the records of the temp basal whose command went unanswered are read - see
    /// `holdForUnconfirmedRead`. Only under `doseReportLock`.
    var heldForUnconfirmedRead: [UnfinalizedDose] = []

    /// When the last full status of the previous patch came in, not taken - no session runs, the old patch still on the
    /// base (`StateSyncer.isEndedSessionsPatchRunning`): it moves no `lastSync`, and a heartbeat would ask for another
    /// on every tick - see `heartbeatSync`
    let previousPatchsFullStatusAt = Locked(Date.distantPast)

    /// Statuses handled, and how many showed the patch halted - see `requestStatusAfterHalt`
    let statusesHandled = Locked(0)
    let haltsSeen = Locked(0)

    /// Commands in flight, by when they started: the record sync yields to them - see `isCommandActive`
    let activeCommands = Locked([UUID: Date]())
    /// When the last command ended, on the manager's clock - see `isRightAfterACommand`
    let lastCommandEndedAt = Locked(Date.distantPast)
    /// The loop's own sync (`syncPumpData`) until it hears back, a patch time fetch (`fetchPatchTimeIfStale`) in
    /// progress, and every operation waiting for `commandLock` (`lockCommandLock`) - a deactivation, a full status: not
    /// all commands, they wait for the link all the same - see `readsLongerAsTempBasalEnds`. By when each began: one
    /// not over within `loopWaitExpiry` - its connect's completion orphaned - no longer counts, as for `activeCommands`
    let loopWaits = Locked([UUID: Date]())
    /// `ensureConnected` can orphan its completion; a command not finished this long after it connected no longer counts
    static let commandActivityTimeout: TimeInterval = .minutes(3)

    /// One operation on the patch at a time. A command holds it from its first write until it settled what it changed:
    /// a temp basal it ended reported final, its records read. A record read holds it for that one record, and never
    /// waits for it. Taken only on the threads commands and reads block on - never on the queue answers and statuses
    /// arrive on, nor on the delegate queue. Recursive: the stop command reads the last records under it.
    let commandLock = NSRecursiveLock()

    /// The clock the record fallbacks and a bolus's deadline go by - and the settled uncertain deliveries' day
    /// (`MedtrumPumpState.wallClock`). Only tests move it.
    var now: () -> Date = { Date.now } {
        didSet {
            state.wallClock = now
        }
    }
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
            state.wallClock = now
        }
    }
    var oldState: MedtrumPumpState

    /// Records read off the patch, for the debug screen. Not part of `state` - see `PumpRecordStore`.
    public let recordStore = PumpRecordStore()
    /// The records of the current patch and the one before, in a file each - see `PatchRecordHistory`. Nil for a test
    /// that keeps none.
    let recordHistory: PatchRecordHistory?
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
    var pendingDoseHandedOut = false

    private let logDeviceIdentifierLock = NSLock()
    private var logDeviceIdentifierStorage = ""

    /// for host-app logging
    var logDeviceIdentifier: String {
        logDeviceIdentifierLock.withLock { logDeviceIdentifierStorage }
    }

    func refreshLogDeviceIdentifier() {
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
        recordHistory = PatchRecordHistory()
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
    /// and registers nothing global: no app lifecycle observers, and `MedtrumLogger` keeps no reference. Keeps no record
    /// history unless given one - never in the app's documents.
    init(state: MedtrumPumpState, link: MedtrumLink, recordHistory: PatchRecordHistory? = nil) {
        self.state = state
        state.doseLock = doseReportLock
        oldState = MedtrumPumpState(rawValue: state.rawValue)
        self.recordHistory = recordHistory
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

    /// Floored onto the patch's steps - a value between two is sent as the lower one - and capped at the highest. We do
    /// support rounding down to 0.00u. A value a hair below a step - floating point noise, `0.7 - 0.05` - keeps it.
    public func roundToSupportedBolusVolume(units: Double) -> Double {
        supportedBolusVolumes.last(where: { $0 <= units + Self.stepNoise }) ?? 0
    }

    /// Floored onto the patch's steps, as `roundToSupportedBolusVolume`
    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        supportedBasalRates.last(where: { $0 <= unitsPerHour + Self.stepNoise }) ?? 0
    }

    /// How far below a step a value may be and still be on it: floating point noise, far less than a step
    internal static let stepNoise = 1e-9

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
    var isDeactivatingPatch = false

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
        // On disk before the app may be suspended
        recordHistory?.commit()
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

    internal func status(_ state: MedtrumPumpState) -> PumpManagerStatus {
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

    func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        self.mustProvideBLEHeartbeat = mustProvideBLEHeartbeat
    }
}

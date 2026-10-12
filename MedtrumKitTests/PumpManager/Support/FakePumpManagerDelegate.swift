import Foundation
import LoopKit

/// Stands in for the host: records what the pump manager tells it, and answers event batches the way
/// the test asks - acknowledged straight away by default, failed, or held until `releaseHeldBatches`.
///
/// The manager calls in on `queue` (the delegate queue), except for device log entries, which arrive
/// on whatever thread logged them - so everything is behind one lock.
final class FakePumpManagerDelegate: PumpManagerDelegate {
    struct Batch {
        let events: [NewPumpEvent]
        let lastReconciliation: Date?
        let replacePendingEvents: Bool
        /// The state the host had saved when the batch arrived: what an app killed right after storing it restarts from
        let savedState: PumpManager.RawStateValue?
    }

    struct StatusUpdate {
        let status: PumpManagerStatus
        let oldStatus: PumpManagerStatus
    }

    struct ReservoirRead {
        let units: Double
        let date: Date
    }

    struct LogEntry {
        let type: DeviceLogEntryType
        let message: String
    }

    enum BatchReply {
        case acknowledge
        case fail(Error)
        /// Keep the completion until `releaseHeldBatches`
        case hold
    }

    let queue = DispatchQueue(label: "com.nightscout.MedtrumKitTests.fakeDelegate")

    private let lock = NSLock()
    private var recordedBatches: [Batch] = []
    private var heldCompletions: [(Error?) -> Void] = []
    private var reply: BatchReply = .acknowledge
    private var recordedStateUpdates = 0
    private var lastSavedState: PumpManager.RawStateValue?
    private var recordedStatusUpdates: [StatusUpdate] = []
    private var recordedErrors: [PumpManagerError] = []
    private var recordedReservoirReads: [ReservoirRead] = []
    private var recordedAlerts: [Alert] = []
    private var recordedLogEntries: [LogEntry] = []
    private var recordedHeartbeats = 0

    // MARK: Steering

    var batchReply: BatchReply {
        get { lock.withLock { reply } }
        set { lock.withLock { reply = newValue } }
    }

    /// Completes every held batch with `error`, on the delegate queue like the host would
    func releaseHeldBatches(error: Error? = nil) {
        let completions = lock.withLock { () -> [(Error?) -> Void] in
            defer { heldCompletions = [] }
            return heldCompletions
        }

        queue.async {
            for completion in completions {
                completion(error)
            }
        }
    }

    // MARK: What happened

    var batches: [Batch] {
        lock.withLock { recordedBatches }
    }

    var heldBatchCount: Int {
        lock.withLock { heldCompletions.count }
    }

    var stateUpdates: Int {
        lock.withLock { recordedStateUpdates }
    }

    /// The raw state handed over by the last `pumpManagerDidUpdateState`, as the host saves it
    var savedState: PumpManager.RawStateValue? {
        lock.withLock { lastSavedState }
    }

    var statusUpdates: [StatusUpdate] {
        lock.withLock { recordedStatusUpdates }
    }

    var errors: [PumpManagerError] {
        lock.withLock { recordedErrors }
    }

    var reservoirReads: [ReservoirRead] {
        lock.withLock { recordedReservoirReads }
    }

    var alerts: [Alert] {
        lock.withLock { recordedAlerts }
    }

    var logEntries: [LogEntry] {
        lock.withLock { recordedLogEntries }
    }

    var heartbeats: Int {
        lock.withLock { recordedHeartbeats }
    }

    // MARK: PumpManagerDelegate

    func pumpManager(
        _: PumpManager,
        hasNewPumpEvents events: [NewPumpEvent],
        lastReconciliation: Date?,
        replacePendingEvents: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        let reply = lock.withLock { () -> BatchReply in
            recordedBatches.append(Batch(
                events: events,
                lastReconciliation: lastReconciliation,
                replacePendingEvents: replacePendingEvents,
                savedState: lastSavedState
            ))

            if case .hold = self.reply {
                heldCompletions.append(completion)
            }
            return self.reply
        }

        switch reply {
        case .acknowledge:
            completion(nil)
        case let .fail(error):
            completion(error)
        case .hold:
            break
        }
    }

    private struct FakeReservoirValue: ReservoirValue {
        let startDate: Date
        let unitVolume: Double
    }

    func pumpManager(
        _: PumpManager,
        didReadReservoirValue units: Double,
        at date: Date,
        completion: @escaping (Swift.Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>)
            -> Void
    ) {
        lock.withLock {
            recordedReservoirReads.append(ReservoirRead(units: units, date: date))
        }

        completion(.success((
            newValue: FakeReservoirValue(startDate: date, unitVolume: units),
            lastValue: nil,
            areStoredValuesContinuous: true
        )))
    }

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        let rawState = pumpManager.rawState
        lock.withLock {
            recordedStateUpdates += 1
            lastSavedState = rawState
        }
    }

    func pumpManager(_: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        lock.withLock {
            recordedStatusUpdates.append(StatusUpdate(status: status, oldStatus: oldStatus))
        }
    }

    func pumpManager(_: PumpManager, didError error: PumpManagerError) {
        lock.withLock {
            recordedErrors.append(error)
        }
    }

    func pumpManagerBLEHeartbeatDidFire(_: PumpManager) {
        lock.withLock {
            recordedHeartbeats += 1
        }
    }

    func pumpManagerMustProvideBLEHeartbeat(_: PumpManager) -> Bool {
        false
    }

    func pumpManagerWillDeactivate(_: PumpManager) {}

    func pumpManagerPumpWasReplaced(_: PumpManager) {}

    func pumpManager(_: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents _: Bool) {}

    func pumpManager(_: PumpManager, didAdjustPumpClockBy _: TimeInterval) {}

    func pumpManager(
        _: PumpManager,
        didRequestBasalRateScheduleChange _: BasalRateSchedule,
        completion: @escaping (Error?) -> Void
    ) {
        completion(nil)
    }

    func startDateToFilterNewPumpEvents(for _: PumpManager) -> Date {
        Date.distantPast
    }

    var detectedSystemTimeOffset: TimeInterval {
        0
    }

    var automaticDosingEnabled: Bool {
        true
    }

    // MARK: DeviceManagerDelegate

    func deviceManager(
        _: DeviceManager,
        logEventForDeviceIdentifier _: String?,
        type: DeviceLogEntryType,
        message: String,
        completion: ((Error?) -> Void)?
    ) {
        lock.withLock {
            recordedLogEntries.append(LogEntry(type: type, message: message))
        }

        completion?(nil)
    }

    // MARK: AlertIssuer

    func issueAlert(_ alert: Alert) {
        lock.withLock {
            recordedAlerts.append(alert)
        }
    }

    func retractAlert(identifier _: Alert.Identifier) {}

    // MARK: PersistedAlertStore

    func doesIssuedAlertExist(identifier _: Alert.Identifier, completion: @escaping (Swift.Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    func lookupAllUnretracted(managerIdentifier _: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
    }

    func lookupAllUnacknowledgedUnretracted(
        managerIdentifier _: String,
        completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void
    ) {
        completion(.success([]))
    }

    func recordRetractedAlert(_: Alert, at _: Date) {}
}

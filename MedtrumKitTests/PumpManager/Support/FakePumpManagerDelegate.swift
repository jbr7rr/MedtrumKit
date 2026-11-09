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
        /// The host stored it: it answered it with no error, or holds it still
        var stored = true
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
    private var heldCompletions: [(batch: Int, completion: (Error?) -> Void)] = []
    private var reply: BatchReply = .acknowledge
    private var recordedStateUpdates = 0
    private var lastSavedState: PumpManager.RawStateValue?
    /// Every state handed over, and how many batches had arrived by then
    private var stateSaves: [(state: PumpManager.RawStateValue, batchesBefore: Int)] = []
    private var recordedStatusUpdates: [StatusUpdate] = []
    private var recordedErrors: [PumpManagerError] = []
    private var recordedReservoirReads: [ReservoirRead] = []
    private var recordedAlerts: [Alert] = []
    private var recordedRetractions: [Alert.Identifier] = []
    private var recordedLogEntries: [LogEntry] = []
    private var recordedHeartbeats = 0
    private var afterSaving: ((PumpManager.RawStateValue) -> Void)?

    // MARK: Steering

    var batchReply: BatchReply {
        get { lock.withLock { reply } }
        set { lock.withLock { reply = newValue } }
    }

    /// Completes every held batch with `error`, on the delegate queue like the host would
    func releaseHeldBatches(error: Error? = nil) {
        let completions = lock.withLock { () -> [(Error?) -> Void] in
            defer { heldCompletions = [] }
            if error != nil {
                for held in heldCompletions {
                    recordedBatches[held.batch].stored = false
                }
            }
            return heldCompletions.map(\.completion)
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

    /// The batches the host had stored when it saved `saved`, the last time it did - and the one that came with it: what an
    /// app killed right after storing it, and restarted from `saved`, left the host with. Nil, it never saved that state.
    func batchesStored(savingState saved: PumpManager.RawStateValue) -> [LoopOrderingChecker.Batch]? {
        let (saves, all) = lock.withLock { (stateSaves, recordedBatches) }
        let isSaved = { (state: PumpManager.RawStateValue?) -> Bool in
            state.map { NSDictionary(dictionary: $0).isEqual(to: saved) } ?? false
        }
        guard var stored = saves.last(where: { isSaved($0.state) })?.batchesBefore else {
            return nil
        }
        if stored < all.count, isSaved(all[stored].savedState) {
            stored += 1
        }
        return all.prefix(stored).map {
            LoopOrderingChecker.Batch(events: $0.events, replacePendingEvents: $0.replacePendingEvents, stored: $0.stored)
        }
    }

    /// The batches as the Loop-ordering checker takes them
    var hostBatches: [LoopOrderingChecker.Batch] {
        batches.map { LoopOrderingChecker.Batch(events: $0.events, replacePendingEvents: $0.replacePendingEvents, stored: $0.stored) }
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

    /// Every raw state handed over so far, oldest first
    var savedStates: [PumpManager.RawStateValue] {
        lock.withLock { stateSaves.map(\.state) }
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

    /// Every alert retracted, by its identifier, in order
    var retractedAlerts: [Alert.Identifier] {
        lock.withLock { recordedRetractions }
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
            var stored = true
            if case .fail = self.reply {
                stored = false
            }
            recordedBatches.append(Batch(
                events: events,
                lastReconciliation: lastReconciliation,
                replacePendingEvents: replacePendingEvents,
                savedState: lastSavedState,
                stored: stored
            ))

            if case .hold = self.reply {
                heldCompletions.append((recordedBatches.count - 1, completion))
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
        let afterSaving = lock.withLock { () -> ((PumpManager.RawStateValue) -> Void)? in
            recordedStateUpdates += 1
            lastSavedState = rawState
            stateSaves.append((rawState, recordedBatches.count))
            return afterSaving
        }
        // What the host does after it saved it - iAPS logs it, and tells of the pump's status - held up, say
        afterSaving?(rawState)
    }

    /// Runs on the delegate queue each time the state was saved, before `pumpManagerDidUpdateState` returns
    var afterSavingState: ((PumpManager.RawStateValue) -> Void)? {
        get { lock.withLock { afterSaving } }
        set { lock.withLock { afterSaving = newValue } }
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

    func retractAlert(identifier: Alert.Identifier) {
        lock.withLock {
            recordedRetractions.append(identifier)
        }
    }

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

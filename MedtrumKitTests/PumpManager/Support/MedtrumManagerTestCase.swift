import LoopKit
@testable import MedtrumKit
import XCTest

/// Base for manager-level scenarios: a `MedtrumPumpManager` on a `FakeMedtrumLink`, reporting to a
/// `FakePumpManagerDelegate`.
///
/// Times are plain seconds on purpose - LoopKit and MedtrumKit both extend `TimeInterval` with
/// `.minutes()`/`.hours()`, which is ambiguous with both imported.
class MedtrumManagerTestCase: XCTestCase {
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3600

    private(set) var link: FakeMedtrumLink!
    private(set) var delegate: FakePumpManagerDelegate!
    private(set) var pumpManager: MedtrumPumpManager!

    /// What the hosts of the runs before a `restart` had been handed by then, each checked on its own - see
    /// `assertLoopOrdering`
    private var earlierHosts: [[LoopOrderingChecker.Batch]] = []
    /// What the host had stored across every `restart`, as one host: the runs before, up to the batch each restart's
    /// state was saved with. Nil, no restart.
    private var storedBeforeRestart: [LoopOrderingChecker.Batch]?

    /// Whether `tearDown` checks every host's batches against the rules Loop needs kept - see `LoopOrderingChecker`. Off
    /// only for a scenario that hands the host what no manager would. The rules iAPS needs kept
    /// (`LoopOrderingChecker.iAPSRules`) are checked all the same, unless `checksIAPSRules` is off too.
    var checksLoopOrdering = true
    /// Whether `tearDown` checks the rules iAPS needs kept where `checksLoopOrdering` is off
    var checksIAPSRules = true

    /// The start of a suspend the host stored before the scenario began - the one a state it builds says was reported in
    /// a run before - for the iAPS rule of the checker: a resume after it is not one without a suspend
    var hostSuspendedSince: Date?

    /// How far the manager's clock - the one its record fallbacks and bolus deadlines go by - is ahead of ours
    let clockOffset = Locked<TimeInterval>(0)
    /// How far the manager's monotonic clock is ahead of ours: moved with `clockOffset`, but not by a change of the wall
    /// clock (`changeWallClock`)
    let uptimeOffset = Locked<TimeInterval>(0)
    /// Whether the manager's clock stands still from `makeManager` on, moved only by `advanceClock`: for a scenario that
    /// tells a dose's span to the second from the time it ran, the test's own run time left out
    var freezesManagerClock = false

    override func setUp() {
        super.setUp()

        RecordSyncer.resetForTesting()
        link = FakeMedtrumLink()
        delegate = FakePumpManagerDelegate()
    }

    override func tearDown() {
        if checksLoopOrdering || checksIAPSRules {
            let rules = checksLoopOrdering ? nil : LoopOrderingChecker.iAPSRules
            // Delivering or not as the scenario ends - rule 8 - known of the last run only
            let delivering = pumpManager.map { manager in
                manager.state.basalDose.type != .suspend && manager.state.basalState != .suspended &&
                    !manager.state.patchSessionEnded
            }
            for batches in earlierHosts {
                assertLoopOrdering(batches, rules: rules)
            }
            assertLoopOrdering(delegate?.hostBatches ?? [], delivering: delivering, rules: rules)
            // The host keeps what it stored across a restart: the runs together, as it had them
            if let storedBeforeRestart {
                assertLoopOrdering(storedBeforeRestart + (delegate?.hostBatches ?? []), delivering: delivering, rules: rules)
            }
        }
        earlierHosts = []
        storedBeforeRestart = nil
        hostSuspendedSince = nil

        XCTAssertEqual(link.unscriptedWrites, [], "Commands were sent that the scenario has no answer for")
        XCTAssertEqual(link.unusedAnswers, 0, "Answers were scripted that nothing asked for")

        // Nothing it queued reaches the record sync of the next scenario
        pumpManager?.stopBackgroundReads()
        for earlier in earlierManagers {
            earlier.value?.stopBackgroundReads()
        }
        earlierManagers = []

        pumpManager = nil
        delegate = nil
        link = nil

        super.tearDown()
    }

    // MARK: Setup

    /// The managers of the runs before a `restart`, still alive if something holds them - see `tearDown`
    private var earlierManagers: [Weak] = []

    final class Weak {
        weak var value: MedtrumPumpManager?
        init(_ value: MedtrumPumpManager?) { self.value = value }
    }

    @discardableResult func makeManager(_ state: MedtrumPumpState) -> MedtrumPumpManager {
        if let pumpManager = self.pumpManager {
            earlierManagers.append(Weak(pumpManager))
        }
        let pumpManager = MedtrumPumpManager(state: state, link: link)
        // Read as soon as the command is over: `settle` waits for it
        pumpManager.openTempBasalEndReadDelay = 0
        let clockOffset = clockOffset
        let frozenAt = freezesManagerClock ? Date.now : nil
        pumpManager.now = { (frozenAt ?? Date.now).addingTimeInterval(clockOffset.value) }
        let uptimeOffset = uptimeOffset
        pumpManager.uptime = { TimeInterval.continuousUptime + uptimeOffset.value }
        pumpManager.delegateQueue = delegate.queue
        pumpManager.pumpManagerDelegate = delegate
        self.pumpManager = pumpManager
        return pumpManager
    }

    /// The app killed, and started again from `saved` - the state as the host had it, through the property list it is
    /// saved in: a new manager, and a new host. What the old manager still sends reaches no one.
    @discardableResult func restart(from saved: PumpManager.RawStateValue?) throws -> MedtrumPumpManager {
        let raw = try XCTUnwrap(saved, "the host has no state")
        let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        // Killed: nothing it queued runs on
        pumpManager?.stopBackgroundReads()
        earlierHosts.append(delegate.hostBatches)
        // A state the host never saved - built by the scenario - leaves what it stored unknown: all of it
        storedBeforeRestart = (storedBeforeRestart ?? []) + (delegate.batchesStored(savingState: raw) ?? delegate.hostBatches)
        delegate = FakePumpManagerDelegate()
        return makeManager(MedtrumPumpState(rawValue: decoded))
    }

    /// `batches` break none of the rules Loop needs kept - see `LoopOrderingChecker` - of `rules` only, if given; the
    /// patch `delivering` after them, or not, if known (rule 8)
    func assertLoopOrdering(
        _ batches: [LoopOrderingChecker.Batch],
        delivering: Bool? = nil,
        rules: Set<Int>? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for violation in LoopOrderingChecker.violations(in: batches, suspendedSince: hostSuspendedSince, delivering: delivering)
            where rules?.contains(violation.rule) ?? true
        {
            XCTFail("Loop ordering: \(violation)", file: file, line: line)
        }
    }

    /// An activated, connected patch running its schedule - one rate all day
    func activePatchState(patchId: UInt64, scheduledRate: Double, sequence: Int, reservoir: Double) -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        let now = Date.now

        state.isOnboarded = true
        state.pumpState = .active
        state.patchSessionEnded = false
        state.isConnected = true
        state.patchId = patchId.toData(length: 4)
        state.patchActivatedAt = now.addingTimeInterval(-24 * Self.hour)
        state.basalSchedule = BasalSchedule(entries: [RepeatingScheduleValue(startTime: 0, value: scheduledRate)])
        state.basalDose = UnfinalizedDose(basalRate: scheduledRate, insulinType: nil, startDate: now.addingTimeInterval(-Self.hour))
        state.basalState = .active
        state.currentSequenceNumber = sequence
        state.syncedSequenceNumber = sequence
        state.reservoir = reservoir
        state.initialReservoir = 200
        state.lastSync = now.addingTimeInterval(-Self.minute)
        state.pumpTime = now
        state.pumpTimeSyncedAt = now

        return state
    }

    /// A temp basal we set `startedAgo` seconds ago. `UnfinalizedDose` always starts now, so it is made
    /// through its raw value to back-date it.
    func runningTempBasal(rate: Double, startedAgo: TimeInterval, duration: TimeInterval, pumpStartTime: Date? = nil) -> UnfinalizedDose {
        let start = Date.now.addingTimeInterval(-startedAgo)

        var raw = UnfinalizedDose(tempRate: rate, duration: duration, insulinType: nil, automatic: true).rawValue
        raw["startDate"] = start
        raw["estimatedEndDate"] = start.addingTimeInterval(duration)
        raw["pumpStartTime"] = pumpStartTime
        raw["sentAt"] = start

        guard let dose = UnfinalizedDose(rawValue: raw) else {
            preconditionFailure("Temp basal raw value does not round-trip")
        }
        return dose
    }

    /// The patch clock read as `patchTime` right now: the skew every patch time in the scenario is taken through
    func alignPatchClock(_ state: MedtrumPumpState, patchTime: Date) {
        state.pumpTime = patchTime
        state.pumpTimeSyncedAt = Date.now
    }

    /// Patch seconds, as statuses, answers and records carry them
    static func patchTime(_ seconds: UInt64) -> Date {
        Date.fromMedtrumSeconds(seconds)
    }

    // MARK: Driving

    /// Moves the manager's clock on - see `clockOffset` - and its monotonic clock with it
    func advanceClock(by interval: TimeInterval) {
        clockOffset.mutate { $0 += interval }
        uptimeOffset.mutate { $0 += interval }
    }

    /// The phone's wall clock set by `interval`, forward or back: the monotonic clock does not move
    func changeWallClock(by interval: TimeInterval) {
        clockOffset.mutate { $0 += interval }
    }

    /// What `PeripheralManager` does after a full status, or a heartbeat with doses waiting
    func syncRecords(_ trigger: RecordSyncer.Trigger = .fullSync) {
        link.onQueue {
            RecordSyncer.syncRecords(pumpManager: self.pumpManager, trigger: trigger)
        }
        settle()
    }

    /// A notification saying the newest record the patch has written is `currentSequenceNumber` - as every full status
    /// says, and the patch's heartbeat while its records move
    func confirmRecordSequence() {
        let state = pumpManager.state
        let storage = UInt64(state.currentSequenceNumber).toData(length: 2) + (state.patchId.toUInt64() & 0xFFFF).toData(length: 2)
        link.notify("200001" + storage.hexEncodedString())
        settle()
    }

    func commandSuspend(duration: TimeInterval = 30 * MedtrumManagerTestCase.minute) -> Error? {
        let outcome: Error?? = completion(of: "suspendDelivery") { done in
            self.pumpManager.suspendPatch(duration: duration, completion: done)
        }
        return outcome ?? nil
    }

    func commandResume() -> Error? {
        let outcome: Error?? = completion(of: "resumeDelivery") { done in
            self.pumpManager.resumeDelivery(completion: done)
        }
        return outcome ?? nil
    }

    func commandBolus(
        _ units: Double,
        activationType: BolusActivationType = .manualNoRecommendation,
        timeout: TimeInterval = 5
    ) -> PumpManagerError? {
        let outcome: PumpManagerError?? = completion(of: "enactBolus", timeout: timeout) { done in
            self.pumpManager.enactBolus(units: units, activationType: activationType, completion: done)
        }
        return outcome ?? nil
    }

    func commandCancelBolus() -> PumpManagerResult<DoseEntry?>? {
        completion(of: "cancelBolus") { done in
            self.pumpManager.cancelBolus(completion: done)
        }
    }

    func commandTempBasal(_ unitsPerHour: Double, duration: TimeInterval, timeout: TimeInterval = 5) -> PumpManagerError? {
        let outcome: PumpManagerError?? = completion(of: "enactTempBasal", timeout: timeout) { done in
            self.pumpManager.enactTempBasal(unitsPerHour: unitsPerHour, for: duration, completion: done)
        }
        return outcome ?? nil
    }

    /// The command failed, not sent: the host did not take the state in time - see `MedtrumPumpManager.handOverPendingDose`.
    /// `tempBasalCancelled`: after the temp basal running was cancelled.
    func isStateNotSaved(_ error: PumpManagerError?, tempBasalCancelled: Bool = false) -> Bool {
        guard case let .deviceState(error)? = error, case let .stateNotSaved(cancelled)? = error as? MedtrumConnectError else {
            return false
        }
        return cancelled == tempBasalCancelled
    }

    /// Keeps the host - the delegate queue - busy from now until the returned release is called, 60 s at most: what the
    /// manager hands it meanwhile waits
    func stallHost() -> () -> Void {
        let free = DispatchSemaphore(value: 0)
        delegate.queue.async { _ = free.wait(timeout: .now() + 60) }
        return { free.signal() }
    }

    /// The host saves the first state with `key` in it - a bolus or a temp basal pending - and is then held up before it
    /// is done, until the returned release is called, 60 s at most
    func stallHostAfterSaving(_ key: String) -> () -> Void {
        let free = DispatchSemaphore(value: 0)
        let stalled = Locked(false)
        delegate.afterSavingState = { saved in
            guard saved[key] != nil, !stalled.value else {
                return
            }
            stalled.value = true
            _ = free.wait(timeout: .now() + 60)
        }
        return { [delegate] in
            delegate?.afterSavingState = nil
            free.signal()
        }
    }

    func isUncertainDelivery(_ error: PumpManagerError?) -> Bool {
        if case .uncertainDelivery? = error {
            return true
        }
        return false
    }

    var uncertainDeliveryErrors: Int {
        delegate.errors.filter { error in
            if case .uncertainDelivery = error {
                return true
            }
            return false
        }.count
    }

    /// Every final report of `dose` the host was handed, by its identity, in order
    func finals(of dose: DoseEntry?) -> [DoseEntry] {
        guard let identity = dose?.syncIdentifier else {
            return []
        }
        return delegate.batches.flatMap(\.events).compactMap(\.dose)
            .filter { $0.syncIdentifier == identity && !$0.isMutable }
    }

    /// The one final report of `dose` the host was handed: batches carry every final the host has yet to confirm, so it
    /// may have been handed more than once - hosts take it once by its identity - but every copy is the same, as it is
    /// fixed once. Fails unless there is one, and every copy equals it; returns it, nil if there is none.
    @discardableResult func assertOneFinal(
        of dose: DoseEntry?,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> DoseEntry? {
        let all = finals(of: dose)
        guard let first = all.first else {
            XCTFail("No final of \(dose.map { "\($0.type) \($0.startDate)" } ?? "-") \(message())", file: file, line: line)
            return nil
        }
        for other in all.dropFirst() where other != first {
            XCTFail("Two finals of \(first.type) \(first.startDate) differ: \(first) - \(other) \(message())", file: file, line: line)
        }
        return first
    }

    /// Every report of a dose of `type` the host was handed
    func reports(of type: DoseType) -> [DoseEntry] {
        delegate.batches.flatMap(\.events).compactMap(\.dose).filter { $0.type == type }
    }

    /// Starts a manager call that reports through a completion and waits for it - `timeout` at most. A call that never
    /// completes fails the test in `wait` and returns nil.
    func completion<T>(of description: String, timeout: TimeInterval = 5, _ call: (@escaping (T) -> Void) -> Void) -> T? {
        let done = expectation(description: description)
        let result = Locked<T?>(nil)

        call { value in
            result.value = value
            done.fulfill()
        }

        wait(for: [done], timeout: timeout)
        return result.value
    }

    /// Lets everything the manager posted run. `notifyStateDidChange` hops to the main queue and from
    /// there to the delegate queue, event batches go to the delegate queue directly, and the record store
    /// lands on main.
    /// What the settings screen tells of the doses the driver could not be sure of: each, and where it is
    var uncertain: [(kind: UncertainDelivery.Kind, cause: UncertainDelivery.Cause, phase: UncertainDelivery.Phase, delivered: Double?, record: Int?)] {
        pumpManager.state.uncertainDeliveries.map { delivery in
            (delivery.kind, delivery.cause, pumpManager.state.phase(of: delivery), delivery.delivered, delivery.record)
        }
    }

    func settle() {
        // Where the records of a temp basal a notification ended are read
        pumpManager?.tempBasalEndQueue.sync {}

        for _ in 0 ..< 2 {
            let drained = expectation(description: "main queue drained")
            DispatchQueue.main.async {
                drained.fulfill()
            }
            wait(for: [drained], timeout: 5)

            delegate.queue.sync {}
        }
    }
}

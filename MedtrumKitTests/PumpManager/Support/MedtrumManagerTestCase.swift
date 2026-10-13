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

    /// How far the manager's clock - the one its record fallbacks and bolus deadlines go by - is ahead of ours
    let clockOffset = Locked<TimeInterval>(0)

    override func setUp() {
        super.setUp()

        RecordSyncer.resetForTesting()
        link = FakeMedtrumLink()
        delegate = FakePumpManagerDelegate()
    }

    override func tearDown() {
        XCTAssertEqual(link.unscriptedWrites, [], "Commands were sent that the scenario has no answer for")
        XCTAssertEqual(link.unusedAnswers, 0, "Answers were scripted that nothing asked for")

        pumpManager = nil
        delegate = nil
        link = nil

        super.tearDown()
    }

    // MARK: Setup

    @discardableResult func makeManager(_ state: MedtrumPumpState) -> MedtrumPumpManager {
        let pumpManager = MedtrumPumpManager(state: state, link: link)
        let clockOffset = clockOffset
        pumpManager.now = { Date.now.addingTimeInterval(clockOffset.value) }
        pumpManager.delegateQueue = delegate.queue
        pumpManager.pumpManagerDelegate = delegate
        self.pumpManager = pumpManager
        return pumpManager
    }

    /// An activated, connected patch running its schedule - one rate all day
    func activePatchState(patchId: UInt64, scheduledRate: Double, sequence: Int, reservoir: Double) -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        let now = Date.now

        state.isOnboarded = true
        state.pumpState = .active
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

    /// Moves the manager's clock on - see `clockOffset`
    func advanceClock(by interval: TimeInterval) {
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

    func commandBolus(_ units: Double, activationType: BolusActivationType = .manualNoRecommendation) -> PumpManagerError? {
        let outcome: PumpManagerError?? = completion(of: "enactBolus") { done in
            self.pumpManager.enactBolus(units: units, activationType: activationType, completion: done)
        }
        return outcome ?? nil
    }

    func commandCancelBolus() -> PumpManagerResult<DoseEntry?>? {
        completion(of: "cancelBolus") { done in
            self.pumpManager.cancelBolus(completion: done)
        }
    }

    func commandTempBasal(_ unitsPerHour: Double, duration: TimeInterval) -> PumpManagerError? {
        let outcome: PumpManagerError?? = completion(of: "enactTempBasal") { done in
            self.pumpManager.enactTempBasal(unitsPerHour: unitsPerHour, for: duration, completion: done)
        }
        return outcome ?? nil
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

    /// Every report of a dose of `type` the host was handed
    func reports(of type: DoseType) -> [DoseEntry] {
        delegate.batches.flatMap(\.events).compactMap(\.dose).filter { $0.type == type }
    }

    /// Starts a manager call that reports through a completion and waits for it. A call that never
    /// completes fails the test in `wait` and returns nil.
    func completion<T>(of description: String, _ call: (@escaping (T) -> Void) -> Void) -> T? {
        let done = expectation(description: description)
        let result = Locked<T?>(nil)

        call { value in
            result.value = value
            done.fulfill()
        }

        wait(for: [done], timeout: 5)
        return result.value
    }

    /// Lets everything the manager posted run. `notifyStateDidChange` hops to the main queue and from
    /// there to the delegate queue, event batches go to the delegate queue directly, and the record store
    /// lands on main.
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

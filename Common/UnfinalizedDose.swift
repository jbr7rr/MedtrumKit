import Foundation
import LoopKit

public class UnfinalizedDose {
    public typealias RawValue = [String: Any]

    private let logger = MedtrumLogger(category: "UnfinalizedDose")

    public let type: DoseType
    public let startDate: Date
    public let estimatedEndDate: Date
    public let value: Double
    public let insulinType: InsulinType?
    public let automatic: Bool

    /// Why a dose stopped running. Decides what it is finalized as when its record never turns up.
    public enum FinishReason: String {
        /// The patch reported the bolus complete, with what it delivered - or the temp basal ran its course
        case completed
        /// Stopped on our request: a cancelled bolus, a temp basal cancelled, replaced or suspended
        case cancelled
        /// The bolus was over by the time we heard from the patch again, and we never saw how it ended
        case completionNotSeen
        /// The patch session ended under it. Its record is unreachable, so it is finalized at once.
        case interrupted
    }

    /// Whether the patch took the command that started a bolus or a temp basal
    public enum Confirmation: String {
        case confirmed
        /// Its command went out and no usable answer came back: the patch may or may not be delivering it. Never sent
        /// again. A bolus is reported running, counted in full, until a notification shows it delivering or its
        /// deadline passes. A temp basal is kept unreported (`MedtrumPumpState.unconfirmedTempBasal`) until a status
        /// or its record shows it ran, or every record the patch told of long enough after it ended at the latest was
        /// read.
        case uncertain
    }

    /// An end we never saw is extrapolated at this rate: the slow end of what the patch was seen delivering, so the
    /// estimated end errs late
    static let observedBolusUnitsPerMinute = 1.0

    /// What a bolus's deadline assumes the patch delivers at least - slow patches reach 0.77 U/min - plus
    /// `deliveryGrace`. Only matters once the link was lost: a late deadline costs nothing in insulin.
    static let deadlineBolusUnitsPerMinute = 0.5
    static let deliveryGrace: TimeInterval = .minutes(2)

    /// A record the patch wrote of a part of a running temp basal - it restarts the segment at patch-local midnight and on
    /// a profile change - read while the temp basal ran on: its final sums the parts, these and the ones read as it ends
    public struct RecordedPart: Equatable {
        public let sequence: Int
        /// The patch's, as the record carries it: the low two bytes
        public let patchId: UInt64
        /// On the patch clock
        public let start: Date
        public let end: Date
        public let delivered: Double

        public init(sequence: Int, patchId: UInt64, start: Date, end: Date, delivered: Double) {
            self.sequence = sequence
            self.patchId = patchId
            self.start = start
            self.end = end
            self.delivered = delivered
        }

        init?(rawValue: [String: Any]) {
            guard let sequence = rawValue["sequence"] as? Int, let patchId = rawValue["patchId"] as? Int,
                  let start = rawValue["start"] as? Date, let end = rawValue["end"] as? Date,
                  let delivered = rawValue["delivered"] as? Double
            else {
                return nil
            }
            self.init(sequence: sequence, patchId: UInt64(patchId), start: start, end: end, delivered: delivered)
        }

        var rawValue: [String: Any] {
            ["sequence": sequence, "patchId": Int(patchId & 0xFFFF), "start": start, "end": end, "delivered": delivered]
        }
    }

    /// Everything about a dose that changes after it was created. One object is shared by the running dose,
    /// `MedtrumPumpState.awaitingRecord`, a progress reporter and the record matching, on the BLE, command, delegate
    /// and record sync queues - so it is one value behind one lock: every transition changes it in one step, and
    /// `snapshot` reads it in one.
    public struct State {
        public fileprivate(set) var deliveredUnits: Double = 0

        /// When the patch says the dose started, on its own clock, as opposed to `startDate` which is ours: what a
        /// temp basal's record is matched on. Kept alongside `startDate`, which is the dose's identity and must not
        /// move.
        public fileprivate(set) var pumpStartTime: Date?

        /// Set when the dose stops running. From then on a bolus waits for its record, mutable for the host - see
        /// `MedtrumPumpState.awaitingRecord`. A temp basal is finalized as it ends - unless it ended open, see `endedOpen`.
        public fileprivate(set) var finishReason: FinishReason?
        /// When we learned that the dose stopped - what the record timeouts count from
        public fileprivate(set) var finishedAt: Date?
        /// When the dose stopped, if we saw it happen
        public fileprivate(set) var observedEndDate: Date?
        /// The last change of the delivered amount of a running bolus, and that amount: an end we never saw is
        /// extrapolated from there
        public fileprivate(set) var lastProgressAt: Date?
        public fileprivate(set) var lastProgressUnits: Double?

        /// No record may finalize this temp basal: a basal profile was set while it ran, and the patch split it into a
        /// record per segment. Also one whose command went unanswered that a status first showed restarted so, or that
        /// only the record of a part showed ran - and one still unconfirmed when a profile was set: its patch start is
        /// not where its records begin. It is finalized from our own estimate instead, at its rate × duration.
        public fileprivate(set) var recordMatchDisabled = false

        /// What the patch had delivered of this running temp basal by the last status showing its segment - the one
        /// starting on `pumpStartTime` - and when that status was received: the base of our estimate of it, should its
        /// records not be read
        public fileprivate(set) var statusDelivery: Double?
        public fileprivate(set) var statusDeliveryReceivedAt: Date?

        /// The parts of this running temp basal whose records were read while it ran, in order - see `RecordedPart` - and of
        /// one `endedOpen`, read since it ended
        public fileprivate(set) var recordedParts: [RecordedPart] = []

        /// This temp basal ended where the one that replaced it started, back to back: reported ended, its end there, and
        /// mutable until its records are read - see `MedtrumPumpManager.openTempBasalEnds`
        public fileprivate(set) var endedOpen = false
        /// Of one `endedOpen`: the number of its last record, which the answer to the cancel that ended it named - nil,
        /// no answer named one. Of one whose command went unanswered, the record the answer to a cancel after it named:
        /// its own, if it ran - read early, see `MedtrumPumpManager.lastRecordOfOpenTempBasalEnds`.
        public fileprivate(set) var endRecord: Int?
        /// And where that record ends, on the patch clock: where the segment after it started
        public fileprivate(set) var patchEndTime: Date?
        /// Of a temp basal whose records are read as it ends (`MedtrumPumpManager.TempBasalEnd`): the number of its last
        /// record, and where it ends on the patch clock, where known - saved with it, so that a run killed during that
        /// read has the next one read them after all (`MedtrumPumpManager.takeOverTempBasalEndFromLastRun`). Nil, none
        /// known - and for a state saved before these were kept: our estimate stands in.
        public fileprivate(set) var endReadLastRecord: Int?
        public fileprivate(set) var endReadPatchEnd: Date?
        /// Of one a halt ended with no record named - its status cut short, say: the newest record the next status names
        /// is its last (`MedtrumPumpManager.TempBasalEnd.awaitsRecord`) - saved, so that a run killed meanwhile waits for
        /// that status too. `endReadPatchEnd` where it ends, if known.
        public fileprivate(set) var endReadAwaitsRecord = false

        /// The final report, once there is one. Every report of the final is rebuilt from exactly these, so a final
        /// sent again until the host confirms storing it is byte for byte the same.
        public fileprivate(set) var finalDeliveredUnits: Double?
        public fileprivate(set) var finalEndDate: Date?
        /// When the final was fixed - what its expiry counts from, see `MedtrumPumpManager.isUnconfirmedFinalExpired`
        public fileprivate(set) var finalizedAt: Date?

        public fileprivate(set) var confirmation: Confirmation = .confirmed
        /// The host was warned that this bolus may or may not have been delivered - once per bolus
        public fileprivate(set) var uncertaintyReported = false

        /// When the command that started this dose went out: a status received before then says nothing of it
        /// (`MedtrumPumpManager.statusPredatesCommand`), and a bolus's deadline and the window its record is looked
        /// for in count from it. Nil for any other dose, and for one saved before this was kept.
        public fileprivate(set) var sentAt: Date?
        /// `sentAt` on the monotonic clock, which survives a change of the wall clock - but not a restart, so it is
        /// never saved
        public fileprivate(set) var sentUptime: TimeInterval?
        /// When the command was written, after the wait for the host to take the state with it pending - `sentAt` is
        /// from before, and stays its identity: a status received before then says nothing of it
        /// (`MedtrumPumpManager.statusPredatesCommand`). Nil, the same as `sentAt` as far as is known - one taken over
        /// after a kill, one saved before this was kept.
        public fileprivate(set) var writtenAt: Date?
        /// `writtenAt` on the monotonic clock, never saved - as `sentUptime`
        public fileprivate(set) var writtenUptime: TimeInterval?
        /// The newest record number known when the command went out - for a bolus, or claimed by an earlier bolus's
        /// answer (`MedtrumPumpState.answeredBolusRecords`): the record of a bolus whose answer was lost is numbered past it
        public fileprivate(set) var sequenceAtSend: Int?
        /// The record the patch allocated for this bolus, from the answer to its command: matched by number
        public fileprivate(set) var recordSequence: Int?
        /// That number came back as a record of another kind - one the patch wrote as the bolus ran, an alarm, say
        /// (device 2026-10-22 13:52): the bolus's own is numbered after it, matched by its answered start
        /// (`MedtrumPumpManager.reconcile`)
        public fileprivate(set) var answeredRecordTaken = false
        /// Of a bolus whose command went unanswered: every record numbered past `sequenceAtSend` up to this one was read,
        /// in order and in its own place, while it ran or waited on its record - nil, none yet. A record skipped, or
        /// read in another's place, stops it there for good: that one could have been its.
        public fileprivate(set) var recordsReadThrough: Int?
        /// Of a bolus whose command went unanswered: the first record read that could be its - at its amount, numbered
        /// past `sequenceAtSend`, near when it went out or matching no dose of ours - whatever it finalized
        public fileprivate(set) var possibleRecord: Int?
        /// The latest start of a segment the patch was known to run when the command of this unanswered temp basal
        /// went out, on its clock: a segment of ours started after it
        public fileprivate(set) var priorSegmentStart: Date?
        /// The start of the earliest segment known to have begun after the command of this unanswered temp basal went
        /// out - the one a later command's answer reports, or one a status shows - on the patch clock: a segment of this
        /// temp basal started before it, and if it ran at all it ended by then
        public fileprivate(set) var laterSegmentStart: Date?
        /// Of a temp basal whose command went unanswered: a status showed its segment, from this start on the patch
        /// clock - late, the segment over by then: it ran, and its record settles it
        public fileprivate(set) var shownRunningFrom: Date?
        /// A cancel of this temp basal went out and no answer came back: the patch may have stopped it
        public fileprivate(set) var stopUnansweredAt: Date?
        /// Of a temp basal whose command went unanswered: the start of the basal the host was told ran when it went out -
        /// the scheduled basal from the cancel before it, say. A temp basal it ran is dated after it.
        public fileprivate(set) var basalBefore: Date?
        /// Where that basal started on the patch clock, where known - the segment the cancel before the command started:
        /// the patch's times of this one are told from there, with no skew
        public fileprivate(set) var basalBeforeOnPatch: Date?
        /// Its patch start may not be where it began delivering, nor its start on our clock where the patch began it: it
        /// went unanswered and a status or a record showed it later - a restart of it at patch-local midnight, say - or its
        /// patch start was taken from a status. How long the patch ran it is not told from its patch start.
        public fileprivate(set) var firstSegmentUncertain = false

        public var isFinished: Bool {
            finishedAt != nil
        }

        /// Its one final report has been produced, and never changes again
        public var isFinalized: Bool {
            finalEndDate != nil
        }

        /// An amount that reaches a dose after it ended - a completion read just before a cancel ended it, say -
        /// only ever raises what the dose ended with, until its final
        @discardableResult fileprivate mutating func raiseAfterEnd(to delivered: Double) -> Bool {
            guard isFinished, !isFinalized, delivered > deliveredUnits else {
                return false
            }
            deliveredUnits = delivered
            return true
        }
    }

    /// A leaf lock: nothing runs under it but reading and changing the value - no other lock, no logging, delegate or
    /// dispatch, and no getter of this dose (it is not recursive). It may be taken under `doseReportLock`, never the
    /// other way around. Inside a transition use the pure helpers that take the state (`…(of:)`).
    private let locked = Locked(State())

    /// The whole state, read in one go
    public var snapshot: State {
        locked.value
    }

    public var deliveredUnits: Double { snapshot.deliveredUnits }
    public var pumpStartTime: Date? { snapshot.pumpStartTime }
    public var finishReason: FinishReason? { snapshot.finishReason }
    public var finishedAt: Date? { snapshot.finishedAt }
    public var observedEndDate: Date? { snapshot.observedEndDate }
    public var lastProgressAt: Date? { snapshot.lastProgressAt }
    public var lastProgressUnits: Double? { snapshot.lastProgressUnits }
    public var recordMatchDisabled: Bool { snapshot.recordMatchDisabled }
    public var finalDeliveredUnits: Double? { snapshot.finalDeliveredUnits }
    public var finalEndDate: Date? { snapshot.finalEndDate }
    public var finalizedAt: Date? { snapshot.finalizedAt }
    public var isFinished: Bool { snapshot.isFinished }
    public var isFinalized: Bool { snapshot.isFinalized }
    public var confirmation: Confirmation { snapshot.confirmation }
    public var sentAt: Date? { snapshot.sentAt }
    public var recordSequence: Int? { snapshot.recordSequence }

    public init(
        units: Double,
        duration: TimeInterval,
        activationType: BolusActivationType,
        insulinType: InsulinType?,
        confirmation: Confirmation = .confirmed,
        startDate: Date = Date.now
    ) {
        type = .bolus
        value = units
        self.startDate = startDate
        estimatedEndDate = startDate.addingTimeInterval(duration)
        self.insulinType = insulinType
        automatic = activationType.isAutomatic

        var state = State()
        state.confirmation = confirmation
        locked.value = state
    }

    public init(basalRate: Double, insulinType: InsulinType?, startDate: Date = Date.now) {
        type = .basal
        value = basalRate
        self.startDate = startDate
        estimatedEndDate = startDate
        self.insulinType = insulinType
        automatic = false
    }

    public init(
        tempRate: Double,
        duration: TimeInterval,
        insulinType: InsulinType?,
        automatic: Bool,
        confirmation: Confirmation = .confirmed,
        startDate: Date = Date.now
    ) {
        type = .tempBasal
        value = tempRate
        self.startDate = startDate
        self.insulinType = insulinType
        estimatedEndDate = startDate.addingTimeInterval(duration)
        self.automatic = automatic

        var state = State()
        state.confirmation = confirmation
        locked.value = state
    }

    public init(suspendStartTime: Date) {
        type = .suspend
        value = 0
        startDate = suspendStartTime
        estimatedEndDate = startDate
        automatic = false // OSAID does not use suspend function
        insulinType = nil
    }

    public init(resumeStartTime: Date, insulinType: InsulinType?) {
        type = .resume
        value = 0
        startDate = resumeStartTime
        estimatedEndDate = startDate
        self.insulinType = insulinType
        automatic = false // OSAID does not use resume function
    }

    public init?(rawValue: RawValue) {
        if let rawType = rawValue["type"] as? DoseType.RawValue, let type = DoseType(rawValue: rawType) {
            self.type = type
        } else {
            logger.warning("Couldn't convert type")
            return nil
        }

        if let value = rawValue["value"] as? Double {
            self.value = value
        } else {
            logger.warning("Couldn't convert value")
            return nil
        }

        if let rawStartDate = rawValue["startDate"] as? Date {
            startDate = rawStartDate
        } else {
            logger.warning("Couldn't convert startDate")
            return nil
        }

        if let rawEstimatedEndDate = rawValue["estimatedEndDate"] as? Date {
            estimatedEndDate = rawEstimatedEndDate
        } else {
            logger.warning("Couldn't convert estimatedEndDate")
            return nil
        }

        var state = State()

        if let rawDeliveredUnits = rawValue["deliveredUnits"] as? Double {
            state.deliveredUnits = rawDeliveredUnits
        } else {
            logger.warning("Couldn't convert deliveredUnits")
            return nil
        }

        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue,
           let insulinType = InsulinType(rawValue: rawInsulinType)
        {
            self.insulinType = insulinType
        } else {
            insulinType = nil
        }

        if let rawAutomatic = rawValue["automatic"] as? Bool {
            automatic = rawAutomatic
        } else {
            logger.warning("Couldn't convert automatic")
            return nil
        }

        // Everything below is optional, and absent for every dose written before it was kept - not a decode failure
        state.pumpStartTime = rawValue["pumpStartTime"] as? Date
        state.finishReason = (rawValue["finishReason"] as? FinishReason.RawValue).flatMap(FinishReason.init(rawValue:))
        state.finishedAt = rawValue["finishedAt"] as? Date
        state.observedEndDate = rawValue["observedEndDate"] as? Date
        state.lastProgressAt = rawValue["lastProgressAt"] as? Date
        state.lastProgressUnits = rawValue["lastProgressUnits"] as? Double
        state.recordMatchDisabled = rawValue["recordMatchDisabled"] as? Bool ?? false
        // Both or neither
        if let statusDeliveryReceivedAt = rawValue["statusDeliveryReceivedAt"] as? Date,
           let statusDelivery = rawValue["statusDelivery"] as? Double
        {
            state.statusDelivery = statusDelivery
            state.statusDeliveryReceivedAt = statusDeliveryReceivedAt
        }

        // A part that does not decode leaves a gap: the parts then do not add up, and our estimate stands in
        state.recordedParts = (rawValue["recordedParts"] as? [[String: Any]])?.compactMap(RecordedPart.init(rawValue:)) ?? []
        state.endedOpen = rawValue["endedOpen"] as? Bool ?? false
        state.endRecord = rawValue["endRecord"] as? Int
        state.patchEndTime = rawValue["patchEndTime"] as? Date
        state.endReadLastRecord = rawValue["endReadLastRecord"] as? Int
        state.endReadPatchEnd = rawValue["endReadPatchEnd"] as? Date
        state.endReadAwaitsRecord = rawValue["endReadAwaitsRecord"] as? Bool ?? false

        // Both or neither: a final is only ever set whole
        if let finalEndDate = rawValue["finalEndDate"] as? Date {
            state.finalEndDate = finalEndDate
            state.finalDeliveredUnits = rawValue["finalDeliveredUnits"] as? Double
            state.finalizedAt = rawValue["finalizedAt"] as? Date
        }

        state.confirmation = (rawValue["confirmation"] as? Confirmation.RawValue).flatMap(Confirmation.init(rawValue:)) ??
            .confirmed
        state.uncertaintyReported = rawValue["uncertaintyReported"] as? Bool ?? false
        state.sentAt = rawValue["sentAt"] as? Date
        state.writtenAt = rawValue["writtenAt"] as? Date
        state.sequenceAtSend = rawValue["sequenceAtSend"] as? Int
        state.recordSequence = rawValue["recordSequence"] as? Int
        state.answeredRecordTaken = rawValue["answeredRecordTaken"] as? Bool ?? false
        state.recordsReadThrough = rawValue["recordsReadThrough"] as? Int
        state.possibleRecord = rawValue["possibleRecord"] as? Int
        state.priorSegmentStart = rawValue["priorSegmentStart"] as? Date
        state.laterSegmentStart = rawValue["laterSegmentStart"] as? Date
        state.shownRunningFrom = rawValue["shownRunningFrom"] as? Date
        state.stopUnansweredAt = rawValue["stopUnansweredAt"] as? Date
        state.basalBefore = rawValue["basalBefore"] as? Date
        state.basalBeforeOnPatch = rawValue["basalBeforeOnPatch"] as? Date
        state.firstSegmentUncertain = rawValue["firstSegmentUncertain"] as? Bool ?? false

        locked.value = state
    }

    /// From one snapshot: a dose saved while another queue finishes it is saved either before or after, not half-way
    public var rawValue: RawValue {
        let state = snapshot
        var raw: RawValue = [:]

        raw["type"] = type.rawValue
        raw["value"] = value
        raw["startDate"] = startDate
        raw["estimatedEndDate"] = estimatedEndDate
        raw["deliveredUnits"] = state.deliveredUnits
        raw["insulinType"] = insulinType?.rawValue
        raw["automatic"] = automatic
        raw["pumpStartTime"] = state.pumpStartTime
        raw["finishReason"] = state.finishReason?.rawValue
        raw["finishedAt"] = state.finishedAt
        raw["observedEndDate"] = state.observedEndDate
        raw["lastProgressAt"] = state.lastProgressAt
        raw["lastProgressUnits"] = state.lastProgressUnits
        if state.recordMatchDisabled {
            raw["recordMatchDisabled"] = true
        }
        raw["statusDelivery"] = state.statusDelivery
        raw["statusDeliveryReceivedAt"] = state.statusDeliveryReceivedAt
        if !state.recordedParts.isEmpty {
            raw["recordedParts"] = state.recordedParts.map(\.rawValue)
        }
        if state.endedOpen {
            raw["endedOpen"] = true
        }
        raw["endRecord"] = state.endRecord
        raw["patchEndTime"] = state.patchEndTime
        raw["endReadLastRecord"] = state.endReadLastRecord
        raw["endReadPatchEnd"] = state.endReadPatchEnd
        if state.endReadAwaitsRecord {
            raw["endReadAwaitsRecord"] = true
        }
        raw["finalDeliveredUnits"] = state.finalDeliveredUnits
        raw["finalEndDate"] = state.finalEndDate
        raw["finalizedAt"] = state.finalizedAt
        // Only where they depart from a confirmed dose, so every other dose is saved as before
        if state.confirmation != .confirmed {
            raw["confirmation"] = state.confirmation.rawValue
        }
        if state.uncertaintyReported {
            raw["uncertaintyReported"] = true
        }
        raw["sentAt"] = state.sentAt
        raw["writtenAt"] = state.writtenAt
        raw["sequenceAtSend"] = state.sequenceAtSend
        raw["recordSequence"] = state.recordSequence
        if state.answeredRecordTaken {
            raw["answeredRecordTaken"] = true
        }
        raw["recordsReadThrough"] = state.recordsReadThrough
        raw["possibleRecord"] = state.possibleRecord
        raw["priorSegmentStart"] = state.priorSegmentStart
        raw["laterSegmentStart"] = state.laterSegmentStart
        raw["shownRunningFrom"] = state.shownRunningFrom
        raw["stopUnansweredAt"] = state.stopUnansweredAt
        raw["basalBefore"] = state.basalBefore
        raw["basalBeforeOnPatch"] = state.basalBeforeOnPatch
        if state.firstSegmentUncertain {
            raw["firstSegmentUncertain"] = true
        }

        return raw
    }

    /// The same dose, as far as the host is concerned
    func isSameDose(as other: UnfinalizedDose) -> Bool {
        type == other.type && startDate == other.startDate
    }

    // MARK: - Transitions

    /// Changes the state in one step, under the dose lock: `change` may only read and write the value it is handed
    private func transition<Outcome>(_ change: (inout State) -> Outcome) -> Outcome {
        var result: Outcome?
        locked.mutate { state in
            result = change(&state)
        }
        return result!
    }

    /// The command that started this dose went out at `sentAt` (`uptime` on the monotonic clock), the patch having
    /// written up to record `sequence`. For a dose not shared yet.
    func noteCommand(
        sentAt: Date,
        uptime: TimeInterval?,
        sequence: Int,
        priorSegmentStart: Date? = nil,
        basalBefore: Date? = nil,
        basalBeforeOnPatch: Date? = nil
    ) {
        transition { state in
            state.basalBeforeOnPatch = basalBeforeOnPatch
            state.sentAt = sentAt
            state.sentUptime = uptime
            state.sequenceAtSend = sequence
            state.priorSegmentStart = priorSegmentStart
            state.basalBefore = basalBefore
        }
    }

    /// The command that started this dose was written at `at` (`uptime` on the monotonic clock) - see
    /// `State.writtenAt`. For a dose not shared yet.
    func noteWritten(at: Date, uptime: TimeInterval?) {
        transition { state in
            state.writtenAt = at
            state.writtenUptime = uptime
        }
    }

    /// What the answer to the SetBolus command said of this bolus. For a dose not shared yet.
    func noteAnswer(recordSequence: Int, pumpStartTime: Date? = nil) {
        transition { state in
            state.recordSequence = recordSequence
            state.pumpStartTime = pumpStartTime
        }
    }

    /// The record its answer named came back as one of another kind - see `State.answeredRecordTaken`. Returns whether
    /// that is news.
    func noteAnsweredRecordTaken() -> Bool {
        transition { state in
            guard type == .bolus, !state.isFinalized, !state.answeredRecordTaken else {
                return false
            }
            state.answeredRecordTaken = true
            return true
        }
    }

    /// Record `sequence` was read in its own place while this bolus whose command went unanswered ran or waited on its
    /// record - see `State.recordsReadThrough`. Moves it on only from the record before.
    func noteRecordRead(_ sequence: Int) {
        transition { state in
            guard let sequenceAtSend = state.sequenceAtSend, sequence == (state.recordsReadThrough ?? sequenceAtSend) + 1 else {
                return
            }
            state.recordsReadThrough = sequence
        }
    }

    /// Record `sequence` could be that of this bolus whose command went unanswered - see `State.possibleRecord`
    func notePossibleRecord(_ sequence: Int) {
        transition { state in
            state.possibleRecord = state.possibleRecord ?? sequence
        }
    }

    /// A segment started at `start`, after the command of this unanswered temp basal went out - see
    /// `State.laterSegmentStart`. The earliest one is kept: a status can show one older than an answer already did.
    func noteLaterSegment(startingAt start: Date) {
        transition { state in
            state.laterSegmentStart = min(state.laterSegmentStart ?? start, start)
        }
    }

    /// A status showed the segment of this unanswered temp basal from `start` - late: see `State.shownRunningFrom`. The
    /// first one shown is kept.
    func noteShownRunning(from start: Date) {
        transition { state in
            state.shownRunningFrom = state.shownRunningFrom ?? start
        }
    }

    /// Sets the patch's start of this dose - the first one known only, and only while it runs. Returns whether it was set.
    @discardableResult func setPumpStartTime(_ time: Date) -> Bool {
        transition { state -> Bool in
            guard !state.isFinished, state.pumpStartTime == nil else {
                return false
            }
            state.pumpStartTime = time
            return true
        }
    }

    /// The patch start of this basal of another kind than a temp basal pairs with nothing on our clock after all: gone
    func forgetPumpStartTime() {
        transition { state in
            guard type != .tempBasal, type != .bolus else {
                return
            }
            state.pumpStartTime = nil
        }
    }

    /// No record may finalize this dose from now on - see `State.recordMatchDisabled`. Only while it runs: one that
    /// ended has its records written already. Returns whether it applied.
    @discardableResult func disableRecordMatch() -> Bool {
        transition { state -> Bool in
            guard !state.isFinished, !state.recordMatchDisabled else {
                return false
            }
            state.recordMatchDisabled = true
            return true
        }
    }

    /// A cancel of this running temp basal went out at `time` unanswered - see `State.stopUnansweredAt`
    @discardableResult func markStopUnanswered(at time: Date) -> Bool {
        transition { state -> Bool in
            guard type == .tempBasal, !state.isFinished else {
                return false
            }
            state.stopUnansweredAt = time
            return true
        }
    }

    /// A status shows the patch still running this temp basal after its unanswered cancel. Returns whether it was marked.
    @discardableResult func clearStopUnanswered() -> Bool {
        transition { state -> Bool in
            guard state.stopUnansweredAt != nil else {
                return false
            }
            state.stopUnansweredAt = nil
            return true
        }
    }

    /// A status received at `receivedAt` shows this running temp basal's segment having delivered `delivered` - see
    /// `State.statusDelivery`. The latest status is kept: they are handled on different queues.
    @discardableResult func noteStatusDelivery(_ delivered: Double, receivedAt: Date) -> Bool {
        transition { state -> Bool in
            guard type == .tempBasal, !state.isFinished,
                  state.statusDeliveryReceivedAt.map({ receivedAt > $0 }) ?? true
            else {
                return false
            }
            state.statusDelivery = delivered
            state.statusDeliveryReceivedAt = receivedAt
            return true
        }
    }

    /// The record of a part of this temp basal, read while it runs - see `RecordedPart` - or since it ended open (see
    /// `State.endedOpen`). Kept once, only until its final. Returns whether it was kept.
    @discardableResult func keepRecordedPart(_ part: RecordedPart) -> Bool {
        transition { state -> Bool in
            guard type == .tempBasal, !state.isFinalized, !state.isFinished || state.endedOpen,
                  !state.recordedParts.contains(where: { $0.sequence == part.sequence })
            else {
                return false
            }
            state.recordedParts.append(part)
            return true
        }
    }

    /// Whether the host is to be warned of this bolus now, being told so: once, and only while it is uncertain
    func noteUncertaintyReported() -> Bool {
        transition { state -> Bool in
            guard state.confirmation == .uncertain, !state.uncertaintyReported else {
                return false
            }
            state.uncertaintyReported = true
            return true
        }
    }

    /// Progress of a running bolus: it never lowers the amount, and confirms one whose command went unanswered - the
    /// patch is delivering it. Once it finished, only raises the amount it ended with, until its final. Returns whether
    /// it was taken as progress, and whether that confirmed it.
    @discardableResult func updateProgress(delivered: Double, at now: Date = Date.now) -> (taken: Bool, confirmed: Bool) {
        transition { state -> (taken: Bool, confirmed: Bool) in
            guard !state.isFinished else {
                state.raiseAfterEnd(to: delivered)
                return (false, false)
            }
            // Cumulative, but statuses are handled on different queues and can arrive out of order
            guard delivered >= state.deliveredUnits else {
                return (false, false)
            }
            if delivered != state.lastProgressUnits {
                state.lastProgressAt = now
                state.lastProgressUnits = delivered
            }
            state.deliveredUnits = delivered
            let confirmed = state.confirmation != .confirmed
            state.confirmation = .confirmed
            return (true, confirmed)
        }
    }

    /// The dose stopped running. `deliveredUnits` is what it delivered, when the end says so (a completion does);
    /// without it the last amount reported stands. Once: a later end keeps the first, only raising the amount until
    /// the final. A completion below the progress already seen keeps the progress - the amount is cumulative.
    /// A completion of a bolus confirms it. Returns whether this call ended it.
    @discardableResult func finish(
        _ reason: FinishReason,
        deliveredUnits delivered: Double? = nil,
        endedAt: Date?,
        at now: Date = Date.now
    ) -> Bool {
        transition { state -> Bool in
            guard !state.isFinished, !state.isFinalized else {
                if let delivered {
                    state.raiseAfterEnd(to: delivered)
                }
                return false
            }
            if let delivered, delivered > state.deliveredUnits {
                state.deliveredUnits = delivered
            }
            state.finishReason = reason
            state.finishedAt = now
            state.observedEndDate = endedAt
            if reason == .completed, type == .bolus {
                state.confirmation = .confirmed
            }
            return true
        }
    }

    /// See `State.firstSegmentUncertain`
    func markFirstSegmentUncertain() {
        transition { state in
            state.firstSegmentUncertain = true
        }
    }

    /// The answer to a cancel, gone out while this temp basal whose command went unanswered was kept, names `record`: if
    /// it ran, the record of its end - see `State.endRecord`. Only before it is settled.
    func noteEndRecord(_ record: Int) {
        transition { state in
            guard !state.isFinished, !state.isFinalized else {
                return
            }
            state.endRecord = record
        }
    }

    /// This running temp basal ended at `endedAt`, where the temp basal that replaced it started - open (see
    /// `State.endedOpen`), its last record `endRecord`, ending at `patchEnd` on the patch clock, where known. Once, in one
    /// step: returns whether this call ended it.
    @discardableResult func endOpen(at endedAt: Date, patchEnd: Date?, endRecord: Int?, at now: Date = Date.now) -> Bool {
        transition { state -> Bool in
            guard type == .tempBasal, !state.isFinished, !state.isFinalized else {
                return false
            }
            state.finishReason = endedAt >= estimatedEndDate ? .completed : .cancelled
            state.finishedAt = now
            state.observedEndDate = endedAt
            state.endedOpen = true
            state.endRecord = endRecord
            state.patchEndTime = patchEnd
            return true
        }
    }

    /// This temp basal, ended, has its records read up to `lastRecord`, ending at `patchEnd` on the patch clock, where
    /// known - see `State.endReadLastRecord`. Only before its final, and not for one ended open: those keep their own.
    func noteEndRead(lastRecord: Int, patchEnd: Date?) {
        transition { state in
            guard type == .tempBasal, state.isFinished, !state.isFinalized, !state.endedOpen else {
                return
            }
            state.endReadLastRecord = lastRecord
            state.endReadPatchEnd = patchEnd
            state.endReadAwaitsRecord = false
        }
    }

    /// This temp basal, ended, waits for the next status that names a record - its last - ending at `patchEnd` on the
    /// patch clock, where known - see `State.endReadAwaitsRecord`. As `noteEndRead`, only before its final, and not for
    /// one ended open.
    func noteEndAwaitsRecord(patchEnd: Date?) {
        transition { state in
            guard type == .tempBasal, state.isFinished, !state.isFinalized, !state.endedOpen else {
                return
            }
            state.endReadLastRecord = nil
            state.endReadPatchEnd = patchEnd
            state.endReadAwaitsRecord = true
        }
    }

    /// Raises the amount of this bolus, ended already - the completion the patch sends after a cancel. Returns whether
    /// it did.
    @discardableResult func raiseAfterEnd(to delivered: Double) -> Bool {
        transition { state -> Bool in
            state.raiseAfterEnd(to: delivered)
        }
    }

    /// The completion the patch sends after a cancel, shown to be this bolus's own: raises its amount as
    /// `raiseAfterEnd`, and confirms it if its command went unanswered - the patch says what it delivered of it, so it no
    /// longer counts in full. Only once it ended, until its final. Returns whether it changed it.
    @discardableResult func confirmAfterEnd(delivered: Double) -> Bool {
        transition { state -> Bool in
            guard state.isFinished, !state.isFinalized else {
                return false
            }
            let raised = state.raiseAfterEnd(to: delivered)
            let confirmed = state.confirmation != .confirmed
            state.confirmation = .confirmed
            return raised || confirmed
        }
    }

    /// Fixes the final report of this finished bolus or temp basal - once: returns false, changing nothing, if it has one.
    /// `deliveredUnits` nil: by our own estimate (`fallbackAmount`), taken in the same step. Only
    /// `MedtrumPumpManager.finalize` calls it, under `doseReportLock`.
    @discardableResult func finalize(deliveredUnits delivered: Double?, endDate: Date? = nil, at now: Date = Date.now) -> Bool {
        transition { state -> Bool in
            guard !state.isFinalized else {
                return false
            }
            let entry = closingEntry(of: state, deliveredUnits: delivered ?? fallbackAmount(of: state), endDate: endDate, now: now)
            // As rounded for the report, so rebuilding it from these rounds nothing differently
            state.finalDeliveredUnits = entry.deliveredUnits
            state.finalEndDate = entry.endDate
            state.finalizedAt = now
            // Summed up, or given up on
            state.recordedParts = []
            return true
        }
    }

    // MARK: - Reports

    public func toDoseEntry(isMutable: Bool = false, endDate: Date = Date.now) -> DoseEntry {
        doseEntry(of: snapshot, isMutable: isMutable, endDate: endDate)
    }

    /// `toDoseEntry` as of `state`
    func doseEntry(of state: State, isMutable: Bool = false, endDate: Date = Date.now) -> DoseEntry {
        switch type {
        case .bolus:
            guard state.isFinished else {
                return bolusDoseEntry(
                    isMutable: isMutable,
                    endDate: isMutable ? estimatedEndDate : endDate,
                    deliveredUnits: isMutable ? nil : state.deliveredUnits
                )
            }

            // Finished and waiting on its record. The host counts `deliveredUnits ?? programmed`: one whose end we
            // never saw counts in full until the record says otherwise.
            let delivered: Double? = isMutable && countsInFull(state) ? nil : state.deliveredUnits
            return bolusDoseEntry(
                isMutable: isMutable,
                endDate: bolusEnd(of: state, delivered: delivered ?? value),
                deliveredUnits: delivered
            )

        case .basal:
            return DoseEntry(
                type: .basal,
                startDate: startDate,
                value: roundBasalRate(value),
                unit: .unitsPerHour,
                insulinType: insulinType
            )

        case .tempBasal:
            let actualEndDate: Date
            if state.isFinished {
                actualEndDate = tempBasalEnd(of: state)
            } else if isMutable {
                actualEndDate = estimatedEndDate
            } else {
                // in case this finalization happens late (TBR ended while not connected to the phone, etc)
                // don't report the end date later than the scheduled end date
                actualEndDate = min(endDate, estimatedEndDate)
            }

            return tempBasalDoseEntry(
                isMutable: isMutable,
                endDate: actualEndDate,
                deliveredUnits: isMutable ? nil : estimatedTempBasalDelivery(until: actualEndDate)
            )

        case .suspend:
            return DoseEntry(
                suspendDate: startDate,
                automatic: automatic
            )

        case .resume:
            return DoseEntry(
                resumeDate: startDate,
                insulinType: insulinType,
                automatic: automatic
            )
        }
    }

    /// The final report of a finished bolus or temp basal: same identity as every report before it - only the
    /// delivered amount and the end move. `endDate` is for a temp basal whose record gave its duration.
    private func closingEntry(of state: State, deliveredUnits delivered: Double, endDate: Date?, now: Date) -> DoseEntry {
        switch type {
        case .bolus:
            return bolusDoseEntry(isMutable: false, endDate: bolusEnd(of: state, delivered: delivered, now: now), deliveredUnits: delivered)

        case .tempBasal:
            let end = endDate.map { min(max($0, startDate), estimatedEndDate) } ?? tempBasalEnd(of: state, now: now)
            return tempBasalDoseEntry(isMutable: false, endDate: end, deliveredUnits: delivered)

        case .basal,
             .resume,
             .suspend:
            return doseEntry(of: state)
        }
    }

    /// The final report as fixed by `finalize` - nil until then
    private func fixedFinalEntry(of state: State) -> DoseEntry? {
        guard let finalEndDate = state.finalEndDate else {
            return nil
        }

        switch type {
        case .bolus:
            return bolusDoseEntry(isMutable: false, endDate: finalEndDate, deliveredUnits: state.finalDeliveredUnits)
        case .tempBasal:
            return tempBasalDoseEntry(isMutable: false, endDate: finalEndDate, deliveredUnits: state.finalDeliveredUnits)
        case .basal,
             .resume,
             .suspend:
            return nil
        }
    }

    /// The final report as the event the host is sent, every time it is sent - nil until `finalize`
    var finalEvent: NewPumpEvent? {
        fixedFinalEvent(of: snapshot)
    }

    func fixedFinalEvent(of state: State) -> NewPumpEvent? {
        fixedFinalEntry(of: state).flatMap { NewPumpEvent.finishedDose(self, entry: $0) }
    }

    /// What a finished dose is finalized as when its record never turns up
    var fallbackDeliveredUnits: Double {
        fallbackAmount(of: snapshot)
    }

    func fallbackAmount(of state: State) -> Double {
        switch type {
        case .bolus:
            // A completed bolus carries the amount of its completion, a cancelled one the last amount the patch
            // reported. One we never saw end is assumed delivered in full.
            return countsInFull(state) ? value : state.deliveredUnits

        case .tempBasal:
            return tempBasalEstimate(of: state, restarted: false).units

        case .basal,
             .resume,
             .suspend:
            return 0
        }
    }

    /// What our estimate of a temp basal is based on
    public enum TempBasalEstimateSource: String {
        /// The amount the last status of its segment showed, and its rate since
        case status
        case rateTimesDuration = "rate × duration"
    }

    /// What a finished temp basal delivered, by our estimate: what the last status of its segment showed it had
    /// delivered, plus its rate from then to its end - within [that amount, rate × duration], in 0.05 U steps. Without
    /// such a status - or `restarted`, at patch-local midnight or by a profile change, which restarts that amount -
    /// its rate × duration. `until`: when it stopped delivering, if before its end as reported - one ended open stopped at
    /// the cancel, and is reported ended where the next one started, a few seconds on.
    func tempBasalEstimate(of state: State, restarted: Bool, until: Date? = nil) -> (units: Double, source: TempBasalEstimateSource) {
        let end = until.map { max(min($0, tempBasalEnd(of: state)), startDate) } ?? tempBasalEnd(of: state)
        let rateTimesDuration = estimatedTempBasalDelivery(until: end)

        guard !restarted, !state.recordMatchDisabled, let delivered = state.statusDelivery,
              let receivedAt = state.statusDeliveryReceivedAt
        else {
            return (rateTimesDuration, .rateTimesDuration)
        }

        let since = value * max(0, end.timeIntervalSince(receivedAt)) / .hours(1)
        let estimate = max(delivered, min(delivered + since, value * max(0, end.timeIntervalSince(startDate)) / .hours(1)))
        return (((estimate / 0.05).rounded() * 0.05).rounded(toPlaces: 2), .status)
    }

    /// A bolus that ended without our seeing how - over when we heard from the patch again, or one the patch never
    /// confirmed taking that was cancelled or cut off - counts as fully delivered until its record says otherwise
    func countsInFull(_ state: State) -> Bool {
        guard type == .bolus else {
            return false
        }

        switch state.finishReason {
        case .completionNotSeen:
            return true
        case .cancelled,
             .interrupted:
            return state.confirmation != .confirmed
        case .completed,
             .none:
            return false
        }
    }

    /// By when a running bolus should be over: its amount at `deadlineBolusUnitsPerMinute` from when its command went out
    /// (from its start, for one saved before that was kept), and `deliveryGrace`
    func deliveryDeadline(of state: State) -> Date {
        (state.sentAt ?? startDate).addingTimeInterval(.minutes(value / Self.deadlineBolusUnitsPerMinute) + Self.deliveryGrace)
    }

    /// When a bolus stopped delivering, having delivered `delivered`. Seen live, when it ended; otherwise extrapolated
    /// from the last progress (or its start) at the observed rate, never later than when we learned it was over.
    private func bolusEnd(of state: State, delivered: Double, now: Date = Date.now) -> Date {
        if let observedEndDate = state.observedEndDate {
            return observedEndDate
        }

        let latest = state.finishedAt ?? now
        let from = state.lastProgressAt ?? startDate
        let remaining = max(0, delivered - (state.lastProgressUnits ?? 0))
        let end = from.addingTimeInterval(.minutes(remaining / Self.observedBolusUnitsPerMinute))

        return max(min(end, latest), startDate)
    }

    /// When a finished temp basal stopped, as observed - never later than it was programmed to run
    func tempBasalEnd(of state: State, now: Date = Date.now) -> Date {
        let ended = state.observedEndDate ?? state.finishedAt ?? now
        return max(min(ended, estimatedEndDate), startDate)
    }

    /// Its rate × how long it ran, in 0.05 U steps, to the nearest - not onto the table of rates, which would floor it and
    /// cap it at the highest rate (a long temp basal delivers more than 30 U)
    private func estimatedTempBasalDelivery(until endDate: Date) -> Double {
        let units = value * (max(0, endDate.timeIntervalSince(startDate)) / .hours(1))
        return ((units / 0.05).rounded() * 0.05).rounded(toPlaces: 2)
    }

    private func bolusDoseEntry(isMutable: Bool, endDate: Date, deliveredUnits: Double?) -> DoseEntry {
        DoseEntry(
            type: .bolus,
            startDate: startDate,
            endDate: endDate,
            value: value.rounded(toPlaces: 2),
            unit: .units,
            deliveredUnits: deliveredUnits?.rounded(toPlaces: 2),
            insulinType: insulinType,
            automatic: automatic,
            isMutable: isMutable
        )
    }

    private func tempBasalDoseEntry(isMutable: Bool, endDate: Date, deliveredUnits: Double?) -> DoseEntry {
        DoseEntry(
            type: .tempBasal,
            startDate: startDate,
            endDate: endDate,
            value: value,
            unit: .unitsPerHour,
            // whole 0.05 U steps either way, without the floating point tail of `steps * 0.05`
            deliveredUnits: deliveredUnits?.rounded(toPlaces: 2),
            insulinType: insulinType,
            automatic: automatic,
            isMutable: isMutable
        )
    }

    private func roundBasalRate(_ rate: Double) -> Double {
        UnfinalizedDose.roundBasalRate(rate)
    }

    /// Snaps a value onto the increments the pump can actually meter. Note this *floors* rather than
    /// rounds to nearest, so a value between two increments is always reported low.
    static func roundBasalRate(_ rate: Double) -> Double {
        MedtrumPumpManager.onboardingSupportedBasalRates.last(where: { $0 <= rate }) ?? 0
    }

    public static func defaultBasalDose(basalSchedule: BasalSchedule, insulineType: InsulinType?) -> UnfinalizedDose {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)

        let currentRate = basalSchedule.entries.last(where: { $0.startTime <= nowTimeInterval })?.rate ?? 0
        return UnfinalizedDose(
            basalRate: currentRate,
            insulinType: insulineType,
            startDate: Date.now
        )
    }
}

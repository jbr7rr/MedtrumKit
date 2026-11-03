import CoreBluetooth
import LoopKit

public enum BasalState: Int {
    case active = 0
    case suspended = 1
    case tempBasal = 2
}

public enum BolusState: Int {
    case noBolus = 0
    case inProgress = 1
    case canceling = 2
}

public enum ExpiryMode: Int {
    case `default` = 1
    case extended = 2

    var lifespan: TimeInterval {
        switch self {
        case .default:
            return .hours(72)
        case .extended:
            return .hours(112)
        }
    }

    var gracePeriod: TimeInterval {
        .hours(8)
    }

    var timer: UInt8 {
        self == .default ? 1 : 0
    }
}

public struct PreviousPatch: Codable {
    public var patchId: Data
    public var lastStateRaw: UInt8
    public var lastSyncAt: Date
    public var battery: Double
    public var activatedAt: Date
    public var deactivatedAt: Date
    public var initialReservoirLevel: Double?
    public var reservoirLevel: Double?
}

/// A SetBolus on its way to the patch: saved before it is written, gone once its outcome is in. Found in the state of a
/// new run, it went out and the app was gone before its answer - the patch may be delivering it.
public struct PendingBolus: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public let units: Double
    public let sentAt: Date
    /// The newest record number known or claimed when it went out (`UnfinalizedDose.State.sequenceAtSend`): its record,
    /// if the patch ran it, is numbered past it
    public let sequenceAtSend: Int
    public let automatic: Bool

    public init(units: Double, sentAt: Date, sequenceAtSend: Int, automatic: Bool) {
        self.units = units
        self.sentAt = sentAt
        self.sequenceAtSend = sequenceAtSend
        self.automatic = automatic
    }

    public init?(rawValue: RawValue) {
        guard let units = rawValue["units"] as? Double, let sentAt = rawValue["sentAt"] as? Date,
              let sequenceAtSend = rawValue["sequenceAtSend"] as? Int, let automatic = rawValue["automatic"] as? Bool
        else {
            return nil
        }
        self.init(units: units, sentAt: sentAt, sequenceAtSend: sequenceAtSend, automatic: automatic)
    }

    public var rawValue: RawValue {
        ["units": units, "sentAt": sentAt, "sequenceAtSend": sequenceAtSend, "automatic": automatic]
    }
}

/// A bolus of ours that went final without its record - from our estimate - kept for its record, should it come after
/// all: it matches no dose then, and is not one the host is missing - but what it delivered may not be what the host
/// has (`MedtrumPumpManager.tellOfBolusRecord`, `compare`)
public struct BolusFinalWithoutRecord: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public let units: Double
    /// What its final said it delivered: what the host has
    public let delivered: Double
    public let sentAt: Date
    /// Where it started on the patch clock, as its answer said - nil, its answer was lost
    public let pumpStartTime: Date?
    /// The record its answer named - nil, its answer was lost
    public let recordSequence: Int?
    /// The possible record taken for its own as it went final (`MedtrumPumpManager.settlePossibleBolusRecords`) - nil,
    /// none was, or kept before they were: its own read later, that one is another bolus's, the host missing it
    public let taken: PossibleBolusRecord?

    public init(
        units: Double,
        delivered: Double,
        sentAt: Date,
        pumpStartTime: Date?,
        recordSequence: Int?,
        taken: PossibleBolusRecord? = nil
    ) {
        self.units = units
        self.delivered = delivered
        self.sentAt = sentAt
        self.pumpStartTime = pumpStartTime
        self.recordSequence = recordSequence
        self.taken = taken
    }

    public init?(rawValue: RawValue) {
        guard let units = rawValue["units"] as? Double, let sentAt = rawValue["sentAt"] as? Date else {
            return nil
        }
        self.init(
            units: units,
            // Kept before what it delivered was: counted in full, as one whose answer was lost
            delivered: rawValue["delivered"] as? Double ?? units,
            sentAt: sentAt,
            pumpStartTime: rawValue["pumpStartTime"] as? Date,
            recordSequence: rawValue["recordSequence"] as? Int,
            taken: (rawValue["taken"] as? PossibleBolusRecord.RawValue).flatMap(PossibleBolusRecord.init(rawValue:))
        )
    }

    public var rawValue: RawValue {
        var value: RawValue = ["units": units, "delivered": delivered, "sentAt": sentAt]
        value["pumpStartTime"] = pumpStartTime
        value["recordSequence"] = recordSequence
        value["taken"] = taken?.rawValue
        return value
    }
}

/// A bolus record that matched no dose of ours, but could be one whose answer was lost, still waiting on its record - by
/// its amount, starting further from when it went out than its record would: kept until that bolus settles
/// (`MedtrumPumpManager.settlePossibleBolusRecords`)
public struct PossibleBolusRecord: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public let sequence: Int
    public let amount: Double
    public let delivered: Double
    /// On the patch clock
    public let startTime: Date

    public init(sequence: Int, amount: Double, delivered: Double, startTime: Date) {
        self.sequence = sequence
        self.amount = amount
        self.delivered = delivered
        self.startTime = startTime
    }

    public init?(rawValue: RawValue) {
        guard let sequence = rawValue["sequence"] as? Int, let amount = rawValue["amount"] as? Double,
              let delivered = rawValue["delivered"] as? Double, let startTime = rawValue["startTime"] as? Date
        else {
            return nil
        }
        self.init(sequence: sequence, amount: amount, delivered: delivered, startTime: startTime)
    }

    public var rawValue: RawValue {
        ["sequence": sequence, "amount": amount, "delivered": delivered, "startTime": startTime]
    }
}

/// A SetTempBasal on its way to the patch, as `PendingBolus`: saved before it is written, gone once its outcome is in.
/// Found in the state of a new run, it went out and the app was gone before its answer - the patch may be running it,
/// and the cancel before it ended the temp basal running till then (`MedtrumPumpManager.takeOverPendingTempBasal`).
public struct PendingTempBasal: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public let unitsPerHour: Double
    public let duration: TimeInterval
    public let automatic: Bool
    public let sentAt: Date
    /// The newest record number known when it went out (`UnfinalizedDose.State.sequenceAtSend`)
    public let sequenceAtSend: Int
    /// The latest start of a segment the patch was known to run then, on its clock
    /// (`UnfinalizedDose.State.priorSegmentStart`)
    public let priorSegmentStart: Date?
    /// When the answered cancel that went out first ended the temp basal running before it - nil, none went out
    public let cancelledAt: Date?
    /// Where the segment that cancel started began, on the patch clock, as its answer said - nil, none went out, or its
    /// answer did not parse: the times of this one are then told through the skew
    public let cancelSegmentStart: Date?

    public init(
        unitsPerHour: Double,
        duration: TimeInterval,
        automatic: Bool,
        sentAt: Date,
        sequenceAtSend: Int,
        priorSegmentStart: Date?,
        cancelledAt: Date?,
        cancelSegmentStart: Date? = nil
    ) {
        self.unitsPerHour = unitsPerHour
        self.duration = duration
        self.automatic = automatic
        self.sentAt = sentAt
        self.sequenceAtSend = sequenceAtSend
        self.priorSegmentStart = priorSegmentStart
        self.cancelledAt = cancelledAt
        self.cancelSegmentStart = cancelSegmentStart
    }

    public init?(rawValue: RawValue) {
        guard let unitsPerHour = rawValue["unitsPerHour"] as? Double, let duration = rawValue["duration"] as? TimeInterval,
              let automatic = rawValue["automatic"] as? Bool, let sentAt = rawValue["sentAt"] as? Date,
              let sequenceAtSend = rawValue["sequenceAtSend"] as? Int
        else {
            return nil
        }
        self.init(
            unitsPerHour: unitsPerHour,
            duration: duration,
            automatic: automatic,
            sentAt: sentAt,
            sequenceAtSend: sequenceAtSend,
            priorSegmentStart: rawValue["priorSegmentStart"] as? Date,
            cancelledAt: rawValue["cancelledAt"] as? Date,
            cancelSegmentStart: rawValue["cancelSegmentStart"] as? Date
        )
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "unitsPerHour": unitsPerHour,
            "duration": duration,
            "automatic": automatic,
            "sentAt": sentAt,
            "sequenceAtSend": sequenceAtSend
        ]
        raw["priorSegmentStart"] = priorSegmentStart
        raw["cancelledAt"] = cancelledAt
        raw["cancelSegmentStart"] = cancelSegmentStart
        return raw
    }
}

/// A dose held back after a temp basal whose records are being read - see `MedtrumPumpState.heldBasalDoses` - and
/// since when
public struct HeldBasalDose {
    public let dose: UnfinalizedDose
    /// When it was held back: what its expiry counts from, as a final's does from when it was fixed - never before the
    /// temp basal's final, fixed once it goes out, can expire
    public let heldAt: Date

    public init(dose: UnfinalizedDose, heldAt: Date) {
        self.dose = dose
        self.heldAt = heldAt
    }

    /// The dose's own raw value, with when it was held. Saved without it by the build before: held as it is read back.
    init?(rawValue: UnfinalizedDose.RawValue, readAt: Date) {
        guard let dose = UnfinalizedDose(rawValue: rawValue) else {
            return nil
        }
        self.init(dose: dose, heldAt: rawValue["heldAt"] as? Date ?? readAt)
    }

    var rawValue: UnfinalizedDose.RawValue {
        var raw = dose.rawValue
        raw["heldAt"] = heldAt
        return raw
    }
}

/// A dose the driver could not be sure of - what the warning of uncertain delivery was about - for the settings
/// screen: why, and, once it is final, how it was settled. Kept until the user clears it, or a day after it was settled
/// (`keptSettled`).
public struct UncertainDelivery: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public enum Kind: String {
        case bolus
        /// A temp basal whose command went unanswered
        case tempBasal
        /// The cancel of a running temp basal, unanswered
        case tempBasalCancel
    }

    public enum Cause: String {
        /// The patch did not answer the command
        case unanswered
        /// The bolus was over by the time the patch was heard from again: how it ended was not seen
        case endNotSeen
        /// The app was gone while the command was out
        case appRestarted
        /// The patch was deactivated during the bolus
        case patchDeactivated
        /// A status showed the patch running a temp basal that is none of ours: one the app was gone before saving, say
        case unknownSegment
    }

    public enum Outcome: String {
        /// Final from the patch's records
        case byRecord
        /// Final without its record, from our estimate - counted in full, for a bolus the patch never confirmed
        case byEstimate
        /// The patch's records show it never ran
        case neverRan
        /// Given up on unconfirmed - a later command replaced it, or the patch session ended - not counted, though the
        /// patch may have run it
        case notConfirmed
        /// Its dose was found final, how is not known - the app was gone as it was finalized
        case final
        /// Its dose is no longer tracked
        case untracked
        /// A temp basal the driver has no dose of, seen running: what it delivers is not counted
        case notCounted
    }

    /// Where it is now, for a dose not settled taken from the state - see `MedtrumPumpState.phase(of:)`
    public enum Phase: Equatable {
        /// A bolus, counted in full until its record says what it delivered
        case countedInFull
        /// A bolus that ended, counted as what the patch reported it delivered until its record says
        case countedAs(Double)
        /// A temp basal not reported to the host until a status or its record shows it ran
        case notReported
        /// Shown to have run, or to have ended: final once its record is read
        case awaitingRecord
        /// A temp basal counted as running until a status shows whether the cancel stopped it
        case countedRunning
        /// A status showed the temp basal running after the cancel
        case stillRunning
        case settled(Outcome)
    }

    public let kind: Kind
    public let cause: Cause
    /// When the command of its dose went out: with the kind, which dose it is
    public let sentAt: Date
    /// Units, or units per hour for a temp basal
    public let amount: Double
    /// For how long a temp basal was set
    public let duration: TimeInterval?
    /// When it became uncertain
    public let notedAt: Date
    public internal(set) var outcome: Outcome?
    /// What its final says it delivered
    public internal(set) var delivered: Double?
    /// The record that settled it, where known
    public internal(set) var record: Int?
    public internal(set) var settledAt: Date?
    /// A cancel's: a status showed its temp basal still running after it - told of once settled too. False in a state
    /// saved before it was kept.
    public internal(set) var cancelDidNotStop = false

    public init(kind: Kind, cause: Cause, sentAt: Date, amount: Double, duration: TimeInterval? = nil, notedAt: Date) {
        self.kind = kind
        self.cause = cause
        self.sentAt = sentAt
        self.amount = amount
        self.duration = duration
        self.notedAt = notedAt
    }

    public init?(rawValue: RawValue) {
        guard let kind = (rawValue["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let cause = (rawValue["cause"] as? String).flatMap(Cause.init(rawValue:)),
              let sentAt = rawValue["sentAt"] as? Date, let amount = rawValue["amount"] as? Double,
              let notedAt = rawValue["notedAt"] as? Date
        else {
            return nil
        }
        self.init(
            kind: kind,
            cause: cause,
            sentAt: sentAt,
            amount: amount,
            duration: rawValue["duration"] as? TimeInterval,
            notedAt: notedAt
        )
        outcome = (rawValue["outcome"] as? String).flatMap(Outcome.init(rawValue:))
        delivered = rawValue["delivered"] as? Double
        record = rawValue["record"] as? Int
        settledAt = rawValue["settledAt"] as? Date
        cancelDidNotStop = rawValue["cancelDidNotStop"] as? Bool ?? false
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "kind": kind.rawValue,
            "cause": cause.rawValue,
            "sentAt": sentAt,
            "amount": amount,
            "notedAt": notedAt
        ]
        raw["duration"] = duration
        raw["outcome"] = outcome?.rawValue
        raw["delivered"] = delivered
        raw["record"] = record
        raw["settledAt"] = settledAt
        if cancelDidNotStop {
            raw["cancelDidNotStop"] = true
        }
        return raw
    }

    public var isSettled: Bool {
        outcome != nil
    }

    /// How long one stays listed once settled
    static let keptSettled: TimeInterval = .hours(24)

    /// `deliveries` without the ones settled more than `keptSettled` before `now`. Never one not settled.
    static func kept(_ deliveries: [UncertainDelivery], at now: Date) -> [UncertainDelivery] {
        deliveries.filter { delivery in
            guard delivery.isSettled else {
                return true
            }
            return now.timeIntervalSince(delivery.settledAt ?? delivery.notedAt) <= keptSettled
        }
    }

    /// Whether it is about `dose`
    func isOf(_ dose: UnfinalizedDose) -> Bool {
        isOf(DoseKey(dose))
    }

    /// Whether it is about the dose of `key`: of its type, its command sent when this one was - saved and read back as
    /// they may have been
    func isOf(_ key: DoseKey) -> Bool {
        guard (kind == .bolus) == (key.type == .bolus), key.type == .bolus || key.type == .tempBasal else {
            return false
        }
        return abs(key.sentAt.timeIntervalSince(sentAt)) < 0.1
    }

    /// Which dose it is: its type, and when its command went out - taken outside the lock of the deliveries, the dose's
    /// own being taken for it
    struct DoseKey {
        let type: DoseType
        let sentAt: Date

        init(_ dose: UnfinalizedDose) {
            type = dose.type
            sentAt = dose.snapshot.sentAt ?? dose.startDate
        }
    }
}

public class MedtrumPumpState: RawRepresentable {
    public typealias RawValue = PumpManager.RawStateValue

    public required init(rawValue: RawValue) {
        isOnboarded = rawValue["isOnboarded"] as? Bool ?? false
        lastSync = rawValue["lastSync"] as? Date ?? Date.distantPast
        pumpSN = rawValue["pumpSN"] as? Data ?? Data()
        useSilentTones = rawValue["useSilentTones"] as? Bool ?? false
        lowReservoirWarning = rawValue["lowReservoirWarning"] as? Double
        sessionToken = rawValue["sessionToken"] as? Data ?? Data()
        backupSessionToken = rawValue["backupSessionToken"] as? Data ?? Data()
        patchId = rawValue["patchId"] as? Data ?? Data()
        peripheralIdentifier = (rawValue["peripheralIdentifier"] as? String).flatMap { UUID(uuidString: $0) }
        currentSequenceNumber = rawValue["currentSequenceNumber"] as? Int ?? 0
        syncedSequenceNumber = rawValue["syncedSequenceNumber"] as? Int ?? 0
        // Absent in state written before records were matched: never told, nothing skipped or answered
        sequenceConfirmedAt = rawValue["sequenceConfirmedAt"] as? Date
        skippedRecordSequences = rawValue["skippedRecordSequences"] as? [Int] ?? []
        // Saved as number and patch start before builds kept the number only
        answeredBolusRecords = rawValue["answeredBolusRecords"] as? [Int] ??
            (rawValue["answeredBolusRecords"] as? [[String: Any]] ?? []).compactMap { $0["sequence"] as? Int }
        // Absent in state written before unmatched bolus records were told of: the records read by then are not told of
        sessionStartSequence = rawValue["sessionStartSequence"] as? Int ?? syncedSequenceNumber
        unmatchedBolusRecords = rawValue["unmatchedBolusRecords"] as? [Int] ?? []
        bolusesFinalWithoutRecord = (rawValue["bolusesFinalWithoutRecord"] as? [BolusFinalWithoutRecord.RawValue] ?? [])
            .compactMap(BolusFinalWithoutRecord.init(rawValue:))
        possibleBolusRecords = (rawValue["possibleBolusRecords"] as? [PossibleBolusRecord.RawValue] ?? [])
            .compactMap(PossibleBolusRecord.init(rawValue:))
        patchActivatedAt = rawValue["patchActivatedAt"] as? Date ?? nil
        deviceType = rawValue["deviceType"] as? UInt8 ?? 0
        swVersion = rawValue["swVersion"] as? String ?? "0.0.0"
        pumpTime = rawValue["pumpTime"] as? Date ?? Date()
        pumpTimeSyncedAt = rawValue["pumpTimeSyncedAt"] as? Date ?? Date()
        patchUTCOffset = rawValue["patchUTCOffset"] as? TimeInterval
        maxHourlyInsulin = rawValue["maxHourlyInsulin"] as? Double ?? 20
        maxDailyInsulin = rawValue["maxDailyInsulin"] as? Double ?? 100
        initialReservoir = rawValue["initialReservoir"] as? Double
        reservoir = rawValue["reservoir"] as? Double ?? 0
        battery = rawValue["battery"] as? Double ?? 0
        notificationAfterActivation = rawValue["notificationAfterActivation"] as? TimeInterval ?? .hours(72)

        if let expiryModeRaw = rawValue["expiryMode"] as? ExpiryMode.RawValue {
            expiryMode = ExpiryMode(rawValue: expiryModeRaw) ?? .default
        } else if let expirationTimer = rawValue["expirationTimer"] as? UInt8 {
            expiryMode = expirationTimer == 1 ? .default : .extended
        } else {
            expiryMode = .default
        }

        if let previousPatchRaw = rawValue["previousPatch"] as? Data {
            do {
                previousPatch = try JSONDecoder().decode(PreviousPatch.self, from: previousPatchRaw)
            } catch {}
        }

        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        }

        if let pumpStateRaw = rawValue["pumpState"] as? PatchState.RawValue {
            pumpState = PatchState(rawValue: pumpStateRaw) ?? .none
        } else {
            pumpState = .none
        }
        // Not kept by earlier versions: then unknown
        lastShownNotDeliveringAt = rawValue["lastShownNotDeliveringAt"] as? Date

        // Not kept by earlier versions: then only a patch being set up has no session
        patchSessionEnded = rawValue["patchSessionEnded"] as? Bool ?? pumpState.isSetup

        if let rawBasalSchedule = rawValue["basalSchedule"] as? BasalSchedule.RawValue {
            basalSchedule = BasalSchedule(rawValue: rawBasalSchedule) ??
                BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }

        if let basalStateRaw = rawValue["basalState"] as? BasalState.RawValue {
            basalState = BasalState(rawValue: basalStateRaw) ?? .active
        } else {
            basalState = .active
        }

        if let alarmSettingRaw = rawValue["alarmSetting"] as? AlarmSettings.RawValue {
            alarmSetting = AlarmSettings(rawValue: alarmSettingRaw) ?? .BeepOnly
        } else {
            alarmSetting = .BeepOnly
        }

        // Absent in state written before boluses were saved ahead of their command: none
        pendingBolus = (rawValue["pendingBolus"] as? PendingBolus.RawValue).flatMap(PendingBolus.init(rawValue:))
        // Absent in state written before temp basals were saved ahead of their command, or before what followed a temp
        // basal being read was: none
        pendingTempBasal = (rawValue["pendingTempBasal"] as? PendingTempBasal.RawValue).flatMap(PendingTempBasal.init(rawValue:))
        let readAt = Date.now
        heldBasalDoses = (rawValue["heldBasalDoses"] as? [UnfinalizedDose.RawValue] ?? []).compactMap {
            HeldBasalDose(rawValue: $0, readAt: readAt)
        }

        if let rawDoseEntry = rawValue["bolusDose"] as? UnfinalizedDose.RawValue {
            bolusDose = UnfinalizedDose(rawValue: rawDoseEntry)
        } else {
            bolusDose = nil
        }

        // Absent in state written before it was kept: worked out from the doses below, see `MedtrumPumpManager`
        loopWatermark = rawValue["loopWatermark"] as? Date
        if let rawDoseEntry = rawValue["basalDose"] as? UnfinalizedDose.RawValue, let decoded = UnfinalizedDose(rawValue: rawDoseEntry) {
            basalDose = decoded
            basalDoseIsPlaceholder = rawValue["basalDoseIsPlaceholder"] as? Bool ?? false
        } else {
            basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
            basalDoseIsPlaceholder = true
        }

        // Absent in state written before records were matched: none
        unconfirmedTempBasal = (rawValue["unconfirmedTempBasal"] as? UnfinalizedDose.RawValue).flatMap(UnfinalizedDose.init(rawValue:))
        var awaitingRecord = Self.deduplicated(
            (rawValue["awaitingRecord"] as? [UnfinalizedDose.RawValue] ?? []).compactMap(UnfinalizedDose.init(rawValue:))
        )

        // A dose moves from running to waiting in two steps, and the state may have been saved in between: it is then
        // in both places, or finished as the running one only. One dose again, waiting - a copy would be finished, and
        // reported, a second time. The temp basal gives way to the scheduled basal until the next status says what runs.
        func isWaiting(_ dose: UnfinalizedDose) -> Bool {
            if awaitingRecord.contains(where: { $0.isSameDose(as: dose) }) {
                return true
            }
            guard dose.isFinished else {
                return false
            }
            awaitingRecord.append(dose)
            return true
        }
        if let running = bolusDose, isWaiting(running) {
            bolusDose = nil
        }
        if isWaiting(basalDose) {
            basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
            basalDoseIsPlaceholder = true
        }

        awaitingRecordStorage = Locked(awaitingRecord)
        uncertainDeliveriesStorage = Locked(
            (rawValue["uncertainDeliveries"] as? [UncertainDelivery.RawValue] ?? []).compactMap(UncertainDelivery.init(rawValue:))
        )
        // Saved as its dose was finalized, before it was settled
        settleOrphanedUncertainDeliveries(at: Date.now)
    }

    /// One entry per dose. Of two copies of a dose, the one with a final is kept: that final may have reached the host.
    static func deduplicated(_ doses: [UnfinalizedDose]) -> [UnfinalizedDose] {
        var kept: [UnfinalizedDose] = []

        for dose in doses {
            guard let index = kept.firstIndex(where: { $0.isSameDose(as: dose) }) else {
                kept.append(dose)
                continue
            }

            if dose.isFinalized, !kept[index].isFinalized {
                kept[index] = dose
            }
        }

        return kept
    }

    public init(_ basal: BasalRateSchedule?) {
        isOnboarded = false
        lastSync = Date.distantPast
        pumpSN = Data()
        useSilentTones = false
        lowReservoirWarning = nil
        pendingBolus = nil
        pendingTempBasal = nil
        heldBasalDoses = []
        bolusDose = nil
        unconfirmedTempBasal = nil
        awaitingRecordStorage = Locked([])
        uncertainDeliveriesStorage = Locked([])
        sessionToken = Data()
        backupSessionToken = Data()
        patchId = Data()
        peripheralIdentifier = nil
        currentSequenceNumber = 0
        syncedSequenceNumber = 0
        sequenceConfirmedAt = nil
        skippedRecordSequences = []
        answeredBolusRecords = []
        sessionStartSequence = 0
        unmatchedBolusRecords = []
        bolusesFinalWithoutRecord = []
        possibleBolusRecords = []
        patchActivatedAt = nil
        deviceType = 0
        swVersion = "0.0.0"
        pumpTime = Date()
        pumpTimeSyncedAt = Date()
        patchUTCOffset = nil
        pumpState = .none
        lastShownNotDeliveringAt = nil
        patchSessionEnded = true

        maxHourlyInsulin = 20
        maxDailyInsulin = 100
        reservoir = 0
        battery = 0
        basalState = .active
        alarmSetting = .BeepOnly
        expiryMode = .default
        notificationAfterActivation = .hours(72)
        previousPatch = nil

        if let basal = basal {
            basalSchedule = BasalSchedule(entries: basal.items)
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }

        basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
        basalDoseIsPlaceholder = true
    }

    public var rawValue: RawValue {
        var value: [String: Any] = [:]

        value["isOnboarded"] = isOnboarded
        value["lastSync"] = lastSync
        value["insulinType"] = insulinType?.rawValue
        value["lowReservoirWarning"] = lowReservoirWarning
        value["pumpSN"] = pumpSN
        value["sessionToken"] = sessionToken
        value["backupSessionToken"] = backupSessionToken
        value["patchId"] = patchId
        value["peripheralIdentifier"] = peripheralIdentifier?.uuidString
        value["currentSequenceNumber"] = currentSequenceNumber
        value["syncedSequenceNumber"] = syncedSequenceNumber
        value["sequenceConfirmedAt"] = sequenceConfirmedAt
        if !skippedRecordSequences.isEmpty {
            value["skippedRecordSequences"] = skippedRecordSequences
        }
        if !answeredBolusRecords.isEmpty {
            value["answeredBolusRecords"] = answeredBolusRecords
        }
        value["sessionStartSequence"] = sessionStartSequence
        if !unmatchedBolusRecords.isEmpty {
            value["unmatchedBolusRecords"] = unmatchedBolusRecords
        }
        if !bolusesFinalWithoutRecord.isEmpty {
            value["bolusesFinalWithoutRecord"] = bolusesFinalWithoutRecord.map(\.rawValue)
        }
        if !possibleBolusRecords.isEmpty {
            value["possibleBolusRecords"] = possibleBolusRecords.map(\.rawValue)
        }
        value["patchActivatedAt"] = patchActivatedAt
        value["patchGracePeriodFrom"] = patchGracePeriodFrom
        value["patchExpiresAt"] = patchExpiresAt
        value["deviceType"] = deviceType
        value["swVersion"] = swVersion
        value["pumpTime"] = pumpTime
        value["pumpTimeSyncedAt"] = pumpTimeSyncedAt
        value["patchUTCOffset"] = patchUTCOffset
        value["pumpState"] = pumpState.rawValue
        value["lastShownNotDeliveringAt"] = lastShownNotDeliveringAt
        value["patchSessionEnded"] = patchSessionEnded
        value["maxHourlyInsulin"] = maxHourlyInsulin
        value["maxDailyInsulin"] = maxDailyInsulin
        value["basalSchedule"] = basalSchedule.rawValue
        value["initialReservoir"] = initialReservoir
        // The running doses before the ones waiting: a dose is added to `awaitingRecord` before it stops being the
        // running one, so read in this order it is saved in one of them at least - see `init(rawValue:)`. The pending
        // bolus and temp basal first of all: each is cleared after its dose is registered. What is held back after a
        // temp basal being read after the running basal: kept before the dose that followed that temp basal runs. The
        // manager saves the state under its `doseReportLock` besides (`MedtrumPumpManager.rawState`).
        value["pendingBolus"] = pendingBolus?.rawValue
        value["pendingTempBasal"] = pendingTempBasal?.rawValue
        value["bolusDose"] = bolusDose?.rawValue
        value["basalDose"] = basalDose.rawValue
        value["loopWatermark"] = loopWatermark
        if basalDoseIsPlaceholder {
            value["basalDoseIsPlaceholder"] = true
        }
        if !heldBasalDoses.isEmpty {
            value["heldBasalDoses"] = heldBasalDoses.map(\.rawValue)
        }
        value["unconfirmedTempBasal"] = unconfirmedTempBasal?.rawValue
        value["awaitingRecord"] = awaitingRecord.map(\.rawValue)
        value["uncertainDeliveries"] = uncertainDeliveries.map(\.rawValue)
        value["reservoir"] = reservoir
        value["battery"] = battery
        value["basalState"] = basalState.rawValue
        value["alarmSetting"] = alarmSetting.rawValue
        value["expiryMode"] = expiryMode.rawValue
        value["notificationAfterActivation"] = notificationAfterActivation
        value["useSilentTones"] = useSilentTones

        if let previousPatch = previousPatch {
            do {
                value["previousPatch"] = try JSONEncoder().encode(previousPatch)
            } catch {}
        }

        return value
    }

    public var isOnboarded: Bool
    public var insulinType: InsulinType?
    public var lastSync: Date
    public var pumpSN: Data {
        didSet {
            guard pumpSN != oldValue else {
                return
            }

            // prevent ensureConnected from reconnecting straight back to the previous base
            peripheralIdentifier = nil
        }
    }

    public var lowReservoirWarning: Double?
    public var useSilentTones: Bool

    // Patch specific data
    public var sessionToken: Data
    public var backupSessionToken: Data
    public var patchId: Data

    /// The CoreBluetooth identifier of the pump base we are paired with - the base carries the
    /// radio, so this survives a patch change. iOS keeps it stable, which lets us get a
    /// `CBPeripheral` back with `retrievePeripherals(withIdentifiers:)` instead of scanning. That
    /// matters because scanning finds nothing while the app is in the background, whereas
    /// reconnecting to a known peripheral is honoured there.
    public var peripheralIdentifier: UUID?


    /// The highest record number the patch says it has written - the pump reports it in the storage
    /// field of every full status response
    public var currentSequenceNumber: Int
    /// The highest record number we have read back from the patch. Records are numbered per patch,
    /// so this resets whenever `patchId` changes.
    public var syncedSequenceNumber: Int
    /// When the patch last told us its newest record is `currentSequenceNumber` - the storage field of a status, or
    /// the answer to a command that ended a segment - on the manager's clock. A dose's record is written when it ends:
    /// the cursor at a number told before then says nothing of it (`MedtrumPumpManager.isCaughtUp`). Nil until told.
    public var sequenceConfirmedAt: Date?
    /// The latest such telling in this run of the app, on the manager's clock and on the monotonic one - what a bolus's
    /// deadline is checked against, out of reach of a change of the wall clock (`MedtrumPumpManager.sequenceConfirmed`).
    /// Never saved: the monotonic clock of another run, maybe another boot, is not ours. Nil until told in this run.
    public var sequenceConfirmedInThisRun: (at: Date, uptime: TimeInterval)?
    /// Records the sync gave up on as unreadable, never read: only those that could be the record of the unconfirmed
    /// temp basal - numbered past the newest record known when its command went out. It is then never dropped for
    /// having no record. Per patch.
    public var skippedRecordSequences: [Int]
    /// The record numbers the SetBolus answers gave our latest boluses. Assumed: a bolus answered with a record number
    /// has claimed that record - the patch writes that bolus's record under it, whatever becomes of the bolus, and
    /// gives the number to nothing else. So a record with one of these numbers is that bolus's, even one finalized or
    /// gone since - never the record of one whose answer was lost, and the record of a bolus sent later is numbered past
    /// the newest of them (its `PendingBolus.sequenceAtSend` takes it in). Kept while the record may still be read - see
    /// `MedtrumPumpManager.noteAnsweredBolusRecord`. Per patch.
    public var answeredBolusRecords: [Int]
    /// The newest record the patch had written as this state took it up - 0, a patch it activated, or no patch: the
    /// records up to it were written before, none of their doses ours to tell of
    /// (`MedtrumPumpManager.warnOfBolusNotCounted`). Per patch.
    public var sessionStartSequence: Int
    /// The bolus records that matched no dose of ours, each looked at once: the user told of it, or a bolus of ours
    /// final without its record found to be it - read again, nothing more is done. Per patch.
    public var unmatchedBolusRecords: [Int]
    /// The latest boluses of ours final without their record - see `BolusFinalWithoutRecord`. Per patch.
    public var bolusesFinalWithoutRecord: [BolusFinalWithoutRecord]
    /// The unmatched bolus records a bolus of ours whose answer was lost could be - see `PossibleBolusRecord`.
    /// Per patch.
    public var possibleBolusRecords: [PossibleBolusRecord]

    /// Forgets what belonged to the records of the patch before
    func resetRecordSequence() {
        currentSequenceNumber = 0
        syncedSequenceNumber = 0
        sequenceConfirmedAt = nil
        sequenceConfirmedInThisRun = nil
        skippedRecordSequences = []
        answeredBolusRecords = []
        sessionStartSequence = 0
        unmatchedBolusRecords = []
        bolusesFinalWithoutRecord = []
        possibleBolusRecords = []
    }

    public var patchActivatedAt: Date?
    public var patchGracePeriodFrom: Date? {
        guard let activatedAt = patchActivatedAt else {
            return nil
        }

        return activatedAt.addingTimeInterval(expiryMode.lifespan)
    }

    public var patchExpiresAt: Date? {
        guard let activatedAt = patchActivatedAt else {
            return nil
        }

        return activatedAt.addingTimeInterval(expiryMode.lifespan + expiryMode.gracePeriod)
    }

    public var previousPatch: PreviousPatch?

    public var deviceType: UInt8
    public var swVersion: String

    public var pumpTime: Date
    public var pumpTimeSyncedAt: Date

    /// How far the patch clock runs ahead of ours, as of the last time we read it
    var patchClockSkew: TimeInterval {
        pumpTime.timeIntervalSince(pumpTimeSyncedAt)
    }

    /// The UTC offset we set on the patch with SetTimeZone: patch-local midnight, where the patch splits a temp basal
    /// into two records, is on it. Nil for a patch set up before this was kept.
    public var patchUTCOffset: TimeInterval?

    public var pumpState: PatchState
    /// When a status of the patch last showed it not delivering - the one `pumpState` is from, while that shows it so.
    /// Unlike `lastSync`, which a command's answer moves too, telling nothing of the patch's state. Nil until shown.
    public var lastShownNotDeliveringAt: Date?
    /// No patch session is running: the last one ended, or none started yet
    public var patchSessionEnded: Bool
    public var initialReservoir: Double?
    public var reservoir: Double
    public var battery: Double

    // Patch settings
    public var maxHourlyInsulin: Double
    public var maxDailyInsulin: Double
    public var alarmSetting: AlarmSettings
    public var expiryMode: ExpiryMode
    public var notificationAfterActivation: TimeInterval

    /// A cancel of a bolus asked for and not yet over (`MedtrumPumpManager.cancelBolus`): of the bolus running when it was
    /// asked for - or, none running, the one whose SetBolus was out (`pendingSentAt`) - else of none known. It shows
    /// `.canceling` only while that bolus is still the one running: a new bolus is never shown, nor refused, as being
    /// cancelled by a cancel of the one before - and the cancel, once it has the link, writes nothing for it. One of none
    /// known never shows: it stops nothing that runs (`isOfTheRunningBolus`), and showing would only refuse dosing.
    struct BolusCancel {
        let id = UUID()
        let since: Date
        let dose: UnfinalizedDose?
        let pendingSentAt: Date?
    }

    /// The cancels of a bolus not yet over - see `BolusCancel`. Ended as each completes; a completion `ensureConnected`
    /// orphans would leave one for good, so each also runs out after `cancelBolusBackstop`.
    private let bolusCancels = Locked<[BolusCancel]>([])

    /// A cancel's longest run: a connect - joining one past didConnect, its session watchdog 150 s
    /// (`BluetoothManager`), the steps before it 15 s each - the wait for the command lock (`commandActivityTimeout`,
    /// 3 min) and the write (`PeripheralManager.writeTimeout`, 30 s): some 6 min, rounded up. Only a backstop for one
    /// orphaned: its bolus over, a cancel shows `.canceling` no longer anyway, and one of none known never does.
    static let cancelBolusBackstop: TimeInterval = .minutes(7)

    /// The manager's `doseReportLock`, which `bolusDose` and `pendingBolus` change under: a cancel outstanding, whether
    /// it is of the running bolus is read under it (`cancelingBolusSince`)
    weak var doseLock: NSRecursiveLock?

    // **** THESE VALUES SHOULD NOT BE PERSISTED ****
    public var primeProgress: UInt8 = 0
    public var isConnected: Bool = false
    /// When the earliest cancel still showing `.canceling` was asked for - see `BolusCancel`. Not persisted: restored,
    /// nothing would end it.
    public var cancelingBolusSince: Date? {
        let cancels = bolusCancels.value
        guard !cancels.isEmpty else {
            return nil
        }
        let now = Date.now
        let since = { cancels.filter { self.isShowing($0, at: now) }.map(\.since).min() }
        return doseLock.map { $0.withLock(since) } ?? since()
    }
    // last state CoreBluetooth reported
    public var bluetoothState: CBManagerState = .unknown
    /// The latest start of a basal segment the patch reported, on its clock - from statuses and command answers.
    /// What an unanswered temp basal's segment must have started after.
    var lastSegmentStart: Date?
    // **** END ****

    public var bolusDose: UnfinalizedDose?

    /// The SetBolus being written, saved - and handed to the host - before it goes out, never written unless the host
    /// took it (`MedtrumPumpManager.handOverState`): an app killed before its answer comes back with it here, and runs it
    /// as a bolus whose command went unanswered (`MedtrumPumpManager.takeOverPendingBolus`). Cleared as its outcome is
    /// in, with the dose registered in the same step if there is one - or as it is not written after all.
    public var pendingBolus: PendingBolus?

    /// The SetTempBasal being written, saved - and handed to the host - before it goes out, as `pendingBolus`: an app
    /// killed before its answer comes back with it here, and keeps it as a temp basal whose command went unanswered
    /// (`MedtrumPumpManager.takeOverPendingTempBasal`). Cleared as its outcome is in, after its dose is in place if there
    /// is one. Changed under `MedtrumPumpManager.doseReportLock`.
    public var pendingTempBasal: PendingTempBasal?

    /// What followed a temp basal whose records are being read - a suspend, a resume, the scheduled basal - its report
    /// held back until the temp basal's final goes out (`MedtrumPumpManager.TempBasalEnd`), saved until the host
    /// confirms storing a batch that carried it: an app killed meanwhile reports them after all, in its first batch,
    /// with that temp basal final from our estimate - and a batch the host could not store has them go out again, with
    /// that final. A temp basal that followed is not kept here: it runs, and goes out with every batch. Kept here too: a
    /// suspend held back for the records of the temp basal whose command went unanswered
    /// (`MedtrumPumpManager.holdForUnconfirmedRead`), and what is held with it - a resume, a suspend - in the order they
    /// go out. And every other suspend and resume reported, until the host confirms storing it: handed over once, a kill
    /// before the host stored it would lose it for good (`MedtrumPumpManager.keepUntilStored`). Empty otherwise. Changed
    /// under `MedtrumPumpManager.doseReportLock`.
    public var heldBasalDoses: [HeldBasalDose]

    /// A temp basal whose command went out unanswered: kept here, unreported, until a status shows the patch running it
    /// - it then runs - or its record turns up - its final, or a part of it, then finalized from our estimate - or every
    /// record the patch told of 15 min past when it ended at the latest was read, none that could be its skipped -
    /// dropped (`MedtrumPumpManager.unconfirmedTempBasalEnd`). No time limit otherwise: while records cannot be read it
    /// stays, and delivery stays uncertain. The patch session ending drops it. The host keeps counting what it counted
    /// before. Changed under `MedtrumPumpManager.doseReportLock`.
    public var unconfirmedTempBasal: UnfinalizedDose?

    /// Boluses and temp basals that stopped running, until the host has confirmed storing their final report.
    ///
    /// A bolus stays mutable until the patch's record for it has been read, or until we give up on the record. So does a
    /// temp basal a new one replaced back to back, ended open - see `MedtrumPumpManager.openTempBasalEnds`. Any other temp
    /// basal is final as it ends: it is here unfinalized only while its records are read, never reported so - see
    /// `MedtrumPumpManager.TempBasalEnd`. Once finalized a dose stays here with its final, which goes out with every
    /// batch until the host confirms a batch that carried it - see `MedtrumPumpManager.emitPumpEvents`.
    ///
    /// Locked: commands, statuses and the record sync add to and take from it on different queues.
    public var awaitingRecord: [UnfinalizedDose] {
        awaitingRecordStorage.value
    }

    func mutateAwaitingRecord(_ changes: (inout [UnfinalizedDose]) -> Void) {
        awaitingRecordStorage.mutate(changes)
    }

    private let awaitingRecordStorage: Locked<[UnfinalizedDose]>

    /// The doses the driver could not be sure of, oldest first - see `UncertainDelivery`. Locked, as `awaitingRecord`.
    /// Without the ones settled over a day ago: they drop out as the settings screen reads them and as the state is saved.
    public var uncertainDeliveries: [UncertainDelivery] {
        UncertainDelivery.kept(uncertainDeliveriesStorage.value, at: wallClock())
    }

    func mutateUncertainDeliveries(_ changes: (inout [UncertainDelivery]) -> Void) {
        uncertainDeliveriesStorage.mutate(changes)
    }

    private let uncertainDeliveriesStorage: Locked<[UncertainDelivery]>

    /// The doses tracked, running or waiting
    private var trackedDoses: [UnfinalizedDose] {
        [bolusDose, basalDose, unconfirmedTempBasal].compactMap { $0 } + awaitingRecord
    }

    /// Settles every uncertain delivery left unsettled whose dose is final - how is not known - or no longer tracked:
    /// as the state was saved between the two, or the session ended
    func settleOrphanedUncertainDeliveries(at now: Date) {
        let doses = trackedDoses.map { (key: UncertainDelivery.DoseKey($0), final: $0.snapshot) }
        mutateUncertainDeliveries { deliveries in
            for index in deliveries.indices where !deliveries[index].isSettled {
                let dose = doses.first { deliveries[index].isOf($0.key) }
                if let dose, !dose.final.isFinalized {
                    continue
                }
                deliveries[index].outcome = dose == nil ? .untracked : .final
                deliveries[index].delivered = dose?.final.finalDeliveredUnits
                deliveries[index].settledAt = now
            }
        }
    }

    /// Where `delivery` is now: settled, or what the state says of its dose
    public func phase(of delivery: UncertainDelivery) -> UncertainDelivery.Phase {
        if let outcome = delivery.outcome {
            return .settled(outcome)
        }

        switch delivery.kind {
        case .bolus:
            // Running, it counts in full; ended, as the host is told
            guard let dose = trackedDoses.first(where: delivery.isOf) else {
                return .countedInFull
            }
            let ended = dose.snapshot
            guard ended.isFinished, !dose.countsInFull(ended) else {
                return .countedInFull
            }
            return .countedAs(ended.deliveredUnits)
        case .tempBasal:
            return unconfirmedTempBasal.map(delivery.isOf) == true ? .notReported : .awaitingRecord
        case .tempBasalCancel:
            let running = basalDose.snapshot
            guard delivery.isOf(basalDose), !running.isFinished else {
                return .awaitingRecord
            }
            return running.stopUnansweredAt != nil ? .countedRunning : .stillRunning
        }
    }

    /// No session runs, and the patch last reported a state it never leaves: the old patch, stopped as its session ended -
    /// nothing to sync with it, and the new patch's setup that follows is no base reset. Not a running patch with no
    /// session: its activation's answer was lost.
    var stoppedWithNoSession: Bool {
        patchSessionEnded && pumpState.isTerminated
    }

    /// A bolus whose command went unanswered, still running as far as we know, or a temp basal whose command went
    /// unanswered and is not settled - or a cancel of the running one. For the host's `deliveryIsUncertain`. One that
    /// ended has its count settled by its record or the fallback, counting the more insulin meanwhile.
    public var deliveryIsUncertain: Bool {
        if let bolus = bolusDose?.snapshot, bolus.confirmation == .uncertain, !bolus.isFinished {
            return true
        }

        if unconfirmedTempBasal != nil {
            return true
        }

        let basal = basalDose
        let running = basal.snapshot
        return basal.type == .tempBasal && running.stopUnansweredAt != nil && !running.isFinished &&
            Date.now < basal.estimatedEndDate
    }

    private var isCancelingBolus: Bool {
        cancelingBolusSince != nil
    }

    /// A cancel of a bolus is asked for, of the one running now - or whose SetBolus is out - if any. Ended with
    /// `endBolusCancel`.
    func beginBolusCancel(at date: Date = Date.now) -> BolusCancel {
        let cancel: BolusCancel
        if let running = bolusDose, !running.isFinished {
            cancel = BolusCancel(since: date, dose: running, pendingSentAt: nil)
        } else {
            cancel = BolusCancel(since: date, dose: nil, pendingSentAt: pendingBolus?.sentAt)
        }
        bolusCancels.mutate { $0.append(cancel) }
        return cancel
    }

    func endBolusCancel(_ cancel: BolusCancel) {
        bolusCancels.mutate { $0.removeAll { $0.id == cancel.id } }
    }

    /// Whether `cancel` is of the bolus running now: the one it was asked for, still running - the one whose SetBolus
    /// was out, running or its command still out - or, of none known, none running nor out. A new bolus since is not
    /// what it was asked to stop.
    func isOfTheRunningBolus(_ cancel: BolusCancel) -> Bool {
        let running = bolusDose.flatMap { $0.isFinished ? nil : $0 }
        if let dose = cancel.dose {
            return running === dose
        }
        if let sentAt = cancel.pendingSentAt {
            return running?.sentAt == sentAt || (running == nil && pendingBolus?.sentAt == sentAt)
        }
        return running == nil && pendingBolus == nil
    }

    private func isShowing(_ cancel: BolusCancel, at now: Date) -> Bool {
        (cancel.dose != nil || cancel.pendingSentAt != nil) &&
            now.timeIntervalSince(cancel.since) < Self.cancelBolusBackstop && isOfTheRunningBolus(cancel)
    }

    public var bolusState: BolusState {
        if isCancelingBolus {
            return .canceling
        }

        return bolusDose == nil ? .noBolus : .inProgress
    }

    // basalState is the basalState from the patch itself
    // Preventing acting on an out-dated basalDose
    public var basalState: BasalState
    public var basalDose: UnfinalizedDose {
        didSet {
            basalDoseSince = monotonicClock()
            basalDoseIsPlaceholder = false
        }
    }

    /// `basalDose` stands in for what the patch runs, the host never told of it: the schedule put in place as the state
    /// was read back - none saved, or the temp basal saved there had ended - or at the activation of a patch. Anything
    /// set later, or reported, clears it. Nothing is dated after it as after something the host has.
    public internal(set) var basalDoseIsPlaceholder = false

    /// Loop's watermark, as what was handed to the host makes it - see `LoopWatermark`,
    /// `MedtrumPumpManager.warnIfBehindWhatIsFinal`. Saved: a restart keeps it. Changed under
    /// `MedtrumPumpManager.doseReportLock`.
    public internal(set) var loopWatermark: Date?

    /// When `basalDose` was put in place in this run, on the manager's monotonic clock: a status received before then
    /// says nothing of it. Nil for one read back with the state. Never saved: another run's monotonic clock is not ours.
    var basalDoseSince: TimeInterval?
    /// The manager's monotonic clock (`MedtrumPumpManager.uptime`) - only tests move it
    var monotonicClock: () -> TimeInterval = { .continuousUptime }
    /// The manager's `now`, which settles uncertain deliveries: the one their day is counted on
    var wallClock: () -> Date = { Date.now }
    public var basalSchedule: BasalSchedule

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        switch basalDose.type {
        case .basal,
             .bolus,
             .resume:
            return .active(basalDose.startDate)
        case .suspend:
            return .suspended(basalDose.startDate)
        case .tempBasal:
            // One that ended, while what follows it is put in place: the scheduled basal runs
            let dose = basalDose
            let tempBasal = dose.snapshot
            guard !tempBasal.isFinished else {
                return .active(dose.tempBasalEnd(of: tempBasal))
            }
            return .tempBasal(dose.doseEntry(of: tempBasal, isMutable: true))
        }
    }

    var bolusDeliveryState: PumpManagerStatus.BolusState {
        if isCancelingBolus {
            return .canceling
        }

        guard let dose = bolusDose?.toDoseEntry(isMutable: true) else {
            return .noBolus
        }

        return .inProgress(dose)
    }

    public var currentBaseBasalRate: Double {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)

        return basalSchedule.entries.last(where: { $0.startTime <= nowTimeInterval })?.rate ?? 0
    }

    public var model: String {
        let type = Crypto.simpleDecrypt(Data(pumpSN.reversed())).toUInt64()

        if (126_000_000 ..< 126_999_999).contains(type) {
            return "MD0201"
        } else if (127_000_000 ..< 127_999_999).contains(type) {
            return "MD5201"
        } else if (128_000_000 ..< 128_999_999).contains(type) {
            return "MD8201"
        } else if (130_000_000 ..< 130_999_999).contains(type) {
            return "MD0202"
        } else if (131_000_000 ..< 131_999_999).contains(type) {
            return "MD5202"
        } else if (148_000_000 ..< 148_999_999).contains(type) {
            return "MD8301"
        } else {
            return "INVALID"
        }
    }

    public var pumpName: String {
        let model = self.model
        if model == "MD8301" {
            return "Medtrum Nano 300U"
        } else if model == "INVALID" {
            return "Medtrum Nano UNKNOWN"
        } else {
            return "Medtrum Nano 200U"
        }
    }

    func shouldShowTimeWarning() -> Bool {
        // Allow a 15 sec diff in time
        abs(pumpTimeSyncedAt.timeIntervalSince1970 - pumpTime.timeIntervalSince1970) > 15
    }

    public var debugDescription: String {
        [
            "## MedtrumPumpState - \(Date.now)",
            "* isOnboarded: \(isOnboarded)",
            "* lastSync: \(lastSync)",
            "* pumpState: \(pumpState.rawValue)",
            "* patchSessionEnded: \(patchSessionEnded)",
            "* pumpSN: \(pumpSN.hexEncodedString())",
            "* pumpName: \(pumpName)",
            "* model: \(model)",
            "* swVersion: \(swVersion)",
            "* maxDailyInsulin: \(maxDailyInsulin)u",
            "* maxHourlyInsulin: \(maxHourlyInsulin)u",
            "* battery: \(battery)",
            "* pumpTime: \(pumpTime)",
            "* pumpTimeSyncedAt: \(pumpTimeSyncedAt)",
            "* insulinType: \(String(describing: insulinType))",
            "* reservoirLevel: \(reservoir)",
            "* lowReservoirWarning: \(String(describing: lowReservoirWarning))",
            "* bolusState: \(bolusState.rawValue)",
            "* bluetoothState: \(bluetoothState.rawValue)",
            "* patchId: \(patchId.hexEncodedString())",
            "* recordSequence: \(syncedSequenceNumber)/\(currentSequenceNumber) (synced/pump)",
            "* awaitingRecord: \(awaitingRecord.map { "\($0.type.rawValue)@\($0.startDate)\($0.isFinalized ? " (final)" : "")" }.joined(separator: ", "))",
            "* unconfirmedTempBasal: \(unconfirmedTempBasal.map { "\($0.value) U/h sent \($0.sentAt.map { "\($0)" } ?? "-")" } ?? "-")",
            "* pendingTempBasal: \(pendingTempBasal.map { "\($0.unitsPerHour) U/h sent \($0.sentAt)" } ?? "-")",
            "* heldBasalDoses: \(heldBasalDoses.map { "\($0.dose.type.rawValue)@\($0.dose.startDate)" }.joined(separator: ", "))"
        ].joined(separator: "\n")
    }
}

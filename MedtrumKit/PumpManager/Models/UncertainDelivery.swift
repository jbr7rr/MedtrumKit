import LoopKit

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

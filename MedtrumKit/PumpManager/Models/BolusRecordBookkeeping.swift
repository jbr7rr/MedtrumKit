import Foundation

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
    /// Saved in flight by the released driver: `sentAt` is when its answer came. A record of its amount starting from a
    /// while before then up to its deadline is its own (`MedtrumPumpManager.releasedBolusRecordBounds`,
    /// `tellOfBolusRecord`).
    public let datedByItsAnswer: Bool

    public init(
        units: Double,
        delivered: Double,
        sentAt: Date,
        pumpStartTime: Date?,
        recordSequence: Int?,
        taken: PossibleBolusRecord? = nil,
        datedByItsAnswer: Bool = false
    ) {
        self.units = units
        self.delivered = delivered
        self.sentAt = sentAt
        self.pumpStartTime = pumpStartTime
        self.recordSequence = recordSequence
        self.taken = taken
        self.datedByItsAnswer = datedByItsAnswer
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
            taken: (rawValue["taken"] as? PossibleBolusRecord.RawValue).flatMap(PossibleBolusRecord.init(rawValue:)),
            datedByItsAnswer: rawValue["datedByItsAnswer"] as? Bool ?? false
        )
    }

    public var rawValue: RawValue {
        var value: RawValue = ["units": units, "delivered": delivered, "sentAt": sentAt]
        value["pumpStartTime"] = pumpStartTime
        value["recordSequence"] = recordSequence
        value["taken"] = taken?.rawValue
        if datedByItsAnswer {
            value["datedByItsAnswer"] = true
        }
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

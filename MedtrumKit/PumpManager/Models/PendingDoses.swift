import Foundation

/// A SetBolus on its way to the patch: saved before it is written, gone once its outcome is in. Found in the state of a
/// new run, it went out and the app was gone before its answer - the patch may be delivering it.
public struct PendingBolus: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public let units: Double
    public let sentAt: Date
    /// The newest record number known or claimed when it went out (`UnfinalizedDose.State.sequenceAtSend`): its record,
    /// if the patch ran it, is numbered past it
    public let sequenceAtSend: Int
    /// The patch that number is of - see `UnfinalizedDose.State.sequencePatchId`. Nil, none was known - and for one
    /// saved before this was kept.
    public let sequencePatchId: Int?
    public let automatic: Bool

    public init(units: Double, sentAt: Date, sequenceAtSend: Int, sequencePatchId: Int? = nil, automatic: Bool) {
        self.units = units
        self.sentAt = sentAt
        self.sequenceAtSend = sequenceAtSend
        self.sequencePatchId = sequencePatchId
        self.automatic = automatic
    }

    public init?(rawValue: RawValue) {
        guard let units = rawValue["units"] as? Double, let sentAt = rawValue["sentAt"] as? Date,
              let sequenceAtSend = rawValue["sequenceAtSend"] as? Int, let automatic = rawValue["automatic"] as? Bool
        else {
            return nil
        }
        self.init(
            units: units,
            sentAt: sentAt,
            sequenceAtSend: sequenceAtSend,
            sequencePatchId: rawValue["sequencePatchId"] as? Int,
            automatic: automatic
        )
    }

    public var rawValue: RawValue {
        var raw: RawValue = ["units": units, "sentAt": sentAt, "sequenceAtSend": sequenceAtSend, "automatic": automatic]
        raw["sequencePatchId"] = sequencePatchId
        return raw
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

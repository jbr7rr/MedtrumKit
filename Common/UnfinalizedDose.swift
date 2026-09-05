import Foundation
import LoopKit

public class UnfinalizedDose {
    public typealias RawValue = [String: Any]

    private let logger = MedtrumLogger(category: "UnfinalizedDose")

    public let type: DoseType
    public let startDate: Date
    public let estimatedEndDate: Date
    public let value: Double
    public var deliveredUnits: Double = 0
    public let insulinType: InsulinType?
    public let automatic: Bool

    public init(units: Double, duration: TimeInterval, activationType: BolusActivationType, insulinType: InsulinType?) {
        var estimatedEndDate = Date.now
        estimatedEndDate.addTimeInterval(duration)

        type = .bolus
        value = units
        startDate = Date.now
        self.estimatedEndDate = estimatedEndDate
        self.insulinType = insulinType
        automatic = activationType.isAutomatic
    }

    public init(basalRate: Double, insulinType: InsulinType?, startDate: Date = Date.now) {
        type = .basal
        value = basalRate
        self.startDate = startDate
        estimatedEndDate = startDate
        self.insulinType = insulinType
        automatic = false
    }

    public init(tempRate: Double, duration: TimeInterval, insulinType: InsulinType?, automatic: Bool) {
        type = .tempBasal
        value = tempRate
        startDate = Date.now
        self.insulinType = insulinType
        estimatedEndDate = startDate.addingTimeInterval(duration)
        self.automatic = automatic
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

        if let rawDeliveredUnits = rawValue["deliveredUnits"] as? Double {
            deliveredUnits = rawDeliveredUnits
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
    }

    public var rawValue: RawValue {
        var raw: RawValue = [:]

        raw["type"] = type.rawValue
        raw["value"] = value
        raw["startDate"] = startDate
        raw["estimatedEndDate"] = estimatedEndDate
        raw["deliveredUnits"] = deliveredUnits
        raw["insulinType"] = insulinType?.rawValue
        raw["automatic"] = automatic

        return raw
    }

    public func toDoseEntry(isMutable: Bool = false, useEstimatedEndDate: Bool = false, endDate: Date = Date.now) -> DoseEntry {
        switch type {
        case .bolus:
            var endDate = isMutable || useEstimatedEndDate ? estimatedEndDate : endDate
            if useEstimatedEndDate, endDate > Date.now {
                // The endDate of a bolus cannot be in the future...
                endDate = Date.now
            }

            return DoseEntry(
                type: .bolus,
                startDate: startDate,
                endDate: endDate,
                value: value.rounded(toPlaces: 2),
                unit: .units,
                deliveredUnits: isMutable ? nil : deliveredUnits.rounded(toPlaces: 2),
                insulinType: insulinType,
                automatic: automatic,
                isMutable: isMutable
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
            let actualEndDate = isMutable ?
                estimatedEndDate :
                min(endDate, estimatedEndDate) // in case this finalization happens late (TBR ended while not connected to the phone, etc)
                                               // don't report the end date later than the scheduled end date
            let duration = actualEndDate.timeIntervalSince(startDate)
            return DoseEntry(
                type: .tempBasal,
                startDate: startDate,
                endDate: actualEndDate,
                value: value,
                unit: .unitsPerHour,
                deliveredUnits: isMutable ? nil : roundBasalRate(value * (duration / .hours(1))),
                insulinType: insulinType,
                automatic: automatic,
                isMutable: isMutable
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

    private func roundBasalRate(_ rate: Double) -> Double {
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

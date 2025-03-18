//
//  DoseEntry.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 17/03/2025.
//

import Foundation
import LoopKit

extension DoseEntry {
    public static func bolus(units: Double, deliveredUnits: Double, duration: TimeInterval, activationType: BolusActivationType, insulinType: InsulinType, startDate: Date = Date.now) -> DoseEntry {
        var endTime = Date.now
        endTime.addTimeInterval(duration)
        
        return DoseEntry(
            type: .bolus,
            startDate: startDate,
            endDate: endTime,
            value: units,
            unit: .units,
            deliveredUnits: deliveredUnits,
            insulinType: insulinType,
            automatic: activationType.isAutomatic,
            manuallyEntered: activationType == .manualNoRecommendation,
            isMutable: false
        )
    }
    
    public static func tempBasal(absoluteUnit: Double, duration: TimeInterval, insulinType: InsulinType, startDate: Date = Date.now) -> DoseEntry {
        return DoseEntry(
            type: .tempBasal,
            startDate: startDate,
            endDate: startDate + duration,
            value: absoluteUnit,
            unit: .unitsPerHour,
            insulinType: insulinType
        )
    }
    
    public static func basal(rate: Double, insulinType: InsulinType, startDate: Date = Date.now) -> DoseEntry {
        return DoseEntry(
            type: .basal,
            startDate: startDate,
            value: rate,
            unit: .unitsPerHour,
            insulinType: insulinType
        )
    }
    
    public static func resume(insulinType: InsulinType, resumeDate: Date = Date.now) -> DoseEntry {
        return DoseEntry(
            resumeDate: resumeDate,
            insulinType: insulinType
        )
    }
    
    public static func suspend(suspendDate: Date = Date.now) -> DoseEntry {
        return DoseEntry(suspendDate: suspendDate)
    }
}

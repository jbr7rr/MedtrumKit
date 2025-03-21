//
//  MedtrumPumpState.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

import LoopKit

public enum BolusState: Int {
    case noBolus = 0
    case inProgress = 1
    case canceling = 2
}

class MedtrumPumpState: RawRepresentable {
    public typealias RawValue = PumpManager.RawStateValue
    
    required public init(rawValue: RawValue) {
        isOnboarded = rawValue["isOnboarded"] as? Bool ?? false
        pumpSN = rawValue["pumpSN"] as? Data ?? Data()
        sessionToken = rawValue["sessionToken"] as? Data ?? Data()
        patchId = rawValue["patchId"] as? Data ?? Data()
        deviceType = rawValue["deviceType"] as? UInt8 ?? 0
        swVersion = rawValue["swVersion"] as? String ?? "0.0.0"
        pumpTime = rawValue["pumpTime"] as? Date ?? Date()
        pumpTimeSyncedAt = rawValue["pumpTimeSyncedAt"] as? Date ?? Date()
        maxHourlyInsulin = rawValue["maxHourlyInsulin"] as? Double ?? 20
        maxDailyInsulin = rawValue["maxDailyInsulin"] as? Double ?? 100
        isTempBasalInProgress = rawValue["isTempBasalInProgress"] as? Bool ?? false
        reservoir = rawValue["reservoir"] as? Double ?? 0
        
        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        }
        
        if let pumpStateRaw = rawValue["pumpState"] as? PatchState.RawValue {
            pumpState = PatchState(rawValue: pumpStateRaw) ?? .none
        } else {
            pumpState = .none
        }
        
        if let rawBasalSchedule = rawValue["basalSchedule"] as? BasalSchedule.RawValue {
            basalSchedule = BasalSchedule(rawValue: rawBasalSchedule) ?? BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }
        
        if let bolusStateRaw = rawValue["bolusState"] as? BolusState.RawValue {
            bolusState = BolusState(rawValue: bolusStateRaw) ?? .noBolus
        } else {
            bolusState = .noBolus
        }
    }
    
    public init(_ basal: BasalRateSchedule?) {
        isOnboarded = false
        pumpSN = Data()
        sessionToken = Data()
        patchId = Data()
        deviceType = 0
        swVersion = "0.0.0"
        pumpTime = Date()
        pumpTimeSyncedAt = Date()
        pumpState = .none
        
        maxHourlyInsulin = 20
        maxDailyInsulin = 100
        reservoir = 0
        bolusState = .noBolus
        isTempBasalInProgress = false
        
        if let basal = basal {
            basalSchedule = BasalSchedule(entries: basal.items)
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }
    }
    
    public var rawValue: RawValue {
        var value: [String: Any] = [:]
        
        value["isOnboarded"] = isOnboarded
        value["insulinType"] = insulinType
        value["pumpSN"] = pumpSN
        value["sessionToken"] = sessionToken
        value["patchId"] = patchId
        value["deviceType"] = deviceType
        value["swVersion"] = swVersion
        value["pumpTime"] = pumpTime
        value["pumpTimeSyncedAt"] = pumpTimeSyncedAt
        value["pumpState"] = pumpState.rawValue
        value["maxHourlyInsulin"] = maxHourlyInsulin
        value["maxDailyInsulin"] = maxDailyInsulin
        value["isTempBasalInProgress"] = isTempBasalInProgress
        value["basalSchedule"] = basalSchedule.rawValue
        value["bolusState"] = bolusState.rawValue
        value["reservoir"] = reservoir
        
        return value
    }
    
    public var isOnboarded: Bool
    public var insulinType: InsulinType?
    
    public var pumpSN: Data
    public var sessionToken: Data
    public var patchId: Data
    
    public var deviceType: UInt8
    public var swVersion: String
    
    public var pumpTime: Date
    public var pumpTimeSyncedAt: Date
    
    public var pumpState: PatchState
    public var reservoir: Double
    
    // Patch limits
    public var maxHourlyInsulin: Double
    public var maxDailyInsulin: Double
    
    public var isTempBasalInProgress: Bool
    public var basalSchedule: BasalSchedule
    
    public var bolusState: BolusState
}

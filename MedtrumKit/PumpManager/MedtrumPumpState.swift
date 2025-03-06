//
//  MedtrumPumpState.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//
import LoopKit

class MedtrumPumpState: RawRepresentable {
    public typealias RawValue = PumpManager.RawStateValue
    
    required public init(rawValue: RawValue) {
        pumpSN = rawValue["pumpSN"] as? Data ?? Data()
        sessionToken = rawValue["sessionToken"] as? Data ?? Data()
        patchId = rawValue["patchId"] as? Data ?? Data()
        deviceType = rawValue["deviceType"] as? UInt8 ?? 0
        swVersion = rawValue["swVersion"] as? String ?? "0.0.0"
        pumpTime = rawValue["pumpTime"] as? Date ?? Date()
        pumpTimeSyncedAt = rawValue["pumpTimeSyncedAt"] as? Date ?? Date()
        maxHourlyInsulin = rawValue["maxHourlyInsulin"] as? Double ?? 20
        maxDailyInsulin = rawValue["maxDailyInsulin"] as? Double ?? 100
        
        if let pumpStateRaw = rawValue["pumpState"] as? MedtrumState.RawValue {
            pumpState = MedtrumState(rawValue: pumpStateRaw) ?? .none
        } else {
            pumpState = .none
        }
        
        if let rawBasalSchedule = rawValue["basalSchedule"] as? BasalSchedule.RawValue {
            basalSchedule = BasalSchedule(rawValue: rawBasalSchedule) ?? BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }
    }
    
    public init() {
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
        
        basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
    }
    
    public var rawValue: RawValue {
        var value: [String: Any] = [:]
        
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
        value["basalSchedule"] = basalSchedule.rawValue
        
        return value
    }
    
    public var pumpSN: Data
    public var sessionToken: Data
    public var patchId: Data
    
    public var deviceType: UInt8
    public var swVersion: String
    
    public var pumpTime: Date
    public var pumpTimeSyncedAt: Date
    
    public var pumpState: MedtrumState
    
    // Patch limits
    public var maxHourlyInsulin: Double
    public var maxDailyInsulin: Double
    
    public var basalSchedule: BasalSchedule
}

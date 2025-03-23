//
//  MedtrumPumpState.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

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

class MedtrumPumpState: RawRepresentable {
    public typealias RawValue = PumpManager.RawStateValue
    
    required public init(rawValue: RawValue) {
        isOnboarded = rawValue["isOnboarded"] as? Bool ?? false
        lastSync = rawValue["lastSync"] as? Date ?? Date.distantPast
        pumpSN = rawValue["pumpSN"] as? Data ?? Data()
        sessionToken = rawValue["sessionToken"] as? Data ?? Data()
        patchId = rawValue["patchId"] as? Data ?? Data()
        deviceType = rawValue["deviceType"] as? UInt8 ?? 0
        swVersion = rawValue["swVersion"] as? String ?? "0.0.0"
        pumpTime = rawValue["pumpTime"] as? Date ?? Date()
        pumpTimeSyncedAt = rawValue["pumpTimeSyncedAt"] as? Date ?? Date()
        maxHourlyInsulin = rawValue["maxHourlyInsulin"] as? Double ?? 20
        maxDailyInsulin = rawValue["maxDailyInsulin"] as? Double ?? 100
        reservoir = rawValue["reservoir"] as? Double ?? 0
        battery = rawValue["battery"] as? Double ?? 0
        basalStateSince = rawValue["basalStateSince"] as? Date ?? Date.distantPast
        
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
        
        if let basalStateRaw = rawValue["basalState"] as? BasalState.RawValue {
            basalState = BasalState(rawValue: basalStateRaw) ?? .active
        } else {
            basalState = .active
        }
        
        if let bolusStateRaw = rawValue["bolusState"] as? BolusState.RawValue {
            bolusState = BolusState(rawValue: bolusStateRaw) ?? .noBolus
        } else {
            bolusState = .noBolus
        }
    }
    
    public init(_ basal: BasalRateSchedule?) {
        isOnboarded = false
        lastSync = Date.distantPast
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
        battery = 0
        basalState = .active
        basalStateSince = Date.distantPast
        bolusState = .noBolus

        if let basal = basal {
            basalSchedule = BasalSchedule(entries: basal.items)
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }
    }
    
    public var rawValue: RawValue {
        var value: [String: Any] = [:]
        
        value["isOnboarded"] = isOnboarded
        value["lastSync"] = lastSync
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
        value["basalSchedule"] = basalSchedule.rawValue
        value["bolusState"] = bolusState.rawValue
        value["reservoir"] = reservoir
        value["battery"] = battery
        value["basalState"] = basalState.rawValue
        value["basalStateSince"] = basalStateSince
        
        return value
    }
    
    public var isOnboarded: Bool
    public var insulinType: InsulinType?
    public var lastSync: Date
    
    public var pumpSN: Data
    public var sessionToken: Data
    public var patchId: Data
    
    public var deviceType: UInt8
    public var swVersion: String
    
    public var pumpTime: Date
    public var pumpTimeSyncedAt: Date
    
    public var pumpState: PatchState
    public var reservoir: Double
    public var battery: Double
    
    // Patch limits
    public var maxHourlyInsulin: Double
    public var maxDailyInsulin: Double
    
    public var bolusState: BolusState
    
    public var basalState: BasalState
    public var basalStateSince: Date
    public var basalSchedule: BasalSchedule
    public var tempBasalUnits: Double?
    public var tempBasalDuration: Double?
    public var tempBasalEndsAt: Date {
        basalStateSince + (tempBasalDuration ?? 0)
    }
    
    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        switch basalState {
        case .active:
            return .active(basalStateSince)
        case .suspended:
            return .suspended(basalStateSince)
        case .tempBasal:
            return .tempBasal(
                DoseEntry.tempBasal(
                    absoluteUnit: tempBasalUnits ?? 0,
                    duration: tempBasalDuration ?? 0,
                    insulinType: insulinType!,
                    startDate: basalStateSince
                )
            )
        }
    }

    public var model: String {
        let type = Crypto.simpleDecrypt(self.pumpSN).toUInt64()
        
        if (126000000..<126999999).contains(type) {
            return "MD0201"
        } else if (127000000..<127999999).contains(type) {
            return "MD5201"
        } else if (128000000..<128999999).contains(type) {
            return "MD8201"
        }else if (130000000..<130999999).contains(type) {
            return "MD0202"
        }else if (131000000..<131999999).contains(type) {
            return "MD5202"
        }else if (148000000..<148999999).contains(type) {
            return "MD8301"
        } else {
            return "INVALID"
        }
    }
    
    public var pumpName: String {
        let model = self.model
        if model == "MD8301" {
            return "TouchCare Nano 300U"
        } else if model == "MD0201" || model == "MD8201" {
            return "TouchCare Nano 200U"
        } else {
            return "TouchCare Nano UNKNOWN"
        }
    }
}

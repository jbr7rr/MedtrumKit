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
        deviceType = rawValue["deviceType"] as? UInt8 ?? 0
        swVersion = rawValue["swVersion"] as? String ?? "0.0.0"
        pumpTime = rawValue["pumpTime"] as? Date ?? Date()
        pumpTimeSyncedAt = rawValue["pumpTimeSyncedAt"] as? Date ?? Date()
        
        if let pumpStateRaw = rawValue["pumpState"] as? MedtrumState.RawValue {
            pumpState = MedtrumState(rawValue: pumpStateRaw) ?? .none
        } else {
            pumpState = .none
        }
    }
    
    public init() {
        pumpSN = Data()
        sessionToken = Data()
        deviceType = 0
        swVersion = "0.0.0"
        pumpTime = Date()
        pumpTimeSyncedAt = Date()
        pumpState = .none
    }
    
    public var rawValue: RawValue {
        var value: [String: Any] = [:]
        
        value["pumpSN"] = pumpSN
        value["sessionToken"] = sessionToken
        value["deviceType"] = deviceType
        value["swVersion"] = swVersion
        value["pumpTime"] = pumpTime
        value["pumpTimeSyncedAt"] = pumpTimeSyncedAt
        value["pumpState"] = pumpState.rawValue
        
        return value
    }
    
    public var pumpSN: Data
    public var sessionToken: Data
    
    public var deviceType: UInt8
    public var swVersion: String
    
    public var pumpTime: Date
    public var pumpTimeSyncedAt: Date
    
    public var pumpState: MedtrumState
}

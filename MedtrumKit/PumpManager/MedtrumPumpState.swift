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
    }
    
    public var rawValue: RawValue {
        var value: [String: Any] = [:]
        
        value["pumpSN"] = pumpSN
        value["sessionToken"] = sessionToken
        
        return value
    }
    
    public var pumpSN: Data
    public var sessionToken: Data
}

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
    }
    
    public var rawValue: RawValue {
        var value: [String: Any] = [:]
        
        return value
    }
    
}

//
//  BasalSchedule.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 04/03/2025.
//

import LoopKit

public struct BasalSchedule: RawRepresentable {
    
    public typealias RawValue = [String: Any]

    let entries: [BasalScheduleEntry]
    
    
    public init(entries: [LoopKit.RepeatingScheduleValue<Double>]) {
        self.entries = entries.map{ BasalScheduleEntry(rate: $0.value, startTime: $0.startTime) }
    }
    
    public init?(rawValue: RawValue) {
        guard let entries = rawValue["entries"] as? [BasalScheduleEntry.RawValue] else {
            return nil
        }
        
        self.entries = entries.compactMap { BasalScheduleEntry(rawValue: $0) }
    }
    
    public var rawValue: RawValue {
        let rawValue: RawValue = [
            "entries": entries.map { $0.rawValue }
        ]
        
        return rawValue
    }
    
    public func toData() -> Data {
        var output = Data([UInt8(entries.count)])
        
        zip(entries, entries.dropFirst()).forEach { (current, next) in
            let rate = UInt16(round(current.rate / 0.05))
            let time = UInt16((next.startTime - current.startTime).minutes)
            
            if time > 0xFFF || rate > 0xFFF {
                preconditionFailure("Rate or time is too big: \(rate), \(time)")
            }
            
            let entries = Data([
                UInt8((rate >> 4) & 0xFF),
                UInt8((rate << 4) & 0xF0 | (time >> 8) & 0x0F),
                UInt8(time & 0xFF)
            ])
            output.append(entries)
        }
        
        if let lastEntry = entries.last {
            let rate = UInt16(round(lastEntry.rate / 0.05))
            
            let entries = Data([
                UInt8((rate >> 4) & 0xFF),
                UInt8((rate << 4) & 0xF0),
                0
            ])
            output.append(entries)
        }
        
        return output
    }
    
}

public struct BasalScheduleEntry: RawRepresentable {
    
    public typealias RawValue = [String: Any]

    let rate: Double
    let startTime: TimeInterval
    
    public init(rate: Double, startTime: TimeInterval) {
        self.rate = rate
        self.startTime = startTime
    }
    
    public init?(rawValue: RawValue) {
        guard let rate = rawValue["rate"] as? Double, let startTime = rawValue["startTime"] as? Double else {
            return nil
        }
        
        self.rate = rate
        self.startTime = startTime
    }
    
    public var rawValue: RawValue {
        let rawValue: RawValue = [
            "rate": rate,
            "startTime": startTime
        ]
        
        return rawValue
    }
}

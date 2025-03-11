//
//  Date.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

let baseUnix: TimeInterval = .seconds(1388534400) //2014-01-01T00:00:00+0000

extension Date {
    static func fromMedtrumSeconds(_ seconds: UInt64) -> Date {
        return Date(timeIntervalSince1970: baseUnix + Double(seconds))
    }
    
    func toMedtrumSeconds() -> Data {
        let data = UInt64(self.timeIntervalSince1970 - baseUnix)
        return data.toData(length: 4)
    }
}

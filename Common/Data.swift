//
//  Data.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 26/02/2025.
//

extension Data {
    struct HexEncodingOptions: OptionSet {
            let rawValue: Int
            static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
        }
    
    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let format = options.contains(.upperCase) ? "%02hhX" : "%02hhx"
        return self.map { String(format: format, $0) }.joined()
    }
    
    func toUInt64() -> UInt64 {
        guard self.count <= 8 else {
            preconditionFailure("Cannot convert Data to UInt64, size too long")
        }
        
        var result: UInt64 = 0
        for i in 0..<self.count {
            let shifted = UInt64(self[i]) << (8 * i)
            result |= shifted
        }
        
        return result
    }
    
    func toInt64() -> Int64 {
        guard self.count <= 8 else {
            preconditionFailure("Cannot convert Data to Int64, size too long")
        }
        
        var result: Int64 = 0
        for i in 0..<self.count {
            let shifted = Int64(self[i]) << (8 * i)
            result |= shifted
        }
        
        return result
    }
}

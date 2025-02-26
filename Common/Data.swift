//
//  Data.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 26/02/2025.
//

extension Data {
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
}

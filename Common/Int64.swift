//
//  Int64.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 26/02/2025.
//

extension UInt64 {
    func toData(length: Int) -> Data {
        var output = Data(count: length)
        for i in 0..<length {
            output[i] = UInt8((self >> (i * 8)) & 0xFF)
        }
        
        return output
    }
}

extension Int64 {
    func toData(length: Int) -> Data {
        var output = Data(count: length)
        for i in 0..<length {
            output[i] = UInt8((self >> (i * 8)) & 0xFF)
        }
        
        return output
    }
}

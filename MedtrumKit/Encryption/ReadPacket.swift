//
//  ReadPacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

class ReadPacket {
    private let dataSize: UInt8
    
    private(set) var totalData: Data
    private var sequenceNumber: UInt8
    private(set) var failed: Bool = false
    
    var commandType: UInt8 {
        totalData[1]
    }
    
    var isComplete: Bool {
        totalData.count == dataSize
    }
    
    init(_ data: Data) {
        totalData = data
        dataSize = data[0]
        sequenceNumber = data[3]
        
        let initialCrc = Crc8.calculate(data[0..<data.count - 1])
        if initialCrc[0] != data[data.count - 1] {
            failed = true
        }
    }
    
    func addData(_ data: Data) {
        totalData.append(data)
        sequenceNumber+=1
        
        let newCrc = Crc8.calculate(data[0..<data.count - 1])
        if newCrc[0] != data[data.count - 1] {
            failed = true
        }
        if sequenceNumber != data[3] {
            failed = true
        }
    }
}

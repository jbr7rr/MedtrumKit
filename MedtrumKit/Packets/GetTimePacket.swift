//
//  GetTimePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

struct GetTimePacketResponse {
    let time: Date
}

class GetTimePacket : MedtrumBasePacket {
    typealias T = GetTimePacketResponse
    
    let commandType: UInt8 = CommandType.GET_TIME
    
    func getRequestBytes() -> Data {
        return Data()
    }
    
    static func parseResponse(data: Data) -> GetTimePacketResponse {
        let secondsPassed = data[6..<10].toUInt64()
        return GetTimePacketResponse(
            time: Date.fromMedtrumSeconds(secondsPassed)
        )
    }
}

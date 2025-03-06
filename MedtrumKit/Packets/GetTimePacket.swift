//
//  GetTimePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

struct GetTimePacketResponse {
    let time: Date
}

class GetTimePacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = GetTimePacketResponse
    
    let commandType: UInt8 = CommandType.GET_TIME
    
    func getRequestBytes() -> Data {
        return Data()
    }
    
    func parseResponse() -> GetTimePacketResponse {
        let secondsPassed = totalData.subdata(in: 6..<10).toUInt64()
        return GetTimePacketResponse(
            time: Date.fromMedtrumSeconds(secondsPassed)
        )
    }
}

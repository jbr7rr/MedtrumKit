//
//  SetTimeZonePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

struct SetTimeZonePacketResponse {}

class SetTimeZonePacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = SetTimeZonePacketResponse
    
    let commandType: UInt8 = CommandType.SET_TIME_ZONE
    
    func getRequestBytes() -> Data {
        var offsetInSeconds = TimeZone.current.secondsFromGMT(for: Date.now)
        if offsetInSeconds < 0 {
            offsetInSeconds += 65536
        }
        
        let offsetData = UInt64(offsetInSeconds).toData(length: 2)
        let timeData = Date.toMedtrumSeconds()
        
        return offsetData + timeData
    }
    
    func parseResponse() -> SetTimeZonePacketResponse {
        return SetTimeZonePacketResponse()
    }
}

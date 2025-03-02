//
//  SubscribePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

struct SubscribePacketResponse {}

class SubscribePacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = SubscribePacketResponse
    
    let commandType: UInt8 = CommandType.SUBSCRIBE
    
    func getRequestBytes() -> Data {
        return UInt64(4095).toData(length: 2)
    }
    
    func parseResponse() -> SubscribePacketResponse {
        return SubscribePacketResponse()
    }
}

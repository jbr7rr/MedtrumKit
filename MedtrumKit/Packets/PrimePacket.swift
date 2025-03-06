//
//  PrimePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 06/03/2025.
//

struct PrimePacketResponse { }

class PrimePacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = PrimePacketResponse
    
    let commandType: UInt8 = CommandType.PRIME
    
    func getRequestBytes() -> Data {
        return Data([])
    }
    
    func parseResponse() -> PrimePacketResponse {
        return PrimePacketResponse()
    }
}

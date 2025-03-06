//
//  PollPatchPacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 06/03/2025.
//

struct PollPatchPacketResponse { }

class PollPatchPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = PollPatchPacketResponse
    
    let commandType: UInt8 = CommandType.POLL_PATCH
    
    func getRequestBytes() -> Data {
        return Data([])
    }
    
    func parseResponse() -> PollPatchPacketResponse {
        return PollPatchPacketResponse()
    }
}

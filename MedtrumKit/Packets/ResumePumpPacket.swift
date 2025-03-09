//
//  ResumePumpPacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 09/03/2025.
//

struct ResumePumpPacketResponse { }

class ResumePumpPacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = ResumePumpPacketResponse
    let commandType: UInt8 = CommandType.RESUME_PUMP
    
    func getRequestBytes() -> Data {
        return Data()
    }
    
    func parseResponse() -> ResumePumpPacketResponse {
        return ResumePumpPacketResponse()
    }
}

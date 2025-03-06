//
//  CancelBolusPacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 06/03/2025.
//

struct CancelBolusPacketResponse{}

class CancelBolusPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = CancelBolusPacketResponse
    
    let commandType: UInt8 = CommandType.CANCEL_BOLUS
    
    /**
        1 -> Normal bolus
        2 -> Extended bolus
        3 -> Combi bolus
     */
    private let bolusType: UInt8 = 1
    
    func getRequestBytes() -> Data {
        return Data([bolusType])
    }
    
    func parseResponse() -> CancelBolusPacketResponse {
        return CancelBolusPacketResponse()
    }
}



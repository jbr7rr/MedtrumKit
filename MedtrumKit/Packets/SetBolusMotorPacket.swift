//
//  SetBolusMotorPacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 09/03/2025.
//

struct SetBolusMotorResponse {}

/// Unused packet
class SetBolusMotorPacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = SetBolusMotorResponse
    let commandType: UInt8 = CommandType.SET_BOLUS_MOTOR
    
    func getRequestBytes() -> Data {
        return Data([])
    }
    
    func parseResponse() -> SetBolusMotorResponse {
        return SetBolusMotorResponse()
    }
}

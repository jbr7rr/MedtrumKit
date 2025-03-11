//
//  SetBolusPacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 09/03/2025.
//

struct SetBolusResponse {}

class SetBolusPacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = SetBolusResponse
    let commandType: UInt8 = CommandType.SET_BOLUS
    
    // Bolus types:
    // 1 = normal
    // 2 = Extended
    // 3 = Combi
    let bolusType: UInt8 = 1
    let bolusAmount: Double
    
    init(bolusAmount: Double) {
        self.bolusAmount = bolusAmount
    }
    
    func getRequestBytes() -> Data {
        let amount = UInt16(round(bolusAmount / 0.05))
        return Data([
            bolusType,
            UInt8(amount & 0xFF),
            UInt8(amount >> 8)
        ])
    }
    
    func parseResponse() -> SetBolusResponse {
        return SetBolusResponse()
    }
}

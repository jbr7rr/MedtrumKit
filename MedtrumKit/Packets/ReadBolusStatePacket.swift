//
//  ReadBolusStatePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 09/03/2025.
//

struct ReadBolusStatePacketResponse {
    let bolusData: Data
}

class ReadBolusStatePacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = ReadBolusStatePacketResponse
    let commandType: UInt8 = CommandType.READ_BOLUS_STATE
    
    func getRequestBytes() -> Data {
        return Data()
    }
    
    func parseResponse() -> ReadBolusStatePacketResponse {
        return ReadBolusStatePacketResponse(
            bolusData: totalData.subdata(in: 6..<totalData.count)
        )
    }
}

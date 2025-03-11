//
//  StopPatchPacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 11/03/2025.
//

struct StopPatchResponse {
    let sequence: Double
    let patchId: Double
}

class StopPatchPacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = StopPatchResponse
    let commandType: UInt8 = CommandType.STOP_PATCH
    
    func getRequestBytes() -> Data {
        return Data()
    }
    
    func parseResponse() -> StopPatchResponse {
        return StopPatchResponse(
            sequence: totalData.subdata(in: 6..<8).toDouble(),
            patchId: totalData.subdata(in: 8..<10).toDouble()
        )
    }
}

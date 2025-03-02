//
//  GetDeviceTypePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

struct GetDeviceTypeResponse {
    let deviceType: UInt8
    let deviceSN: Data
}

class GetDeviceTypePacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = GetDeviceTypeResponse
    let commandType: UInt8 = CommandType.GET_DEVICE_TYPE
    
    func getRequestBytes() -> Data {
        return Data()
    }
    
    func parseResponse() -> GetDeviceTypeResponse {
        return GetDeviceTypeResponse(
            deviceType: totalData[6],
            deviceSN: totalData[7..<11]
        )
    }
}

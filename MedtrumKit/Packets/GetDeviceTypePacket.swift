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

class GetDeviceTypePacket: MedtrumBasePacket {
    typealias T = GetDeviceTypeResponse
    let commandType: UInt8 = CommandType.GET_DEVICE_TYPE
    
    func getRequestBytes() -> Data {
        return Data()
    }
    
    static func parseResponse(data: Data) -> GetDeviceTypeResponse {
        return GetDeviceTypeResponse(
            deviceType: data[6],
            deviceSN: data[7..<11]
        )
    }
}

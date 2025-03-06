//
//  ClearPumpAlarmPacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 06/03/2025.
//

struct ClearPumpAlarmResponse{}

class ClearPumpAlarmPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = ClearPumpAlarmResponse
    
    let commandType: UInt8 = CommandType.CLEAR_ALARM
    
    private let alarmType: ClearAlarmType
    
    init(alarmType: ClearAlarmType) {
        self.alarmType = alarmType
    }
    
    func getRequestBytes() -> Data {
        return Data([alarmType.rawValue])
    }
    
    func parseResponse() -> ClearPumpAlarmResponse {
        return ClearPumpAlarmResponse()
    }
}

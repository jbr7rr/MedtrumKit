//
//  SuspendPumpPacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 18/03/2025.
//

struct SuspendPumpResponse {}

class SuspendPumpPacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = SuspendPumpResponse
    let commandType: UInt8 = CommandType.SUSPEND_PUMP
    
    let duration: TimeInterval
    init(duration: TimeInterval) {
        self.duration = duration
    }
    
    func getRequestBytes() -> Data {
        // 3 -> cause: unknown why this is 3
        return Data([3, UInt8(self.duration.minutes)])
    }
    
    func parseResponse() -> SuspendPumpResponse {
        return SuspendPumpResponse()
    }
    
    
}

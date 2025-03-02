//
//  ActivatePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 01/03/2025.
//

struct AuthorizePacketResponse {
    let patchId: Data
    let time: Date
    let basalType: BasalType
    let basalValue: Double
    let basalSequence: Double
    let basalPatchId: Data
    let basalStartTime: Date
}

class ActivatePacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = AuthorizePacketResponse
    
    let commandType: UInt8 = CommandType.ACTIVATE
    
    let autoSuspendEnable: UInt8 = 0
    let autoSuspendTime: UInt8 = 12 // unknown why this value needs to be this
    let expirationTimer: UInt8
    let alarmSetting: AlarmSettings
    let lowSuspend: UInt8 = 0
    let predictiveLowSuspend: UInt8 = 0
    let predictiveLowSuspendRange: UInt8 = 30 // Not sure why, but pump needs this in order to activate
    let hourlyMaxInsulin: Double
    let dailyMaxInsulin: Double
    let currentTDD: Double
    let basalProfile: Data
    
    init(expirationTimer: UInt8, alarmSetting: AlarmSettings, hourlyMaxInsulin: Double, dailyMaxInsulin: Double, currentTDD: Double, basalProfile: Data) {
        self.expirationTimer = expirationTimer
        self.alarmSetting = alarmSetting
        self.hourlyMaxInsulin = hourlyMaxInsulin
        self.dailyMaxInsulin = dailyMaxInsulin
        self.currentTDD = currentTDD
        self.basalProfile = basalProfile
    }
    
    /**
     * byte 1: autoSuspendEnable -> Value for auto mode, not used for LoopKit
     * byte 2: autoSuspendTime -> Value for auto mode, not used for LoopKit
     * byte 3: expirationTimer -> Expiration timer, 0 = no expiration 1 = 12 hour reminder and expiration after 3 days
     * byte 4: alarmSetting -> see AlarmSetting
     * byte 5: lowSuspend -> Value for auto mode, not used for LoopKit
     * byte 6: predictiveLowSuspend -> Value for auto mode, not used for LoopKit
     * byte 7: predictiveLowSuspendRange -> Value for auto mode, not used for LoopKit
     * byte 8-9: hourlyMaxInsulin -> Max hourly dose of insulin, divided by 0.05
     * byte 10-11: dailyMaxSet -> Max daily dose of insulin, divided by 0.05
     * byte 12-13: tddToday -> Current TDD (of present day), divided by 0.05
     * byte 14: 1 -> Always 1
     * bytes 15 - end -> Basal profile
     */
    func getRequestBytes() -> Data {
        let base = Data([
            autoSuspendEnable,
            autoSuspendTime,
            expirationTimer,
            alarmSetting.rawValue,
            lowSuspend,
            predictiveLowSuspend,
            predictiveLowSuspendRange,
            UInt8(round(hourlyMaxInsulin / 0.05)),
            UInt8(round(dailyMaxInsulin / 0.05)),
            UInt8(round(currentTDD / 0.05)),
            1,
        ])
        
        return base + basalProfile
    }
    
    func parseResponse() -> AuthorizePacketResponse {
        <#code#>
    }
}

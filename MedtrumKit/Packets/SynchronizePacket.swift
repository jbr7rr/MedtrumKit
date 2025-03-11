//
//  SynchronizePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

struct SynchronizePacketResponse {
    let state: PatchState
    var suspendTime: Date?
    var bolus: BolusData?
    var basal: BasalData?
    var primeProgress: Double?
    var reservoir: Double?
    var startTime: Date?
    var battery: BatteryData?
    var storage: StorageData?
    var activeAlarms: [AlarmState]
    var patchAge: UInt64?
    var magnetoPlacement: Double?
}

struct BolusData {
    let type: UInt8
    let completed: Bool
    let delivered: Double
}

struct BasalData {
    let type: BasalType
    let sequence: Data
    let patchId: Double
    let startTime: Date
    let rate: Double
    let delivery: Double
}

struct BatteryData {
    let voltageA: Double
    let voltageB: Double
}

struct StorageData {
    let sequence: Double
    let patchId: Double
}

let MASK_SUSPEND: UInt16 = 0x01
let MASK_NORMAL_BOLUS: UInt16 = 0x02
let MASK_EXTENDED_BOLUS: UInt16 = 0x04
let MASK_BASAL: UInt16 = 0x08
let MASK_SETUP: UInt16 = 0x10
let MASK_RESERVOIR: UInt16 = 0x20
let MASK_START_TIME: UInt16 = 0x40
let MASK_BATTERY: UInt16 = 0x80
let MASK_STORAGE: UInt16 = 0x100
let MASK_ALARM: UInt16 = 0x200
let MASK_AGE: UInt16 = 0x400
let MASK_MAGNETO_PLACE: UInt16 = 0x800
let MASK_UNUSED_CGM: UInt16 = 0x1000
let MASK_UNUSED_COMMAND_CONFIRM: UInt16 = 0x2000
let MASK_UNUSED_AUTO_STATUS: UInt16 = 0x4000
let MASK_UNUSED_LEGACY: UInt16 = 0x8000

class SynchronizePacket : MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = SynchronizePacketResponse
    
    let commandType: UInt8 = CommandType.SYNCHRONIZE
    
    func getRequestBytes() -> Data {
        return Data()
    }
    
    func parseResponse() -> SynchronizePacketResponse {
        let fieldMask = UInt16(totalData.subdata(in: 7..<9).toUInt64())
        let syncData = totalData.subdata(in: 9..<totalData.count)
        var offset = 0
        
        var output = SynchronizePacketResponse(
            state: PatchState(rawValue: totalData[6]) ?? .none,
            suspendTime: nil,
            bolus: nil,
            basal: nil,
            primeProgress: nil,
            reservoir: nil,
            startTime: nil,
            battery: nil,
            storage: nil,
            activeAlarms: [],
            patchAge: nil,
            magnetoPlacement: nil
        )
        
        // Proces masks
        for (mask, handler) in maskHandlers {
            if fieldMask & mask != 0 {
                offset += handler(syncData, offset, &output)
            }
        }
        
        return output
    }
    
    
    private let maskHandlers: Dictionary<UInt16, (Data, Int, inout SynchronizePacketResponse) -> Int> = [
        MASK_SUSPEND: { (data, offset, output) in
            output.suspendTime = Date.fromMedtrumSeconds(data.subdata(in: offset..<offset+4).toUInt64())
            return offset + 4
        },
        MASK_NORMAL_BOLUS: { (data, offset, output) in
            output.bolus = BolusData(
                type: data[offset] & 0x7F,
                completed: data[offset] & 0x80 != 0,
                delivered: data.subdata(in: offset+1..<offset+3).toDouble()*0.05
            )
            return offset + 3
        },
        // TODO: Add more masks
    ]
    
}


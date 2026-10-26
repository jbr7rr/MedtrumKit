struct SynchronizePacketResponse: Codable {
    let state: PatchState
    var suspendTime: Date?
    var bolus: BolusData?
    var basal: BasalData?
    var primeProgress: UInt8?
    var reservoir: Double?
    var startTime: Date?
    var battery: BatteryData?
    var storage: StorageData?
    var activeAlarms: [AlarmState]
    var patchAge: UInt64?
    var magnetoPlacement: Double?

    var truncated: Bool = false
    var invalidPayload: Bool = false

    /// When it came in, taken as it is parsed: a command written after it can't be in it, whenever it is applied -
    /// see `MedtrumPumpManager.statusPredatesCommand`
    var receivedAt = Date.now
    /// `receivedAt` on the monotonic clock, which a change of the wall clock does not move - the one
    /// `MedtrumPumpManager.uptime` stamps commands on
    var receivedUptime = TimeInterval.continuousUptime

    func validated(expectedPatchId: UInt64 = 0) -> SynchronizePacketResponse {
        let invalidBolus = bolus.map { !(0 ... 50).contains($0.delivered) } ?? false
        let invalidBasal = basal.map { !(0 ... 40).contains($0.rate) } ?? false
        let invalidReservoir = reservoir.map { !(0 ... 400).contains($0) } ?? false
        let wrongBasalPatch = basal.map { expectedPatchId != 0 && $0.patchId != Double(expectedPatchId) } ?? false
        let wrongStoragePatch = storage.map { expectedPatchId != 0 && $0.patchId != Double(expectedPatchId) } ?? false

        guard !invalidBolus, !invalidBasal, !invalidReservoir, !wrongBasalPatch, !wrongStoragePatch else {
            MedtrumLogger(category: "NotificationPacket").error("Rejecting mismatched notification payload")
            return SynchronizePacketResponse(
                state: state, activeAlarms: [], invalidPayload: true, receivedAt: receivedAt, receivedUptime: receivedUptime
            )
        }
        return self
    }
}

struct BolusData: Codable {
    let type: UInt8
    let completed: Bool
    let delivered: Double
}

struct BasalData: Codable {
    let type: BasalType
    let sequence: Double
    let patchId: Double
    let startTime: Date
    let rate: Double
    let delivery: Double
}

struct BatteryData: Codable {
    let voltageA: Double
    let voltageB: Double
}

struct StorageData: Codable {
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

class NotificationPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = SynchronizePacketResponse

    private static let log = MedtrumLogger(category: "NotificationPacket")

    let commandType: UInt8 = CommandType.SYNCHRONIZE
    let mimimumDataSize: Int = 1

    func getRequestBytes() -> Data {
        Data()
    }

    func parseResponse() -> SynchronizePacketResponse {
        guard totalData.count >= mimimumDataSize else {
            NotificationPacket.log.error("Notification too short: \(totalData.hexEncodedString())")
            return SynchronizePacketResponse(state: .none, activeAlarms: [], truncated: true)
        }

        let state = PatchState(rawValue: totalData[0]) ?? .none
        // a single byte is a valid state-only update, if a field mask follows, both of its bytes must be present
        guard totalData.count >= 3 else {
            return SynchronizePacketResponse(state: state, activeAlarms: [], truncated: totalData.count == 2)
        }

        return handle(
            state: state,
            fieldMask: UInt16(totalData.subdata(in: 1 ..< 3).toUInt64()),
            syncData: Data(totalData.dropFirst(3))
        )
    }

    public func handle(state: PatchState, fieldMask: UInt16, syncData: Data) -> SynchronizePacketResponse {
        var offset = 0

        var output = SynchronizePacketResponse(
            state: state,
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

        let present = NotificationPacket.fields.filter { fieldMask & $0.mask != 0 }
        let expectedLength = present.reduce(0) { $0 + $1.size }

        // A basal field of type none can come as its type byte alone - device 2026-10-26 10:08:55, a halt as the reservoir
        // ran dry: 16 bytes for the 27 its mask announces, storage and the rest in their places after it. Told by the
        // length: exactly that much short, the type byte none. It carries no basal: none is taken from it.
        let basalOffset = present.prefix(while: { $0.mask != MASK_BASAL }).reduce(0) { $0 + $1.size }
        let isBasalTypeOnly = fieldMask & MASK_BASAL != 0 &&
            syncData.count == expectedLength - (NotificationPacket.basalSize - 1) &&
            syncData.count > basalOffset && syncData[basalOffset] == BasalType.NONE.rawValue
        if isBasalTypeOnly {
            NotificationPacket.log.info(
                "Notification basal field of type none is its type byte alone, no basal taken from it - mask: " +
                    "\(String(fieldMask, radix: 2)), \(syncData.count) bytes: \(syncData.hexEncodedString())"
            )
        }

        // validate the entire mask before parsing, short payload -> keep only the state
        guard isBasalTypeOnly || syncData.count >= expectedLength else {
            NotificationPacket.log.error(
                "Notification payload too short - mask: \(String(fieldMask, radix: 2)) expects " +
                    "\(expectedLength) bytes, got \(syncData.count): \(syncData.hexEncodedString())"
            )
            output.truncated = true
            return output
        }

        for field in present {
            if isBasalTypeOnly, field.mask == MASK_BASAL {
                offset += 1
                continue
            }

            guard offset + field.size <= syncData.count else {
                output.truncated = true
                break
            }

            field.parse(syncData, offset, &output)
            offset += field.size
        }

        return output.validated()
    }

    private struct Field {
        let mask: UInt16
        let size: Int
        let parse: (Data, Int, inout SynchronizePacketResponse) -> Void
    }

    /// The basal field in full - see `handle` for the one of type none that is its type byte alone
    private static let basalSize = 12

    private static let fields: [Field] = [
        Field(mask: MASK_SUSPEND, size: 4) { data, offset, output in
            output.suspendTime = Date.fromMedtrumSeconds(data.subdata(in: offset ..< offset + 4).toUInt64())
        },
        Field(mask: MASK_NORMAL_BOLUS, size: 3) { data, offset, output in
            output.bolus = BolusData(
                type: data[offset] & 0x7F,
                completed: data[offset] & 0x80 != 0,
                delivered: data.subdata(in: offset + 1 ..< offset + 3).toDouble() * 0.05
            )
        },
        // Just ignore this flag
        Field(mask: MASK_EXTENDED_BOLUS, size: 3) { _, _, _ in },
        Field(mask: MASK_BASAL, size: basalSize) { data, offset, output in
            let rateDelivery = UInt32(data.subdata(in: offset + 9 ..< offset + 12).toDouble())
            let delivery = rateDelivery >> 12
            let rate = rateDelivery & 0x0FFF

            output.basal = BasalData(
                type: BasalType(rawValue: data[offset]) ?? .NONE,
                sequence: data.subdata(in: offset + 1 ..< offset + 3).toDouble(),
                patchId: data.subdata(in: offset + 3 ..< offset + 5).toDouble(),
                startTime: Date.fromMedtrumSeconds(data.subdata(in: offset + 5 ..< offset + 9).toUInt64()),
                rate: Double(rate) * 0.05,
                delivery: Double(delivery) * 0.05
            )
        },
        Field(mask: MASK_SETUP, size: 1) { data, offset, output in
            output.primeProgress = data[offset]
        },
        Field(mask: MASK_RESERVOIR, size: 2) { data, offset, output in
            output.reservoir = data.subdata(in: offset ..< offset + 2).toDouble() * 0.05
        },
        Field(mask: MASK_START_TIME, size: 4) { data, offset, output in
            output.startTime = Date.fromMedtrumSeconds(data.subdata(in: offset ..< offset + 4).toUInt64())
        },
        Field(mask: MASK_BATTERY, size: 3) { data, offset, output in
            let value = UInt32(data.subdata(in: offset ..< offset + 3).toUInt64())

            output.battery = BatteryData(
                voltageA: Double(value & 0x0FFF) / 512,
                voltageB: Double(value >> 12) / 512
            )
        },
        Field(mask: MASK_STORAGE, size: 4) { data, offset, output in
            output.storage = StorageData(
                sequence: data.subdata(in: offset ..< offset + 2).toDouble(),
                patchId: data.subdata(in: offset + 2 ..< offset + 4).toDouble()
            )
        },
        Field(mask: MASK_ALARM, size: 4) { data, offset, output in
            let flags = UInt16(data.subdata(in: offset ..< offset + 2).toUInt64())
            if flags != AlarmState.None.rawValue {
                // Alarms list available, only need to check the first 3
                for i in 0 ..< 3 {
                    if flags & (1 << i) != 0, let alarmState = AlarmState(rawValue: 1 << i) {
                        output.activeAlarms.append(alarmState)
                    }
                }
            }

            // Unused parameter
            let _parameter = data.subdata(in: offset + 2 ..< offset + 4)
        },
        Field(mask: MASK_AGE, size: 4) { data, offset, output in
            output.patchAge = data.subdata(in: offset ..< offset + 4).toUInt64()
        },
        Field(mask: MASK_MAGNETO_PLACE, size: 2) { data, offset, output in
            output.magnetoPlacement = data.subdata(in: offset ..< offset + 2).toDouble()
        },
        Field(mask: MASK_UNUSED_CGM, size: 5) { _, _, _ in },
        Field(mask: MASK_UNUSED_COMMAND_CONFIRM, size: 2) { _, _, _ in },
        Field(mask: MASK_UNUSED_AUTO_STATUS, size: 2) { _, _, _ in },
        Field(mask: MASK_UNUSED_LEGACY, size: 2) { _, _, _ in }
    ]
}

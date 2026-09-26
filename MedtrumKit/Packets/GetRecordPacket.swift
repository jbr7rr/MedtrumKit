import Foundation

// GetRecordPacket — reads the records the patch stores (bolus / basal / TDD / alarm).
//
// Swift port of the AndroidAPS `GetRecordPacket.kt` by J. Bunt (@jbr7rr):
// pump/medtrum/src/main/kotlin/app/aaps/pump/medtrum/comm/packets/GetRecordPacket.kt
// Translated and restructured in 2026: parsing only, no pump-sync side effects, and the
// payload length is checked per record type. Written by Claude (Anthropic), directed
// and reviewed by @tomacs.
//
// LICENSE: the AAPS original is under the GNU AGPL-3.0, and so is this file — NOT
// MedtrumKit's MIT license. It can only become MIT if J. Bunt, author of the original and
// copyright holder of MedtrumKit, relicenses it himself; no maintainer can do that on his
// behalf. Reasoning and request: see the pull request that adds this file, and issue #141.
// Once he agrees, replace this paragraph with the grant (link to his comment + date).

enum BolusType: UInt8, Codable {
    case NONE = 0
    case NORMAL = 1
    case EXTENDED = 2
    case COMBI = 3
}

enum BasalEndReason: UInt8, Codable {
    case SUCCESS = 0
    case SUSPEND_LOW_GLUCOSE = 1
    case SUSPEND_PREDICT_LOW_GLUCOSE = 2
    case SUSPEND_AUTO = 3
    case SUSPEND_MORE_THAN_MAX_PER_HOUR = 4
    case SUSPEND_MORE_THAN_MAX_PER_DAY = 5
    case SUSPEND_MANUAL = 6
    case STOP_OCCLUSION = 7
    case STOP_EXPIRED = 8
    case STOP_EMPTY = 9
    case STOP_PATCH_FAULT = 10
    case STOP_PATCH_FAULT2 = 11
    case STOP_BASE_FAULT = 12
    case STOP_PATCH_BATTERY_EMPTY = 13
    case STOP_MAG_SENSOR_NO_CALIBRATION = 14
    case STOP = 15
    case STOP_LOW_BATTERY = 16
    case STOP_AUTO_EXIT = 17
    case STOP_CANCEL = 18
    case STOP_LOW_SUPER_CAPACITOR = 19
    case STOP_DISCARD = 20
    case PAUSE_INTERRUPT = 21
    case AUTO_MODE_EXIT = 22
    case AUTO_MODE_EXIT_MIN_DELIVERY_TOO_LONG = 23
    case AUTO_MODE_EXIT_NO_GLUCOSE_3_HOUR = 24
    case AUTO_MODE_EXIT_MAX_DELIVERY_TOO_LONG = 25

    func isSuspendedByPump() -> Bool {
        // Matches AAPS: SUSPEND_LOW_GLUCOSE..STOP_DISCARD (1..20).
        rawValue >= BasalEndReason.SUSPEND_LOW_GLUCOSE.rawValue
            && rawValue <= BasalEndReason.STOP_DISCARD.rawValue
    }
}

private let RESP_RECORD_HEADER_START = 6
private let RESP_RECORD_HEADER_END = RESP_RECORD_HEADER_START + 1
private let RESP_RECORD_UNKNOWN_START = RESP_RECORD_HEADER_END
private let RESP_RECORD_UNKNOWN_END = RESP_RECORD_UNKNOWN_START + 1
private let RESP_RECORD_TYPE_START = RESP_RECORD_UNKNOWN_END
private let RESP_RECORD_TYPE_END = RESP_RECORD_TYPE_START + 1
private let RESP_RECORD_UNKNOWN1_START = RESP_RECORD_TYPE_END
private let RESP_RECORD_UNKNOWN1_END = RESP_RECORD_UNKNOWN1_START + 1
private let RESP_RECORD_SERIAL_START = RESP_RECORD_UNKNOWN1_END
private let RESP_RECORD_SERIAL_END = RESP_RECORD_SERIAL_START + 4
private let RESP_RECORD_PATCH_ID_START = RESP_RECORD_SERIAL_END
private let RESP_RECORD_PATCH_ID_END = RESP_RECORD_PATCH_ID_START + 2
private let RESP_RECORD_SEQUENCE_START = RESP_RECORD_PATCH_ID_END
private let RESP_RECORD_SEQUENCE_END = RESP_RECORD_SEQUENCE_START + 2
private let RESP_RECORD_DATA_START = RESP_RECORD_SEQUENCE_END

// Payload bytes each parser reads past RESP_RECORD_DATA_START. `mimimumDataSize` only
// guarantees the header; a known type with a short payload would otherwise crash in
// `Data.subdata(in:)` — relevant now that records are read unattended on every sync.
private let BOLUS_RECORD_PAYLOAD = 24
private let BASAL_RECORD_PAYLOAD = 16
private let TDD_RECORD_PAYLOAD = 64
/// Only the timestamp is claimed for an alarm record — everything else is kept raw, see `AlarmRecord`.
private let ALARM_RECORD_PAYLOAD = 8

private let VALID_HEADER: UInt8 = 170
private let BOLUS_RECORD: UInt8 = 1
private let BOLUS_RECORD_ALT: UInt8 = 65
private let BASAL_RECORD: UInt8 = 2
private let BASAL_RECORD_ALT: UInt8 = 66
private let ALARM_RECORD: UInt8 = 3
private let AUTO_RECORD: UInt8 = 4
private let TIME_SYNC_RECORD: UInt8 = 5
private let AUTO1_RECORD: UInt8 = 6
private let AUTO2_RECORD: UInt8 = 7
private let AUTO3_RECORD: UInt8 = 8
private let TDD_RECORD: UInt8 = 9

struct BolusRecord {
    let bolusType: BolusType
    let bolusWizard: Bool
    let bolusCause: UInt8
    let bolusStartTime: Date
    let bolusNormalAmount: Double
    let bolusNormalDelivered: Double
    let bolusExtendedAmount: Double
    let bolusExtendedDuration: TimeInterval
    let bolusExtendedDelivered: Double
    let bolusCarb: UInt16
    let bolusGlucose: UInt16
    let bolusIOB: UInt16
}

struct BasalRecord {
    let patchId: UInt64
    let sequence: UInt16
    let basalStartTime: Date
    let basalEndTime: Date
    let basalType: BasalType
    let basalEndReason: BasalEndReason?
    let basalRate: Double
    let basalDelivered: Double
    let basalPercent: UInt16
}

/// An entry from the patch's alarm log.
///
/// The payload layout is undocumented — AAPS stops at "an alarm record exists here" too — so the
/// only field claimed here is the timestamp, which sits where every other record type puts it
/// (`DATA_START + 4`, cross-checked against the basal record that ends at the same second). The
/// rest is carried through verbatim: when a patch dies with a bare "Fault" state, this is the only
/// per-event data the pump hands out, and a log line with the raw bytes is what makes it possible
/// to tell two fault causes apart after the fact.
struct AlarmRecord {
    let timestamp: Date
    let payload: Data
}

struct TddRecord {
    let timestamp: Date
    let timeZoneOffset: UInt16
    let tddMinutes: UInt16
    let glucoseRecordTime: UInt64
    let tdd: Float
    let basalTdd: Float
    let glucose: Float
    let usedTdd: Float
    let usedIBasal: Float
    let usedSgBasal: Float
    let usedUMax: Float
    let newTdd: Float
    let newIBasal: Float
    let newSgBasal: Float
    let newUMax: Float
}

struct GetRecordPacketResponse {
    enum Record {
        case bolus(BolusRecord)
        case basal(BasalRecord)
        case alarm(AlarmRecord)
        case auto
        case timeSync
        case auto1
        case auto2
        case auto3
        case tdd(TddRecord)
        case unknownType(UInt8)
        case invalidHeader
        /// The record type is known but the payload is shorter than that type's layout.
        case truncated
    }

    let recordHeader: UInt8
    let recordType: UInt8
    let recordSerial: UInt64
    let recordPatchId: UInt64
    let recordSequence: UInt16
    let record: Record
}

class GetRecordPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = GetRecordPacketResponse

    let commandType: UInt8 = CommandType.GET_RECORD
    let mimimumDataSize: Int = RESP_RECORD_DATA_START

    private let recordIndex: UInt16
    private let patchId: Data

    init(recordIndex: UInt16, patchId: Data) {
        self.recordIndex = recordIndex
        self.patchId = patchId
    }

    func getRequestBytes() -> Data {
        UInt64(recordIndex).toData(length: 2)
            + patchId.subdata(in: 0 ..< min(2, patchId.count))
    }

    func parseResponse() -> GetRecordPacketResponse {
        let recordHeader = totalData[RESP_RECORD_HEADER_START]
        let recordType = totalData[RESP_RECORD_TYPE_START]
        let recordSerial = totalData
            .subdata(in: RESP_RECORD_SERIAL_START ..< RESP_RECORD_SERIAL_END).toUInt64()
        let recordPatchId = totalData
            .subdata(in: RESP_RECORD_PATCH_ID_START ..< RESP_RECORD_PATCH_ID_END).toUInt64()
        let recordSequence = UInt16(
            totalData.subdata(in: RESP_RECORD_SEQUENCE_START ..< RESP_RECORD_SEQUENCE_END).toUInt64()
        )

        guard recordHeader == VALID_HEADER else {
            return GetRecordPacketResponse(
                recordHeader: recordHeader,
                recordType: recordType,
                recordSerial: recordSerial,
                recordPatchId: recordPatchId,
                recordSequence: recordSequence,
                record: .invalidHeader
            )
        }

        func hasPayload(_ bytes: Int) -> Bool {
            totalData.count >= RESP_RECORD_DATA_START + bytes
        }

        let record: GetRecordPacketResponse.Record
        switch recordType {
        case BOLUS_RECORD, BOLUS_RECORD_ALT:
            record = hasPayload(BOLUS_RECORD_PAYLOAD) ? .bolus(parseBolusRecord()) : .truncated
        case BASAL_RECORD, BASAL_RECORD_ALT:
            record = hasPayload(BASAL_RECORD_PAYLOAD)
                ? .basal(parseBasalRecord(patchId: recordPatchId, sequence: recordSequence))
                : .truncated
        case ALARM_RECORD:
            record = hasPayload(ALARM_RECORD_PAYLOAD) ? .alarm(parseAlarmRecord()) : .truncated
        case AUTO_RECORD:
            record = .auto
        case TIME_SYNC_RECORD:
            record = .timeSync
        case AUTO1_RECORD:
            record = .auto1
        case AUTO2_RECORD:
            record = .auto2
        case AUTO3_RECORD:
            record = .auto3
        case TDD_RECORD:
            record = hasPayload(TDD_RECORD_PAYLOAD) ? .tdd(parseTddRecord()) : .truncated
        default:
            record = .unknownType(recordType)
        }

        return GetRecordPacketResponse(
            recordHeader: recordHeader,
            recordType: recordType,
            recordSerial: recordSerial,
            recordPatchId: recordPatchId,
            recordSequence: recordSequence,
            record: record
        )
    }

    private func parseBolusRecord() -> BolusRecord {
        let typeAndWizard = Int(totalData[RESP_RECORD_DATA_START])
        let bolusCause = totalData[RESP_RECORD_DATA_START + 1]
        let bolusStartTime = Date.fromMedtrumSeconds(
            totalData.subdata(in: RESP_RECORD_DATA_START + 4 ..< RESP_RECORD_DATA_START + 8).toUInt64()
        )
        let bolusNormalAmount = Double(totalData.subdata(in: RESP_RECORD_DATA_START + 8 ..< RESP_RECORD_DATA_START + 10).toUInt64()) * 0.05
        let bolusNormalDelivered = Double(totalData.subdata(in: RESP_RECORD_DATA_START + 10 ..< RESP_RECORD_DATA_START + 12).toUInt64()) * 0.05
        let bolusExtendedAmount = Double(totalData.subdata(in: RESP_RECORD_DATA_START + 12 ..< RESP_RECORD_DATA_START + 14).toUInt64()) * 0.05
        let bolusExtendedDurationMinutes = totalData.subdata(in: RESP_RECORD_DATA_START + 14 ..< RESP_RECORD_DATA_START + 16).toUInt64()
        let bolusExtendedDuration = TimeInterval(bolusExtendedDurationMinutes * 60)
        let bolusExtendedDelivered = Double(totalData.subdata(in: RESP_RECORD_DATA_START + 16 ..< RESP_RECORD_DATA_START + 18).toUInt64()) * 0.05
        let bolusCarb = UInt16(totalData.subdata(in: RESP_RECORD_DATA_START + 18 ..< RESP_RECORD_DATA_START + 20).toUInt64())
        let bolusGlucose = UInt16(totalData.subdata(in: RESP_RECORD_DATA_START + 20 ..< RESP_RECORD_DATA_START + 22).toUInt64())
        let bolusIOB = UInt16(totalData.subdata(in: RESP_RECORD_DATA_START + 22 ..< RESP_RECORD_DATA_START + 24).toUInt64())
        let bolusType = BolusType(rawValue: UInt8(typeAndWizard & 0x0F)) ?? .NONE
        let bolusWizard = (typeAndWizard & 0xF0) != 0

        return BolusRecord(
            bolusType: bolusType,
            bolusWizard: bolusWizard,
            bolusCause: bolusCause,
            bolusStartTime: bolusStartTime,
            bolusNormalAmount: bolusNormalAmount,
            bolusNormalDelivered: bolusNormalDelivered,
            bolusExtendedAmount: bolusExtendedAmount,
            bolusExtendedDuration: bolusExtendedDuration,
            bolusExtendedDelivered: bolusExtendedDelivered,
            bolusCarb: bolusCarb,
            bolusGlucose: bolusGlucose,
            bolusIOB: bolusIOB
        )
    }

    private func parseBasalRecord(patchId: UInt64, sequence: UInt16) -> BasalRecord {
        let basalStartTime = Date.fromMedtrumSeconds(
            totalData.subdata(in: RESP_RECORD_DATA_START ..< RESP_RECORD_DATA_START + 4).toUInt64()
        )
        let basalEndTime = Date.fromMedtrumSeconds(
            totalData.subdata(in: RESP_RECORD_DATA_START + 4 ..< RESP_RECORD_DATA_START + 8).toUInt64()
        )
        let basalType = BasalType(rawValue: totalData[RESP_RECORD_DATA_START + 8]) ?? .NONE
        let basalEndReason = BasalEndReason(rawValue: totalData[RESP_RECORD_DATA_START + 9])
        let basalRate = Double(totalData.subdata(in: RESP_RECORD_DATA_START + 10 ..< RESP_RECORD_DATA_START + 12).toUInt64()) * 0.05
        let basalDelivered = Double(totalData.subdata(in: RESP_RECORD_DATA_START + 12 ..< RESP_RECORD_DATA_START + 14).toUInt64()) * 0.05
        let basalPercent = UInt16(totalData.subdata(in: RESP_RECORD_DATA_START + 14 ..< RESP_RECORD_DATA_START + 16).toUInt64())

        return BasalRecord(
            patchId: patchId,
            sequence: sequence,
            basalStartTime: basalStartTime,
            basalEndTime: basalEndTime,
            basalType: basalType,
            basalEndReason: basalEndReason,
            basalRate: basalRate,
            basalDelivered: basalDelivered,
            basalPercent: basalPercent
        )
    }

    private func parseAlarmRecord() -> AlarmRecord {
        let timestamp = Date.fromMedtrumSeconds(
            totalData.subdata(in: RESP_RECORD_DATA_START + 4 ..< RESP_RECORD_DATA_START + 8).toUInt64()
        )

        return AlarmRecord(
            timestamp: timestamp,
            payload: totalData.subdata(in: RESP_RECORD_DATA_START ..< totalData.count)
        )
    }

    private func parseTddRecord() -> TddRecord {
        let timestamp = Date.fromMedtrumSeconds(
            totalData.subdata(in: RESP_RECORD_DATA_START ..< RESP_RECORD_DATA_START + 4).toUInt64()
        )
        let timeZoneOffset = UInt16(totalData.subdata(in: RESP_RECORD_DATA_START + 4 ..< RESP_RECORD_DATA_START + 6).toUInt64())
        let tddMinutes = UInt16(totalData.subdata(in: RESP_RECORD_DATA_START + 6 ..< RESP_RECORD_DATA_START + 8).toUInt64())
        let glucoseRecordTime = totalData.subdata(in: RESP_RECORD_DATA_START + 8 ..< RESP_RECORD_DATA_START + 12).toUInt64()
        let tdd = totalData.subdata(in: RESP_RECORD_DATA_START + 12 ..< RESP_RECORD_DATA_START + 16).toFloat32()
        let basalTdd = totalData.subdata(in: RESP_RECORD_DATA_START + 16 ..< RESP_RECORD_DATA_START + 20).toFloat32()
        let glucose = totalData.subdata(in: RESP_RECORD_DATA_START + 20 ..< RESP_RECORD_DATA_START + 24).toFloat32()
        let usedTdd = totalData.subdata(in: RESP_RECORD_DATA_START + 32 ..< RESP_RECORD_DATA_START + 36).toFloat32()
        let usedIBasal = totalData.subdata(in: RESP_RECORD_DATA_START + 36 ..< RESP_RECORD_DATA_START + 40).toFloat32()
        let usedSgBasal = totalData.subdata(in: RESP_RECORD_DATA_START + 40 ..< RESP_RECORD_DATA_START + 44).toFloat32()
        let usedUMax = totalData.subdata(in: RESP_RECORD_DATA_START + 44 ..< RESP_RECORD_DATA_START + 48).toFloat32()
        let newTdd = totalData.subdata(in: RESP_RECORD_DATA_START + 48 ..< RESP_RECORD_DATA_START + 52).toFloat32()
        let newIBasal = totalData.subdata(in: RESP_RECORD_DATA_START + 52 ..< RESP_RECORD_DATA_START + 56).toFloat32()
        let newSgBasal = totalData.subdata(in: RESP_RECORD_DATA_START + 56 ..< RESP_RECORD_DATA_START + 60).toFloat32()
        let newUMax = totalData.subdata(in: RESP_RECORD_DATA_START + 60 ..< RESP_RECORD_DATA_START + 64).toFloat32()

        return TddRecord(
            timestamp: timestamp,
            timeZoneOffset: timeZoneOffset,
            tddMinutes: tddMinutes,
            glucoseRecordTime: glucoseRecordTime,
            tdd: tdd,
            basalTdd: basalTdd,
            glucose: glucose,
            usedTdd: usedTdd,
            usedIBasal: usedIBasal,
            usedSgBasal: usedSgBasal,
            usedUMax: usedUMax,
            newTdd: newTdd,
            newIBasal: newIBasal,
            newSgBasal: newSgBasal,
            newUMax: newUMax
        )
    }
}

private extension Data {
    // Reads 4 little-endian bytes as an IEEE-754 32-bit float (matches AAPS Kotlin
    // ByteArray.toFloat() extension used in GetRecordPacket).
    func toFloat32() -> Float {
        precondition(count >= 4)
        var bits: UInt32 = 0
        for i in 0 ..< 4 {
            bits |= UInt32(self[i]) << (8 * i)
        }
        return Float(bitPattern: bits)
    }
}

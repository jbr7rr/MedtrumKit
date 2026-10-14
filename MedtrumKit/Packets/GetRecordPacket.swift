import Foundation

/// One entry of the pump's own event log. The pump keeps a numbered record per delivery event, so
/// unlike the status notifications these carry real start/end times and the amount the pump itself
/// says it delivered.
///
/// Ported from AndroidAPS (`GetRecordPacket.kt`), including the offsets and the fields we don't
/// have a use for yet - they are cheap to keep and expensive to reverse-engineer twice.
enum PumpRecord {
    case bolus(BolusRecord)
    case basal(BasalRecord)
    case tdd(TddRecord)
    /// A record we know exists but don't parse (alarm, auto mode, time sync, ...)
    case unhandled(type: UInt8)
    /// The record header wasn't 0xAA, so the payload is not a record at all
    case invalid
    /// The response was too short for the record type it claims to be
    case truncated(type: UInt8, size: Int)
}

struct BolusRecord {
    let type: BolusType
    let wizard: Bool
    let cause: UInt8
    let startTime: Date
    let normalAmount: Double
    let normalDelivered: Double
    let extendedAmount: Double
    let extendedDuration: TimeInterval
    let extendedDelivered: Double
    let carbs: UInt64
    let glucose: UInt64
    let iob: UInt64
}

struct BasalRecord {
    let type: BasalType
    let endReason: BasalEndReason?
    let rawEndReason: UInt8
    let startTime: Date
    let endTime: Date
    let rate: Double
    let delivered: Double
    let percent: UInt64

    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

struct TddRecord {
    let timestamp: Date
    let timeZoneOffset: UInt64
    let minutes: UInt64
    let total: Float
    let basal: Float
    let glucose: Float

    var bolus: Float {
        total - basal
    }
}

struct GetRecordResponse {
    let sequence: Int
    let patchId: UInt64
    let serial: UInt64
    let record: PumpRecord
}

class GetRecordPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = GetRecordResponse

    let commandType: UInt8 = CommandType.GET_RECORD

    private static let headerOffset = 6
    private static let typeOffset = 8
    private static let serialOffset = 10
    private static let patchIdOffset = 14
    private static let sequenceOffset = 16
    private static let dataOffset = 18

    private static let validHeader: UInt8 = 0xAA // 170

    // The pump uses two type codes for both bolus and basal records - the high bit appears to be a
    // flag we don't decode, the payload layout is the same either way
    private static let bolusRecord: UInt8 = 1
    private static let bolusRecordAlt: UInt8 = 65
    private static let basalRecord: UInt8 = 2
    private static let basalRecordAlt: UInt8 = 66
    private static let tddRecord: UInt8 = 9

    /// The record types the patch writes. We only decode bolus, basal and TDD; the rest are named here
    /// so an unparsed record is still identifiable on the debug screen. AndroidAPS knows the same names
    /// and does not decode their payloads either.
    static func name(forRecordType type: UInt8) -> String {
        switch type {
        case bolusRecord,
             bolusRecordAlt: "BOLUS"
        case basalRecord,
             basalRecordAlt: "BASAL"
        case 3: "ALARM"
        case 4: "AUTO"
        case 5: "TIME_SYNC"
        case 6: "AUTO1"
        case 7: "AUTO2"
        case 8: "AUTO3"
        case tddRecord: "TDD"
        default: "UNKNOWN"
        }
    }

    // How much of the record payload we actually read. The records are longer than this - these are
    // the offsets past which we don't decode anything.
    private static let bolusRecordSize = 24
    private static let basalRecordSize = 16
    private static let tddRecordSize = 24

    let mimimumDataSize: Int = GetRecordPacket.dataOffset

    private let recordIndex: Int
    private let patchId: UInt64

    init(recordIndex: Int, patchId: UInt64) {
        self.recordIndex = recordIndex
        self.patchId = patchId
    }

    func getRequestBytes() -> Data {
        UInt64(recordIndex).toData(length: 2) + patchId.toData(length: 2)
    }

    func parseResponse() -> GetRecordResponse {
        GetRecordResponse(
            sequence: Int(field(Self.sequenceOffset, 2)),
            patchId: field(Self.patchIdOffset, 2),
            serial: field(Self.serialOffset, 4),
            record: parseRecord()
        )
    }

    private func parseRecord() -> PumpRecord {
        guard totalData[Self.headerOffset] == Self.validHeader else {
            return .invalid
        }

        let type = totalData[Self.typeOffset]
        switch type {
        case Self.bolusRecord,
             Self.bolusRecordAlt:
            guard has(Self.bolusRecordSize) else {
                return .truncated(type: type, size: totalData.count)
            }
            return .bolus(parseBolusRecord())

        case Self.basalRecord,
             Self.basalRecordAlt:
            guard has(Self.basalRecordSize) else {
                return .truncated(type: type, size: totalData.count)
            }
            return .basal(parseBasalRecord())

        case Self.tddRecord:
            guard has(Self.tddRecordSize) else {
                return .truncated(type: type, size: totalData.count)
            }
            return .tdd(parseTddRecord())

        default:
            return .unhandled(type: type)
        }
    }

    private func parseBolusRecord() -> BolusRecord {
        let typeAndWizard = data(0)

        return BolusRecord(
            type: BolusType(rawValue: typeAndWizard & 0x0F) ?? .NONE,
            wizard: typeAndWizard & 0xF0 != 0,
            cause: data(1),
            startTime: Date.fromMedtrumSeconds(data(4, 4)),
            normalAmount: Double(data(8, 2)) * 0.05,
            normalDelivered: Double(data(10, 2)) * 0.05,
            extendedAmount: Double(data(12, 2)) * 0.05,
            extendedDuration: .minutes(Double(data(14, 2))),
            extendedDelivered: Double(data(16, 2)) * 0.05,
            carbs: data(18, 2),
            glucose: data(20, 2),
            iob: data(22, 2)
        )
    }

    private func parseBasalRecord() -> BasalRecord {
        let rawEndReason = data(9)

        return BasalRecord(
            type: BasalType(rawValue: data(8)) ?? .NONE,
            endReason: BasalEndReason(rawValue: rawEndReason),
            rawEndReason: rawEndReason,
            startTime: Date.fromMedtrumSeconds(data(0, 4)),
            endTime: Date.fromMedtrumSeconds(data(4, 4)),
            rate: Double(data(10, 2)) * 0.05,
            delivered: Double(data(12, 2)) * 0.05,
            percent: data(14, 2)
        )
    }

    private func parseTddRecord() -> TddRecord {
        TddRecord(
            timestamp: Date.fromMedtrumSeconds(data(0, 4)),
            timeZoneOffset: data(4, 2),
            minutes: data(6, 2),
            total: float(12),
            basal: float(16),
            glucose: float(20)
        )
    }

    /// Is there at least `size` bytes of record payload?
    private func has(_ size: Int) -> Bool {
        totalData.count >= Self.dataOffset + size
    }

    /// A field of the record header, relative to the start of the response
    private func field(_ offset: Int, _ length: Int) -> UInt64 {
        totalData.subdata(in: offset ..< offset + length).toUInt64()
    }

    /// A field of the record payload, relative to the start of the record data
    private func data(_ offset: Int, _ length: Int) -> UInt64 {
        field(Self.dataOffset + offset, length)
    }

    private func data(_ offset: Int) -> UInt8 {
        totalData[Self.dataOffset + offset]
    }

    private func float(_ offset: Int) -> Float {
        totalData.subdata(in: Self.dataOffset + offset ..< Self.dataOffset + offset + 4).toFloat()
    }
}

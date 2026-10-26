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
    /// An event that delivered nothing - an alarm, a resume, the daily snapshot, the base's counters. Decoded for the log
    /// and the record screen only: nothing of ours is matched against these, they go wherever `unhandled` goes.
    case event(EventRecord)
    /// A record we know exists but don't parse (auto mode, time sync, ...) - or one of the `event` types too short for
    /// its payload
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

    /// `timeZoneOffset` read as the signed minutes east of UTC it is
    var signedTimeZoneOffset: Int {
        Int(Int16(truncatingIfNeeded: timeZoneOffset))
    }
}

/// The records of `PumpRecord.event`. Their layouts are not from AndroidAPS, which leaves them undecoded: they were
/// worked out against the status notifications and Nightscout notes of the same second (jbr7rr/MedtrumKit#217), and
/// checked against our own device's frames.
enum EventRecord {
    case alarm(AlarmRecord)
    case resumed(ResumedRecord)
    case dailySnapshot(DailySnapshotRecord)
    case baseCounters(BaseCountersRecord)
}

/// Record type 3: an alarm the patch raised, by its bit in the status's alarm field (`MASK_ALARM`)
struct AlarmRecord {
    /// Seconds since the patch first powered up on the base - the same counter as the status's patch age
    let patchAge: UInt64
    let timestamp: Date
    /// The number of the bit this alarm sets in the status's alarm field: the same numbering, so 2 is low reservoir
    let bit: UInt8
    /// Two values we don't know the meaning of - the first was always 5 for a suspend in #217's records
    let unknown1: UInt64
    let unknown2: UInt64

    /// What the bit means, nil for one we have no name for. Bit 14 is one of those: seen in a status on a deactivated
    /// patch only.
    var name: String? {
        switch bit {
        case 1: "low battery"
        case 2: "low reservoir"
        case 3: "expires soon"
        case 4: "delivery suspended"
        // From the status of a live occlusion: no occlusion record has been seen yet
        case 6: "occlusion"
        // Device 2026-10-26 09:09:00 UTC: record #1643, as the patch ran dry - status state 98, alarm field 0x0104
        case 8: "reservoir empty"
        case 10: "patch fault"
        default: nil
        }
    }
}

/// Record type 8: delivery resumed. It follows the alarm record of the suspend (bit 4).
struct ResumedRecord {
    let timestamp: Date
}

/// Record type 10: written at the patch's local midnight, and at a fault
struct DailySnapshotRecord {
    let timestamp: Date
    /// The patch's time zone, in minutes east of UTC: the one it was given, which a DST change does not move
    let timeZoneOffset: Int
    /// Two values we don't know the meaning of
    let a: Float
    let b: Float
}

/// Record type 12: the lifetime counters of the base, written every 8 h
struct BaseCountersRecord {
    let timestamp: Date
    /// Insulin this base has delivered, over every patch it ran, in the patch's 0.05 U steps
    let lifetimeSteps: UInt64
    let operatingHours: UInt64
    let patchesUsed: UInt64

    var lifetimeInsulin: Double {
        Double(lifetimeSteps) * 0.05
    }

    /// `lifetimeInsulin` in whole units, rounded down
    var lifetimeWholeUnits: UInt64 {
        lifetimeSteps / 20
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
    /// The record's length, counted from its 0xAA header: 12 bytes of header, the payload, then a CRC-32/MPEG-2 of
    /// all that (little-endian, 4 bytes). One more byte follows the record in the response.
    private static let recordLengthOffset = 7
    private static let recordHeaderSize = 12
    private static let recordCrcSize = 4
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
    private static let alarmRecord: UInt8 = 3
    private static let resumedRecord: UInt8 = 8
    private static let tddRecord: UInt8 = 9
    private static let dailySnapshotRecord: UInt8 = 10
    private static let baseCountersRecord: UInt8 = 12

    /// The record types the patch writes. We don't decode the auto mode and time sync records; they are named
    /// here so an unparsed record is still identifiable on the debug screen. AndroidAPS knows the same names
    /// (type 8 as AUTO3) and does not decode their payloads either.
    static func name(forRecordType type: UInt8) -> String {
        switch type {
        case bolusRecord,
             bolusRecordAlt: "BOLUS"
        case basalRecord,
             basalRecordAlt: "BASAL"
        case alarmRecord: "ALARM"
        case 4: "AUTO"
        case 5: "TIME_SYNC"
        case 6: "AUTO1"
        case 7: "AUTO2"
        case resumedRecord: "RESUMED"
        case tddRecord: "TDD"
        case dailySnapshotRecord: "DAILY"
        case baseCountersRecord: "BASE"
        default: "UNKNOWN"
        }
    }

    // How much of the record payload we actually read. The records are longer than this - these are
    // the offsets past which we don't decode anything.
    private static let bolusRecordSize = 24
    private static let basalRecordSize = 16
    private static let tddRecordSize = 24
    // The event records' payloads are read by the length they give themselves, so their CRC is never read as payload:
    // alarm and resumed are this long, the snapshot 20 (four zero bytes after what we read), the base counters 12
    private static let alarmRecordSize = 16
    private static let resumedRecordSize = 8
    private static let dailySnapshotRecordSize = 16
    private static let baseCountersRecordSize = 12

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

        // Too short for its payload, an event record is left unparsed rather than `truncated`: it is not read again
        // or skipped for that, as it wasn't before these were decoded. Its length is the one it gives itself (byte 7);
        // dose records are still read by the response's length - `has`.
        case Self.alarmRecord:
            guard hasEventPayload(Self.alarmRecordSize) else {
                return .unhandled(type: type)
            }
            return .event(.alarm(parseAlarmRecord()))

        case Self.resumedRecord:
            guard hasEventPayload(Self.resumedRecordSize) else {
                return .unhandled(type: type)
            }
            return .event(.resumed(parseResumedRecord()))

        case Self.dailySnapshotRecord:
            guard hasEventPayload(Self.dailySnapshotRecordSize) else {
                return .unhandled(type: type)
            }
            return .event(.dailySnapshot(parseDailySnapshotRecord()))

        case Self.baseCountersRecord:
            guard hasEventPayload(Self.baseCountersRecordSize) else {
                return .unhandled(type: type)
            }
            return .event(.baseCounters(parseBaseCountersRecord()))

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

    /// Patch age (4), time (4), the alarm's bit (1), `00`, `ffff`, two unknown UInt16
    private func parseAlarmRecord() -> AlarmRecord {
        AlarmRecord(
            patchAge: data(0, 4),
            timestamp: Date.fromMedtrumSeconds(data(4, 4)),
            bit: data(8),
            unknown1: data(12, 2),
            unknown2: data(14, 2)
        )
    }

    /// `01 00 ff ff`, then the time (4)
    private func parseResumedRecord() -> ResumedRecord {
        ResumedRecord(timestamp: Date.fromMedtrumSeconds(data(4, 4)))
    }

    /// Time (4), time-zone offset in minutes (Int16), `ffff`, two Float32, then four zero bytes (payload, not the CRC)
    private func parseDailySnapshotRecord() -> DailySnapshotRecord {
        DailySnapshotRecord(
            timestamp: Date.fromMedtrumSeconds(data(0, 4)),
            timeZoneOffset: Int(Int16(truncatingIfNeeded: data(4, 2))),
            a: float(8),
            b: float(12)
        )
    }

    /// Time (4), lifetime insulin in 0.05 U steps (4), operating hours (2), patches used (2)
    private func parseBaseCountersRecord() -> BaseCountersRecord {
        BaseCountersRecord(
            timestamp: Date.fromMedtrumSeconds(data(0, 4)),
            lifetimeSteps: data(4, 4),
            operatingHours: data(8, 2),
            patchesUsed: data(10, 2)
        )
    }

    /// Does the record say it has at least `size` bytes of payload, and are they there? The length byte counts the
    /// header and the CRC, which `has` alone would read as payload in a record shorter than its type's.
    private func hasEventPayload(_ size: Int) -> Bool {
        let payload = Int(totalData[Self.recordLengthOffset]) - Self.recordHeaderSize - Self.recordCrcSize
        return payload >= size && has(size)
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

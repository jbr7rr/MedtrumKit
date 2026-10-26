@testable import MedtrumKit
import XCTest

/// GET_RECORD event records - alarm (3), resumed (8), daily snapshot (10), base counters (12) - decoded from our device's
/// frames (2026-10-25/26, patches 274 and older) and the examples of jbr7rr/MedtrumKit#217
final class EventRecordTests: XCTestCase {
    /// The fragments as the patch sent them: decoded as the link does, CRCs checked
    private func parse(_ fragments: [String]) -> GetRecordResponse {
        var packet = GetRecordPacket(recordIndex: 0, patchId: 0)
        for fragment in fragments {
            packet.decode(Data(hex: fragment)!)
        }
        XCTAssertFalse(packet.failed)
        XCTAssertTrue(packet.isComplete)
        return packet.parseResponse()
    }

    /// A record of `type` with this payload, framed as the patch frames one: its length, its CRC, the byte after it
    private func parse(type: UInt8, payload: String) -> GetRecordResponse {
        // `Data(hex:)` can't take an empty string
        let payload = payload.isEmpty ? Data() : Data(hex: payload)!
        return parse(PatchBytes.framedRecord(type: type, sequence: 1643, patchId: 274, payload: payload))
    }

    private func medtrumDate(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_388_534_400 + seconds)
    }

    // MARK: - Alarm

    /// Device 2026-10-26 09:09:00 UTC: patch 274 ran dry - status state 98, alarm field 0x0104
    private static let reservoirEmpty = [
        "276395010000aa2003ff9e75aef712016b065bda",
        "27639502c104002cbe1b180800ffffa20ea20e23",
        "2763950383693d2dd13a"
    ]

    func testAlarmRecordOfReservoirEmptyFromDevice() {
        let response = parse(Self.reservoirEmpty)
        XCTAssertEqual(response.sequence, 1643)
        XCTAssertEqual(response.patchId, 274)

        guard case let .event(.alarm(alarm)) = response.record else {
            return XCTFail("Expected an alarm record, got \(response.record)")
        }
        XCTAssertEqual(alarm.patchAge, 311_643)
        XCTAssertEqual(alarm.timestamp, Date(timeIntervalSince1970: 1_793_005_740)) // 2026-10-26 09:09:00 UTC
        XCTAssertEqual(alarm.bit, 8)
        XCTAssertEqual(alarm.name, "reservoir empty")
        XCTAssertEqual(alarm.unknown1, 0x0EA2)
        XCTAssertEqual(alarm.unknown2, 0x0EA2)

        let described = RecordSyncer.describe(response.record)
        XCTAssertEqual(described.kind, "ALARM")
        XCTAssertTrue(described.summary.hasPrefix("reservoir empty (bit 8) age=311643s time="), described.summary)
        XCTAssertEqual(described.label, "Reservoir empty · patch age 86.6 h")
        XCTAssertEqual(described.eventDate, alarm.timestamp)
    }

    /// #217: record 1340 of patch 309, set as the reservoir went 20.05 -> 19.95 U
    func testAlarmRecordOfLowReservoirFromIssue() {
        let response = parse([
            "276307010000aa2003ffce1f6c0d35013c05aec6",
            "2763070249040037f2d9170200ffff4b09bc07ac",
            "27630703f5a3007dcba6"
        ])
        XCTAssertEqual(response.sequence, 1340)
        XCTAssertEqual(response.patchId, 309)

        guard case let .event(.alarm(alarm)) = response.record else {
            return XCTFail("Expected an alarm record, got \(response.record)")
        }
        XCTAssertEqual(alarm.patchAge, 281_006)
        XCTAssertEqual(alarm.timestamp, medtrumDate(400_159_287)) // 2026-09-06 11:21:27 UTC
        XCTAssertEqual(alarm.bit, 2)
        XCTAssertEqual(alarm.name, "low reservoir")
        XCTAssertEqual(alarm.unknown1, 0x094B)
        XCTAssertEqual(alarm.unknown2, 0x07BC)
        XCTAssertEqual(RecordSyncer.describe(response.record).label, "Low reservoir · patch age 78.1 h")
    }

    /// Device 2026-10-25 21:31:32 UTC, record 1414: the low-reservoir status of pass 23 (alarm field 0x0004)
    func testAlarmRecordOfLowReservoirFromDevice() {
        let response = parse([
            "2763fd010000aa2003ff9e75aef712018605e395",
            "2763fd021d0400b41a1b180200ffffa20e140d5c",
            "2763fd03f9958d978b48"
        ])
        XCTAssertEqual(response.sequence, 1414)

        guard case let .event(.alarm(alarm)) = response.record else {
            return XCTFail("Expected an alarm record, got \(response.record)")
        }
        XCTAssertEqual(alarm.bit, 2)
        XCTAssertEqual(alarm.timestamp, medtrumDate(404_429_492))
    }

    /// Device 2026-10-26 07:54:25 UTC, record 1630: a suspend - its first unknown is 5, as in all of #217's
    func testAlarmRecordOfSuspendFromDevice() {
        let response = parse([
            "276362010000aa2003ff9e75aef712015e06e084",
            "27636202af0400b1ac1b180400ffff05008a0e47",
            "2763620330af2cacbe11"
        ])
        XCTAssertEqual(response.sequence, 1630)

        guard case let .event(.alarm(alarm)) = response.record else {
            return XCTFail("Expected an alarm record, got \(response.record)")
        }
        XCTAssertEqual(alarm.bit, 4)
        XCTAssertEqual(alarm.name, "delivery suspended")
        XCTAssertEqual(alarm.patchAge, 307_168)
        XCTAssertEqual(alarm.timestamp, medtrumDate(404_466_865))
        XCTAssertEqual(alarm.unknown1, 5)
        XCTAssertEqual(RecordSyncer.describe(response.record).label, "Delivery suspended · patch age 85.3 h")
    }

    func testAlarmRecordOfAnUnknownBit() {
        for bit in [0, 5, 14, 255] {
            let payload = "5bc104002cbe1b18" + String(format: "%02x", bit) + "00ffffa20ea20e"
            guard case let .event(.alarm(alarm)) = parse(type: 3, payload: payload).record else {
                return XCTFail("Expected an alarm record for bit \(bit)")
            }
            XCTAssertEqual(Int(alarm.bit), bit)
            XCTAssertNil(alarm.name)

            let described = RecordSyncer.describe(.event(.alarm(alarm)))
            XCTAssertTrue(described.summary.hasPrefix("alarm bit \(bit) (bit \(bit)) age=311643s"), described.summary)
            XCTAssertEqual(described.label, "Alarm bit \(bit) · patch age 86.6 h")
        }
    }

    func testEveryNamedAlarmBit() {
        let names: [Int: String] = [
            1: "Low battery",
            2: "Low reservoir",
            3: "Expires soon",
            4: "Delivery suspended",
            6: "Occlusion",
            8: "Reservoir empty",
            10: "Patch fault"
        ]
        for (bit, name) in names {
            let payload = "100e00002cbe1b18" + String(format: "%02x", bit) + "00ffff00000000"
            XCTAssertEqual(
                RecordSyncer.describe(parse(type: 3, payload: payload).record).label,
                "\(name) · patch age 1.0 h"
            )
        }
    }

    // MARK: - Resumed

    /// Device 2026-10-26 08:47:39 UTC, record 1631: the resume after the suspend of record 1630
    func testResumedRecordFromDevice() {
        let response = parse([
            "1f637a010000aa1808ff9e75aef712015f060141",
            "1f637a0200ffff2bb91b18b1a0bce981e2"
        ])
        XCTAssertEqual(response.sequence, 1631)

        guard case let .event(.resumed(resumed)) = response.record else {
            return XCTFail("Expected a resumed record, got \(response.record)")
        }
        XCTAssertEqual(resumed.timestamp, Date(timeIntervalSince1970: 1_793_004_459))

        let described = RecordSyncer.describe(response.record)
        XCTAssertEqual(described.kind, "RESUMED")
        XCTAssertTrue(described.summary.hasPrefix("time="), described.summary)
        XCTAssertEqual(described.label, "Delivery resumed")
        XCTAssertEqual(described.eventDate, resumed.timestamp)
    }

    // MARK: - Daily snapshot

    /// Device, record 1426: the patch's midnight, 2026-10-25 22:00:00 UTC - after DST had ended, on the zone it kept
    func testDailySnapshotAtMidnightFromDevice() {
        let response = parse([
            "2b631f010000aa240aff9e75aef71201920560cc",
            "2b631f02211b187800ffff9c5b60407d393640e5",
            "2b631f0300000000b33652972543"
        ])
        XCTAssertEqual(response.sequence, 1426)

        guard case let .event(.dailySnapshot(snapshot)) = response.record else {
            return XCTFail("Expected a daily snapshot, got \(response.record)")
        }
        XCTAssertEqual(snapshot.timestamp, Date(timeIntervalSince1970: 1_792_965_600))
        XCTAssertEqual(snapshot.timeZoneOffset, 120)
        XCTAssertEqual(snapshot.a, 3.5056, accuracy: 0.0001)
        XCTAssertEqual(snapshot.b, 2.8473, accuracy: 0.0001)

        let described = RecordSyncer.describe(response.record)
        XCTAssertEqual(described.kind, "DAILY")
        XCTAssertTrue(described.summary.hasSuffix("tzOffset=120 a=3.506 b=2.847"), described.summary)
        XCTAssertEqual(described.label, "Daily snapshot · UTC+2")
        XCTAssertEqual(described.eventDate, snapshot.timestamp)
    }

    /// Device, record 1642: written at the dry-out, 2026-10-26 09:09:00 UTC, just before the alarm record 1643
    func testDailySnapshotAtAFaultFromDevice() {
        let response = parse([
            "2b6394010000aa240aff9e75aef712016a062c69",
            "2b639402be1b187800ffff8428c23f77c85b3f7f",
            "2b63940300000000bd1d794d9da1"
        ])
        XCTAssertEqual(response.sequence, 1642)

        guard case let .event(.dailySnapshot(snapshot)) = response.record else {
            return XCTFail("Expected a daily snapshot, got \(response.record)")
        }
        XCTAssertEqual(snapshot.timestamp, Date(timeIntervalSince1970: 1_793_005_740))
        XCTAssertEqual(snapshot.timeZoneOffset, 120)
        XCTAssertEqual(snapshot.a, 1.5169, accuracy: 0.0001)
        XCTAssertEqual(snapshot.b, 0.8585, accuracy: 0.0001)
        XCTAssertTrue(RecordSyncer.describe(response.record).summary.hasSuffix("tzOffset=120 a=1.517 b=0.859"))
    }

    func testDailySnapshotWithAZoneWestOfUTC() {
        // -300 min, UTC-5
        guard case let .event(.dailySnapshot(snapshot)) = parse(
            type: 10,
            payload: "2cbe1b18d4feffff8428c23f77c85b3f00000000"
        ).record else {
            return XCTFail("Expected a daily snapshot")
        }
        XCTAssertEqual(snapshot.timeZoneOffset, -300)
        XCTAssertEqual(RecordSyncer.describe(.event(.dailySnapshot(snapshot))).label, "Daily snapshot · UTC-5")
    }

    // MARK: - Base counters

    /// Device 2026-10-26 02:35:00 UTC, record 1520
    func testBaseCountersFromDevice() {
        let response = parse([
            "236329010000aa1c0c009e75aef71201f005d475",
            "23632902611b18e1a50500f0228f007e6666d663",
            "23632903a457"
        ])
        XCTAssertEqual(response.sequence, 1520)

        guard case let .event(.baseCounters(base)) = response.record else {
            return XCTFail("Expected base counters, got \(response.record)")
        }
        XCTAssertEqual(base.timestamp, Date(timeIntervalSince1970: 1_792_982_100))
        XCTAssertEqual(base.lifetimeSteps, 370_145)
        XCTAssertEqual(base.lifetimeInsulin, 18507.25, accuracy: 0.0001)
        XCTAssertEqual(base.operatingHours, 8944)
        XCTAssertEqual(base.patchesUsed, 143)

        let described = RecordSyncer.describe(response.record)
        XCTAssertEqual(described.kind, "BASE")
        XCTAssertTrue(described.summary.hasSuffix("lifetime=18507.25U hours=8944 patches=143"), described.summary)
        XCTAssertEqual(described.label, "Base: 18,507 U · 8944 h · 143 patches")
        XCTAssertEqual(described.eventDate, base.timestamp)
    }

    /// #217's example, its payload: the four bytes the issue showed after it are the record's CRC
    func testBaseCountersFromIssue() {
        guard case let .event(.baseCounters(base)) = parse(type: 12, payload: "70d6ce17237c0300401f2c00").record else {
            return XCTFail("Expected base counters")
        }
        XCTAssertEqual(base.timestamp, medtrumDate(399_431_280))
        XCTAssertEqual(base.lifetimeInsulin, 11419.35, accuracy: 0.0001)
        XCTAssertEqual(base.lifetimeWholeUnits, 11419)
        XCTAssertEqual(base.operatingHours, 8000)
        XCTAssertEqual(base.patchesUsed, 44)

        let described = RecordSyncer.describe(.event(.baseCounters(base)))
        XCTAssertTrue(described.summary.hasSuffix("lifetime=11419.35U hours=8000 patches=44"), described.summary)
        XCTAssertEqual(described.label, "Base: 11,419 U · 8000 h · 44 patches")
    }

    // MARK: - Framing

    /// Byte 7 is the record's length from 0xAA, and its last four bytes the CRC-32/MPEG-2 of the rest, little-endian -
    /// then one more byte. Every device frame here, and the issue's: alarm 16 bytes of payload, resumed 8, snapshot 20
    /// (its zeros are payload), base counters 12.
    func testRecordLengthAndCrcOfDeviceFrames() {
        let frames: [(fragments: [String], payload: Int)] = [
            (Self.reservoirEmpty, 16),
            (["276307010000aa2003ffce1f6c0d35013c05aec6", "2763070249040037f2d9170200ffff4b09bc07ac", "27630703f5a3007dcba6"], 16),
            (["1f637a010000aa1808ff9e75aef712015f060141", "1f637a0200ffff2bb91b18b1a0bce981e2"], 8),
            (["2b631f010000aa240aff9e75aef71201920560cc", "2b631f02211b187800ffff9c5b60407d393640e5", "2b631f0300000000b33652972543"], 20),
            (["236329010000aa1c0c009e75aef71201f005d475", "23632902611b18e1a50500f0228f007e6666d663", "23632903a457"], 12)
        ]
        for (fragments, payload) in frames {
            var packet = GetRecordPacket(recordIndex: 0, patchId: 0)
            for fragment in fragments {
                packet.decode(Data(hex: fragment)!)
            }
            let data = packet.totalData
            let length = Int(data[7])
            XCTAssertEqual(length, 12 + payload + 4)
            XCTAssertEqual(data.count, 6 + length + 1)

            let record = data.subdata(in: 6 ..< 6 + length - 4)
            let crc = UInt32(data.subdata(in: 6 + length - 4 ..< 6 + length).toUInt64())
            XCTAssertEqual(PatchBytes.crc32Mpeg2(record), crc)
        }
    }

    // MARK: - Too short

    /// Too short for its payload by the length it gives itself, an event record is left unhandled - as all of them were
    /// before - rather than truncated, which would have it read again and skipped. Framed as the patch frames them, so
    /// the CRC and the byte after it are there: read by the response's length, they would pass for payload.
    func testEventRecordsTooShortAreLeftUnhandled() {
        let cases: [(type: UInt8, payload: String)] = [
            (3, ""),
            (3, "5bc104002cbe1b18"),
            (3, "5bc104002cbe1b180800ffff"),
            (3, "5bc104002cbe1b180800ffffa20ea2"),
            (8, "0100ffff"),
            (8, "0100ffff2bb91b"),
            (10, "2cbe1b187800ffff8428c23f"),
            (10, "2cbe1b187800ffff8428c23f77c85b"),
            (12, "70d6ce17237c0300"),
            (12, "70d6ce17237c0300401f2c")
        ]
        for (type, payload) in cases {
            guard case let .unhandled(unhandledType) = parse(type: type, payload: payload).record else {
                XCTFail("Expected type \(type) with \(payload.count / 2) payload bytes unhandled")
                continue
            }
            XCTAssertEqual(unhandledType, type)
        }
    }

    /// A record that says it is long enough but the response is cut short: unhandled, not read past its end
    func testEventRecordLongerThanTheResponseIsLeftUnhandled() {
        let packet = GetRecordPacket(recordIndex: 0, patchId: 0)
        // base counters of 12 bytes by its length byte (0x1c), 6 of them there
        packet.totalData = Data(hex: "236329010000aa1c0c009e75aef71201f005d4611b18e1a5")!

        guard case .unhandled(12) = packet.parseResponse().record else {
            return XCTFail("Expected an unhandled record")
        }
    }

    // MARK: - Time zone

    private static func snapshot(_ offset: Int) -> PumpRecord {
        .event(.dailySnapshot(DailySnapshotRecord(
            timestamp: Date(timeIntervalSince1970: 1_792_965_600),
            timeZoneOffset: offset,
            a: 0,
            b: 0
        )))
    }

    /// Compared with the zone set on the patch: after DST the phone moved, the patch and its midnight did not
    func testTimeZoneComparedWithTheOneSetOnThePatch() {
        XCTAssertNil(RecordSyncer.timeZoneMismatch(of: Self.snapshot(120), patchUTCOffset: .hours(2), phoneOffset: .hours(1)))
        XCTAssertEqual(
            RecordSyncer.timeZoneMismatch(of: Self.snapshot(120), patchUTCOffset: .hours(1), phoneOffset: .hours(1)),
            "the record's time-zone offset is 120 min (UTC+2), the one set on the patch 60 min (UTC+1), " +
                "the phone's 60 min (UTC+1)"
        )
    }

    /// With none known set, with the phone's
    func testTimeZoneComparedWithThePhoneWithNoneKnownSet() {
        XCTAssertNil(RecordSyncer.timeZoneMismatch(of: Self.snapshot(120), patchUTCOffset: nil, phoneOffset: .hours(2)))
        XCTAssertEqual(
            RecordSyncer.timeZoneMismatch(of: Self.snapshot(120), patchUTCOffset: nil, phoneOffset: .hours(1)),
            "the record's time-zone offset is 120 min (UTC+2), none known set on the patch, the phone's 60 min (UTC+1)"
        )
    }

    /// Past UTC+12 the patch is set a day less (`SetTimeZonePacket`): UTC+13 is -660 on it, which is no mismatch
    func testTimeZonePastUTCPlus12() {
        XCTAssertNil(RecordSyncer.timeZoneMismatch(of: Self.snapshot(-660), patchUTCOffset: nil, phoneOffset: .hours(13)))
        XCTAssertNil(RecordSyncer.timeZoneMismatch(of: Self.snapshot(-660), patchUTCOffset: .hours(-11), phoneOffset: .hours(13)))
        XCTAssertEqual(
            RecordSyncer.timeZoneMismatch(of: Self.snapshot(780), patchUTCOffset: nil, phoneOffset: .hours(13)),
            "the record's time-zone offset is 780 min (UTC+13), none known set on the patch, the phone's 780 min " +
                "(UTC+13), set on a patch as -660 min (UTC-11)"
        )
        XCTAssertNil(RecordSyncer.timeZoneMismatch(of: Self.snapshot(720), patchUTCOffset: nil, phoneOffset: .hours(12)))

        XCTAssertEqual(SetTimeZonePacket.patchOffset(.hours(13)), .hours(-11))
        XCTAssertEqual(SetTimeZonePacket.patchOffset(.hours(12)), .hours(12))
        XCTAssertEqual(SetTimeZonePacket.patchOffset(.hours(-5)), .hours(-5))
    }

    func testTimeZoneOfTdd() {
        let tdd = TddRecord(
            timestamp: Date(timeIntervalSince1970: 1_792_965_600),
            timeZoneOffset: 0xFED4, // -300
            minutes: 1440,
            total: 0,
            basal: 0,
            glucose: 0
        )
        XCTAssertEqual(tdd.signedTimeZoneOffset, -300)
        XCTAssertNil(RecordSyncer.timeZoneMismatch(of: .tdd(tdd), patchUTCOffset: .hours(-5), phoneOffset: .hours(-4)))
        XCTAssertEqual(
            RecordSyncer.timeZoneMismatch(of: .tdd(tdd), patchUTCOffset: nil, phoneOffset: .hours(-4)),
            "the record's time-zone offset is -300 min (UTC-5), none known set on the patch, the phone's -240 min (UTC-4)"
        )

        // Records with no time zone
        let resumed = PumpRecord.event(.resumed(ResumedRecord(timestamp: .now)))
        XCTAssertNil(RecordSyncer.timeZoneMismatch(of: resumed, patchUTCOffset: .hours(2), phoneOffset: .hours(1)))
        XCTAssertNil(RecordSyncer.timeZoneMismatch(of: .unhandled(type: 5), patchUTCOffset: nil, phoneOffset: .hours(1)))
    }

    func testUTCOffset() {
        XCTAssertEqual(RecordSyncer.utcOffset(0), "UTC+0")
        XCTAssertEqual(RecordSyncer.utcOffset(120), "UTC+2")
        XCTAssertEqual(RecordSyncer.utcOffset(345), "UTC+5:45")
        XCTAssertEqual(RecordSyncer.utcOffset(-210), "UTC-3:30")
    }
}

@testable import MedtrumKit
import XCTest

final class NotificationPacketTests: XCTestCase {
    func testBasalDataProvided() throws {
        let response = Data([32, 40, 64, 6, 25, 0, 14, 0, 84, 163, 173, 17, 17, 64, 0, 152, 14, 0, 16])
        let packet = NotificationPacket()

        packet.totalData = response

        let actual = packet.parseResponse()
        XCTAssertEqual(actual.state, .active)
        XCTAssertEqual(actual.basal?.type, .ABSOLUTE_TEMP)
        XCTAssertEqual(actual.basal?.rate ?? 0, 0.85, accuracy: 0.01)
        XCTAssertEqual(actual.basal?.sequence, 25)
        XCTAssertEqual(actual.basal?.startTime, Date(timeIntervalSince1970: 1_685_126_612))
        XCTAssertEqual(actual.reservoir ?? 0, 186.80, accuracy: 0.01)
    }

    func testSequenceDataProvided() throws {
        let response = Data([32, 0, 17, 167, 0, 14, 0, 0, 0, 0, 0, 0])
        let packet = NotificationPacket()

        packet.totalData = response

        let actual = packet.parseResponse()
        XCTAssertEqual(actual.state, .active)
        XCTAssertEqual(actual.storage?.sequence, 167)
    }

    func testTruncatedPayloadKeepsOnlyTheState() throws {
        // state 98 (reservoir empty), mask announces reservoir + storage + alarm, but the payload
        // stops halfway through the storage field - see issue #194
        let packet = NotificationPacket()
        packet.totalData = Data([98, 0x20, 0x03, 20, 0, 167, 0])

        let actual = packet.parseResponse()
        XCTAssertEqual(actual.state, .reservoirEmpty)
        XCTAssertTrue(actual.truncated)
        XCTAssertNil(actual.reservoir)
        XCTAssertNil(actual.storage)
        XCTAssertTrue(actual.activeAlarms.isEmpty)
    }

    func testNotificationWithoutFieldsIsNotTruncated() throws {
        let packet = NotificationPacket()
        packet.totalData = Data([98, 0, 0])

        let actual = packet.parseResponse()
        XCTAssertEqual(actual.state, .reservoirEmpty)
        XCTAssertFalse(actual.truncated)
    }

    func testNotificationShorterThanTheHeader() throws {
        let packet = NotificationPacket()
        packet.totalData = Data([98, 0x20])

        XCTAssertTrue(packet.hasEnoughData)

        let actual = packet.parseResponse()
        XCTAssertEqual(actual.state, .reservoirEmpty)
        XCTAssertTrue(actual.truncated)
    }

    func testBolusProgress() throws {
        let response = Data([32, 34, 16, 0, 3, 0, 198, 12, 0, 0, 0, 0, 0])
        let packet = NotificationPacket()

        packet.totalData = response

        let actual = packet.parseResponse()
        XCTAssertEqual(actual.state, .active)
        XCTAssertEqual(actual.bolus?.completed, false)
        XCTAssertEqual(actual.bolus?.delivered ?? 0, 0.15, accuracy: 0.01)
        XCTAssertEqual(actual.reservoir ?? 0, 163.50, accuracy: 0.01)
    }

    func testStateOnlyNotification() {
        let packet = NotificationPacket()
        packet.totalData = Data([98])
        XCTAssertTrue(packet.hasEnoughData)
        let response = packet.parseResponse()
        XCTAssertEqual(response.state, .reservoirEmpty)
        XCTAssertFalse(response.truncated)
    }

    func testEmptyNotificationIsRejectedWithoutTrapping() {
        let packet = NotificationPacket()
        XCTAssertFalse(packet.hasEnoughData)
        XCTAssertTrue(packet.parseResponse().truncated)
    }

    func testOutOfRangeFieldDiscardsEntirePayloadButKeepsState() {
        // Each packet also contains a valid field, which must be discarded together with the bad one.
        let payloads: [[UInt8]] = [
            [98, 0x22, 0, 0, 0xE9, 3, 20, 0], // bolus 50.05 U, valid reservoir
            [98, 0x28, 0, 6, 1, 0, 14, 0, 0, 0, 0, 0, 0x21, 3, 0, 20, 0], // basal 40.05 U/h
            [98, 0x22, 0, 0, 3, 0, 0x41, 0x1F] // valid bolus, reservoir 400.05 U
        ]
        for payload in payloads {
            let packet = NotificationPacket()
            packet.totalData = Data(payload)
            let response = packet.parseResponse()
            XCTAssertEqual(response.state, .reservoirEmpty)
            XCTAssertTrue(response.invalidPayload)
            XCTAssertFalse(response.truncated)
            XCTAssertNil(response.bolus)
            XCTAssertNil(response.basal)
            XCTAssertNil(response.reservoir)
        }
    }

    func testValidationAcceptsBoundaryValues() {
        let response = SynchronizePacketResponse(
            state: .active, bolus: BolusData(type: 0, completed: true, delivered: 50),
            basal: BasalData(type: .ABSOLUTE_TEMP, sequence: 1, patchId: 14, startTime: Date(), rate: 40, delivery: 0),
            reservoir: 400, storage: StorageData(sequence: 1, patchId: 14), activeAlarms: []
        ).validated(expectedPatchId: 14)
        XCTAssertFalse(response.invalidPayload)
        XCTAssertEqual(response.reservoir, 400)
        XCTAssertEqual(response.basal?.rate, 40)
        XCTAssertEqual(response.bolus?.delivered, 50)
    }

    func testMismatchedPatchDiscardsAllFields() {
        for basalPatch in [14.0, 15.0] {
            let response = SynchronizePacketResponse(
                state: .reservoirEmpty,
                basal: BasalData(type: .ABSOLUTE_TEMP, sequence: 1, patchId: basalPatch, startTime: Date(), rate: 2, delivery: 0),
                reservoir: 20, storage: StorageData(sequence: 1, patchId: basalPatch == 14 ? 15 : 14), activeAlarms: []
            )
            let rejected = response.validated(expectedPatchId: 14)
            XCTAssertTrue(rejected.invalidPayload)
            XCTAssertEqual(rejected.state, .reservoirEmpty)
            XCTAssertNil(rejected.basal)
            XCTAssertNil(rejected.storage)
            XCTAssertNil(rejected.reservoir)
            XCTAssertFalse(response.validated().invalidPayload) // No known patch yet during setup.
        }
    }

    /// Device 2026-10-26 10:08:55 (patch 274, the reservoir run dry): the mask announces basal, reservoir, storage, alarm
    /// and cgm - 27 bytes - and 16 come: the basal field of type none is its type byte alone. The rest is in place.
    func testBasalFieldOfTypeNoneAsItsTypeByteAlone() {
        let packet = NotificationPacket()
        packet.totalData = FakeMedtrumLink.bytes("6228130000006b061201040100000000000000")

        let actual = packet.parseResponse()
        XCTAssertEqual(actual.state, .reservoirEmpty)
        XCTAssertFalse(actual.truncated)
        XCTAssertFalse(actual.invalidPayload)
        XCTAssertNil(actual.basal)
        XCTAssertEqual(actual.reservoir, 0)
        XCTAssertEqual(actual.storage?.sequence, 1643)
        XCTAssertEqual(actual.storage?.patchId, 274)
        XCTAssertEqual(actual.activeAlarms, [.PumpLowReservoir, .ReservoirEmpty]) // 0x0104: bits 2 and 8
    }

    /// The same after fields that come before it: the suspend time, and a bolus too - the basal field's offset past them
    func testBasalFieldOfTypeNoneAsItsTypeByteAloneAfterOtherFields() {
        let suspendedAt = Date.fromMedtrumSeconds(400_000_000)
        let storage = Data([0x6B, 0x06, 0x12, 0x01])
        let packets: [(mask: [UInt8], bolus: Data)] = [([0x09, 0x01], Data()), ([0x0B, 0x01], Data([0x80, 0x06, 0x00]))]
        for (mask, bolus) in packets {
            let packet = NotificationPacket()
            packet.totalData = Data([98] + mask) + suspendedAt.toMedtrumSeconds() + bolus + Data([0]) + storage

            let actual = packet.parseResponse()
            XCTAssertFalse(actual.truncated)
            XCTAssertNil(actual.basal)
            XCTAssertEqual(actual.suspendTime, suspendedAt)
            XCTAssertEqual(actual.storage?.sequence, 1643)
            XCTAssertEqual(actual.storage?.patchId, 274)
            if !bolus.isEmpty {
                XCTAssertEqual(actual.bolus?.completed, true)
                XCTAssertEqual(actual.bolus?.delivered ?? 0, 0.3, accuracy: 0.001)
            }
        }
    }

    /// A basal field of type none in full, 12 bytes, parses as it always did
    func testBasalFieldOfTypeNoneInFull() {
        let packet = NotificationPacket()
        packet.totalData = Data([98, 0x28, 0x00, 0, 1, 0, 14, 0, 0, 0, 0, 0, 0, 0, 0, 20, 0])

        let actual = packet.parseResponse()
        XCTAssertFalse(actual.truncated)
        XCTAssertEqual(actual.basal?.type, BasalType.NONE)
        XCTAssertEqual(actual.basal?.sequence, 1)
        XCTAssertEqual(actual.basal?.patchId, 14)
        XCTAssertEqual(actual.reservoir ?? 0, 1.0, accuracy: 0.001)
    }

    /// Short of that by anything else - a byte less, or the basal field of another type - is cut short, as before
    func testShortPayloadIsStillTruncated() {
        for hex in [
            "6228130000006b0612010401000000000000", // a byte short of the type-only basal field's length
            "6228130600006b061201040100000000000000" // 16 bytes, the basal field of a temp basal
        ] {
            let packet = NotificationPacket()
            packet.totalData = FakeMedtrumLink.bytes(hex)

            let actual = packet.parseResponse()
            XCTAssertTrue(actual.truncated, hex)
            XCTAssertNil(actual.storage, hex)
            XCTAssertNil(actual.reservoir, hex)
            XCTAssertNil(actual.basal, hex)
        }
    }

    /// Device 2026-10-25 22:31:28 (patch 274): bit 2 of the alarm field first set as the reservoir went 20.0 to 19.9 U -
    /// low reservoir, as AAPS reads it (jbr7rr/MedtrumKit#217), not expires soon
    func testAlarmBitOfLowReservoirFromDevice() {
        let packet = NotificationPacket()
        packet.totalData = FakeMedtrumLink.bytes("2022038013008e018605120104000000")

        let actual = packet.parseResponse()
        XCTAssertFalse(actual.truncated)
        XCTAssertEqual(actual.reservoir ?? 0, 19.9, accuracy: 0.001)
        XCTAssertEqual(actual.storage?.sequence, 1414)
        XCTAssertEqual(actual.activeAlarms, [.PumpLowReservoir])
    }

    /// Bit i of the alarm field is the i-th alarm state as AAPS lists them: none at 0, then the three warnings
    private func alarms(_ flags: UInt16, file: StaticString = #filePath, line: UInt = #line) -> [AlarmState] {
        let packet = NotificationPacket()
        packet.totalData = Data([32, 0x00, 0x02, UInt8(flags & 0xFF), UInt8(flags >> 8), 0, 0])
        let actual = packet.parseResponse()
        XCTAssertFalse(actual.truncated, file: file, line: line)
        return actual.activeAlarms
    }

    func testAlarmBit0IsNone() {
        XCTAssertEqual(alarms(0x0001), [])
        XCTAssertEqual(alarms(0x0000), [])
    }

    func testAlarmBit1IsLowBattery() {
        XCTAssertEqual(alarms(0x0002), [.PumpLowBattery])
    }

    func testAlarmBit2IsLowReservoir() {
        XCTAssertEqual(alarms(0x0004), [.PumpLowReservoir])
    }

    func testAlarmBit3IsExpiresSoon() {
        XCTAssertEqual(alarms(0x0008), [.PumpExpiresSoon])
    }

    /// Bit 8 is reservoir empty: set with state 98 as patch 274 ran dry, as its alarm record #1643 of bit 8 shows
    func testAlarmBit8IsReservoirEmpty() {
        XCTAssertEqual(alarms(0x0100), [.ReservoirEmpty])
    }

    /// Several at once, and the other bits above 3 left to the patch state
    func testAlarmBitsCombined() {
        XCTAssertEqual(alarms(0x000F), [.PumpLowBattery, .PumpLowReservoir, .PumpExpiresSoon])
        XCTAssertEqual(alarms(0x010A), [.PumpLowBattery, .PumpExpiresSoon, .ReservoirEmpty])
        XCTAssertEqual(alarms(0xFEF1), [])
        XCTAssertEqual(alarms(0xFFF1), [.ReservoirEmpty])
    }
}

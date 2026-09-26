@testable import MedtrumKit
import XCTest

// Swift port of the AndroidAPS `GetRecordPacketTest.kt` by J. Bunt (@jbr7rr):
// pump/medtrum/src/test/kotlin/app/aaps/pump/medtrum/comm/packets/GetRecordPacketTest.kt
// Same captured payloads; asserts on the parsed GetRecordPacketResponse instead of on mocked
// pumpSync calls. Written by Claude (Anthropic), directed and reviewed by @tomacs.
//
//
// NOTE on the trailing byte: MedtrumKit's decode() verifies a Crc8 over the frame, AAPS's
// handleResponse() does not (it only checks length, opcode and response code), so the AAPS
// fixtures carry an arbitrary last byte. It is recomputed here so the frames are valid for
// this implementation; the record payload is untouched, and decode() drops the byte anyway.
// LICENSE: AGPL-3.0, like the AAPS original — not MedtrumKit's MIT license. See the header
// of GetRecordPacket.swift.

final class GetRecordPacketTests: XCTestCase {
    func testGetRequestGivenPacketWhenCalledThenReturnOpCode() throws {
        // AAPS: medtrumPump.patchId = 146, recordIndex = 4 → request [99, 4, 0, 146, 0].
        // Swift's getRequestBytes() omits the opCode byte (encode() prepends it), so the
        // expected payload here is the trailing 4 bytes.
        let packet = GetRecordPacket(recordIndex: 4, patchId: Data([146, 0]))
        XCTAssertEqual(packet.getRequestBytes(), Data([4, 0, 146, 0]))
    }

    func testHandleResponseGivenPacketWhenValuesSetThenReturnCorrectValues() throws {
        let data = Data([35, 99, 9, 1, 0, 0, 170, 28, 2, 255, 251, 216, 229, 238, 14, 0, 192, 1,
                         165, 236, 174, 17, 165, 236, 174, 17, 1, 0, 26, 0, 0, 0, 154, 0, 195])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)
        XCTAssertTrue(packet.hasEnoughData)
    }

    func testHandleResponseGivenResponseWhenMessageTooShortThenResultFalse() throws {
        // Truncated to 17 bytes — less than mimimumDataSize (18).
        let data = Data([35, 99, 9, 1, 0, 0, 170, 28, 2, 255, 251, 216, 229, 238, 14, 0, 182])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.hasEnoughData)
    }

    func testHandleResponseGivenBolusRecordThenExpectNormalBolusParsed() throws {
        // Same captured response as the AAPS "DetailedBolusInfo present" / "absent" tests —
        // they share bytes and only differ in mock setup, which doesn't apply here.
        let data = Data([47, 99, 10, 1, 0, 0, 170, 40, 1, 255, 38, 105, 179, 57, 56, 0, 29, 0,
                         1, 0, 0, 0, 174, 171, 62, 18, 22, 0, 22, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                         0, 0, 0, 0, 0, 0, 0, 0, 58])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)

        let result = packet.parseResponse()
        guard case let .bolus(bolus) = result.record else {
            XCTFail("Expected bolus record, got \(result.record)")
            return
        }
        XCTAssertEqual(bolus.bolusType, .NORMAL)
        XCTAssertFalse(bolus.bolusWizard)
        XCTAssertEqual(bolus.bolusStartTime.timeIntervalSince1970, 1_694_631_470, accuracy: 0.5)
        XCTAssertEqual(bolus.bolusNormalDelivered, 1.1, accuracy: 0.01)
    }

    func testHandleResponseGivenExtendedBolusRecordThenExpectExtendedBolusParsed() throws {
        let data = Data([47, 99, 5, 1, 0, 0, 170, 40, 1, 255, 38, 105, 179, 57, 63, 0, 6, 0,
                         2, 0, 0, 0, 234, 133, 67, 18, 0, 0, 0, 0, 25, 0, 30, 0, 25, 0, 0, 0,
                         0, 0, 0, 0, 0, 0, 0, 0, 242])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)

        let result = packet.parseResponse()
        guard case let .bolus(bolus) = result.record else {
            XCTFail("Expected bolus record, got \(result.record)")
            return
        }
        XCTAssertEqual(bolus.bolusType, .EXTENDED)
        XCTAssertEqual(bolus.bolusStartTime.timeIntervalSince1970, 1_694_949_482, accuracy: 0.5)
        XCTAssertEqual(bolus.bolusExtendedDelivered, 1.25, accuracy: 0.01)
        XCTAssertEqual(bolus.bolusExtendedDuration, 30 * 60, accuracy: 1)
    }

    func testHandleResponseGivenComboBolusRecordThenExpectComboBolusParsed() throws {
        let data = Data([47, 99, 5, 1, 0, 0, 170, 40, 1, 255, 38, 105, 179, 57, 63, 0, 8, 0,
                         3, 0, 0, 0, 111, 146, 67, 18, 40, 0, 40, 0, 20, 0, 30, 0, 20, 0, 0, 0,
                         0, 0, 0, 0, 0, 0, 0, 0, 240])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)

        let result = packet.parseResponse()
        guard case let .bolus(bolus) = result.record else {
            XCTFail("Expected bolus record, got \(result.record)")
            return
        }
        XCTAssertEqual(bolus.bolusType, .COMBI)
        XCTAssertEqual(bolus.bolusStartTime.timeIntervalSince1970, 1_694_952_687, accuracy: 0.5)
        XCTAssertEqual(bolus.bolusNormalDelivered, 2.0, accuracy: 0.01)
        XCTAssertEqual(bolus.bolusExtendedDelivered, 1.0, accuracy: 0.01)
        XCTAssertEqual(bolus.bolusExtendedDuration, 30 * 60, accuracy: 1)
    }

    func testHandleResponseGivenBasalRecordWhenAbsoluteTempThenExpectAbsoluteTempParsed() throws {
        let data = Data([35, 99, 7, 1, 0, 0, 170, 28, 2, 255, 38, 105, 179, 57, 56, 0, 30, 0,
                         171, 171, 62, 18, 222, 172, 62, 18, 6, 0, 69, 0, 6, 0, 69, 0, 144])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)

        let result = packet.parseResponse()
        guard case let .basal(basal) = result.record else {
            XCTFail("Expected basal record, got \(result.record)")
            return
        }
        XCTAssertEqual(basal.basalType, .ABSOLUTE_TEMP)
        XCTAssertEqual(basal.basalStartTime.timeIntervalSince1970, 1_694_631_467, accuracy: 0.5)
        XCTAssertEqual(basal.basalEndTime.timeIntervalSince1970, 1_694_631_774, accuracy: 0.5)
        XCTAssertEqual(basal.basalRate, 3.45, accuracy: 0.01)
    }

    func testHandleResponseGivenBasalRecordWhenRelativeTempThenExpectRelativeTempParsed() throws {
        let data = Data([35, 99, 7, 1, 0, 0, 170, 28, 2, 255, 38, 105, 179, 57, 63, 0, 4, 0,
                         140, 133, 67, 18, 81, 137, 67, 18, 7, 0, 4, 0, 1, 0, 200, 0, 18])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)

        let result = packet.parseResponse()
        guard case let .basal(basal) = result.record else {
            XCTFail("Expected basal record, got \(result.record)")
            return
        }
        XCTAssertEqual(basal.basalType, .RELATIVE_TEMP)
        XCTAssertEqual(basal.basalStartTime.timeIntervalSince1970, 1_694_949_388, accuracy: 0.5)
        XCTAssertEqual(basal.basalEndTime.timeIntervalSince1970, 1_694_950_353, accuracy: 0.5)
        XCTAssertEqual(basal.basalPercent, 200)
    }

    func testHandleResponseGivenBasalRecordWhenSuspendThenExpectSuspendParsed() throws {
        let data = Data([35, 99, 7, 1, 0, 0, 170, 28, 2, 255, 217, 249, 118, 170, 171, 1, 8, 0,
                         252, 116, 240, 17, 21, 125, 240, 17, 18, 0, 0, 0, 0, 0, 0, 0, 229])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)

        let result = packet.parseResponse()
        guard case let .basal(basal) = result.record else {
            XCTFail("Expected basal record, got \(result.record)")
            return
        }
        XCTAssertEqual(basal.basalType, .SUSPEND_MANUAL)
        XCTAssertEqual(basal.basalStartTime.timeIntervalSince1970, 1_689_505_660, accuracy: 0.5)
        XCTAssertEqual(basal.basalEndTime.timeIntervalSince1970, 1_689_507_733, accuracy: 0.5)
        XCTAssertEqual(basal.basalRate, 0.0, accuracy: 0.01)
    }

    func testHandleResponseGivenBasalRecordWhenStandardAndSuspendEndReasonThenIsSuspendedByPump() throws {
        let data = Data([35, 99, 8, 1, 0, 0, 170, 28, 2, 255, 217, 249, 118, 170, 171, 1, 4, 0,
                         139, 113, 240, 17, 9, 116, 240, 17, 1, 4, 10, 0, 2, 0, 0, 0, 42])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)

        let result = packet.parseResponse()
        guard case let .basal(basal) = result.record else {
            XCTFail("Expected basal record, got \(result.record)")
            return
        }
        XCTAssertEqual(basal.basalType, .STANDARD)
        XCTAssertEqual(basal.basalEndReason, .SUSPEND_MORE_THAN_MAX_PER_HOUR)
        XCTAssertTrue(basal.basalEndReason?.isSuspendedByPump() ?? false)
        XCTAssertEqual(basal.basalEndTime.timeIntervalSince1970, 1_689_505_417, accuracy: 0.5)
    }

    func testHandleResponseGivenBasalRecordWhenTempAndSuspendEndReasonThenIsSuspendedByPump() throws {
        let data = Data([35, 99, 8, 1, 0, 0, 170, 28, 2, 255, 217, 249, 118, 170, 174, 1, 5, 0,
                         75, 24, 242, 17, 44, 27, 242, 17, 6, 4, 16, 0, 3, 0, 16, 0, 164])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)

        let result = packet.parseResponse()
        guard case let .basal(basal) = result.record else {
            XCTFail("Expected basal record, got \(result.record)")
            return
        }
        XCTAssertEqual(basal.basalType, .ABSOLUTE_TEMP)
        XCTAssertEqual(basal.basalEndReason, .SUSPEND_MORE_THAN_MAX_PER_HOUR)
        XCTAssertTrue(basal.basalEndReason?.isSuspendedByPump() ?? false)
        XCTAssertEqual(basal.basalEndTime.timeIntervalSince1970, 1_689_613_740, accuracy: 0.5)
    }

    func testHandleResponseGivenTDDRecordThenExpectTddParsed() throws {
        let data = Data([87, 99, 8, 1, 0, 0, 170, 80, 9, 255, 38, 105, 179, 57, 56, 0, 82, 0,
                         224, 132, 61, 18, 120, 0, 136, 5, 0, 0, 0, 0, 154, 153, 84, 66, 0, 0,
                         136, 65, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 102, 230, 128, 66, 58,
                         204, 181, 63, 0, 0, 240, 66, 207, 247, 243, 63, 153, 153, 121, 66, 55,
                         181, 172, 63, 0, 0, 240, 66, 207, 247, 243, 63, 0, 0, 0, 0, 111])
        var packet = GetRecordPacket(recordIndex: 0, patchId: Data([0, 0]))
        packet.decode(data)
        XCTAssertFalse(packet.failed)

        let result = packet.parseResponse()
        guard case let .tdd(tdd) = result.record else {
            XCTFail("Expected TDD record, got \(result.record)")
            return
        }
        XCTAssertEqual(tdd.timestamp.timeIntervalSince1970, 1_694_556_000, accuracy: 0.5)
        XCTAssertEqual(Double(tdd.tdd), 53.15, accuracy: 0.01)
        XCTAssertEqual(Double(tdd.basalTdd), 17.0, accuracy: 0.01)
    }
}

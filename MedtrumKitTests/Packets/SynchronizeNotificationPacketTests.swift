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
}

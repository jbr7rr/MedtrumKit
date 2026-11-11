@testable import MedtrumKit
import LoopKit
import XCTest

/// GET_RECORD parsing (test vectors from AndroidAPS `GetRecordPacketTest`), the record cursor, the fallback for doses
/// whose record never turns up, and the patch-clock rules records are matched by
final class PatchRecordTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_694_631_000)

    // MARK: - Parsing

    /// The AndroidAPS vectors are signed bytes and end in the CRC, which `decode` strips
    private func parse(_ bytes: [Int]) -> GetRecordResponse {
        let packet = GetRecordPacket(recordIndex: 0, patchId: 0)
        packet.totalData = Data(bytes.dropLast().map { UInt8(bitPattern: Int8($0)) })
        return packet.parseResponse()
    }

    private let bolusVector = [
        47, 99, 10, 1, 0, 0, -86, 40, 1, -1, 38, 105, -77, 57, 56, 0, 29, 0, 1, 0, 0, 0, -82, -85, 62, 18, 22, 0, 22, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 76
    ]

    private let absoluteTempVector = [
        35, 99, 7, 1, 0, 0, -86, 28, 2, -1, 38, 105, -77, 57, 56, 0, 30, 0, -85, -85, 62, 18, -34, -84, 62, 18, 6, 0, 69,
        0, 6, 0, 69, 0, -125
    ]

    func testRequestCarriesRecordIndexAndPatchId() {
        let packet = GetRecordPacket(recordIndex: 4, patchId: 146)
        XCTAssertEqual(packet.getRequestBytes(), Data([4, 0, 146, 0]))
    }

    func testBolusRecord() {
        let response = parse(bolusVector)
        XCTAssertEqual(response.sequence, 29)
        XCTAssertEqual(response.patchId, 56)

        guard case let .bolus(record) = response.record else {
            return XCTFail("Expected a bolus record, got \(response.record)")
        }

        XCTAssertEqual(record.type, .NORMAL)
        XCTAssertFalse(record.wizard)
        XCTAssertEqual(record.startTime, Date(timeIntervalSince1970: 1_694_631_470))
        XCTAssertEqual(record.normalAmount, 1.1, accuracy: 0.0001)
        XCTAssertEqual(record.normalDelivered, 1.1, accuracy: 0.0001)
    }

    func testExtendedBolusRecord() {
        let response = parse([
            47, 99, 5, 1, 0, 0, -86, 40, 1, -1, 38, 105, -77, 57, 63, 0, 6, 0, 2, 0, 0, 0, -22, -123, 67, 18, 0, 0, 0, 0,
            25, 0, 30, 0, 25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -124
        ])

        guard case let .bolus(record) = response.record else {
            return XCTFail("Expected a bolus record, got \(response.record)")
        }

        XCTAssertEqual(record.type, .EXTENDED)
        XCTAssertEqual(record.startTime, Date(timeIntervalSince1970: 1_694_949_482))
        XCTAssertEqual(record.extendedAmount, 1.25, accuracy: 0.0001)
        XCTAssertEqual(record.extendedDuration, TimeInterval.minutes(30))
    }

    func testAbsoluteTempBasalRecord() {
        let response = parse(absoluteTempVector)
        XCTAssertEqual(response.sequence, 30)
        XCTAssertEqual(response.patchId, 56)

        guard case let .basal(record) = response.record else {
            return XCTFail("Expected a basal record, got \(response.record)")
        }

        XCTAssertEqual(record.type, .ABSOLUTE_TEMP)
        XCTAssertEqual(record.endReason, .SUCCESS)
        XCTAssertEqual(record.startTime, Date(timeIntervalSince1970: 1_694_631_467))
        XCTAssertEqual(record.endTime, Date(timeIntervalSince1970: 1_694_631_774))
        XCTAssertEqual(record.duration, 307)
        XCTAssertEqual(record.rate, 3.45, accuracy: 0.0001)
        XCTAssertEqual(record.delivered, 0.3, accuracy: 0.0001)
        XCTAssertEqual(record.percent, 69)
    }

    func testRelativeTempBasalRecord() {
        let response = parse([
            35, 99, 7, 1, 0, 0, -86, 28, 2, -1, 38, 105, -77, 57, 63, 0, 4, 0, -116, -123, 67, 18, 81, -119, 67, 18, 7, 0,
            4, 0, 1, 0, -56, 0, 1
        ])
        XCTAssertEqual(response.sequence, 4)

        guard case let .basal(record) = response.record else {
            return XCTFail("Expected a basal record, got \(response.record)")
        }

        XCTAssertEqual(record.type, .RELATIVE_TEMP)
        XCTAssertEqual(record.startTime, Date(timeIntervalSince1970: 1_694_949_388))
        XCTAssertEqual(record.endTime, Date(timeIntervalSince1970: 1_694_950_353))
        XCTAssertEqual(record.rate, 0.2, accuracy: 0.0001)
        XCTAssertEqual(record.delivered, 0.05, accuracy: 0.0001)
        XCTAssertEqual(record.percent, 200)
    }

    func testStandardBasalRecordEndedBySuspend() {
        let response = parse([
            35, 99, 8, 1, 0, 0, -86, 28, 2, -1, -39, -7, 118, -86, -85, 1, 8, 0, -117, 113, -16, 17, 9, 116, -16, 17, 1,
            4, 10, 0, 2, 0, 0, 0, 57
        ])
        XCTAssertEqual(response.sequence, 8)
        XCTAssertEqual(response.patchId, 427)

        guard case let .basal(record) = response.record else {
            return XCTFail("Expected a basal record, got \(response.record)")
        }

        XCTAssertEqual(record.type, .STANDARD)
        XCTAssertEqual(record.endReason, .SUSPEND_MORE_THAN_MAX_PER_HOUR)
        XCTAssertEqual(record.endReason?.isSuspendedByPump(), true)
        XCTAssertEqual(record.startTime, Date(timeIntervalSince1970: 1_689_504_779))
        XCTAssertEqual(record.endTime, Date(timeIntervalSince1970: 1_689_505_417))
    }

    func testTddRecord() {
        let response = parse([
            87, 99, 8, 1, 0, 0, -86, 80, 9, -1, 38, 105, -77, 57, 56, 0, 82, 0, -32, -124, 61, 18, 120, 0, -120, 5, 0, 0,
            0, 0, -102, -103, 84, 66, 0, 0, -120, 65, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 102, -26, -128, 66, 58, -52, -75,
            63, 0, 0, -16, 66, -49, -9, -13, 63, -103, -103, 121, 66, 55, -75, -84, 63, 0, 0, -16, 66, -49, -9, -13, 63, 0,
            0, 0, 0, -128
        ])
        XCTAssertEqual(response.sequence, 82)

        guard case let .tdd(record) = response.record else {
            return XCTFail("Expected a TDD record, got \(response.record)")
        }

        XCTAssertEqual(record.timestamp, Date(timeIntervalSince1970: 1_694_556_000))
        XCTAssertEqual(record.timeZoneOffset, 120)
        XCTAssertEqual(record.minutes, 1416)
        XCTAssertEqual(record.total, 53.15, accuracy: 0.001)
        XCTAssertEqual(record.basal, 17.0, accuracy: 0.001)
        XCTAssertEqual(record.bolus, 36.15, accuracy: 0.001)
    }

    func testResponseTooShortForTheHeader() {
        let packet = GetRecordPacket(recordIndex: 0, patchId: 0)
        packet.totalData = Data([35, 99, 9, 1, 0, 0, 170, 28, 2, 255, 251, 216, 229, 238, 14, 0, 192])
        XCTAssertFalse(packet.hasEnoughData)
    }

    func testRecordTooShortForItsType() {
        // the header of the absolute temp basal, and 10 of its 16 payload bytes
        let packet = GetRecordPacket(recordIndex: 0, patchId: 0)
        packet.totalData = Data(absoluteTempVector.prefix(28).map { UInt8(bitPattern: Int8($0)) })

        guard case let .truncated(type, size) = packet.parseResponse().record else {
            return XCTFail("Expected a truncated record")
        }
        XCTAssertEqual(type, 2)
        XCTAssertEqual(size, 28)
    }

    func testInvalidRecordHeader() {
        var bytes = absoluteTempVector
        bytes[6] = 0

        guard case .invalid = parse(bytes).record else {
            return XCTFail("Expected an invalid record")
        }
    }

    // MARK: - Cursor

    func testCursorFollowsALaterRecordNumberWithinRange() {
        XCTAssertEqual(RecordSyncer.cursorAfterReading(reported: 30, requested: 30, current: 40), 30)
        XCTAssertEqual(RecordSyncer.cursorAfterReading(reported: 35, requested: 31, current: 40), 35)
        XCTAssertEqual(RecordSyncer.cursorAfterReading(reported: 40, requested: 31, current: 40), 40)
        XCTAssertEqual(RecordSyncer.cursorAfterReading(reported: 65535, requested: 31, current: 40), 31)
        XCTAssertEqual(RecordSyncer.cursorAfterReading(reported: 0, requested: 5, current: 10), 5)
    }

    func testStaleRecordNumberDoesNotHoldTheCursorBack() {
        // record 30 answered with what is still in its slot - an older record - must not be asked for forever
        XCTAssertEqual(RecordSyncer.cursorAfterReading(reported: 29, requested: 30, current: 40), 30)
        XCTAssertEqual(RecordSyncer.cursorAfterReading(reported: 3, requested: 30, current: 40), 30)
    }

    // MARK: - Empty-reservoir end

    private func tempBasalRecord(
        type: BasalType = .ABSOLUTE_TEMP,
        endReason: BasalEndReason = .STOP_EMPTY,
        minutes: Double,
        rate: Double,
        delivered: Double
    ) -> PumpRecord {
        .basal(BasalRecord(
            type: type,
            endReason: endReason,
            rawEndReason: endReason.rawValue,
            startTime: t0,
            endTime: t0.addingTimeInterval(.minutes(minutes)),
            rate: rate,
            delivered: delivered,
            percent: 0
        ))
    }

    /// The dry-outs' records: 11-03 #2043 and 10-30 #1704 claim a step or more over rate × duration, 10-26 #1641 only
    /// its rounding
    func testEmptyStopOvercountIsToldOfOnlyAStepOrMoreOverRateTimesDuration() throws {
        let overcount = try XCTUnwrap(RecordSyncer.emptyStopOvercount(of: tempBasalRecord(minutes: 1.5, rate: 0.35, delivered: 0.1)))
        XCTAssertTrue(overcount.contains("claiming 0.10U"), overcount)
        XCTAssertTrue(overcount.contains("0.35U/h × 1.5min = 0.009U"), overcount)

        XCTAssertNotNil(RecordSyncer.emptyStopOvercount(of: tempBasalRecord(minutes: 1.4, rate: 5.7, delivered: 0.2)))
        XCTAssertNil(RecordSyncer.emptyStopOvercount(of: tempBasalRecord(minutes: 3.2, rate: 4.6, delivered: 0.25)))
        XCTAssertNil(RecordSyncer.emptyStopOvercount(of: tempBasalRecord(minutes: 2, rate: 0, delivered: 0)))
    }

    func testEmptyStopOvercountIsNotToldOfForOtherEndsOrScheduledBasal() {
        XCTAssertNil(RecordSyncer.emptyStopOvercount(of: tempBasalRecord(endReason: .SUCCESS, minutes: 1.5, rate: 0.35, delivered: 0.1)))
        XCTAssertNil(RecordSyncer.emptyStopOvercount(of: tempBasalRecord(type: .STANDARD, minutes: 1.5, rate: 0.35, delivered: 0.1)))
    }

    // MARK: - Fallback

    func testFallbackIsDueCaughtUpAfter15MinutesOrAfter60MinutesAnyway() {
        let ended = Date(timeIntervalSince1970: 1_694_631_000)

        XCTAssertNil(RecordSyncer.fallbackRule(since: ended, caughtUp: true, now: ended.addingTimeInterval(14 * 60)))
        XCTAssertEqual(RecordSyncer.fallbackRule(since: ended, caughtUp: true, now: ended.addingTimeInterval(15 * 60)), .noRecord)
        XCTAssertNil(RecordSyncer.fallbackRule(since: ended, caughtUp: false, now: ended.addingTimeInterval(59 * 60)))
        XCTAssertEqual(RecordSyncer.fallbackRule(since: ended, caughtUp: false, now: ended.addingTimeInterval(60 * 60)), .maximumWait)
        XCTAssertEqual(RecordSyncer.fallbackRule(since: ended, caughtUp: true, now: ended.addingTimeInterval(60 * 60)), .noRecord)
    }

    // MARK: - Patch clock

    func testPatchLocalMidnightIsCrossedOnlyStrictlyInside() {
        // 2026-08-02 00:00:00 at UTC+2, on the patch clock
        let midnight = Date.fromMedtrumSeconds(397_087_200)
        let offset: TimeInterval = 2 * 3600

        XCTAssertTrue(MedtrumPumpManager.crossesPatchMidnight(
            from: midnight.addingTimeInterval(-435), to: midnight.addingTimeInterval(462), utcOffset: offset
        ))
        XCTAssertFalse(MedtrumPumpManager.crossesPatchMidnight(
            from: midnight.addingTimeInterval(-435), to: midnight, utcOffset: offset
        ), "ending at midnight is one record")
        XCTAssertFalse(MedtrumPumpManager.crossesPatchMidnight(
            from: midnight, to: midnight.addingTimeInterval(3600), utcOffset: offset
        ))
        // The same moment is not midnight in another zone
        XCTAssertFalse(MedtrumPumpManager.crossesPatchMidnight(
            from: midnight.addingTimeInterval(-435), to: midnight.addingTimeInterval(462), utcOffset: 0
        ))
    }

    func testTheSetAnswerIsOursOnlyAtOurRateAsAnAbsoluteTempBasal() {
        let packet = SetTempBasalPacket(rate: 0.6, duration: 1800)
        packet.totalData = Data(hex: "121860000000060c00b103ec002d10ab1701")!
        let response = packet.parseResponse()

        XCTAssertTrue(RecordSyncer.isCommandedTempBasal(response, rate: 0.6))
        XCTAssertFalse(RecordSyncer.isCommandedTempBasal(response, rate: 0.65))
    }

    func testSetBolusAnswerNamesTheRecordAndThePatchStart() {
        let packet = SetBolusPacket(bolusAmount: 0.05)
        packet.totalData = Data(hex: "0f1343000000a903ec00f907ab17b3")!
        let response = packet.parseResponse()

        XCTAssertEqual(response.recordSequence, 937)
        XCTAssertEqual(response.patchId, 236)
        XCTAssertEqual(response.startTime, Date.fromMedtrumSeconds(397_084_665))

        // A short answer is still an answer: the bolus is not failed over what it says of its record
        let short = SetBolusPacket(bolusAmount: 0.05)
        short.totalData = Data(hex: "0713430000001c")!
        XCTAssertNil(short.parseResponse().recordSequence)
        XCTAssertTrue(short.hasEnoughData)
    }

    func testResumeAnswerCarriesTheSegmentItResumedWith() {
        let packet = ResumePumpPacket()
        packet.totalData = Data(hex: "121d06000000010c000302ed004196ac17c0")!
        let response = packet.parseResponse()

        XCTAssertEqual(response.basalType, .STANDARD)
        XCTAssertEqual(response.basalSequence, 515)
        XCTAssertEqual(response.basalStartTime, Date.fromMedtrumSeconds(397_186_625))
    }

    func testBuiltRecordsParseAsTheLoggedOnes() {
        let built = PatchBytes.bolusRecord(
            sequence: 937, patchId: 236, start: Date.fromMedtrumSeconds(397_084_665), amount: 0.05, delivered: 0.05
        )
        let result = FakeMedtrumLink.result(
            of: GetRecordPacket(recordIndex: 937, patchId: 236),
            decoding: built.map(FakeMedtrumLink.bytes)
        )
        guard case let .success(data) = result, let response = data as? GetRecordResponse,
              case let .bolus(record) = response.record
        else {
            return XCTFail("Built bolus record does not parse: \(result)")
        }
        XCTAssertEqual(response.sequence, 937)
        XCTAssertEqual(response.patchId, 236)
        XCTAssertEqual(record.startTime, Date.fromMedtrumSeconds(397_084_665))
        XCTAssertEqual(record.normalAmount, 0.05, accuracy: 0.0001)
        XCTAssertEqual(record.normalDelivered, 0.05, accuracy: 0.0001)

        let basal = PatchBytes.basalRecord(
            sequence: 944,
            patchId: 236,
            type: .ABSOLUTE_TEMP,
            start: Date.fromMedtrumSeconds(397_086_472),
            end: Date.fromMedtrumSeconds(397_086_763),
            rate: 0.85,
            delivered: 0.1
        )
        let basalResult = FakeMedtrumLink.result(
            of: GetRecordPacket(recordIndex: 944, patchId: 236),
            decoding: basal.map(FakeMedtrumLink.bytes)
        )
        guard case let .success(basalData) = basalResult, let basalResponse = basalData as? GetRecordResponse,
              case let .basal(basalRecord) = basalResponse.record
        else {
            return XCTFail("Built basal record does not parse: \(basalResult)")
        }
        XCTAssertEqual(basalRecord.type, .ABSOLUTE_TEMP)
        XCTAssertEqual(basalRecord.duration, 291)
        XCTAssertEqual(basalRecord.rate, 0.85, accuracy: 0.0001)
        XCTAssertEqual(basalRecord.delivered, 0.1, accuracy: 0.0001)
    }
}

//
//  SetTimeZonePacketTests.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 11/03/2025.
//

@testable import MedtrumKit
import XCTest

final class SetTimeZonePacketTests : XCTestCase {
    func testRequestGivenPacketWhenValuesSetThenReturnCorrectByteArray() throws {
        let input = SetTimeZonePacket(date: Date(timeIntervalSince1970: 1741721000), timeZone: TimeZone.init(abbreviation: "CET")!)
        
        let expected = Data([11, 12, 0, 0, 60, 0, 40, 51, 13, 21, 110, 0])
        
        let sequence: UInt8 = 0
        let actual = input.encode(sequenceNumber: sequence)
        
        XCTAssertEqual(actual.count, 1)
        XCTAssertEqual(actual[0], expected)
    }
}

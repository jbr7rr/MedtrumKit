//
//  SetTimePacketTests.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 11/03/2025.
//

@testable import MedtrumKit
import XCTest

final class SetTimePacketTests : XCTestCase {
    func testRequestGivenPacketWhenValuesSetThenReturnCorrectByteArray() throws {
        let input = SetTimePacket(date: Date(timeIntervalSince1970: 1741721000))
        
        let expected = Data([10, 10, 0, 0, 2, 40, 51, 13, 21, 26, 0])
        
        let sequence: UInt8 = 0
        let actual = input.encode(sequenceNumber: sequence)
        
        XCTAssertEqual(actual.count, 1)
        XCTAssertEqual(actual[0], expected)
    }
}

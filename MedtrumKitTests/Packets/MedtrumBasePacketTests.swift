//
//  WritePacketTests.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 01/03/2025.
//

@testable import MedtrumKit
import XCTest

final class MedtrumBasePacketTests : XCTestCase {
    func testWriteAuthorizeCommandExpectOnePacket() throws {
        let input = AuthorizePacket(pumpSN: Data([217, 249, 118, 170]), sessionToken: Data([0, 0, 0, 0]))
        let expected = Data([14, 5, 0, 0, 2, 0, 0, 0, 0, 235, 57, 134, 200, 163, 0])
        
        let sequence: UInt8 = 0
        let actual = input.encode(sequenceNumber: sequence)
        
        XCTAssertEqual(actual.count, 1)
        XCTAssertEqual(actual[0], expected)
    }
}

import LoopKit
@testable import MedtrumKit
import XCTest

final class BasalScheduleTests: XCTestCase {
    func testScheduleToData() throws {
        // Basal profile with 7 elements:
        // 00:00 : 2.1
        // 04:00 : 1.9
        // 06:00 : 1.7
        // 08:00 : 1.5
        // 16:00 : 1.6
        // 21:00 : 1.7
        // 23:00 : 2
        let input: [LoopKit.RepeatingScheduleValue<Double>] = [
            LoopKit.RepeatingScheduleValue(startTime: .hours(0), value: 2.1),
            LoopKit.RepeatingScheduleValue(startTime: .hours(4), value: 1.9),
            LoopKit.RepeatingScheduleValue(startTime: .hours(6), value: 1.7),
            LoopKit.RepeatingScheduleValue(startTime: .hours(8), value: 1.5),
            LoopKit.RepeatingScheduleValue(startTime: .hours(16), value: 1.6),
            LoopKit.RepeatingScheduleValue(startTime: .hours(21), value: 1.7),
            LoopKit.RepeatingScheduleValue(startTime: .hours(23), value: 2)
        ]

        let schedule = BasalSchedule(entries: input)
        let actual = schedule.toData()

        let expected = Data([7, 0, 160, 2, 240, 96, 2, 104, 33, 2, 224, 225, 1, 192, 3, 2, 236, 36, 2, 100, 133, 2])
        print(expected.hexEncodedString())
        print(actual.hexEncodedString())
        XCTAssert(actual.elementsEqual(expected))
    }
}

final class SessionTokenPolicyTests: XCTestCase {
    // Genuinely terminal (must-replace) states back up + clear the token.
    func testTerminalStatesAreTerminal() {
        XCTAssertTrue(SessionTokenPolicy.isTerminal(.occlusion))
        XCTAssertTrue(SessionTokenPolicy.isTerminal(.expired))
        XCTAssertTrue(SessionTokenPolicy.isTerminal(.reservoirEmpty))
        XCTAssertTrue(SessionTokenPolicy.isTerminal(.patchFault))
        XCTAssertTrue(SessionTokenPolicy.isTerminal(.patchFaultd2))
        XCTAssertTrue(SessionTokenPolicy.isTerminal(.baseFault))
        XCTAssertTrue(SessionTokenPolicy.isTerminal(.batteryOut))
        XCTAssertTrue(SessionTokenPolicy.isTerminal(.stopped))
    }

    // Active and the recoverable suspend/paused states are NOT terminal and MUST
    // keep their token - they are >32 but below `occlusion`.
    func testActiveAndSuspendStatesAreNotTerminal() {
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.active))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.active_alt))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.lowBgSuspended))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.autoSuspended))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.hourlyMaxSuspended))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.dailyMaxSuspended))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.suspended))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.paused))
    }

    // Transient activation/needle states (ejecting/ejected) and pre-active states
    // are NOT terminal - clearing the token here was the regression that wiped a
    // live patch's token mid-activation.
    func testTransientAndPreActiveStatesAreNotTerminal() {
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.none))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.idle))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.filled))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.priming))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.primed))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.ejecting))
        XCTAssertFalse(SessionTokenPolicy.isTerminal(.ejected))
    }
}

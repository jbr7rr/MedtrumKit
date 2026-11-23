import LoopKit
@testable import MedtrumKit
import XCTest

private final class FakeBluetoothManager: BluetoothManager {
    var pendingConnects: [(MedtrumConnectError?) -> Void] = []
    var writeResults: [MedtrumWriteResult<Any>] = []
    var writes = 0

    override func ensureConnected(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        DispatchQueue.main.async { self.pendingConnects.append(completion) }
    }

    override func write(_: any MedtrumBasePacketProtocol) -> MedtrumWriteResult<Any> {
        writes += 1
        return writeResults.isEmpty ? .success(data: ()) : writeResults.removeFirst()
    }
}

final class EnactBolusTests: XCTestCase {
    private var pumpManager: MedtrumPumpManager!
    private var bluetooth: FakeBluetoothManager!

    override func setUp() {
        let state = MedtrumPumpState(nil)
        state.pumpState = .active
        state.patchSessionEnded = false
        bluetooth = FakeBluetoothManager(knownPeripheralIdentifier: nil, restoresState: false)
        pumpManager = MedtrumPumpManager(state: state, bluetooth: bluetooth)
    }

    private func waitForConnects(_ count: Int) {
        let predicate = NSPredicate { _, _ in self.bluetooth.pendingConnects.count == count }
        wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 2)
    }

    // tomacs, jbr7rr/MedtrumKit#216: a remote bolus and an SMB in the same second
    func testSecondBolusWhileFirstIsBeingSentIsRejectedAndFirstIsKept() {
        let first = expectation(description: "first bolus")
        pumpManager.enactBolus(units: 2.8, activationType: .manualNoRecommendation) { error in
            XCTAssertNil(error)
            first.fulfill()
        }

        let second = expectation(description: "second bolus")
        pumpManager.enactBolus(units: 0.3, activationType: .automatic) { error in
            guard case let .deviceState(deviceError)? = error,
                  case .isBolussing? = deviceError as? MedtrumConnectError
            else {
                return XCTFail("Expected isBolussing, got \(String(describing: error))")
            }
            second.fulfill()
        }
        wait(for: [second], timeout: 1)

        waitForConnects(1)
        DispatchQueue.global().async { self.bluetooth.pendingConnects[0](nil) }
        wait(for: [first], timeout: 2)

        XCTAssertEqual(bluetooth.writes, 1)
        XCTAssertEqual(pumpManager.state.bolusDose?.value, 2.8)
        XCTAssertEqual(pumpManager.state.bolusState, .inProgress)
    }

    func testFailedBolusReleasesTheClaimWithoutRecordingADose() {
        bluetooth.writeResults = [.failure(error: .invalidResponse(code: 8))]
        let failed = expectation(description: "failed bolus")
        pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }
        waitForConnects(1)
        DispatchQueue.global().async { self.bluetooth.pendingConnects[0](nil) }
        wait(for: [failed], timeout: 2)
        XCTAssertNil(pumpManager.state.bolusDose)

        let retried = expectation(description: "retried bolus")
        pumpManager.enactBolus(units: 1, activationType: .manualNoRecommendation) { error in
            XCTAssertNil(error)
            retried.fulfill()
        }
        waitForConnects(2)
        DispatchQueue.global().async { self.bluetooth.pendingConnects[1](nil) }
        wait(for: [retried], timeout: 2)
        XCTAssertEqual(pumpManager.state.bolusDose?.value, 1)
    }
}

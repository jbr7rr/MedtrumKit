import LoopKit
@testable import MedtrumKit
import XCTest

private final class RecordingBluetoothManager: BluetoothManager {
    private let lock = NSLock()
    private var recorded: [any MedtrumBasePacketProtocol] = []

    var packets: [any MedtrumBasePacketProtocol] {
        lock.withLock { recorded }
    }

    override func ensureConnected(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        completion(nil)
    }

    override func write(_ packet: any MedtrumBasePacketProtocol, timeout _: TimeInterval?) -> MedtrumWriteResult<Any> {
        lock.withLock { recorded.append(packet) }
        // A temp basal is running only once its answer names the segment set - else it is kept unconfirmed, the command
        // failing as uncertain: answered as the patch does, with the steps it was sent
        if let packet = packet as? SetTempBasalPacket {
            let bytes = packet.getRequestBytes()
            let steps = Int(bytes[bytes.startIndex + 1]) | Int(bytes[bytes.startIndex + 2]) << 8
            return .success(data: SetTempBasalResponse(
                basalType: .ABSOLUTE_TEMP,
                basalValue: Double(steps) * 0.05,
                basalSequence: 0,
                basalPatchId: 0,
                basalStartTime: Date.now
            ))
        }
        return .success(data: ())
    }
}

final class EnactDoseFloorTests: XCTestCase {
    private var pumpManager: MedtrumPumpManager!
    private var bluetooth: RecordingBluetoothManager!
    private var delegate: FakePumpManagerDelegate!

    override func setUp() {
        RecordSyncer.resetForTesting()
        let state = MedtrumPumpState(nil)
        state.pumpState = .active
        state.patchSessionEnded = false
        state.basalState = .active
        bluetooth = RecordingBluetoothManager(knownPeripheralIdentifier: nil, restoresState: false)
        pumpManager = MedtrumPumpManager(state: state, bluetooth: bluetooth)
        // A dose is not written unless the host took the state with it pending (`handOverPendingDose`): a host to take it
        delegate = FakePumpManagerDelegate()
        pumpManager.delegateQueue = delegate.queue
        pumpManager.pumpManagerDelegate = delegate
    }

    override func tearDown() {
        // Nothing it queued reaches the record sync of the next test
        pumpManager?.stopBackgroundReads()
        pumpManager = nil
        bluetooth = nil
        delegate = nil
    }

    private func step(_ data: Data, at index: Int) -> Int {
        Int(data[data.startIndex + index]) | Int(data[data.startIndex + index + 1]) << 8
    }

    private func enactTempBasal(_ unitsPerHour: Double) {
        let done = expectation(description: "temp basal")
        pumpManager.enactTempBasal(unitsPerHour: unitsPerHour, for: .minutes(30)) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    private func enactBolus(_ units: Double) {
        let done = expectation(description: "bolus")
        pumpManager.enactBolus(units: units, activationType: .manualNoRecommendation) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    private func assertTempBasal(_ unitsPerHour: Double, step expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        enactTempBasal(unitsPerHour)

        let packets = bluetooth.packets
        XCTAssertEqual(packets.count, 1, file: file, line: line)
        guard let packet = packets.first as? SetTempBasalPacket else {
            return XCTFail("Expected SetTempBasalPacket, got \(packets)", file: file, line: line)
        }
        XCTAssertEqual(step(packet.getRequestBytes(), at: 1), expected, file: file, line: line)
        XCTAssertEqual(packet.rate, Double(expected) / 20, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(pumpManager.state.basalDose.type, .tempBasal, file: file, line: line)
        XCTAssertEqual(pumpManager.state.basalDose.value, Double(expected) / 20, accuracy: 1e-9, file: file, line: line)
    }

    private func assertBolus(_ units: Double, step expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        enactBolus(units)

        let packets = bluetooth.packets
        XCTAssertEqual(packets.count, 1, file: file, line: line)
        guard let packet = packets.first as? SetBolusPacket else {
            return XCTFail("Expected SetBolusPacket, got \(packets)", file: file, line: line)
        }
        XCTAssertEqual(step(packet.getRequestBytes(), at: 1), expected, file: file, line: line)
        XCTAssertEqual(packet.bolusAmount, Double(expected) / 20, accuracy: 1e-9, file: file, line: line)
        guard let dose = pumpManager.state.bolusDose else {
            return XCTFail("Expected a bolus dose", file: file, line: line)
        }
        XCTAssertEqual(dose.value, Double(expected) / 20, accuracy: 1e-9, file: file, line: line)
    }

    func testTempBasalBelowFirstStepFloorsToOneStep() {
        assertTempBasal(0.08, step: 1)
    }

    func testTempBasalOffTableFloorsTo22Steps() {
        assertTempBasal(1.13, step: 22)
    }

    func testTempBasalOffTableFloorsTo23Steps() {
        assertTempBasal(1.18, step: 23)
    }

    func testTempBasalOnTableIsUnchanged() {
        assertTempBasal(1.25, step: 25)
    }

    func testBolusOffTableFloorsToOneStep() {
        assertBolus(0.09, step: 1)
    }

    func testBolusOffTableFloorsToTwoSteps() {
        assertBolus(0.14, step: 2)
    }

    func testBolusOnTableIsUnchanged() {
        assertBolus(1.0, step: 20)
    }

    func testBolusBelowMinimumFailsWithoutWrite() {
        let done = expectation(description: "bolus")
        pumpManager.enactBolus(units: 0.03, activationType: .manualNoRecommendation) { error in
            guard case let .deviceState(deviceError)? = error,
                  case .isBelowMinimumBolus? = deviceError as? MedtrumConnectError
            else {
                XCTFail("Expected isBelowMinimumBolus, got \(String(describing: error))")
                return done.fulfill()
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(bluetooth.packets.count, 0)
        XCTAssertNil(pumpManager.state.bolusDose)
    }

    func testEveryBasalTableEntryMapsToItself() {
        for (index, rate) in MedtrumPumpManager.onboardingSupportedBasalRates.enumerated() {
            XCTAssertEqual(pumpManager.roundToSupportedBasalRate(unitsPerHour: rate), rate, "rate \(rate)")
            let packet = SetTempBasalPacket(rate: rate, duration: .minutes(30))
            XCTAssertEqual(step(packet.getRequestBytes(), at: 1), index, "rate \(rate)")
        }
    }
}

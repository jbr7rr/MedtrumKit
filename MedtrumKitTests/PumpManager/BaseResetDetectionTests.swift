@testable import MedtrumKit
import XCTest

final class BaseResetDetectionTests: XCTestCase {
    private func makeState(pumpState: PatchState, patchId: UInt64 = 256) -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.pumpState = pumpState
        state.patchId = patchId.toData(length: 4)
        return state
    }

    private func makeResponse(
        state: PatchState,
        patchId: Double? = nil,
        patchAge: UInt64? = nil
    ) -> SynchronizePacketResponse {
        var response = SynchronizePacketResponse(state: state, activeAlarms: [])
        response.storage = patchId.map { StorageData(sequence: 0, patchId: $0) }
        response.patchAge = patchAge
        return response
    }

    func testActivePatchStayingActiveIsNotAReset() {
        let check = StateSyncer.baseResetCheck(
            syncResponse: makeResponse(state: .active, patchId: 256),
            state: makeState(pumpState: .active)
        )
        XCTAssertEqual(check, .noReset)
    }

    func testActivePatchGettingSuspendedOrFaultedIsNotAReset() {
        for newState in [PatchState.suspended, .hourlyMaxSuspended, .occlusion, .stopped] {
            let check = StateSyncer.baseResetCheck(
                syncResponse: makeResponse(state: newState),
                state: makeState(pumpState: .active)
            )
            XCTAssertEqual(check, .noReset)
        }
    }

    func testSetupOfANewPatchIsNotAReset() {
        for newState in [PatchState.none, .idle, .filled, .priming, .primed] {
            let check = StateSyncer.baseResetCheck(
                syncResponse: makeResponse(state: newState, patchId: 257),
                state: makeState(pumpState: .none, patchId: 0)
            )
            XCTAssertEqual(check, .noReset)
        }
    }

    // The first thing the rebooted base said on 2026-09-19: state none, next patch id, age of 1s
    func testNoneWithNewPatchIdIsAReset() {
        let check = StateSyncer.baseResetCheck(
            syncResponse: makeResponse(state: .none, patchId: 257, patchAge: 1),
            state: makeState(pumpState: .active)
        )
        XCTAssertEqual(check, .reset)
    }

    func testActivatedPatchGoingBackToSetupIsAReset() {
        for oldState in [PatchState.active, .suspended, .lowBgSuspended, .occlusion] {
            for newState in [PatchState.idle, .filled, .priming, .primed] {
                let check = StateSyncer.baseResetCheck(
                    syncResponse: makeResponse(state: newState),
                    state: makeState(pumpState: oldState)
                )
                XCTAssertEqual(check, .reset)
            }
        }
    }

    // `.none` is also what an unknown state byte parses to
    func testNoneWithoutANewPatchIdIsUnconfirmed() {
        let active = makeState(pumpState: .active)

        XCTAssertEqual(StateSyncer.baseResetCheck(syncResponse: makeResponse(state: .none), state: active), .unconfirmed)
        XCTAssertEqual(
            StateSyncer.baseResetCheck(syncResponse: makeResponse(state: .none, patchId: 256), state: active),
            .unconfirmed
        )
    }

    func testDeliveryStoppedWhenTheBaseBooted() {
        let now = Date.now
        let state = makeState(pumpState: .active)
        state.lastSync = now.addingTimeInterval(-3 * 3600)

        let stoppedAt = StateSyncer.deliveryStoppedAt(
            syncResponse: makeResponse(state: .idle, patchId: 257, patchAge: 3600),
            state: state,
            receivedAt: now
        )
        XCTAssertEqual(stoppedAt, now.addingTimeInterval(-3600))
    }

    func testDeliveryDidNotStopBeforeTheLastSync() {
        let now = Date.now
        let state = makeState(pumpState: .active)
        state.lastSync = now.addingTimeInterval(-60)

        let stoppedAt = StateSyncer.deliveryStoppedAt(
            syncResponse: makeResponse(state: .idle, patchId: 257, patchAge: 3600),
            state: state,
            receivedAt: now
        )
        XCTAssertEqual(stoppedAt, state.lastSync)
    }

    func testDeliveryStoppedNowWithoutAPatchAge() {
        let now = Date.now
        let stoppedAt = StateSyncer.deliveryStoppedAt(
            syncResponse: makeResponse(state: .idle),
            state: makeState(pumpState: .active),
            receivedAt: now
        )
        XCTAssertEqual(stoppedAt, now)
    }
}

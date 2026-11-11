@testable import MedtrumKit
import XCTest

/// At a patch change the record history keeps exactly two files: the new patch's and the one before it
/// (`MedtrumPumpManager.pruneRecordHistory`)
extension ManagerPatchChangeScenarioTests {
    private func keepRecords(of patches: [UInt64], in history: PatchRecordHistory) {
        for patch in patches {
            history.append(alarmRecordResponse(sequence: 1, patchId: patch), patchId: patch, outcome: nil)
        }
        history.flush()
    }

    /// Deactivated: its file stays, the previous patch's now, the ones before go. The next one activated: its file and
    /// that one's, nothing else.
    func testAPatchChangeKeepsTheFilesOfTheNewPatchAndTheOneBefore() {
        let history = keepRecordHistory()
        keepRecords(of: [268, 269, Self.oldPatchId], in: history)
        makeManager(activePatchState(patchId: Self.oldPatchId, scheduledRate: Self.scheduledRate, sequence: 10, reservoir: 50))
        XCTAssertEqual(pumpManager.recordHistoryPatches(), [Self.oldPatchId])

        XCTAssertEqual(deactivate(), true)
        XCTAssertEqual(history.patchesWithFiles(), [Self.oldPatchId])
        XCTAssertEqual(pumpManager.recordHistoryPatches(), [Self.oldPatchId], "the previous patch's")

        // A file left behind - say one a delete failed for
        keepRecords(of: [269], in: history)
        XCTAssertEqual(activate(), true)
        keepRecords(of: [Self.newPatchId], in: history)

        XCTAssertEqual(history.patchesWithFiles(), [Self.newPatchId, Self.oldPatchId])
        XCTAssertEqual(pumpManager.recordHistoryPatches(), [Self.newPatchId, Self.oldPatchId])
    }

    /// A running patch of another id heard from after the session ended - its records taken up by the status: the
    /// previous patch's file stays, the ones before go
    func testANewPatchSeenAfterTheSessionEndedKeepsThePreviousPatchsFile() {
        let history = keepRecordHistory()
        keepRecords(of: [268, 269, Self.oldPatchId], in: history)
        makeManager(endedSessionState())

        link.notify(Self.notification(state: .primed, primeProgress: 240))
        settle()
        link.notify(Self.notification(
            state: .active,
            basal: (type: .STANDARD, start: Self.patchSecond(Date.now), patchId: Self.newPatchId),
            activatedAt: Self.patchSecond(Date.now.addingTimeInterval(-Self.minute)),
            storage: (sequence: 1, patchId: Self.newPatchId)
        ))
        settle()

        XCTAssertEqual(pumpManager.state.patchId, Self.newPatchId.toData(length: 4))
        XCTAssertEqual(history.patchesWithFiles(), [Self.oldPatchId])
    }
}

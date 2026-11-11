import LoopKit
@testable import MedtrumKit
import XCTest

/// A full status sync driven through the manager, pinning down what the driver does today (b557739).
/// Bytes are from the user's MedtrumKit logs, cited by the line in the merged analysis log `user.txt`.
final class ManagerStatusSyncScenarioTests: MedtrumManagerTestCase {
    /// 2026-08-02 02:36:36 - 02:36:54 (`user.txt:25821-25852`), patch 237, while 2.1 U/h runs: the
    /// session's periodic full sync, as `PeripheralManager.considerFullSync` runs it - the Synchronize
    /// answer, the patch time (stale), then the records the patch has written so far.
    ///
    /// `syncPumpData` would be the manager's own way in, but in the simulator it never touches the link
    /// (`#if targetEnvironment(simulator)`), so this drives the steps `considerFullSync` takes instead.
    func testFullStatusSyncThenRecords() {
        let state = activePatchState(patchId: 237, scheduledRate: 0.6, sequence: 2, reservoir: 184.65)
        state.syncedSequenceNumber = 0
        // Taken up with the two written before it: the bolus of record 3 after them is no dose of this state's - the user
        // is told to add it
        state.sessionStartSequence = 2
        state.pumpTimeSyncedAt = Date.now.addingTimeInterval(-Self.hour)
        let tempBasal = runningTempBasal(rate: 2.1, startedAgo: 4 * Self.minute, duration: 30 * Self.minute)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        makeManager(state)

        link.script(CommandType.GET_TIME, fragments: "0d0b110000008b36ab1778002a00")
        // 1: time sync (not decoded), 2: the scheduled basal before the temp basal, 3: a 0.2 U bolus
        link.script(
            CommandType.GET_RECORD,
            fragments: "236312010000aa1c05ff9e75aef7ed000100afd8",
            "23631202010000b334ab17af0100009b6dc19942",
            "2363120373bb"
        )
        link.script(
            CommandType.GET_RECORD,
            fragments: "276313010000aa2002ff9e75aef7ed000200c2ac",
            "2763130234ab179835ab1701000c0000002a009a",
            "27631303a8d00d70ef41"
        )
        link.script(
            CommandType.GET_RECORD,
            fragments: "336314010000aa2c01ff9e75aef7ed00030001a6",
            "336314020000009935ab1704000400000000006f",
            "3363140300000000000000000000000064771636",
            "33631404823520"
        )

        let syncedFrom = Date.now
        link.deliverFullStatus([
            "2f031001000020ee0d800400800000060200ed70",
            "2f031002009835ab172a4000690ec234ab1746e8",
            "2f0310035c590300ed00840300005f0eb4dc"
        ])
        link.onQueue {
            StateSyncer.fetchPatchTimeIfStale(pumpManager: self.pumpManager)
            RecordSyncer.syncRecords(pumpManager: self.pumpManager)
        }
        settle()

        // The status
        let synced = pumpManager.state
        XCTAssertEqual(synced.pumpState, .active)
        XCTAssertEqual(synced.basalState, .tempBasal)
        XCTAssertEqual(synced.reservoir, 184.45, accuracy: 0.001)
        XCTAssertEqual(synced.initialReservoir, 200, "only set when there is none")
        XCTAssertEqual(synced.battery, 2.791015625, accuracy: 0.000001)
        XCTAssertEqual(synced.patchActivatedAt, Date(timeIntervalSince1970: 1_785_630_530))
        XCTAssertGreaterThanOrEqual(synced.lastSync, syncedFrom)

        // The running temp basal had no patch start yet, so it takes the one the status reports
        XCTAssertEqual(synced.basalDose.pumpStartTime, Date(timeIntervalSince1970: 1_785_630_744))

        // A full status reports the running dose again, replacing what the host holds. Its bolus field
        // repeats the completion of the 0.2 U bolus before it, which - with no bolus running - is ignored.
        XCTAssertEqual(delegate.batches.count, 1)
        let batch = delegate.batches.first
        XCTAssertEqual(batch?.replacePendingEvents, true)
        XCTAssertEqual(batch?.events.map(\.dose?.type), [.tempBasal])
        XCTAssertEqual(batch?.events.first?.dose?.isMutable, true)
        XCTAssertEqual(batch?.events.first?.dose?.startDate, tempBasal.startDate)
        XCTAssertGreaterThanOrEqual(batch?.lastReconciliation ?? .distantPast, syncedFrom)

        // The reservoir changed on a full sync, so it is reported - rounded to one decimal
        XCTAssertEqual(delegate.reservoirReads.count, 1)
        XCTAssertEqual(delegate.reservoirReads.first?.units ?? 0, 184.5, accuracy: 0.001)

        // The patch time
        XCTAssertEqual(synced.pumpTime, Date(timeIntervalSince1970: 1_785_630_987))
        XCTAssertGreaterThanOrEqual(synced.pumpTimeSyncedAt, syncedFrom)

        // The records: everything up to the 3 the status reports, oldest first
        XCTAssertEqual(
            link.writtenCommands,
            [CommandType.GET_TIME, CommandType.GET_RECORD, CommandType.GET_RECORD, CommandType.GET_RECORD]
        )
        let writes = link.writes
        if writes.count == 4 {
            XCTAssertEqual(writes[0].encoded(sequence: 0x11), "050b11004c00")
            XCTAssertEqual(writes[1].encoded(sequence: 0x12), "096312000100ed002900")
            XCTAssertEqual(writes[2].encoded(sequence: 0x13), "096313000200ed00de00")
            XCTAssertEqual(writes[3].encoded(sequence: 0x14), "096314000300ed000f00")
        }

        XCTAssertEqual(synced.currentSequenceNumber, 3)
        XCTAssertEqual(synced.syncedSequenceNumber, 3)

        let records = pumpManager.recordStore.records
        XCTAssertEqual(records.map(\.id), [3, 2, 1])
        XCTAssertEqual(records.map(\.kind), ["BOLUS", "BASAL", "UNHANDLED"])
        XCTAssertEqual(records.first?.eventDate, Date(timeIntervalSince1970: 1_785_630_745))
        XCTAssertEqual(records.dropFirst().first?.eventDate, Date(timeIntervalSince1970: 1_785_630_530))
        XCTAssertEqual(pumpManager.recordStore.status, .idle)

        XCTAssertEqual(delegate.errors.count, 0)
        XCTAssertEqual(delegate.alerts.count, 1)
        XCTAssertEqual(delegate.alerts.first?.identifier.alertIdentifier.hasPrefix("com.nightscout.medtrumkit.bolus-not-counted"), true)
        XCTAssertEqual(delegate.alerts.first?.foregroundContent?.body.contains("a bolus of \(0.2.formatted()) U delivered at"), true)
    }
}

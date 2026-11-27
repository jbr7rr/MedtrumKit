import LoopKit
@testable import MedtrumKit
import XCTest

extension ManagerTempBasalBackToBackScenarioTests {
    // MARK: - Driving

    /// `rate` U/h of ours, 30 min, running for 20 min from `start1`, every record read up to `sequence` - the patch clock
    /// `end1` plus `patchAhead` now
    @discardableResult func runFirst(
        patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId,
        sequence: Int = 130,
        rate: Double = 1.2,
        patchAhead: TimeInterval = 0
    ) -> UnfinalizedDose {
        let state = activePatchState(patchId: patchId, scheduledRate: 0.7, sequence: sequence, reservoir: 150)
        let tempBasal = runningTempBasal(rate: rate, startedAgo: 20 * Self.minute, duration: 30 * Self.minute, pumpStartTime: Self.start1)
        state.basalDose = tempBasal
        state.basalState = .tempBasal
        state.lastSegmentStart = Self.start1
        alignPatchClock(state, patchTime: Self.end1.addingTimeInterval(patchAhead))
        makeManager(state)
        return tempBasal
    }

    /// The answers to replacing the `n`th temp basal: 1, the 1.2 U/h one at `end1` for 0.5 U/h (its record 131, the
    /// scheduled second 132); 2, the 0.5 U/h one at `end2` for 0.8 U/h (133, 134)
    func scriptReplacement(of n: Int, patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId, rate: Double? = nil) {
        let (end, record, defaultRate) = n == 1 ? (Self.end1, 131, 0.5) : (Self.end2, 133, 0.8)
        let rate = rate ?? defaultRate
        link.script(CommandType.CANCEL_TEMP_BASAL, cancelAnswer(record: record, at: end, patchId: patchId))
        link.script(CommandType.SET_TEMP_BASAL, setAnswer(rate: rate, record: record + 1, at: end.addingTimeInterval(1), patchId: patchId))
    }

    func cancelAnswer(record: Int, at end: Date, patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId) -> [String] {
        PatchBytes.segmentAnswer(command: CommandType.CANCEL_TEMP_BASAL, type: .STANDARD, rate: 0.7, sequence: record, patchId: patchId, start: end)
    }

    func setAnswer(rate: Double, record: Int, at start: Date, patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId) -> [String] {
        PatchBytes.segmentAnswer(command: CommandType.SET_TEMP_BASAL, type: .ABSOLUTE_TEMP, rate: rate, sequence: record, patchId: patchId, start: start)
    }

    func recordOfFirst(
        delivered: Double,
        patchId: UInt64 = ManagerTempBasalBackToBackScenarioTests.patchId,
        end: Date = ManagerTempBasalBackToBackScenarioTests.end1
    ) -> [String] {
        PatchBytes.basalRecord(
            sequence: 131, patchId: patchId, type: .ABSOLUTE_TEMP, start: Self.start1, end: end, rate: 1.2, delivered: delivered
        )
    }

    func recordOfSecond(
        delivered: Double,
        end: Date = ManagerTempBasalBackToBackScenarioTests.end2,
        rate: Double = 0.5,
        endReason: BasalEndReason = .SUCCESS
    ) -> [String] {
        PatchBytes.basalRecord(
            sequence: 133,
            patchId: Self.patchId,
            type: .ABSOLUTE_TEMP,
            start: Self.end1.addingTimeInterval(1),
            end: end,
            rate: rate,
            delivered: delivered,
            endReason: endReason
        )
    }

    /// The second of scheduled basal between a cancel at `at` and the set after it
    func scheduledSecond(sequence: Int, at: Date) -> [String] {
        PatchBytes.basalRecord(
            sequence: sequence, patchId: Self.patchId, type: .STANDARD, start: at, end: at.addingTimeInterval(1), rate: 0.7, delivered: 0
        )
    }

    /// Records 131 - 133: the first temp basal, the scheduled second, the second temp basal
    func recordsThroughTheSecond(
        delivered: Double,
        rate: Double = 0.5,
        endReason: BasalEndReason = .SUCCESS,
        end: Date = ManagerTempBasalBackToBackScenarioTests.end2
    ) -> [FakeMedtrumLink.Answer] {
        [
            .fragments(recordOfFirst(delivered: 0.35)),
            .fragments(scheduledSecond(sequence: 132, at: Self.end1)),
            .fragments(recordOfSecond(delivered: delivered, end: end, rate: rate, endReason: endReason))
        ]
    }

    /// The SET_BOLUS answer: record `record`, started at `start`
    func bolusAnswer(record: Int, start: Date) -> [String] {
        let body = UInt64(record).toData(length: 2) + Self.patchId.toData(length: 2) + start.toMedtrumSeconds()
        return PatchBytes.answer(command: CommandType.SET_BOLUS, body: body)
    }

    /// The patch's notification of the running bolus complete at `delivered`, naming `record` the newest
    func completion(delivered: Double, record: Int) -> String {
        let storage = UInt64(record).toData(length: 2) + Self.patchId.toData(length: 2)
        return "200211" + "80" + UInt64((delivered / 0.05).rounded()).toData(length: 2).hexEncodedString() +
            storage.hexEncodedString() + "0000000000"
    }

    /// The patch's heartbeat naming its newest record, then what `PeripheralManager.considerFullSync` does between full
    /// syncs
    func heartbeat() {
        confirmRecordSequence()
        if pumpManager.heartbeatSync() == .records {
            syncRecords(.awaitingDoses)
        }
    }

    func running(rate: Double, from start: Date, sequence: Int) -> String {
        PatchBytes.basalNotification(type: .ABSOLUTE_TEMP, sequence: sequence, patchId: Self.patchId, start: start, rate: rate)
    }

    /// The patch's notification that it halted delivery, in `state`, naming `newestRecord`, with when it halted - or
    /// without, as for a halt of its own
    func halt(_ state: PatchState, at: Date?, newestRecord: Int) -> String {
        let storage = UInt64(newestRecord).toData(length: 2) + Self.patchId.toData(length: 2)
        guard let at else {
            return (Data([state.rawValue, 0x00, 0x01]) + storage).hexEncodedString()
        }
        return (Data([state.rawValue, 0x01, 0x01]) + at.toMedtrumSeconds() + storage).hexEncodedString()
    }

    /// The first batch that carries `final`
    func batchIndex(ofFinal final: DoseEntry) -> Int? {
        delegate.batches.firstIndex { batch in
            batch.events.contains { $0.dose?.syncIdentifier == final.syncIdentifier && $0.dose?.isMutable == false }
        }
    }
}

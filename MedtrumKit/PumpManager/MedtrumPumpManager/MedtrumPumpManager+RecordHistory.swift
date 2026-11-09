import Foundation

/// What a fill of the current patch's history read - see `MedtrumPumpManager.fillRecordHistory`
public struct RecordHistoryFill: Equatable {
    public enum Stop: Equatable {
        /// Every record missing was asked for
        case done
        /// `limit` records asked for: the rest is for the next call
        case limitReached
        /// No session runs - or no history is kept
        case noSession
        /// A bolus runs: the link is its notifications'
        case bolusRunning
        /// A command holds the link - never waited for - or another operation, or the record sync, waits for it or runs:
        /// yielded to
        case linkBusy
        /// No answer, or no link
        case linkLost(String)
        /// The session ended, or the patch changed, as it read
        case sessionChanged
    }

    /// The numbers read and kept, in the order read - newest first
    public let read: [Int]
    /// The numbers asked for and not kept as records: unreadable, or answered with another record - another patch's, or
    /// another number. Noted as such in the file (`PatchRecordHistory.appendNotKept`): not asked for again.
    public let notKept: [Int]
    public let stop: Stop
}

/// The records of the current patch and the one before, kept in a file each (`PatchRecordHistory`): for the screens
/// that show them, and the shared logs
extension MedtrumPumpManager {
    /// Records one fill asks for at most
    public static let recordHistoryPageSize = 20

    /// The patches whose records can be shown: the current one, if a session runs, then the previous one if it has a
    /// file
    public func recordHistoryPatches() -> [UInt64] {
        guard let recordHistory else {
            return []
        }
        let current = currentHistoryPatch
        let previous = state.previousPatch.map { $0.patchId.toUInt64() }.flatMap { previous in
            previous != current && !recordHistory.files(of: [previous]).isEmpty ? previous : nil
        }
        return [current, previous].compactMap { $0 }
    }

    /// The records kept of patch `patchId`, decoded, newest first, one per number
    public func historyRecords(forPatch patchId: UInt64) async -> [StoredRecord] {
        await recordHistory?.records(forPatch: patchId) ?? []
    }

    /// The numbers of patch `patchId` with no record kept, from 1 on, in order: for the current patch up to the newest
    /// the record sync went past (`syncedSequenceNumber`) - the ones after it are the sync's to read
    public func missingRecordSequences(forPatch patchId: UInt64) async -> [Int] {
        let through = patchId == currentHistoryPatch ? state.syncedSequenceNumber : nil
        return await recordHistory?.missingSequences(forPatch: patchId, through: through) ?? []
    }

    /// Reads up to `limit` of the current patch's missing records off the patch - newest first - and keeps them,
    /// matched to nothing: "history read". Connects first, and reads off the queue the connect answers on.
    public func fillRecordHistory(limit: Int = MedtrumPumpManager.recordHistoryPageSize) async -> RecordHistoryFill {
        guard currentHistoryPatch != nil else {
            return RecordHistoryFill(read: [], notKept: [], stop: .noSession)
        }
        return await withCheckedContinuation { continuation in
            link.ensureConnected { error in
                if let error {
                    continuation.resume(returning: RecordHistoryFill(read: [], notKept: [], stop: .linkLost(error.localizedDescription)))
                    return
                }
                let manager = UncheckedSendable(self)
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: manager.value.readMissingRecords(limit: limit))
                }
            }
        }
    }

    /// `fillRecordHistory` once connected - blocking on the link: never on the main queue or the Bluetooth queue.
    ///
    /// Display only, to the rules of the review of tomacs's reader (jbr7rr/MedtrumKit#224): each record holding the
    /// command lock, never waiting for it; never while a bolus runs; only records of this patch at the number asked for
    /// are kept, as the syncer's callers check them; a lost link ends it; the record sync's cursor
    /// (`syncedSequenceNumber`) is not moved, and nothing is matched to a dose. The current patch only: the base cannot be
    /// taken to serve the records of one before.
    ///
    /// It yields before every read: to an operation waiting for the command lock (`isLoopWaiting` - a stop, a prime, an
    /// activation, the loop's sync) and to the record sync running - its records, a temp basal's end, finalize doses. It
    /// never begins a command, so nothing would yield to it: without this, a page could keep winning the lock from them.
    /// An answer not kept is noted, not asked for again: otherwise stale slots at the newest end would fill every page.
    func readMissingRecords(limit: Int = MedtrumPumpManager.recordHistoryPageSize) -> RecordHistoryFill {
        guard let recordHistory, let patch = currentHistoryPatch else {
            return RecordHistoryFill(read: [], notKept: [], stop: .noSession)
        }
        let patchId = state.patchId
        let missing = recordHistory.missingSequencesNow(forPatch: patch, through: state.syncedSequenceNumber)
        guard !missing.isEmpty else {
            return RecordHistoryFill(read: [], notKept: [], stop: .done)
        }
        log.info("Record history: reading up to \(limit) of \(missing.count) record(s) missing of patch \(patch)")

        var read: [Int] = []
        var notKept: [Int] = []
        let stop = { (stop: RecordHistoryFill.Stop) -> RecordHistoryFill in
            recordHistory.commit()
            if stop != .done, stop != .limitReached {
                self.log.info("Record history: stopped after \(read.count) record(s) read - \(stop)")
            }
            return RecordHistoryFill(read: read, notKept: notKept, stop: stop)
        }

        for (index, sequence) in missing.reversed().enumerated() {
            guard index < limit else {
                return stop(.limitReached)
            }
            guard state.bolusDose == nil else {
                return stop(.bolusRunning)
            }
            guard state.patchId == patchId, !state.patchSessionEnded else {
                return stop(.sessionChanged)
            }
            guard !yieldsTheLink else {
                return stop(.linkBusy)
            }

            let result = withCommandLockIfFree { () -> RecordSyncer.ReadResult? in
                // Once it has the lock: a command, a bolus, a wait for the lock or a sync may have started meanwhile
                guard !isCommandActive, state.bolusDose == nil, !yieldsTheLink else {
                    return nil
                }
                return RecordSyncer.readOnce(sequence, patchId: patchId, pumpManager: self)
            }
            guard let result = result ?? nil else {
                return stop(state.bolusDose != nil ? .bolusRunning : .linkBusy)
            }
            guard state.patchId == patchId else {
                return stop(.sessionChanged)
            }

            switch result {
            case let .linkLost(error):
                return stop(.linkLost(error.errorDescription))

            case let .bad(problem):
                log.warning("Record history: record \(sequence) unreadable, not kept: \(problem)")
                recordHistory.appendNotKept(sequence: sequence, patchId: patch, raw: Data(), outcome: "unreadable: \(problem)")
                notKept.append(sequence)

            case let .record(response):
                guard response.sequence == sequence, RecordSyncer.isSamePatch(response.patchId, patch) else {
                    log.warning(
                        "Record history: record \(sequence) came back as \(response.sequence) of patch \(response.patchId), not kept"
                    )
                    recordHistory.appendNotKept(
                        sequence: sequence,
                        patchId: patch,
                        raw: response.raw,
                        outcome: "unreadable: answered as \(response.sequence) of patch \(response.patchId)"
                    )
                    notKept.append(sequence)
                    continue
                }
                recordHistory.append(response, patchId: patch, outcome: PatchRecordHistory.historyReadOutcome)
                read.append(sequence)
            }
        }
        return stop(.done)
    }

    /// The history files of the current patch and the previous one, what is queued written first: shared with the logs
    public func recordHistoryFilesForSharing() -> [URL] {
        guard let recordHistory else {
            return []
        }
        let previous = state.previousPatch.map { $0.patchId.toUInt64() }
        return recordHistory.files(of: [currentHistoryPatch, previous].compactMap { $0 }.uniqued())
    }

    /// The patch changed - `replaced` is the id it had, empty if none: the files of all but the current patch and the
    /// one before it go. The one before is the one replaced, or the previous patch recorded if none was.
    func pruneRecordHistory(replacing replaced: Data) {
        guard let recordHistory else {
            return
        }
        var keeping = Set<UInt64>()
        if !state.patchId.isEmpty {
            keeping.insert(state.patchId.toUInt64())
        }
        if !replaced.isEmpty {
            keeping.insert(replaced.toUInt64())
        } else if let previous = state.previousPatch, !previous.patchId.isEmpty {
            keeping.insert(previous.patchId.toUInt64())
        }
        // No patch known at all - a state lost, say: nothing to tell the files kept from the others by, all stay
        guard !keeping.isEmpty else {
            log.info("Record history: no patch to keep the records of, no file deleted")
            return
        }
        recordHistory.prune(keeping: keeping)
    }

    /// Another operation waits for the command lock - or the record sync runs: the fill gives way
    private var yieldsTheLink: Bool {
        isLoopWaiting || RecordSyncer.isRunning
    }

    /// The patch whose session runs, nil if none - or if no history is kept
    private var currentHistoryPatch: UInt64? {
        guard recordHistory != nil, !state.patchId.isEmpty, !state.patchSessionEnded else {
            return nil
        }
        return state.patchId.toUInt64()
    }
}

/// The manager, handed to the queue the fill reads on: it is used across queues by design, under its own locks
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

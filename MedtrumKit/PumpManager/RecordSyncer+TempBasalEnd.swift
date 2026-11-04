import Foundation

extension RecordSyncer {
    /// Reads the records the patch wrote for a temp basal of ours as it ended, up to the last one it named, and has it
    /// reported final with what followed it - see `MedtrumPumpManager.TempBasalEnd`. On the caller's thread, which may
    /// block on the link, holding the command lock: a full status's, or the end queue's. A run in progress is waited
    /// out: it yields between two records to the lock held here. Each record is asked for once: on the first that can't
    /// be read, or the first that is not the one asked for, it stops, and our estimate stands in. Not while a bolus
    /// runs: its notifications and a cancel have the link - read once it is over
    /// (`MedtrumPumpManager.readsTempBasalEndAfterBolus`).
    static func finishTempBasalEnd(pumpManager: MedtrumPumpManager) {
        guard let ending = pumpManager.pendingTempBasalEnd else {
            return
        }
        // A bolus running - a halt's notification ahead of its completion: read once it is over
        if pumpManager.readsTempBasalEndAfterBolus(ending) {
            return
        }
        guard mayRead(ending, pumpManager: pumpManager) else {
            return
        }

        guard beginWaiting(nil, timeout: beforeStopWait) else {
            _ = pumpManager.settleTempBasalEnd(ending, records: [], unread: "a record sync held the link")
            return
        }
        defer { end() }

        finishTempBasalEndInFlight(
            pumpManager: pumpManager,
            until: pumpManager.now().addingTimeInterval(MedtrumPumpManager.tempBasalEndReadBudget)
        )
    }

    /// The same, on a command's own thread, holding the command lock: no other command comes between its answer and
    /// these reads. They end by `deadline`. A run in progress stops at its next record, seeing the command: it is given
    /// `inCommandRunWait` of that time to, then our estimate stands in.
    static func finishTempBasalEnd(pumpManager: MedtrumPumpManager, inCommandUntil deadline: Date) {
        guard let ending = pumpManager.pendingTempBasalEnd, mayRead(ending, pumpManager: pumpManager) else {
            return
        }

        let wait = min(inCommandRunWait, max(0, deadline.timeIntervalSince(pumpManager.now())))
        guard beginWaiting(nil, timeout: wait) else {
            _ = pumpManager.settleTempBasalEnd(ending, records: [], unread: "a record sync was running")
            return
        }
        defer { end() }

        finishTempBasalEndInFlight(pumpManager: pumpManager, until: deadline)
    }

    /// How long a command's read waits for a run in progress to stop - the loop's own sync, say, that its follow-up
    /// started just before
    static let inCommandRunWait: TimeInterval = 1.5

    /// Whether the records of `ending` would be read now: it names its last - or the temp basals ended open before it
    /// do, see `MedtrumPumpManager.lastRecordToRead` - and no bolus runs. Those of the temp basals ended open before it are
    /// read with them, numbered before.
    static func wouldRead(_ ending: MedtrumPumpManager.TempBasalEnd, pumpManager: MedtrumPumpManager) -> Bool {
        pumpManager.lastRecordToRead(for: ending) != nil && pumpManager.state.bolusDose == nil
    }

    /// Whether the records of `ending` are to be read at all - if not, it is settled from our estimate here. Not yet
    /// while it waits for a status to name its last record (`TempBasalEnd.awaitsRecord`): read once one does.
    private static func mayRead(_ ending: MedtrumPumpManager.TempBasalEnd, pumpManager: MedtrumPumpManager) -> Bool {
        guard !ending.awaitsRecord else {
            logger.debug("The records of the temp basal of \(ending.dose.startDate) are read once a status names its last")
            return false
        }
        guard wouldRead(ending, pumpManager: pumpManager) else {
            _ = pumpManager.settleTempBasalEnd(
                ending,
                records: [],
                unread: pumpManager.lastRecordToRead(for: ending) == nil ? "no record of its end is known" : "a bolus is running"
            )
            return false
        }
        return true
    }

    /// `finishTempBasalEnd`, the run already this one's, reading until `deadline` on the manager's clock
    static func finishTempBasalEndInFlight(pumpManager: MedtrumPumpManager, until deadline: Date) {
        // Its last record named by a status yet to come: read then - not settled here meanwhile
        guard let ending = pumpManager.pendingTempBasalEnd, !ending.awaitsRecord else {
            return
        }
        pumpManager.noteTempBasalEndReadBegins(ending)

        let state = pumpManager.state
        let patchId = state.patchId
        let store = pumpManager.recordStore
        var records: [GetRecordResponse] = []
        var unread: String?

        // Off a command, the patch suspended: longer, for a slow link - see `tempBasalEndSuspendedReadBudget`
        let suspendedDeadline = max(
            deadline,
            pumpManager.now().addingTimeInterval(MedtrumPumpManager.tempBasalEndSuspendedReadBudget)
        )

        if let last = pumpManager.lastRecordToRead(for: ending), !patchId.isEmpty {
            let first = state.syncedSequenceNumber + 1

            if last < first {
                unread = "its record \(last) was read before it ended"
            } else if last - first >= MedtrumPumpManager.tempBasalEndMaxRecords {
                unread = "records \(first)...\(last) are too many to read now"
            } else {
                logger.info("Reading records \(first)...\(last), of the temp basal of \(ending.dose.startDate) that ended")

                reading: for sequence in first ... last {
                    // Less than a round trip left, and the record would be asked for only to be given up on
                    let longer = pumpManager.readsLongerAsTempBasalEnds
                    let left = (longer ? suspendedDeadline : deadline).timeIntervalSince(pumpManager.now())
                    guard left >= MedtrumPumpManager.tempBasalEndRecordReadMinimum else {
                        let budget = longer ? MedtrumPumpManager.tempBasalEndSuspendedReadBudget : MedtrumPumpManager.tempBasalEndReadBudget
                        unread = "the \(Int(budget)) s to read them ran out at \(sequence)"
                        break reading
                    }

                    store.setStatus(.syncing(sequence: sequence, upTo: last))

                    let timeout = min(left, MedtrumPumpManager.tempBasalEndRecordTimeout)
                    switch readOnce(sequence, patchId: patchId, pumpManager: pumpManager, timeout: timeout) {
                    case let .record(response):
                        guard response.sequence == sequence, isSamePatch(response.patchId, patchId.toUInt64()) else {
                            unread = "record \(sequence) came back as \(response.sequence) of patch \(response.patchId)"
                            break reading
                        }
                        records.append(response)

                        // Its own records read, adding up to where it is shown to have ended: the ones after them say
                        // nothing of it - left to the sync
                        if sequence < last, pumpManager.settlesTempBasalEnd(ending, records: records) {
                            logger.info(
                                "Record(s) up to \(sequence) settle the temp basal of \(ending.dose.startDate), " +
                                    "\(sequence + 1)...\(last) are left to the sync"
                            )
                            break reading
                        }

                    case let .bad(problem):
                        unread = "record \(sequence): \(problem)"
                        break reading

                    case let .linkLost(error):
                        unread = "record \(sequence): \(error.errorDescription)"
                        break reading
                    }
                }

                if let unread {
                    logger.warning("Stopped reading the records of the temp basal of \(ending.dose.startDate): \(unread)")
                    store.setStatus(.failed(unread))
                }
            }
        } else {
            unread = "no record of its end is known"
        }

        // The session ended meanwhile - a base reset, a stop: these records are moot, and not this session's to keep
        guard state.patchId == patchId else {
            logger.warning("The patch session changed while the records of the temp basal of \(ending.dose.startDate) were read")
            _ = pumpManager.settleTempBasalEnd(ending, records: [], unread: "the patch session changed while they were read")
            return
        }

        let outcomes = pumpManager.settleTempBasalEnd(ending, records: records, unread: unread)

        // As a sync would: stored, and the cursor past them - after the final went out
        for response in records {
            apply(
                response,
                requested: response.sequence,
                current: state.currentSequenceNumber,
                patchId: patchId,
                pumpManager: pumpManager,
                outcome: outcomes[response.sequence]
            )
        }
        if !records.isEmpty, unread == nil {
            store.finishedSync()
        }
    }

    /// Reads the records from the cursor up to `last`, in order, on a command's own thread, holding the command lock,
    /// and reconciles each as a sync would - every one: a bolus's between the cursor and `last` is not skipped. For
    /// `what`, its record among them. Each is asked for once, `tempBasalEndRecordTimeout` at most, all of them by
    /// `deadline`; on the first that can't be read it stops - the rest are left to the sync. A run in progress stops at
    /// its next record, seeing the command: it is given `inCommandRunWait` to. Not more than `tempBasalEndMaxRecords`.
    static func readInCommand(pumpManager: MedtrumPumpManager, through last: Int, until deadline: Date, of what: String) {
        let state = pumpManager.state
        let patchId = state.patchId
        let first = state.syncedSequenceNumber + 1
        guard !patchId.isEmpty, first <= last else {
            return
        }
        guard last - first < MedtrumPumpManager.tempBasalEndMaxRecords else {
            logger.info("Records \(first)...\(last) are too many to read in the command, of \(what): left to the sync")
            return
        }

        // A temp basal's record unnamed may be among them: left to the sync, which reads them once it is named
        if let ending = pumpManager.pendingTempBasalEnd, ending.awaitsRecord {
            logger.info(
                "The temp basal of \(ending.dose.startDate) waits for a status to name its record: the records of \(what) " +
                    "are left to the sync"
            )
            return
        }

        let wait = min(inCommandRunWait, max(0, deadline.timeIntervalSince(pumpManager.now())))
        guard beginWaiting(nil, timeout: wait) else {
            logger.warning("A record sync was running: the records of \(what) are left to the next")
            return
        }
        defer { end() }

        logger.info("Reading records \(first)...\(last) in the command, of \(what)")
        let store = pumpManager.recordStore
        var unread: String?

        reading: for sequence in first ... last {
            // The cursor can run ahead, following a record that came back with a later number
            guard sequence > state.syncedSequenceNumber else {
                continue
            }
            let left = deadline.timeIntervalSince(pumpManager.now())
            guard left >= MedtrumPumpManager.tempBasalEndRecordReadMinimum else {
                unread = "the \(Int(MedtrumPumpManager.tempBasalEndReadBudget)) s to read them ran out at \(sequence)"
                break reading
            }

            store.setStatus(.syncing(sequence: sequence, upTo: last))
            let timeout = min(left, MedtrumPumpManager.tempBasalEndRecordTimeout)
            switch readOnce(sequence, patchId: patchId, pumpManager: pumpManager, timeout: timeout) {
            case let .record(response):
                // The session ended while it was read: not this session's to keep
                guard state.patchId == patchId else {
                    unread = "the patch session changed while record \(sequence) was read"
                    break reading
                }
                apply(response, requested: sequence, current: state.currentSequenceNumber, patchId: patchId, pumpManager: pumpManager)

            case let .bad(problem):
                unread = "record \(sequence): \(problem)"
                break reading

            case let .linkLost(error):
                unread = "record \(sequence): \(error.errorDescription)"
                break reading
            }
        }

        if let unread {
            logger.warning("Stopped reading the records of \(what): \(unread) - left to the sync")
            store.setStatus(.failed(unread))
        } else {
            store.finishedSync()
        }
    }
}

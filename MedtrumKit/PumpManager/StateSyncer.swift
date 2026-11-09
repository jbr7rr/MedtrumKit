import LoopKit

enum StateSyncer {
    private static let logger = MedtrumLogger(category: "StateSyncer")

    static func sync(
        syncResponse: SynchronizePacketResponse,
        state: MedtrumPumpState,
        pumpManager: MedtrumPumpManager,
        duringReconnect: Bool,
        fullSync: Bool
    ) {
        let syncDate = Date.now

        // In one step with a session's end - a forced deactivation, on the main queue - which sets the state these go by
        // (`endPatchSession`): a status that passed them just before it would write a running state over its `.none`.
        // No test drives a status into this block as a forced end runs: the lock leaves no seam to pause one between
        // the checks and the state written.
        let taken = pumpManager.withDoseReportLock { () -> (response: SynchronizePacketResponse, startsSession: Bool)? in
            // Checked on the payload as received: a rebooted base reports a new patch id, and validation
            // would strip exactly the fields that tell a reset apart - and when it happened
            switch baseResetCheck(syncResponse: syncResponse, state: state) {
            case .reset:
                guard !pumpManager.isDeactivatingPatch else {
                    break
                }

                // Nothing else in this payload describes the patch we knew
                pumpManager.handleBaseReset(
                    deliveryStoppedAt: deliveryStoppedAt(syncResponse: syncResponse, state: state, receivedAt: syncDate)
                )
                return nil

            case .unconfirmed:
                // `.none` is also what an unknown state byte parses to, don't drop an activated patch over it
                logger.warning("Activated patch reported state none without a new patch id, ignoring")
                return nil

            case .noReset:
                break
            }

            // No session, the old patch heard from running - forced out, its StopPatch lost, still on the base: nothing of
            // it is ours. Not its state - a running one would have the new patch's setup taken for a base reset, the loop
            // sync with it, commands go to it, an activation take it for the new patch - nor its basal: its schedule would
            // resume over the session's suspend. One that stopped is taken as before: what the setup screens and the loop
            // go by. Nor its battery and reservoir: not the next patch's, a low reservoir alert of the old one's.
            if isEndedSessionsPatchRunning(syncResponse: syncResponse, state: state) {
                logger.info("Status of the previous patch, running, its session ended: not taken - \(syncResponse.state.description)")
                if fullSync {
                    pumpManager.noteStatusOfThePreviousPatch(at: syncDate)
                }
                return nil
            }

            // No session: the id kept can be stale - the previous patch's, or one never started - and would reject the
            // new patch's payloads. The storage gate below decides which id to keep then.
            let expectedPatchId = state.patchSessionEnded ? 0 : state.patchId.toUInt64()
            let syncResponse = syncResponse.validated(expectedPatchId: expectedPatchId)

            StateSyncer.updatePumpState(syncResponse: syncResponse, pumpManager: pumpManager, receivedAt: syncDate)
            // A patch being set up, not primed yet, since an activation went out: a next patch, the one it went to not
            // activated - nothing of a status is to start a session for it. Not primed: a status as the activation is
            // written may show it still. Not `.none`: an unknown state byte reads as that too. Priming a next patch
            // clears it as well (`MedtrumPumpManager.primePatch`).
            if state.activationSentAt != nil, [PatchState.idle, .filled, .priming].contains(syncResponse.state) {
                logger.info("A patch is being set up, \(syncResponse.state.description): the activation sent before is done with")
                state.activationSentAt = nil
            }
            return (syncResponse, showsActivatedPatch(syncResponse: syncResponse, state: state))
        }
        guard let taken else {
            return
        }
        let syncResponse = taken.response
        // After what this status tells is in - the patch's start, its id - as a retried activation goes by
        defer {
            if taken.startsSession {
                pumpManager.startSessionOfActivatedPatchSoon()
            }
        }

        let hasActivatedPatch = syncResponse.state.rawValue >= PatchState.active.rawValue

        if let reservoir = syncResponse.reservoir {
            if hasActivatedPatch,
               let lowReservoirWarning = state.lowReservoirWarning,
               state.reservoir > lowReservoirWarning,
               reservoir < lowReservoirWarning
            {
                // Send low reservoir warning notification to user
                pumpManager.emitAlert(alertType: .lowReservoir(level: reservoir))
            }

            if state.reservoir != reservoir {
                state.reservoir = reservoir

                if fullSync, hasActivatedPatch {
                    // to prevent spaming the OSAID app with reservoir updates
                    pumpManager.emitReservoirLevel()
                }
            }

            if hasActivatedPatch, state.initialReservoir == nil {
                state.initialReservoir = reservoir
            }
        }

        // Before anything below reports a batch: the state saved with it has these already
        if let prime = syncResponse.primeProgress {
            state.primeProgress = prime
        }

        if let battery = syncResponse.battery {
            state.battery = battery.voltageB
        }

        if let startTime = syncResponse.startTime {
            state.patchActivatedAt = startTime
        }

        // No session: the old patch can report its id until it disconnects - its records are not ours to follow. A running
        // patch with another id is the new one, its session not started.
        if let storage = syncResponse.storage, !state.patchSessionEnded ||
            (syncResponse.state.isRunning && UInt64(storage.patchId) != state.previousPatch?.patchId.toUInt64())
        {
            let patchId = UInt64(storage.patchId).toData(length: 4)
            if state.patchId != patchId {
                // Record numbers are per patch, so anything we synced from the old one is meaningless
                logger.info("New patch id \(patchId.hexEncodedString()), resetting the record sequence")
                state.patchId = patchId
                state.resetRecordSequence()
                // Taken up with what it has written: another app's doses, or an earlier state's
                state.sessionStartSequence = Int(storage.sequence)
                pumpManager.recordStore.clear()
                state.lastSegmentStart = nil
            } else if state.sessionStartSequence == nil {
                // Saved mid-patch by a build that did not keep it - the released driver: taken up here, as a new patch
                // id is. The records up to here are that build's doses, which the host has.
                logger.info("No session start known for patch \(patchId.hexEncodedString()), taking it up at record \(storage.sequence)")
                state.sessionStartSequence = Int(storage.sequence)
            }

            state.currentSequenceNumber = max(state.currentSequenceNumber, Int(storage.sequence))
            // The newest record the patch has written, as it says
            if Int(storage.sequence) >= state.currentSequenceNumber {
                pumpManager.noteRecordSequenceConfirmed(
                    receivedAt: syncResponse.receivedAt, receivedUptime: syncResponse.receivedUptime
                )
            }
        }

        // Not while the session start is unknown - the released driver's state, no status naming the newest record since:
        // the records it let the sync read would never be told of (`MedtrumPumpManager.warnOfBolusNotCounted`)
        if let basal = syncResponse.basal, state.sessionStartSequence != nil {
            state.currentSequenceNumber = max(state.currentSequenceNumber, Int(basal.sequence))
        }

        // A status received before the command of the dose it is checked against says nothing of that dose - see
        // `MedtrumPumpManager.statusPredatesCommand`
        let receivedAt = syncResponse.receivedAt
        let receivedUptime = syncResponse.receivedUptime

        pumpManager.noteStatusHandled(
            halted: syncResponse.state.isDeliveryHalted || syncResponse.basal.map { $0.type.isSuspendedByPump() } == true
        )

        // The temp basal a halt ended, its status naming no record - cut short: this one names the newest, its last or
        // after it - read now, as if this status ended it (`MedtrumPumpManager.namesRecordOfTempBasalEnd`). Before what
        // this status ends: a temp basal set since - held behind it - ended here too would take it out from our estimate
        // first (`beginTempBasalEnd`). So with one running it is read right here, a full status's thread free to block on
        // the link - a command's own, asking for it (`askForTheRecordOfTheWaitingEnd`), or the heartbeat's.
        var namedTempBasalEnd = false
        if let storage = syncResponse.storage,
           pumpManager.namesRecordOfTempBasalEnd(
               Int(storage.sequence),
               patchId: UInt64(storage.patchId),
               receivedUptime: receivedUptime
           )
        {
            let tempBasalRunning = pumpManager.withDoseReportLock {
                pumpManager.state.basalDose.type == .tempBasal && !pumpManager.state.basalDose.isFinished
            }
            let readNow = fullSync && !duringReconnect && tempBasalRunning && pumpManager.finishPendingTempBasalEndIfFree()
            namedTempBasalEnd = !readNow
        }

        var events: [NewPumpEvent] = []
        // A temp basal this status ended, reported once its records are read
        var endedTempBasal = false
        if syncResponse.state.isDeliveryHalted {
            // a halted state is authoritative even when the notification carries a cached basal.
            if let suspended = recordSuspendIfDelivering(
                pumpManager: pumpManager,
                basal: syncResponse.basal,
                basalIsCurrent: false,
                suspendTime: syncResponse.suspendTime,
                storage: syncResponse.storage,
                receivedAt: receivedAt,
                receivedUptime: receivedUptime
            ) {
                events.append(contentsOf: suspended.events)
                endedTempBasal = suspended.endedTempBasal
                state.basalState = .suspended
            }
        } else if let basal = syncResponse.basal {
            pumpManager.withDoseReportLock {
                pumpManager.noteSegmentStart(basal.startTime)
            }

            switch basal.type {
            case .ABSOLUTE_TEMP,
                 .RELATIVE_TEMP:
                // `sequence` does NOT identify the segment running now - it is the last record the patch has
                // written, and the running segment is only numbered once it ends. The basal state is set there.
                pumpManager.followTempBasalSegment(
                    basal,
                    fullSync: fullSync,
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                )

            case .STOP,
                 .STOP_BASE_FAULT,
                 .STOP_BATTERY_EMPTY,
                 .STOP_DISCARD,
                 .STOP_EMPTY,
                 .STOP_EXPIRED,
                 .STOP_OCCLUSION,
                 .STOP_PATCH_FAULT,
                 .STOP_PATCH_FAULT2,
                 .SUSPEND_AUTO,
                 .SUSPEND_KEY_LOST,
                 .SUSPEND_LOW_GLUCOSE,
                 .SUSPEND_MANUAL,
                 .SUSPEND_MORE_THAN_MAX_PER_DAY,
                 .SUSPEND_MORE_THAN_MAX_PER_HOUR,
                 .SUSPEND_PREDICT_LOW_GLUCOSE:
                if let suspended = recordSuspendIfDelivering(
                    pumpManager: pumpManager,
                    basal: basal,
                    basalIsCurrent: true,
                    suspendTime: syncResponse.suspendTime,
                    storage: syncResponse.storage,
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                ) {
                    events.append(contentsOf: suspended.events)
                    endedTempBasal = suspended.endedTempBasal
                    state.basalState = .suspended
                }

            default:
                if let resumed = scheduleShown(basal, receivedAt: receivedAt, receivedUptime: receivedUptime, pumpManager: pumpManager) {
                    events.append(contentsOf: resumed.events)
                    endedTempBasal = resumed.endedTempBasal
                }
            }
        }

        if namedTempBasalEnd {
            endedTempBasal = true
        }

        // The first status of this run, the run before killed as it read the records of a temp basal that ended: read
        // now, as if this status ended it - see `MedtrumPumpManager.takeOverTempBasalEndFromLastRun`
        if pumpManager.readsTempBasalEndFromLastRun() {
            endedTempBasal = true
        }

        // A status that failed validation, or came in cut short, shows nothing - not that no bolus is delivering, nor
        // that we are in touch with the patch
        let isUsable = !syncResponse.invalidPayload && !syncResponse.truncated

        // Whether the running bolus stalled - before the step this status carries is taken: it closes the gap since the
        // last one
        pumpManager.checkBolusStall(syncResponse, usable: isUsable, duringReconnect: duringReconnect, fullSync: fullSync)

        // Progress, from any status, is the running bolus's. A completion only from a notification: a full status
        // repeats the last bolus's completion for hours - and with no bolus running, the notification after a cancel
        // tells what the cancelled one delivered.
        if let bolus = syncResponse.bolus {
            if !bolus.completed {
                pumpManager.updateBolusProgress(
                    delivered: bolus.delivered,
                    fullSync: fullSync,
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                )
            } else if !fullSync,
                      !pumpManager.completeBolus(delivered: bolus.delivered, receivedAt: receivedAt, receivedUptime: receivedUptime)
            {
                pumpManager.noteCompletionWithNoBolusRunning(
                    delivered: bolus.delivered,
                    record: syncResponse.storage.map { Int($0.sequence) },
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                )
            }
        }

        // A full status showing no bolus delivering, naming the running bolus's record written - or past its deadline:
        // we lost its end
        if fullSync, isUsable, syncResponse.bolus?.completed != false {
            if let bolus = syncResponse.bolus, let storage = syncResponse.storage {
                pumpManager.completeBolusByItsRecord(
                    delivered: bolus.delivered,
                    newestRecord: Int(storage.sequence),
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                )
            }
            pumpManager.checkBolusDone(receivedAt: receivedAt, receivedUptime: receivedUptime)
        }

        // Its records are read here for a full status, whose thread may block on the link - not while connecting, nor
        // with a command in flight, whose path comes first. Otherwise off the queue notifications arrive on. After the
        // bolus this status ends, if any - its end held behind the read (`MedtrumPumpManager.emitBolusEvents`): with a
        // bolus running, they would not be read, our estimate standing in (`RecordSyncer.wouldRead`).
        var endReadDeferred = false
        if endedTempBasal {
            if !fullSync || duringReconnect || pumpManager.isCommandActive || !pumpManager.finishPendingTempBasalEndIfFree() {
                pumpManager.finishPendingTempBasalEndSoon()
                endReadDeferred = true
            }
        }

        if (fullSync && isUsable) || !events.isEmpty {
            if isUsable {
                pumpManager.state.lastSync = syncDate
            }
            // Not with the records of a temp basal still to be read - this status ended it, or a command did and reads
            // them meanwhile: this batch would carry it out final from our estimate first. The batch their read ends
            // with replaces pending events as this one would.
            if !endReadDeferred || !events.isEmpty {
                // A suspend held back for the records of the temp basal whose command went unanswered goes out ahead
                // of what this status reports - not a resume: held with it (`resumeSchedule`)
                if !events.isEmpty {
                    pumpManager.releaseHeldForUnconfirmedRead()
                }
                pumpManager.emitPumpEvents(events, unlessTempBasalEndPending: true)
            }
        }

        pumpManager.notifyStateDidChange()
    }

    /// A status shows the patch running its schedule, from `basal`'s start: what that ends and starts, and whether it ended
    /// a temp basal whose records are to be read. In one step with what it ends, and with the basal state: a command's
    /// own, set under the same lock - the temp basal it started, or the unconfirmed one it kept - is never overwritten by
    /// what a status decided before it. Nil: it says nothing of the basal running.
    private static func scheduleShown(
        _ basal: BasalData,
        receivedAt: Date,
        receivedUptime: TimeInterval,
        pumpManager: MedtrumPumpManager
    ) -> (events: [NewPumpEvent], endedTempBasal: Bool)? {
        pumpManager.withDoseReportLock { () -> (events: [NewPumpEvent], endedTempBasal: Bool)? in
            // One begun before the unconfirmed temp basal's command - or seen before it went out - says nothing
            // of whether the patch runs it: the next temp basal still cancels first
            let endsUnconfirmed = pumpManager.noteSegmentAfterUnconfirmedTempBasal(
                startingAt: basal.startTime,
                receivedAt: receivedAt,
                receivedUptime: receivedUptime
            )

            // The patch is delivering on its schedule again, since the start of the segment it shows. Nil: this
            // status says nothing of the basal running, which stays as it is.
            guard let resumed = resumeSchedule(
                pumpManager: pumpManager,
                basal: basal,
                receivedAt: receivedAt,
                receivedUptime: receivedUptime
            ) else {
                return nil
            }
            if endsUnconfirmed {
                pumpManager.state.basalState = .active
            }
            return resumed
        }
    }

    /// The schedule a status showed while a cancel of the running temp basal was in flight, set aside for the command
    /// (`MedtrumPumpManager.isCancelInFlight`) - taken now that the cancel failed: it may have been the patch's own, a temp
    /// basal that ran out, or the cancel's, its answer lost. On the command's thread, holding the command lock.
    static func replayScheduleSetAside(
        _ basal: BasalData,
        receivedAt: Date,
        receivedUptime: TimeInterval,
        pumpManager: MedtrumPumpManager
    ) {
        logger.info("Taking the scheduled basal since \(basal.startTime) a status showed while the cancel was in flight")
        guard let resumed = scheduleShown(basal, receivedAt: receivedAt, receivedUptime: receivedUptime, pumpManager: pumpManager) else {
            return
        }
        if resumed.endedTempBasal {
            pumpManager.finishPendingTempBasalEndSoon()
        } else if !resumed.events.isEmpty {
            pumpManager.emitPumpEvents(resumed.events)
        }
        pumpManager.notifyStateDidChange()
    }

    /// The patch stopped delivering: the running basal ends, and the suspend starts, when the patch says it suspended
    /// (`suspendTime`, exact on its clock), or when a suspend segment started - else when this was received. A suspend
    /// ends a temp basal for good: the patch resumes on its schedule. The temp basal is reported final with the
    /// suspend, once its records up to the newest one this status names are read: `storage`'s, else the sequence of a
    /// `basalIsCurrent` - the suspend segment this status shows, not one cached in a halted state - else the next status
    /// naming one (`MedtrumPumpManager.TempBasalEnd.awaitsRecord`). Nil when this status says
    /// nothing of the basal running - received before the running temp basal's command went out - so the caller leaves
    /// the basal state as it is: marking it suspended would refuse dosing with nothing suspended as far as the doses go.
    private static func recordSuspendIfDelivering(
        pumpManager: MedtrumPumpManager,
        basal: BasalData?,
        basalIsCurrent: Bool,
        suspendTime: Date?,
        storage: StorageData?,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> (events: [NewPumpEvent], endedTempBasal: Bool)? {
        let patchTime = suspendTime ?? basal.flatMap { $0.type.isSuspendedByPump() ? $0.startTime : nil }

        return pumpManager.withDoseReportLock { () -> (events: [NewPumpEvent], endedTempBasal: Bool)? in
            if let patchTime {
                pumpManager.noteSegmentAfterUnconfirmedTempBasal(
                    startingAt: patchTime,
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                )
            }

            let state = pumpManager.state
            let dose = state.basalDose
            guard dose.type == .basal || dose.type == .resume || dose.type == .tempBasal else {
                return ([], false)
            }

            if dose.type == .tempBasal, MedtrumPumpManager.statusPredatesCommand(
                of: dose.snapshot, receivedAt: receivedAt, receivedUptime: receivedUptime
            ) {
                logger.warning("Status received at \(receivedAt) shows a suspend, from before the temp basal of \(dose.startDate)")
                return nil
            }

            let eventTime = patchTime.map {
                pumpManager.suspendOnOurClock(of: dose, patchTime: $0, notAfter: receivedAt)
            } ?? max(receivedAt, MedtrumPumpManager.earliestAfter(dose))

            let suspendDose = UnfinalizedDose(suspendStartTime: eventTime)
            let suspended = NewPumpEvent.suspend(dose: suspendDose.toDoseEntry())
            // The suspend segment shown names the newest record too, as the scheduled one does (`resumeSchedule`). With no
            // record named - the status cut short, or without storage, in a halted state - the next status names it.
            let lastRecord = storage.map { Int($0.sequence) } ?? (basalIsCurrent ? basal.map { Int($0.sequence) } : nil)
            let ending = pumpManager.beginTempBasalEnd(
                endedAt: eventTime,
                patchEnd: patchTime,
                lastRecord: lastRecord,
                awaitsRecordAfter: lastRecord == nil ? receivedUptime : nil,
                then: (suspendDose, suspended)
            )
            state.basalDose = suspendDose

            if ending {
                return ([], true)
            }
            // The temp basal whose command went unanswered may have its record to read first
            if pumpManager.holdForUnconfirmedRead(suspendDose) {
                return ([], false)
            }
            // The temp basal a command ended still read - a cancel's, in the command: behind its final, with what the
            // command started, not taking it out from our estimate. Its read reports them, as for a resume
            // (`resumeSchedule`).
            if pumpManager.holdBehindTempBasalEnd((suspendDose, suspended)) {
                return ([], true)
            }
            // Out again with every batch until the host has it (`MedtrumPumpManager.keepUntilStored`)
            pumpManager.keepUntilStored(suspendDose)
            return ([suspended], false)
        }
    }

    /// The patch runs its schedule since the segment `basal` started: a temp basal of ours ends there - reported final
    /// with the scheduled basal once its records up to the one `basal` names, the newest, are read - a suspend is
    /// resumed there - on our clock, bounded to [the dose's start, when this was received]. Nil when this status says
    /// nothing of the temp basal running: received before its command went out, a segment that started no later than it
    /// - the cancel before it, shown after it started - or the scheduled basal of a cancel of it a command has in flight,
    /// which reports what follows it.
    private static func resumeSchedule(
        pumpManager: MedtrumPumpManager,
        basal: BasalData,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> (events: [NewPumpEvent], endedTempBasal: Bool)? {
        pumpManager.withDoseReportLock { () -> (events: [NewPumpEvent], endedTempBasal: Bool)? in
            let state = pumpManager.state
            let dose = state.basalDose

            // No session: whichever patch this is, nothing of ours runs on it. Only the activation resumes delivery
            // (`MedtrumPumpManager.startPatchSession`) - a resume here would stand over the session's suspend, the old
            // patch's schedule counted as delivered, or the new patch's ahead of its session. Whatever let it through.
            guard !state.patchSessionEnded else {
                logger.info("Status shows the scheduled basal since \(basal.startTime), no session runs: nothing resumed")
                return nil
            }

            switch dose.type {
            case .tempBasal:
                let running = dose.snapshot
                if MedtrumPumpManager.statusPredatesCommand(of: running, receivedAt: receivedAt, receivedUptime: receivedUptime) {
                    logger.warning(
                        "Status received at \(receivedAt) shows the scheduled basal, from before the command of the temp " +
                            "basal of \(dose.startDate) went out: not ending it"
                    )
                    return nil
                }

                if pumpManager.isCancelInFlight(of: dose) {
                    logger.info(
                        "Status shows the scheduled basal since \(basal.startTime), the cancel of the temp basal of " +
                            "\(dose.startDate) in flight: the command reports what follows it, set aside should the cancel fail"
                    )
                    pumpManager.setAsideForTheCancel(basal, receivedAt: receivedAt, receivedUptime: receivedUptime)
                    return nil
                }

                if let pumpStartTime = running.pumpStartTime, basal.startTime <= pumpStartTime {
                    logger.warning(
                        "Status shows the scheduled basal since \(basal.startTime), no later than the temp basal of " +
                            "\(dose.startDate) started (\(pumpStartTime)): not ending it"
                    )
                    return nil
                }

                // A temp basal was running - it ended. Back to scheduled basal.
                let endedAt = pumpManager.endOnOurClock(of: dose, patchTime: basal.startTime, notAfter: receivedAt)
                let basalDose = UnfinalizedDose(
                    basalRate: state.currentBaseBasalRate,
                    insulinType: state.insulinType,
                    startDate: endedAt
                )
                // Where its segment began on the patch clock - what a temp basal after it is told from, skew-free - where that
                // is the same instant as its start on ours
                if let paired = pumpManager.patchTimePaired(with: endedAt, endOf: dose, at: basal.startTime) {
                    basalDose.setPumpStartTime(paired)
                }
                let scheduled = NewPumpEvent.basal(dose: basalDose.toDoseEntry())
                let ending = pumpManager.beginTempBasalEnd(
                    endedAt: endedAt,
                    patchEnd: basal.startTime,
                    lastRecord: Int(basal.sequence),
                    then: (basalDose, scheduled)
                )
                state.basalDose = basalDose

                return ending ? ([], true) : ([scheduled], false)

            case .suspend:
                // Delivery was suspended - report the resume. The suspend is already finalized - or held back, and the
                // resume with it: never out ahead of it (`MedtrumPumpManager.holdWithHeldSuspend`). In a later second
                // than it at the earliest (`MedtrumPumpManager.earliestResume`).
                let resumeDose = UnfinalizedDose(
                    resumeStartTime: pumpManager.patchTimeOnOurClock(
                        basal.startTime,
                        notBefore: MedtrumPumpManager.earliestResume(after: dose.startDate),
                        notAfter: receivedAt
                    ),
                    insulinType: state.insulinType
                )
                state.basalDose = resumeDose

                if pumpManager.holdWithHeldSuspend(resumeDose) {
                    return ([], false)
                }
                let resumed = NewPumpEvent.resume(dose: resumeDose.toDoseEntry())
                // The temp basal the suspend ended still read - the first status after a restart during that read, say:
                // behind its final, with the suspend, not taking it out from our estimate. Its read reports them.
                if pumpManager.holdBehindTempBasalEnd((resumeDose, resumed)) {
                    return ([], true)
                }
                // Out again with every batch until the host has it (`MedtrumPumpManager.keepUntilStored`)
                pumpManager.keepUntilStored(resumeDose)
                return ([resumed], false)

            default:
                return ([], false)
            }
        }
    }

    /// No session runs, and the status, in a running state, is the previous patch's: its id, as storage and basal carry it,
    /// the low two bytes. Or it can't be told from the next one's - it names no id, or the previous patch's id is not
    /// known (a session started by a retried activation, ended before a status named it) - and since the session's
    /// suspend nothing of a next patch was heard: no setup state of it, no running state taken as its. The next patch is
    /// set up on this host - primed before its activation, from a state the connect syncs - so a patch running with none
    /// of that seen is the old one, forced out and still on the base. A status naming another id than a known previous
    /// one is the new patch's, its activation's answer lost: taken as before.
    static func isEndedSessionsPatchRunning(syncResponse: SynchronizePacketResponse, state: MedtrumPumpState) -> Bool {
        guard state.patchSessionEnded, syncResponse.state.isRunning else {
            return false
        }
        let ids = [syncResponse.storage?.patchId, syncResponse.basal?.patchId].compactMap { $0 }.map { UInt64($0) & 0xFFFF }
        let previous = state.previousPatch.flatMap { $0.patchId.isEmpty ? nil : $0.patchId.toUInt64() & 0xFFFF }
        if let previous, ids.contains(previous) {
            return true
        }

        // A first patch has no suspend of a session before it
        guard state.basalDose.type == .suspend, ids.isEmpty || previous == nil else {
            return false
        }
        return !isNextPatchSeen(state.pumpState)
    }

    /// No session runs, an activation went out since it ended (`MedtrumPumpState.activationSentAt`), and the status - taken,
    /// not the previous patch's (`isEndedSessionsPatchRunning`) - shows a patch running under an id, storage's or basal's,
    /// other than the previous patch's: the new one, activated, its answer lost. Its session starts on its own. Naming no
    /// id, it can't be told from the old one's: the next status naming one, or a retried activation, tells. With no
    /// activation sent, a running patch never starts a session.
    static func showsActivatedPatch(syncResponse: SynchronizePacketResponse, state: MedtrumPumpState) -> Bool {
        guard state.patchSessionEnded, state.activationSentAt != nil, syncResponse.state.isRunning,
              !syncResponse.invalidPayload, !syncResponse.truncated
        else {
            return false
        }
        let ids = [syncResponse.storage?.patchId, syncResponse.basal?.patchId].compactMap { $0 }.map { UInt64($0) & 0xFFFF }
        let previous = state.previousPatch.flatMap { $0.patchId.isEmpty ? nil : $0.patchId.toUInt64() & 0xFFFF }
        return !ids.isEmpty && (previous.map { !ids.contains($0) } ?? true)
    }

    /// What a patch since the session's end - whose state replaced the `.none` the end left - showed of a next patch: a
    /// setup state past the base's own, or a running state already taken as its
    private static func isNextPatchSeen(_ pumpState: PatchState) -> Bool {
        pumpState.isRunning || (pumpState.isSetup && pumpState != .none && pumpState != .idle)
    }

    enum BaseResetCheck {
        case noReset
        case reset
        case unconfirmed
    }

    /// An activated patch never goes back to a setup state on its own: when it does, the base has
    /// rebooted and came back as a blank patch - with a new patch id, its age and sequence restarted,
    /// and no delivery. Not a patch whose session ended: the state the old one reported after it, as it
    /// stopped, is followed by the new one's setup.
    static func baseResetCheck(syncResponse: SynchronizePacketResponse, state: MedtrumPumpState) -> BaseResetCheck {
        // No session, its suspend standing: nothing delivering for us to end - whatever the patch last heard from showed.
        // So a real reset of the base in the window after a lost activation answer - the new patch running, its session
        // not started - goes unalerted: harmless to the doses, the suspend standing and nothing resumed over it until an
        // activation starts a session.
        guard !state.pumpState.isSetup, syncResponse.state.isSetup,
              !state.stoppedWithNoSession, !(state.patchSessionEnded && state.basalDose.type == .suspend)
        else {
            return .noReset
        }

        guard syncResponse.state == .none else {
            return .reset
        }

        guard let storage = syncResponse.storage, !state.patchId.isEmpty else {
            return .unconfirmed
        }

        return UInt64(storage.patchId) != state.patchId.toUInt64() ? .reset : .unconfirmed
    }

    /// The base counts the patch age from its boot, which is when delivery stopped - unless we have
    /// heard from the activated patch after that
    static func deliveryStoppedAt(
        syncResponse: SynchronizePacketResponse,
        state: MedtrumPumpState,
        receivedAt: Date
    ) -> Date {
        guard let patchAge = syncResponse.patchAge else {
            return receivedAt
        }

        let bootedAt = receivedAt.addingTimeInterval(-TimeInterval(patchAge))
        return min(max(bootedAt, state.lastSync), receivedAt)
    }

    public static func fetchPatchTimeIfStale(pumpManager: MedtrumPumpManager) {
        let age = Date.now.timeIntervalSince(pumpManager.state.pumpTimeSyncedAt)
        guard age > MedtrumPumpManager.patchTimeRefreshInterval else {
            return
        }

        // Between commands, not ahead of the records one reads - waiting for them, which take no longer meanwhile than
        // with a command waiting (`betweenCommands` counts the wait)
        _ = pumpManager.betweenCommands {
            fetchPatchTime(pumpManager: pumpManager)
        }
    }

    public static func fetchPatchTime(pumpManager: MedtrumPumpManager) {
        let timeData = pumpManager.link.write(GetTimePacket())

        switch timeData {
        case let .failure(error: error):
            logger.warning("Failed to get current Patch time: \(error.errorDescription)")
            return
        case let .success(data: data):
            guard let timeResponse = data as? GetTimePacketResponse else {
                logger.error("Failed to get time: invalid response")
                return
            }

            pumpManager.state.pumpTime = timeResponse.time
            pumpManager.state.pumpTimeSyncedAt = Date.now
            pumpManager.notifyStateDidChange()
        }
    }

    public static func syncTime(pumpManager: MedtrumPumpManager) {
        let timeData = pumpManager.link.write(SetTimePacket(date: Date.now))
        switch timeData {
        case let .failure(error: error):
            logger.error("Failed to sync time: \(error.errorDescription)")
            return
        default:
            break
        }

        let timeZonePacket = SetTimeZonePacket(date: Date.now, timeZone: TimeZone.current)
        let timeZoneData = pumpManager.link.write(timeZonePacket)
        switch timeZoneData {
        case let .failure(error: error):
            logger.error("Failed to sync timezone: \(error.errorDescription)")
            return
        default:
            // Patch-local midnight is on it - see `MedtrumPumpManager.crossesPatchMidnight`
            pumpManager.state.patchUTCOffset = timeZonePacket.utcOffset
            StateSyncer.fetchPatchTime(pumpManager: pumpManager)
        }
    }

    private static func updatePumpState(syncResponse: SynchronizePacketResponse, pumpManager: MedtrumPumpManager, receivedAt: Date) {
        let previousState = pumpManager.state.pumpState
        pumpManager.state.pumpState = syncResponse.state
        if !syncResponse.state.isDelivering {
            pumpManager.state.lastShownNotDeliveringAt = receivedAt
        }

        guard syncResponse.state != previousState else {
            return
        }

        // Send notification for specific states
        switch syncResponse.state {
        case .dailyMaxSuspended:
            pumpManager.emitAlert(alertType: .patchDailyMaxNotification)
        case .hourlyMaxSuspended:
            pumpManager.emitAlert(alertType: .patchHourlyMaxNotification)
        case .occlusion:
            pumpManager.retractBolusStallAlerts(because: "the patch raised an occlusion")
            pumpManager.emitAlert(alertType: .occlusionNotification)
        case .baseFault,
             .patchFault,
             .patchFaultd2:
            pumpManager.retractBolusStallAlerts(because: "the patch raised a fault")
            pumpManager.emitAlert(alertType: .patchFaultNotification)
        case .reservoirEmpty:
            pumpManager.retractBolusStallAlerts(because: "the patch raised its reservoir empty")
            pumpManager.emitAlert(alertType: .reservoirEmptyNotification)
        default:
            break
        }
    }
}

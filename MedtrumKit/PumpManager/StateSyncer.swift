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
            return

        case .unconfirmed:
            // `.none` is also what an unknown state byte parses to, don't drop an activated patch over it
            logger.warning("Activated patch reported state none without a new patch id, ignoring")
            return

        case .noReset:
            break
        }

        // No session: the id kept can be stale - the previous patch's, or one never started - and would reject the new
        // patch's payloads. The storage gate below decides which id to keep then.
        let expectedPatchId = state.patchSessionEnded ? 0 : state.patchId.toUInt64()
        let syncResponse = syncResponse.validated(expectedPatchId: expectedPatchId)

        StateSyncer.updatePumpState(syncResponse: syncResponse, pumpManager: pumpManager)

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
                pumpManager.recordStore.clear()
                state.lastSegmentStart = nil
            }

            state.currentSequenceNumber = max(state.currentSequenceNumber, Int(storage.sequence))
            // The newest record the patch has written, as it says
            if Int(storage.sequence) >= state.currentSequenceNumber {
                pumpManager.noteRecordSequenceConfirmed(receivedAt: syncResponse.receivedAt)
            }
        }

        if let basal = syncResponse.basal {
            state.currentSequenceNumber = max(state.currentSequenceNumber, Int(basal.sequence))
        }

        // A status received before the command of the dose it is checked against says nothing of that dose - see
        // `MedtrumPumpManager.statusPredatesCommand`
        let receivedAt = syncResponse.receivedAt
        let receivedUptime = syncResponse.receivedUptime

        var events: [NewPumpEvent] = []
        if syncResponse.state.isDeliveryHalted {
            // a halted state is authoritative even when the notification carries a cached basal.
            if let suspended = recordSuspendIfDelivering(
                pumpManager: pumpManager,
                basal: syncResponse.basal,
                suspendTime: syncResponse.suspendTime,
                receivedAt: receivedAt,
                receivedUptime: receivedUptime
            ) {
                events.append(contentsOf: suspended)
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
                // written, and the running segment is only numbered once it ends
                state.basalState = .tempBasal
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
                    suspendTime: syncResponse.suspendTime,
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                ) {
                    events.append(contentsOf: suspended)
                    state.basalState = .suspended
                }

            default:
                // One begun before the unconfirmed temp basal's command - or seen before it went out - says nothing of
                // whether the patch runs it: the next temp basal still cancels first
                let endsUnconfirmed = pumpManager.noteSegmentAfterUnconfirmedTempBasal(
                    startingAt: basal.startTime,
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                )

                // The patch is delivering on its schedule again, since the start of the segment it shows. Nil: this
                // status says nothing of the basal running, which stays as it is.
                if let resumed = resumeSchedule(
                    pumpManager: pumpManager,
                    basal: basal,
                    receivedAt: receivedAt,
                    receivedUptime: receivedUptime
                ) {
                    events.append(contentsOf: resumed)
                    if endsUnconfirmed {
                        state.basalState = .active
                    }
                }
            }
        }

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
                pumpManager.raiseCancelledBolus(delivered: bolus.delivered)
            }
        }

        // A status that failed validation, or came in cut short, shows nothing - not that no bolus is delivering, nor
        // that we are in touch with the patch
        let isUsable = !syncResponse.invalidPayload && !syncResponse.truncated

        // A full status past the running bolus's deadline, showing no bolus delivering: we lost its end
        if fullSync, isUsable, syncResponse.bolus?.completed != false {
            pumpManager.checkBolusDone(receivedAt: receivedAt, receivedUptime: receivedUptime)
        }

        if (fullSync && isUsable) || !events.isEmpty {
            if isUsable {
                pumpManager.state.lastSync = syncDate
            }
            pumpManager.emitPumpEvents(events)
        }

        pumpManager.notifyStateDidChange()
    }

    /// The patch stopped delivering: the running basal ends, and the suspend starts, when the patch says it suspended
    /// (`suspendTime`, exact on its clock), or when a suspend segment started - else when this was received. A suspend
    /// ends a temp basal for good: the patch resumes on its schedule. Nil when this status says nothing of the basal
    /// running - received before the running temp basal's command went out - so the caller leaves the basal state as
    /// it is: marking it suspended would refuse dosing with nothing suspended as far as the doses go.
    private static func recordSuspendIfDelivering(
        pumpManager: MedtrumPumpManager,
        basal: BasalData?,
        suspendTime: Date?,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> [NewPumpEvent]? {
        let patchTime = suspendTime ?? basal.flatMap { $0.type.isSuspendedByPump() ? $0.startTime : nil }

        return pumpManager.withDoseReportLock { () -> [NewPumpEvent]? in
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
                return []
            }

            if dose.type == .tempBasal, MedtrumPumpManager.statusPredatesCommand(
                of: dose.snapshot, receivedAt: receivedAt, receivedUptime: receivedUptime
            ) {
                logger.warning("Status received at \(receivedAt) shows a suspend, from before the temp basal of \(dose.startDate)")
                return nil
            }

            let eventTime = patchTime.map {
                pumpManager.patchTimeOnOurClock($0, notBefore: dose.startDate, notAfter: receivedAt)
            } ?? receivedAt

            var events = pumpManager.endTempBasal(endedAt: eventTime)
            state.basalDose = UnfinalizedDose(suspendStartTime: eventTime)
            events.insert(NewPumpEvent.suspend(dose: state.basalDose.toDoseEntry()), at: 0)

            return events
        }
    }

    /// The patch runs its schedule since the segment `basal` started: a temp basal of ours ends there, a suspend is
    /// resumed there - on our clock, bounded to [the dose's start, when this was received]. Nil when this status says
    /// nothing of the temp basal running: received before its command went out, or a segment that started no later
    /// than it - the cancel before it, shown after it started.
    private static func resumeSchedule(
        pumpManager: MedtrumPumpManager,
        basal: BasalData,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> [NewPumpEvent]? {
        pumpManager.withDoseReportLock { () -> [NewPumpEvent]? in
            let state = pumpManager.state
            let dose = state.basalDose

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

                if let pumpStartTime = running.pumpStartTime, basal.startTime <= pumpStartTime {
                    logger.warning(
                        "Status shows the scheduled basal since \(basal.startTime), no later than the temp basal of " +
                            "\(dose.startDate) started (\(pumpStartTime)): not ending it"
                    )
                    return nil
                }

                // A temp basal was running - it ended, and waits for its record. Back to scheduled basal.
                let endedAt = pumpManager.patchTimeOnOurClock(basal.startTime, notBefore: dose.startDate, notAfter: receivedAt)
                let finishedTempBasal = pumpManager.endTempBasal(endedAt: endedAt)
                state.basalDose = UnfinalizedDose(
                    basalRate: state.currentBaseBasalRate,
                    insulinType: state.insulinType,
                    startDate: endedAt
                )

                return [NewPumpEvent.basal(dose: state.basalDose.toDoseEntry())] + finishedTempBasal

            case .suspend:
                // Delivery was suspended - report the resume. The suspend is already finalized.
                state.basalDose = UnfinalizedDose(
                    resumeStartTime: pumpManager.patchTimeOnOurClock(basal.startTime, notBefore: dose.startDate, notAfter: receivedAt),
                    insulinType: state.insulinType
                )

                return [NewPumpEvent.resume(dose: state.basalDose.toDoseEntry())]

            default:
                return []
            }
        }
    }

    enum BaseResetCheck {
        case noReset
        case reset
        case unconfirmed
    }

    /// An activated patch never goes back to a setup state on its own: when it does, the base has
    /// rebooted and came back as a blank patch - with a new patch id, its age and sequence restarted,
    /// and no delivery.
    static func baseResetCheck(syncResponse: SynchronizePacketResponse, state: MedtrumPumpState) -> BaseResetCheck {
        // No session: the old patch, stopped, is still reported until the new one is set up - that setup is no reset
        guard !state.pumpState.isSetup, syncResponse.state.isSetup,
              !(state.patchSessionEnded && state.pumpState.isTerminated)
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

        fetchPatchTime(pumpManager: pumpManager)
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

    private static func updatePumpState(syncResponse: SynchronizePacketResponse, pumpManager: MedtrumPumpManager) {
        let previousState = pumpManager.state.pumpState
        pumpManager.state.pumpState = syncResponse.state

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
            pumpManager.emitAlert(alertType: .occlusionNotification)
        case .baseFault,
             .patchFault,
             .patchFaultd2:
            pumpManager.emitAlert(alertType: .patchFaultNotification)
        case .reservoirEmpty:
            pumpManager.emitAlert(alertType: .reservoirEmptyNotification)
        default:
            break
        }
    }
}

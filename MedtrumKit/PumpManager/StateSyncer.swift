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
        let syncResponse = syncResponse.validated(expectedPatchId: state.patchId.toUInt64())

        StateSyncer.updatePumpState(syncResponse: syncResponse, pumpManager: pumpManager)

        if let reservoir = syncResponse.reservoir {
            if let lowReservoirWarning = state.lowReservoirWarning,
               state.reservoir > lowReservoirWarning,
               reservoir < lowReservoirWarning
            {
                // Send low reservoir warning notification to user
                pumpManager.emitAlert(alertType: .lowReservoir(level: reservoir))
            }

            if state.reservoir != reservoir {
                state.reservoir = reservoir
                if state.initialReservoir == nil {
                    state.initialReservoir = state.reservoir
                }

                if fullSync {
                    // to prevent spaming the OSAID app with reservoir updates
                    pumpManager.emitReservoirLevel()
                }
            }
        }

        var events: [NewPumpEvent] = []
        if syncResponse.state.isDeliveryHalted {
            // a halted state is authoritative even when the notification carries a cached basal.
            events.append(contentsOf: recordSuspendIfDelivering(
                state: state, basal: syncResponse.basal, receivedAt: syncDate
            ))
            state.basalState = .suspended
        } else if let basal = syncResponse.basal {
            switch basal.type {
            case .ABSOLUTE_TEMP,
                 .RELATIVE_TEMP:
                state.basalState = .tempBasal

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
                events.append(contentsOf: recordSuspendIfDelivering(
                    state: state, basal: basal, receivedAt: syncDate
                ))
                state.basalState = .suspended

            default:
                // The patch is delivering on its schedule again
                let eventTime = syncDate

                switch state.basalDose.type {
                case .tempBasal:
                    // A temp basal was running - finalize it, and go back to scheduled basal
                    let finishedTempBasal = state.basalDose.toDoseEntry(isMutable: false, endDate: eventTime)
                    state.basalDose = UnfinalizedDose(
                        basalRate: state.currentBaseBasalRate,
                        insulinType: state.insulinType
                    )

                    events.append(NewPumpEvent.basal(dose: state.basalDose.toDoseEntry()))
                    // Record finalized temp basal, the scheduled basal above is already finalized
                    events.append(NewPumpEvent.tempBasal(dose: finishedTempBasal))

                case .suspend:
                    // Delivery was suspended - report the resume. The suspend is already finalized.
                    state.basalDose = UnfinalizedDose(
                        resumeStartTime: eventTime,
                        insulinType: state.insulinType
                    )

                    events.append(NewPumpEvent.resume(dose: state.basalDose.toDoseEntry()))

                default:
                    break
                }

                state.basalState = .active
            }
        }

        if let prime = syncResponse.primeProgress {
            state.primeProgress = prime
        }

        if let battery = syncResponse.battery {
            state.battery = battery.voltageB
        }

        if let startTime = syncResponse.startTime {
            state.patchActivatedAt = startTime
        }

        if let storage = syncResponse.storage {
            state.patchId = UInt64(storage.patchId).toData(length: 4)
        }

        if let bolusProgress = syncResponse.bolus {
            pumpManager.updateBolusProgress(
                delivered: bolusProgress.delivered,
                completed: bolusProgress.completed,
                useEstimatedEndDate: duringReconnect
            )
        } else if duringReconnect {
            pumpManager.checkBolusDone()
        }

        if fullSync || !events.isEmpty {
            pumpManager.state.lastSync = syncDate
            pumpManager.emitPumpEvents(events)
        }

        pumpManager.notifyStateDidChange()
    }

    private static func recordSuspendIfDelivering(
        state: MedtrumPumpState,
        basal: BasalData?,
        receivedAt: Date
    ) -> [NewPumpEvent] {
        guard state.basalDose.type == .basal || state.basalDose.type == .resume || state.basalDose.type == .tempBasal
        else {
            return []
        }

        var events: [NewPumpEvent] = []
        // accurate time would require pump-history reconciliation
        let eventTime: Date
        if let basal = basal,
           basal.type.isSuspendedByPump(),
           basal.startTime >= state.basalDose.startDate,
           basal.startTime <= receivedAt
        {
            eventTime = basal.startTime
        } else {
            eventTime = receivedAt
        }
        let dose = state.basalDose.toDoseEntry(isMutable: false, endDate: eventTime)
        state.basalDose = UnfinalizedDose(suspendStartTime: eventTime)

        events.append(NewPumpEvent.suspend(dose: state.basalDose.toDoseEntry()))
        if dose.type == .tempBasal {
            events.append(NewPumpEvent.tempBasal(dose: dose))
        }

        return events
    }

    public static func fetchPatchTimeIfStale(pumpManager: MedtrumPumpManager) {
        let age = Date.now.timeIntervalSince(pumpManager.state.pumpTimeSyncedAt)
        guard age > MedtrumPumpManager.patchTimeRefreshInterval else {
            return
        }

        fetchPatchTime(pumpManager: pumpManager)
    }

    public static func fetchPatchTime(pumpManager: MedtrumPumpManager) {
        let timeData = pumpManager.bluetooth.write(GetTimePacket())

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
        let timeData = pumpManager.bluetooth.write(SetTimePacket(date: Date.now))
        switch timeData {
        case let .failure(error: error):
            logger.error("Failed to sync time: \(error.errorDescription)")
            return
        default:
            break
        }

        let timeZoneData = pumpManager.bluetooth.write(
            SetTimeZonePacket(date: Date.now, timeZone: TimeZone.current)
        )
        switch timeZoneData {
        case let .failure(error: error):
            logger.error("Failed to sync timezone: \(error.errorDescription)")
            return
        default:
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

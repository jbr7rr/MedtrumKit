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
        if fullSync {
            pumpManager.state.lastSync = Date.now
        }

        StateSyncer.updatePumpState(syncResponse: syncResponse, state: state)

        // When the patch permanently ends (occlusion / expired / reservoir empty /
        // fault / battery out / stopped - i.e. >= occlusion), back up and clear the
        // session token so the next patch starts with a fresh one. The old token
        // stays recoverable via restore-on-auth-failure. NOTE: this must NOT fire
        // on suspends/paused (64-70) or transient activation states (ejecting/
        // ejected) - those keep their token.
        if SessionTokenPolicy.isTerminal(syncResponse.state) {
            pumpManager.backupAndClearSessionToken(reason: "patch terminal: \(syncResponse.state.description)")
        }

        if let reservoir = syncResponse.reservoir {
            if let lowReservoirWarning = state.lowReservoirWarning,
               state.reservoir > lowReservoirWarning,
               reservoir < lowReservoirWarning
            {
                // Send low reservoir warning notification to user
                NotificationManager.reservoirLowNotification(reservoir)
            }

            state.reservoir = reservoir
            if state.initialReservoir == nil {
                state.initialReservoir = state.reservoir
            }

            if fullSync {
                // to prevent spaming the OSAID app with reservoir updates
                pumpManager.emitReservoirLevel()
            }
        }

        if let basal = syncResponse.basal {
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
                if state.basalDose.type == .basal || state.basalDose.type == .resume || state.basalDose.type == .tempBasal {
                    // Patch unexpectedly suspended itself
                    let eventTime = Date.now
                    let dose = state.basalDose.toDoseEntry(isMutable: false, endDate: eventTime)
                    state.basalDose = UnfinalizedDose(suspendStartTime: eventTime)
                    let basalDose = state.basalDose.toDoseEntry()

                    var events: [NewPumpEvent] = [NewPumpEvent.basal(dose: basalDose, date: basalDose.startDate)]
                    if dose.type == .tempBasal {
                        // Record finalized temp basal, resume/basal is already finalized
                        events.append(NewPumpEvent.tempBasal(dose: dose, date: dose.startDate))
                    }

                    pumpManager.emitPumpEvents(events)
                    pumpManager.notifyStateDidChange()
                }

                state.basalState = .suspended

            default:
                if state.basalDose.type == .suspend || state.basalDose.type == .tempBasal {
                    // unfinalized dose is finalized!
                    let eventTime = Date.now
                    let dose = state.basalDose.toDoseEntry(isMutable: false, endDate: eventTime)
                    state.basalDose = dose.type == .tempBasal ?
                        UnfinalizedDose(
                            basalRate: state.currentBaseBasalRate,
                            insulinType: state.insulinType
                        ) :
                        UnfinalizedDose(
                            resumeStartTime: eventTime,
                            insulinType: state.insulinType
                        )

                    let basalDose = state.basalDose.toDoseEntry(isMutable: true)
                    var events: [NewPumpEvent] = [
                        basalDose.type == .resume ?
                            NewPumpEvent.resume(dose: basalDose, date: basalDose.startDate) :
                            NewPumpEvent.basal(dose: basalDose, date: basalDose.startDate)
                    ]
                    if dose.type == .tempBasal {
                        // Record finalized temp basal, suspend is already finalized
                        events.append(NewPumpEvent.tempBasal(dose: dose, date: dose.startDate))
                    }

                    pumpManager.emitPumpEvents(events)
                    pumpManager.notifyStateDidChange()
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
            pumpManager.state.bolusState = bolusProgress.completed ? .noBolus : .inProgress
        } else if duringReconnect {
            pumpManager.checkBolusDone()
        } else {
            pumpManager.state.bolusState = .noBolus
        }

        pumpManager.notifyStateDidChange()
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

    private static func updatePumpState(syncResponse: SynchronizePacketResponse, state: MedtrumPumpState) {
        state.pumpState = syncResponse.state

        // Send notification for specific states
        // If this has already been done, iOS will remove the old one
        switch syncResponse.state {
        case .dailyMaxSuspended:
            NotificationManager.patchDailyMaxNotification()
        case .hourlyMaxSuspended:
            NotificationManager.patchHourlyMaxNotification()
        case .occlusion:
            NotificationManager.occlusionNotification()
        case .baseFault,
             .patchFault,
             .patchFaultd2:
            NotificationManager.patchFaultNotification()
        case .reservoirEmpty:
            NotificationManager.reservoirEmptyNotification()
        default:
            break
        }
    }
}

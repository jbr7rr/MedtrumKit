import LoopKit

enum StateSyncer {
    static func sync(
        syncResponse: SynchronizePacketResponse,
        state: MedtrumPumpState,
        pumpManager: MedtrumPumpManager,
        duringReconnect: Bool
    ) {
        StateSyncer.updatePumpState(syncResponse: syncResponse, state: state)

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
        }

        if let basal = syncResponse.basal {
            switch basal.type {
            case .ABSOLUTE_TEMP,
                 .RELATIVE_TEMP:
                state.basalState = .tempBasal
                state.tempBasalUnits = basal.rate

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
                state.basalState = .suspended

            default:
                state.basalState = .active
                state.tempBasalUnits = nil
                state.tempBasalDuration = nil
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
        }

        pumpManager.notifyStateDidChange()
    }

    public static func timeSync(pumpManager: MedtrumPumpManager) async {
        let logger = MedtrumLogger(category: "TimeSync")
        let timeData = await pumpManager.bluetooth.write(GetTimePacket())

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

    public static func syncTime(pumpManager: MedtrumPumpManager) async {
        let logger = MedtrumLogger(category: "TimeSync")

        let timeData = await pumpManager.bluetooth.write(SetTimePacket(date: Date.now))
        switch timeData {
        case let .failure(error: error):
            logger.error("Failed to sync time: \(error.errorDescription)")
            return
        default:
            break
        }

        let timeZoneData = await pumpManager.bluetooth.write(
            SetTimeZonePacket(date: Date.now, timeZone: TimeZone.current)
        )
        switch timeZoneData {
        case let .failure(error: error):
            logger.error("Failed to sync timezone: \(error.errorDescription)")
            return
        default:
            await StateSyncer.timeSync(pumpManager: pumpManager)
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

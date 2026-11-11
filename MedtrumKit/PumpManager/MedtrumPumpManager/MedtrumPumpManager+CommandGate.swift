import LoopKit

public extension MedtrumPumpManager {
    /// Hands the state to the host, and waits until it has it - `stateHandOverTimeout` at most: a command is about to
    /// read the records of the temp basal it ended, a round trip or more on the link, and only then does the batch go
    /// out that saves the state with it - or to fail a bolus or a temp basal, which a kill after must not bring back.
    /// Best effort: a host slower than that is not waited for, and that is logged. Not holding `doseReportLock`, nor on
    /// the delegate queue.
    internal func handOverState(before action: String) {
        guard handOverState(until: .now() + Self.stateHandOverTimeout) else {
            log.warning("The host did not take the state within \(Int(Self.stateHandOverTimeout)) s, \(action) anyway")
            return
        }
    }

    /// Hands the state to the host, and waits until it has it - until `deadline` at most. Returns whether it did. Not
    /// holding `doseReportLock`, nor on the delegate queue.
    internal func handOverState(until deadline: DispatchTime) -> Bool {
        let handedOver = DispatchSemaphore(value: 0)
        pumpDelegate.notify { delegate in
            delegate?.pumpManagerDidUpdateState(self)
            handedOver.signal()
        }
        return handedOver.wait(timeout: deadline) == .success
    }

    /// Hands the state to the host with `dose`, a bolus or a temp basal, pending in it - about to be written - and waits
    /// until it has it, until `deadline` at most (`dosingHandOverTimeout`): a kill after the write, before the host saved
    /// the state with it pending, would leave the next run with no dose of it - its record matching nothing of ours,
    /// what it delivered missing at the host (device 2026-10-23 15:42, the host's queue stalled 80 s). Returns whether
    /// it is written.
    ///
    /// The host saves the state as it reads it (`rawState`), and only then is it done - its log, its status updates
    /// after (device: the stall was its logging). So past the deadline, under `doseReportLock`, which its read takes:
    /// read by the host with `dose` pending, it is on its way to its disk - the host writes what it read right after -
    /// and written all the same, logged. Not read: `notWritten` takes it off the state, in the same step - no read from
    /// then on has it pending - and the caller fails it, and logs it. Not on the delegate queue.
    internal func handOverPendingDose(_ dose: String, until deadline: DispatchTime, orElse notWritten: () -> Void) -> Bool {
        // How long it waits - the bound of the command, what is left of it - for the log
        let start = DispatchTime.now()
        let waits = deadline > start ? Double(deadline.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 : 0
        if handOverState(until: deadline) {
            return true
        }
        return doseReportLock.withLock { () -> Bool in
            guard pendingDoseHandedOut else {
                notWritten()
                return false
            }
            log.warning(
                "The host did not take the state within \(Int(waits.rounded())) s, but read it with \(dose) pending - " +
                    "saving it: written"
            )
            return true
        }
    }

    /// How long a command waits for the host to take the state before it reads records, or fails a bolus or a temp basal
    internal static let stateHandOverTimeout: TimeInterval = 3

    /// `isCommand`: counted as a command from here until `completion` returns, so a record sync neither starts nor
    /// carries on while it runs - see `isCommandActive` - and run holding `commandLock`, once connected. A failed connect
    /// is reported without it.
    /// A command is refused while no session runs, as in a setup state: the patch heard from running then is either the
    /// old one - forced out, its StopPatch lost, still on the base - or the new one, its activation's answer lost, until
    /// the retried activation starts its session. Neither takes a dose or a resume of ours. Priming, activating and
    /// stopping a patch don't come through here.
    internal func ensureConnectedAndActive(isCommand: Bool = true, _ completion: @escaping (MedtrumConnectError?) -> Void) {
        guard !state.pumpState.isSetup else {
            log.warning("No active patch, failing immediately")
            completion(.noActivePatch)
            return
        }

        guard !isCommand || !state.patchSessionEnded else {
            log.warning("No patch session runs, failing immediately: \(state.pumpState.description)")
            completion(.noActivePatch)
            return
        }

        let command = isCommand ? beginCommand() : nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                completion(.failedToFindDevice)
                return
            }

            self.link.ensureConnected { error in
                if let command {
                    self.commandConnected(command)
                }

                // Command bodies run synchronously inside the completion (their writes block)
                defer {
                    if let command {
                        self.endCommand(command)
                    }
                }

                // A connect that failed is reported at once, not once the operation holding the lock is over
                guard isCommand, error == nil else {
                    completion(error)
                    return
                }

                guard self.withCommandLock({
                    // Ended while it connected, or waited for the operation ahead of it - a deactivation, say
                    guard !self.state.patchSessionEnded else {
                        self.log.warning("The patch session ended before the command went out, failing it")
                        completion(.noActivePatch)
                        return
                    }
                    completion(error)
                }) else {
                    completion(.failedToConnectToDevice)
                    return
                }
            }
        }
    }

    /// Runs `body` holding `commandLock` - waiting for the operation holding it to end, as long as a command may take.
    /// Returns false, not having run it, if it does not end by then. Never on the queue answers or statuses arrive on.
    /// `waits`: counted as waiting meanwhile (`lockCommandLock`) - not the read of a temp basal's end, which the
    /// operation ahead of it may be doing itself.
    @discardableResult internal func withCommandLock(waits: Bool = true, _ body: () -> Void) -> Bool {
        guard lockCommandLock(waits: waits) else {
            return false
        }
        defer { commandLock.unlock() }

        body()
        return true
    }

    /// Takes `commandLock` as `withCommandLock` does - the caller unlocks it - for the commands that do not go through
    /// `ensureConnectedAndActive`: priming, activating and stopping a patch
    internal func lockCommandLock(waits: Bool = true) -> Bool {
        // Waiting: the records a temp basal's end has read meanwhile take no longer than with a command waiting
        let lock = { self.commandLock.lock(before: Date.now.addingTimeInterval(Self.commandActivityTimeout)) }
        guard waits ? whileTheLoopWaits(lock) : lock() else {
            log.error("Another operation has held the patch for \(Int(Self.commandActivityTimeout / 60)) min, giving up")
            return false
        }
        return true
    }

    /// Runs `body` holding `commandLock` if no other operation holds it - nil, not having run it, if one does
    internal func withCommandLockIfFree<T>(_ body: () -> T) -> T? {
        guard commandLock.try() else {
            return nil
        }
        defer { commandLock.unlock() }

        return body()
    }

    /// Runs `write` holding `commandLock` - a status or the patch time, asked for between commands: the records a command
    /// reads, a temp basal's it ended, are not held up by it, and it is answered after them. Nil, not having run it, if
    /// the operation holding the patch does not end as long as a command may take. Never on the queue answers or
    /// statuses arrive on.
    internal func betweenCommands<T>(_ write: () -> T) -> T? {
        guard lockCommandLock() else {
            return nil
        }
        defer { commandLock.unlock() }

        return write()
    }

    private func beginCommand() -> UUID {
        let command = UUID()
        let startedAt = Date.now
        activeCommands.mutate { commands in
            commands = commands.filter { startedAt.timeIntervalSince($0.value) < Self.commandActivityTimeout }
            commands[command] = startedAt
        }
        return command
    }

    /// The activity timeout counts from here: a slow reconnect must not use up the time of the command waiting on it
    private func commandConnected(_ command: UUID) {
        let connectedAt = Date.now
        activeCommands.mutate { commands in
            commands[command] = connectedAt
        }
    }

    private func endCommand(_ command: UUID) {
        activeCommands.mutate { commands in
            commands[command] = nil
        }
        lastCommandEndedAt.value = now()
    }

    /// A command ended within `openTempBasalEndReadDelay` of `checkedAt`: the loop's bolus right behind it has the link
    /// first. A wall clock set back since - the age negative - holds nothing off.
    internal func isRightAfterACommand(at checkedAt: Date) -> Bool {
        let age = checkedAt.timeIntervalSince(lastCommandEndedAt.value)
        return age >= 0 && age < openTempBasalEndReadDelay
    }

    /// A command is between asking to connect and its last response. The record sync yields to it: its reads share
    /// the link, and would hold up a bolus or temp basal for as long as they take.
    internal var isCommandActive: Bool {
        let checkedAt = Date.now
        return activeCommands.value.contains { checkedAt.timeIntervalSince($0.value) < Self.commandActivityTimeout }
    }

    internal func handlePumpDelegateError(method: String, _ error: Error, _ function: String = #function, _ line: Int = #line) {
        let logLine = "Received pump delegate error in \(method): \(error) at \(function):\(line)"
        log.error(logLine)
        logDeviceCommunication(logLine, type: .error)
    }

    internal func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        // Not dispatching here; if delegate queue is blocked, timestamps will be delayed
        pumpManagerDelegate?.deviceManager(
            self,
            logEventForDeviceIdentifier: logDeviceIdentifier,
            type: type,
            message: message,
            completion: nil
        )
    }

    /// Something waits for the link (`loopWaits`). One waiting `loopWaitExpiry` or longer is dropped, with a warning.
    internal var isLoopWaiting: Bool {
        let checkedAt = Date.now
        var expired = 0
        let waits = loopWaits.mutate { waits in
            let before = waits.count
            waits = waits.filter { checkedAt.timeIntervalSince($0.value) < Self.loopWaitExpiry }
            expired = before - waits.count
        }
        if expired > 0 {
            log.warning("\(expired) wait(s) for the link not over within \(Int(Self.loopWaitExpiry)) s, no longer counted")
        }
        return !waits.isEmpty
    }

    /// See `loopWaits`: as long as a command may take. Only tests change it.
    internal static var loopWaitExpiry: TimeInterval = commandActivityTimeout

    /// Runs `body` - the loop's sync, a patch time fetch, waiting for the link - counted in `loopWaits` meanwhile: a
    /// temp basal's records read as it ends take no longer than `tempBasalEndReadBudget` - the loop's background task
    /// is some 30 s, and iAPS waits on the sync with no timeout of its own
    internal func whileTheLoopWaits<T>(_ body: () -> T) -> T {
        let waiting = loopBeginsWaiting()
        defer { loopWaits.mutate { $0[waiting] = nil } }
        return body()
    }

    /// The loop's sync begins waiting for the link (`whileTheLoopWaits`) - until `loopHearsBack` with the token returned
    internal func loopBeginsWaiting() -> UUID {
        let waiting = UUID()
        let beganAt = Date.now
        loopWaits.mutate { $0[waiting] = beganAt }
        return waiting
    }

    /// The loop's sync of `waiting` is answered: no longer waiting
    internal func loopHearsBack(_ waiting: UUID, _ date: Date?, _ completion: ((Date?) -> Void)?) {
        loopWaits.mutate { $0[waiting] = nil }
        completion?(date)
    }
}

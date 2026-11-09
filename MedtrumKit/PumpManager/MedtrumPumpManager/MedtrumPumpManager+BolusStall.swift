import LoopKit

/// What the stall check keeps of the running bolus beyond its dose - whose last step, `UnfinalizedDose.State.lastProgressAt`
/// on the monotonic clock, it judges from - see `MedtrumPumpManager.checkBolusStall`. Never saved: after a restart nothing
/// is judged until the patch is heard from again. Only under `doseReportLock`.
struct BolusStallWatch {
    /// The bolus watched
    let dose: UnfinalizedDose
    /// From when its progress is judged, on the monotonic clock: the answer to its command, or the first usable status
    /// since the app started or the link came back. What came before says nothing of the bolus.
    var judgedFrom: TimeInterval
    /// When the last usable status came in - or the answer - on the monotonic clock: a silence longer than
    /// `bolusLinkSilence` is the link's, not the bolus's
    var lastHeardAt: TimeInterval
    /// Usable statuses since the last step, for the log
    var statusesSinceStep = 0
    /// The longest gap a step closed, judged
    var longestGap: TimeInterval = 0
    /// Warned of: in this run, or in one before - as its note says (`UncertainDelivery.stalledFor`)
    var stalled: Bool
    /// Steps at the patch's pace in a row since it stalled, its completion the last: `bolusStallResumeSteps` of them,
    /// and it was delivered slowly rather than stalled
    var stepsAtPaceSinceStall = 0
    /// The patch raised its own alarm, or its session ended: not judged from here on - see `retractBolusStallAlerts`
    var silenced = false
}

/// Warns when a running bolus stops advancing while the patch keeps answering - a possible occlusion the patch has not
/// raised (tomacs, jbr7rr/MedtrumKit#224). Against a blocked cannula the patch stretches its pulses about tenfold - one
/// 0.1 U step every 25-40 s instead of every 4-8 s - keeps counting, reports the full amount delivered, and records it so;
/// its own occlusion alarm comes minutes after the bolus "completed", or not at all (2026-10-13: 5 U, stalled at 3.5 U,
/// the alarm 205 s after its completion). The time since the last step is the earliest sign.
///
/// A warning only: nothing the bolus counts as changes - a false one must not cut insulin that is needed, and its record
/// would not tell either. Noted in the uncertain deliveries, for the settings screen.
extension MedtrumPumpManager {
    /// No step for longer than this while the patch keeps answering: stalled. 7,550 step intervals of 1,456 boluses in
    /// the user's logs (June-November 2026): p99 8.8 s, the longest 17.0 s - a step displaced by a full status or a
    /// notification in between; the longest silence before the first step, between steps or before the completion of
    /// a bolus judged, 17.0 s. The stall of 2026-10-13: 40, 38, 36, 34, ... s.
    static let bolusStallThreshold: TimeInterval = 25

    /// A gap closed above this is logged, for tuning the threshold; a step closing one at most this long is at the patch's
    /// pace
    static let bolusSlowStepGap: TimeInterval = MedtrumPumpManager.bolusStallThreshold / 2

    /// A smaller bolus is not judged: it is done before it could stall visibly. The slowest patch's own pace is 8.2 s a
    /// step of 0.1 U (the slowest bolus's median interval, 0.73 U/min): 0.3 U is done in 24.6 s, under the threshold.
    /// Leaves most SMBs out (1,657 of 2,765 boluses in the logs), whose completion can come well after their last step.
    static let bolusStallMinimumUnits = 0.35

    /// Steps at the patch's pace in a row - the completion the last - after which a stalled bolus that completed in full
    /// was delivered slowly: its warning is retracted
    static let bolusStallResumeSteps = 3

    /// No usable status for longer than this: the link was gone, not the bolus - judged from the next status on. While a
    /// bolus ran on a working link the patch was never silent longer than 14.3 s; the stall's steps came 40 s apart at
    /// most, with nothing in between where the patch sends only its steps - as it does in 2 of 3 boluses.
    static let bolusLinkSilence: TimeInterval = 60

    /// `dose`, just registered, its command answered at `answeredUptime` on the monotonic clock: judged from there. Only
    /// under `doseReportLock`.
    internal func startBolusStallWatch(_ dose: UnfinalizedDose, answeredUptime: TimeInterval) {
        bolusStallWatch = BolusStallWatch(dose: dose, judgedFrom: answeredUptime, lastHeardAt: answeredUptime, stalled: false)
    }

    /// A status of the patch, `usable` - not cut short, valid - handled now, before what it says of the bolus is taken:
    /// the step it carries, if any, closes the gap since the last one. The running bolus - answered, or confirmed since,
    /// and judged (`bolusStallMinimumUnits`, not counted in full yet) - has not moved for longer than
    /// `bolusStallThreshold` while the patch kept answering, the link up: it stalled. Warned of once. Judged on the
    /// status's receipt, on the monotonic clock: statuses are handled on different queues. Not on one of a reconnect -
    /// the link was gone - nor after a silence of `bolusLinkSilence`, nor on the first status after a restart: from it on.
    internal func checkBolusStall(_ status: SynchronizePacketResponse, usable: Bool, duringReconnect: Bool, fullSync: Bool) {
        let receivedUptime = status.receivedUptime

        let warning = doseReportLock.withLock { () -> MedtrumAlert? in
            guard let dose = state.bolusDose else {
                bolusStallWatch = nil
                return nil
            }
            let running = dose.snapshot
            // Not one to judge - yet - nor a status that is evidence of anything
            guard usable, !running.isFinished, running.confirmation == .confirmed,
                  !Self.statusPredatesCommand(of: running, receivedAt: status.receivedAt, receivedUptime: receivedUptime)
            else {
                return nil
            }

            guard var watch = bolusStallWatch, watch.dose === dose else {
                // A restart, or confirmed by a step just now: from here on. Warned of in a run before, it is not again.
                bolusStallWatch = BolusStallWatch(
                    dose: dose,
                    judgedFrom: receivedUptime,
                    lastHeardAt: receivedUptime,
                    stalled: isNotedStalled(dose)
                )
                return nil
            }
            defer { bolusStallWatch = watch }
            guard !watch.silenced else {
                return nil
            }

            // The link was down before this, or the patch halted - its own alarm tells: from here on
            let silence = receivedUptime - watch.lastHeardAt
            watch.lastHeardAt = max(watch.lastHeardAt, receivedUptime)
            guard !duringReconnect, state.isConnected, silence <= Self.bolusLinkSilence, !status.state.isDeliveryHalted else {
                if silence > Self.bolusLinkSilence {
                    log.info("Bolus progress: nothing heard for \(Int(silence)) s - the link's, not judged")
                }
                watch.judgedFrom = receivedUptime
                watch.statusesSinceStep = 0
                return nil
            }

            let lastStep = running.lastProgressUnits ?? running.deliveredUnits
            let gap = receivedUptime - max(running.lastProgressUptime ?? watch.judgedFrom, watch.judgedFrom)
            // A step, or the completion: the gap ends here. A full status's completion repeats the last bolus's.
            let closes = status.bolus.map { bolus in
                bolus.completed ? !fullSync : RecordSyncer.steps(bolus.delivered) > RecordSyncer.steps(lastStep)
            } ?? false
            let judged = RecordSyncer.steps(dose.value) >= RecordSyncer.steps(Self.bolusStallMinimumUnits) &&
                RecordSyncer.steps(lastStep) < RecordSyncer.steps(dose.value)

            var alert: MedtrumAlert?
            if judged, gap > Self.bolusStallThreshold {
                noteBolusStalled(dose, for: gap)
                if !watch.stalled {
                    watch.stalled = true
                    let key = UncertainDelivery.DoseKey(dose)
                    alert = .bolusStalled(delivered: lastStep, units: dose.value, stalledFor: gap, sentAt: key.sentAt)
                    log.warning(
                        "Bolus stalled: no progress past \(lastStep) U of \(dose.value) U for \(Int(gap)) s, the patch " +
                            "answering (\(watch.statusesSinceStep) statuses since the last step\(closes ? ", this one a step" : "")) " +
                            "- possible occlusion. Warned of; counted as before"
                    )
                }
            }

            guard closes else {
                watch.statusesSinceStep += 1
                return alert
            }
            if gap > Self.bolusSlowStepGap {
                log.info(
                    "Bolus progress gap: \(Int(gap)) s to \(status.bolus?.completed == true ? "its completion" : "a step") " +
                        "past \(lastStep) U of \(dose.value) U, \(watch.statusesSinceStep) statuses in between"
                )
            }
            watch.longestGap = max(watch.longestGap, gap)
            if watch.stalled {
                watch.stepsAtPaceSinceStall = gap <= Self.bolusSlowStepGap ? watch.stepsAtPaceSinceStall + 1 : 0
            }
            watch.statusesSinceStep = 0
            return alert
        }

        if let warning {
            emitAlert(alertType: warning)
        }
    }

    /// `dose` ended, having delivered `delivered`: its completion received at `receivedAt` (`receivedUptime` on the
    /// monotonic clock), or ended otherwise, now. Logs its pace - every bolus's, for tuning the stall check. One warned
    /// of as stalled that went on at the patch's pace and completed in full was delivered slowly: its warning is
    /// retracted, its note says so. One that ended short is ended by the patch, or by the user - the patch's own alarm
    /// tells, if any: its warning is retracted too. One that completed in full at no pace stays warned of: the patch
    /// counts the full amount whether it went in or not. `endSeen` false: how it ended is not known - past its deadline,
    /// or its session ended under it - and a warning stays as it is; the session's end retracts it
    /// (`retractBolusStallAlerts`). Only under `doseReportLock`.
    internal func endBolusStallWatch(
        _ dose: UnfinalizedDose,
        delivered: Double,
        receivedAt: Date,
        receivedUptime: TimeInterval,
        _ ending: String,
        endSeen: Bool = true
    ) {
        let watch = bolusStallWatch?.dose === dose ? bolusStallWatch : nil
        if watch != nil {
            bolusStallWatch = nil
        }

        let running = dose.snapshot
        let elapsed = running.writtenUptime.map { receivedUptime - $0 } ??
            receivedAt.timeIntervalSince(running.writtenAt ?? dose.startDate)
        let pace = elapsed > 0 ? (delivered / (elapsed / 60)).rounded(toPlaces: 2) : 0
        let stalled = watch?.stalled ?? isNotedStalled(dose)
        log.info(
            "Bolus pace: \(delivered.rounded(toPlaces: 2)) U of \(dose.value) U in \(Int(elapsed)) s (\(pace) U/min), " +
                "longest gap \(watch.map { "\(Int($0.longestGap)) s" } ?? "not judged")\(stalled ? ", stalled" : "") - \(ending)"
        )

        guard stalled else {
            return
        }
        guard endSeen else {
            log.warning("The stalled bolus of \(dose.startDate) ended unseen - \(ending): its warning stands")
            return
        }
        let key = UncertainDelivery.DoseKey(dose)
        guard RecordSyncer.steps(delivered) >= RecordSyncer.steps(dose.value) else {
            log.info(
                "The stalled bolus of \(dose.startDate) ended short, at \(delivered) U: its warning retracted, the end tells"
            )
            retractBolusStallAlert(sentAt: key.sentAt)
            return
        }
        guard let watch, watch.stepsAtPaceSinceStall >= Self.bolusStallResumeSteps else {
            log.warning(
                "The stalled bolus of \(dose.startDate) completed in full, not at the patch's pace: still warned of - the " +
                    "patch counts it whether it went in or not"
            )
            return
        }
        log.info(
            "The stalled bolus of \(dose.startDate) went on at the patch's pace and completed in full: delivered slowly, " +
                "its warning retracted"
        )
        noteBolusStallResumed(dose)
        retractBolusStallAlert(sentAt: key.sentAt)
    }

    /// The patch raised its own alarm - an occlusion, a fault, its reservoir empty - or its session ended, the patch
    /// deactivated or replaced: that tells of the boluses warned of as stalled better, or they are over with their patch.
    /// Their warnings are retracted, and the running bolus, if any, is not warned of from here on. In one step with the
    /// stall check: it takes the dose lock - recursive, so a caller may hold it.
    internal func retractBolusStallAlerts(because reason: String) {
        let stalled = doseReportLock.withLock { () -> [UncertainDelivery] in
            bolusStallWatch?.silenced = true
            return state.uncertainDeliveries.filter { $0.kind == .bolus && $0.stalledFor != nil && !$0.stallResumed }
        }
        guard !stalled.isEmpty else {
            return
        }
        log.info("Stall warnings of \(stalled.count) bolus(es) retracted: \(reason)")
        for delivery in stalled {
            retractBolusStallAlert(sentAt: delivery.sentAt)
        }
    }

    private func retractBolusStallAlert(sentAt: Date) {
        let identifier = MedtrumAlert.bolusStalled(delivered: 0, units: 0, stalledFor: 0, sentAt: sentAt).alert.identifier
        pumpDelegate.notify { delegate in
            delegate?.retractAlert(identifier: identifier)
        }
    }

    /// Whether `dose` was warned of as stalled - in this run or one before
    private func isNotedStalled(_ dose: UnfinalizedDose) -> Bool {
        let key = UncertainDelivery.DoseKey(dose)
        return state.uncertainDeliveries.contains { $0.kind == .bolus && $0.isOf(key) && $0.stalledFor != nil }
    }
}

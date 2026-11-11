import LoopKit

public extension MedtrumPumpManager {
    func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        suspendPatch(duration: .minutes(120), completion: completion)
    }

    func suspendPatch(duration: TimeInterval, completion: @escaping ((any Error)?) -> Void) {
        log.info("Suspending delivery...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error)
                return
            }

            let sequenceBefore = self.state.currentSequenceNumber
            let result = self.link.write(SuspendPumpPacket(duration: duration))
            if case let .failure(error) = result {
                self.log.error("Failed to suspend delivery: \(error.localizedDescription)")
                completion(error)
                return
            }
            // As near as we know, not after the wait below
            let start = self.now()

            // The patch announces the suspend right away, with its exact time, and that status usually beats this:
            // it dated the suspend and ended the temp basal there already - its records are read here. A temp basal of
            // ours still running, it is waited for a moment. Otherwise at the answer - the temp basal's records read up
            // to the newest record the patch told of since the write, the one it wrote as it ended it, or the records
            // before the write still unread; from our estimate if there are none, or they cannot be read.
            let endRecord = self.awaitSuspendAnnouncement(after: sequenceBefore)
            // The temp basal whose command went unanswered, kept: its record, if written, read before the suspend is
            // reported - Loop fills up to a suspend, its watermark past the unanswered one. A suspend the status
            // reported is held back meanwhile (`holdForUnconfirmedRead`).
            self.readUnconfirmedTempBasalsRecords(through: self.state.currentSequenceNumber)
            self.releaseHeldForUnconfirmedRead()
            let replaced = self.replaceRunningBasal(lastRecord: endRecord) {
                // Before the batch: the state saved with it is suspended
                self.state.basalState = .suspended
                self.state.lastSync = Date.now

                guard self.state.basalDose.type != .suspend else {
                    return nil
                }

                // Never before a resume dated up to a second ahead - see `earliestAfter`
                let basalDose = UnfinalizedDose(suspendStartTime: max(start, Self.earliestAfter(self.state.basalDose)))
                return (basalDose, NewPumpEvent.suspend(dose: basalDose.toDoseEntry()))
            }
            self.notifyStateDidChange()
            // The session ended while it was out - forced: its own suspend stands
            guard replaced else {
                completion(MedtrumConnectError.noActivePatch)
                return
            }

            self.log.info("Delivery suspended for \(duration.minutes) min!")
            completion(nil)
        }
    }

    /// The patch, told to suspend, announces it right after its answer: a status with when it suspended, naming the
    /// newest record - the one it wrote for the temp basal it ended (device log 2026-10-20 09:50:02, in the second of the
    /// answer). With a temp basal of ours still running it is waited for, `suspendAnnouncementWait` at most: the status
    /// then ends the temp basal itself, where the patch suspended, its records read in the command - or a heartbeat
    /// names a newer record than `sequenceBefore`, the newest known as the command went out. Returns that record, the
    /// last of the temp basal's to read. With none told, `sequenceBefore` if records up to it are unread: the patch may
    /// have ended the temp basal unseen before the write - it ran its course, say, then not waited for - its record among
    /// them. Nil - none running, a status ended it, or nothing to read.
    private func awaitSuspendAnnouncement(after sequenceBefore: Int) -> Int? {
        let deadline = Date.now.addingTimeInterval(Self.suspendAnnouncementWait)
        while true {
            let (running, pastItsEnd, newest, synced) = doseReportLock.withLock { () -> (Bool, Bool, Int, Int) in
                let dose = state.basalDose
                return (
                    dose.type == .tempBasal && !dose.isFinished,
                    now() >= dose.estimatedEndDate,
                    state.currentSequenceNumber,
                    state.syncedSequenceNumber
                )
            }
            guard running else {
                return nil
            }
            if newest > sequenceBefore {
                return newest
            }
            let unread = sequenceBefore > synced ? sequenceBefore : nil
            if pastItsEnd {
                return unread
            }
            guard Date.now < deadline else {
                let known = unread.map { "reading the records up to \($0)" } ?? "no record of the temp basal's end is known"
                log.info("No status announced the suspend within \(Int(Self.suspendAnnouncementWait)) s: \(known)")
                return unread
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// How long a suspend command waits for the patch to announce it, a temp basal of ours running - see
    /// `awaitSuspendAnnouncement`
    internal static let suspendAnnouncementWait: TimeInterval = 2

    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        log.info("Resuming delivery...")

        ensureConnectedAndActive { error in
            if let error = error {
                self.log.error("Failed to connect: \(error.localizedDescription)")
                completion(error)
                return
            }

            // A suspend held back for the records of the temp basal whose command went unanswered goes out first, those
            // records read before, as a suspend command does: the unanswered one final from its own ahead of the suspend
            // - Loop fills up to it, its watermark past the unanswered one. Before the resume is written: the patch still
            // suspended, its record written at the halt, and no status of its schedule comes during the reads - the one it
            // sends a second after the resume would, its resume then held back with the suspend (`holdWithHeldSuspend`).
            self.releaseHeldAfterUnconfirmedRead()

            let response = self.link.write(ResumePumpPacket())
            if case let .failure(error) = response {
                self.log.error("Failed to resume delivery: \(error.localizedDescription)")
                completion(error)
                return
            }

            self.log.info("Resumed delivery!")

            // The answer carries the segment the patch resumed with, started at the resume on its clock - and the newest
            // record: a temp basal still taken to run has its record among those, written as the patch suspended
            var segmentStart: Date?
            var newestRecord: Int?
            if case let .success(data) = response, let answer = data as? ResumePumpPacketResponse,
               let start = answer.basalStartTime
            {
                segmentStart = start
                if let sequence = answer.basalSequence {
                    self.adoptRecordSequence(sequence, from: "Resume")
                    newestRecord = self.state.currentSequenceNumber
                }
                self.noteAnsweredSegment(startingAt: start)
            }

            // The same for a suspend a halt seen during the write held back - after the resume, Loop would have its
            // watermark past it, and never store the suspension. A resume a status reported during those reads is held
            // with it (`holdWithHeldSuspend`), out after it.
            self.releaseHeldAfterUnconfirmedRead()

            // Read and replaced in one step - see `doseReportLock`. A status showing the scheduled basal may have
            // reported the resume already - or held it back, behind a suspend held since.
            let replaced = self.replaceRunningBasal(lastRecord: newestRecord) {
                // Before the batch: the state saved with it is resumed
                self.state.basalState = .active
                self.state.lastSync = Date.now

                guard self.state.basalDose.type == .suspend || self.state.basalDose.type == .tempBasal else {
                    return nil
                }

                var resumedAt = segmentStart.map {
                    self.endOnOurClock(of: self.state.basalDose, patchTime: $0, notAfter: self.now())
                } ?? self.now()
                // In a later second than the suspend at the earliest - see `earliestResume`
                if self.state.basalDose.type == .suspend {
                    resumedAt = max(resumedAt, Self.earliestResume(after: self.state.basalDose.startDate))
                }

                // A temp basal still taken to run stopped at the suspend for good (the patch resumes the schedule):
                // ended at the resume at the latest, final from its record - read up to the newest the answer named -
                // else from our estimate. The schedule follows it, not a resume: with no suspend reported before it,
                // iAPS would take the patch to have been suspended since before its history (`holdWithHeldSuspend`).
                let tookTempBasalToRun = self.state.basalDose.type == .tempBasal
                let resumeDose = tookTempBasalToRun
                    ? UnfinalizedDose(basalRate: self.state.currentBaseBasalRate, insulinType: self.state.insulinType, startDate: resumedAt)
                    : UnfinalizedDose(resumeStartTime: resumedAt, insulinType: self.state.insulinType)
                // Its start on the patch clock, where it is the same instant as on ours
                if let segmentStart, let paired = self.patchTimePaired(with: resumedAt, endOf: self.state.basalDose, at: segmentStart) {
                    resumeDose.setPumpStartTime(paired)
                }

                return (
                    resumeDose,
                    tookTempBasalToRun ? NewPumpEvent.basal(dose: resumeDose.toDoseEntry()) : NewPumpEvent.resume(dose: resumeDose.toDoseEntry())
                )
            }
            self.notifyStateDidChange()
            // The session ended while it was out - forced: no resume over its suspend
            guard replaced else {
                completion(MedtrumConnectError.noActivePatch)
                return
            }

            completion(nil)
        }
    }
}

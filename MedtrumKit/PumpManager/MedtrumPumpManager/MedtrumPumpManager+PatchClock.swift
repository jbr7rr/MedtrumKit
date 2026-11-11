import Foundation

public extension MedtrumPumpManager {
    /// How far apart a temp basal's end on the patch clock - taken to ours through the skew - and where we saw it end
    /// may be and still be the same: the skew is known to a few seconds only (`unansweredStartSlack`), and an answer
    /// takes a second or two to come back. Further apart, the patch had stopped it earlier: the gap is the schedule's.
    internal static let patchEndTolerance: TimeInterval = unansweredStartSlack

    /// No final ends this close to its start by an end we worked out: it would be dropped by the host as 0-duration, and
    /// what it delivered with it - our observed end stands instead
    internal static let shortestComputedDuration: TimeInterval = 1

    /// Where the patch had stopped `dose` before our cancel went out at `cancelSentAt`, on our clock - nil if it ran it up
    /// to the cancel, as far as we can tell. Told on each clock alone, so a wrong skew does not move it: how long the
    /// patch ran it (from its patch start to `patchEnd`, the start of the segment the cancel's answer reports) against how
    /// long we had it running when the cancel went out (from its answer). Short of that by more than `patchEndTolerance`,
    /// it was stopped then. Without a patch start, or one not of its first segment (`firstSegmentUncertain`), nothing is
    /// told.
    internal func stopBeforeCancel(of dose: UnfinalizedDose, patchEnd: Date, cancelSentAt: Date, logging: Bool = true) -> Date? {
        let running = dose.snapshot
        // Its patch start a later segment's, or its start not the patch's on our clock: nothing to tell it from
        guard let pumpStartTime = running.pumpStartTime, !running.firstSegmentUncertain else {
            return nil
        }
        let patchElapsed = max(0, patchEnd.timeIntervalSince(pumpStartTime))
        // From its answer: short of the patch's by the round trip - never a stop that was not
        let ourElapsed = cancelSentAt.timeIntervalSince(dose.startDate)
        guard patchElapsed < ourElapsed - Self.patchEndTolerance else {
            return nil
        }
        guard patchElapsed >= Self.shortestComputedDuration else {
            guard logging else {
                return nil
            }
            log.warning(
                "The cancel of the temp basal of \(dose.startDate) says the patch ran it \(Int(patchElapsed)) s: not ended " +
                    "on that, it would end where it started - where we saw it end instead"
            )
            return nil
        }
        let stoppedAt = dose.startDate.addingTimeInterval(patchElapsed)
        if logging {
            log.warning(
                "The cancel of the temp basal of \(dose.startDate) says the patch ran it \(Int(patchElapsed)) s, we had it " +
                    "running \(Int(ourElapsed)) s: the patch had stopped it at \(stoppedAt) - it ends there, the schedule ran since"
            )
        }
        return stoppedAt
    }

    /// The patch time of `ourTime` - the cancel's answer, or the schedule after it, dated at it - for an anchor: the
    /// instant `cancel` ended `tempBasal` on both clocks. Its segment began at `basalStartTime` on the patch clock: there
    /// on ours too, the cancel going out as the patch ended it - unless the patch had stopped it before, at
    /// `stopBeforeCancel` on ours: then `ourTime` is that much later on the patch clock as well.
    /// Not a temp basal running - the reported schedule, a temp basal kept unconfirmed that never ran - the cancel ended
    /// nothing: its segment still the one running, `ourTime` is as far past its start on both clocks. A segment the patch
    /// began since is the cancel's own. Nil, the running one's patch start unknown: no anchor - the skew stands in.
    internal func cancelSegmentOnPatch(
        at ourTime: Date,
        cancel: CancelTempBasalPacketResponse,
        cancelSentAt: Date?,
        tempBasal: UnfinalizedDose
    ) -> Date? {
        guard tempBasal.type == .tempBasal else {
            guard let runningOnPatch = tempBasal.pumpStartTime else {
                return nil
            }
            guard cancel.basalStartTime == runningOnPatch else {
                return cancel.basalStartTime
            }
            return runningOnPatch.addingTimeInterval(ourTime.timeIntervalSince(tempBasal.startDate))
        }
        guard let cancelSentAt,
              let stoppedAt = stopBeforeCancel(of: tempBasal, patchEnd: cancel.basalStartTime, cancelSentAt: cancelSentAt, logging: false)
        else {
            return cancel.basalStartTime
        }
        return cancel.basalStartTime.addingTimeInterval(ourTime.timeIntervalSince(stoppedAt))
    }

    /// `patchTime`, where the patch ended `dose`, for an anchor at `ourTime`: only if `ourTime` is that same instant on our
    /// clock, told skew-free from its patch start (`endOnOurClock`, not bounded). Nil otherwise: the skew is all there
    /// is, and an anchor through it would tell nothing more.
    internal func patchTimePaired(with ourTime: Date, endOf dose: UnfinalizedDose, at patchTime: Date) -> Date? {
        let running = dose.snapshot
        guard dose.type == .tempBasal, let pumpStartTime = running.pumpStartTime, !running.firstSegmentUncertain,
              dose.startDate.addingTimeInterval(max(0, patchTime.timeIntervalSince(pumpStartTime))) == ourTime
        else {
            return nil
        }
        return patchTime
    }

    /// A status received before the command of the dose it is checked against went out - was written, past the wait
    /// for the host (`UnfinalizedDose.State.writtenAt`) - says nothing of that dose: the monotonic clock where both are
    /// known (one run of the app), the wall clock otherwise
    internal static func statusPredatesCommand(
        of dose: UnfinalizedDose.State,
        receivedAt: Date,
        receivedUptime: TimeInterval
    ) -> Bool {
        if let sentUptime = dose.writtenUptime ?? dose.sentUptime {
            return receivedUptime < sentUptime
        }
        if let sentAt = dose.writtenAt ?? dose.sentAt {
            return receivedAt < sentAt
        }
        return false
    }

    /// A time on the patch clock as ours - by the skew of the last reading - bounded to `[notBefore, notAfter]`
    /// Where `dose`, running, ended, the patch saying it ended at `patchTime` on its clock: from its start, as long as the
    /// patch ran it from its patch start - skew-free - where that is its first segment; through the skew otherwise. No
    /// later than `notAfter`, no earlier than its start.
    internal func endOnOurClock(of dose: UnfinalizedDose, patchTime: Date, notAfter: Date) -> Date {
        let running = dose.snapshot
        guard dose.type == .tempBasal, let pumpStartTime = running.pumpStartTime, !running.firstSegmentUncertain else {
            return patchTimeOnOurClock(patchTime, notBefore: dose.startDate, notAfter: notAfter)
        }
        let ended = dose.startDate.addingTimeInterval(max(0, patchTime.timeIntervalSince(pumpStartTime)))
        return max(min(ended, notAfter), dose.startDate)
    }

    /// Where the patch, suspending at `patchTime`, ended `dose`, the running basal, on our clock: a temp basal as
    /// `endOnOurClock` tells it. Another kind - the schedule - from the anchor the temp basal whose command went
    /// unanswered, kept, is dated by (`basalBefore`, `basalBeforeOnPatch`), so that the two agree to the second; else
    /// from its own patch start, paired with its start; through the skew otherwise. Between its start and `notAfter` -
    /// strictly after a resume: at its instant, Loop orders the two either way, and may close this suspend with it.
    internal func suspendOnOurClock(of dose: UnfinalizedDose, patchTime: Date, notAfter: Date) -> Date {
        guard dose.type != .tempBasal else {
            return endOnOurClock(of: dose, patchTime: patchTime, notAfter: notAfter)
        }
        let earliest = Self.earliestAfter(dose)
        let unconfirmed = state.unconfirmedTempBasal?.snapshot
        let anchor: (ours: Date, patch: Date)?
        if let basalBefore = unconfirmed?.basalBefore, let onPatch = unconfirmed?.basalBeforeOnPatch {
            anchor = (basalBefore, onPatch)
        } else if let pumpStartTime = dose.snapshot.pumpStartTime {
            anchor = (dose.startDate, pumpStartTime)
        } else {
            anchor = nil
        }
        guard let anchor else {
            return patchTimeOnOurClock(patchTime, notBefore: earliest, notAfter: notAfter)
        }
        let suspended = anchor.ours.addingTimeInterval(patchTime.timeIntervalSince(anchor.patch))
        return max(min(suspended, notAfter), earliest)
    }

    internal func patchTimeOnOurClock(_ patchTime: Date, notBefore: Date, notAfter: Date) -> Date {
        max(min(patchTime.addingTimeInterval(-state.patchClockSkew), notAfter), notBefore)
    }

    /// The patch restarts a temp basal running at patch-local midnight: two records, and the amount its statuses show
    /// starts over
    internal static func crossesPatchMidnight(from start: Date, to end: Date, utcOffset: TimeInterval) -> Bool {
        let day: TimeInterval = .hours(24)
        let localStart = start.timeIntervalSince1970 + utcOffset
        let nextMidnight = (floor(localStart / day) + 1) * day
        return end.timeIntervalSince1970 + utcOffset > nextMidnight
    }

    /// The basal doses the host has: the running one unless a placeholder, those waiting on their record or final, and
    /// the suspends and resumes held back - the host gets them all the same, after what goes out meanwhile: a resume
    /// held with its suspend the running one, that suspend bounds the temp basal before it, not the resume
    internal var reportedBasalDoses: [UnfinalizedDose] {
        (state.basalDoseIsPlaceholder ? [] : [state.basalDose]) + state.awaitingRecord.filter { $0.type != .bolus } +
            state.heldBasalDoses.map(\.dose).filter { $0.type == .suspend || $0.type == .resume }
    }

    /// Where the running basal of `reportedBasalStart` began on the patch clock, where known - the segment the cancel, the
    /// resume or the status that put it in place showed
    internal var reportedBasalPatchStart: Date? {
        reportedBasalStart != nil ? state.basalDose.pumpStartTime : nil
    }

    /// The start of the running basal, if it is of another kind than a temp basal and the host was told of it - not a
    /// placeholder (`MedtrumPumpState.basalDoseIsPlaceholder`)
    internal var reportedBasalStart: Date? {
        state.basalDose.type != .tempBasal && !state.basalDoseIsPlaceholder ? state.basalDose.startDate : nil
    }

    /// How far after a dose of another basal kind a temp basal is dated at the earliest, when its start would be the same
    /// instant: just after, the order unmistakable
    internal static let afterFinal: TimeInterval = 0.001

    /// The earliest a basal dose following `dose`, the running one, is dated: just after it if it is a resume - one may
    /// be dated up to a second ahead (`earliestResume`), and a suspend or a temp basal dated before it, or at its instant,
    /// would have oref0 pair the suspend before it with it as well, or Loop order the two either way. Its start otherwise.
    internal static func earliestAfter(_ dose: UnfinalizedDose) -> Date {
        dose.type == .resume ? dose.startDate.addingTimeInterval(afterFinal) : dose.startDate
    }

    /// The earliest a resume of the suspend started at `suspendStart` is dated: the next whole second. iAPS stores pump
    /// events to the second, floored (`PumpHistoryEvent`, `truncatedToSecond`), and oref0 pairs a resume with a suspend
    /// only if it is strictly later (`iob/history`): in the suspend's second, the suspend is left open - every temp basal
    /// after it zeroed, up to now. At most a second after the patch resumed: for Loop, a second more of the suspension.
    internal static func earliestResume(after suspendStart: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: suspendStart.timeIntervalSinceReferenceDate.rounded(.down) + 1)
    }

    /// The patch splits a temp basal at patch-local midnight: a record of it ending then is a part
    internal static func isPatchMidnight(_ time: Date, utcOffset: TimeInterval) -> Bool {
        (time.timeIntervalSince1970 + utcOffset).truncatingRemainder(dividingBy: .hours(24)) == 0
    }
}

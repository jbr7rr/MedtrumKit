import Foundation
import LoopKit
@testable import MedtrumKit

/// What Loop's DoseStore makes of the batches a pump manager hands it, checked against the rules a driver has to keep
/// so that no basal insulin is lost or mis-counted (`LoopKit/InsulinKit/DoseStore.swift`, `InsulinDeliveryStore.swift`,
/// `InsulinMath.swift`). The host keeps pump events as Loop does: one per `raw`, a final never replaced by a later
/// report (store-trump), every mutable one purged by a replacing batch. A batch the host could not store changes
/// nothing. The basal kinds are all but the bolus: temp basal, scheduled basal, suspend, resume.
///
/// 1. Exact alignment. A temp basal followed by another, nothing between them, ends exactly where the next one starts
///    while mutable; its final there too - or earlier, by its records (see `checkAlignment`), never later - and no final
///    that delivered lasts 0 s, or under a second with its end moved earlier than its mutable report: Loop drops it. A gap is filled with immutable
///    scheduled basal (`overlayBasalSchedule`, MedtrumKit does not record the schedule's starts) - past a mutable one,
///    see 3; an overlap is trimmed off it, its delivered amount scaled down with it (`reconciled`, `trimmed`). Nor does a
///    temp basal reach past the start of a dose of another basal kind after it.
/// 2. Finals in start order, and 3. no gap-creating dose while an earlier ended temp basal is mutable: nothing of a basal
///    kind immutable ends after a temp basal still mutable starts. Loop's watermark - the latest end of an immutable basal
///    dose (`getLastImmutableBasalEndDate`) - would move past that temp basal, which is never sent again
///    (`getNormalizedPumpEventDoseEntriesForSavingToInsulinDeliveryStore`).
/// 4. Every replacing batch carries every temp basal the host holds mutable: it purges the rest.
/// 5. No dose of another basal kind between two temp basals back to back: it would trim the first one off where it
///    starts, a 0-duration scheduled basal included.
/// 6. Nothing of a basal kind new to the host - of positive duration, mutable or final - starts before the watermark as
///    the batches before left it: Loop fetches the basal doses to store from the watermark on (`startDate >= basalStart`),
///    and never stores that one - nor one it holds mutable, moved past. The watermark is `MedtrumKit.LoopWatermark`'s - the one the driver goes by - derived
///    there from LoopKit, line by line: a 0-s scheduled basal moves nothing, a dose after a gap moves it to its start.
///
/// And two iAPS needs kept, which Loop does not - oref0's `iob/history` (`FreeAPS/Resources/javascript/bundle/
/// oref0-bridge.js`) pairs a suspend with the first resume strictly later than it, both as iAPS stores them: to the
/// second, floored (`PumpHistoryEvent`, `truncatedToSecond`) - a resume in its suspend's second is not later:
/// 7. No resume is stored before a suspend starting earlier than it - in that batch, or one before. A history whose
///    earliest resume comes no later than its earliest suspend - or that has no suspend - was suspended since before it
///    begins: with `suspend_zeros_iob` it zeroes every temp basal before that resume, and the scheduled basal from 8 h
///    back ("suspended prior to history block").
/// 8. The patch delivering once the batches are in (`finish(delivering:)`), no suspend stored is left with no resume
///    stored strictly later: open, it runs to now, every temp basal after it zeroed ("suspended past end of history
///    block").
/// `iAPSRules` are checked on their own where the rest are not - see `MedtrumManagerTestCase.checksLoopOrdering`.
struct LoopOrderingChecker {
    /// The rules iAPS needs kept
    static let iAPSRules: Set<Int> = [7, 8]

    struct Violation: CustomStringConvertible {
        /// Of the batches checked, from 0
        let batch: Int
        let rule: Int
        let message: String

        var description: String {
            "batch \(batch), rule \(rule): \(message)"
        }
    }

    /// One batch as the host got it
    struct Batch {
        let events: [NewPumpEvent]
        let replacePendingEvents: Bool
        let stored: Bool

        init(events: [NewPumpEvent], replacePendingEvents: Bool = true, stored: Bool = true) {
            self.events = events
            self.replacePendingEvents = replacePendingEvents
            self.stored = stored
        }
    }

    private var held: [Data: DoseEntry] = [:]
    /// The end a mutable report of a temp basal ended back to back gave it
    private var mutableEnds: [Data: Date] = [:]
    private var checked = 0
    /// Loop's watermark, as the batches stored make it
    private var watermark = LoopWatermark()
    /// The longest a mutable report of a temp basal gave it
    private var mutableDurations: [Data: TimeInterval] = [:]
    /// What the host holds wrong stays wrong in every batch after: told once
    private var told: Set<String> = []
    /// The earliest and the latest start of a suspend stored, and the latest of a resume
    private var earliestSuspend: Date?
    private var latestSuspend: Date?
    private var latestResume: Date?

    private(set) var violations: [Violation] = []

    /// Every rule broken by `batches`, in the order the host got them - a host that had stored a suspend from
    /// `suspendedSince` before them, if given - and after them, the patch delivering or not, if told (rule 8)
    static func violations(in batches: [Batch], suspendedSince: Date? = nil, delivering: Bool? = nil) -> [Violation] {
        var checker = LoopOrderingChecker()
        checker.earliestSuspend = suspendedSince.map(stored)
        checker.latestSuspend = suspendedSince.map(stored)
        batches.forEach { checker.apply($0) }
        if let delivering {
            checker.finish(delivering: delivering)
        }
        return checker.violations
    }

    /// The batches are in, the patch `delivering` or not: rule 8
    mutating func finish(delivering: Bool) {
        guard delivering, let latestSuspend, !(latestResume.map { $0 > latestSuspend } ?? false) else {
            return
        }
        fail(
            8,
            "the suspend of \(latestSuspend) is stored with no resume after it, the patch delivering: iAPS takes it to run " +
                "to now, and zeroes every temp basal after it"
        )
    }

    mutating func apply(_ batch: Batch) {
        defer { checked += 1 }
        guard batch.stored else {
            return
        }

        let doses = batch.events.compactMap { event in event.dose.map { (raw: event.raw, dose: $0) } }

        for dose in watermark.store(batch.events, replacePendingEvents: batch.replacePendingEvents) {
            fail(
                6,
                "the \(dose.type) of \(dose.startDate), new to the host, starts before Loop's watermark: never stored"
            )
        }
        // And a mutable one it holds, the watermark moved past - by a final dated over it, say: resolved away
        for start in watermark.mutableBehind {
            fail(6, "the mutable dose of \(start) the host holds starts before Loop's watermark \(watermark.date ?? start): lost")
        }

        if batch.replacePendingEvents {
            let carried = Set(doses.map(\.raw))
            for (raw, dose) in held where dose.isMutable && dose.type == .tempBasal && !carried.contains(raw) {
                fail(4, "a replacing batch leaves out the mutable temp basal of \(dose.startDate): the host drops it")
            }
            held = held.filter { !$0.value.isMutable }
        }

        for (raw, dose) in doses {
            if let stored = held[raw], !stored.isMutable {
                continue
            }
            held[raw] = dose
            if dose.type == .tempBasal, dose.isMutable {
                mutableDurations[raw] = max(mutableDurations[raw] ?? 0, dose.endDate.timeIntervalSince(dose.startDate))
            }
            // Reported ended: where another temp basal of the batch starts. A running one's end is its planned end.
            if dose.type == .tempBasal, dose.isMutable,
               doses.contains(where: { $0.dose.type == .tempBasal && $0.dose.startDate == dose.endDate })
            {
                mutableEnds[raw] = dose.endDate
            }
        }

        checkWatermark()
        checkAlignment()
        checkResumes(doses.map(\.dose))
    }

    /// `date` as iAPS stores a pump event's: to the second, floored
    static func stored(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    private mutating func checkResumes(_ doses: [DoseEntry]) {
        let suspends = doses.filter { $0.type == .suspend }.map { Self.stored($0.startDate) }
        if let earliest = suspends.min(), let latest = suspends.max() {
            earliestSuspend = min(earliestSuspend ?? earliest, earliest)
            latestSuspend = max(latestSuspend ?? latest, latest)
        }
        if let resume = doses.filter({ $0.type == .resume }).map({ Self.stored($0.startDate) }).max() {
            latestResume = max(latestResume ?? resume, resume)
        }
        // Strictly: one at the same instant is not paired with it
        for resume in doses where resume.type == .resume && !(earliestSuspend.map { $0 < Self.stored(resume.startDate) } ?? false) {
            fail(
                7,
                "the resume of \(resume.startDate) is stored with no suspend in an earlier second: with none, iAPS takes " +
                    "the patch suspended since before its history, and zeroes the basal before the resume - with one in " +
                    "its second only, it leaves that one open (rule 8)"
            )
        }
    }

    private mutating func fail(_ rule: Int, _ message: String) {
        guard told.insert("\(rule) \(message)").inserted else {
            return
        }
        violations.append(Violation(batch: checked, rule: rule, message: message))
    }

    private static func isBasalKind(_ dose: DoseEntry) -> Bool {
        dose.type != .bolus
    }

    private func basalDoses() -> [(raw: Data, dose: DoseEntry)] {
        held.filter { Self.isBasalKind($0.value) }.map { (raw: $0.key, dose: $0.value) }
            .sorted { ($0.dose.startDate, $0.dose.type == .tempBasal ? 0 : 1) < ($1.dose.startDate, $1.dose.type == .tempBasal ? 0 : 1) }
    }

    private mutating func checkWatermark() {
        let doses = basalDoses()
        for mutable in doses where mutable.dose.type == .tempBasal && mutable.dose.isMutable {
            for immutable in doses where !immutable.dose.isMutable && immutable.dose.endDate > mutable.dose.startDate {
                let rule = immutable.dose.type == .tempBasal ? 2 : 3
                fail(
                    rule,
                    "the immutable \(immutable.dose.type) of \(immutable.dose.startDate), ending \(immutable.dose.endDate), " +
                        "is stored with the temp basal of \(mutable.dose.startDate) still mutable: the watermark passes it"
                )
            }
        }
    }

    private mutating func checkAlignment() {
        let doses = basalDoses()

        // A final of 0 duration, having delivered: `reconciled()` drops it (`endDate > last.startDate`), and what it
        // delivered with it. One whose end was moved earlier than its mutable report had - computed - is held to a
        // second at least: that is the bug class, an end clamped to its start.
        // So is one cut to its start - an end computed through a wrong skew, clamped there - whatever it delivered, once a
        // mutable report had it run longer than a second
        for (raw, dose) in doses where dose.type == .tempBasal && !dose.isMutable {
            let duration = dose.endDate.timeIntervalSince(dose.startDate)
            let movedEarlier = mutableEnds[raw].map { dose.endDate < $0 } ?? false
            let delivered = (dose.deliveredUnits ?? 0) > 0
            let cutToItsStart = duration < 0.001 && (mutableDurations[raw] ?? 0) > 1
            guard (delivered && (duration <= 0 || (movedEarlier && duration < 1))) || cutToItsStart else {
                continue
            }
            fail(
                1,
                "the temp basal of \(dose.startDate) is final ending at \(dose.endDate), \(duration) s after its start, " +
                    "having delivered \(dose.deliveredUnits ?? 0) U: dropped as 0-duration, or cut to nothing"
            )
        }

        for (index, (_, dose)) in doses.enumerated() where dose.type == .tempBasal && index + 1 < doses.count {
            let next = doses[index + 1].dose

            if dose.endDate > next.startDate {
                fail(
                    1,
                    "the temp basal of \(dose.startDate) ends at \(dose.endDate), past the start of the \(next.type) of " +
                        "\(next.startDate): trimmed off it"
                )
            } else if next.type == .tempBasal, dose.endDate < next.startDate {
                if dose.isMutable {
                    fail(
                        1,
                        "the mutable temp basal of \(dose.startDate) ends at \(dose.endDate), before the temp basal of " +
                            "\(next.startDate) starts: the scheduled basal filled between them passes it"
                    )
                }
                // A final ending before the end its mutable report had, at the next temp basal's start, is allowed: its
                // records showed the patch had stopped it then (`MedtrumPumpManager.finalizeOpen`). Safe for Loop:
                // `reconciled()` trims a basal dose to min(its end, the next one's start) - an earlier end is kept as it is,
                // its delivered amount unscaled - and `overlayBasalSchedule(insertingBasalEntries: true)` fills the gap with
                // scheduled entries from its end to `dose.startDate` of the next, `Swift.min(dose.startDate, ...)`: they end
                // exactly where the next one starts. The watermark - the latest immutable end - is then that start, and the
                // next temp basal, `startDate >= basalStart`, is still fetched and stored.
            }
        }

        let tempBasals = doses.filter { $0.dose.type == .tempBasal }
        for (first, second) in zip(tempBasals, tempBasals.dropFirst()) where first.dose.endDate == second.dose.startDate {
            for between in doses where between.dose.type != .tempBasal &&
                between.dose.startDate > first.dose.startDate && between.dose.startDate < second.dose.startDate
            {
                fail(
                    5,
                    "the \(between.dose.type) of \(between.dose.startDate) lies between the temp basals of " +
                        "\(first.dose.startDate) and \(second.dose.startDate), back to back"
                )
            }
        }
    }
}

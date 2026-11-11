import Foundation
import LoopKit

/// Loop's watermark, as far as the pump events handed to it tell: the latest end of an immutable basal dose its insulin
/// delivery store holds (`InsulinDeliveryStore.updateLastImmutableBasalEndDate`, `isMutable == NO`, reason basal). The
/// next sync stores only the basal doses starting from there on (`DoseStore.getNormalizedPumpEventDoseEntriesForSaving
/// ToInsulinDeliveryStore`, `.filter({ $0.startDate >= basalStart || $0.type == .bolus })`): one reported later, starting
/// before it, is never stored - Loop does not count it. iAPS keeps no such mark.
///
/// After a batch is stored (`DoseStore.addPumpEvents`, then `syncPumpEventsToInsulinDeliveryStore(after: watermark)`):
/// 1. The pump events from the watermark on - every one still held: the mutable ones a replacing batch did not purge, a
///    final never replaced by a later report - are `reconciled()` (`InsulinMath` 396-519): a basal dose ends where the
///    next one starts, at the latest; a suspend runs to its resume, or to a temp basal after it; a trailing suspend stays
///    mutable, ending where it starts; a dose of 0 duration is dropped - a scheduled basal event (`DoseEntry.init`,
///    `endDate ?? startDate`) moves nothing by itself.
/// 2. `overlayBasalSchedule(startingAt: watermark, insertingBasalEntries: true)` (`InsulinMath` 888-951): from a
///    placeholder ending at the watermark, every basal-kind dose after a gap (`> .ulpOfOne`) since the end of the one
///    before gets IMMUTABLE scheduled entries filling it, ending at that dose's start - whether that dose is mutable or not.
/// 3. The watermark is then the latest end of an immutable entry of positive duration: a final, a suspend ended by its
///    resume, or a fill - so a mutable temp basal reported after a gap moves it to its own start.
///
/// With nothing immutable stored yet, Loop syncs from `recentStartDate`, 24 h back (`syncPumpEventsToInsulinDeliveryStore`,
/// `max(date, self.recentStartDate)`): the first basal-kind dose stored gets a fill from there, and the watermark is its
/// start at least.
///
/// The doses Loop checks against `endDate <= now` are all past here. Used by `MedtrumPumpManager` (what it handed over,
/// taken as stored) and by the tests' Loop-ordering checker (what the host stored): one definition.
public struct LoopWatermark {
    /// A basal-kind dose as Loop's reconciliation sees it
    struct Interval: Equatable {
        let type: DoseType
        var start: Date
        var end: Date
        let isMutable: Bool
    }

    /// Nil: nothing stored yet - see above
    public private(set) var date: Date?

    /// The basal-kind pump events the host holds, by identity - recent ones only
    private var held: [Data: Interval] = [:]

    /// How far before the watermark the pump events still reconciled reach (`pumpEventReconciliationWindow`, 3 h by
    /// default): kept for trimming the ones after them
    private static let retention: TimeInterval = 6 * 60 * 60

    public init(date: Date? = nil) {
        self.date = date
    }

    /// The host stored `events`. Returns the basal-kind doses new to it in them - of positive duration - that start before
    /// the watermark as it was: never stored by Loop.
    /// The mutable basal-kind doses the host holds that start before the watermark: Loop no longer fetches them - the next
    /// sync resolves them away (`resolveMutable`), the running temp basal among them
    public var mutableBehind: [Date] {
        guard let date else {
            return []
        }
        return held.values.filter { $0.isMutable && $0.start < date }.map(\.start).sorted()
    }

    @discardableResult public mutating func store(_ events: [NewPumpEvent], replacePendingEvents: Bool) -> [DoseEntry] {
        let before = date

        if replacePendingEvents {
            held = held.filter { !$0.value.isMutable }
        }

        var behind: [DoseEntry] = []
        for event in events {
            guard let dose = event.dose, dose.type != .bolus else {
                continue
            }
            if let stored = held[event.raw], !stored.isMutable {
                continue
            }
            if held[event.raw] == nil, let before, dose.startDate < before, dose.endDate > dose.startDate {
                behind.append(dose)
            }
            held[event.raw] = Interval(type: dose.type, start: dose.startDate, end: dose.endDate, isMutable: dose.isMutable)
        }

        let doses = held.values.sorted { $0.start < $1.start }
        let fetched = Self.reconciled(doses).filter { entry in before.map { entry.start >= $0 } ?? true }

        var latest = before
        // From 24 h back with nothing stored yet: any first dose gets a fill
        var lastEnd = before ?? .distantPast
        for entry in fetched where entry.type != .resume {
            if entry.start.timeIntervalSince(lastEnd) > .ulpOfOne {
                // A scheduled fill, immutable, up to this one's start
                latest = max(latest ?? entry.start, entry.start)
            }
            if !entry.isMutable, entry.end > entry.start {
                latest = max(latest ?? entry.end, entry.end)
            }
            lastEnd = entry.end
        }
        date = latest

        if let latest {
            let oldest = latest.addingTimeInterval(-Self.retention)
            held = held.filter { $0.value.end >= oldest || $0.value.isMutable }
        }
        return behind
    }

    /// `Collection<DoseEntry>.reconciled()` (`InsulinMath` 396-519), on the times and mutability only
    static func reconciled(_ doses: [Interval]) -> [Interval] {
        var reconciled: [Interval] = []
        var lastSuspend: Interval?
        var lastBasal: Interval?

        for dose in doses {
            switch dose.type {
            case .bolus:
                continue
            case .basal,
                 .tempBasal:
                if lastSuspend == nil, let last = lastBasal {
                    let end = min(last.end, dose.start)
                    // Ignore 0-duration doses
                    if end > last.start {
                        reconciled.append(Interval(type: last.type, start: last.start, end: end, isMutable: last.isMutable))
                    }
                } else if let suspend = lastSuspend, dose.type == .tempBasal {
                    // A suspend with no resume, a temp basal after it
                    reconciled.append(Interval(type: suspend.type, start: suspend.start, end: dose.start, isMutable: suspend.isMutable))
                    lastSuspend = nil
                }
                lastBasal = dose
            case .resume:
                if let suspend = lastSuspend {
                    reconciled.append(Interval(type: suspend.type, start: suspend.start, end: dose.start, isMutable: suspend.isMutable))
                    lastSuspend = nil
                    // A temp basal that started before the suspend goes on after the resume
                    if let last = lastBasal {
                        lastBasal = last.end > dose.end ?
                            Interval(type: last.type, start: dose.end, end: last.end, isMutable: last.isMutable) : nil
                    }
                }
            case .suspend:
                if let last = lastBasal {
                    reconciled.append(Interval(type: last.type, start: last.start, end: min(last.end, dose.start), isMutable: last.isMutable))
                    if last.end <= dose.start {
                        lastBasal = nil
                    }
                }
                lastSuspend = dose
            }
        }

        if let suspend = lastSuspend {
            // Mutable until its resume
            reconciled.append(Interval(type: suspend.type, start: suspend.start, end: suspend.start, isMutable: true))
        } else if let last = lastBasal, last.end > last.start {
            reconciled.append(last)
        }

        return reconciled
    }
}

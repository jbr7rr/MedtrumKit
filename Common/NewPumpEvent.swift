import Foundation
import LoopKit

/// The `raw` of an event is its permanent identity: LoopKit derives `DoseEntry.syncIdentifier` from it.
/// It has to stay byte-for-byte identical for the whole life of a dose.
public extension NewPumpEvent {
    private static let dateFormatter = ISO8601DateFormatter()

    static func bolus(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "\(DoseType.bolus.rawValue) \(dose.programmedUnits) \(dateFormatter.string(from: dose.startDate))"
                .data(using: .utf8) ?? Data([]),
            title: String(localized: "Bolus", comment: "Pump Event title for UnfinalizedDose with doseType of .bolus")
        )
    }

    static func bolus(unfinalizedDose: UnfinalizedDose) -> NewPumpEvent {
        NewPumpEvent.bolus(dose: unfinalizedDose.toDoseEntry(isMutable: true))
    }

    static func tempBasal(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "\(DoseType.tempBasal.rawValue) \(dose.unitsPerHour) \(dateFormatter.string(from: dose.startDate))"
                .data(using: .utf8) ?? Data([]),
            title: String(localized: "Temp Basal", comment: "Pump Event title for UnfinalizedDose with doseType of .tempBasal")
        )
    }

    /// A bolus or temp basal reported off its `UnfinalizedDose`, as `entry` - nil for any other kind of dose. Same
    /// identity for every report of the dose, mutable or final.
    internal static func finishedDose(_ dose: UnfinalizedDose, entry: DoseEntry) -> NewPumpEvent? {
        switch dose.type {
        case .bolus:
            return NewPumpEvent.bolus(dose: entry)
        case .tempBasal:
            return NewPumpEvent.tempBasal(dose: entry)
        case .basal,
             .resume,
             .suspend:
            return nil
        }
    }

    static func basal(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "\(DoseType.basal.rawValue) \(dateFormatter.string(from: dose.startDate))".data(using: .utf8) ?? Data([]),
            title: String(localized: "Basal", comment: "Pump Event title for UnfinalizedDose with doseType of .basal")
        )
    }

    static func resume(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "\(DoseType.resume.rawValue) \(dateFormatter.string(from: dose.startDate))".data(using: .utf8) ?? Data([]),
            title: String(localized: "Resume", comment: "Pump Event title for UnfinalizedDose with doseType of .resume")
        )
    }

    static func suspend(dose: DoseEntry) -> NewPumpEvent {
        NewPumpEvent(
            date: dose.startDate,
            dose: dose,
            raw: "\(DoseType.suspend.rawValue) \(dateFormatter.string(from: dose.startDate))".data(using: .utf8) ?? Data([]),
            title: String(localized: "Suspended", comment: "Pump Event title for UnfinalizedDose with doseType of .suspend")
        )
    }

    static func replacedPump(date: Date = Date.now) -> NewPumpEvent {
        NewPumpEvent(
            date: date,
            dose: nil,
            raw: "PATCH_REPLACE \(dateFormatter.string(from: date))".data(using: .utf8) ?? Data([]),
            title: String(localized: "Patch replace", comment: "Pump Event title for replace patch"),
            type: .replaceComponent(componentType: .pump),
            alarmType: nil
        )
    }

    /// An alarm of `type` raised at `date` - nil for an alert that is none. Each its own event: its `raw` carries its date
    /// as well as its title. Loop keeps one pump event per `raw` and iAPS keys them by its hash - by its title alone,
    /// every alarm of a kind would be the first one to the host, a later one merged into it or dropped.
    internal static func alert(type: MedtrumAlert, date: Date = Date.now) -> NewPumpEvent? {
        guard let alertTitle = type.title, let alertType = type.type else {
            return nil
        }

        return NewPumpEvent(
            date: date,
            dose: nil,
            raw: "\(alertTitle) \(Int(date.timeIntervalSince1970))".data(using: .utf8) ?? Data([]),
            title: alertTitle,
            type: .alarm,
            alarmType: alertType
        )
    }
}

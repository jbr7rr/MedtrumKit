import Foundation
import LoopKit

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
            date: Date.now,
            dose: nil,
            raw: "PATCH_REPLACE \(dateFormatter.string(from: date))".data(using: .utf8) ?? Data([]),
            title: String(localized: "Patch replace", comment: "Pump Event title for replace patch"),
            type: .replaceComponent(componentType: .pump),
            alarmType: nil
        )
    }

    internal static func alert(type: MedtrumAlert) -> NewPumpEvent? {
        guard let alertTitle = type.title, let alertType = type.type else {
            return nil
        }

        return NewPumpEvent(
            date: Date.now,
            dose: nil,
            raw: alertTitle.data(using: .utf8) ?? Data([]),
            title: alertTitle,
            type: .alarm,
            alarmType: alertType
        )
    }
}

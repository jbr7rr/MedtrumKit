import LoopKit

enum MedtrumAlert {
    case patchExpiredNotification(after: TimeInterval)
    case lowReservoir(level: Double)
    case patchDailyMaxNotification
    case patchHourlyMaxNotification
    case occlusionNotification
    case patchFaultNotification
    case reservoirEmptyNotification
    case baseResetNotification

    var title: String? {
        switch self {
        case .patchDailyMaxNotification:
            return String(localized: "Alert: Daily Insulin Limit", comment: "alert daily limit")
        case .patchHourlyMaxNotification:
            return String(localized: "Alert: Hourly Insulin Limit", comment: "alert hourly limit")
        case .occlusionNotification:
            return String(localized: "Alert: Occlusion", comment: "alert occlusion")
        case .patchFaultNotification:
            return String(localized: "Alert: Patch fault", comment: "alert patch fault")
        case .reservoirEmptyNotification:
            return String(localized: "Alert: Reservoir empty", comment: "alert reservoir empty")
        case .baseResetNotification:
            return String(localized: "Alert: Pump base restarted", comment: "alert pump base reset")
        default:
            return nil
        }
    }

    var type: PumpAlarmType? {
        switch self {
        case .baseResetNotification,
             .patchDailyMaxNotification,
             .patchFaultNotification,
             .patchHourlyMaxNotification:
            return .noDelivery
        case .occlusionNotification:
            return .occlusion
        case .reservoirEmptyNotification:
            return .noInsulin
        default:
            return nil
        }
    }

    var alert: Alert {
        let content = alertContent
        return Alert(
            identifier: identifier,
            foregroundContent: content,
            backgroundContent: content,
            trigger: trigger,
        )
    }

    private static let managerIdentifier = "Medtrum"
    private var identifier: Alert.Identifier {
        switch self {
        case .patchExpiredNotification:
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.patch-expired"
            )
        case .patchDailyMaxNotification:
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.patch-daily-limit"
            )
        case .patchHourlyMaxNotification:
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.patch-hourly-limit"
            )
        case .occlusionNotification:
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.patch-occlussion"
            )
        case .patchFaultNotification:
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.patch-fault"
            )
        case .reservoirEmptyNotification:
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.patch-empty"
            )
        case .baseResetNotification:
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.base-reset"
            )
        case .lowReservoir:
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.reservoir-low"
            )
        }
    }

    private var alertContent: Alert.Content {
        switch self {
        case let .patchExpiredNotification(after):
            return Alert.Content(
                title: String(
                    localized: "Your patch will expire soon!",
                    comment: "Title expire reminder notification"
                ),
                body: String(
                    format: String(
                        localized: "Your patch has %lld hours left",
                        comment: "Body expire reminder notification"
                    ),
                    Int(80 - after.hours)
                ),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case .patchDailyMaxNotification:
            return Alert.Content(
                title: String(localized: "Insulin has been suspended!", comment: "Title insulin suspended notification"),
                body: String(localized: "Your patch has reached its daily maximum!", comment: "Body daily max notification"),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case .patchHourlyMaxNotification:
            return Alert.Content(
                title: String(localized: "Insulin has been suspended!", comment: "Title insulin suspended notification"),
                body: String(
                    localized: "Your patch has reached its hourly maximum!",
                    comment: "Body hourly max notification"
                ),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case .occlusionNotification:
            return Alert.Content(
                title: String(localized: "Replace your patch now!", comment: "Title replace patch notification"),
                body: String(localized: "Your patch has detected an occlusion!", comment: "Body occlusion notification"),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case .patchFaultNotification:
            return Alert.Content(
                title: String(localized: "Replace your patch now!", comment: "Title replace patch notification"),
                body: String(localized: "Your patch is in Fault state!", comment: "Body fault notification"),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case .reservoirEmptyNotification:
            return Alert.Content(
                title: String(localized: "Replace your patch now!", comment: "Title replace patch notification"),
                body: String(localized: "Your patch is out of insulin!", comment: "Body reservoir empty notification"),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case .baseResetNotification:
            return Alert.Content(
                title: String(localized: "Replace your patch now!", comment: "Title replace patch notification"),
                body: String(
                    localized: "Your pump base has restarted unexpectedly and is no longer delivering insulin!",
                    comment: "Body pump base reset notification"
                ),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case let .lowReservoir(level):
            return Alert.Content(
                title: String(
                    format: String(localized: "Reservoir low (%lld U)", comment: "Title low reservoir notification"),
                    Int(level)
                ),
                body: String(localized: "Your patch is running out of insulin!", comment: "Body low reservoir notification"),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        }
    }

    private var trigger: Alert.Trigger {
        switch self {
        case let .patchExpiredNotification(after):
            return Alert.Trigger.delayed(interval: after)
        default:
            return Alert.Trigger.immediate
        }
    }
}

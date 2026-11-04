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
    /// A bolus whose command went unanswered, finalized in full without its record
    case bolusCountedAsDelivered(units: Double)
    /// A bolus of ours running, or its command out, as the patch session was forced to end - or out as it ended, the app
    /// killed meanwhile: finalized in full, nothing of that patch heard from after - its command sent at `sentAt`
    case bolusCountedAsDeliveredAtSessionEnd(units: Double, sentAt: Date)
    /// A bolus the patch's records show delivered that matches no dose of ours, not counted - started at `at`
    case bolusNotCounted(units: Double, at: Date)
    /// A bolus of ours final from our estimate, `counted`, whose record came after all, `delivered` - started at `at`
    case bolusMiscounted(counted: Double, delivered: Double, at: Date)

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
        case .bolusCountedAsDelivered:
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.bolus-counted-as-delivered"
            )
        case let .bolusCountedAsDeliveredAtSessionEnd(_, sentAt):
            // One for each: several - one running, one out - are not one notification
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.bolus-counted-at-session-end.\(Int(sentAt.timeIntervalSince1970))"
            )
        case let .bolusNotCounted(_, at):
            // One for each: they are told of once
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.bolus-not-counted.\(Int(at.timeIntervalSince1970))"
            )
        case let .bolusMiscounted(_, _, at):
            // One for each: they are told of once
            return Alert.Identifier(
                managerIdentifier: MedtrumAlert.managerIdentifier,
                alertIdentifier: "com.nightscout.medtrumkit.bolus-miscounted.\(Int(at.timeIntervalSince1970))"
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
        case let .bolusCountedAsDelivered(units):
            return Alert.Content(
                title: String(localized: "Bolus counted as delivered", comment: "Title bolus counted as delivered notification"),
                body: String(
                    format: String(
                        localized: "The patch did not answer the command for a bolus of %@ U, and its records do not show it. The full amount was counted as delivered.",
                        comment: "Body bolus counted as delivered notification"
                    ),
                    units.formatted()
                ),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case let .bolusCountedAsDeliveredAtSessionEnd(units, _):
            return Alert.Content(
                title: String(localized: "Bolus counted as delivered", comment: "Title bolus counted as delivered notification"),
                body: String(
                    format: String(
                        localized: "The patch session ended before the patch told how much of the bolus of %@ U it delivered. The full amount was counted as delivered.",
                        comment: "Body bolus counted as delivered at the patch session end notification"
                    ),
                    units.formatted()
                ),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case let .bolusNotCounted(units, at):
            return Alert.Content(
                title: String(localized: "Bolus not counted", comment: "Title bolus not counted notification"),
                body: String(
                    format: String(
                        localized: "The patch's records show a bolus of %1$@ U delivered at %2$@ that is not in the app. Add it manually.",
                        comment: "Body bolus not counted notification"
                    ),
                    units.formatted(),
                    at.formatted(date: .abbreviated, time: .shortened)
                ),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case let .bolusMiscounted(counted, delivered, at) where delivered > counted:
            return Alert.Content(
                title: String(localized: "Bolus not fully counted", comment: "Title bolus under-counted notification"),
                body: String(
                    format: String(
                        localized: "The patch's records show %1$@ U delivered by the bolus at %2$@, the app counted %3$@ U. Add the %4$@ U missing manually.",
                        comment: "Body bolus under-counted notification"
                    ),
                    delivered.rounded(toPlaces: 2).formatted(),
                    at.formatted(date: .abbreviated, time: .shortened),
                    counted.rounded(toPlaces: 2).formatted(),
                    (delivered - counted).rounded(toPlaces: 2).formatted()
                ),
                acknowledgeActionButtonLabel: String(
                    localized: "OK",
                    comment: "Acknoledge alert"
                )
            )
        case let .bolusMiscounted(counted, delivered, at):
            return Alert.Content(
                title: String(localized: "Bolus counted too high", comment: "Title bolus over-counted notification"),
                body: String(
                    format: String(
                        localized: "The patch's records show %1$@ U delivered by the bolus at %2$@, the app counted %3$@ U. Insulin on board is overstated by %4$@ U.",
                        comment: "Body bolus over-counted notification"
                    ),
                    delivered.rounded(toPlaces: 2).formatted(),
                    at.formatted(date: .abbreviated, time: .shortened),
                    counted.rounded(toPlaces: 2).formatted(),
                    (counted - delivered).rounded(toPlaces: 2).formatted()
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

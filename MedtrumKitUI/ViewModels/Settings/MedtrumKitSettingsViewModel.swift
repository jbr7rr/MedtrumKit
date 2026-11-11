import LoopKit
import LoopKitUI
import SwiftUI

/// One dose the driver could not be sure of, as the settings screen tells of it - see `UncertainDelivery`
struct UncertainDeliveryNotice: Identifiable {
    let id: String
    let title: String
    let cause: String
    let status: String
    /// What to do meanwhile, while it is not settled
    let advice: String?
    let isSettled: Bool
    /// Still uncertain: what the host counts may not be what the patch delivered
    let isUncertain: Bool
}

enum PatchLifecycleState {
    case noPatch
    case active
    case activeLast24h
    case gracePeriod
    case expired
    case expiredBasalOnly
    case fault
}

class MedtrumKitSettingsViewModel: PatchLifetimeFormatting, ObservableObject, PumpManagerStatusObserver {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.settingsViewModel")

    @Published var model: String = ""
    @Published var is300u: Bool = false
    @Published var showPumpTimeSyncWarning = false
    @Published var reservoirLevel: Double = 0
    @Published var maxReservoirLevel: Double = 1
    @Published var pumpTime = Date.distantPast
    @Published var pumpTimeSyncedAt = Date.distantPast
    @Published var patchState: PatchState = .none
    /// The "Activate Patch" row with a patch shown: one being set up, or one running whose session never started - its
    /// activation's answer lost, the sheet dismissed since - for the activation's retry, which starts it
    @Published var showsActivatePatch = false
    @Published var patchStateString: String = PatchState.none.description
    @Published var basalType: DoseType = .basal
    @Published var basalRate: String = ""
    @Published var tempBasalManual = false
    @Published var insulinType: InsulinType = .novolog
    @Published var lastSync = Date.distantPast
    @Published var hourlyLimit = 0
    @Published var dailyLimit = 0
    @Published var patchLifecycleProgress: Double = 0
    @Published var patchLifecycleState: PatchLifecycleState = .noPatch
    @Published var patchLifetime: String = ""
    @Published var patchActivatedAt: Date? = nil
    @Published var patchExpiresAt: Date? = nil
    @Published var patchGracePeriodFrom: Date? = nil
    @Published var patchGraceTimeout = ""
    @Published var isConnected: Bool = false
    @Published var isReconnecting: Bool = false
    @Published var isUpdatingPumpState = false
    @Published var isUpdatingSuspend = false
    @Published var isUpdatingTempBasal = false
    @Published var showingHeartbeatWarning = false
    @Published var showingDeleteConfirmation = false
    @Published var showingSuspendPicker = false
    @Published var showingStopTempBasalConfirmation = false
    @Published var hasPreviousPatch = false
    @Published var isClearingAlert = false
    /// Newest first
    @Published var uncertainDeliveries: [UncertainDeliveryNotice] = []

    @Published var useSilentTones = false {
        didSet {
            // prevent infinite loop: notifyStateDidChange() -> notify observers -> notify this view model -> set useSilentTones -> notifyStateDidChange() -> ...
            guard pumpManager?.state.useSilentTones != useSilentTones else {
                return
            }

            pumpManager?.state.useSilentTones = useSilentTones
            pumpManager?.notifyStateDidChange()
        }
    }

    public var pumpName: String {
        pumpManager?.state.pumpName ?? "Medtrum Nano"
    }

    let reservoirVolumeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.roundingMode = .floor
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    let basalRateFormatter: NumberFormatter = {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumFractionDigits = 1
        numberFormatter.minimumIntegerDigits = 1
        return numberFormatter
    }()

    let dateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    let dateTimeFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    let noticeDateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    let unitsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = 1
        return formatter
    }()

    let timeRemainingFormatter: DateComponentsFormatter = {
        let dateComponentsFormatter = DateComponentsFormatter()
        dateComponentsFormatter.allowedUnits = [.hour, .minute]
        dateComponentsFormatter.unitsStyle = .full
        dateComponentsFormatter.zeroFormattingBehavior = .dropAll
        return dateComponentsFormatter
    }()

    let deactivatePatchAction: () -> Void
    let pumpRemovalAction: () -> Void
    let toSettings: () -> Void
    let toTempBasal: () -> Void
    let toPatchDetails: () -> Void
    let toPreviousPatchDetails: () -> Void
    let toPumpRecords: () -> Void
    let toInsulinType: () -> Void
    let pumpActivationAction: (Bool) -> Void
    let activatePatchAction: () -> Void
    private let log = MedtrumLogger(category: "settingsViewModel")
    private let pumpManager: MedtrumPumpManager?
    init(
        _ pumpManager: MedtrumPumpManager?,
        _ deactivatePatchAction: @escaping () -> Void,
        _ pumpActivationAction: @escaping (Bool) -> Void,
        _ toSettings: @escaping () -> Void,
        _ toTempBasal: @escaping () -> Void,
        _ toPatchDetails: @escaping () -> Void,
        _ toPreviousPatchDetails: @escaping () -> Void,
        _ toPumpRecords: @escaping () -> Void,
        _ toInsulinType: @escaping () -> Void,
        _ pumpRemovalAction: @escaping () -> Void,
        _ activatePatchAction: @escaping () -> Void
    ) {
        self.pumpManager = pumpManager
        self.deactivatePatchAction = deactivatePatchAction
        self.pumpActivationAction = pumpActivationAction
        self.pumpRemovalAction = pumpRemovalAction
        self.toInsulinType = toInsulinType
        self.toPatchDetails = toPatchDetails
        self.toPreviousPatchDetails = toPreviousPatchDetails
        self.toPumpRecords = toPumpRecords
        self.toSettings = toSettings
        self.toTempBasal = toTempBasal
        self.activatePatchAction = activatePatchAction
        super.init()

        guard let pumpManager = pumpManager else {
            return
        }

        // Not the BLE link in the tests
        isConnected = pumpManager.bluetooth?.isConnected ?? false
        updateState(pumpManager.state)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func reservoirText(for units: Double) -> String {
        reservoirVolumeFormatter.string(from: units as NSNumber) ?? ""
    }

    var tempBasalRemaining: String? {
        guard basalType == .tempBasal, let pumpManager else {
            return nil
        }

        let remaining = pumpManager.state.basalDose.estimatedEndDate.timeIntervalSinceNow
        let hours = Int(floor(remaining.hours))
        let minutes = Int(floor(remaining.minutes))

        if hours > 0 {
            return String(
                format: String(localized: "(%lld hr %lld min)", comment: "temp basal remaining hours+minutes"),
                hours,
                minutes - hours * 60
            )
        }

        return String(
            format: String(localized: "(%lld min)", comment: "temp basal remaining minutes"),
            minutes
        )
    }

    var patchLifecycleDays: Int? {
        guard patchLifecycleState == .active || patchLifecycleState == .activeLast24h, let patchGracePeriodFrom else {
            return nil
        }

        return Int((patchGracePeriodFrom.timeIntervalSince1970 - Date.now.timeIntervalSince1970).days.rounded(.towardZero))
    }

    var patchLifecycleHours: Int? {
        guard patchLifecycleState == .active || patchLifecycleState == .activeLast24h, let patchGracePeriodFrom else {
            return nil
        }

        return Int(
            (patchGracePeriodFrom.timeIntervalSince1970 - Date.now.timeIntervalSince1970).hours
                .truncatingRemainder(dividingBy: 24).rounded(.towardZero)
        )
    }

    var patchLifecycleMinutes: Int? {
        guard patchLifecycleState == .active || patchLifecycleState == .activeLast24h, let patchGracePeriodFrom else {
            return nil
        }

        return Int(
            (patchGracePeriodFrom.timeIntervalSince1970 - Date.now.timeIntervalSince1970).minutes
                .truncatingRemainder(dividingBy: 60).rounded(.towardZero)
        )
    }

    func syncData() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        isUpdatingPumpState = true
        pumpManager.syncPumpData { _ in
            DispatchQueue.main.async {
                self.isUpdatingPumpState = false
            }
        }
    }

    func clearAlert(_ alertType: AlertType) {
        guard let pumpManager else {
            return
        }

        isClearingAlert = true
        pumpManager.clearAlert(alertType: alertType) { _ in
            DispatchQueue.main.async {
                self.isClearingAlert = false
            }
        }
    }

    func didChangeInsulinType(_ newType: InsulinType?) {
        guard let type = newType else {
            return
        }

        pumpManager?.state.insulinType = type
        pumpManager?.notifyStateDidChange()
        insulinType = type
    }

    func stopUsingMedtrum() {
        guard let pumpManager = self.pumpManager else {
            pumpRemovalAction()
            return
        }

        pumpManager.notifyDelegateOfDeactivation {
            DispatchQueue.main.async {
                self.pumpRemovalAction()
            }
        }
    }

    func getLogs() -> [URL] {
        if let pumpManager = self.pumpManager {
            log.info(pumpManager.state.debugDescription)
        }
        // After the log files: the record history of the current patch and the previous one, written out first
        return log.getDebugLogs() + (pumpManager?.recordHistoryFilesForSharing() ?? [])
    }

    func toPumpActivation() {
        guard let pumpManager = self.pumpManager else {
            pumpActivationAction(false)
            return
        }

        // Activated with no session: the activation's retry, not priming
        let state = pumpManager.state
        pumpActivationAction(state.pumpState.hasCompletedPriming || state.isActivatedWithNoSession)
    }

    /// The "Activate Patch" row with no patch shown - none activated, or its id not named yet: a patch running whose
    /// session never started goes to the activation's retry, not to setting up a new one from the base
    func activatePatchPressed() {
        guard pumpManager?.state.isActivatedWithNoSession == true else {
            activatePatchAction()
            return
        }
        toPumpActivation()
    }

    func suspendDelivery(duration: TimeInterval) {
        guard let pumpManager else {
            return
        }

        isUpdatingSuspend = true
        pumpManager.suspendPatch(duration: duration) { error in
            DispatchQueue.main.async {
                self.isUpdatingSuspend = false
            }

            if let error = error {
                self.log.error("Failed to suspend delivery: \(error)")
            }
        }
    }

    func suspendResumeButtonPressed() {
        if basalType != .suspend {
            showingSuspendPicker = true
            return
        }

        guard let pumpManager = self.pumpManager else {
            return
        }

        isUpdatingSuspend = true
        pumpManager.resumeDelivery { error in
            DispatchQueue.main.async {
                self.isUpdatingSuspend = false
            }

            if let error = error {
                self.log.error("Failed to resume delivery: \(error)")
            }
        }
    }

    func stopTempBasal() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        // This goes straight to the pump manager, so the host never sees it and never logs it. Say so
        // here, or a temp basal cancelled from this screen looks like it came out of nowhere.
        log.info("Stop temp basal (from settings)")
        isUpdatingTempBasal = true
        pumpManager.enactTempBasal(unitsPerHour: 0, for: 0) { error in
            DispatchQueue.main.async {
                self.isUpdatingTempBasal = false
            }

            if let error = error {
                self.log.error("Failed to stop temp basal: \(error)")
            }
        }
    }

    func checkConnection() {
        guard let pumpManager = self.pumpManager else {
            return
        }

        if !pumpManager.bluetooth.isConnected {
            // Reconnect to patch
            isReconnecting = true
            pumpManager.bluetooth.ensureConnected { _ in
                DispatchQueue.main.async {
                    self.isReconnecting = false
                }
            }
            return
        } else {
            // Disconnect from patch
            pumpManager.bluetooth.disconnect(force: true)
            return
        }
    }

    func syncPumpTime() {
        guard let pumpManager = pumpManager else {
            return
        }

        isUpdatingPumpState = true
        pumpManager.bluetooth.ensureConnected { error in
            if error != nil {
                DispatchQueue.main.async {
                    self.isUpdatingPumpState = false
                }
                return
            }

            StateSyncer.syncTime(pumpManager: pumpManager)
            DispatchQueue.main.async {
                self.isUpdatingPumpState = false
            }
        }
    }
}

extension MedtrumKitSettingsViewModel {
    func pumpManager(
        _ pumpManager: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            return
        }

        DispatchQueue.main.async {
            self.isConnected = pumpManager.bluetooth?.isConnected ?? false
            self.updateState(pumpManager.state)
        }
    }

    private func updateState(_ state: MedtrumPumpState) {
        model = state.model
        switch model {
        case "MD8301":
            is300u = true
            maxReservoirLevel = 300
        default:
            is300u = false
            maxReservoirLevel = 200
        }

        showPumpTimeSyncWarning = state.shouldShowTimeWarning()
        patchState = state.pumpState
        showsActivatePatch = state.pumpState.isAwaitingActivation || state.isActivatedWithNoSession
        useSilentTones = state.useSilentTones
        patchStateString = state.pumpState.description
        pumpTime = state.pumpTime
        pumpTimeSyncedAt = state.pumpTimeSyncedAt
        reservoirLevel = patchState != .reservoirEmpty ? state.reservoir : 0
        basalType = state.basalDose.type
        basalRate = basalRateFormatter
            .string(from: (basalType == .tempBasal ? state.basalDose.value : state.currentBaseBasalRate) as NSNumber) ?? ""
        tempBasalManual = state.basalDose.type == .tempBasal && !state.basalDose.automatic
        lastSync = state.lastSync
        patchActivatedAt = state.patchActivatedAt
        patchGracePeriodFrom = state.patchGracePeriodFrom
        patchExpiresAt = state.patchExpiresAt
        if let patchActivatedAt = state.patchActivatedAt {
            patchLifetime = processPatchLifetime(patchActivatedAt, Date())
        }
        hasPreviousPatch = state.previousPatch != nil
        hourlyLimit = Int(state.maxHourlyInsulin)
        dailyLimit = Int(state.maxDailyInsulin)

        if !state.patchId.isEmpty, let patchActivatedAt, let patchGracePeriodFrom {
            let totalLifetime = patchGracePeriodFrom.timeIntervalSince(patchActivatedAt)
            let progress = Date.now.timeIntervalSince1970 - patchActivatedAt.timeIntervalSince1970

            patchLifecycleProgress = min(progress / totalLifetime, 1)
            patchLifecycleState = getLifecycleState(state: state)

            if patchLifecycleState == .gracePeriod, let patchExpiresAt {
                let timeRemaining = patchExpiresAt.timeIntervalSinceNow
                patchGraceTimeout = timeRemainingFormatter.string(from: timeRemaining) ?? ""
            }
        } else {
            patchLifecycleState = .noPatch
        }

        if let insulinType = state.insulinType {
            self.insulinType = insulinType
        }

        uncertainDeliveries = state.uncertainDeliveries.reversed().map { notice(for: $0, phase: state.phase(of: $0)) }
    }

    func notice(for delivery: UncertainDelivery, phase: UncertainDelivery.Phase) -> UncertainDeliveryNotice {
        let amount = unitsFormatter.string(from: delivery.amount as NSNumber) ?? "\(delivery.amount)"
        let delivered = delivery.delivered.map { unitsFormatter.string(from: $0 as NSNumber) ?? "\($0)" } ?? "-"

        let title: String
        switch delivery.kind {
        case .bolus:
            title = String(
                format: String(localized: "Bolus of %1$@ U (%2$@)", comment: "uncertain delivery notice: the bolus, and when"),
                amount,
                noticeDateFormatter.string(from: delivery.sentAt)
            )
        case .tempBasal:
            title = String(
                format: String(
                    localized: "Temp basal of %1$@ U/h (%2$@)",
                    comment: "uncertain delivery notice: the temp basal, and when"
                ),
                amount,
                noticeDateFormatter.string(from: delivery.sentAt)
            )
        case .tempBasalCancel:
            title = String(
                format: String(
                    localized: "Cancel of the temp basal of %1$@ U/h (%2$@)",
                    comment: "uncertain delivery notice: the cancel of a temp basal, and when"
                ),
                amount,
                noticeDateFormatter.string(from: delivery.notedAt)
            )
        }

        var cause: String
        switch delivery.cause {
        case .unanswered:
            cause = String(localized: "The patch did not confirm the command.", comment: "uncertain delivery cause: unconfirmed")
        case .endNotSeen:
            cause = String(localized: "The end of the bolus was not seen.", comment: "uncertain delivery cause: end not seen")
        case .appRestarted:
            cause = String(
                localized: "The app was restarted while the command was out.",
                comment: "uncertain delivery cause: app restarted"
            )
        case .patchDeactivated:
            cause = String(
                localized: "The patch session ended during the bolus.",
                comment: "uncertain delivery cause: the patch session ended"
            )
        case .unknownSegment:
            cause = String(
                localized: "A status showed the patch running a temp basal the app has no record of.",
                comment: "uncertain delivery cause: a temp basal running that the app did not know of"
            )
        case .stalled:
            cause = ""
        }
        // A bolus that stood still while the patch kept answering - its cause, or told of with another
        if let stalledFor = delivery.stalledFor {
            let stall = delivery.stallResumed ? String(
                format: String(
                    localized: "Delivered slowly: up to %lld s between the patch's steps, then at its pace to the end.",
                    comment: "uncertain delivery cause: a bolus that stalled, then went on at the patch's pace (longest gap in seconds)"
                ),
                Int(stalledFor)
            ) : String(
                format: String(
                    localized: "The bolus stalled: no progress for %lld s while the patch kept answering. Possible occlusion: the patch counts the insulin whether it went in or not.",
                    comment: "uncertain delivery cause: a bolus that stalled (longest time without progress in seconds)"
                ),
                Int(stalledFor)
            )
            cause = cause.isEmpty ? stall : cause + " " + stall
        }

        var status: String
        switch phase {
        case .countedInFull:
            status = String(
                format: String(
                    localized: "Counted as the full %@ U until the patch's record says what it delivered.",
                    comment: "uncertain delivery status: bolus counted in full"
                ),
                amount
            )
        case let .countedAs(units):
            status = String(
                format: String(
                    localized: "Counted as the %@ U the patch reported until its record says what it delivered.",
                    comment: "uncertain delivery status: bolus counted as reported"
                ),
                unitsFormatter.string(from: units as NSNumber) ?? "\(units)"
            )
        case .notReported:
            status = String(
                localized: "Not counted until a status or its record shows that the patch ran it.",
                comment: "uncertain delivery status: temp basal not reported"
            )
        case .awaitingRecord:
            status = delivery.kind == .tempBasalCancel ? String(
                localized: "The temp basal ended. Final once its record is read.",
                comment: "uncertain delivery status: cancelled temp basal awaiting record"
            ) : String(
                localized: "The patch ran it. Final once its record is read.",
                comment: "uncertain delivery status: awaiting record"
            )
        case .countedRunning:
            status = String(
                localized: "Counted as running until a status shows whether the cancel stopped it.",
                comment: "uncertain delivery status: temp basal counted running"
            )
        case .stillRunning:
            status = String(
                localized: "A status shows the temp basal still running: the cancel did not stop it.",
                comment: "uncertain delivery status: temp basal still running"
            )
        case .settled(.byRecord):
            status = delivery.record.map { record in
                String(
                    format: String(
                        localized: "Settled by the patch's record #%1$lld: %2$@ U delivered.",
                        comment: "uncertain delivery status: settled by a numbered record"
                    ),
                    record,
                    delivered
                )
            } ?? String(
                format: String(
                    localized: "Settled by the patch's records: %@ U delivered.",
                    comment: "uncertain delivery status: settled by records"
                ),
                delivered
            )
        case .settled(.byEstimate):
            status = String(
                format: String(
                    localized: "Final without its record: counted as %@ U.",
                    comment: "uncertain delivery status: settled by estimate"
                ),
                delivered
            )
        case .settled(.neverRan):
            status = String(
                localized: "The patch's records show it never ran: 0 U.",
                comment: "uncertain delivery status: never ran"
            )
        case .settled(.notConfirmed):
            let duration = delivery.duration.flatMap { timeRemainingFormatter.string(from: $0) } ?? "-"
            status = String(
                format: String(
                    localized: "Not counted: the patch never showed it running, but may have run it - %1$@ U/h for up to %2$@.",
                    comment: "uncertain delivery status: temp basal never confirmed, not counted"
                ),
                amount,
                duration
            )
        case .settled(.final):
            status = String(
                format: String(localized: "Final: %@ U.", comment: "uncertain delivery status: final, how not known"),
                delivered
            )
        case .settled(.untracked):
            status = String(
                localized: "No longer tracked.",
                comment: "uncertain delivery status: its dose no longer tracked"
            )
        case .settled(.notCounted):
            status = String(
                localized: "Not counted: what it delivered is not known.",
                comment: "uncertain delivery status: an unknown temp basal, not counted"
            )
        }
        // A cancel the patch did not act on: still so once its temp basal ended, waiting on its record or settled
        if delivery.cancelDidNotStop, phase != .stillRunning {
            status = String(
                localized: "The cancel did not stop it: the patch kept running it.",
                comment: "uncertain delivery status: settled cancel, its temp basal shown still running after it"
            ) + " " + status
        }

        var advice: String?
        let isUncertain: Bool
        switch phase {
        case .countedInFull,
             .countedAs:
            isUncertain = true
            advice = String(
                localized: "Don't bolus again to make up for it. Keep the phone near the patch: its record is usually read within minutes.",
                comment: "uncertain delivery advice for a bolus"
            )
        case .notReported:
            isUncertain = true
            advice = String(
                localized: "Keep the phone near the patch: a status or its record settles it. If its records cannot be read, it may stay uncertain.",
                comment: "uncertain delivery advice for a temp basal not reported"
            )
        case .countedRunning:
            isUncertain = true
            advice = String(
                localized: "Keep the phone near the patch: the next status settles it.",
                comment: "uncertain delivery advice for a cancel"
            )
        case .settled(.notCounted):
            isUncertain = true
            advice = String(
                localized: "Check the patch's basal. Setting or cancelling a temp basal from the app replaces it.",
                comment: "uncertain delivery advice for an unknown temp basal"
            )
        case .awaitingRecord,
             .stillRunning,
             .settled:
            isUncertain = false
            advice = nil
        }
        // Its record will not tell: the patch records what it was set to deliver
        if delivery.stalledFor != nil, !delivery.stallResumed {
            advice = String(
                localized: "Check the infusion site and your glucose. If it keeps rising, replace the patch: its record will not tell whether the insulin went in.",
                comment: "uncertain delivery advice for a bolus that stalled"
            )
        }

        return UncertainDeliveryNotice(
            id: "\(delivery.kind.rawValue)-\(delivery.sentAt.timeIntervalSince1970)-\(delivery.notedAt.timeIntervalSince1970)",
            title: title,
            cause: cause,
            status: status,
            advice: advice,
            isSettled: delivery.isSettled,
            isUncertain: isUncertain
        )
    }

    func clearSettledUncertainDeliveries() {
        pumpManager?.clearSettledUncertainDeliveries()
    }

    private func getLifecycleState(state: MedtrumPumpState) -> PatchLifecycleState {
        if state.pumpState.isFault {
            return .fault
        }

        if patchLifecycleProgress < 1 {
            if let patchGracePeriodFrom = state.patchGracePeriodFrom,
               patchGracePeriodFrom.addingTimeInterval(.days(-1)) <= Date.now
            {
                return .activeLast24h
            } else {
                return .active
            }
        }

        if let patchExpiresAt, Date.now > patchExpiresAt {
            return state.expiryMode == .extended ? .expiredBasalOnly : .expired
        }

        return .gracePeriod
    }
}

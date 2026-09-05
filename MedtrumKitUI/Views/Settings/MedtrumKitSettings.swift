import LoopKit
import SwiftUI

struct MedtrumKitSettings: View {
    @State private var showingTimeSyncConfirmation: Bool = false
    @State private var isSharePresented: Bool = false
    @ObservedObject var viewModel: MedtrumKitSettingsViewModel

    @Environment(\.dismissAction) private var dismiss
    @Environment(\.insulinTintColor) var insulinTintColor
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.appName) private var appName

    var syncPumpTime: ActionSheet {
        ActionSheet(
            title: Text("Time Change Detected", comment: "Title for pod sync time action sheet."),
            message: Text(
                "The time on your pump is different from the current time. Do you want to update the time on your pump to the current time?",
                comment: "Message for pod sync time action sheet"
            ),
            buttons: [
                .default(Text("Yes, Sync to Current Time", comment: "Button text to confirm pump time sync")) {
                    self.viewModel.syncPumpTime()
                },
                .cancel(Text("No, Keep Pump As Is", comment: "Button text to cancel pump time sync"))
            ]
        )
    }

    var suspendSheet: ActionSheet {
        ActionSheet(
            title: Text("Suspend Insulin Delivery", comment: "Title for suspend action"),
            message: Text(
                "How long you wish to suspend your patch maximum? It will resume automaticly after this time.",
                comment: "Message for suspend action"
            ),
            buttons: [
                .default(Text("30 minutes", comment: "suspend for 30 min")) {
                    self.viewModel.suspendDelivery(duration: .minutes(30))
                },
                .default(Text("1 hour", comment: "suspend for 1h")) {
                    self.viewModel.suspendDelivery(duration: .minutes(60))
                },
                .default(Text("1.5 hours", comment: "suspend for 1.5h")) {
                    self.viewModel.suspendDelivery(duration: .minutes(90))
                },
                .default(Text("2 hours", comment: "suspend for 2h")) {
                    self.viewModel.suspendDelivery(duration: .minutes(120))
                },
                .cancel(Text("Cancel", comment: "button cancel"))
            ]
        )
    }

    var body: some View {
        List {
            Section {
                VStack {
                    PumpImage(is300u: viewModel.is300u)
                    patchLifecycle
                }

                if viewModel.patchLifecycleState != .noPatch && viewModel.patchLifecycleState != .expired {
                    HStack(alignment: .top) {
                        deliveryStatus
                        Spacer()
                        reservoirStatus
                    }
                    .padding(.bottom, 5)
                }

                if viewModel.showPumpTimeSyncWarning {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time Change Detected", comment: "title for time change detected notice")
                            .font(Font.subheadline.weight(.bold))
                        Text(
                            "The time on your pump is different from the current time. Your pump’s time controls your scheduled therapy settings. Scroll down to Pump Time row to review the time difference and configure your pump.",
                            comment: "description for time change detected notice"
                        )
                        .font(Font.footnote.weight(.semibold))
                    }.padding(.vertical, 8)
                }

                if viewModel.patchLifecycleState == .gracePeriod {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: String(
                            localized: "Change your Patch now. Insulin delivery will stop in %@ or when no more insulin remains.",
                            comment: "description for grace period notice"
                        ), viewModel.patchGraceTimeout))
                            .font(Font.footnote.weight(.semibold))
                    }.padding(.vertical, 8)
                }

                if viewModel.patchState == .hourlyMaxSuspended {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Alert: Hourly max insulin", comment: "title hourlyMaxSuspended")
                            .font(Font.footnote.weight(.semibold))
                        Text(
                            String(
                                format: String(
                                    localized:
                                    "Patch is suspended. Limit of %lld U exceeded. If you increase the limit, you can clear the alert now. If you wait, patch will resume when enough time passes.",
                                    comment: "description dailyMaxSuspended"
                                ),
                                viewModel.hourlyLimit
                            )
                        )
                        .font(.footnote)
                        .padding(.bottom, 4)

                        Button {
                            viewModel.clearAlert(AlertType.hourly)
                        } label: {
                            Text("Clear alert", comment: "")
                                .font(.title3)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isClearingAlert)

                    }.padding(.vertical, 8)
                }

                if viewModel.patchState == .dailyMaxSuspended {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Alert: Daily max insulin", comment: "title dailyMaxSuspended")
                            .font(Font.footnote.weight(.semibold))
                        Text(
                            String(
                                format: String(
                                    localized:
                                    "Patch is suspended. Limit of %lld U exceeded. If you increase the limit, you can clear the alert now. If you wait, patch will resume when enough time passes.",
                                    comment: "description dailyMaxSuspended"
                                ),
                                viewModel.dailyLimit
                            )
                        )
                        .font(.footnote)
                        .padding(.bottom, 4)

                        Button {
                            viewModel.clearAlert(AlertType.daily)
                        } label: {
                            Text("Clear alert", comment: "")
                                .font(.title3)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isClearingAlert)
                    }.padding(.vertical, 8)
                }
            }

            Section {
                if viewModel.patchLifecycleState != .noPatch {
                    Button(action: {
                        viewModel.suspendResumeButtonPressed()
                    }) {
                        HStack {
                            if viewModel.basalType == .suspend {
                                Text("Resume Insulin Delivery", comment: "Resume patch")
                            } else {
                                Text("Suspend Insulin Delivery", comment: "Suspend patch")
                            }
                            Spacer()
                            if viewModel.isUpdatingSuspend {
                                ActivityIndicator()
                            }
                        }
                    }
                    .disabled(
                        viewModel.isUpdatingPumpState || viewModel.isUpdatingTempBasal || viewModel
                            .isUpdatingSuspend || viewModel.isClearingAlert
                    )
                    .actionSheet(isPresented: $viewModel.showingSuspendPicker) {
                        suspendSheet
                    }

                    if viewModel.basalType == .tempBasal {
                        Button(action: {
                            viewModel.stopTempBasal()
                        }) {
                            HStack {
                                Text("Stop Temp Basal", comment: "Stop temp basal")
                                Spacer()
                                if viewModel.isUpdatingTempBasal {
                                    ActivityIndicator()
                                }
                            }
                        }
                        .disabled(
                            viewModel.isUpdatingPumpState || viewModel.isUpdatingTempBasal || viewModel
                                .isUpdatingSuspend || viewModel.isClearingAlert
                        )
                    }

                    Button(action: { viewModel.syncData() }) {
                        HStack {
                            Text("Sync Patch Data", comment: "sync pump")
                            Spacer()
                            if viewModel.isUpdatingPumpState {
                                ActivityIndicator()
                            }
                        }
                    }
                    .disabled(
                        viewModel.isUpdatingPumpState || viewModel.isUpdatingTempBasal || viewModel
                            .isUpdatingSuspend || viewModel.isClearingAlert
                    )

                    if !viewModel.tempBasalManual {
                        Button(action: { viewModel.toTempBasal() }) {
                            HStack {
                                Text("Manual Temp Basal", comment: "sync pump")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if viewModel.patchState.rawValue < PatchState.active.rawValue && viewModel.patchState != .none {
                        Button(action: { viewModel.toPumpActivation() }) {
                            HStack {
                                Text("Activate Patch", comment: "label for activate patch")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                    .opacity(0.35)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(action: { viewModel.checkConnection() }) {
                        HStack {
                            if viewModel.isConnected {
                                Text("Disconnect", comment: "disconnect from patch")
                            } else {
                                Text("Reconnect", comment: "reconnect to patch")
                            }
                            Spacer()
                            if viewModel.isReconnecting {
                                ActivityIndicator()
                            }
                        }
                    }

                    Button(action: { viewModel.deactivatePatchAction() }) {
                        HStack {
                            Text("Deactivate Patch", comment: "deactivate patch")
                                .foregroundStyle(.red)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                .opacity(0.5)
                                .foregroundColor(.red)
                        }
                    }

                    HStack {
                        Text("Patch State", comment: "Text for patch state")
                            .foregroundColor(Color.primary)
                        Spacer()
                        Text(viewModel.patchStateString)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Last Sync", comment: "Text for last sync")
                            .foregroundColor(Color.primary)
                        Spacer()
                        if viewModel.patchLifecycleState != .noPatch {
                            Text(viewModel.dateFormatter.string(from: viewModel.lastSync))
                                .foregroundColor(.secondary)
                        } else {
                            Text("-")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Status", comment: "Text for status")
                            .foregroundColor(Color.primary)
                        Spacer()
                        HStack(spacing: 10) {
                            connectionStatusText
                            connectionStatusIcon
                        }
                    }
                } else {
                    Button(action: { viewModel.activatePatchAction() }) {
                        HStack {
                            Text("Activate Patch", comment: "activate patch")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                .opacity(0.5)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Insulin Type", comment: "Text for selecting insulin type")
                        .foregroundColor(Color.primary)
                    Spacer()
                    Text(viewModel.insulinType.brandName)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIFont.systemFontSize, weight: .medium))
                        .opacity(0.3)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.toInsulinType()
                }

                HStack {
                    Text("Patch Settings", comment: "Text for patch settings view")
                        .foregroundColor(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIFont.systemFontSize, weight: .medium))
                        .opacity(0.3)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.toSettings()
                }
            } header: {
                Text("Configuration", comment: "Configuration section")
            }

            Section {
                HStack {
                    Text("Cannula Age", comment: "Text for cannula age (CAGE)")
                        .foregroundColor(Color.primary)
                    Spacer()
                    if viewModel.patchLifecycleState != .noPatch {
                        Text(viewModel.patchLifetime)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("-")
                            .foregroundColor(.secondary)
                    }
                }
                if let activatedAt = viewModel.patchActivatedAt {
                    HStack {
                        Text("Activation", comment: "Text for activatedAt")
                            .foregroundColor(Color.primary)
                        Spacer()
                        if viewModel.patchLifecycleState != .noPatch {
                            Text(viewModel.dateTimeFormatter.string(from: activatedAt))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("-")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let gracePeriodFrom = viewModel.patchGracePeriodFrom {
                    HStack {
                        Text("Expiration", comment: "Text for expiresAt")
                            .foregroundColor(Color.primary)
                        Spacer()
                        if viewModel.patchLifecycleState != .noPatch {
                            Text(viewModel.dateTimeFormatter.string(from: gracePeriodFrom))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("-")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let expiresAt = viewModel.patchExpiresAt {
                    HStack {
                        Text("No Delivery", comment: "Text for expiresAt")
                            .foregroundColor(Color.primary)
                        Spacer()
                        if viewModel.patchLifecycleState != .noPatch {
                            Text(viewModel.dateTimeFormatter.string(from: expiresAt))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("-")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                HStack {
                    Text("Patch Details", comment: "header patch details")
                        .foregroundColor(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIFont.systemFontSize, weight: .medium))
                        .opacity(0.3)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.toPatchDetails()
                }
                HStack {
                    Text("Previous Patch Details", comment: "header patch details")
                        .foregroundColor(Color.primary)
                    Spacer()
                    if viewModel.hasPreviousPatch {
                        Image(systemName: "chevron.right")
                            .font(.system(size: UIFont.systemFontSize, weight: .medium))
                            .opacity(0.3)
                    } else {
                        Text("-")
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if viewModel.hasPreviousPatch {
                        viewModel.toPreviousPatchDetails()
                    }
                }

            } header: {
                Text("Information", comment: "The title for patch/pump information")
            }

            Section {
                HStack {
                    Text("Patch Time", comment: "Text for pump time")
                        .foregroundColor(Color.primary)
                    Spacer()
                    if viewModel.showPumpTimeSyncWarning {
                        Image(systemName: "clock.fill")
                            .foregroundColor(guidanceColors.warning)
                    }
                    Text(String(viewModel.dateFormatter.string(from: viewModel.pumpTime)))
                        .foregroundColor(viewModel.showPumpTimeSyncWarning ? guidanceColors.warning : .secondary)
                }
                HStack {
                    Text("Checked at", comment: "Text for pump time synced at")
                        .foregroundColor(Color.primary)
                    Spacer()
                    Text(String(viewModel.dateFormatter.string(from: viewModel.pumpTimeSyncedAt)))
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    showingTimeSyncConfirmation = true
                }) {
                    HStack {
                        Text("Manually sync Pump time", comment: "Label for syncing the time on the pump")
                        Spacer()
                        if viewModel.isUpdatingPumpState {
                            ActivityIndicator()
                        }
                    }
                }
                .disabled(viewModel.isUpdatingPumpState || viewModel.patchLifecycleState == .noPatch)
                .foregroundColor(.accentColor)
                .actionSheet(isPresented: $showingTimeSyncConfirmation) {
                    syncPumpTime
                }
            }
            header: {
                Text("Patch Time", comment: "The title for patch time")
            }

            Section {
                Toggle(isOn: $viewModel.useSilentTones) {
                    Text("Enable Silent tones", comment: "silent tones label")
                }
                Button(action: { self.isSharePresented = true }) {
                    Text("Share Medtrum patch logs", comment: "Share logs")
                }
                .sheet(isPresented: $isSharePresented, onDismiss: {}, content: {
                    ActivityViewController(activityItems: viewModel.getLogs())
                })

                Button(action: {
                    viewModel.showingDeleteConfirmation = true
                }) {
                    Text("Delete Pump", comment: "Label for PumpManager deletion button")
                        .foregroundColor(guidanceColors.critical)
                }
                .actionSheet(isPresented: $viewModel.showingDeleteConfirmation) {
                    removePumpManagerActionSheet(deleteAction: viewModel.pumpRemovalAction)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarItems(trailing: doneButton)
    }

    var reservoirStatus: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("Insulin Remaining", comment: "Header for insulin remaining on pod settings screen")
                .foregroundColor(Color(UIColor.secondaryLabel))
            HStack(alignment: .center, spacing: 10) {
                ReservoirView(
                    reservoirLevel: viewModel.reservoirLevel,
                    fillColor: reservoirColor,
                    maxReservoirLevel: viewModel.maxReservoirLevel
                )
                .frame(width: 23, height: 32)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(viewModel.reservoirText(for: viewModel.reservoirLevel))
                        .font(.system(size: 28))
                        .fontWeight(.heavy)
                        .fixedSize()

                    Text("U", comment: "Insulin unit")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var deliveryStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(deliverySectionTitle)
                .foregroundColor(Color(UIColor.secondaryLabel))

            if viewModel.basalType == .suspend {
                HStack(alignment: .center) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 34))
                        .fixedSize()
                        .foregroundColor(guidanceColors.warning)
                    Text(
                        "Insulin\nSuspended",
                        comment: "Text shown in insulin delivery space when insulin suspended"
                    )
                    .fontWeight(.bold)
                    .fixedSize()
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(viewModel.basalRate)
                            .font(.system(size: 28))
                            .fontWeight(.heavy)
                            .fixedSize()
                        Text("U/hr", comment: "Units for showing temp basal rate")
                            .foregroundColor(.secondary)

                        if let tempRemaining = viewModel.tempBasalRemaining {
                            Text(tempRemaining)
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    var patchLifecycle: some View {
        VStack {
            switch viewModel.patchLifecycleState {
            case .noPatch:
                HStack {
                    Text("No active patch", comment: "Text shown when no patch active")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .active,
                 .activeLast24h:
                HStack {
                    Text("Expires in:", comment: "Text shown while patch is active")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let days = viewModel.patchLifecycleDays, days > 0 {
                        timeComponent(
                            value: days,
                            units: days == 1 ?
                                String(localized: "day", comment: "Unit for singular day") :
                                String(localized: "days", comment: "Unit for plural days")
                        )
                    }

                    if let hours = viewModel.patchLifecycleHours {
                        timeComponent(
                            value: hours,
                            units: hours == 1 ?
                                String(localized: "hour", comment: "Unit for singular hour") :
                                String(localized: "hours", comment: "Unit for plural hours")
                        )
                    }

                    if let minutes = viewModel.patchLifecycleMinutes, (viewModel.patchLifecycleDays ?? -1) == 0 {
                        timeComponent(
                            value: minutes,
                            units: minutes == 1 ?
                                String(localized: "minute", comment: "Unit for singular minute") :
                                String(localized: "minutes", comment: "Unit for plural minutes")
                        )
                    }
                }
            case .expired,
                 .gracePeriod:
                HStack {
                    Text("Patch expired", comment: "Text shown when patch expired")
                        .foregroundStyle(.red)
                    Spacer()
                }
            case .expiredBasalOnly:
                HStack {
                    Text(
                        "Extended Patch expired. Basal only.",
                        comment: "Text shown when extended patch expired surpasses 120 hours"
                    )
                    .foregroundStyle(.red)
                    Spacer()
                }
            }

            ProgressView(value: viewModel.patchLifecycleProgress)
                .tint(progressColor)
                .padding(.top, -5)
        }
    }

    func timeComponent(value: Int, units: String) -> some View {
        Group {
            Text(String(value))
                .font(.system(size: 24))
                .fontWeight(.heavy)
                .foregroundColor(.primary)
            Text(units)
                .foregroundColor(.secondary)
        }
    }

    private var doneButton: some View {
        Button(String(localized: "Done", comment: "Button for closing settings"), action: {
            dismiss()
        })
    }

    public var reservoirColor: Color {
        // TODO: Configurable??
        if viewModel.reservoirLevel > (viewModel.maxReservoirLevel * 0.1) {
            return insulinTintColor
        }

        if viewModel.reservoirLevel > 0 {
            return guidanceColors.warning
        }

        return guidanceColors.critical
    }

    public var progressColor: Color {
        switch viewModel.patchLifecycleState {
        case .active:
            return .accentColor
        case .activeLast24h:
            return guidanceColors.warning
        case .expired,
             .expiredBasalOnly,
             .gracePeriod,
             .noPatch:
            return guidanceColors.critical
        }
    }

    var connectionStatusText: some View {
        if viewModel.isConnected {
            return Text("Connected", comment: "label for connected")
        }

        if viewModel.isReconnecting {
            return Text("Reconnecting...", comment: "label for reconnecting")
        }

        return Text("Disconnected", comment: "label for disconnected")
    }

    var connectionStatusIcon: some View {
        let color = viewModel.isReconnecting ? Color.orange : viewModel.isConnected ? Color.green : Color.red

        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    var deliverySectionTitle: String {
        if viewModel.tempBasalManual {
            return String(
                localized: "Manual Temp Basal",
                comment: "Pump Event title for UnfinalizedDose with doseType of .tempBasal"
            )
        }

        switch viewModel.basalType {
        case .basal,
             .bolus,
             .resume:
            return String(localized: "Scheduled Basal", comment: "Title of insulin delivery section")
        case .tempBasal:
            return String(localized: "Temp Basal", comment: "Pump Event title for UnfinalizedDose with doseType of .tempBasal")
        case .suspend:
            return String(localized: "Insulin Delivery", comment: "Title of insulin delivery section")
        }
    }
}

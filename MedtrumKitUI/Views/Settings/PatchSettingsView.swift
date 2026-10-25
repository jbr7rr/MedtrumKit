import LoopKitUI
import SwiftUI

struct PatchSettingsView: View {
    @ObservedObject var viewModel: PatchSettingsViewModel
    @State var isEditingMaxHourly = false
    @State var isEditingMaxDaily = false
    @State var isEditingAlarmSetting = false
    @State var isEditingExpirationTimer = false
    @State var isEditingNotificationAfterActivation = false
    @State var isEditingLowReservoir = false

    var doDirtyCheck = true

    let unitText = String(localized: "U", comment: "Insulin unit")
    let hourText = String(localized: "h", comment: "Hour unit")
    let extendedWarningId = "extendedWarning"

    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        sectionItem(
                            title: String(localized: "Max hourly insulin", comment: "Label for maximum hourly insulin delivery"),
                            isEditing: isEditingMaxHourly,
                            value: $viewModel.maxHourlyInsulin,
                            valueRange: viewModel.allowedOptionsHourly,
                            formatter: { value in "\(String(format: "%.0f", value)) \(self.unitText)" }
                        )
                        .onTapGesture {
                            withAnimation {
                                self.isEditingMaxHourly.toggle()
                                self.isEditingMaxDaily = false
                                self.isEditingAlarmSetting = false
                                self.isEditingExpirationTimer = false
                                self.isEditingNotificationAfterActivation = false
                                self.isEditingLowReservoir = false
                            }
                        }

                        sectionItem(
                            title: String(localized: "Max daily insulin", comment: "Label for maximum daily insulin delivery"),
                            isEditing: isEditingMaxDaily,
                            value: $viewModel.maxDailyInsulin,
                            valueRange: viewModel.allowedOptionsDaily,
                            formatter: { value in "\(String(format: "%.0f", value)) \(self.unitText)" }
                        )
                        .onTapGesture {
                            withAnimation {
                                self.isEditingMaxHourly = false
                                self.isEditingMaxDaily.toggle()
                                self.isEditingAlarmSetting = false
                                self.isEditingExpirationTimer = false
                                self.isEditingNotificationAfterActivation = false
                                self.isEditingLowReservoir = false
                            }
                        }

                        sectionItem(
                            title: String(localized: "Alarm Setting", comment: "Label for alarm settings"),
                            isEditing: isEditingAlarmSetting,
                            value: $viewModel.alarmSettings,
                            valueRange: viewModel.alarmOptions,
                            formatter: { value in
                                switch value {
                                case 0:
                                    return String(
                                        localized:
                                        "Light, vibrate and, beep",
                                        comment: "Label for alarm options: light, vibrate and beep"
                                    )
                                case 1:
                                    return String(
                                        localized: "Light and vibrate",
                                        comment: "Label for alarm options: light and vibrate"
                                    )
                                case 2:
                                    return String(localized: "Light and beep", comment: "Label for alarm options: light and beep")
                                case 3:
                                    return String(localized: "Light-only", comment: "Label for alarm options: light")
                                case 4:
                                    return String(
                                        localized: "Vibrate and beep",
                                        comment: "Label for alarm options: vibrate and beep"
                                    )
                                case 5:
                                    return String(localized: "Vibrate-only", comment: "Label for alarm options: vibrate")
                                case 6:
                                    return String(localized: "Beep-only", comment: "Label for alarm options: beep")
                                default:
                                    return String(localized: "Silence", comment: "Label for alarm options: none")
                                }
                            }
                        )
                        .onTapGesture {
                            withAnimation {
                                self.isEditingMaxHourly = false
                                self.isEditingMaxDaily = false
                                self.isEditingAlarmSetting.toggle()
                                self.isEditingExpirationTimer = false
                                self.isEditingNotificationAfterActivation = false
                                self.isEditingLowReservoir = false
                            }
                        }

                        sectionItem(
                            title: String(localized: "Patch Lifetime", comment: "Label for expiration alarm"),
                            isEditing: isEditingExpirationTimer,
                            value: $viewModel.expirationTimer,
                            valueRange: Array(0 ... 1).map({ Double($0) }),
                            formatter: { value in
                                switch value {
                                case 0:
                                    return String(localized: "Use extended lifetime", comment: "Label for extended lifetime")
                                default:
                                    return String(
                                        localized: "Use normal lifetime (3d 8h)",
                                        comment: "Label for normal patch lifetime"
                                    )
                                }
                            }
                        )
                        .onTapGesture {
                            withAnimation {
                                self.isEditingMaxHourly = false
                                self.isEditingMaxDaily = false
                                self.isEditingAlarmSetting = false
                                self.isEditingExpirationTimer.toggle()
                                self.isEditingNotificationAfterActivation = false
                                self.isEditingLowReservoir = false
                            }
                        }

                        if viewModel.expirationTimer == 1 {
                            sectionItem(
                                title: String(
                                    localized:
                                    "Notification for expirate patch",
                                    comment: "Label for expired patch notification"
                                ),
                                isEditing: isEditingNotificationAfterActivation,
                                value: $viewModel.notificationAfterActivation,
                                valueRange: Array(60 ... 78).map({ Double($0) }),
                                formatter: { value in "\(String(format: "%.0f", value)) \(self.hourText)" }
                            )
                            .onTapGesture {
                                withAnimation {
                                    self.isEditingMaxHourly = false
                                    self.isEditingMaxDaily = false
                                    self.isEditingAlarmSetting = false
                                    self.isEditingExpirationTimer = false
                                    self.isEditingNotificationAfterActivation.toggle()
                                    self.isEditingLowReservoir = false
                                }
                            }
                        }

                        sectionItem(
                            title: String(
                                localized: "Notification for low reservoir",
                                comment: "Label for low reservoir notification"
                            ),
                            isEditing: isEditingLowReservoir,
                            value: $viewModel.lowReservoirNotification,
                            valueRange: Array(0 ... 10).map({ Double($0 * 5) }),
                            formatter: { value in
                                if value == 0 {
                                    return String(localized: "Disabled", comment: "label for disabled")
                                }

                                return "\(String(format: "%.0f", value))\(unitText)"
                            }
                        )
                        .onTapGesture {
                            withAnimation {
                                self.isEditingMaxHourly = false
                                self.isEditingMaxDaily = false
                                self.isEditingAlarmSetting = false
                                self.isEditingExpirationTimer = false
                                self.isEditingNotificationAfterActivation = false
                                self.isEditingLowReservoir.toggle()
                            }
                        }
                    }

                    if viewModel.expirationTimer == 0 {
                        Section {
                            VStack {
                                Text("Use at your own risk!", comment: "warning title")
                                    .font(.headline)
                                    .bold()
                                    .padding(.bottom, 10)

                                Text(
                                    "The patch is intended to be used for only 3 days and 8 hours. Exceeding this time may cause the patch to become unreliable. This is NOT recommended. Consider using normal lifetime. Please be aware that new firmware in the latest generation of pump bases may block bolus commands after 5 days (120 hours).",
                                    comment: "warning body"
                                )
                            }
                            .id(extendedWarningId)
                        }
                        .listRowBackground(Color.orange)
                    }
                }
                .onChange(of: viewModel.expirationTimer) { _, newValue in
                    // The warning is below the picker, scroll to it
                    guard newValue == 0, isEditingExpirationTimer else { return }
                    DispatchQueue.main.async {
                        withAnimation {
                            proxy.scrollTo(extendedWarningId, anchor: .bottom)
                        }
                    }
                }
            }

            Spacer()
            if !viewModel.errorMessage.isEmpty {
                Text(viewModel.errorMessage)
                    .foregroundStyle(.red)
            }
            Button(action: {
                viewModel.save()
            }) {
                if !viewModel.isUpdating {
                    if viewModel.updatePatch {
                        Text("Save", comment: "save")
                    } else {
                        Text("Continue", comment: "Continue")
                    }
                } else {
                    ActivityIndicator()
                }
            }
            .disabled(viewModel.isUpdating || doDirtyCheck && !viewModel.isDirty)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .edgesIgnoringSafeArea(.bottom)
    }

    @ViewBuilder func sectionItem(
        title: String,
        isEditing: Bool,
        value: Binding<Double>,
        valueRange: [Double],
        formatter: @escaping (Double) -> String
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(formatter(value.wrappedValue))
        }
        .foregroundColor(isEditing ? Color.accentColor : Color.primary)

        if isEditing {
            ResizeablePicker(
                selection: value,
                data: valueRange,
                formatter: { value in formatter(value) }
            )
            .padding(.horizontal)
        }
    }
}

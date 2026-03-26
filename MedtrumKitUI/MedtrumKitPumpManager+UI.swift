import LoopKit
import LoopKitUI
import SwiftUI

extension MedtrumPumpManager: PumpManagerUI {
    public static func setupViewController(
        initialSettings settings: LoopKitUI.PumpManagerSetupSettings,
        bluetoothProvider _: any LoopKit.BluetoothProvider,
        colorPalette: LoopKitUI.LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction _: Bool,
        allowedInsulinTypes: [LoopKit.InsulinType]
    ) -> LoopKitUI.SetupUIResult<any LoopKitUI.PumpManagerViewController, any LoopKitUI.PumpManagerUI> {
        let vc = MedtrumKitUICoordinator(
            colorPalette: colorPalette,
            pumpManagerSettings: settings,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )

        return .userInteractionRequired(vc)
    }

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> PumpManagerViewController {
        MedtrumKitUICoordinator(
            pumpManager: self,
            colorPalette: colorPalette,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }

    public func deliveryUncertaintyRecoveryViewController(
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> (UIViewController & CompletionNotifying) {
        return MedtrumKitUICoordinator(pumpManager: self, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures)
    }

    public func hudProvider(
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes: [InsulinType]
    ) -> HUDProvider? {
        MedtrumKitHUDProvider(
            pumpManager: self,
            bluetoothProvider: bluetoothProvider,
            colorPalette: colorPalette,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }

    public static func createHUDView(rawValue: [String: Any]) -> BaseHUDView? {
        MedtrumKitHUDProvider.createHUDView(rawValue: rawValue)
    }

    public static var onboardingImage: UIImage? {
        UIImage(named: "nano200", in: Bundle(for: MedtrumKitHUDProvider.self), compatibleWith: nil)
    }

    public var smallImage: UIImage? {
        UIImage(
            named: state.pumpName.contains("300u") ? "nano300" : "nano200",
            in: Bundle(for: MedtrumKitHUDProvider.self),
            compatibleWith: nil
        )
    }

    public var pumpStatusHighlight: DeviceStatusHighlight? {
        if state.patchId.isEmpty {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "No patch",
                    comment: "Status highlight when no patch is active."
                ),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        } else if state.reservoir < 1 || state.pumpState == .reservoirEmpty {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString("No Insulin", comment: "Status highlight that a pump is out of insulin."),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        } else if state.basalState == .suspended {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Insulin Suspended",
                    comment: "Status highlight that insulin delivery was suspended."
                ),
                imageName: "pause.circle.fill",
                state: .warning
            )
        } else if state.expirationTimer == 0, let patchActivatedAt = state.patchActivatedAt, min(
            // expirationTimer == 0 means user selected extended mode
            // hard check if we are past 120 hrs
            (Date.now.timeIntervalSince1970 - patchActivatedAt.timeIntervalSince1970) / TimeInterval(hours: 120),
            1
        ) == 1 {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Patch expired. Basal only.",
                    comment: "Status highlight when extended patch has expired, i.e. lifetime past 120 hours."
                ),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        } else if Date.now.timeIntervalSince(state.lastSync) > .minutes(12) {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Signal Loss",
                    comment: "Status highlight when communications with the patch haven't happened recently."
                ),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        } else if state.pumpState.rawValue > PatchState.active_alt.rawValue {
            return PumpStatusHighlight(
                localizedMessage: LocalizedString(
                    "Patch Error",
                    comment: "Status highlight message for other alarm."
                ),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        }

        return nil
    }

    public var pumpLifecycleProgress: DeviceLifecycleProgress? {
        guard let expiresAt = state.patchExpiresAt else {
            return nil
        }

        if expiresAt <= Date.now {
            // Patch is expired
            return PumpLifecycleProgress(percentComplete: 100, progressState: .critical)
        }

        if let patchActivatedAt = state.patchActivatedAt, expiresAt.addingTimeInterval(.hours(-8)) <= Date.now {
            // Patch is in grace period
            let completed = expiresAt.timeIntervalSince(patchActivatedAt) / TimeInterval(hours: 80)
            return PumpLifecycleProgress(percentComplete: completed, progressState: .warning)
        }

        return nil
    }

    // LoopKit only requires here to show "time sync required"
    // But this is handled during connection and can be left empty
    public var pumpStatusBadge: DeviceStatusBadge? {
        state.shouldShowTimeWarning() ? MedtrumStatusBadge.timeSyncNeeded : nil
    }
}

extension MedtrumPumpManager {
    private enum MedtrumStatusBadge: DeviceStatusBadge {
        case timeSyncNeeded

        public var image: UIImage? {
            switch self {
            case .timeSyncNeeded:
                return UIImage(systemName: "clock.fill")
            }
        }

        public var state: DeviceStatusBadgeState {
            switch self {
            case .timeSyncNeeded:
                return .warning
            }
        }
    }
}

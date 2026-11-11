import CoreBluetooth
import LoopKit

public enum MedtrumConnectError: LocalizedError {
    case failedToDiscoverServices(localizedError: String)
    case failedToDiscoverCharacteristics(localizedError: String)
    case failedToEnableNotify(localizedError: String)
    case failedToCompleteAuthorizationFlow(localizedError: String)
    case failedToFindDevice
    case bluetoothUnavailable(state: CBManagerState)
    case failedToConnectToDevice
    case isBolussing
    case isSuspended
    /// A bolus refused: on the patch's 0.05 U steps - floored, as it is sent - it is none. Nothing was sent.
    case isBelowMinimumBolus
    /// A bolus or a temp basal not written: the host did not take the state with it pending in time - see
    /// `MedtrumPumpManager.handOverPendingDose`. `tempBasalCancelled`: the temp basal running was cancelled before;
    /// else nothing was sent.
    case stateNotSaved(tempBasalCancelled: Bool)
    /// A command refused: no patch session runs - none activated, or the last one ended - see
    /// `MedtrumPumpManager.ensureConnectedAndActive`
    case noActivePatch

    public var errorDescription: String? {
        switch self {
        case let .failedToDiscoverServices(localizedErr):
            return localizedErr
        case let .failedToDiscoverCharacteristics(localizedErr):
            return localizedErr
        case let .failedToEnableNotify(localizedErr):
            return localizedErr
        case let .failedToCompleteAuthorizationFlow(localizedErr):
            return localizedErr
        case .failedToConnectToDevice:
            return String(
                localized: "Failed to connect to patch -> Timeout reached",
                comment: "MedtrumError patch failedToConnectToDevice"
            )
        case .failedToFindDevice:
            return String(localized: "Failed to connect to patch", comment: "MedtrumError patch failedToFindDevice")
        case let .bluetoothUnavailable(state):
            return String(
                localized: "Bluetooth is unavailable. Restart the app if this persists.",
                comment: "MedtrumError bluetoothUnavailable"
            ) + " (\(state.rawValue))"
        case .isBolussing:
            return String(localized: "Bolus issue. Patch is already bolussing", comment: "MedtrumError patch bolussing")
        case .isSuspended:
            return String(localized: "Bolus issue. Patch is suspended. Resume delivery", comment: "MedtrumError patch suspended")
        case .isBelowMinimumBolus:
            return String(localized: "Bolus issue. Bolus is below the minimum of 0.05U", comment: "MedtrumError bolus below minimum")
        case let .stateNotSaved(tempBasalCancelled):
            guard tempBasalCancelled else {
                return String(
                    localized: "The app did not save the pump state in time: nothing was sent to the patch",
                    comment: "MedtrumError state not saved"
                )
            }
            return String(
                localized: "The app did not save the pump state in time: the running temp basal was cancelled, the new one was not sent",
                comment: "MedtrumError state not saved after the temp basal was cancelled"
            )
        case .noActivePatch:
            return String(localized: "No patch is active. Activate a patch first.", comment: "MedtrumError no patch session runs")
        }
    }

    /// As a dosing command fails with it: no patch session is the patch's state - refused, as a suspended patch is -
    /// anything else the link's
    var pumpManagerError: PumpManagerError {
        if case .noActivePatch = self {
            return .deviceState(self)
        }
        return .communication(self)
    }
}

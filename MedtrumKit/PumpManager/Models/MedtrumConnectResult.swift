import CoreBluetooth

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
        }
    }
}

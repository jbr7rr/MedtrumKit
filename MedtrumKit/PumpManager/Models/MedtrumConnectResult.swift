public enum MedtrumConnectError: LocalizedError {
    case failedToDiscoverServices(localizedError: String)
    case failedToDiscoverCharacteristics(localizedError: String)
    case failedToEnableNotify(localizedError: String)
    case failedToCompleteAuthorizationFlow(localizedError: String)
    case failedToFindDevice
    case failedToConnectToDevice
    case isBolussing
    case isSuspended
    case unacknowledgedBolus

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
        case .isBolussing:
            return String(localized: "Bolus issue. Patch is already bolussing", comment: "MedtrumError patch bolussing")
        case .isSuspended:
            return String(localized: "Bolus issue. Patch is suspended. Resume delivery", comment: "MedtrumError patch suspended")
        case .unacknowledgedBolus:
            return String(
                localized: "Bolus issue. A previous bolus could not be confirmed. Wait for the patch to be read out",
                comment: "MedtrumError previous bolus command still unacknowledged"
            )
        }
    }
}

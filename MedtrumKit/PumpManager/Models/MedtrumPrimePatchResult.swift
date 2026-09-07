public enum MedtrumPrimePatchResult {
    case success
    case failure(error: MedtrumPrimePatchError)
}

public enum MedtrumPrimePatchError: LocalizedError {
    case needToDeactivateFirst
    case connectionFailure(reason: String)
    case noKnownPumpBase
    case patchNotPrimeable(state: PatchState)
    case unknownError(reason: LocalizedError)

    var description: String {
        switch self {
        case let .connectionFailure(reason: reason):
            return "Failed to connect to pump base: \(reason)"
        case .needToDeactivateFirst:
            return "Pump base is currently active. Please deactivate it first."
        case .noKnownPumpBase:
            return "No known pump base found."
        case let .patchNotPrimeable(state: state):
            return "This patch can no longer be primed (\(state.description)). Please replace it with a new patch."
        case let .unknownError(reason: reason):
            return "Unknown error: \(reason)"
        }
    }
}

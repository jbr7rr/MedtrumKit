public enum MedtrumActivatePatchResult {
    case success
    case failure(error: MedtrumActivatePatchError)
}

public enum MedtrumActivatePatchError: LocalizedError {
    case connectionFailure(reason: String)
    case patchNotActivatable(state: PatchState)
    case unknownError(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .connectionFailure(reason: reason):
            return "Connection failure: \(reason)"
        case let .patchNotActivatable(state: state):
            return "This patch can no longer be activated (\(state.description)). Please replace it with a new patch."
        case let .unknownError(reason: reason):
            return "Unknown error: \(reason)"
        }
    }
}

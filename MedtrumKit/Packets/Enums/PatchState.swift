public enum PatchState: UInt8, Codable {
    case none = 0
    case idle = 1
    case filled = 2
    case priming = 3
    case primed = 4
    case ejecting = 5
    case ejected = 6
    case active = 32
    case active_alt = 33
    case lowBgSuspended = 64
    case lowBgSuspended2 = 65
    case autoSuspended = 66
    case hourlyMaxSuspended = 67
    case dailyMaxSuspended = 68
    case suspended = 69
    case paused = 70
    case occlusion = 96
    case expired = 97
    case reservoirEmpty = 98
    case patchFault = 99
    case patchFaultd2 = 100
    case baseFault = 101
    case batteryOut = 102
    case noCalibration = 103
    case stopped = 128

    var description: String {
        switch self {
        case .none:
            return String(localized: "None", comment: "Patch state for none")
        case .idle:
            return String(localized: "Idle", comment: "Patch state for idle")
        case .filled:
            return String(localized: "Filled", comment: "Patch state for filled")
        case .priming:
            return String(localized: "Priming", comment: "Patch state for priming")
        case .primed:
            return String(localized: "Primed", comment: "Patch state for primed")
        case .ejecting:
            return String(localized: "Ejecting", comment: "Patch state for ejecting")
        case .ejected:
            return String(localized: "Ejected", comment: "Patch state for ejected")
        case .active,
             .active_alt:
            return String(localized: "Active", comment: "Patch state for active, active_alt")
        case .lowBgSuspended,
             .lowBgSuspended2:
            return String(localized: "Suspended - Low BG", comment: "Patch state for lowBgSuspended, lowBgSuspended2")
        case .autoSuspended:
            return String(localized: "Suspended - Auto", comment: "Patch state for autoSuspended")
        case .hourlyMaxSuspended:
            return String(localized: "Suspended - Hourly Max", comment: "Patch state for hourlyMaxSuspended")
        case .dailyMaxSuspended:
            return String(localized: "Suspended - Daily Max", comment: "Patch state for dailyMaxSuspended")
        case .suspended:
            return String(localized: "Suspended", comment: "Patch state for suspended")
        case .paused:
            return String(localized: "Paused", comment: "Patch state for paused")
        case .occlusion:
            return String(localized: "Occlusion", comment: "Patch state for occlusion")
        case .expired:
            return String(localized: "Expired", comment: "Patch state for expired")
        case .reservoirEmpty:
            return String(localized: "Reservoir Empty", comment: "Patch state for reservoirEmpty")
        case .baseFault,
             .patchFault,
             .patchFaultd2:
            return String(localized: "Fault", comment: "Patch state for patchFault, patchFaultd2, baseFault")
        case .batteryOut:
            return String(localized: "Battery Empty", comment: "Patch state for batteryOut")
        case .noCalibration:
            return String(localized: "No Calibration", comment: "Patch state for noCalibration")
        case .stopped:
            return String(localized: "Stopped", comment: "Patch state for stopped")
        }
    }
}

/// Classifies patch states for session-token lifecycle decisions.
enum SessionTokenPolicy {
    /// True when the patch has permanently ended and must be replaced (occlusion,
    /// expired, reservoir empty, fault, battery out, stopped, ...). When this is
    /// reached we back up and clear the active token so the next patch starts with
    /// a fresh one.
    ///
    /// IMPORTANT: the boundary is `>= occlusion` (96), NOT `> active` (32).
    /// States 33-70 (active_alt, the suspends and paused) are also `> 32` but are
    /// recoverable and must KEEP their token; and transient activation states like
    /// `ejecting`/`ejected` (5/6) are below 32 and must also keep their token.
    static func isTerminal(_ state: PatchState) -> Bool {
        state.rawValue >= PatchState.occlusion.rawValue
    }
}

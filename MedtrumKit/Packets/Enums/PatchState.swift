//
//  PatchState.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 11/03/2025.
//

enum PatchState: UInt8, Codable {
    case none = 0
    case idle = 1
    case filled = 2
    case priming = 3
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
}

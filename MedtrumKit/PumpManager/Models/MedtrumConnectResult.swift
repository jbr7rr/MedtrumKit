//
//  ConnectResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

public enum MedtrumConnectResult {
    case success
    case failure(error: MedtrumConnectError)
}

public enum MedtrumConnectError {
    case failedToDiscoverServices(localizedError: String)
    case failedToDiscoverCharacteristics(localizedError: String)
    case failedToEnableNotify(localizedError: String)
    case failedToCompleteAuthorizationFlow(localizedError: String)
    
    func toString() -> String {
        switch self {
        case .failedToDiscoverServices(let localizedErr):
            return localizedErr
        case .failedToDiscoverCharacteristics(let localizedErr):
            return localizedErr
        case .failedToEnableNotify(let localizedErr):
            return localizedErr
        case .failedToCompleteAuthorizationFlow(let localizedErr):
            return localizedErr
        }
    }
}

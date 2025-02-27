//
//  ConnectResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

enum MedtrumConnectResult {
    case success
    case failure(error: MedtrumConnectError)
}

enum MedtrumConnectError {
    case failedToDiscoverServices(localizedError: String)
    case failedToDiscoverCharacteristics(localizedError: String)
    case failedToEnableNotify(localizedError: String)
    case failedToCompleteAuthorizationFlow(localizedError: String)
}

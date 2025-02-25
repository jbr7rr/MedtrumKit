//
//  ConnectResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

enum ConnectResult {
    case success
    case failure(error: ConnectError)
}

enum ConnectError {
    case failedToDiscoverServices(localizedError: String)
    case failedToDiscoverCharacteristics(localizedError: String)
}

//
//  MedtrumPrimePatchResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 21/03/2025.
//

public enum MedtrumPrimePatchResult {
    case success
    case failure(error: MedtrumPrimePatchError)
}

public enum MedtrumPrimePatchError: LocalizedError {
    case needToDeactivateFirst
    case connectionFailure
    case noKnownPumpBase
    case unknownError(reason: String)
}

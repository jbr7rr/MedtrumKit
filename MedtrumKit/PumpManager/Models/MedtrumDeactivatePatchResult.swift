//
//  MedtrumActivatePatchResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 21/03/2025.
//

public enum MedtrumDeactivatePatchResult {
    case success
    case failure(error: MedtrumDeactivatePatchError)
}

public enum MedtrumDeactivatePatchError: LocalizedError {
    case connectionFailure
    case unknownError(reason: String)
}

//
//  MedtrumActivatePatchResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 21/03/2025.
//

public enum MedtrumActivatePatchResult {
    case success
    case failure(error: MedtrumActivatePatchError)
}

public enum MedtrumActivatePatchError: LocalizedError {
    case connectionFailure
    case unknownError(reason: String)
}

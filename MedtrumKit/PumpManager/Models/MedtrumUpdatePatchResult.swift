//
//  MedtrumActivatePatchResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 21/03/2025.
//

public enum MedtrumUpdatePatchResult {
    case success
    case failure(error: MedtrumUpdatePatchError)
}

public enum MedtrumUpdatePatchError: LocalizedError {
    case connectionFailure
    case unknownError(reason: String)
}

//
//  WriteResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

enum MedtrumWriteResult<T> {
    case success(data: T)
    case failure(error: MedtrumWriteError)
}

enum MedtrumWriteError: LocalizedError {
    case timeout
    case invalidResponse
    case noManager
    
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Timeout hit"
        case .invalidResponse:
            return "Invalid response"
        case .noManager:
            return "No peripheral manager"
        }
    }
}

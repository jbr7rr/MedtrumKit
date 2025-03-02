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

enum MedtrumWriteError {
    case timeout
    case invalidResponse
    
    func toString() -> String {
        switch self {
        case .timeout:
            return "Timeout hit"
        case .invalidResponse:
            return "Invalid response"
        }
    }
}

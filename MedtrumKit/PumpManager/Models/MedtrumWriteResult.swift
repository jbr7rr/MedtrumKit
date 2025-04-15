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
    case invalidData
    case invalidResponse(code: UInt16)
    case noManager
    case noWriteCharacteristic
    
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Timeout hit"
        case .invalidData:
            return "Invalid data received"
        case .invalidResponse(let code):
            return "Invalid response code: \(code)"
        case .noManager:
            return "No peripheral manager"
        case .noWriteCharacteristic:
            return "No write characteristic. Device might be disconnected"
        }
    }
}

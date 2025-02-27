//
//  WriteResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 27/02/2025.
//

enum MedtrumWriteResult {
    case success(data: Data)
    case failure(error: MedtrumWriteError)
}

enum MedtrumWriteError {
    case timeout
    
    func toString() -> String {
        switch self {
        case .timeout:
            return "Timeout hit"
        }
    }
}

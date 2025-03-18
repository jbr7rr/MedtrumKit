//
//  ScanResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

import CoreBluetooth

public enum MedtrumScanResult {
    case success(peripheral: CBPeripheral, pumpSN: Data, deviceType: UInt8, version: UInt8)
    case failure(error: MedtrumScanError)
}

public enum MedtrumScanError: LocalizedError {
    case invalidBluetoothState(state: CBManagerState)
    case alreadyScanning
    
    public var errorDescription: String? {
        switch self {
        case .invalidBluetoothState(state: let state):
            return "Invalid Bluetooth state: \(state)"
        case .alreadyScanning:
            return "Already scanning"
        }
    }
}

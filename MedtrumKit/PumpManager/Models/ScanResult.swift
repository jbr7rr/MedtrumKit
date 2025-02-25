//
//  ScanResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

import CoreBluetooth

enum ScanResult {
    case failure(error: ScanError)
    case success(peripheral: CBPeripheral)
}

enum ScanError {
    case invalidBluetoothState(state: CBManagerState)
    case alreadyScanning
}

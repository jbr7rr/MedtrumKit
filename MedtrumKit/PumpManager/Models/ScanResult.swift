//
//  ScanResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

import CoreBluetooth

enum ScanResult {
    case failure(error: ScanError)
    case success(peripheral: CBPeripheral, pumpSN: Data, deviceType: UInt8, version: UInt8)
}

enum ScanError {
    case invalidBluetoothState(state: CBManagerState)
    case alreadyScanning
}

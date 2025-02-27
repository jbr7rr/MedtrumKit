//
//  ScanResult.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 25/02/2025.
//

import CoreBluetooth

enum MedtrumScanResult {
    case success(peripheral: CBPeripheral, pumpSN: Data, deviceType: UInt8, version: UInt8)
    case failure(error: MedtrumScanError)
}

enum MedtrumScanError {
    case invalidBluetoothState(state: CBManagerState)
    case alreadyScanning
}

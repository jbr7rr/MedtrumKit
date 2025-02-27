//
//  BasePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 26/02/2025.
//

protocol MedtrumBasePacket {
    associatedtype T
    
    var commandType: UInt8 { get }
    
    func getRequestBytes() -> Data
    static func parseResponse(data: Data) -> T
}

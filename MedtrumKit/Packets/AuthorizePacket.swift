//
//  AuthorizePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 26/02/2025.
//

struct AuthorizeResponse {
    let deviceType: UInt8
    let swVersion: String
}

class AuthorizePacket: MedtrumBasePacket {
    typealias T = AuthorizeResponse
    
    let commandType: UInt8 = CommandType.AUTH_REQ
    
    private let role: UInt8 = 2
    private let pumpSN: Data
    private let sessionToken: Data
    
    init(pumpSN: Data, sessionToken: Data) {
        self.pumpSN = pumpSN
        self.sessionToken = sessionToken
    }
    
    func getRequestBytes() -> Data {
        let key = Crypto.genKey(self.pumpSN)
        
        var output = Data([role])
        output.append(self.sessionToken)
        output.append(key)
        
        return output
    }
    
    static func parseResponse(data: Data) throws -> AuthorizeResponse {
        return AuthorizeResponse(
            deviceType: data[7],
            swVersion: "\(data[8]).\(data[9]).\(data[10])"
        )
    }
}



//
//  WritePacket.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 26/02/2025.
//

class WritePacket {
    static func encode(_ data: any MedtrumBasePacket, sequenceNumber: UInt8) -> [Data] {
        let content = data.getRequestBytes()
        var header = Data([
            UInt8(content.count + 4),
            data.commandType,
            sequenceNumber,
            0, // pkgIndex
        ])
        
        let tmp = header + content
        let totalCommand = tmp + Crc8.calculate(tmp)
        
        if (totalCommand.count - header.count) <= 15 {
            return [totalCommand]
        }
        
        // We need to split up the command in multiple packages
        var packages: [Data] = []
        
        var pkgIndex: UInt8 = 1
        var remainingCommand = totalCommand[4...]
        
        while remainingCommand.count > 15 {
            header[3] = pkgIndex
            
            let tmp2 = header + remainingCommand[0..<15]
            packages.append(tmp2 + Crc8.calculate(tmp2))

            remainingCommand = remainingCommand[15...]
            pkgIndex = UInt8(pkgIndex + 1)
        }
        
        header[3] = pkgIndex
        let tmp3 = header + remainingCommand
        
        packages.append(tmp + Crc8.calculate(tmp3))
        return packages
    }

}

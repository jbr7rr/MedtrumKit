struct ClearAlertResponse {}

public enum AlertType: UInt16 {
    case hourly = 4
    case daily = 5
}

class ClearAlertPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = ClearAlertResponse

    let commandType: UInt8 = CommandType.CLEAR_ALARM
    let mimimumDataSize: Int = 2

    let alertType: AlertType
    init(alertType: AlertType) {
        self.alertType = alertType
    }

    func getRequestBytes() -> Data {
        let value = alertType.rawValue

        return Data([
            UInt8(value & 0xFF),
            UInt8(value >> 8)
        ])
    }

    func parseResponse() -> ClearAlertResponse {
        ClearAlertResponse()
    }
}

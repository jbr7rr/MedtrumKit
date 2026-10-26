struct SetTimeZonePacketResponse {}

class SetTimeZonePacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = SetTimeZonePacketResponse

    let commandType: UInt8 = CommandType.SET_TIME_ZONE
    let mimimumDataSize: Int = 0
    let date: Date
    let timeZone: TimeZone

    init(date: Date, timeZone: TimeZone) {
        self.date = date
        self.timeZone = timeZone
    }

    /// The offset the patch is set to
    var utcOffset: TimeInterval {
        Self.patchOffset(TimeInterval(seconds: Double(timeZone.secondsFromGMT(for: date))))
    }

    /// The offset a patch is set to for a zone `offset` east of UTC
    static func patchOffset(_ offset: TimeInterval) -> TimeInterval {
        // Workaround for bug where it fails to set timezone > GMT + 12
        // if offset is > 12 hours, subtract 24 hours
        offset > .hours(12) ? offset - .hours(24) : offset
    }

    func getRequestBytes() -> Data {
        var offsetInMinutes = Int(utcOffset.minutes)
        if offsetInMinutes < 0 {
            offsetInMinutes += 65536
        }

        let base = Data([
            UInt8(offsetInMinutes & 0xFF),
            UInt8(offsetInMinutes >> 8)
        ])

        return base + date.toMedtrumSeconds()
    }

    func parseResponse() -> SetTimeZonePacketResponse {
        SetTimeZonePacketResponse()
    }
}

/// Laid out like the answer to CancelTempBasal: the segment the patch resumed with. Nil when the answer is too short
/// for it - a resume is never failed over that.
struct ResumePumpPacketResponse {
    let basalType: BasalType?
    let basalSequence: Double?
    let basalStartTime: Date?
}

class ResumePumpPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = ResumePumpPacketResponse

    let commandType: UInt8 = CommandType.RESUME_PUMP
    let mimimumDataSize: Int = 0

    func getRequestBytes() -> Data {
        Data()
    }

    func parseResponse() -> ResumePumpPacketResponse {
        guard totalData.count >= 17 else {
            return ResumePumpPacketResponse(basalType: nil, basalSequence: nil, basalStartTime: nil)
        }

        return ResumePumpPacketResponse(
            basalType: BasalType(rawValue: totalData[6]) ?? .NONE,
            basalSequence: totalData.subdata(in: 9 ..< 11).toDouble(),
            basalStartTime: Date.fromMedtrumSeconds(totalData.subdata(in: 13 ..< 17).toUInt64())
        )
    }
}

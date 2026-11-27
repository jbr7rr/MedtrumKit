/// The answer carries the record the patch allocated for this bolus and when it started it, on its own clock. Nil
/// when the answer is too short for them: a bolus is never turned down over what it tells us of its record.
struct SetBolusResponse {
    let recordSequence: Int?
    /// The low two bytes of the patch id, as in a record
    let patchId: UInt64?
    let startTime: Date?
}

class SetBolusPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = SetBolusResponse
    let commandType: UInt8 = CommandType.SET_BOLUS
    let mimimumDataSize: Int = 0

    // Bolus types:
    // 1 = normal
    // 2 = Extended
    // 3 = Combi
    let bolusType: UInt8 = 1
    let bolusAmount: Double

    init(bolusAmount: Double) {
        self.bolusAmount = bolusAmount
    }

    func getRequestBytes() -> Data {
        let amount = UInt64(round(bolusAmount / 0.05)).toData(length: 2)
        var output = Data([bolusType])
        output.append(amount)
        output.append(Data([0]))

        return output
    }

    func parseResponse() -> SetBolusResponse {
        guard totalData.count >= 14 else {
            return SetBolusResponse(recordSequence: nil, patchId: nil, startTime: nil)
        }

        return SetBolusResponse(
            recordSequence: Int(totalData.subdata(in: 6 ..< 8).toUInt64()),
            patchId: totalData.subdata(in: 8 ..< 10).toUInt64(),
            startTime: Date.fromMedtrumSeconds(totalData.subdata(in: 10 ..< 14).toUInt64())
        )
    }
}

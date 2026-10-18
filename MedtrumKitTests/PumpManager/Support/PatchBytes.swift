import Foundation
@testable import MedtrumKit

/// Builds what the patch sends, for scenarios whose bytes no log has: answers fragmented and checksummed the way the
/// patch does it, records laid out as `GetRecordPacket` reads them, and notifications.
enum PatchBytes {
    /// An answer to `command` carrying `body` - everything after the response code - one hex string per fragment: the
    /// first holds the header and 13 bytes of it, every further one 15, each ends in the CRC of what it carries
    static func answer(command: UInt8, sequence: UInt8 = 0, body: Data) -> [String] {
        let total = Data([UInt8(6 + body.count), command, sequence, 1, 0, 0]) + body

        var fragments: [Data] = [Data(total.prefix(19))]
        var index: UInt8 = 2
        var offset = 19
        while offset < total.count {
            let end = min(offset + 15, total.count)
            fragments.append(Data([total[0], command, sequence, index]) + total.subdata(in: offset ..< end))
            offset = end
            index += 1
        }

        return fragments.map { ($0 + Crc8.calculate($0)).hexEncodedString() }
    }

    /// A GET_RECORD answer with a BOLUS record
    static func bolusRecord(sequence: Int, patchId: UInt64, start: Date, amount: Double, delivered: Double) -> [String] {
        var payload = Data([1, 0, 0, 0])
        payload += start.toMedtrumSeconds()
        payload += steps(amount) + steps(delivered)
        payload += Data(count: 27)
        return answer(command: CommandType.GET_RECORD, body: recordHeader(type: 1, sequence: sequence, patchId: patchId) + payload)
    }

    /// A GET_RECORD answer with a BASAL record
    static func basalRecord(
        sequence: Int,
        patchId: UInt64,
        type: BasalType,
        start: Date,
        end: Date,
        rate: Double,
        delivered: Double,
        endReason: BasalEndReason = .SUCCESS
    ) -> [String] {
        var payload = start.toMedtrumSeconds() + end.toMedtrumSeconds()
        payload += Data([type.rawValue, endReason.rawValue])
        payload += steps(rate) + steps(delivered)
        payload += Data(count: 7)
        return answer(command: CommandType.GET_RECORD, body: recordHeader(type: 2, sequence: sequence, patchId: patchId) + payload)
    }

    /// A GET_RECORD answer with a record of a type we do not parse - an ALARM (3), a type 10, ...
    static func otherRecord(type: UInt8, sequence: Int, patchId: UInt64) -> [String] {
        answer(command: CommandType.GET_RECORD, body: recordHeader(type: type, sequence: sequence, patchId: patchId) + Data(count: 16))
    }

    /// An answer to CancelTempBasal, SetTempBasal or ResumePump: the segment the command started
    static func segmentAnswer(
        command: UInt8,
        type: BasalType,
        rate: Double,
        sequence: Int,
        patchId: UInt64,
        start: Date
    ) -> [String] {
        var body = Data([type.rawValue]) + steps(rate)
        body += UInt64(sequence).toData(length: 2) + patchId.toData(length: 2)
        body += start.toMedtrumSeconds()
        return answer(command: command, body: body)
    }

    /// A notification showing only a basal segment, as the patch pushes one when it changes, in patch state `state`,
    /// having delivered `delivered` so far
    static func basalNotification(
        type: BasalType,
        sequence: Int,
        patchId: UInt64,
        start: Date,
        rate: Double,
        delivered: Double = 0,
        state: PatchState = .active
    ) -> String {
        var data = Data([state.rawValue, 0x08, 0x00, type.rawValue])
        data += UInt64(sequence).toData(length: 2) + patchId.toData(length: 2)
        data += start.toMedtrumSeconds()
        let rateDelivery = UInt64((delivered / 0.05).rounded()) << 12 | UInt64((rate / 0.05).rounded())
        data += rateDelivery.toData(length: 3)
        return data.hexEncodedString()
    }

    /// A notification of the suspended state carrying only when the patch suspended, as it sends one after a suspend
    static func suspendNotification(suspendedAt: Date) -> String {
        (Data([PatchState.suspended.rawValue, 0x01, 0x00]) + suspendedAt.toMedtrumSeconds()).hexEncodedString()
    }

    private static func recordHeader(type: UInt8, sequence: Int, patchId: UInt64) -> Data {
        Data([0xAA, 0x20, type, 0xFF, 0x9E, 0x75, 0xAE, 0xF7]) + patchId.toData(length: 2) + UInt64(sequence).toData(length: 2)
    }

    private static func steps(_ units: Double) -> Data {
        UInt64((units / 0.05).rounded()).toData(length: 2)
    }
}

import Foundation

extension RecordSyncer {
    static func log(
        _ response: GetRecordResponse,
        requested: Int,
        expectedPatchId: UInt64,
        outcome: String?,
        patchUTCOffset: TimeInterval?,
        to store: PumpRecordStore
    ) {
        let prefix = "record \(response.sequence)"

        if response.sequence != requested {
            logger.warning("Requested record \(requested) but got \(response.sequence)")
        }

        if !isSamePatch(response.patchId, expectedPatchId) {
            logger.warning("\(prefix): patch id \(response.patchId), expected \(expectedPatchId)")
        }

        let (kind, summary, label, eventDate) = describe(response.record)
        logger.info("\(prefix) \(kind): \(summary)")

        let phoneOffset = TimeInterval(TimeZone.current.secondsFromGMT())
        if let mismatch = timeZoneMismatch(of: response.record, patchUTCOffset: patchUTCOffset, phoneOffset: phoneOffset) {
            logger.warning("\(prefix): \(mismatch)")
        }

        if let overcount = emptyStopOvercount(of: response.record) {
            logger.warning("\(prefix): \(overcount)")
        }

        store.store(StoredPumpRecord(
            id: response.sequence,
            fetchedAt: Date.now,
            kind: kind,
            summary: summary,
            label: label,
            eventDate: eventDate,
            outcome: outcome
        ))
    }

    /// The patch keeps the time zone it was given - at activation, or a time sync - which a DST change since does not
    /// move: its TDD and daily snapshot fall on its midnight. A record's zone is compared with the one we last set on the
    /// patch - `patchUTCOffset`, what patch-midnight splits go by (`MedtrumPumpManager.crossesPatchMidnight`) - or, with
    /// none known, the one we would set: the phone's, as `SetTimeZonePacket` sends it (past UTC+12 a day less). Told of
    /// in the log only. Nil if `record` has no time zone, or it is that one. Offsets are east of UTC.
    static func timeZoneMismatch(of record: PumpRecord, patchUTCOffset: TimeInterval?, phoneOffset: TimeInterval) -> String? {
        let offset: Int
        switch record {
        case let .tdd(tdd):
            offset = tdd.signedTimeZoneOffset
        case let .event(.dailySnapshot(snapshot)):
            offset = snapshot.timeZoneOffset
        default:
            return nil
        }

        let phone = Int(phoneOffset / 60)
        let phoneAsSet = Int(SetTimeZonePacket.patchOffset(phoneOffset) / 60)
        let expected = patchUTCOffset.map { Int($0 / 60) } ?? phoneAsSet

        guard offset != expected else {
            return nil
        }

        let set = patchUTCOffset.map { "the one set on the patch \(offsetText(Int($0 / 60)))" } ?? "none known set on the patch"
        let phoneText = "the phone's \(offsetText(phone))" + (phoneAsSet != phone ? ", set on a patch as \(offsetText(phoneAsSet))" : "")
        return "the record's time-zone offset is \(offsetText(offset)), \(set), \(phoneText)"
    }

    /// A temp basal's record ended on an empty reservoir claims more than its rate over its duration, in 0.05 U steps:
    /// seen on dry-outs (0.10 U for 0.35 U/h over 1.5 min), the reservoir's drop short of it. Told of in the log only, as
    /// evidence: the record is taken as it is. Nil for any other record.
    static func emptyStopOvercount(of record: PumpRecord) -> String? {
        guard case let .basal(basal) = record, basal.type.isTempBasal(), basal.endReason == .STOP_EMPTY else {
            return nil
        }

        let byRate = basal.rate * basal.duration.hours
        guard steps(basal.delivered) > steps(byRate) else {
            return nil
        }

        return "ended on an empty reservoir claiming \(units(basal.delivered)), more than its rate × duration: " +
            "\(units(basal.rate))/h × \(minutes(basal.duration)) = \(String(format: "%.3fU", byRate)) - taken as it is"
    }

    /// An offset as "120 min (UTC+2)"
    private static func offsetText(_ offset: Int) -> String {
        "\(offset) min (\(utcOffset(offset)))"
    }

    /// Flattens a record into what both the log and the debug screen want: what kind it is, its fields as one line,
    /// what an event record is in words, and when the patch says it happened.
    static func describe(_ record: PumpRecord) -> (kind: String, summary: String, label: String?, eventDate: Date?) {
        switch record {
        case let .bolus(bolus):
            let fields: [String] = [
                "type=\(bolus.type)",
                "wizard=\(bolus.wizard)",
                "cause=\(bolus.cause)",
                "start=\(format(bolus.startTime))",
                "requested=\(units(bolus.normalAmount))",
                "delivered=\(units(bolus.normalDelivered))",
                "extended=\(units(bolus.extendedAmount))/\(minutes(bolus.extendedDuration))",
                "extendedDelivered=\(units(bolus.extendedDelivered))",
                "carbs=\(bolus.carbs)",
                "glucose=\(bolus.glucose)",
                "iob=\(bolus.iob)"
            ]
            return ("BOLUS", fields.joined(separator: " "), nil, bolus.startTime)

        case let .basal(basal):
            let endReason: String = basal.endReason.map { "\($0)" } ?? "unknown(\(basal.rawEndReason))"
            let fields: [String] = [
                "type=\(basal.type)",
                "endReason=\(endReason)",
                "start=\(format(basal.startTime))",
                "end=\(format(basal.endTime))",
                "duration=\(minutes(basal.duration))",
                "rate=\(units(basal.rate))/h",
                "percent=\(basal.percent)",
                "delivered=\(units(basal.delivered))"
            ]
            return ("BASAL", fields.joined(separator: " "), nil, basal.startTime)

        case let .tdd(tdd):
            let fields: [String] = [
                "timestamp=\(format(tdd.timestamp))",
                "minutes=\(tdd.minutes)",
                "tzOffset=\(tdd.signedTimeZoneOffset)",
                "total=\(units(Double(tdd.total)))",
                "basal=\(units(Double(tdd.basal)))",
                "bolus=\(units(Double(tdd.bolus)))",
                "glucose=\(tdd.glucose)"
            ]
            return ("TDD", fields.joined(separator: " "), nil, tdd.timestamp)

        case let .event(.alarm(alarm)):
            let fields: [String] = [
                "\(alarm.name ?? "alarm bit \(alarm.bit)") (bit \(alarm.bit))",
                "age=\(alarm.patchAge)s",
                "time=\(format(alarm.timestamp))",
                "unknown=\(alarm.unknown1)/\(alarm.unknown2)"
            ]
            return ("ALARM", fields.joined(separator: " "), label(of: alarm), alarm.timestamp)

        case let .event(.resumed(resumed)):
            return ("RESUMED", "time=\(format(resumed.timestamp))", "Delivery resumed", resumed.timestamp)

        case let .event(.dailySnapshot(snapshot)):
            let fields: [String] = [
                "time=\(format(snapshot.timestamp))",
                "tzOffset=\(snapshot.timeZoneOffset)",
                String(format: "a=%.3f", snapshot.a),
                String(format: "b=%.3f", snapshot.b)
            ]
            return (
                "DAILY",
                fields.joined(separator: " "),
                "Daily snapshot · \(utcOffset(snapshot.timeZoneOffset))",
                snapshot.timestamp
            )

        case let .event(.baseCounters(base)):
            let fields: [String] = [
                "time=\(format(base.timestamp))",
                "lifetime=\(units(base.lifetimeInsulin))",
                "hours=\(base.operatingHours)",
                "patches=\(base.patchesUsed)"
            ]
            let lifetime = groupedFormatter.string(from: NSNumber(value: base.lifetimeWholeUnits)) ?? "-"
            return (
                "BASE",
                fields.joined(separator: " "),
                "Base: \(lifetime) U · \(base.operatingHours) h · \(base.patchesUsed) patches",
                base.timestamp
            )

        case let .unhandled(type):
            return ("UNHANDLED", "\(GetRecordPacket.name(forRecordType: type)) (record type \(type))", nil, nil)

        case let .truncated(type, size):
            return (
                "TRUNCATED",
                "\(GetRecordPacket.name(forRecordType: type)) (record type \(type)) is too short to parse (\(size) bytes)",
                nil,
                nil
            )

        case .invalid:
            return ("INVALID", "invalid record header", nil, nil)
        }
    }

    /// An alarm in words, with the patch's age: how far into its life the patch raised it
    private static func label(of alarm: AlarmRecord) -> String {
        let name = alarm.name.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Alarm bit \(alarm.bit)"
        return name + String(format: " · patch age %.1f h", Double(alarm.patchAge) / 3600)
    }

    /// Minutes east of UTC as "UTC+2", "UTC-3:30"
    static func utcOffset(_ minutes: Int) -> String {
        let sign = minutes < 0 ? "-" : "+"
        let hours = abs(minutes) / 60
        let rest = abs(minutes) % 60
        return "UTC\(sign)\(hours)" + (rest == 0 ? "" : String(format: ":%02d", rest))
    }

    /// Thousands grouped the English way, as the rest of the record screen is: "11,419"
    private static let groupedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func units(_ value: Double) -> String {
        String(format: "%.2fU", value)
    }

    private static func minutes(_ duration: TimeInterval) -> String {
        String(format: "%.1fmin", duration / 60)
    }
}

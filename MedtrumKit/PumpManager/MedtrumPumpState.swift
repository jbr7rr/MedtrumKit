import LoopKit

public enum BasalState: Int {
    case active = 0
    case suspended = 1
    case tempBasal = 2
}

public enum BolusState: Int {
    case noBolus = 0
    case inProgress = 1
    case canceling = 2
}

public enum ExpiryMode: Int {
    case `default` = 1
    case extended = 2

    var lifespan: TimeInterval {
        switch self {
        case .default:
            return .hours(72)
        case .extended:
            return .hours(112)
        }
    }

    var gracePeriod: TimeInterval {
        .hours(8)
    }

    var timer: UInt8 {
        self == .default ? 1 : 0
    }
}

public struct PreviousPatch: Codable {
    public var patchId: Data
    public var lastStateRaw: UInt8
    public var lastSyncAt: Date
    public var battery: Double
    public var activatedAt: Date
    public var deactivatedAt: Date
    public var initialReservoirLevel: Double?
    public var reservoirLevel: Double?
}

public class MedtrumPumpState: RawRepresentable {
    public typealias RawValue = PumpManager.RawStateValue

    public required init(rawValue: RawValue) {
        isOnboarded = rawValue["isOnboarded"] as? Bool ?? false
        lastSync = rawValue["lastSync"] as? Date ?? Date.distantPast
        pumpSN = rawValue["pumpSN"] as? Data ?? Data()
        lowReservoirWarning = rawValue["lowReservoirWarning"] as? Double
        sessionToken = rawValue["sessionToken"] as? Data ?? Data()
        patchId = rawValue["patchId"] as? Data ?? Data()
        patchActivatedAt = rawValue["patchActivatedAt"] as? Date ?? nil
        deviceType = rawValue["deviceType"] as? UInt8 ?? 0
        swVersion = rawValue["swVersion"] as? String ?? "0.0.0"
        pumpTime = rawValue["pumpTime"] as? Date ?? Date()
        pumpTimeSyncedAt = rawValue["pumpTimeSyncedAt"] as? Date ?? Date()
        maxHourlyInsulin = rawValue["maxHourlyInsulin"] as? Double ?? 20
        maxDailyInsulin = rawValue["maxDailyInsulin"] as? Double ?? 100
        initialReservoir = rawValue["initialReservoir"] as? Double
        reservoir = rawValue["reservoir"] as? Double ?? 0
        battery = rawValue["battery"] as? Double ?? 0
        basalStateSince = rawValue["basalStateSince"] as? Date ?? Date.distantPast
        tempBasalUnits = rawValue["tempBasalUnits"] as? Double
        tempBasalDuration = rawValue["tempBasalDuration"] as? Double
        notificationAfterActivation = rawValue["notificationAfterActivation"] as? TimeInterval ?? .hours(72)

        if let expiryModeRaw = rawValue["expiryMode"] as? ExpiryMode.RawValue {
            expiryMode = ExpiryMode(rawValue: expiryModeRaw) ?? .default
        } else if let expirationTimer = rawValue["expirationTimer"] as? UInt8 {
            expiryMode = expirationTimer == 1 ? .default : .extended
        } else {
            expiryMode = .default
        }

        if let previousPatchRaw = rawValue["previousPatch"] as? Data {
            do {
                previousPatch = try JSONDecoder().decode(PreviousPatch.self, from: previousPatchRaw)
            } catch {}
        }

        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        }

        if let rawDoseEntry = rawValue["doseEntry"] as? UnfinalizedDose.RawValue {
            doseEntry = UnfinalizedDose(rawValue: rawDoseEntry)
        } else {
            doseEntry = nil
        }

        if let pumpStateRaw = rawValue["pumpState"] as? PatchState.RawValue {
            pumpState = PatchState(rawValue: pumpStateRaw) ?? .none
        } else {
            pumpState = .none
        }

        if let rawBasalSchedule = rawValue["basalSchedule"] as? BasalSchedule.RawValue {
            basalSchedule = BasalSchedule(rawValue: rawBasalSchedule) ??
                BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }

        if let basalStateRaw = rawValue["basalState"] as? BasalState.RawValue {
            basalState = BasalState(rawValue: basalStateRaw) ?? .active
        } else {
            basalState = .active
        }

        if let bolusStateRaw = rawValue["bolusState"] as? BolusState.RawValue {
            bolusState = BolusState(rawValue: bolusStateRaw) ?? .noBolus
        } else {
            bolusState = .noBolus
        }

        if let alarmSettingRaw = rawValue["alarmSetting"] as? AlarmSettings.RawValue {
            alarmSetting = AlarmSettings(rawValue: alarmSettingRaw) ?? .BeepOnly
        } else {
            alarmSetting = .BeepOnly
        }
    }

    public init(_ basal: BasalRateSchedule?) {
        isOnboarded = false
        lastSync = Date.distantPast
        pumpSN = Data()
        lowReservoirWarning = nil
        doseEntry = nil
        sessionToken = Data()
        patchId = Data()
        patchActivatedAt = nil
        deviceType = 0
        swVersion = "0.0.0"
        pumpTime = Date()
        pumpTimeSyncedAt = Date()
        pumpState = .none

        maxHourlyInsulin = 20
        maxDailyInsulin = 100
        reservoir = 0
        battery = 0
        basalState = .active
        basalStateSince = Date.distantPast
        tempBasalUnits = nil
        tempBasalDuration = nil
        bolusState = .noBolus
        alarmSetting = .BeepOnly
        expiryMode = .default
        notificationAfterActivation = .hours(72)
        previousPatch = nil

        if let basal = basal {
            basalSchedule = BasalSchedule(entries: basal.items)
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }
    }

    public var rawValue: RawValue {
        var value: [String: Any] = [:]

        value["isOnboarded"] = isOnboarded
        value["lastSync"] = lastSync
        value["insulinType"] = insulinType?.rawValue
        value["lowReservoirWarning"] = lowReservoirWarning
        value["pumpSN"] = pumpSN
        value["sessionToken"] = sessionToken
        value["patchId"] = patchId
        value["patchActivatedAt"] = patchActivatedAt
        value["patchGracePeriodFrom"] = patchGracePeriodFrom
        value["patchExpiresAt"] = patchExpiresAt
        value["deviceType"] = deviceType
        value["swVersion"] = swVersion
        value["pumpTime"] = pumpTime
        value["pumpTimeSyncedAt"] = pumpTimeSyncedAt
        value["pumpState"] = pumpState.rawValue
        value["maxHourlyInsulin"] = maxHourlyInsulin
        value["maxDailyInsulin"] = maxDailyInsulin
        value["basalSchedule"] = basalSchedule.rawValue
        value["bolusState"] = bolusState.rawValue
        value["initialReservoir"] = initialReservoir
        value["doseEntry"] = doseEntry?.rawValue
        value["reservoir"] = reservoir
        value["battery"] = battery
        value["basalState"] = basalState.rawValue
        value["basalStateSince"] = basalStateSince
        value["tempBasalUnits"] = tempBasalUnits
        value["tempBasalDuration"] = tempBasalDuration
        value["alarmSetting"] = alarmSetting.rawValue
        value["expiryMode"] = expiryMode.rawValue
        value["notificationAfterActivation"] = notificationAfterActivation

        if let previousPatch = previousPatch {
            do {
                value["previousPatch"] = try JSONEncoder().encode(previousPatch)
            } catch {}
        }

        return value
    }

    public var isOnboarded: Bool
    public var insulinType: InsulinType?
    public var lastSync: Date
    public var pumpSN: Data
    public var lowReservoirWarning: Double?

    // Patch specific data
    public var sessionToken: Data
    public var patchId: Data
    public var patchActivatedAt: Date?
    public var patchGracePeriodFrom: Date? {
        guard let activatedAt = patchActivatedAt else {
            return nil
        }

        return activatedAt.addingTimeInterval(expiryMode.lifespan)
    }

    public var patchExpiresAt: Date? {
        guard let activatedAt = patchActivatedAt else {
            return nil
        }

        return activatedAt.addingTimeInterval(expiryMode.lifespan + expiryMode.gracePeriod)
    }

    public var previousPatch: PreviousPatch?

    public var deviceType: UInt8
    public var swVersion: String

    public var pumpTime: Date
    public var pumpTimeSyncedAt: Date

    public var pumpState: PatchState
    public var doseEntry: UnfinalizedDose?
    public var initialReservoir: Double?
    public var reservoir: Double
    public var battery: Double

    // Patch settings
    public var maxHourlyInsulin: Double
    public var maxDailyInsulin: Double
    public var alarmSetting: AlarmSettings
    public var expiryMode: ExpiryMode
    public var notificationAfterActivation: TimeInterval

    // **** THESE VALUES SHOULD NOT BE PERSISTED ****
    public var primeProgress: UInt8 = 0
    public var isConnected: Bool = false
    // **** END ****

    public var bolusState: BolusState

    public var basalState: BasalState
    public var basalStateSince: Date
    public var basalSchedule: BasalSchedule
    public var tempBasalUnits: Double?
    public var tempBasalDuration: Double?
    public var tempBasalEndsAt: Date {
        basalStateSince + (tempBasalDuration ?? 0)
    }

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        switch basalState {
        case .active:
            return .active(basalStateSince)
        case .suspended:
            return .suspended(basalStateSince)
        case .tempBasal:
            return .tempBasal(
                DoseEntry.tempBasal(
                    absoluteUnit: tempBasalUnits ?? 0,
                    duration: tempBasalDuration ?? 0,
                    insulinType: insulinType!,
                    startDate: basalStateSince
                )
            )
        }
    }

    private let basalIntervals: [TimeInterval] = Array(0 ..< 24).map({ TimeInterval(60 * 60 * $0) })
    public var currentBaseBasalRate: Double {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)

        return basalSchedule.entries.last(where: { $0.startTime < nowTimeInterval })?.rate ?? 0
    }

    public var model: String {
        let type = Crypto.simpleDecrypt(Data(pumpSN.reversed())).toUInt64()

        if (126_000_000 ..< 126_999_999).contains(type) {
            return "MD0201"
        } else if (127_000_000 ..< 127_999_999).contains(type) {
            return "MD5201"
        } else if (128_000_000 ..< 128_999_999).contains(type) {
            return "MD8201"
        } else if (130_000_000 ..< 130_999_999).contains(type) {
            return "MD0202"
        } else if (131_000_000 ..< 131_999_999).contains(type) {
            return "MD5202"
        } else if (148_000_000 ..< 148_999_999).contains(type) {
            return "MD8301"
        } else {
            return "INVALID"
        }
    }

    public var pumpName: String {
        let model = self.model
        if model == "MD8301" {
            return "Medtrum Nano 300U"
        } else if model == "INVALID" {
            return "Medtrum Nano UNKNOWN"
        } else {
            return "Medtrum Nano 200U"
        }
    }

    func shouldShowTimeWarning() -> Bool {
        // Allow a 15 sec diff in time
        abs(pumpTimeSyncedAt.timeIntervalSince1970 - pumpTime.timeIntervalSince1970) > 15
    }

    public var debugDescription: String {
        [
            "## MedtrumPumpState - \(Date.now)",
            "* isOnboarded: \(isOnboarded)",
            "* lastSync: \(lastSync)",
            "* pumpState: \(pumpState.rawValue)",
            "* pumpSN: \(pumpSN.hexEncodedString())",
            "* pumpName: \(pumpName)",
            "* model: \(model)",
            "* swVersion: \(swVersion)",
            "* maxDailyInsulin: \(maxDailyInsulin)u",
            "* maxHourlyInsulin: \(maxHourlyInsulin)u",
            "* battery: \(battery)",
            "* pumpTime: \(pumpTime)",
            "* pumpTimeSyncedAt: \(pumpTimeSyncedAt)",
            "* insulinType: \(String(describing: insulinType))",
            "* reservoirLevel: \(reservoir)",
            "* lowReservoirWarning: \(String(describing: lowReservoirWarning))",
            "* bolusState: \(bolusState.rawValue)"
        ].joined(separator: "\n")
    }
}

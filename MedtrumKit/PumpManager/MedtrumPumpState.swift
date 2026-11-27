import CoreBluetooth
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
        useSilentTones = rawValue["useSilentTones"] as? Bool ?? false
        lowReservoirWarning = rawValue["lowReservoirWarning"] as? Double
        sessionToken = rawValue["sessionToken"] as? Data ?? Data()
        backupSessionToken = rawValue["backupSessionToken"] as? Data ?? Data()
        patchId = rawValue["patchId"] as? Data ?? Data()
        peripheralIdentifier = (rawValue["peripheralIdentifier"] as? String).flatMap { UUID(uuidString: $0) }
        currentSequenceNumber = rawValue["currentSequenceNumber"] as? Int ?? 0
        syncedSequenceNumber = rawValue["syncedSequenceNumber"] as? Int ?? 0
        // Absent in state written before records were matched: never told, nothing skipped or answered
        sequenceConfirmedAt = rawValue["sequenceConfirmedAt"] as? Date
        skippedRecordSequences = rawValue["skippedRecordSequences"] as? [Int] ?? []
        // Saved as number and patch start before builds kept the number only
        answeredBolusRecords = rawValue["answeredBolusRecords"] as? [Int] ??
            (rawValue["answeredBolusRecords"] as? [[String: Any]] ?? []).compactMap { $0["sequence"] as? Int }
        // Absent in state written before it was kept - the released driver's, mid-patch: unknown, taken from the next
        // status naming the newest record (`StateSyncer`). The released driver's cursor there is 0: the backlog read then
        // is the old build's doses, which the host has. A build of this branch before the session start was kept has a
        // cursor: its records from there to that status are not told of either - once.
        sessionStartSequence = rawValue["sessionStartSequence"] as? Int
        unmatchedBolusRecords = rawValue["unmatchedBolusRecords"] as? [Int] ?? []
        bolusesFinalWithoutRecord = (rawValue["bolusesFinalWithoutRecord"] as? [BolusFinalWithoutRecord.RawValue] ?? [])
            .compactMap(BolusFinalWithoutRecord.init(rawValue:))
        possibleBolusRecords = (rawValue["possibleBolusRecords"] as? [PossibleBolusRecord.RawValue] ?? [])
            .compactMap(PossibleBolusRecord.init(rawValue:))
        releasedBolusBacklogRecord = (rawValue["releasedBolusBacklogRecord"] as? PossibleBolusRecord.RawValue)
            .flatMap(PossibleBolusRecord.init(rawValue:))
        patchActivatedAt = rawValue["patchActivatedAt"] as? Date ?? nil
        deviceType = rawValue["deviceType"] as? UInt8 ?? 0
        swVersion = rawValue["swVersion"] as? String ?? "0.0.0"
        pumpTime = rawValue["pumpTime"] as? Date ?? Date()
        pumpTimeSyncedAt = rawValue["pumpTimeSyncedAt"] as? Date ?? Date()
        patchUTCOffset = rawValue["patchUTCOffset"] as? TimeInterval
        maxHourlyInsulin = rawValue["maxHourlyInsulin"] as? Double ?? 20
        maxDailyInsulin = rawValue["maxDailyInsulin"] as? Double ?? 100
        initialReservoir = rawValue["initialReservoir"] as? Double
        reservoir = rawValue["reservoir"] as? Double ?? 0
        battery = rawValue["battery"] as? Double ?? 0
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

        if let pumpStateRaw = rawValue["pumpState"] as? PatchState.RawValue {
            pumpState = PatchState(rawValue: pumpStateRaw) ?? .none
        } else {
            pumpState = .none
        }
        // Not kept by earlier versions: then unknown
        lastShownNotDeliveringAt = rawValue["lastShownNotDeliveringAt"] as? Date

        // Not kept by earlier versions: then only a patch being set up has no session
        patchSessionEnded = rawValue["patchSessionEnded"] as? Bool ?? pumpState.isSetup
        // Not kept by earlier versions: then none sent
        activationSentAt = rawValue["activationSentAt"] as? Date

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

        if let alarmSettingRaw = rawValue["alarmSetting"] as? AlarmSettings.RawValue {
            alarmSetting = AlarmSettings(rawValue: alarmSettingRaw) ?? .BeepOnly
        } else {
            alarmSetting = .BeepOnly
        }

        // Absent in state written before boluses were saved ahead of their command: none
        pendingBolus = (rawValue["pendingBolus"] as? PendingBolus.RawValue).flatMap(PendingBolus.init(rawValue:))
        // Absent in state written before temp basals were saved ahead of their command, or before what followed a temp
        // basal being read was: none
        pendingTempBasal = (rawValue["pendingTempBasal"] as? PendingTempBasal.RawValue).flatMap(PendingTempBasal.init(rawValue:))
        let readAt = Date.now
        heldBasalDoses = (rawValue["heldBasalDoses"] as? [UnfinalizedDose.RawValue] ?? []).compactMap {
            HeldBasalDose(rawValue: $0, readAt: readAt)
        }

        if let rawDoseEntry = rawValue["bolusDose"] as? UnfinalizedDose.RawValue {
            bolusDose = UnfinalizedDose(rawValue: rawDoseEntry)
        } else {
            bolusDose = nil
        }

        // Absent in state written before it was kept: worked out from the doses below, see `MedtrumPumpManager`
        loopWatermark = rawValue["loopWatermark"] as? Date
        if let rawDoseEntry = rawValue["basalDose"] as? UnfinalizedDose.RawValue, let decoded = UnfinalizedDose(rawValue: rawDoseEntry) {
            basalDose = decoded
            basalDoseIsPlaceholder = rawValue["basalDoseIsPlaceholder"] as? Bool ?? false
        } else {
            basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
            basalDoseIsPlaceholder = true
        }

        // Absent in state written before records were matched: none
        unconfirmedTempBasal = (rawValue["unconfirmedTempBasal"] as? UnfinalizedDose.RawValue).flatMap(UnfinalizedDose.init(rawValue:))
        var awaitingRecord = Self.deduplicated(
            (rawValue["awaitingRecord"] as? [UnfinalizedDose.RawValue] ?? []).compactMap(UnfinalizedDose.init(rawValue:))
        )

        // A dose moves from running to waiting in two steps, and the state may have been saved in between: it is then
        // in both places, or finished as the running one only. One dose again, waiting - a copy would be finished, and
        // reported, a second time. The temp basal gives way to the scheduled basal until the next status says what runs.
        func isWaiting(_ dose: UnfinalizedDose) -> Bool {
            if awaitingRecord.contains(where: { $0.isSameDose(as: dose) }) {
                return true
            }
            guard dose.isFinished else {
                return false
            }
            awaitingRecord.append(dose)
            return true
        }
        if let running = bolusDose, isWaiting(running) {
            bolusDose = nil
        }
        if isWaiting(basalDose) {
            basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
            basalDoseIsPlaceholder = true
        }

        awaitingRecordStorage = Locked(awaitingRecord)
        uncertainDeliveriesStorage = Locked(
            (rawValue["uncertainDeliveries"] as? [UncertainDelivery.RawValue] ?? []).compactMap(UncertainDelivery.init(rawValue:))
        )
        // Saved as its dose was finalized, before it was settled
        settleOrphanedUncertainDeliveries(at: Date.now)
    }

    /// One entry per dose. Of two copies of a dose, the one with a final is kept: that final may have reached the host.
    static func deduplicated(_ doses: [UnfinalizedDose]) -> [UnfinalizedDose] {
        var kept: [UnfinalizedDose] = []

        for dose in doses {
            guard let index = kept.firstIndex(where: { $0.isSameDose(as: dose) }) else {
                kept.append(dose)
                continue
            }

            if dose.isFinalized, !kept[index].isFinalized {
                kept[index] = dose
            }
        }

        return kept
    }

    public init(_ basal: BasalRateSchedule?) {
        isOnboarded = false
        lastSync = Date.distantPast
        pumpSN = Data()
        useSilentTones = false
        lowReservoirWarning = nil
        pendingBolus = nil
        pendingTempBasal = nil
        heldBasalDoses = []
        bolusDose = nil
        unconfirmedTempBasal = nil
        awaitingRecordStorage = Locked([])
        uncertainDeliveriesStorage = Locked([])
        sessionToken = Data()
        backupSessionToken = Data()
        patchId = Data()
        peripheralIdentifier = nil
        currentSequenceNumber = 0
        syncedSequenceNumber = 0
        sequenceConfirmedAt = nil
        skippedRecordSequences = []
        answeredBolusRecords = []
        sessionStartSequence = 0
        unmatchedBolusRecords = []
        bolusesFinalWithoutRecord = []
        possibleBolusRecords = []
        releasedBolusBacklogRecord = nil
        patchActivatedAt = nil
        deviceType = 0
        swVersion = "0.0.0"
        pumpTime = Date()
        pumpTimeSyncedAt = Date()
        patchUTCOffset = nil
        pumpState = .none
        lastShownNotDeliveringAt = nil
        patchSessionEnded = true
        activationSentAt = nil

        maxHourlyInsulin = 20
        maxDailyInsulin = 100
        reservoir = 0
        battery = 0
        basalState = .active
        alarmSetting = .BeepOnly
        expiryMode = .default
        notificationAfterActivation = .hours(72)
        previousPatch = nil

        if let basal = basal {
            basalSchedule = BasalSchedule(entries: basal.items)
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }

        basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
        basalDoseIsPlaceholder = true
    }

    public var rawValue: RawValue {
        var value: [String: Any] = [:]

        value["isOnboarded"] = isOnboarded
        value["lastSync"] = lastSync
        value["insulinType"] = insulinType?.rawValue
        value["lowReservoirWarning"] = lowReservoirWarning
        value["pumpSN"] = pumpSN
        value["sessionToken"] = sessionToken
        value["backupSessionToken"] = backupSessionToken
        value["patchId"] = patchId
        value["peripheralIdentifier"] = peripheralIdentifier?.uuidString
        value["currentSequenceNumber"] = currentSequenceNumber
        value["syncedSequenceNumber"] = syncedSequenceNumber
        value["sequenceConfirmedAt"] = sequenceConfirmedAt
        if !skippedRecordSequences.isEmpty {
            value["skippedRecordSequences"] = skippedRecordSequences
        }
        if !answeredBolusRecords.isEmpty {
            value["answeredBolusRecords"] = answeredBolusRecords
        }
        value["sessionStartSequence"] = sessionStartSequence
        if !unmatchedBolusRecords.isEmpty {
            value["unmatchedBolusRecords"] = unmatchedBolusRecords
        }
        if !bolusesFinalWithoutRecord.isEmpty {
            value["bolusesFinalWithoutRecord"] = bolusesFinalWithoutRecord.map(\.rawValue)
        }
        if !possibleBolusRecords.isEmpty {
            value["possibleBolusRecords"] = possibleBolusRecords.map(\.rawValue)
        }
        value["releasedBolusBacklogRecord"] = releasedBolusBacklogRecord?.rawValue
        value["patchActivatedAt"] = patchActivatedAt
        value["patchGracePeriodFrom"] = patchGracePeriodFrom
        value["patchExpiresAt"] = patchExpiresAt
        value["deviceType"] = deviceType
        value["swVersion"] = swVersion
        value["pumpTime"] = pumpTime
        value["pumpTimeSyncedAt"] = pumpTimeSyncedAt
        value["patchUTCOffset"] = patchUTCOffset
        value["pumpState"] = pumpState.rawValue
        value["lastShownNotDeliveringAt"] = lastShownNotDeliveringAt
        value["patchSessionEnded"] = patchSessionEnded
        value["activationSentAt"] = activationSentAt
        value["maxHourlyInsulin"] = maxHourlyInsulin
        value["maxDailyInsulin"] = maxDailyInsulin
        value["basalSchedule"] = basalSchedule.rawValue
        value["initialReservoir"] = initialReservoir
        // The running doses before the ones waiting: a dose is added to `awaitingRecord` before it stops being the
        // running one, so read in this order it is saved in one of them at least - see `init(rawValue:)`. The pending
        // bolus and temp basal first of all: each is cleared after its dose is registered. What is held back after a
        // temp basal being read after the running basal: kept before the dose that followed that temp basal runs. The
        // manager saves the state under its `doseReportLock` besides (`MedtrumPumpManager.rawState`).
        value["pendingBolus"] = pendingBolus?.rawValue
        value["pendingTempBasal"] = pendingTempBasal?.rawValue
        value["bolusDose"] = bolusDose?.rawValue
        value["basalDose"] = basalDose.rawValue
        value["loopWatermark"] = loopWatermark
        if basalDoseIsPlaceholder {
            value["basalDoseIsPlaceholder"] = true
        }
        if !heldBasalDoses.isEmpty {
            value["heldBasalDoses"] = heldBasalDoses.map(\.rawValue)
        }
        value["unconfirmedTempBasal"] = unconfirmedTempBasal?.rawValue
        value["awaitingRecord"] = awaitingRecord.map(\.rawValue)
        value["uncertainDeliveries"] = uncertainDeliveries.map(\.rawValue)
        value["reservoir"] = reservoir
        value["battery"] = battery
        value["basalState"] = basalState.rawValue
        value["alarmSetting"] = alarmSetting.rawValue
        value["expiryMode"] = expiryMode.rawValue
        value["notificationAfterActivation"] = notificationAfterActivation
        value["useSilentTones"] = useSilentTones

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
    public var pumpSN: Data {
        didSet {
            guard pumpSN != oldValue else {
                return
            }

            // prevent ensureConnected from reconnecting straight back to the previous base
            peripheralIdentifier = nil
        }
    }

    public var lowReservoirWarning: Double?
    public var useSilentTones: Bool

    // Patch specific data
    public var sessionToken: Data
    public var backupSessionToken: Data
    public var patchId: Data

    /// The CoreBluetooth identifier of the pump base we are paired with - the base carries the
    /// radio, so this survives a patch change. iOS keeps it stable, which lets us get a
    /// `CBPeripheral` back with `retrievePeripherals(withIdentifiers:)` instead of scanning. That
    /// matters because scanning finds nothing while the app is in the background, whereas
    /// reconnecting to a known peripheral is honoured there.
    public var peripheralIdentifier: UUID?


    /// The highest record number the patch says it has written - the pump reports it in the storage
    /// field of every full status response
    public var currentSequenceNumber: Int
    /// The highest record number we have read back from the patch. Records are numbered per patch,
    /// so this resets whenever `patchId` changes.
    public var syncedSequenceNumber: Int
    /// When the patch last told us its newest record is `currentSequenceNumber` - the storage field of a status, or
    /// the answer to a command that ended a segment - on the manager's clock. A dose's record is written when it ends:
    /// the cursor at a number told before then says nothing of it (`MedtrumPumpManager.isCaughtUp`). Nil until told.
    public var sequenceConfirmedAt: Date?
    /// The latest such telling in this run of the app, on the manager's clock and on the monotonic one - what a bolus's
    /// deadline is checked against, out of reach of a change of the wall clock (`MedtrumPumpManager.sequenceConfirmed`).
    /// Never saved: the monotonic clock of another run, maybe another boot, is not ours. Nil until told in this run.
    public var sequenceConfirmedInThisRun: (at: Date, uptime: TimeInterval)?
    /// Records the sync gave up on as unreadable, never read: only those that could be the record of the unconfirmed
    /// temp basal - numbered past the newest record known when its command went out. It is then never dropped for
    /// having no record. Per patch.
    public var skippedRecordSequences: [Int]
    /// The record numbers the SetBolus answers gave our latest boluses. Assumed: a bolus answered with a record number
    /// has claimed that record - the patch writes that bolus's record under it, whatever becomes of the bolus, and
    /// gives the number to nothing else. So a record with one of these numbers is that bolus's, even one finalized or
    /// gone since - never the record of one whose answer was lost, and the record of a bolus sent later is numbered past
    /// the newest of them (its `PendingBolus.sequenceAtSend` takes it in). Kept while the record may still be read - see
    /// `MedtrumPumpManager.noteAnsweredBolusRecord`. Per patch.
    public var answeredBolusRecords: [Int]
    /// The newest record the patch had written as this state took it up - 0, a patch it activated, or no patch: the
    /// records up to it were written before, none of their doses ours to tell of
    /// (`MedtrumPumpManager.warnOfBolusNotCounted`). Nil, not known yet - a state saved mid-patch by a build that did
    /// not keep it: taken from the next status naming the newest record, as for a new patch id, and not saved until
    /// then. Per patch.
    public var sessionStartSequence: Int?
    /// The bolus records that matched no dose of ours, each looked at once: the user told of it, or a bolus of ours
    /// final without its record found to be it - read again, nothing more is done. Per patch.
    public var unmatchedBolusRecords: [Int]
    /// The latest boluses of ours final without their record - see `BolusFinalWithoutRecord`. Per patch.
    public var bolusesFinalWithoutRecord: [BolusFinalWithoutRecord]
    /// The unmatched bolus records a bolus of ours whose answer was lost could be - see `PossibleBolusRecord`.
    /// Per patch.
    public var possibleBolusRecords: [PossibleBolusRecord]
    /// The newest record read so far, at or before the session start, that could be that of the bolus the released
    /// driver had in flight, waiting on its record - kept until every record written since it ended is read, a newer
    /// one maybe still to come (`MedtrumPumpManager.matchReleasedBolusRecord`). Per patch.
    public var releasedBolusBacklogRecord: PossibleBolusRecord?

    /// The patch the record numbers known now are of - `patchId`'s low 16 bits, as payloads name it - nil with none
    /// known: what a dose's record numbers are noted with (`UnfinalizedDose.State.sequencePatchId`)
    var recordNumbersPatchId: Int? {
        patchId.isEmpty ? nil : Int(patchId.toUInt64() & 0xFFFF)
    }

    /// Forgets what belonged to the records of the patch before
    func resetRecordSequence() {
        currentSequenceNumber = 0
        syncedSequenceNumber = 0
        sequenceConfirmedAt = nil
        sequenceConfirmedInThisRun = nil
        skippedRecordSequences = []
        answeredBolusRecords = []
        sessionStartSequence = 0
        unmatchedBolusRecords = []
        bolusesFinalWithoutRecord = []
        possibleBolusRecords = []
        releasedBolusBacklogRecord = nil
    }

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

    /// How far the patch clock runs ahead of ours, as of the last time we read it
    var patchClockSkew: TimeInterval {
        pumpTime.timeIntervalSince(pumpTimeSyncedAt)
    }

    /// The UTC offset we set on the patch with SetTimeZone: patch-local midnight, where the patch splits a temp basal
    /// into two records, is on it. Nil for a patch set up before this was kept.
    public var patchUTCOffset: TimeInterval?

    public var pumpState: PatchState
    /// When a status of the patch last showed it not delivering - the one `pumpState` is from, while that shows it so.
    /// Unlike `lastSync`, which a command's answer moves too, telling nothing of the patch's state. Nil until shown.
    public var lastShownNotDeliveringAt: Date?
    /// No patch session is running: the last one ended, or none started yet
    public var patchSessionEnded: Bool
    /// When an activation went out to the patch being set up, no session started since - set as its ActivatePacket is
    /// written, cleared as a session starts or ends. Its answer lost, the patch may have activated all the same: the first
    /// status that shows a patch running under another id than the previous one's starts its session - see
    /// `MedtrumPumpManager.startSessionOfActivatedPatchSoon`. A running patch seen without it is not taken as activated.
    public var activationSentAt: Date?
    public var initialReservoir: Double?
    public var reservoir: Double
    public var battery: Double

    // Patch settings
    public var maxHourlyInsulin: Double
    public var maxDailyInsulin: Double
    public var alarmSetting: AlarmSettings
    public var expiryMode: ExpiryMode
    public var notificationAfterActivation: TimeInterval

    /// A cancel of a bolus asked for and not yet over (`MedtrumPumpManager.cancelBolus`): of the bolus running when it was
    /// asked for - or, none running, the one whose SetBolus was out (`pendingSentAt`) - else of none known. It shows
    /// `.canceling` only while that bolus is still the one running: a new bolus is never shown, nor refused, as being
    /// cancelled by a cancel of the one before - and the cancel, once it has the link, writes nothing for it. One of none
    /// known never shows: it stops nothing that runs (`isOfTheRunningBolus`), and showing would only refuse dosing.
    struct BolusCancel {
        let id = UUID()
        let since: Date
        let dose: UnfinalizedDose?
        let pendingSentAt: Date?
    }

    /// The cancels of a bolus not yet over - see `BolusCancel`. Ended as each completes; a completion `ensureConnected`
    /// orphans would leave one for good, so each also runs out after `cancelBolusBackstop`.
    private let bolusCancels = Locked<[BolusCancel]>([])

    /// A cancel's longest run: a connect - joining one past didConnect, its session watchdog 150 s
    /// (`BluetoothManager`), the steps before it 15 s each - the wait for the command lock (`commandActivityTimeout`,
    /// 3 min) and the write (`PeripheralManager.writeTimeout`, 30 s): some 6 min, rounded up. Only a backstop for one
    /// orphaned: its bolus over, a cancel shows `.canceling` no longer anyway, and one of none known never does.
    static let cancelBolusBackstop: TimeInterval = .minutes(7)

    /// The manager's `doseReportLock`, which `bolusDose` and `pendingBolus` change under: a cancel outstanding, whether
    /// it is of the running bolus is read under it (`cancelingBolusSince`)
    weak var doseLock: NSRecursiveLock?

    // **** THESE VALUES SHOULD NOT BE PERSISTED ****
    public var primeProgress: UInt8 = 0
    public var isConnected: Bool = false
    /// When the earliest cancel still showing `.canceling` was asked for - see `BolusCancel`. Not persisted: restored,
    /// nothing would end it.
    public var cancelingBolusSince: Date? {
        let cancels = bolusCancels.value
        guard !cancels.isEmpty else {
            return nil
        }
        let now = Date.now
        let since = { cancels.filter { self.isShowing($0, at: now) }.map(\.since).min() }
        return doseLock.map { $0.withLock(since) } ?? since()
    }
    // last state CoreBluetooth reported
    public var bluetoothState: CBManagerState = .unknown
    /// The latest start of a basal segment the patch reported, on its clock - from statuses and command answers.
    /// What an unanswered temp basal's segment must have started after.
    var lastSegmentStart: Date?
    // **** END ****

    public var bolusDose: UnfinalizedDose?

    /// The SetBolus being written, saved - and handed to the host - before it goes out, never written unless the host
    /// took it (`MedtrumPumpManager.handOverState`): an app killed before its answer comes back with it here, and runs it
    /// as a bolus whose command went unanswered (`MedtrumPumpManager.takeOverPendingBolus`). Cleared as its outcome is
    /// in, with the dose registered in the same step if there is one - or as it is not written after all.
    public var pendingBolus: PendingBolus?

    /// The SetTempBasal being written, saved - and handed to the host - before it goes out, as `pendingBolus`: an app
    /// killed before its answer comes back with it here, and keeps it as a temp basal whose command went unanswered
    /// (`MedtrumPumpManager.takeOverPendingTempBasal`). Cleared as its outcome is in, after its dose is in place if there
    /// is one. Changed under `MedtrumPumpManager.doseReportLock`.
    public var pendingTempBasal: PendingTempBasal?

    /// What followed a temp basal whose records are being read - a suspend, a resume, the scheduled basal - its report
    /// held back until the temp basal's final goes out (`MedtrumPumpManager.TempBasalEnd`), saved until the host
    /// confirms storing a batch that carried it: an app killed meanwhile reports them after all, in its first batch,
    /// with that temp basal final from our estimate - and a batch the host could not store has them go out again, with
    /// that final. A temp basal that followed is not kept here: it runs, and goes out with every batch. Kept here too: a
    /// suspend held back for the records of the temp basal whose command went unanswered
    /// (`MedtrumPumpManager.holdForUnconfirmedRead`), and what is held with it - a resume, a suspend - in the order they
    /// go out. And every other suspend and resume reported, until the host confirms storing it: handed over once, a kill
    /// before the host stored it would lose it for good (`MedtrumPumpManager.keepUntilStored`). Empty otherwise. Changed
    /// under `MedtrumPumpManager.doseReportLock`.
    public var heldBasalDoses: [HeldBasalDose]

    /// A temp basal whose command went out unanswered: kept here, unreported, until a status shows the patch running it
    /// - it then runs - or its record turns up - its final, or a part of it, then finalized from our estimate - or every
    /// record the patch told of 15 min past when it ended at the latest was read, none that could be its skipped -
    /// dropped (`MedtrumPumpManager.unconfirmedTempBasalEnd`). No time limit otherwise: while records cannot be read it
    /// stays, and delivery stays uncertain. The patch session ending drops it. The host keeps counting what it counted
    /// before. Changed under `MedtrumPumpManager.doseReportLock`.
    public var unconfirmedTempBasal: UnfinalizedDose?

    /// Boluses and temp basals that stopped running, until the host has confirmed storing their final report.
    ///
    /// A bolus stays mutable until the patch's record for it has been read, or until we give up on the record. So does a
    /// temp basal a new one replaced back to back, ended open - see `MedtrumPumpManager.openTempBasalEnds`. Any other temp
    /// basal is final as it ends: it is here unfinalized only while its records are read, never reported so - see
    /// `MedtrumPumpManager.TempBasalEnd`. Once finalized a dose stays here with its final, which goes out with every
    /// batch until the host confirms a batch that carried it - see `MedtrumPumpManager.emitPumpEvents`.
    ///
    /// Locked: commands, statuses and the record sync add to and take from it on different queues.
    public var awaitingRecord: [UnfinalizedDose] {
        awaitingRecordStorage.value
    }

    func mutateAwaitingRecord(_ changes: (inout [UnfinalizedDose]) -> Void) {
        awaitingRecordStorage.mutate(changes)
    }

    private let awaitingRecordStorage: Locked<[UnfinalizedDose]>

    /// The doses the driver could not be sure of, oldest first - see `UncertainDelivery`. Locked, as `awaitingRecord`.
    /// Without the ones settled over a day ago: they drop out as the settings screen reads them and as the state is saved.
    public var uncertainDeliveries: [UncertainDelivery] {
        UncertainDelivery.kept(uncertainDeliveriesStorage.value, at: wallClock())
    }

    func mutateUncertainDeliveries(_ changes: (inout [UncertainDelivery]) -> Void) {
        uncertainDeliveriesStorage.mutate(changes)
    }

    private let uncertainDeliveriesStorage: Locked<[UncertainDelivery]>

    /// The doses tracked, running or waiting
    private var trackedDoses: [UnfinalizedDose] {
        [bolusDose, basalDose, unconfirmedTempBasal].compactMap { $0 } + awaitingRecord
    }

    /// Settles every uncertain delivery left unsettled whose dose is final - how is not known - or no longer tracked:
    /// as the state was saved between the two, or the session ended
    func settleOrphanedUncertainDeliveries(at now: Date) {
        let doses = trackedDoses.map { (key: UncertainDelivery.DoseKey($0), final: $0.snapshot) }
        mutateUncertainDeliveries { deliveries in
            for index in deliveries.indices where !deliveries[index].isSettled {
                let dose = doses.first { deliveries[index].isOf($0.key) }
                if let dose, !dose.final.isFinalized {
                    continue
                }
                deliveries[index].outcome = dose == nil ? .untracked : .final
                deliveries[index].delivered = dose?.final.finalDeliveredUnits
                deliveries[index].settledAt = now
            }
        }
    }

    /// Where `delivery` is now: settled, or what the state says of its dose
    public func phase(of delivery: UncertainDelivery) -> UncertainDelivery.Phase {
        if let outcome = delivery.outcome {
            return .settled(outcome)
        }

        switch delivery.kind {
        case .bolus:
            // Running, it counts in full; ended, as the host is told
            guard let dose = trackedDoses.first(where: delivery.isOf) else {
                return .countedInFull
            }
            let ended = dose.snapshot
            guard ended.isFinished, !dose.countsInFull(ended) else {
                return .countedInFull
            }
            return .countedAs(ended.deliveredUnits)
        case .tempBasal:
            return unconfirmedTempBasal.map(delivery.isOf) == true ? .notReported : .awaitingRecord
        case .tempBasalCancel:
            let running = basalDose.snapshot
            guard delivery.isOf(basalDose), !running.isFinished else {
                return .awaitingRecord
            }
            return running.stopUnansweredAt != nil ? .countedRunning : .stillRunning
        }
    }

    /// No session runs, and the patch last reported a state it never leaves: the old patch, stopped as its session ended -
    /// nothing to sync with it, and the new patch's setup that follows is no base reset. Not a running patch with no
    /// session: its activation's answer was lost.
    var stoppedWithNoSession: Bool {
        patchSessionEnded && pumpState.isTerminated
    }

    /// No session runs, and the patch last reported a running state - taken as the new patch's, not the old one's
    /// (`StateSyncer.isEndedSessionsPatchRunning`): its activation's answer was lost, its session not started yet. The
    /// activation's retry starts it (`MedtrumPumpManager.activatePatch`) - the settings screen offers it.
    public var isActivatedWithNoSession: Bool {
        patchSessionEnded && pumpState.isRunning
    }

    /// A bolus whose command went unanswered, still running as far as we know, or a temp basal whose command went
    /// unanswered and is not settled - or a cancel of the running one. For the host's `deliveryIsUncertain`. One that
    /// ended has its count settled by its record or the fallback, counting the more insulin meanwhile.
    public var deliveryIsUncertain: Bool {
        if let bolus = bolusDose?.snapshot, bolus.confirmation == .uncertain, !bolus.isFinished {
            return true
        }

        if unconfirmedTempBasal != nil {
            return true
        }

        let basal = basalDose
        let running = basal.snapshot
        return basal.type == .tempBasal && running.stopUnansweredAt != nil && !running.isFinished &&
            Date.now < basal.estimatedEndDate
    }

    private var isCancelingBolus: Bool {
        cancelingBolusSince != nil
    }

    /// A cancel of a bolus is asked for, of the one running now - or whose SetBolus is out - if any. Ended with
    /// `endBolusCancel`.
    func beginBolusCancel(at date: Date = Date.now) -> BolusCancel {
        let cancel: BolusCancel
        if let running = bolusDose, !running.isFinished {
            cancel = BolusCancel(since: date, dose: running, pendingSentAt: nil)
        } else {
            cancel = BolusCancel(since: date, dose: nil, pendingSentAt: pendingBolus?.sentAt)
        }
        bolusCancels.mutate { $0.append(cancel) }
        return cancel
    }

    func endBolusCancel(_ cancel: BolusCancel) {
        bolusCancels.mutate { $0.removeAll { $0.id == cancel.id } }
    }

    /// Whether `cancel` is of the bolus running now: the one it was asked for, still running - the one whose SetBolus
    /// was out, running or its command still out - or, of none known, none running nor out. A new bolus since is not
    /// what it was asked to stop.
    func isOfTheRunningBolus(_ cancel: BolusCancel) -> Bool {
        let running = bolusDose.flatMap { $0.isFinished ? nil : $0 }
        if let dose = cancel.dose {
            return running === dose
        }
        if let sentAt = cancel.pendingSentAt {
            return running?.sentAt == sentAt || (running == nil && pendingBolus?.sentAt == sentAt)
        }
        return running == nil && pendingBolus == nil
    }

    private func isShowing(_ cancel: BolusCancel, at now: Date) -> Bool {
        (cancel.dose != nil || cancel.pendingSentAt != nil) &&
            now.timeIntervalSince(cancel.since) < Self.cancelBolusBackstop && isOfTheRunningBolus(cancel)
    }

    public var bolusState: BolusState {
        if isCancelingBolus {
            return .canceling
        }

        return bolusDose == nil ? .noBolus : .inProgress
    }

    // basalState is the basalState from the patch itself
    // Preventing acting on an out-dated basalDose
    public var basalState: BasalState
    public var basalDose: UnfinalizedDose {
        didSet {
            basalDoseSince = monotonicClock()
            basalDoseIsPlaceholder = false
        }
    }

    /// `basalDose` stands in for what the patch runs, the host never told of it: the schedule put in place as the state
    /// was read back - none saved, or the temp basal saved there had ended - or at the activation of a patch. Anything
    /// set later, or reported, clears it. Nothing is dated after it as after something the host has.
    public internal(set) var basalDoseIsPlaceholder = false

    /// Loop's watermark, as what was handed to the host makes it - see `LoopWatermark`,
    /// `MedtrumPumpManager.warnIfBehindWhatIsFinal`. Saved: a restart keeps it. Changed under
    /// `MedtrumPumpManager.doseReportLock`.
    public internal(set) var loopWatermark: Date?

    /// When `basalDose` was put in place in this run, on the manager's monotonic clock: a status received before then
    /// says nothing of it. Nil for one read back with the state. Never saved: another run's monotonic clock is not ours.
    var basalDoseSince: TimeInterval?
    /// The manager's monotonic clock (`MedtrumPumpManager.uptime`) - only tests move it
    var monotonicClock: () -> TimeInterval = { .continuousUptime }
    /// The manager's `now`, which settles uncertain deliveries: the one their day is counted on
    var wallClock: () -> Date = { Date.now }
    public var basalSchedule: BasalSchedule

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        switch basalDose.type {
        case .basal,
             .bolus,
             .resume:
            return .active(basalDose.startDate)
        case .suspend:
            return .suspended(basalDose.startDate)
        case .tempBasal:
            // One that ended, while what follows it is put in place: the scheduled basal runs
            let dose = basalDose
            let tempBasal = dose.snapshot
            guard !tempBasal.isFinished else {
                return .active(dose.tempBasalEnd(of: tempBasal))
            }
            return .tempBasal(dose.doseEntry(of: tempBasal, isMutable: true))
        }
    }

    var bolusDeliveryState: PumpManagerStatus.BolusState {
        if isCancelingBolus {
            return .canceling
        }

        guard let dose = bolusDose?.toDoseEntry(isMutable: true) else {
            return .noBolus
        }

        return .inProgress(dose)
    }

    public var currentBaseBasalRate: Double {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)

        return basalSchedule.entries.last(where: { $0.startTime <= nowTimeInterval })?.rate ?? 0
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
            "* patchSessionEnded: \(patchSessionEnded)",
            "* activationSentAt: \(activationSentAt.map { "\($0)" } ?? "-")",
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
            "* bolusState: \(bolusState.rawValue)",
            "* bluetoothState: \(bluetoothState.rawValue)",
            "* patchId: \(patchId.hexEncodedString())",
            "* recordSequence: \(syncedSequenceNumber)/\(currentSequenceNumber) (synced/pump)",
            "* awaitingRecord: \(awaitingRecord.map { "\($0.type.rawValue)@\($0.startDate)\($0.isFinalized ? " (final)" : "")" }.joined(separator: ", "))",
            "* unconfirmedTempBasal: \(unconfirmedTempBasal.map { "\($0.value) U/h sent \($0.sentAt.map { "\($0)" } ?? "-")" } ?? "-")",
            "* pendingTempBasal: \(pendingTempBasal.map { "\($0.unitsPerHour) U/h sent \($0.sentAt)" } ?? "-")",
            "* heldBasalDoses: \(heldBasalDoses.map { "\($0.dose.type.rawValue)@\($0.dose.startDate)" }.joined(separator: ", "))"
        ].joined(separator: "\n")
    }
}

import Foundation

/// One record of a patch's history file, decoded for display: what the patch wrote, and what the driver made of it.
public struct StoredRecord: Identifiable, Equatable {
    public var id: Int { sequence }
    /// The record's own number, as the patch indexes it
    public let sequence: Int
    /// The patch id the record carries - the low two bytes of the patch's
    public let patchId: UInt64
    /// When it was read off the patch
    public let readAt: Date
    /// The answer as it came in: decoded on loading, so a decoder fixed later applies to the records kept before
    public let raw: Data
    /// What the record did to our doses as it was read - `RecordSyncer+Describe`'s text, the dose it finalized, or
    /// "unmatched" - or `PatchRecordHistory.historyReadOutcome` for one read for the history only
    public let outcome: String?
    /// BOLUS, BASAL, TDD, ALARM, ... - as `RecordSyncer.describe` names it
    public let kind: String
    /// Its fields, as the log writes them
    public let summary: String
    /// An event record in words - see `StoredPumpRecord.label`
    public let label: String?
    /// When the event started according to the patch, nil for a record not decoded
    public let eventDate: Date?
    /// False for a number asked for and not answered with its record - unreadable, or another record in its place: kept
    /// so it is not asked for again, `kind` "UNREADABLE", `outcome` saying what came back. Never decoded as a record of
    /// this number: `raw` is what came back, if anything.
    public let isRecord: Bool
}

/// Each patch's records, kept in a file of their own - `Documents/medtrumkit/records/patch-<id>.jsonl`, next to the log -
/// for the current patch and the one before it: the patch has no display, its records are where what it did is compared
/// with what the driver reported. Not in `MedtrumPumpState`, which is saved on every change - see `PumpRecordStore`.
///
/// JSON Lines, one record a line: its number, the patch id it carries, when it was read, the answer's bytes in hex, and
/// what the syncer made of it. A record read again is appended again: the newest line of a number wins on loading. A
/// line that does not decode is skipped. A number asked for and not answered with its record has a line too, marked
/// `notKept`: loaded as no record, it is not missing any more.
///
/// Appends are queued and written on a utility queue of their own - never on the main queue or the Bluetooth queue,
/// as for the log (`MedtrumLogWriter`) - in one write per syncer run (`commit`), or `coalesceDelay` after the first
/// queued. A failed write is logged, and touches nothing else: dosing never waits on this.
///
/// `@unchecked Sendable`: what changes is under `pendingLock` (`pending`, `writeQueued`) or touched on `queue` only (the
/// files, and the coders, used there alone); the rest is set once, in `init`.
final class PatchRecordHistory: @unchecked Sendable {
    /// One line of a history file
    struct Line: Codable, Equatable {
        let sequence: Int
        let patchId: UInt64
        let readAt: Date
        /// `GetRecordResponse.raw`, in hex
        let raw: String
        let outcome: String?
        /// True for a number asked for and not answered with its record (`appendNotKept`); absent otherwise
        var notKept: Bool?
    }

    /// The outcome of a record read for the history only (`MedtrumPumpManager.readMissingRecords`): matched to nothing
    static let historyReadOutcome = "history read"

    /// Next to the log: `Documents/medtrumkit/records`
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("medtrumkit")
            .appendingPathComponent("records")
    }

    private static let logger = MedtrumLogger(category: "RecordHistory")

    let directory: URL
    /// How long a queued append waits for more before it is written, if no `commit` comes first
    let coalesceDelay: TimeInterval

    /// Where the files are written and read. Internal for tests: holding it shows appends do not wait for it.
    let queue = DispatchQueue(label: "com.nightscout.MedtrumKit.recordHistory", qos: .utility)

    private let pendingLock = NSLock()
    /// Queued, not written yet, in order - with the patch whose file they go to. Only under `pendingLock`.
    private var pending: [(patch: UInt64, line: Line)] = []
    /// A write of `pending` is queued. Only under `pendingLock`.
    private var writeQueued = false

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL = PatchRecordHistory.defaultDirectory, coalesceDelay: TimeInterval = 5) {
        self.directory = directory
        self.coalesceDelay = coalesceDelay
    }

    /// The file of patch `patchId` - the full id, as the settings screen shows it
    func fileURL(forPatch patchId: UInt64) -> URL {
        directory.appendingPathComponent("patch-\(patchId).jsonl")
    }

    // MARK: Writing

    /// `response`, read off patch `patchId` at `readAt`, the syncer having made `outcome` of it: queued for its file.
    /// Returns at once.
    func append(_ response: GetRecordResponse, patchId: UInt64, outcome: String?, readAt: Date = Date.now) {
        let line = Line(
            sequence: response.sequence,
            patchId: response.patchId,
            readAt: readAt,
            raw: response.raw.hexEncodedString(),
            outcome: outcome
        )
        enqueue(line, patchId: patchId)
    }

    private func enqueue(_ line: Line, patchId: UInt64) {
        let scheduleWrite = pendingLock.withLock { () -> Bool in
            pending.append((patchId, line))
            defer { writeQueued = true }
            return !writeQueued
        }
        if scheduleWrite {
            queue.asyncAfter(deadline: .now() + coalesceDelay) { [weak self] in
                self?.writePending()
            }
        }
    }

    /// Number `sequence` of patch `patchId` was asked for and not answered with its record - `raw` is what came back,
    /// empty if nothing usable: noted, so it is no longer missing (`missingSequences`), with `outcome` saying why. Loaded
    /// as no record (`StoredRecord.isRecord`). A later read of the record itself wins, as the newest line.
    func appendNotKept(sequence: Int, patchId: UInt64, raw: Data, outcome: String, readAt: Date = Date.now) {
        enqueue(
            Line(
                sequence: sequence,
                patchId: patchId & 0xFFFF,
                readAt: readAt,
                raw: raw.hexEncodedString(),
                outcome: outcome,
                notKept: true
            ),
            patchId: patchId
        )
    }

    /// What is queued, written now - off the caller's queue: the end of a syncer run, the app going to the background
    func commit() {
        queue.async { [weak self] in
            self?.writePending()
        }
    }

    /// What is queued, on disk before this returns - before the files are shared. Not on the Bluetooth queue.
    func flush() {
        queue.sync {
            writePending()
        }
    }

    /// Only on `queue`
    private func writePending() {
        let lines = pendingLock.withLock { () -> [(patch: UInt64, line: Line)] in
            defer {
                pending = []
                writeQueued = false
            }
            return pending
        }
        guard !lines.isEmpty else {
            return
        }

        var byPatch: [UInt64: Data] = [:]
        var order: [UInt64] = []
        for (patch, line) in lines {
            guard let encoded = try? encoder.encode(line) else {
                Self.logger.error("Record history: record \(line.sequence) of patch \(patch) not encoded, dropped")
                continue
            }
            if byPatch[patch] == nil {
                order.append(patch)
            }
            byPatch[patch, default: Data()].append(encoded + Data([0x0A]))
        }

        for patch in order {
            guard let data = byPatch[patch] else {
                continue
            }
            do {
                try write(data, toFileOf: patch)
            } catch {
                let count = lines.filter { $0.patch == patch }.count
                Self.logger.error("Record history: \(count) record(s) of patch \(patch) not written: \(error.localizedDescription)")
            }
        }
    }

    /// Only on `queue`
    private func write(_ data: Data, toFileOf patch: UInt64) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = fileURL(forPatch: patch)
        guard fileManager.fileExists(atPath: url.path) else {
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        // A line cut short - the app killed as it wrote - is ended first: the next one is not lost with it
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if last != Data([0x0A]) {
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.write(contentsOf: data)
    }

    // MARK: Pruning

    /// Deletes the files of every patch but `keeping` - the current one and the one before it, at a patch change. What
    /// is queued is written first. Off the caller's queue.
    func prune(keeping: Set<UInt64>) {
        queue.async { [weak self] in
            self?.writePending()
            self?.deleteFiles(except: keeping)
        }
    }

    /// Only on `queue`
    private func deleteFiles(except keeping: Set<UInt64>) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names {
            guard let patch = Self.patchId(ofFileNamed: name), !keeping.contains(patch) else {
                continue
            }
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
                Self.logger.info("Record history: the file of patch \(patch) deleted")
            } catch {
                Self.logger.error("Record history: the file of patch \(patch) not deleted: \(error.localizedDescription)")
            }
        }
    }

    /// The patch id of a history file's name - `patch-278.jsonl` - nil for any other file
    static func patchId(ofFileNamed name: String) -> UInt64? {
        guard name.hasPrefix("patch-"), name.hasSuffix(".jsonl") else {
            return nil
        }
        return UInt64(name.dropFirst("patch-".count).dropLast(".jsonl".count))
    }

    // MARK: Reading

    /// Which of `patches` have a file, in that order - what is queued written first. Not on the Bluetooth queue.
    func files(of patches: [UInt64]) -> [URL] {
        queue.sync {
            writePending()
            return patches.map(fileURL(forPatch:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// The patches that have a file, newest - highest id - first
    func patchesWithFiles() -> [UInt64] {
        queue.sync {
            writePending()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.compactMap(Self.patchId(ofFileNamed:)).sorted(by: >)
        }
    }

    /// The records of patch `patchId`, decoded, newest first, one per number - the newest line of each
    func records(forPatch patchId: UInt64) async -> [StoredRecord] {
        await onQueue { $0.loadRecords(forPatch: patchId) }
    }

    /// The numbers from 1 to the newest record known - kept, or `through` if that is further on - of which patch
    /// `patchId` has no record kept, in order: records skipped as unreadable, or written before the driver first read
    /// the patch (`RecordSyncer.initialBacklog`)
    func missingSequences(forPatch patchId: UInt64, through: Int? = nil) async -> [Int] {
        await onQueue { $0.computeMissingSequences(forPatch: patchId, through: through) }
    }

    /// `missingSequences`, waiting for the queue. Not on the main or the Bluetooth queue.
    func missingSequencesNow(forPatch patchId: UInt64, through: Int? = nil) -> [Int] {
        queue.sync {
            computeMissingSequences(forPatch: patchId, through: through)
        }
    }

    /// Only on `queue`
    private func computeMissingSequences(forPatch patchId: UInt64, through: Int?) -> [Int] {
        writePending()
        let known = Set(latestLines(forPatch: patchId).keys)
        let newest = max(through ?? 0, known.max() ?? 0)
        guard newest > 0 else {
            return []
        }
        return (1 ... newest).filter { !known.contains($0) }
    }

    /// Only on `queue`
    private func loadRecords(forPatch patchId: UInt64) -> [StoredRecord] {
        writePending()
        return latestLines(forPatch: patchId).values
            .compactMap { line -> StoredRecord? in
                guard let raw = line.raw.isEmpty ? Data() : Self.bytes(ofHex: line.raw) else {
                    Self.logger.warning("Record history: record \(line.sequence) of patch \(patchId) is not hex, skipped")
                    return nil
                }
                let response = GetRecordPacket.decode(raw: raw)
                // Noted as not kept - or bytes that are not this number's record of this patch: no record of it
                guard line.notKept != true, let response, response.sequence == line.sequence,
                      RecordSyncer.isSamePatch(response.patchId, patchId)
                else {
                    guard line.notKept == true || response != nil else {
                        Self.logger.warning("Record history: record \(line.sequence) of patch \(patchId) does not decode, skipped")
                        return nil
                    }
                    return StoredRecord(
                        sequence: line.sequence,
                        patchId: line.patchId,
                        readAt: line.readAt,
                        raw: raw,
                        outcome: line.outcome,
                        kind: "UNREADABLE",
                        summary: line.outcome ?? "not answered with its record",
                        label: nil,
                        eventDate: nil,
                        isRecord: false
                    )
                }
                let described = RecordSyncer.describe(response.record)
                return StoredRecord(
                    sequence: line.sequence,
                    patchId: line.patchId,
                    readAt: line.readAt,
                    raw: raw,
                    outcome: line.outcome,
                    kind: described.kind,
                    summary: described.summary,
                    label: described.label,
                    eventDate: described.eventDate,
                    isRecord: true
                )
            }
            .sorted { $0.sequence > $1.sequence }
    }

    /// The newest line of each number in the file of patch `patchId`, a line that does not parse skipped. Only on `queue`.
    private func latestLines(forPatch patchId: UInt64) -> [Int: Line] {
        guard let data = try? Data(contentsOf: fileURL(forPatch: patchId)) else {
            return [:]
        }
        var lines: [Int: Line] = [:]
        var corrupt = 0
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(Line.self, from: Data(slice)) else {
                corrupt += 1
                continue
            }
            // In the order written: a later read of the number wins
            lines[line.sequence] = line
        }
        if corrupt > 0 {
            Self.logger.warning("Record history: \(corrupt) line(s) of the file of patch \(patchId) unreadable, skipped")
        }
        return lines
    }

    /// `hex` as bytes, nil if it is not hex - `Data(hex:)` traps on a string without a byte in it
    private static func bytes(ofHex hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index ... index + 1], as: UTF8.self), radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }

    private func onQueue<T>(_ work: @escaping (PatchRecordHistory) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work(self))
            }
        }
    }
}

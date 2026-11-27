import Foundation

/// What the history screen reads: the manager - or a fake, in tests
protocol PatchHistorySource: AnyObject {
    func historyRecords(forPatch patchId: UInt64) async -> [StoredRecord]
    func missingRecordSequences(forPatch patchId: UInt64) async -> [Int]
    func fillRecordHistory(limit: Int) async -> RecordHistoryFill
    func recordHistoryFilesForSharing() -> [URL]
}

extension MedtrumPumpManager: PatchHistorySource {}

/// Backs the history screen of one patch - the current one, or the one before: every record kept in its file
/// (`PatchRecordHistory`), newest first, and how many numbers have none.
///
/// For the current patch, the missing records can be read off the patch (`fillRecordHistory`): only when asked, a page
/// at a time until every missing one was asked for or the manager stops - never as the screen appears, as it takes the
/// link. Leaving the screen stops it after the page being read.
@MainActor final class PatchHistoryViewModel: ObservableObject {
    /// How far a fill is: the numbers asked for so far, of the ones missing as it began
    struct Progress: Equatable {
        let asked: Int
        let missing: Int
    }

    let patchId: UInt64
    let isCurrentPatch: Bool

    /// Newest first, one per number - a number kept without its record included, `isRecord` false
    @Published private(set) var records: [StoredRecord] = []
    /// The numbers with nothing kept, from 1 on
    @Published private(set) var missing: [Int] = []
    /// The file has been read once
    @Published private(set) var isLoaded = false
    /// A fill runs. Nil, none.
    @Published private(set) var progress: Progress?
    /// Why the last fill stopped, in words. Nil, none ran - or one runs.
    @Published private(set) var stopLine: String?
    /// The fill was stopped - Stop, or the screen left - and the page in flight is still being read
    @Published private(set) var isStopping = false
    /// This patch's file, looked for off the main queue: nil until it has been - see `prepareShare`
    @Published private(set) var shareURLs: [URL]?
    /// The file is being looked for, to share it
    @Published private(set) var isPreparingShare = false

    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private let source: PatchHistorySource?
    private var fillTask: Task<Void, Never>?

    init(patchId: UInt64, isCurrentPatch: Bool, source: PatchHistorySource?) {
        self.patchId = patchId
        self.isCurrentPatch = isCurrentPatch
        self.source = source
    }

    var recordCount: Int {
        records.filter(\.isRecord).count
    }

    var unreadableCount: Int {
        records.count - recordCount
    }

    /// "N records · M missing" - and how many could not be read, if any
    var countsLine: String {
        var line = String(
            localized: "\(recordCount) records · \(missing.count) missing",
            comment: "patch history: the records kept, and the numbers with none"
        )
        if unreadableCount > 0 {
            line += " · " + String(
                localized: "\(unreadableCount) could not be read",
                comment: "patch history: the numbers kept without their record"
            )
        }
        return line
    }

    /// The missing records can be read: the current patch's, some missing, no fill running
    var canReadMissing: Bool {
        isCurrentPatch && !missing.isEmpty && progress == nil
    }

    var progressLine: String? {
        guard let progress else {
            return nil
        }
        if isStopping {
            return String(localized: "Stopping…", comment: "patch history: a stopped fill finishing the page it reads")
        }
        return String(
            localized: "Reading… \(progress.asked) of \(progress.missing) missing",
            comment: "patch history: a fill of the missing records running"
        )
    }

    /// The file read again - as the screen appears, and after each page of a fill. Reads nothing off the patch.
    func load() async {
        guard let source else {
            isLoaded = true
            return
        }
        let records = await source.historyRecords(forPatch: patchId)
        let missing = await source.missingRecordSequences(forPatch: patchId)
        self.records = records
        self.missing = missing
        isLoaded = true
    }

    /// The user asked to read the missing records: pages until every missing one was asked for, or a stop
    func readMissing() {
        guard canReadMissing, fillTask == nil else {
            return
        }
        // Shown at once: one fill at a time
        progress = Progress(asked: 0, missing: missing.count)
        fillTask = Task { [weak self] in
            await self?.fill()
            self?.fillTask = nil
        }
    }

    /// The screen went away - or the user stopped it: no page after the one being read
    func stopReading() {
        guard let fillTask, !fillTask.isCancelled else {
            return
        }
        fillTask.cancel()
        isStopping = true
    }

    func fill() async {
        // Before anything returns: a progress shown - by `readMissing` - never outlives the fill
        defer {
            progress = nil
            isStopping = false
        }
        guard let source, isCurrentPatch else {
            return
        }
        stopLine = nil
        var asked = 0
        let missingAtStart = missing.count
        progress = Progress(asked: 0, missing: missingAtStart)

        while !Task.isCancelled {
            let page = await source.fillRecordHistory(limit: MedtrumPumpManager.recordHistoryPageSize)
            let pageAsked = page.read.count + page.notKept.count
            asked += pageAsked
            await load()

            // A page in full, and more to read: the next - unless one asked for nothing, which would never end
            guard page.stop == .limitReached, pageAsked > 0 else {
                stopLine = Self.line(for: page.stop)
                return
            }
            progress = Progress(asked: asked, missing: max(missingAtStart, asked + missing.count))
        }
    }

    /// Why a fill stopped, in words - not an alarm: nothing of the dosing depends on it
    static func line(for stop: RecordHistoryFill.Stop) -> String {
        switch stop {
        case .done,
             .limitReached:
            return String(localized: "Nothing more to read", comment: "patch history: the fill read every missing record")
        case .linkBusy:
            return String(
                localized: "The pump is busy — try again in a moment",
                comment: "patch history: the fill gave way to another command"
            )
        case .bolusRunning:
            return String(localized: "Not while a bolus is running", comment: "patch history: the fill stopped for a bolus")
        case .linkLost:
            return String(localized: "Lost the connection", comment: "patch history: the fill stopped as the link was lost")
        case .noSession,
             .sessionChanged:
            return String(localized: "The patch changed", comment: "patch history: the fill stopped as the patch changed")
        }
    }

    /// This patch's file, written out first - nothing if it has none. Looked for off the main queue: what is queued for
    /// the file is written first, waiting for the history's queue.
    @discardableResult func prepareShare() async -> [URL] {
        guard let source else {
            shareURLs = []
            return []
        }
        isPreparingShare = true
        defer {
            isPreparingShare = false
        }
        let patchId = patchId
        // Safe to hand to another queue: the manager is used across queues by design, and `recordHistoryFilesForSharing`
        // reads the files on the history's own queue (`PatchRecordHistory.files`), waiting for it
        let sendable = UncheckedSendable(source)
        let urls = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: sendable.value.recordHistoryFilesForSharing().filter {
                    PatchRecordHistory.patchId(ofFileNamed: $0.lastPathComponent) == patchId
                })
            }
        }
        shareURLs = urls
        return urls
    }
}

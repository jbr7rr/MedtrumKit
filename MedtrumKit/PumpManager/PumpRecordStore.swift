import Combine
import Foundation

/// One record read off the patch, flattened for display.
///
/// The packet types stay internal to MedtrumKit: what the screen needs is what the log already prints,
/// so the syncer formats a record once and both the log and this store get the same text.
public struct StoredPumpRecord: Identifiable, Equatable {
    /// The record's own sequence number, which is what the patch indexes by
    public let id: Int
    /// When we read it, as opposed to when the event it describes happened
    public let fetchedAt: Date
    /// BOLUS, BASAL, TDD, ALARM, RESUMED, DAILY, BASE, or a note about why we couldn't parse it
    public let kind: String
    /// The fields, in the same order the log writes them
    public let summary: String
    /// What an event record is, in words, with its key values - "Reservoir empty", "Base: 11,419 U · 8000 h · 44
    /// patches". Nil for the others, which `kind` names well enough.
    public let label: String?
    /// When the event started according to the patch - nil for records we don't decode. This is what a
    /// dose of ours will eventually be matched against, so it is worth seeing next to our own times.
    public let eventDate: Date?
    /// What the record did to our doses - the dose it finalized, or that it matched none. Nil where there is nothing
    /// to match.
    public let outcome: String?
}

/// A dose exactly as it was handed to the host, flattened for display.
///
/// This is the reported side of the comparison: not what we think is happening now, but what the host
/// was actually told - including the identity it was told under, since a dose reported twice under two
/// identities is precisely the failure mode worth seeing.
public struct EmittedDose: Identifiable, Equatable {
    public let id = UUID()
    public let emittedAt: Date
    /// BOLUS, TEMPBASAL, BASAL, SUSPEND, RESUME
    public let kind: String
    public let start: Date
    public let end: Date
    /// `syncIdentifier` - stable for a dose's whole life, so repeats of the same value are updates of
    /// one dose while a changed value means the host sees a different dose
    public let identity: String
    public let isMutable: Bool
    public let programmed: Double
    public let delivered: Double?

    public static func == (lhs: EmittedDose, rhs: EmittedDose) -> Bool {
        lhs.id == rhs.id
    }
}

/// The records we have read from the patch, kept for the debug screen.
///
/// In memory only, and deliberately so: records can always be re-read from the patch, while the pump
/// state is serialized on every change, so parking a growing list there would make every save heavier.
/// The doses *we* report are the opposite case - they have to survive a restart - and those stay in
/// `MedtrumPumpState`.
///
/// Every mutation lands on the main queue, so `@Published` is only ever touched there and SwiftUI can
/// read it directly. The syncer calls in from a utility queue.
public final class PumpRecordStore: ObservableObject {
    /// What the syncer is doing, so the screen shows progress rather than just going quiet for a while.
    public enum Status: Equatable {
        case idle
        case syncing(sequence: Int, upTo: Int)
        case failed(String)
    }

    /// Newest first, and capped - this is a debug view, not an audit trail.
    private static let capacity = 200

    /// Lower than the record cap on purpose: a dose is written here every time it is reported, not once,
    /// so a temp basal re-sent on each batch fills this far faster than records arrive.
    private static let emittedCapacity = 200

    @Published public private(set) var records: [StoredPumpRecord] = []
    /// Newest first, capped the same way as `records`
    @Published public private(set) var emitted: [EmittedDose] = []
    @Published public private(set) var status: Status = .idle
    @Published public private(set) var lastSyncedAt: Date?
    /// Set when a record can't be read but the sync carries on, so a one-off failure is still visible
    /// after the status has gone back to idle.
    @Published public private(set) var lastError: String?

    public init() {}

    func setStatus(_ status: Status) {
        onMain {
            self.status = status

            if case let .failed(message) = status {
                self.lastError = message
            }
        }
    }

    func finishedSync() {
        onMain {
            self.status = .idle
            self.lastSyncedAt = Date.now
        }
    }

    func store(_ record: StoredPumpRecord) {
        onMain {
            // A record can be read more than once - a retry, or a re-read of one that was still being
            // written - and the newer read wins rather than appearing twice
            self.records.removeAll { $0.id == record.id }
            self.records.append(record)

            // Always by sequence, newest first: a sync walks upwards
            self.records.sort { $0.id > $1.id }

            if self.records.count > Self.capacity {
                self.records.removeLast(self.records.count - Self.capacity)
            }
        }
    }

    func store(emitted doses: [EmittedDose]) {
        guard !doses.isEmpty else {
            return
        }

        onMain {
            self.emitted.insert(contentsOf: doses, at: 0)

            if self.emitted.count > Self.emittedCapacity {
                self.emitted.removeLast(self.emitted.count - Self.emittedCapacity)
            }
        }
    }

    /// Records are numbered per patch, so anything we hold is meaningless once the patch changes. The
    /// doses we emitted are kept: they describe insulin that was actually delivered, which a patch
    /// change does not undo.
    func clear() {
        onMain {
            self.records = []
            self.status = .idle
            self.lastSyncedAt = nil
            self.lastError = nil
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

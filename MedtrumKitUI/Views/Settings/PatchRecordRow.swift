import SwiftUI

/// One record of the patch, as the records screen and the history screen show it: its number and what it is, when the
/// event started by the patch, its fields, and what the syncer made of it.
///
/// A number kept without its record - unreadable, or answered with another record - is shown dimmed as that, never as an
/// event.
struct PatchRecordRow: View {
    let title: String
    let time: String?
    let summary: String?
    let outcome: String?
    let isPlaceholder: Bool

    /// A record the sync read, from the in-memory list of the records screen
    init(_ record: StoredPumpRecord, dateFormatter: DateFormatter) {
        // An event record by what it is - "Reservoir empty", "Base: ..." - the rest by kind
        title = "#\(record.id)  \(record.label ?? record.kind)"
        time = record.eventDate.map { dateFormatter.string(from: $0) }
        summary = record.summary
        outcome = record.outcome
        isPlaceholder = false
    }

    /// A record of a patch's history file - or a number kept without its record
    init(_ record: StoredRecord, dateFormatter: DateFormatter) {
        if record.isRecord {
            title = "#\(record.sequence)  \(record.label ?? record.kind)"
            time = record.eventDate.map { dateFormatter.string(from: $0) }
            summary = record.summary
        } else {
            title = Self.placeholderTitle(record.sequence)
            time = nil
            summary = nil
        }
        outcome = record.outcome
        isPlaceholder = !record.isRecord
    }

    static func placeholderTitle(_ sequence: Int) -> String {
        String(localized: "Record \(sequence) could not be read", comment: "patch history: a record number kept without its record")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(isPlaceholder ? .secondary : .primary)
                Spacer()
                if let time {
                    Text(time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let summary {
                Text(summary)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcome {
                Text(outcome)
                    .font(.caption2.monospaced())
                    .foregroundColor(outcomeColor(outcome))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .opacity(isPlaceholder ? 0.6 : 1)
    }

    private func outcomeColor(_ outcome: String) -> Color {
        if isPlaceholder || outcome == PatchRecordHistory.historyReadOutcome {
            // Matched to nothing, by design: not a finding
            return .secondary
        }
        return outcome == "unmatched" ? .orange : .green
    }
}

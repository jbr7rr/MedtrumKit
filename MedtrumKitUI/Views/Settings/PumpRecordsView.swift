import SwiftUI

/// Diagnostic screen: the doses we are tracking, next to the records the patch has written.
///
/// Strings here are deliberately not localized - this exists to make the record matching work
/// debuggable while it is being built, and the layout will keep changing until it settles.
struct PumpRecordsView: View {
    @ObservedObject var viewModel: PumpRecordsViewModel
    @ObservedObject var store: PumpRecordStore

    var body: some View {
        List {
            Section {
                row("Status", statusText)
                row("Records", "\(viewModel.syncedSequence) / \(viewModel.currentSequence) synced")

                if viewModel.pendingRecords > 0 {
                    row("Pending", "\(viewModel.pendingRecords)")
                }

                if let lastSyncedAt = store.lastSyncedAt {
                    row("Last sync", viewModel.dateFormatter.string(from: lastSyncedAt))
                }

                if let lastError = store.lastError {
                    row("Last error", lastError, color: .red)
                }
            } header: {
                Text("Sync")
            }

            Section {
                ForEach(viewModel.doses) { dose in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(dose.kind)
                                .font(.caption.bold())
                            Spacer()
                            Text(viewModel.dateFormatter.string(from: dose.start))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text(dose.detail)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("In flight")
            } footer: {
                Text("What the driver currently believes is being delivered, and the finished doses still waiting on their record.")
            }

            Section {
                if store.emitted.isEmpty {
                    Text("Nothing reported yet")
                        .foregroundColor(.secondary)
                } else {
                    Button(action: { store.clearEmitted() }) {
                        Text("Clear")
                    }

                    ForEach(store.emitted) { dose in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(dose.kind)
                                    .font(.caption.bold())
                                if dose.isMutable {
                                    Text("mutable")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                                Spacer()
                                Text(viewModel.dateFormatter.string(from: dose.start))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(viewModel.describe(dose))
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(dose.identity)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Reported to the host")
            } footer: {
                Text(
                    "Newest first, last 50. The bottom line is the syncIdentifier - it must stay " +
                        "identical across every report of one dose, so a repeat means an update and a " +
                        "change means the host now sees two doses."
                )
            }

            Section {
                if let fetchError = viewModel.fetchError {
                    Text(fetchError)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                fetchButton("Fetch newest record #\(viewModel.currentSequence)", .current)

                if store.records.isEmpty {
                    // Nothing held, so the only sensible move is to pull the most recent ones - both
                    // directions would do the same thing, so offer one button rather than a choice
                    fetchButton("Fetch 10 latest records", .newer)
                } else {
                    if let newest = store.newestRecordSequence, newest <= viewModel.currentSequence {
                        fetchButton("Fetch 10 newer records", .newer)
                    }

                    // Records are newest first, so newer belongs above the list and earlier below it
                    ForEach(store.records) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("#\(record.id)  \(record.kind)")
                                    .font(.caption.bold())
                                Spacer()
                                if let eventDate = record.eventDate {
                                    Text(viewModel.dateFormatter.string(from: eventDate))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(record.summary)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let outcome = record.outcome {
                                Text(outcome)
                                    .font(.caption2.monospaced())
                                    .foregroundColor(outcome == "unmatched" ? Color.orange : Color.green)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if let oldest = store.oldestRecordSequence, oldest > 1 {
                        fetchButton("Fetch 10 earlier records", .older)
                    }
                }
            } header: {
                Text("Patch records")
            } footer: {
                Text("Newest first, kept in memory only - cleared when the patch changes or the app restarts.")
            }
        }
        .listStyle(InsetGroupedListStyle())
    }

    private var statusText: String {
        switch store.status {
        case .idle:
            return "Idle"
        case let .syncing(sequence, upTo):
            return "Reading \(sequence) of \(upTo)"
        case let .failed(message):
            return message
        }
    }

    @ViewBuilder private func fetchButton(
        _ title: String,
        _ direction: MedtrumPumpManager.RecordFetchDirection
    ) -> some View {
        Button(action: { viewModel.fetchRecords(direction) }) {
            HStack {
                Text(title)
                Spacer()
                if viewModel.isFetching {
                    ProgressView()
                }
            }
        }
        // A fetch shares the BLE link with everything else, so never start one on top of a sync
        .disabled(viewModel.isFetching || store.status != .idle)
    }

    @ViewBuilder private func row(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .foregroundColor(color)
                .multilineTextAlignment(.trailing)
        }
    }
}

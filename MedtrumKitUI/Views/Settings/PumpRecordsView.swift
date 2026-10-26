import SwiftUI

/// Diagnostic screen: the doses we are tracking, next to the records the patch has written.
///
/// Strings here are deliberately not localized - this exists to make the record matching work
/// debuggable while it is being built, and the layout will keep changing until it settles.
struct PumpRecordsView: View {
    @ObservedObject var viewModel: PumpRecordsViewModel
    @ObservedObject var store: PumpRecordStore
    @State private var groupReports = true

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
                    Toggle("Group by dose", isOn: $groupReports)

                    let groups = viewModel.reportedDoses(store.emitted)

                    if groupReports {
                        ForEach(groups) { group in
                            DisclosureGroup {
                                ForEach(group.reports) { report in
                                    reportLine(report)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(group.latest.kind)
                                            .font(.caption.bold())
                                        stateBadge(group.latest)
                                        Text("×\(group.reports.count)")
                                            .font(.caption2.bold())
                                            .foregroundColor(group.reports.count > 1 ? .blue : .secondary)
                                        Spacer()
                                        Text(viewModel.dateFormatter.string(from: group.latest.start))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(viewModel.describe(group.latest))
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    identityLine(group.identity, tag: group.tag)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } else {
                        ForEach(store.emitted) { dose in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(dose.kind)
                                        .font(.caption.bold())
                                    stateBadge(dose)
                                    if let position = viewModel.position(of: dose, in: groups) {
                                        Text("report \(position.index)/\(position.count)")
                                            .font(.caption2)
                                            .foregroundColor(position.count > 1 ? .blue : .secondary)
                                    }
                                    Spacer()
                                    Text(viewModel.dateFormatter.string(from: dose.start))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text("sent " + viewModel.dateFormatter.string(from: dose.emittedAt))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(viewModel.describe(dose))
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                identityLine(
                                    dose.identity,
                                    tag: viewModel.position(of: dose, in: groups)?.tag
                                )
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } header: {
                Text("Reported to the host")
            } footer: {
                Text(
                    "Newest first, last 200 reports, grouped by the dose's syncIdentifier: ×N is how often " +
                        "that dose was reported - its mutable updates, then the final. The identity must stay " +
                        "the same across every report of one dose; a changed one means the host now sees two " +
                        "doses. Ungrouped, the [tag] after each identity matches the reports of one dose."
                )
            }

            Section {
                if store.records.isEmpty {
                    Text("No records read yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.records) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                // An event record by what it is - "Reservoir empty", "Base: ..." - the rest by kind
                                Text("#\(record.id)  \(record.label ?? record.kind)")
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

    /// One report of a dose, inside its group: when it went out and what it said
    @ViewBuilder private func reportLine(_ report: EmittedDose) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("sent " + viewModel.dateFormatter.string(from: report.emittedAt))
                    .font(.caption2)
                stateBadge(report)
            }
            Text(viewModel.describe(report))
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder private func stateBadge(_ dose: EmittedDose) -> some View {
        Text(dose.isMutable ? "mutable" : "final")
            .font(.caption2)
            .foregroundColor(dose.isMutable ? .orange : .green)
    }

    @ViewBuilder private func identityLine(_ identity: String, tag: String?) -> some View {
        Text(tag.map { "[\($0)] " + identity } ?? identity)
            .font(.caption2.monospaced())
            .foregroundColor(.secondary.opacity(0.6))
            .lineLimit(1)
            .truncationMode(.middle)
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

import SwiftUI

/// Every record kept of one patch - the current one, or the one before - newest first, laid out as the records screen
/// lays out its newest 200. For the current patch, the missing records can be read off the patch, when asked.
struct PatchHistoryView: View {
    @ObservedObject var viewModel: PatchHistoryViewModel
    @State private var isSharePresented = false

    var body: some View {
        List {
            Section {
                Text(viewModel.countsLine)
                    .foregroundColor(.secondary)

                if viewModel.isCurrentPatch {
                    if let progressLine = viewModel.progressLine {
                        HStack {
                            ActivityIndicator()
                            Text(progressLine)
                                .foregroundColor(.secondary)
                            Spacer()
                            if !viewModel.isStopping {
                                Button {
                                    viewModel.stopReading()
                                } label: {
                                    Text("Stop", comment: "patch history: button stopping the read of the missing records")
                                }
                            }
                        }
                    } else if !viewModel.missing.isEmpty {
                        Button {
                            viewModel.readMissing()
                        } label: {
                            Text("Read missing records", comment: "patch history: button reading the missing records off the patch")
                        }
                        .disabled(!viewModel.canReadMissing)
                    }

                    if let stopLine = viewModel.stopLine {
                        Text(stopLine)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                if !viewModel.records.isEmpty {
                    Button {
                        Task {
                            // Presented once the file has been looked for, off the main queue
                            let urls = await viewModel.prepareShare()
                            isSharePresented = !urls.isEmpty
                        }
                    } label: {
                        HStack {
                            Text("Share", comment: "patch history: button sharing the patch's record file")
                            Spacer()
                            if viewModel.isPreparingShare {
                                ActivityIndicator()
                            }
                        }
                    }
                    .disabled(viewModel.isPreparingShare)
                    .sheet(isPresented: $isSharePresented) {
                        ActivityViewController(activityItems: viewModel.shareURLs ?? [])
                    }
                }
            } header: {
                Text("Patch \(String(viewModel.patchId))", comment: "patch history: header with the patch id")
            } footer: {
                if viewModel.isCurrentPatch {
                    Text(
                        "Reads the missing records off the patch, \(MedtrumPumpManager.recordHistoryPageSize) at a time, while this screen is open.",
                        comment: "patch history: footer explaining the read of the missing records"
                    )
                }
            }

            Section {
                if !viewModel.isLoaded {
                    ActivityIndicator()
                } else if viewModel.records.isEmpty {
                    Text("No records kept", comment: "patch history: the patch has no record kept")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.records) { record in
                        PatchRecordRow(record, dateFormatter: viewModel.dateFormatter)
                    }
                }
            } header: {
                Text("Records", comment: "patch history: header of the records")
            } footer: {
                Text("Newest first.", comment: "patch history: footer of the records")
            }
        }
        .listStyle(InsetGroupedListStyle())
        // Reads the file only: a fill takes the link, and starts only when asked
        .task {
            await viewModel.load()
        }
        .onDisappear {
            viewModel.stopReading()
        }
    }
}

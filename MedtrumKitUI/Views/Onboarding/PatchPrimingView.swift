import LoopKitUI
import SwiftUI

struct PatchPrimingView: View {
    @ObservedObject var viewModel: PatchPrimingViewModel

    @State private var showingSteps = false

    var body: some View {
        VStack(spacing: 0) {
            PatchOverviewContent(assetName: "step_fill_patch") {
                Text("Fill and Prime the Patch", comment: "Title of the patch priming screen")
                    .font(.title2)
                    .fontWeight(.semibold)

                PatchKeyPoints(notes: [
                    PatchInstructionSteps.minimumFillNote,
                    PatchInstructionSteps.notOnBodyNote
                ])

                Text(
                    "Connect your pump base to a new patch and fill the patch with insulin. Then press the needle button and start priming.",
                    comment: "Patch priming screen: overview of the steps"
                )
                .fixedSize(horizontal: false, vertical: true)

                Button(action: { showingSteps = true }) {
                    Label(
                        String(
                            localized: "How to Fill and Prime the Patch",
                            comment: "Title of the step-by-step priming guide, and of the button opening it"
                        ),
                        systemImage: "questionmark.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: 12) {
                statusSection

                if viewModel.isPriming {
                    ProgressView(progress: viewModel.primeProgress)
                }

                Button(action: { viewModel.startPrime() }) {
                    if viewModel.isPriming {
                        ActivityIndicator()
                    } else {
                        Text("Start priming", comment: "label for prime start action")
                    }
                }
                .disabled(!viewModel.canStartPriming)
                .buttonStyle(ActionButtonStyle())
            }
            .padding()
        }
        .onAppear { viewModel.connect() }
        .sheet(isPresented: $showingSteps) {
            PatchStepsPagerView(
                title: String(
                    localized: "How to Fill and Prime the Patch",
                    comment: "Title of the step-by-step priming guide, and of the button opening it"
                ),
                steps: PatchInstructionSteps.priming,
                didFinish: { showingSteps = false }
            )
        }
    }

    @ViewBuilder private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.status.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(viewModel.status.isFailure ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if !viewModel.isPriming, let reservoirLevel = viewModel.reservoirLevel {
                    Text(
                        String(
                            format: String(
                                localized: "Reservoir: %@ U",
                                comment: "Reservoir level on the priming screen"
                            ),
                            viewModel.reservoirText(for: reservoirLevel)
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if viewModel.status.showsRetry {
                    Button(action: { viewModel.connect() }) {
                        Text("Retry", comment: "label for retrying the connection to the pump base")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let detail = viewModel.status.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

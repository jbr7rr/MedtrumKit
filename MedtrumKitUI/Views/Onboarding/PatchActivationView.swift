import LoopKitUI
import SwiftUI

struct PatchActivationView: View {
    @Environment(\.dismissAction) private var dismiss
    @ObservedObject var viewModel: PatchActivationViewModel

    @State private var showingSteps = false

    var body: some View {
        VStack(spacing: 0) {
            PatchOverviewContent(assetName: "step_insert_needle") {
                Text("Attach and Activate the Patch", comment: "Title of the patch activation screen")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(
                    "Priming is complete. Remove the safety lock, attach the patch to your body and press the needle button to insert the needle. Then activate the patch.",
                    comment: "Patch activation screen: overview of the steps"
                )
                .fixedSize(horizontal: false, vertical: true)

                Button(action: { showingSteps = true }) {
                    Label(
                        String(
                            localized: "How to Attach the Patch",
                            comment: "Title of the step-by-step activation guide, and of the button opening it"
                        ),
                        systemImage: "questionmark.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: 12) {
                if !viewModel.activationError.isEmpty {
                    Text(viewModel.activationError)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: { viewModel.activate() }) {
                    if viewModel.isActivating {
                        ActivityIndicator()
                    } else {
                        Text("Activate Patch", comment: "label for activate patch")
                    }
                }
                .disabled(viewModel.isActivating)
                .buttonStyle(ActionButtonStyle())
            }
            .padding()
        }
        .sheet(isPresented: $showingSteps) {
            PatchStepsPagerView(
                title: String(
                    localized: "How to Attach the Patch",
                    comment: "Title of the step-by-step activation guide, and of the button opening it"
                ),
                steps: PatchInstructionSteps.activation,
                didFinish: { showingSteps = false }
            )
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(String(localized: "Cancel", comment: "Cancel button title"), action: {
                    self.dismiss()
                })
            }
        }
    }
}

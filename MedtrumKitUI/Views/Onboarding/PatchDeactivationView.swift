import LoopKitUI
import SwiftUI

struct PatchDeactivationView: View {
    @ObservedObject var viewModel: DeactivatePatchViewModel

    @State var showingConfirmationPrompt = false
    @State private var showingSteps = false

    var body: some View {
        VStack {
            List {
                Section {
                    PumpImage(is300u: viewModel.is300u)
                    Text(
                        "When clicking on the button, you will get a Biometrics prompt. Once completed, the patch will be deactivated and you will be prompted to pair a new patch.",
                        comment: "Instructions for deactivate patch"
                    )
                }

                Section {
                    Button(action: { showingSteps = true }) {
                        Label(
                            String(
                                localized: "How to Remove the Patch",
                                comment: "Title of the step-by-step patch removal guide, and of the button opening it"
                            ),
                            systemImage: "questionmark.circle.fill"
                        )
                    }
                }
            }
            Spacer()

            if !viewModel.deactivationError.isEmpty {
                Text(viewModel.deactivationError)
                    .foregroundStyle(.red)
            } else if viewModel.disableButtons {
                Text("Cannot deactivate while a bolus is in progress", comment: "Wait for bolus to complete")
                    .foregroundStyle(.red)
            }

            Button(action: { showingConfirmationPrompt = true }) {
                Text("Force remove", comment: "Force remove")
            }
            .buttonStyle(ActionButtonStyle(.secondary))
            .disabled(viewModel.isDeactivating)
            .padding([.bottom, .horizontal])

            Button(action: { viewModel.deactivate() }) {
                if viewModel.isDeactivating {
                    ActivityIndicator()
                } else {
                    Text("Authenticate & deactivate patch", comment: "Authenticate and deactivate label")
                }
            }
            .buttonStyle(ActionButtonStyle(.destructive))
            .disabled(viewModel.isDeactivating || viewModel.disableButtons)
            .padding([.bottom, .horizontal])
        }
        .alert(String(localized: "Are you sure?", comment: "title force remove"), isPresented: $showingConfirmationPrompt) {
            Button(String(localized: "Confirm", comment: "confirm force remove"), role: .destructive) {
                viewModel.forceDeactivate()
            }
        } message: {
            Text("It is recommended to deactivate first", comment: "body force remove")
        }
        .sheet(isPresented: $showingSteps) {
            PatchStepsPagerView(
                title: String(
                    localized: "How to Remove the Patch",
                    comment: "Title of the step-by-step patch removal guide, and of the button opening it"
                ),
                steps: PatchInstructionSteps.removal,
                didFinish: { showingSteps = false }
            )
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
    }
}

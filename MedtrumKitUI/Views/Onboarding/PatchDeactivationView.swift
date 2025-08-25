import LoopKitUI
import SwiftUI

struct PatchDeactivationView: View {
    @ObservedObject var viewModel: DeactivatePatchViewModel
    
    @State var showingConfirmationPrompt = false

    var body: some View {
        VStack {
            List {
                Section {
                    PumpImage(is300u: viewModel.is300u)
                    Text(LocalizedString(
                        "When clicking on the button, you will get a Biometrics prompt. Once completed, the patch will be deactivated and you will be prompted to pair a new patch.",
                        comment: "Instructions for deactivate patch"
                    ))
                }
            }
            Spacer()

            Text(viewModel.deactivationError)
                .foregroundStyle(.red)

            Button(action: { showingConfirmationPrompt = true }) {
                Text(LocalizedString("Force remove", comment: "Force remove"))
            }
            .buttonStyle(ActionButtonStyle(.secondary))
            .disabled(viewModel.isDeactivating)
            .padding([.bottom, .horizontal])
            
            Button(action: { viewModel.deactivate() }) {
                if viewModel.isDeactivating {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                } else {
                    Text(LocalizedString("Authenticate & deactivate patch", comment: "Authenticate and deactivate label"))
                }
            }
            .buttonStyle(ActionButtonStyle(.destructive))
            .disabled(viewModel.isDeactivating)
            .padding([.bottom, .horizontal])
        }
        .alert(LocalizedString("Are you sure?", comment: "title force remove"), isPresented: $showingConfirmationPrompt) {
            Button(LocalizedString("Confirm", comment: "confirm force remove"), role: .destructive) { viewModel.forceDeactivate() }
        } message: {
            Text(LocalizedString("It is recommended to deactivate first", comment: "body force remove"))
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .navigationTitle(LocalizedString("Deactivate patch", comment: "deactive patch"))
    }
}

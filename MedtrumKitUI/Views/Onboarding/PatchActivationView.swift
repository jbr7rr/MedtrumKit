import LoopKitUI
import SwiftUI

struct PatchActivationView: View {
    @Environment(\.dismissAction) private var dismiss
    @ObservedObject var viewModel: PatchActivationViewModel

    var body: some View {
        VStack {
            List {
                Section {
                    supportImage("remove_cover")
                    HStack(alignment: .top) {
                        Text("6.")
                            .foregroundStyle(.primary)
                        Text(
                            "Remove the safety cover from the patch.",
                            comment: "Label for inserting needle step 1"
                        )
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section {
                    supportImage("attach_body")
                    HStack(alignment: .top) {
                        Text("7.")
                            .foregroundStyle(.primary)
                        Text("Attach the pump to the body.", comment: "Label for inserting needle step 2")
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section {
                    supportImage("needle_insert")
                    HStack(alignment: .top) {
                        Text("8.")
                            .foregroundStyle(.primary)
                        Text(
                            "Press the needle button to insert the needle. Click on \"Activate\" to complete the activation process.",
                            comment: "Label for inserting needle step 3"
                        )
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer()
            if !viewModel.activationError.isEmpty {
                Text(viewModel.activationError)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
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
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(String(localized: "Cancel", comment: "Cancel button title"), action: {
                    self.dismiss()
                })
            }
        }
    }

    @ViewBuilder func supportImage(_ imageName: String) -> some View {
        HStack {
            Spacer()
            Image(uiImage: UIImage(named: imageName, in: Bundle(for: MedtrumKitHUDProvider.self), compatibleWith: nil)!)
                .resizable()
                .scaledToFit()
                .padding(.horizontal)
                .frame(height: 100)
            Spacer()
        }
    }
}

import LoopKitUI
import SwiftUI

struct PatchPrimingView: View {
    @ObservedObject var viewModel: PatchPrimingViewModel

    var body: some View {
        VStack {
            List {
                Section {
                    supportImage("connect_base")
                    HStack(alignment: .top) {
                        Text("1.")
                            .foregroundStyle(.primary)
                        Text("Connect your pump base to the patch.", comment: "Label for prime step 2.1")
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section {
                    supportImage("fill_reservoir")
                    VStack(alignment: .leading) {
                        HStack(alignment: .top) {
                            Text("2.")
                                .foregroundStyle(.primary)
                            Text("Fill the syringe with insulin", comment: "Label for prime step 2.2")
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(alignment: .top) {
                            Text("3.")
                                .foregroundStyle(.primary)
                            Text(
                                "Place the syringe in the patch and pull out 1 to 2 dashes of air.",
                                comment: "Label for prime step 2.3"
                            )
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(alignment: .top) {
                            Text("4.")
                                .foregroundStyle(.primary)
                            Text(
                                "Fill the patch with insulin. NOTE: A minimum of 70U is required for activation.",
                                comment: "Label for prime step 2.4"
                            )
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Section {
                    supportImage("half_press_needle_button")
                    HStack(alignment: .top) {
                        Text("5.")
                            .foregroundStyle(.primary)
                        Text(
                            "Press the needle button and start the priming process.",
                            comment: "Label for pressing needle button step 2.5"
                        )
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer()

            statusSection

            if !viewModel.isPriming {
                Text("Do not attach the patch to the body yet", comment: "Label for warning priming")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
            } else {
                ProgressView(progress: viewModel.primeProgress)
                    .padding(.horizontal)
            }

            Button(action: { viewModel.previousStep() }) {
                Text("Go back to pump base", comment: "label for go to pump base patch")
            }
            .buttonStyle(ActionButtonStyle(.secondary))
            .disabled(viewModel.isPriming)
            .padding(.horizontal)

            Button(action: { viewModel.startPrime() }) {
                if viewModel.isPriming {
                    ActivityIndicator()
                } else {
                    Text("Start priming", comment: "label for prime start action")
                }
            }
            .disabled(!viewModel.canStartPriming)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .onAppear { viewModel.connect() }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .navigationBarBackButtonHidden(viewModel.isPriming)
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
        .padding(.horizontal)
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

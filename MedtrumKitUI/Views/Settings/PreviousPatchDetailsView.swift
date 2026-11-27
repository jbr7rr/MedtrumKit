import SwiftUI

struct PreviousPatchDetailsView: View {
    @ObservedObject var viewModel: PreviousPatchDetailsViewModel

    var body: some View {
        List {
            Section {
                sectionItem(
                    title: Text("Patch ID", comment: "Text for pumpSN"),
                    value: viewModel.patchId
                )
                sectionItem(
                    title: Text("Patch State", comment: "Text for patch state"),
                    value: viewModel.patchStateString
                )
                sectionItem(
                    title: Text("Activation", comment: "Text for activatedAt"),
                    value: viewModel.activatedAt
                )
                sectionItem(
                    title: Text("Deactivation", comment: "Text for deactivation"),
                    value: viewModel.deactivatedAt
                )
                sectionItem(
                    title: Text("Cannula Age", comment: "Text for cannula age (CAGE)"),
                    value: viewModel.patchLifetime
                )
                sectionItem(
                    title: Text("Battery", comment: "Text for battery voltageB"),
                    value: viewModel.batteryText(for: viewModel.battery)
                )

                if let reservoirLevel = viewModel.reservoirLevel,
                   let initialReservoirLevel = viewModel.initialReservoirLevel
                {
                    sectionItem(
                        title: Text("Insulin Used", comment: "Text for Insulin used"),
                        value: viewModel.reservoirText(for: initialReservoirLevel - reservoirLevel)
                    )
                } else {
                    sectionItem(
                        title: Text("Insulin Used", comment: "Text for Insulin used"),
                        value: "0 U"
                    )
                }
            }

            if viewModel.historyPatch != nil {
                Section {
                    HStack {
                        Text("History", comment: "previous patch details: the row opening the patch's record history")
                            .foregroundColor(Color.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: UIFont.systemFontSize, weight: .medium))
                            .opacity(0.3)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.toHistory()
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }

    @ViewBuilder func sectionItem(title: Text, value: String) -> some View {
        HStack {
            title
                .foregroundColor(Color.primary)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

import SwiftUI

struct PreviousPatchDetailsView: View {
    @ObservedObject var viewModel: PreviousPatchDetailsViewModel

    var body: some View {
        List {
            Section {
                sectionItem(
                    title: LocalizedString("Patch ID", comment: "Text for pumpSN"),
                    value: viewModel.patchId
                )
                sectionItem(
                    title: LocalizedString("Patch state", comment: "Text for patch state"),
                    value: viewModel.patchStateString
                )
                sectionItem(
                    title: LocalizedString("Activation", comment: "Text for activatedAt"),
                    value: viewModel.activatedAt
                )
                sectionItem(
                    title: LocalizedString("Deactivation", comment: "Text for deactivation"),
                    value: viewModel.deactivatedAt
                )
                sectionItem(
                    title: LocalizedString("Cannula Age", comment: "Text for cannula age (CAGE)"),
                    value: viewModel.patchLifetime
                )
                sectionItem(
                    title: LocalizedString("Battery", comment: "Text for battery voltageB"),
                    value: viewModel.batteryText(for: viewModel.battery)
                )

                if let reservoirLevel = viewModel.reservoirLevel,
                   let initialReservoirLevel = viewModel.initialReservoirLevel
                {
                    sectionItem(
                        title: LocalizedString("Insulin used", comment: "Text for Insulin used"),
                        value: viewModel.reservoirText(for: initialReservoirLevel - reservoirLevel)
                    )
                } else {
                    sectionItem(
                        title: LocalizedString("Insulin used", comment: "Text for Insulin used"),
                        value: "0 U"
                    )
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarTitle(LocalizedString("Previous Patch Details", comment: "header patch details"))
    }

    @ViewBuilder func sectionItem(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(Color.primary)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

import SwiftUI

struct PatchDetailsView: View {
    @ObservedObject var viewModel: PatchDetailsViewModel

    var body: some View {
        List {
            Section {
                sectionItem(
                    title: LocalizedString("Patch state", comment: "Text for patch state"),
                    value: viewModel.patchStateString
                )
                sectionItem(
                    title: LocalizedString("Pump base SN", comment: "Text for pumpSN"),
                    value: viewModel.pumpBaseSN
                )
                sectionItem(
                    title: LocalizedString("Pump base Firmware", comment: "Text for firmware version"),
                    value: viewModel.swVersion
                )
                sectionItem(
                    title: LocalizedString("Pump base model", comment: "Text for model"),
                    value: viewModel.model
                )
                sectionItem(
                    title: LocalizedString("Patch ID", comment: "Text for pumpSN"),
                    value: viewModel.patchId
                )
                sectionItem(
                    title: LocalizedString("Battery", comment: "Text for battery voltageB"),
                    value: viewModel.batteryText(for: viewModel.battery)
                )
                sectionItem(
                    title: LocalizedString("Activation", comment: "Text for activatedAt"),
                    value: viewModel.activatedAt
                )
                sectionItem(
                    title: LocalizedString("Elapsed time", comment: "Text for elapsed patch lifetime"),
                    value: viewModel.patchLifetime
                )

                if let initialReservoirLevel = viewModel.initialReservoirLevel {
                    sectionItem(
                        title: LocalizedString("Insulin used", comment: "Text for Insulin used"),
                        value: viewModel.reservoirText(for: initialReservoirLevel - viewModel.reservoirLevel)
                    )
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarTitle(LocalizedString("Patch Details", comment: "header patch details"))
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

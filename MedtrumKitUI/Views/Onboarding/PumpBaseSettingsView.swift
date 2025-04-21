//
//  PumpBaseSettingsView.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 05/04/2025.
//

import SwiftUI
import LoopKitUI

struct PumpBaseSettingsView: View {
    @ObservedObject var viewModel: PumpBaseSettingsViewModel
    
    var body: some View {
        VStack {
            List {
                Section {
                    PumpImage(is300u: viewModel.is300u)
                    VStack(alignment: .leading) {
                        HStack {
                            Text(LocalizedString("Serial number", comment: "Label for serial number"))
                                .foregroundStyle(.primary)
                            Spacer()
                            TextField("1234ABCD", text: $viewModel.serialNumber)
                                .multilineTextAlignment(.trailing)
                        }
                        Text(LocalizedString("Make sure the Serial Number is correct before connecting it to the patch. After checking, connect the pump base to the patch and press the button", comment: "Label for checking SN"))
                            .padding(.top, 10)
                            .foregroundStyle(.primary)
                    }
                }
            }
            Spacer()
            if !viewModel.errorMessage.isEmpty {
                Text(viewModel.errorMessage)
                    .foregroundStyle(.red)
            }
            Button(action: { viewModel.saveAndConnect() }) {
                Text(LocalizedString("Save and continue", comment: "save and continue"))
            }
            .disabled(viewModel.serialNumber.count != 8)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .navigationTitle(LocalizedString("Pump base settings", comment: "Pump base settings"))
    }
}


//
//  PatchDeactivationView.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 04/04/2025.
//

import SwiftUI
import LoopKitUI

struct PatchDeactivationView: View {
    @ObservedObject var viewModel: DeactivatePatchViewModel
    
    var body: some View {
        VStack {
            List {
                Section {
                    PumpImage(is300u: viewModel.is300u)
                    Text(LocalizedString("When clicking on the button, you will get a Biometrics prompt. Once completed, the patch will be deactivated and you will be prompted to pair a new patch.", comment: "Instructions for deactivate pod when pod not on body"))
                }
            }
            Spacer()
            
            Text(viewModel.deactivationError)
                .foregroundStyle(.red)
            
            Button(action: { viewModel.deactivate() }) {
                if viewModel.isDeactivating {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                } else {
                    Text(LocalizedString("Authenticate & deactivate patch", comment: "deactive patch"))
                }
            }
            .buttonStyle(ActionButtonStyle(.destructive))
            .disabled(viewModel.isDeactivating)
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .navigationTitle(LocalizedString("Deactivate patch", comment: "deactive patch"))
    }
}

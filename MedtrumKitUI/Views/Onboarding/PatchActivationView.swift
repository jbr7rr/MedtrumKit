//
//  PatchActivationView.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 05/04/2025.
//

import SwiftUI
import LoopKitUI

struct PatchActivationView: View {
    @ObservedObject var viewModel: PatchActivationViewModel
    
    var body: some View {
        VStack {
            List {
                Section {
                    supportImage("needle_insert")
                    VStack(alignment: .leading) {
                        Text(LocalizedString("Now, remove the sticker covers from the patch, place the patch on your body, and press the needle button to insert the needle", comment: "Label for inserting needle to body"))
                            .foregroundStyle(.primary)
                        
                        Text(LocalizedString("Click on Activate patch to complete the activation process.", comment: "Label for completing activation"))
                            .foregroundStyle(.primary)
                            .padding(.top, 5)
                    }
                }
            }
            Spacer()
            if !viewModel.activationError.isEmpty {
                Text(viewModel.activationError)
                    .foregroundStyle(.red)
            }
            Button(action: { viewModel.activate() }) {
                if viewModel.isActivating {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                } else {
                    Text(LocalizedString("Activate patch", comment: "label for activate start action"))
                }
            }
            .disabled(viewModel.isActivating)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .navigationTitle(LocalizedString("Patch activation", comment: "Pump base settings"))
    }
    
    @ViewBuilder
    func supportImage(_ imageName: String) -> some View {
        HStack {
            Spacer()
            Image(uiImage: UIImage(named: imageName, in: Bundle(for: MedtrumKitHUDProvider.self), compatibleWith: nil)!)
                .resizable()
                .scaledToFit()
                .padding(.horizontal)
                .frame(height: 120)
            Spacer()
        }
    }
}

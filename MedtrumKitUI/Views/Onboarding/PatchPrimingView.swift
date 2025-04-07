//
//  PatchPrimingView.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 05/04/2025.
//

import SwiftUI
import LoopKitUI

struct PatchPrimingView: View {
    @ObservedObject var viewModel: PatchPrimingViewModel
    
    var body: some View {
        VStack {
            List {
                Section {
                    supportImage("fill_reservoir")
                    VStack(alignment: .leading) {
                        Text(LocalizedString("Connect your pump base to the patch, remove the residual air, and fill with insulin.", comment: "Label for prime steps"))
                            .foregroundStyle(.primary)
                        Text(LocalizedString("NOTE: A minimum of 70U is required for activation", comment: "Label for minimum requirements"))
                            .foregroundStyle(.primary)
                            .padding(.top, 5)
                    }
                }
                
                Section {
                    supportImage("half_press_needle_button")
                    Text(LocalizedString("After filling, half-press the needle button, remove the cover, and start the priming process", comment: "Label for pressing needle button"))
                        .foregroundStyle(.primary)
                }
            }
            Spacer()
            if !viewModel.primingError.isEmpty {
                Text(viewModel.primingError)
                    .foregroundStyle(.red)
            } else if !viewModel.isPriming {
                Text(LocalizedString("Do not attach the patch to the body yet", comment: "Label for warning priming"))
                    .foregroundStyle(.red)
            } else {
                ProgressView(progress: viewModel.primeProgress)
                    .padding(.horizontal)
            }
            Button(action: { viewModel.startPrime() }) {
                if viewModel.isPriming {
                    ActivityIndicator(isAnimating: .constant(true), style: .medium)
                } else {
                    Text(LocalizedString("Start priming", comment: "label for prime start action"))
                }
            }
            .disabled(viewModel.isPriming)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .navigationTitle(LocalizedString("Patch priming", comment: "Pump base settings"))
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

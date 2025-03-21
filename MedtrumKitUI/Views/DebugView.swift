//
//  DebugView.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 13/03/2025.
//

import SwiftUI

struct DebugView: View {
    @ObservedObject var viewModel: DebugViewModel
    @State private var isSharePresented: Bool = false
    
    var body: some View {
        VStack {
            HStack {
                Button("Set pump base SN", action: viewModel.setPumpBase)
                    .frame(width: 100, height: 100)
                
                Button("Prime", action: viewModel.prime)
                    .disabled(!viewModel.hasPumpBaseSN)
                    .frame(width: 100, height: 100)
            }
            
            HStack {
                Button("Activate", action: viewModel.activate)
                    .disabled(!viewModel.hasPumpBaseSN)
                    .frame(width: 100, height: 100)
                
                Button("Connect", action: viewModel.connect)
                    .disabled(!viewModel.hasPumpBaseSN)
                    .frame(width: 100, height: 100)
            }
            
            HStack {
                Button(LocalizedString("Share logs", comment: "Share logs")) {
                    self.isSharePresented = true
                }
                .sheet(isPresented: $isSharePresented, onDismiss: { }, content: {
                    ActivityViewController(activityItems: viewModel.getLogs())
                })
            }
        }
        .alert("Set pump base SN", isPresented: $viewModel.isPresentingPumpBaseSN) {
            TextField(text: $viewModel.pumpBaseSN) {}
            Button("Submit") {
                viewModel.setPumpBaseAction()
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

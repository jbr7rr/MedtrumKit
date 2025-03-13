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
                Button("Scan", action: viewModel.scan)
                    .frame(width: 100, height: 100)

                Button("Connect", action: viewModel.connect)
                    .disabled(viewModel.foundPeripheral == nil)
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
        .alert("Device found!",
               isPresented: $viewModel.isPresentingScanAlert,
               presenting: viewModel.messageScanAlert,
               actions: { detail in
                Button("No", action: {})
                Button("Yes", action: viewModel.connect)
               },
               message: { detail in Text(detail) }
        )
    }
}

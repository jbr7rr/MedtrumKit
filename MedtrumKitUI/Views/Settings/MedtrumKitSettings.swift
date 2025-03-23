//
//  MedtrumKitSettings.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 23/03/2025.
//

import SwiftUI

struct MedtrumKitSettings: View {
    @ObservedObject var viewModel: MedtrumKitSettingsViewModel
    
    var body: some View {
        List {
            Section() {
                HStack(){
                    Spacer()
                    Image(uiImage: UIImage(named: viewModel.imageName, in: Bundle(for: MedtrumKitHUDProvider.self), compatibleWith: nil)!)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal)
                        .frame(height: 200)
                    Spacer()
                }
                
                HStack(alignment: .top) {
//                    deliveryStatus
                    Spacer()
                    reservoirStatus
                }
                .padding(.bottom, 5)
                
//                if viewModel.showPumpTimeSyncWarning {
//                    VStack(alignment: .leading, spacing: 4) {
//                        Text(LocalizedString("Time Change Detected", comment: "title for time change detected notice"))
//                            .font(Font.subheadline.weight(.bold))
//                        Text(LocalizedString("The time on your pump is different from the current time. Your pump’s time controls your scheduled therapy settings. Scroll down to Pump Time row to review the time difference and configure your pump.", comment: "description for time change detected notice"))
//                            .font(Font.footnote.weight(.semibold))
//                    }.padding(.vertical, 8)
//                }
            }
        }
    }
    
    var reservoirStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedString("Insulin Remaining", comment: "Header for insulin remaining on pod settings screen"))
                .foregroundColor(Color(UIColor.secondaryLabel))
            if let reservoirLevel = viewModel.reservoirLevel {
                HStack {
                    ReservoirView(reservoirLevel: reservoirLevel, fillColor: reservoirColor(reservoirLevel))
                        .frame(width: 23, height: 32)
                    Text(viewModel.reservoirText(for: reservoirLevel))
                        .font(.system(size: 28))
                        .fontWeight(.heavy)
                        .fixedSize()
                }
            }
        }
    }
}

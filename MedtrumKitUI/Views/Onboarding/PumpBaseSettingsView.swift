import AVFoundation
import LoopKitUI
import SwiftUI

struct PumpBaseSettingsView: View {
    @State private var isShowingDeleteConfirmation: Bool = false
    @ObservedObject var viewModel: PumpBaseSettingsViewModel

    @Environment(\.guidanceColors) private var guidanceColors

    @State private var showingScanner = false
    @State private var showingCameraDenied = false
    @State private var showingCameraBusy = false

    var body: some View {
        VStack {
            List {
                Section {
                    PumpBaseSerialFigure()
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Serial number", comment: "Label for serial number")
                                .foregroundStyle(.primary)
                            Spacer()
                            TextField("1234ABCD", text: $viewModel.serialNumber.max(8))
                                .multilineTextAlignment(.trailing)
                            if MedtrumSerialScannerView.isSupported {
                                Button(action: scanTapped) {
                                    Image(systemName: "qrcode.viewfinder")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Scan Serial Number", comment: "Accessibility label for the serial number scan button"))
                            }
                        }
                        Text(
                            "Make sure the Serial Number is correct before connecting it to the patch.",
                            comment: "Label for checking SN"
                        )
                        .padding(.top, 10)
                        .foregroundStyle(.primary)

                        Text("Find it on the back of the pump base, or on the product box.", comment: "Caption for where to find the serial number")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                    }
                }
            }
            Spacer()
            if !viewModel.errorMessage.isEmpty {
                Text(viewModel.errorMessage)
                    .foregroundStyle(.red)
            }

            Button(action: { viewModel.saveAndContinue() }) {
                Text("Save and continue", comment: "save and continue")
            }
            .disabled(viewModel.serialNumber.count != 8)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .sheet(isPresented: $showingScanner) {
            NavigationView {
                MedtrumSerialScannerView { serial in
                    showingScanner = false
                    viewModel.serialNumber = serial
                }
                .navigationBarTitle(Text("Scan Serial Number", comment: "Navigation title of the pump base serial scanner"), displayMode: .inline)
                .navigationBarItems(trailing: Button(String(localized: "Cancel", comment: "Cancel button title")) {
                    showingScanner = false
                })
            }
        }
        .alert(
            String(localized: "Camera Access Is Off", comment: "Title of the alert shown when camera permission is denied"),
            isPresented: $showingCameraDenied
        ) {
            Button(String(localized: "Open Settings", comment: "Button title to open the iOS Settings app")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(String(localized: "Cancel", comment: "Cancel button title"), role: .cancel) {}
        } message: {
            Text("Allow camera access in Settings to scan the serial number, or type it in instead.", comment: "Message of the alert shown when camera permission is denied")
        }
        .alert(
            String(localized: "Camera Is Busy", comment: "Title of the alert shown when the camera cannot start scanning right now"),
            isPresented: $showingCameraBusy
        ) {} message: {
            Text("Another app is using the camera, or the phone needs a moment. Try again shortly, or type the serial number in instead.", comment: "Message of the alert shown when the camera cannot start scanning right now")
        }
    }

    private func scanTapped() {
        #if targetEnvironment(simulator)
        viewModel.serialNumber = MedtrumSerialScannerView.simulatedSerial
        return
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        presentScanner()
                    } else {
                        showingCameraDenied = true
                    }
                }
            }
        default:
            showingCameraDenied = true
        }
        #endif
    }

    private func presentScanner() {
        if MedtrumSerialScannerView.isAvailable {
            showingScanner = true
        } else {
            showingCameraBusy = true
        }
    }
}

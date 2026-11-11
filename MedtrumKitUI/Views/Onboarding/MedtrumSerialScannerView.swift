import SwiftUI
import VisionKit

enum MedtrumSerialCode {
    static func serial(fromPayload payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 8, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed.uppercased()
    }
}

struct MedtrumSerialScannerView: UIViewControllerRepresentable {
    var didScan: (_ serial: String) -> Void

    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        // No camera in the simulator, so the scan path could not be walked at
        // all. Offer it and answer with a stand-in serial instead.
        return true
        #else
        return DataScannerViewController.isSupported
            && Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
        #endif
    }

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return isSupported && DataScannerViewController.isAvailable
        #endif
    }

    #if targetEnvironment(simulator)
    static let simulatedSerial = "1234ABCD"
    #endif

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(didScan: didScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let didScan: (String) -> Void
        private var handled = false

        init(didScan: @escaping (String) -> Void) {
            self.didScan = didScan
        }

        /// Only an 8-character hex code is accepted; anything else in view is
        /// ignored and the scanner keeps looking.
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      let serial = MedtrumSerialCode.serial(fromPayload: payload)
                else { continue }
                handled = true
                scanner.stopScanning()
                didScan(serial)
                return
            }
        }
    }
}

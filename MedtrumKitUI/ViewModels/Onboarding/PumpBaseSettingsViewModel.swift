class PumpBaseSettingsViewModel: ObservableObject {
    @Published var isOnboarded = false
    @Published var serialNumber: String = ""
    @Published var errorMessage: String = ""

    private let logger = MedtrumLogger(category: "PumpBaseSettingsViewModel")
    private let pumpManager: MedtrumPumpManager?
    private let nextStep: () -> Void
    init(
        _ pumpManager: MedtrumPumpManager?,
        _ nextStep: @escaping () -> Void
    ) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep

        guard let pumpManager = pumpManager else {
            return
        }

        isOnboarded = pumpManager.state.isOnboarded
        serialNumber = pumpManager.state.pumpSN.hexEncodedString().uppercased()
    }

    func saveAndContinue() {
        guard serialNumber.count == 8 else {
            logger.error("Serial Number is too short: \(serialNumber)")
            errorMessage = "Serial Number is too short"
            return
        }

        guard let snData = Data(hex: serialNumber), snData.count == 4 else {
            logger.error("Serial Number is invalid hex format: \(serialNumber)")
            errorMessage = "Serial Number is invalid hex format"
            return
        }

        guard let pumpManager = pumpManager else {
            logger.error("No pump manager available")
            errorMessage = "No pump manager available"
            return
        }

        if pumpManager.state.pumpSN.hexEncodedString().uppercased() != serialNumber.uppercased() {
            logger.info("Serial number change detected -> Removing references to old pump base...")
            pumpManager.bluetooth.clearPeripheral()
        }

        pumpManager.state.pumpSN = snData
        guard pumpManager.state.model != "INVALID" else {
            errorMessage = "Incorrect serial number received"
            return
        }

        errorMessage = ""

        pumpManager.state.isOnboarded = true
        pumpManager.notifyStateDidChange()
        nextStep()
    }
}

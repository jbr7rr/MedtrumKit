import LoopKit

class ManualTempBasalViewModel: ObservableObject {
    @Published var selectedRate = 0.05
    @Published var selectedDuration = TimeInterval.minutes(30)
    @Published var enacting: Bool = false
    @Published var enactingBolus: Bool = false
    @Published var error: String? = nil

    public let allowedRates: [Double] = MedtrumPumpManager.onboardingSupportedBasalRates.filter { $0 > 0 && $0 < 10 }
    public let allowedDurations: [Double] = (1 ... 24).map { Double($0) * TimeInterval.minutes(30) }

    func rateFormatter(for basal: Double) -> String {
        let stepped = (basal / 0.05).rounded() * 0.05
        return String(format: "%.2f", stepped) + " " + String(localized: "U/hr", comment: "Units for showing temp basal rate")
    }

    func durationFormatter(for duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return String(
                format: String(localized: "%lld hr %lld min", comment: "temp basal remaining hours+minutes"),
                hours, minutes
            )
        }

        return String(
            format: String(localized: "%lld min", comment: "temp basal remaining minutes"),
            minutes
        )
    }

    private let pumpManager: MedtrumPumpManager?
    private let goBack: () -> Void
    init(pumpManager: MedtrumPumpManager?, goBack: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.goBack = goBack

        if let pumpManager {
            selectedRate = pumpManager.state.currentBaseBasalRate
            enactingBolus = pumpManager.state.bolusDose != nil

            pumpManager.addStatusObserver(self, queue: DispatchQueue.main)
        }
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func enact() {
        guard let pumpManager else {
            return
        }

        enacting = true
        pumpManager.syncPumpData { _ in
            pumpManager.enactTempBasal(
                unitsPerHour: self.selectedRate,
                duration: self.selectedDuration,
                automatic: false
            ) { error in
                DispatchQueue.main.async {
                    self.enacting = false

                    if let error {
                        self.error = error.localizedDescription
                    } else {
                        self.goBack()
                    }
                }
            }
        }
    }
}

extension ManualTempBasalViewModel: PumpManagerStatusObserver {
    func pumpManager(_: any LoopKit.PumpManager, didUpdate _: LoopKit.PumpManagerStatus, oldStatus _: LoopKit.PumpManagerStatus) {
        DispatchQueue.main.async {
            self.enactingBolus = self.pumpManager?.state.bolusDose != nil
        }
    }
}

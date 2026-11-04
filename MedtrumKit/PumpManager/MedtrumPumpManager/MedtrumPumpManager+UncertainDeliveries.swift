import Foundation

public extension MedtrumPumpManager {
    /// The settings screen keeps this many of them, the oldest settled going first
    static let uncertainDeliveriesKept = 20

    /// `dose` became uncertain, as `kind` - for the settings screen, see `UncertainDelivery`. Once per dose and kind: the
    /// first cause stays. A cancel's note noted again is for a later cancel: its `cancelDidNotStop` is cleared, that
    /// cancel's own still to be shown. Only under `doseReportLock`.
    internal func noteUncertainDelivery(_ kind: UncertainDelivery.Kind, _ cause: UncertainDelivery.Cause, of dose: UnfinalizedDose) {
        // Final, nothing would settle it
        guard !dose.isFinalized else {
            return
        }

        let key = UncertainDelivery.DoseKey(dose)
        let delivery = UncertainDelivery(
            kind: kind,
            cause: cause,
            sentAt: key.sentAt,
            amount: dose.value,
            duration: dose.type == .tempBasal ? dose.estimatedEndDate.timeIntervalSince(dose.startDate) : nil,
            notedAt: now()
        )
        state.mutateUncertainDeliveries { deliveries in
            if let index = deliveries.firstIndex(where: { $0.kind == kind && $0.isOf(key) && !$0.isSettled }) {
                // Another cancel of it unanswered: whether this one stopped it is not known - a status showing it still
                // running marks it again (`noteCancelDidNotStop`), so the settled note tells of the last cancel
                if kind == .tempBasalCancel {
                    deliveries[index].cancelDidNotStop = false
                }
                return
            }
            deliveries.append(delivery)
            while deliveries.count > Self.uncertainDeliveriesKept {
                deliveries.remove(at: deliveries.firstIndex(where: \.isSettled) ?? 0)
            }
        }
    }

    /// The uncertain deliveries of `dose` not settled yet are, as `outcome` - with its final, if it has one. Only under
    /// `doseReportLock`.
    internal func settleUncertainDeliveries(of dose: UnfinalizedDose, _ outcome: UncertainDelivery.Outcome) {
        let key = UncertainDelivery.DoseKey(dose)
        let final = dose.snapshot
        let settledAt = now()
        state.mutateUncertainDeliveries { deliveries in
            for index in deliveries.indices where !deliveries[index].isSettled && deliveries[index].isOf(key) {
                deliveries[index].outcome = outcome
                deliveries[index].settledAt = settledAt
                switch outcome {
                case .byRecord, .byEstimate:
                    deliveries[index].delivered = final.finalDeliveredUnits
                    deliveries[index].record = outcome == .byRecord && dose.type == .bolus ? final.recordSequence : nil
                case .neverRan:
                    deliveries[index].delivered = 0
                case .notConfirmed, .final, .untracked, .notCounted:
                    break
                }
            }
        }
    }

    /// A status showed `dose` still running after its cancel went unanswered: its cancel's note keeps saying so once
    /// settled. Only under `doseReportLock`.
    internal func noteCancelDidNotStop(_ dose: UnfinalizedDose) {
        let key = UncertainDelivery.DoseKey(dose)
        state.mutateUncertainDeliveries { deliveries in
            for index in deliveries.indices
                where deliveries[index].kind == .tempBasalCancel && !deliveries[index].isSettled && deliveries[index].isOf(key)
            {
                deliveries[index].cancelDidNotStop = true
            }
        }
    }

    /// The user is done with the settled ones
    public func clearSettledUncertainDeliveries() {
        doseReportLock.withLock {
            state.mutateUncertainDeliveries { $0.removeAll(where: \.isSettled) }
        }
        notifyStateDidChange()
    }

    /// A cancel of the running temp basal went out at `sentAt` and no answer came back: the patch may have stopped it.
    /// It stays running and counted until a status says otherwise.
    internal func noteUnansweredCancel(sentAt: Date) {
        // Marked and noted together: a status finalizing it in between would leave the note unsettled
        let marked = doseReportLock.withLock { () -> Bool in
            guard state.basalDose.markStopUnanswered(at: sentAt) else {
                return false
            }
            noteUncertainDelivery(.tempBasalCancel, .unanswered, of: state.basalDose)
            return true
        }
        guard marked else {
            return
        }

        log.warning("The cancel of the temp basal of \(state.basalDose.startDate) went unanswered, it may have stopped")
        notifyStateDidChange()
    }
}

import Foundation

/// One connect attempt: the callers waiting on it, and the deadline that guarantees they hear
/// back. Connect, disconnect, timeout and the auth flow all race to report a result, so the
/// attempt owns which of them wins rather than each site checking for itself.
///
/// An attempt can carry more than one caller. A connect takes seconds to complete - auth,
/// synchronize and subscribe all have to run - and anything the loop or the user asks for in that
/// window joins the attempt in flight rather than being turned away.
///
/// The attempt outlives its deadline. `CBCentralManager.connect` has no timeout by design: to a
/// known peripheral it stays pending until the base is in range, and that is the only thing that
/// still works while the app is backgrounded, where scanning finds nothing. So a deadline answers
/// "how long is this caller willing to wait", not "is the connect dead" - see `deadlineIsTerminal`.
/// The attempt ends when something real ends it: didConnect, didFailToConnect, didDisconnect, or a
/// teardown that cancels the connect.
///
/// NOT thread safe, `BluetoothManager` MUST access its attempt from `managerQueue`.
final class ConnectAttempt {
    /// How long a caller is prepared to sit on an attempt whose connect is still pending.
    enum Patience {
        /// Reported back once its own budget is spent, even though the connect lives on. What every
        /// real caller wants: the loop and the UI need an answer in bounded time.
        case bounded
        /// Waits for whatever actually resolves the attempt. For internal bookkeeping and log lines,
        /// which have no deadline to miss - handing those a budget makes the log announce that a
        /// reconnect failed while its connect is still pending and about to succeed.
        case untilResolved
    }

    private struct Waiter {
        /// When this caller started waiting, or nil for `.untilResolved`.
        let deadlineFrom: Date?
        let completion: (MedtrumConnectError?) -> Void

        init(patience: Patience, completion: @escaping (MedtrumConnectError?) -> Void) {
            deadlineFrom = patience == .bounded ? .now : nil
            self.completion = completion
        }
    }

    private var waiters: [Waiter]
    var timeout: Task<Void, Never>?
    var timeoutGeneration = 0
    private var reported = false

    /// Once the link is up, a deadline means the session flow is wedged - auth, synchronize or
    /// subscribe - and there is nothing left to wait for, so it fails the whole attempt. While the
    /// connect is still pending the opposite holds: the deadline reports the callers waiting on it
    /// and the attempt lives on, because the connect is untouched and may still land.
    var deadlineIsTerminal = false

    init(_ completion: @escaping (MedtrumConnectError?) -> Void, patience: Patience = .bounded) {
        waiters = [Waiter(patience: patience, completion: completion)]
    }

    /// Adds a caller to an attempt that is still in flight, so it gets the same result as everyone
    /// else on it. Only valid before the attempt is reported: `BluetoothManager.finish` claims and
    /// clears the attempt in one step on `managerQueue`, so a non-nil `attempt` there has not been
    /// reported yet.
    func addCompletion(_ completion: @escaping (MedtrumConnectError?) -> Void, patience: Patience = .bounded) {
        waiters.append(Waiter(patience: patience, completion: completion))
    }

    /// Removes and returns the callers that have now been waiting for at least `budget`. Measured
    /// from when each one joined, so a caller that arrives late in a long-pending connect still
    /// gets its own full budget rather than whatever is left of somebody else's. `.untilResolved`
    /// waiters are never expired.
    func takeExpired(budget: TimeInterval, now: Date = .now) -> [(MedtrumConnectError?) -> Void] {
        let isExpired = { (waiter: Waiter) -> Bool in
            guard let deadlineFrom = waiter.deadlineFrom else {
                return false
            }

            return now.timeIntervalSince(deadlineFrom) >= budget
        }

        let expired = waiters.filter(isExpired)
        waiters.removeAll(where: isExpired)

        return expired.map(\.completion)
    }

    /// How long until the longest-waiting caller reaches `budget`, or nil when nobody is waiting on
    /// a deadline - such an attempt needs no timer, it just holds the pending connect.
    func nextDeadline(budget: TimeInterval, now: Date = .now) -> TimeInterval? {
        guard let earliest = waiters.compactMap(\.deadlineFrom).min() else {
            return nil
        }

        return max(0, budget - now.timeIntervalSince(earliest))
    }

    func takeCompletions() -> [(MedtrumConnectError?) -> Void] {
        let waiting = waiters.map(\.completion)
        waiters = []
        return waiting
    }

    /// True for the first caller only - whoever gets it owns reporting the result.
    func claim() -> Bool {
        guard !reported else {
            return false
        }

        reported = true
        timeout?.cancel()
        timeout = nil

        return true
    }
}

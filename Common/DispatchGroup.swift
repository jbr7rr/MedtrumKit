final class MedtrumKitDispatchGroup {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var count = 0

    func enter() {
        lock.lock()
        count += 1
        lock.unlock()
        group.enter()
    }

    func leave() {
        lock.lock()
        count -= 1
        let isBalanced = count >= 0
        lock.unlock()

        // Prevent crash on multiple leave calls
        guard isBalanced else {
            return
        }

        group.leave()
    }

    @discardableResult func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        group.wait(timeout: timeout)
    }
}

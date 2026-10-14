import Foundation
@testable import MedtrumKit
import XCTest

/// A scripted stand-in for `BluetoothManager`.
///
/// Every command is answered from a queue of answers per command type, in the order they were scripted.
/// An answer is the raw bytes the patch sent - the hex of the "Got data" log lines - and goes through
/// the real packet parser, the same way `PeripheralManager.writePacket` turns them into a result.
/// A command nobody scripted an answer for times out and is recorded in `unscriptedWrites`.
///
/// Statuses go the other way, into `pumpManager.handleStatus`, on `queue` - which stands in for the
/// central manager's queue.
final class FakeMedtrumLink: MedtrumLink {
    enum Answer {
        /// The answer as the patch sent it, one hex string per fragment
        case fragments([String])
        /// Nothing came back within the write timeout
        case timeout
        /// The write failed without an answer - the link dropped, no peripheral manager, ...
        case failure(MedtrumWriteError)

        /// The answer with the CRC of its first fragment broken, as if a byte got lost on the air
        static func garbled(_ fragments: [String]) -> Answer {
            var corrupted = fragments
            if var first = corrupted.first.flatMap({ Data(hex: $0) }), let last = first.indices.last {
                first[last] ^= 0xFF
                corrupted[0] = first.hexEncodedString()
            }
            return .fragments(corrupted)
        }
    }

    struct Write {
        let packet: any MedtrumBasePacketProtocol
        /// How long the caller would wait for the answer
        let timeout: TimeInterval

        var commandType: UInt8 {
            packet.commandType
        }

        /// The command as it goes on the air with the sequence number `writePacket` gave it, for
        /// comparing with a "Writing data" log line
        func encoded(sequence: UInt8) -> String {
            packet.encode(sequenceNumber: sequence).map { $0.hexEncodedString() }.joined()
        }
    }

    weak var pumpManager: MedtrumPumpManager? {
        didSet {
            guard pumpManager != nil, let work = lock.withLock({ () -> (() -> Void)? in
                defer { attachWork = nil }
                return attachWork
            }) else {
                return
            }
            work()
        }
    }

    let queue = DispatchQueue(label: "com.nightscout.MedtrumKitTests.fakeLink")

    private let lock = NSLock()
    private var answers: [UInt8: [Answer]] = [:]
    private var followUps: [UInt8: [() -> Void]] = [:]
    private var recordedWrites: [Write] = []
    private var unscripted: [UInt8] = []
    private var disconnectRequests: [Bool] = []
    private var connectRequests = 0
    private var nextConnectError: MedtrumConnectError?
    private var timeoutWait: ((TimeInterval) -> Void)?
    private var attachWork: (() -> Void)?
    /// One write at a time, as on the real link
    private let writer = LinkWriter()

    // MARK: Scripting

    func script(_ commandType: UInt8, _ answer: Answer) {
        script(commandType, answer, thenNotify: [])
    }

    func script(_ commandType: UInt8, fragments: String...) {
        script(commandType, .fragments(fragments))
    }

    func script(_ commandType: UInt8, _ fragments: [String]) {
        script(commandType, .fragments(fragments))
    }

    /// An answer, and the notifications the patch pushes right after it - delivered before the command's caller
    /// carries on, as they are on a device when the BLE queue gets to them first
    func script(_ commandType: UInt8, _ answer: Answer, thenNotify notifications: [String]) {
        script(commandType, answer) { [weak self] in
            notifications.forEach { self?.notify($0) }
        }
    }

    /// An answer, and `work` run once it is in, before the command's caller carries on - what else reaches the manager
    /// meanwhile on a device: a status, a batch another path sends
    func script(_ commandType: UInt8, _ answer: Answer, then work: @escaping () -> Void) {
        lock.withLock {
            answers[commandType, default: []].append(answer)
            followUps[commandType, default: []].append(work)
        }
    }

    /// What `ensureConnected` reports from now on, nil for a usable session
    var connectError: MedtrumConnectError? {
        get { lock.withLock { nextConnectError } }
        set { lock.withLock { nextConnectError = newValue } }
    }

    /// Runs with the time a write answered `.timeout` waited in vain - for moving the manager's clock on by it
    var onTimeout: ((TimeInterval) -> Void)? {
        get { lock.withLock { timeoutWait } }
        set { lock.withLock { timeoutWait = newValue } }
    }

    /// Runs once, as the next manager takes the link - in its init, before it returns: a status arriving at once, say
    var whenAttached: (() -> Void)? {
        get { lock.withLock { attachWork } }
        set { lock.withLock { attachWork = newValue } }
    }

    /// Holds the link's writer, as a write of another path waiting for its answer would - the heartbeat's full sync, say
    /// - until `release` is signalled. Returns once it holds it.
    func holdWriter(until release: DispatchSemaphore) {
        let held = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [writer] in
            _ = writer.exclusively(within: nil) { _ in
                held.signal()
                release.wait()
            }
        }
        held.wait()
    }

    // MARK: What happened

    var writes: [Write] {
        lock.withLock { recordedWrites }
    }

    var writtenCommands: [UInt8] {
        writes.map(\.commandType)
    }

    /// Commands that had no answer scripted, by command type
    var unscriptedWrites: [UInt8] {
        lock.withLock { unscripted }
    }

    /// Answers scripted but never asked for
    var unusedAnswers: Int {
        lock.withLock { answers.values.reduce(0) { $0 + $1.count } }
    }

    var connects: Int {
        lock.withLock { connectRequests }
    }

    /// The `force` of every disconnect asked for
    var disconnects: [Bool] {
        lock.withLock { disconnectRequests }
    }

    // MARK: Statuses from the patch

    /// A notification, as `PeripheralManager.handleHeartbeat` delivers it - without the full sync that
    /// one may start afterwards
    func notify(_ hex: String) {
        let packet = NotificationPacket()
        packet.totalData = Self.bytes(hex)

        guard packet.hasEnoughData else {
            XCTFail("Notification too short: \(hex)")
            return
        }

        deliver(packet.parseResponse(), duringReconnect: false, fullSync: false)
    }

    /// A Synchronize answer, as the connect flow (`duringReconnect`) or the session's periodic full sync
    /// hands it on
    func deliverFullStatus(_ fragments: [String], duringReconnect: Bool = false) {
        let result = Self.result(of: SynchronizePacket(), decoding: fragments.map(Self.bytes))

        guard case let .success(data) = result, let response = data as? SynchronizePacketResponse else {
            XCTFail("Synchronize answer does not parse: \(result)")
            return
        }

        deliver(response, duringReconnect: duringReconnect, fullSync: true)
    }

    /// A full status carrying only what the notification `hex` carries - as the connect flow (`duringReconnect`) or the
    /// session's periodic full sync hands one on
    func deliverFullStatus(notification hex: String, duringReconnect: Bool) {
        let packet = NotificationPacket()
        packet.totalData = Self.bytes(hex)

        guard packet.hasEnoughData else {
            XCTFail("Notification too short: \(hex)")
            return
        }

        deliver(packet.parseResponse(), duringReconnect: duringReconnect, fullSync: true)
    }

    /// Runs `work` where the link delivers statuses - for driving what `PeripheralManager` does around them
    func onQueue(_ work: () -> Void) {
        queue.sync(execute: work)
    }

    private func deliver(_ response: SynchronizePacketResponse, duringReconnect: Bool, fullSync: Bool) {
        queue.sync {
            guard let pumpManager else {
                XCTFail("No pump manager to deliver a status to")
                return
            }

            // Stamped as received on the manager's monotonic clock, which the scenario moves
            var response = response
            response.receivedUptime += pumpManager.uptime() - TimeInterval.continuousUptime
            pumpManager.handleStatus(response, duringReconnect: duringReconnect, fullSync: fullSync)
        }
    }

    // MARK: MedtrumLink

    func ensureConnected(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        let error = lock.withLock { () -> MedtrumConnectError? in
            connectRequests += 1
            return nextConnectError
        }

        completion(error)
    }

    func write(_ packet: any MedtrumBasePacketProtocol, timeout: TimeInterval?) -> MedtrumWriteResult<Any> {
        // Not written, if a write held up ahead of it took all of `timeout`. The follow-up runs once the writer is free.
        let written = writer.exclusively(within: timeout) { left in
            answer(packet, waitingFor: left)
        }
        guard let written else {
            return .failure(error: .timeout)
        }

        written.followUp()
        return written.result
    }

    private func answer(
        _ packet: any MedtrumBasePacketProtocol,
        waitingFor timeout: TimeInterval
    ) -> (result: MedtrumWriteResult<Any>, followUp: () -> Void) {
        let scripted = lock.withLock { () -> (answer: Answer, followUp: () -> Void)? in
            recordedWrites.append(Write(packet: packet, timeout: timeout))

            guard var queued = answers[packet.commandType], !queued.isEmpty else {
                unscripted.append(packet.commandType)
                return nil
            }

            let next = queued.removeFirst()
            answers[packet.commandType] = queued

            var followUp: () -> Void = {}
            if var pending = followUps[packet.commandType], !pending.isEmpty {
                followUp = pending.removeFirst()
                followUps[packet.commandType] = pending
            }
            return (next, followUp)
        }

        guard let scripted else {
            return (.failure(error: .timeout), {})
        }

        let result: MedtrumWriteResult<Any>
        switch scripted.answer {
        case let .fragments(fragments):
            result = Self.result(of: packet, decoding: fragments.map(Self.bytes))
        case .timeout:
            onTimeout?(timeout)
            result = .failure(error: .timeout)
        case let .failure(error):
            result = .failure(error: error)
        }

        return (result, scripted.followUp)
    }

    func disconnect(force: Bool) {
        lock.withLock {
            disconnectRequests.append(force)
        }
    }

    // MARK: Decoding

    /// What `PeripheralManager` makes of an answer once all of its fragments are in
    static func result(of packet: any MedtrumBasePacketProtocol, decoding fragments: [Data]) -> MedtrumWriteResult<Any> {
        var packet = packet
        for fragment in fragments {
            packet.decode(fragment)
        }

        guard packet.isComplete else {
            // writePacket would have waited for the rest until it timed out
            return .failure(error: .timeout)
        }

        // In `PeripheralManager`'s order: a frame that fails its checks first, its code is as garbled as the rest
        if packet.failed {
            return .failure(error: .invalidData)
        }

        if packet.responseCode != 0 {
            return .failure(error: .invalidResponse(code: packet.responseCode))
        }

        if !packet.hasEnoughData {
            return .failure(error: .invalidData)
        }

        return .success(data: packet.parseResponse())
    }

    static func bytes(_ hex: String) -> Data {
        guard !hex.isEmpty, let data = Data(hex: hex) else {
            preconditionFailure("Not a hex string: \(hex)")
        }

        return data
    }
}

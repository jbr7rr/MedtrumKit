enum MedtrumWriteResult<T> {
    case success(data: T)
    case failure(error: MedtrumWriteError)
}

enum MedtrumWriteError: LocalizedError {
    case timeout
    case alreadyRunning
    case noData
    case invalidData
    case invalidResponse(code: UInt16)
    case noManager
    case noWriteCharacteristic
    /// The link was down when the command was to be written, so it was not - see `PeripheralManager.writePacket`
    case notConnected

    public var errorDescription: String {
        switch self {
        case .timeout:
            return "A command timeout is hit"
        case .alreadyRunning:
            return "A command is already running"
        case .noData:
            return "No data"
        case .invalidData:
            return "Invalid data received"
        case let .invalidResponse(code):
            return "Invalid response code: \(code)"
        case .noManager:
            return "No peripheral manager"
        case .noWriteCharacteristic:
            return "No write characteristic. Device might be disconnected"
        case .notConnected:
            return "The device is not connected"
        }
    }
}

/// What became of a dosing command, as far as the phone can tell: whether the patch may have acted on it.
///
/// Nothing is written before the link and the write characteristic are checked (`.noManager`, `.noWriteCharacteristic`,
/// `.notConnected`). Once the command is handed to CoreBluetooth, whatever goes wrong - no answer in time, an answer
/// that fails its checks - leaves it open whether the patch got it. Only an intact answer carrying an error code is the
/// patch turning it down.
enum MedtrumCommandOutcome: Equatable {
    /// The patch answered that it took it
    case accepted
    /// It never left the phone
    case notSent
    /// The patch answered, turning it down
    case rejected
    /// It went out - or may have - and no usable answer came back: the patch may or may not have acted on it
    case unknown

    init<T>(_ result: MedtrumWriteResult<T>) {
        switch result {
        case .success:
            self = .accepted
        case let .failure(error):
            self.init(error)
        }
    }

    init(_ error: MedtrumWriteError) {
        switch error {
        case .alreadyRunning,
             .noManager,
             .noWriteCharacteristic,
             .notConnected:
            self = .notSent
        case .invalidResponse:
            self = .rejected
        case .invalidData,
             .noData,
             .timeout:
            self = .unknown
        }
    }
}

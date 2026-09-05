import Combine
import LoopKit
import OSLog

class MedtrumLogger {
    private let logger: Logger
    private let writer = MedtrumLogWriter.shared
    public static var pumpManager: MedtrumPumpManager?

    init(category: String) {
        logger = Logger(subsystem: "org.nightscout.MedtrumKit", category: category)
    }

    public func debug(_ msg: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let message = "\(file.file) - \(function)#\(line): \(msg)"
        logger.debug("\(message, privacy: .public)")
        writeToFile(message, .debug)
        writeToPumpManager(message, .debug)
    }

    public func info(_ msg: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let message = "\(file.file) - \(function)#\(line): \(msg)"
        logger.info("\(message, privacy: .public)")
        writeToFile(message, .info)
        writeToPumpManager(message, .info)
    }

    public func warning(_ msg: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let message = "\(file.file) - \(function)#\(line): \(msg)"
        logger.warning("\(message, privacy: .public)")
        writeToFile(message, .notice)
        writeToPumpManager(message, .notice)
    }

    public func error(_ msg: String, file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let message = "\(file.file) - \(function)#\(line): \(msg)"
        logger.error("\(message, privacy: .public)")
        writeToFile(message, .error)
        writeToPumpManager(message, .error)
    }

    func getDebugLogs() -> [URL] {
        writer.debugLogs()
    }

    private func writeToFile(_ msg: String, _ type: OSLogEntryLog.Level) {
        writer.append(msg, level: getLevel(type))
    }
    
    private func writeToPumpManager(_ msg: String, _ type: OSLogEntryLog.Level) {
        guard let pumpManager = Self.pumpManager else {
            return
        }
        
        pumpManager.pumpDelegate.notify { delegate in
            guard let delegate else {
                return
            }
            
            delegate.deviceManager(
                pumpManager,
                logEventForDeviceIdentifier: pumpManager.state.pumpSN.hexEncodedString(),
                type: .delegate,
                message: "[\(self.getLevel(type))] \(msg)",
            ) { _ in }
        }
    }

    private func getLevel(_ type: OSLogEntryLog.Level) -> String {
        switch type {
        case .info:
            return "INFO"
        case .notice:
            return "WARNING"
        case .error:
            return "ERROR"
        case .fault:
            return "FAULT"
        case .debug:
            return "DEBUG"
        default:
            return "UNKNOWN"
        }
    }
}

/// Appends the log entries to the log file. Shared by every MedtrumLogger, since they all write to
/// the same file.
///
/// The writing itself is done on a background queue: the pump communication runs on the main queue
/// and on the bluetooth queue, and stalling either of those makes commands time out
private final class MedtrumLogWriter {
    static let shared = MedtrumLogWriter()

    private let queue = DispatchQueue(label: "org.nightscout.MedtrumKit.logWriter", qos: .utility)
    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter

    private let logDir: URL
    private let logFile: URL
    private let logFilePrev: URL

    /// Only accessed from `queue`
    private var fileHandle: FileHandle?
    private var fileCreatedAt: Date?

    private init() {
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logDir = documentsDirectory.appendingPathComponent("medtrumkit")
        logFile = logDir.appendingPathComponent("medtrumkit_log.txt")
        logFilePrev = logDir.appendingPathComponent("medtrumkit_log_prev.txt")

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    }

    /// Queues the entry to be appended to the log file. The timestamp is taken here, so it reflects
    /// when the event happened instead of when it got written
    func append(_ msg: String, level: String) {
        let timestamp = Date()

        queue.async {
            guard let fileHandle = self.openLogFile() else {
                return
            }

            let logEntry = "[\(self.dateFormatter.string(from: timestamp)) \(level)] \(msg)\n"
            guard let data = logEntry.data(using: .utf8) else {
                return
            }

            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        }
    }

    func debugLogs() -> [URL] {
        // Make sure everything which has been logged so far is on disk before it gets shared
        queue.sync {
            try? self.fileHandle?.synchronize()
        }

        var items: [URL] = []

        if fileManager.fileExists(atPath: logFile.path) {
            items.append(logFile)
        }

        if fileManager.fileExists(atPath: logFilePrev.path) {
            items.append(logFilePrev)
        }

        return items
    }

    /// Returns the handle to write to, rotating the log file when it is from a previous day
    private func openLogFile() -> FileHandle? {
        let startOfDay = Calendar.current.startOfDay(for: Date())

        if let fileHandle = fileHandle, let fileCreatedAt = fileCreatedAt, fileCreatedAt >= startOfDay {
            return fileHandle
        }

        try? fileHandle?.close()
        fileHandle = nil
        fileCreatedAt = nil

        if !fileManager.fileExists(atPath: logDir.path) {
            try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: false, attributes: nil)
        }

        let createdAt = (try? fileManager.attributesOfItem(atPath: logFile.path))?[.creationDate] as? Date
        if createdAt == nil {
            createFile(at: startOfDay)
        } else if createdAt! < startOfDay {
            try? fileManager.removeItem(at: logFilePrev)
            try? fileManager.moveItem(at: logFile, to: logFilePrev)
            createFile(at: startOfDay)
        }

        guard let fileHandle = try? FileHandle(forWritingTo: logFile) else {
            return nil
        }

        self.fileHandle = fileHandle
        fileCreatedAt = max(createdAt ?? startOfDay, startOfDay)

        return fileHandle
    }

    private func createFile(at date: Date) {
        fileManager.createFile(atPath: logFile.path, contents: nil, attributes: [.creationDate: date])
    }
}

private extension String {
    var file: String { components(separatedBy: "/").last ?? "" }
}

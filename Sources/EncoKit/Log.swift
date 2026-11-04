import Foundation
import os

/// Small logger: unified logging + an in-memory ring buffer the Diagnostics view can show,
/// mirrored to ~/Library/Logs/Encore/Encore.log so problems can be reported.
@MainActor
public final class EncoreLog {
    public static let shared = EncoreLog()

    public struct Line: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let text: String
    }

    public private(set) var lines: [Line] = []
    public var onAppend: (() -> Void)?

    private let logger = Logger(subsystem: "app.encore.Encore", category: "bluetooth")
    private let fileHandle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Encore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Encore.log")
        // Start a fresh file each launch once it grows past ~1 MB.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    public var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Encore/Encore.log")
    }

    public func callAsFunction(_ text: String) {
        logger.debug("\(text, privacy: .public)")
        let line = Line(date: Date(), text: text)
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        if let data = "\(formatter.string(from: line.date))  \(text)\n".data(using: .utf8) {
            fileHandle?.write(data)
        }
        onAppend?()
    }

    public var transcript: String {
        lines.map { "\(formatter.string(from: $0.date))  \($0.text)" }.joined(separator: "\n")
    }
}

// MARK: - Crash breadcrumbs

/// File descriptor the signal handler writes to (must be a plain global for a C callback).
nonisolated(unsafe) private var crashLogFD: Int32 = -1

private func writeRaw(_ s: String) {
    guard crashLogFD >= 0 else { return }
    s.utf8CString.withUnsafeBufferPointer { buf in
        _ = write(crashLogFD, buf.baseAddress, buf.count - 1)
    }
}

public enum CrashReporter {
    /// Writes the reason and a stack trace to Encore.log when the app dies, so crashes are
    /// diagnosable even without access to system crash reports.
    public static func install(logURL: URL) {
        crashLogFD = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        NSSetUncaughtExceptionHandler { exception in
            writeRaw("CRASH uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n")
            writeRaw(exception.callStackSymbols.joined(separator: "\n") + "\n")
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                writeRaw("CRASH signal \(s)\n")
                writeRaw(Thread.callStackSymbols.joined(separator: "\n") + "\n")
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}

// MARK: - Threading

/// IOBluetooth delivers some callbacks on the main thread and (on macOS 26) others on a
/// background dispatch queue. Everything in EncoKit is main-actor, so hop when needed.
func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}

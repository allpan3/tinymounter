import Darwin
import Foundation

/// Phase 3 plan §2: how the app's last run ended, so that the extension restarts it after a crash.
public enum RunState: String, Sendable {
    case running, crashed, stopped

    public struct Record: Equatable, Sendable {
        public let state: RunState
        public let launched: Date

        public init(state: RunState, launched: Date) {
            self.state = state
            self.launched = launched
        }
    }

    public static let fileName = "RunState"
    /// A crash sooner than this after launch is not restarted, so a crash at launch can't loop.
    public static let restartAfter: TimeInterval = 60

    /// Each state is 8 bytes with its newline, so the crash handler overwrites it in place.
    public static func encode(_ record: Record) -> Data {
        Data("\(record.state.rawValue)\n\(Int64(record.launched.timeIntervalSince1970))\n".utf8)
    }

    public static func decode(_ data: Data) -> Record? {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard lines.count == 2, let state = RunState(rawValue: String(lines[0])),
              let seconds = Int64(lines[1]) else { return nil }
        return Record(state: state, launched: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// Quit and Force Quit leave `stopped` and `running`: only a crash restarts the app.
    public static func shouldRestart(_ record: Record?, now: Date) -> Bool {
        guard let record, record.state == .crashed else { return false }
        return now.timeIntervalSince(record.launched) >= restartAfter
    }

    public static func read(_ url: URL) -> Record? {
        (try? Data(contentsOf: url)).flatMap(decode)
    }
}

/// The app's side. `start` keeps a descriptor open for the crash handler, which can't open files.
public enum RunStateRecorder {
    nonisolated(unsafe) fileprivate static var descriptor: Int32 = -1
    nonisolated(unsafe) fileprivate static var crashedLine: UnsafeMutableRawPointer?
    static let crashSignals = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE]

    /// Writes `running` and returns the record that the previous run left.
    public static func start(at url: URL, now: Date = Date()) throws -> RunState.Record? {
        let previous = RunState.read(url)
        let fd = open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("open") }
        let data = RunState.encode(.init(state: .running, launched: now))
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard written == data.count, ftruncate(fd, off_t(data.count)) == 0 else {
            let error = posixError("pwrite")
            close(fd)
            throw error
        }
        let line = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 1)
        line.copyMemory(from: Array("crashed\n".utf8), byteCount: 8)
        crashedLine = line
        descriptor = fd
        var action = sigaction()
        action.__sigaction_u.__sa_handler = recordCrash
        sigemptyset(&action.sa_mask)
        for signal in crashSignals { sigaction(signal, &action, nil) }
        return previous
    }

    /// Quit, logout and shutdown.
    public static func stop() {
        guard descriptor >= 0 else { return }
        _ = Array("stopped\n".utf8).withUnsafeBytes { pwrite(descriptor, $0.baseAddress, 8, 0) }
    }
}

/// Only async-signal-safe calls. Raising again with the default action crashes as before.
private func recordCrash(_ signal: Int32) {
    if let line = RunStateRecorder.crashedLine { _ = pwrite(RunStateRecorder.descriptor, line, 8, 0) }
    // Not SA_RESETHAND: macOS ignores it for SIGILL and SIGTRAP, and a Swift trap then loops here.
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

import Darwin
import Foundation
import TransferCore

let usage = """
Usage: transfer-bench FILE [options]
  --stage-dir DIRECTORY  Copy into an exclusive temporary local file, then remove it.
  --offset BYTES         Start at this offset (default 0).
  --length BYTES         Read this many bytes (default through EOF).
  --block-size BYTES     POSIX request size: 4096..16777216 (default 1048576).
  --runs COUNT           Reopen and repeat 1..100 times (default 1).
  --no-cache             Request F_NOCACHE; does NOT prove the NAS cache is cold.
  --sync                Include fsync of the staging file in the transfer time.
  --verify              SHA-256 compare source/staged range AFTER timing; requires --stage-dir.
  --cache-label TEXT     Operator's description, default 'unknown'; not verified by this tool.
  --help                Show this help.

JSONL goes to stdout. Errors go to stderr and return nonzero. Source files are opened
read-only. No existing destination is overwritten. This uses POSIX reads, not file
coordination or server-side copy. Repeated reads and --verify can warm caches.
"""

struct Options {
    var path: String
    var staging: String?
    var offset: Int64 = 0
    var length: Int64?
    var blockSize = 1024 * 1024
    var runs = 1
    var noCache = false
    var sync = false
    var verify = false
    var cacheLabel = "unknown"

    init(_ args: [String]) throws {
        guard let first = args.first, !first.hasPrefix("--") else { throw CLIError.message(usage) }
        path = first
        var i = 1
        while i < args.count {
            let flag = args[i]; i += 1
            if flag == "--no-cache" { noCache = true; continue }
            if flag == "--sync" { sync = true; continue }
            if flag == "--verify" { verify = true; continue }
            guard i < args.count else { throw CLIError.message("Missing value for \(flag)") }
            let value = args[i]; i += 1
            switch flag {
            case "--stage-dir": staging = value
            case "--cache-label": cacheLabel = value
            case "--offset", "--length", "--block-size", "--runs":
                guard let number = Int64(value), number >= 0 else { throw CLIError.message("Invalid number for \(flag)") }
                switch flag {
                case "--offset": offset = number
                case "--length": length = number
                case "--block-size": blockSize = Int(number)
                default: runs = Int(number)
                }
            default: throw CLIError.message("Unknown option: \(flag)")
            }
        }
        guard (1...100).contains(runs) else { throw CLIError.message("--runs must be 1..100") }
        guard !(verify || sync) || staging != nil else { throw CLIError.message("--verify and --sync require --stage-dir") }
    }
}

enum CLIError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct Record: Encodable {
    let schemaVersion = 1
    let toolVersion = "0.1.0"
    let runID: String
    let run: Int
    let timestamp: String
    let sourcePath: String
    let sourceFilesystem: FileSystemInfo
    let sourceSnapshot: FileSnapshot
    let range: ByteRange
    let mode: String
    let blockSize: Int
    let noCacheRequested: Bool
    let cacheLabel: String
    let cacheStateVerified = false
    let syncStaging: Bool
    let openSeconds: Double
    let totalSeconds: Double
    let metrics: TransferMetrics
    let megabytesPerSecond: Double?
    let verification: String
    let sha256: String?
    let verificationSeconds: Double?
    let stageFileRetained = false
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
}

func run(_ options: Options, iteration: Int) throws {
    let start = DispatchTime.now().uptimeNanoseconds
    let sourceURL = URL(fileURLWithPath: options.path).standardizedFileURL
    let source = try ReadOnlyFile(url: sourceURL, noCache: options.noCache)
    guard options.offset <= source.snapshot.size else { throw TransferError.invalidRange }
    let range = try ByteRange(offset: options.offset,
        length: options.length ?? (source.snapshot.size - options.offset), fileSize: source.snapshot.size)
    let opened = DispatchTime.now().uptimeNanoseconds
    let output = try Transfer.run(source: source, range: range, blockSize: options.blockSize,
        stagingDirectory: options.staging.map { URL(fileURLWithPath: $0, isDirectory: true) }, syncStaging: options.sync)
    defer { if let url = output.stagingURL { try? FileManager.default.removeItem(at: url) } }
    let completed = DispatchTime.now().uptimeNanoseconds
    var digest: String?
    var verifySeconds: Double?
    if options.verify, let stageURL = output.stagingURL {
        let begin = DispatchTime.now().uptimeNanoseconds
        let expected = try source.checksum(range: range)
        let stage = try ReadOnlyFile(url: stageURL)
        guard try stage.checksum(range: range) == expected else { throw TransferError.checksumMismatch }
        digest = expected
        verifySeconds = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e9
    }
    // Ensure cleanup succeeds before emitting a successful record.
    if let url = output.stagingURL { try FileManager.default.removeItem(at: url) }
    let record = Record(runID: UUID().uuidString, run: iteration, timestamp: ISO8601DateFormatter().string(from: Date()),
        sourcePath: sourceURL.path, sourceFilesystem: source.filesystem, sourceSnapshot: source.snapshot,
        range: range, mode: output.stagingURL == nil ? "read-to-sink" : "read-to-local-stage",
        blockSize: options.blockSize, noCacheRequested: options.noCache, cacheLabel: options.cacheLabel,
        syncStaging: options.sync, openSeconds: Double(opened - start) / 1e9,
        totalSeconds: Double(completed - start) / 1e9, metrics: output.metrics,
        megabytesPerSecond: output.metrics.megabytesPerSecond,
        verification: options.verify ? "sha256-match-after-timing" : "not-performed",
        sha256: digest, verificationSeconds: verifySeconds)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] { print(usage) }
    else {
        let options = try Options(args)
        for iteration in 1...options.runs { try run(options, iteration: iteration) }
    }
} catch {
    FileHandle.standardError.write(Data("transfer-bench: \(error.localizedDescription)\n".utf8))
    exit(1)
}

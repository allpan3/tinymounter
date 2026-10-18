import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class RunStateTests: XCTestCase {
    private let launched = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecordRoundTripsAndEachStateIsEightBytes() {
        for state in [RunState.running, .crashed, .stopped] {
            let data = RunState.encode(.init(state: state, launched: launched))
            XCTAssertEqual(data.firstIndex(of: UInt8(ascii: "\n")), 7)
            XCTAssertEqual(RunState.decode(data), .init(state: state, launched: launched))
        }
        XCTAssertNil(RunState.decode(Data("crashed\n".utf8)))
        XCTAssertNil(RunState.decode(Data("paused\n1\n".utf8)))
    }

    func testOnlyACrashAfterTheFirstMinuteRestarts() {
        let later = launched.addingTimeInterval(RunState.restartAfter)
        XCTAssertTrue(RunState.shouldRestart(.init(state: .crashed, launched: launched), now: later))
        XCTAssertFalse(RunState.shouldRestart(.init(state: .crashed, launched: launched),
                                              now: later.addingTimeInterval(-1)))
        XCTAssertFalse(RunState.shouldRestart(.init(state: .running, launched: launched), now: later))
        XCTAssertFalse(RunState.shouldRestart(.init(state: .stopped, launched: launched), now: later))
        XCTAssertFalse(RunState.shouldRestart(nil, now: later))
    }

    func testRecorderWritesRunningThenStopped() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "RunState-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RunState.encode(.init(state: .crashed, launched: launched)).write(to: url)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertEqual(try RunStateRecorder.start(at: url, now: now), .init(state: .crashed, launched: launched))
        XCTAssertEqual(RunState.read(url), .init(state: .running, launched: now))
        RunStateRecorder.stop()
        XCTAssertEqual(RunState.read(url), .init(state: .stopped, launched: now))
        for signal in RunStateRecorder.crashSignals { Darwin.signal(signal, SIG_DFL) }
    }
}

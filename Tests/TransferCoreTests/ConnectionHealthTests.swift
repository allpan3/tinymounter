import Foundation
import XCTest
@testable import TransferCore

final class ConnectionHealthTests: XCTestCase {
    private final class ManualClock: @unchecked Sendable {
        var now = Duration.seconds(1000)
    }

    private let both: [SourceFailure] = [.serverUnreachable, .notAuthenticated]

    private func connected(_ clock: ManualClock) -> ConnectionHealth {
        var health = ConnectionHealth(now: { clock.now })
        XCTAssertEqual(health.evaluate(), .notConnected)
        // The first recovery resolves both: an earlier process may have returned either.
        XCTAssertEqual(health.succeeded(), both)
        XCTAssertEqual(health.succeeded(), [])
        XCTAssertEqual(health.evaluate(), .connected)
        return health
    }

    func testOperationOverTheLimitMakesTheShareUnresponsive() {
        let clock = ManualClock()
        var health = connected(clock)
        let finished = health.begin()
        clock.now += .seconds(1)
        health.end(finished)
        _ = health.begin()
        clock.now += ConnectionHealth.stallLimit
        XCTAssertEqual(health.evaluate(), .connected)
        clock.now += .milliseconds(1)
        XCTAssertEqual(health.evaluate(), .unresponsive)
        // Requests fail at once: the state stays unresponsive with no probe.
        clock.now += .seconds(60)
        XCTAssertEqual(health.refusal(), .serverUnreachable)
        XCTAssertEqual(health.evaluate(), .unresponsive)
    }

    func testTransferStallCountsFromLastProgress() {
        let clock = ManualClock()
        var health = connected(clock)
        let transfer = health.begin()
        for _ in 0..<6 {
            clock.now += .seconds(50)
            health.progressed(transfer)
            XCTAssertEqual(health.evaluate(), .connected)
        }
        clock.now += ConnectionHealth.stallLimit + .milliseconds(1)
        XCTAssertEqual(health.evaluate(), .unresponsive)
    }

    func testSuccessfulOperationResolvesTimeoutBeforeTheNextRequest() {
        let clock = ManualClock()
        var health = connected(clock)
        let activity = health.begin()
        clock.now += ConnectionHealth.stallLimit + .milliseconds(1)
        XCTAssertEqual(health.refusal(), .serverUnreachable)
        XCTAssertEqual(health.succeeded(), [.serverUnreachable])
        health.end(activity)
        XCTAssertNil(health.refusal())
        XCTAssertEqual(health.succeeded(), [])
    }

    func testOnlyANewPasswordEndsARefusedSignIn() {
        for failure in [SourceFailure.notAuthenticated, .classify(errno: EAUTH, context: .fetch)] {
            let clock = ManualClock()
            var health = connected(clock)
            health.failed(failure)
            XCTAssertEqual(health.evaluate(), .needsSignIn, "\(failure)")
            XCTAssertEqual(health.refusal(), .notAuthenticated, "\(failure)")

            // No probe, stall, success or other failure changes it.
            _ = health.begin()
            clock.now += .seconds(120)
            XCTAssertFalse(health.startProbe(), "\(failure)")
            for other: SourceFailure in [.serverUnreachable, .notConnected] { health.failed(other) }
            XCTAssertEqual(health.succeeded(), [], "\(failure)")
            health.networkChanged(satisfied: false)
            XCTAssertEqual(health.refusal(), .notAuthenticated, "\(failure)")
            health.networkChanged(satisfied: true)
            XCTAssertEqual(health.evaluate(), .needsSignIn, "\(failure)")

            health.signedIn()
            XCTAssertEqual(health.evaluate(), .notConnected, "\(failure)")
            XCTAssertNil(health.refusal(), "\(failure)")
            XCTAssertEqual(health.succeeded(), both, "\(failure)")

            // Each recovery resolves notAuthenticated only if it was used since the last one.
            health.failed(.serverUnreachable)
            clock.now += ConnectionHealth.firstProbeDelay
            XCTAssertTrue(health.startProbe(), "\(failure)")
            XCTAssertEqual(health.probeFinished(succeeded: true), [.serverUnreachable], "\(failure)")
        }
    }

    func testASignInRefusedWhileUnresponsiveOrNotConnectedNeedsSignIn() {
        let clock = ManualClock()
        var health = connected(clock)
        health.failed(.serverUnreachable)
        clock.now += ConnectionHealth.firstProbeDelay
        XCTAssertTrue(health.startProbe())
        health.failed(.notAuthenticated)
        XCTAssertEqual(health.evaluate(), .needsSignIn)
        XCTAssertEqual(health.probeFinished(succeeded: true), [])
        XCTAssertEqual(health.evaluate(), .needsSignIn)

        var fresh = ConnectionHealth(now: { clock.now })
        fresh.failed(.notAuthenticated)
        XCTAssertEqual(fresh.evaluate(), .needsSignIn)
    }

    func testRefusalFollowsTheState() {
        let clock = ManualClock()
        var health = ConnectionHealth(now: { clock.now })
        // A share that is not connected is tried: its next request opens a session.
        XCTAssertNil(health.refusal())
        XCTAssertEqual(health.succeeded(), both)
        XCTAssertNil(health.refusal())
        _ = health.begin()
        clock.now += ConnectionHealth.stallLimit + .milliseconds(1)
        XCTAssertEqual(health.refusal(), .serverUnreachable)
        XCTAssertEqual(health.state, .unresponsive)
        health.failed(.notConnected)
        XCTAssertNil(health.refusal())
        health.failed(.notAuthenticated)
        XCTAssertEqual(health.refusal(), .notAuthenticated)
    }

    func testOnlyTimeoutsMakeTheShareUnresponsive() {
        var health = connected(ManualClock())
        for failure: SourceFailure in [.noPermission, .pathRejected, .missing, .versionChanged, .cancelled,
                                       .tooManyEntries, .listingIncomplete,
                                       .unknown(domain: NSPOSIXErrorDomain, code: 5)] {
            health.failed(failure)
            XCTAssertEqual(health.evaluate(), .connected, "\(failure)")
        }
        health.failed(.classify(errno: ETIMEDOUT, context: .fetch))
        XCTAssertEqual(health.evaluate(), .unresponsive)
    }

    func testAShareThatCannotConnectIsUnresponsiveUntilAProbeSignsIn() {
        let clock = ManualClock()
        var health = ConnectionHealth(now: { clock.now })
        health.failed(.classify(errno: ECONNREFUSED, context: .listing))
        XCTAssertEqual(health.refusal(), .serverUnreachable)
        XCTAssertFalse(health.startProbe())
        clock.now += ConnectionHealth.firstProbeDelay
        XCTAssertTrue(health.startProbe())
        XCTAssertEqual(health.probeFinished(succeeded: true), both)
        XCTAssertEqual(health.evaluate(), .connected)
    }

    func testProbesBackOffToTheLongestDelayAndRestartOnWake() {
        let clock = ManualClock()
        var health = connected(clock)
        let stuck = health.begin()
        health.failed(.serverUnreachable)
        var delays: [Duration] = []
        var delay = ConnectionHealth.firstProbeDelay
        for _ in 0..<6 {
            clock.now += delay - .milliseconds(1)
            XCTAssertFalse(health.startProbe())
            clock.now += .milliseconds(1)
            XCTAssertTrue(health.startProbe())
            XCTAssertFalse(health.startProbe())
            XCTAssertEqual(health.probeFinished(succeeded: false), [])
            delays.append(delay)
            delay = min(delay * 2, ConnectionHealth.longestProbeDelay)
        }
        XCTAssertEqual(delays, [5, 10, 20, 40, 60, 60].map { Duration.seconds($0) })

        // Wake probes at once and starts the delays again.
        health.conditionsChanged()
        XCTAssertTrue(health.startProbe())
        XCTAssertEqual(health.probeFinished(succeeded: false), [])
        clock.now += ConnectionHealth.firstProbeDelay * 2
        XCTAssertTrue(health.startProbe())
        XCTAssertEqual(health.probeFinished(succeeded: true), [.serverUnreachable])
        XCTAssertEqual(health.evaluate(), .connected)
        XCTAssertEqual(health.probeFinished(succeeded: true), [])

        // A call still blocked from before the outage doesn't make the share unresponsive again.
        clock.now += .seconds(120)
        XCTAssertEqual(health.evaluate(), .connected)
        health.end(stuck)
        XCTAssertFalse(health.startProbe())
    }

    func testWithoutANetworkPathRequestsFailAtOnceAndThePathProbesAtOnce() {
        let clock = ManualClock()
        var health = connected(clock)
        health.networkChanged(satisfied: false)
        XCTAssertEqual(health.evaluate(), .notConnected)
        XCTAssertEqual(health.refusal(), .notConnected)
        health.failed(.serverUnreachable)
        XCTAssertFalse(health.startProbe())
        health.networkChanged(satisfied: true)
        XCTAssertTrue(health.startProbe())
        XCTAssertEqual(health.probeFinished(succeeded: true), [.serverUnreachable])
        XCTAssertNil(health.refusal())
    }

    func testLateProbeCannotRepeatSuccessfulOperationRecovery() {
        let clock = ManualClock()
        var health = connected(clock)
        health.failed(.serverUnreachable)
        clock.now += ConnectionHealth.firstProbeDelay
        XCTAssertTrue(health.startProbe())
        XCTAssertEqual(health.succeeded(), [.serverUnreachable])
        XCTAssertEqual(health.probeFinished(succeeded: true), [])
        XCTAssertNil(health.refusal())
    }
}

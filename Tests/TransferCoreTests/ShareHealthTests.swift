import Foundation
import XCTest
@testable import TransferCore

final class ShareHealthTests: XCTestCase {
    private final class ManualClock: @unchecked Sendable {
        var now = Duration.seconds(1000)
    }

    private let both: [SourceFailure] = [.serverUnreachable, .notAuthenticated]

    private func connected(_ clock: ManualClock) -> ShareHealth {
        var health = ShareHealth(now: { clock.now })
        XCTAssertEqual(health.evaluate(), .notConnected)
        // The first recovery resolves both: an earlier process may have returned either.
        XCTAssertEqual(health.mountAppeared(), both)
        XCTAssertEqual(health.mountAppeared(), [])
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
        clock.now += ShareHealth.stallLimit
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
            clock.now += .seconds(10)
            health.progressed(transfer)
            XCTAssertEqual(health.evaluate(), .connected)
        }
        clock.now += ShareHealth.stallLimit + .milliseconds(1)
        XCTAssertEqual(health.evaluate(), .unresponsive)
    }

    func testADirectSMBCallHasTheLongerLimitOnlyWhileItRuns() {
        let clock = ManualClock()
        var health = connected(clock)
        let activity = health.begin()
        health.beginDirectCall(activity)
        clock.now += ShareHealth.directCallLimit
        XCTAssertEqual(health.evaluate(), .connected)
        // The call's return counts as progress, and the next wait has the ordinary limit.
        health.endDirectCall(activity)
        clock.now += ShareHealth.stallLimit
        XCTAssertEqual(health.evaluate(), .connected)
        clock.now += .milliseconds(1)
        XCTAssertEqual(health.evaluate(), .unresponsive)

        // A direct call that never returns still makes the share unresponsive.
        _ = health.operationSucceeded()
        let stuck = health.begin()
        health.beginDirectCall(stuck)
        clock.now += ShareHealth.directCallLimit + .milliseconds(1)
        XCTAssertEqual(health.evaluate(), .unresponsive)
        // Its late return after the transition counts for nothing.
        health.endDirectCall(stuck)
        XCTAssertEqual(health.evaluate(), .unresponsive)
    }

    func testADirectCallDoesNotHideAnotherStalledActivity() {
        let clock = ManualClock()
        var health = connected(clock)
        let direct = health.begin()
        health.beginDirectCall(direct)
        _ = health.begin()
        clock.now += ShareHealth.stallLimit + .milliseconds(1)
        XCTAssertEqual(health.evaluate(), .unresponsive)
    }

    func testSuccessfulOperationResolvesTimeoutBeforeTheNextRequest() {
        let clock = ManualClock()
        var health = connected(clock)
        let activity = health.begin()
        clock.now += ShareHealth.stallLimit + .milliseconds(1)
        XCTAssertEqual(health.refusal(), .serverUnreachable)
        XCTAssertEqual(health.operationSucceeded(), [.serverUnreachable])
        health.end(activity)
        XCTAssertNil(health.refusal())
        XCTAssertEqual(health.operationSucceeded(), [])
    }

    func testSuccessfulOperationCannotRestoreLostMountOrDeniedGrant() {
        var health = connected(ManualClock())
        health.failed(.notAuthenticated)
        XCTAssertEqual(health.operationSucceeded(), [])
        XCTAssertEqual(health.refusal(), .notAuthenticated)
        health.mountDisappeared()
        XCTAssertEqual(health.operationSucceeded(), [])
        XCTAssertEqual(health.state, .notConnected)
    }

    func testLateProbeCannotRepeatSuccessfulOperationRecovery() {
        let clock = ManualClock()
        var health = connected(clock)
        health.failed(.serverUnreachable)
        clock.now += ShareHealth.probeInterval
        XCTAssertTrue(health.startProbe())
        XCTAssertEqual(health.operationSucceeded(), [.serverUnreachable])
        XCTAssertEqual(health.probeFinished(succeeded: true), [])
        XCTAssertNil(health.refusal())
    }

    func testRefusalFollowsTheState() {
        let clock = ManualClock()
        var health = ShareHealth(now: { clock.now })
        // A share that is not connected is tried: the mount table decides, with no I/O.
        XCTAssertNil(health.refusal())
        XCTAssertEqual(health.mountAppeared(), both)
        XCTAssertNil(health.refusal())
        _ = health.begin()
        clock.now += ShareHealth.stallLimit + .milliseconds(1)
        XCTAssertEqual(health.refusal(), .serverUnreachable)
        XCTAssertEqual(health.state, .unresponsive)
        health.failed(.notAuthenticated)
        XCTAssertEqual(health.refusal(), .notAuthenticated)
        health.mountDisappeared()
        XCTAssertNil(health.refusal())
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

    func testAFailedGrantNeedsAGrantUntilTheSessionEnds() {
        for failure in [SourceFailure.notAuthenticated, .classify(errno: EAUTH, context: .fetch),
                        .classify(errno: EPERM, context: .locationRoot)] {
            let clock = ManualClock()
            var health = connected(clock)
            health.failed(failure)
            XCTAssertEqual(health.evaluate(), .needsGrant, "\(failure)")
            XCTAssertEqual(health.refusal(), .notAuthenticated, "\(failure)")

            // No probe and no stall can change it, and only the end of the session clears it.
            _ = health.begin()
            clock.now += .seconds(60)
            XCTAssertFalse(health.startProbe(), "\(failure)")
            health.failed(.serverUnreachable)
            XCTAssertEqual(health.evaluate(), .needsGrant, "\(failure)")
            XCTAssertEqual(health.mountAppeared(), [], "\(failure)")
            XCTAssertEqual(health.evaluate(), .needsGrant, "\(failure)")

            health.mountDisappeared()
            XCTAssertEqual(health.evaluate(), .notConnected, "\(failure)")
            XCTAssertEqual(health.mountAppeared(), both, "\(failure)")

            // Each recovery resolves notAuthenticated only if it was used since the last one.
            health.failed(.serverUnreachable)
            clock.now += ShareHealth.probeInterval
            XCTAssertTrue(health.startProbe(), "\(failure)")
            XCTAssertEqual(health.probeFinished(succeeded: true), [.serverUnreachable], "\(failure)")
        }
    }

    func testAGrantThatFailsWhileUnresponsiveOrNotConnectedNeedsAGrant() {
        let clock = ManualClock()
        var health = connected(clock)
        health.failed(.serverUnreachable)
        clock.now += ShareHealth.probeInterval
        XCTAssertTrue(health.startProbe())
        health.failed(.notAuthenticated)
        XCTAssertEqual(health.evaluate(), .needsGrant)
        XCTAssertEqual(health.probeFinished(succeeded: true), [])
        XCTAssertEqual(health.evaluate(), .needsGrant)

        health.mountDisappeared()
        // A session that can't start for its grant needs one too.
        health.failed(.notAuthenticated)
        XCTAssertEqual(health.evaluate(), .needsGrant)
        health.failed(.notConnected)
        XCTAssertEqual(health.evaluate(), .notConnected)
        XCTAssertEqual(health.mountAppeared(), both)
        health.mountDisappeared()
        XCTAssertEqual(health.mountAppeared(), [.serverUnreachable])
    }

    func testAMountThatWentAwayIsNotConnectedNeverUnresponsive() {
        let gone: [SourceFailure] = [.classify(errno: ENOENT, context: .shareRoot),
                                     .classify(errno: ENOTDIR, context: .shareRoot), .notConnected]
        for failure in gone {
            let clock = ManualClock()
            var health = connected(clock)
            health.failed(failure)
            XCTAssertEqual(health.evaluate(), .notConnected, "\(failure)")
            // A probe can't bring it back; only the next mount can.
            clock.now += ShareHealth.probeInterval
            XCTAssertFalse(health.startProbe(), "\(failure)")
            health.failed(.serverUnreachable)
            XCTAssertEqual(health.evaluate(), .notConnected, "\(failure)")
            XCTAssertEqual(health.mountAppeared(), [.serverUnreachable], "\(failure)")

            health.failed(.serverUnreachable)
            clock.now += ShareHealth.probeInterval
            XCTAssertTrue(health.startProbe(), "\(failure)")
            health.failed(failure)
            XCTAssertEqual(health.evaluate(), .notConnected, "\(failure)")
            XCTAssertEqual(health.probeFinished(succeeded: true), [], "\(failure)")
            XCTAssertEqual(health.evaluate(), .notConnected, "\(failure)")
        }
    }

    func testOneProbeAtATimeEveryIntervalAndRecovery() {
        let clock = ManualClock()
        var health = connected(clock)
        let stuck = health.begin()
        health.failed(.serverUnreachable)
        XCTAssertFalse(health.startProbe())
        clock.now += ShareHealth.probeInterval
        XCTAssertTrue(health.startProbe())
        XCTAssertFalse(health.startProbe())
        clock.now += .seconds(30)
        XCTAssertFalse(health.startProbe())
        XCTAssertEqual(health.probeFinished(succeeded: false), [])
        XCTAssertEqual(health.evaluate(), .unresponsive)
        XCTAssertFalse(health.startProbe())
        clock.now += ShareHealth.probeInterval
        XCTAssertTrue(health.startProbe())
        XCTAssertEqual(health.probeFinished(succeeded: true), [.serverUnreachable])
        XCTAssertEqual(health.evaluate(), .connected)
        XCTAssertEqual(health.probeFinished(succeeded: true), [])

        // A call still blocked from before the outage doesn't make the share unresponsive again.
        clock.now += .seconds(60)
        XCTAssertEqual(health.evaluate(), .connected)
        health.end(stuck)
        XCTAssertFalse(health.startProbe())
    }

    func testAStartThatTimesOutIsUnresponsiveUntilAProbeStartsTheSession() {
        let clock = ManualClock()
        var health = ShareHealth(now: { clock.now })
        health.startFailed()
        XCTAssertEqual(health.refusal(), .serverUnreachable)
        XCTAssertFalse(health.startProbe())
        clock.now += ShareHealth.probeInterval
        XCTAssertTrue(health.startProbe())
        XCTAssertEqual(health.probeFinished(succeeded: false), [])
        clock.now += ShareHealth.probeInterval
        XCTAssertTrue(health.startProbe())
        // The probe's session start reports nothing; the probe's success recovers the share.
        XCTAssertEqual(health.mountAppeared(), [])
        XCTAssertEqual(health.probeFinished(succeeded: true), both)
        XCTAssertEqual(health.evaluate(), .connected)

        // Only a share that is not connected changes: a connected one has a session.
        health.startFailed()
        XCTAssertEqual(health.evaluate(), .connected)
        health.failed(.notAuthenticated)
        health.startFailed()
        XCTAssertEqual(health.evaluate(), .needsGrant)

        // A mount that goes away while a start is retried is not connected again.
        health.mountDisappeared()
        health.startFailed()
        health.mountDisappeared()
        XCTAssertEqual(health.evaluate(), .notConnected)
        XCTAssertNil(health.refusal())
    }

    func testMountEventsOverrideOtherStates() {
        let clock = ManualClock()
        var health = connected(clock)
        health.failed(.serverUnreachable)
        clock.now += ShareHealth.probeInterval
        XCTAssertTrue(health.startProbe())
        health.mountDisappeared()
        XCTAssertEqual(health.evaluate(), .notConnected)
        XCTAssertEqual(health.probeFinished(succeeded: true), [])
        XCTAssertEqual(health.evaluate(), .notConnected)

        clock.now += .seconds(60)
        XCTAssertFalse(health.startProbe())
        health.failed(.serverUnreachable)
        _ = health.begin()
        clock.now += .seconds(60)
        XCTAssertEqual(health.evaluate(), .notConnected)

        XCTAssertEqual(health.mountAppeared(), [.serverUnreachable])
        XCTAssertEqual(health.evaluate(), .connected)
        health.failed(.serverUnreachable)
        XCTAssertEqual(health.mountAppeared(), [])
        XCTAssertEqual(health.evaluate(), .unresponsive)
    }
}

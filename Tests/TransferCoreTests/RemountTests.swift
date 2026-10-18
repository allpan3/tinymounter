import Darwin
import Foundation
import XCTest
@testable import TransferCore

final class RemountPolicyTests: XCTestCase {
    private func wanted() -> RemountPolicy {
        var policy = RemountPolicy()
        policy.wanted = true
        return policy
    }

    func testShareWithoutLocationsIsNotMounted() {
        var policy = RemountPolicy()
        XCTAssertFalse(policy.startMount(now: .seconds(1)))
    }

    func testOneMountRunsAtATime() {
        var policy = wanted()
        XCTAssertTrue(policy.startMount(now: .seconds(1)))
        XCTAssertFalse(policy.startMount(now: .seconds(2)))
        XCTAssertEqual(policy.finished(status: 0, now: .seconds(3)), .mounted)
        XCTAssertTrue(policy.startMount(now: .seconds(4)))
    }

    func testAlreadyMountedCountsAsMounted() {
        var policy = wanted()
        _ = policy.startMount(now: .zero)
        XCTAssertEqual(policy.finished(status: EEXIST, now: .zero), .mounted)
    }

    func testNetworkFailuresWaitLongerUpToTheLimit() {
        var policy = wanted()
        var now = Duration.seconds(100)
        var delays: [Duration] = []
        for _ in 0..<7 {
            XCTAssertTrue(policy.startMount(now: now))
            guard case .retry(let delay) = policy.finished(status: ETIMEDOUT, now: now) else { return XCTFail() }
            delays.append(delay)
            XCTAssertFalse(policy.startMount(now: now + delay - .seconds(1)))
            now += delay
        }
        XCTAssertEqual(delays, [10, 20, 40, 80, 160, 300, 300].map { Duration.seconds($0) })
    }

    func testOtherFailureStopsUntilConditionsChange() {
        var policy = wanted()
        _ = policy.startMount(now: .zero)
        XCTAssertEqual(policy.finished(status: EAUTH, now: .zero), .stopped)
        XCTAssertFalse(policy.startMount(now: .seconds(3600)))
        policy.conditionsChanged()
        XCTAssertTrue(policy.startMount(now: .seconds(3601)))
    }

    func testConditionsChangeEndsTheWait() {
        var policy = wanted()
        _ = policy.startMount(now: .zero)
        _ = policy.finished(status: EHOSTUNREACH, now: .zero)
        XCTAssertFalse(policy.startMount(now: .seconds(1)))
        policy.conditionsChanged()
        XCTAssertTrue(policy.startMount(now: .seconds(1)))
    }

    func testEjectHoldsUntilTheShareIsMountedAgain() {
        var policy = wanted()
        policy.ejectStarted()
        XCTAssertFalse(policy.startMount(now: .seconds(1)))
        policy.conditionsChanged()
        XCTAssertFalse(policy.startMount(now: .seconds(2)))
        policy.mountListed()
        XCTAssertTrue(policy.startMount(now: .seconds(3)))
    }
}

import Foundation
import Testing
@testable import Wallstats

@Suite("Collector retry policy")
struct CollectorRetryPolicyTests {
    @Test("Immediate exits walk the backoff ladder and then exhaust")
    func immediateExitsExhaust() {
        var policy = CollectorRetryPolicy(
            delays: [.seconds(2), .seconds(5)],
            stableRun: .seconds(60)
        )
        #expect(policy.nextDelay(uptime: .milliseconds(300)) == .seconds(2))
        #expect(policy.attempt == 1)
        #expect(policy.nextDelay(uptime: .milliseconds(300)) == .seconds(5))
        #expect(policy.attempt == 2)
        #expect(policy.nextDelay(uptime: .milliseconds(300)) == nil)
    }

    @Test("A stable run restores the full budget before the next incident")
    func stableRunResets() {
        var policy = CollectorRetryPolicy(
            delays: [.seconds(2), .seconds(5)],
            stableRun: .seconds(60)
        )
        #expect(policy.nextDelay(uptime: .seconds(1)) == .seconds(2))
        #expect(policy.nextDelay(uptime: .seconds(1)) == .seconds(5))
        #expect(policy.nextDelay(uptime: .seconds(90)) == .seconds(2))
    }

    @Test("An unknown uptime consumes the budget without resetting it")
    func unknownUptimeNeverResets() {
        var policy = CollectorRetryPolicy(
            delays: [.seconds(2)],
            stableRun: .seconds(60)
        )
        #expect(policy.nextDelay(uptime: nil) == .seconds(2))
        #expect(policy.nextDelay(uptime: nil) == nil)
    }

    @Test("A manual reset restores the budget")
    func manualReset() {
        var policy = CollectorRetryPolicy(
            delays: [.seconds(2)],
            stableRun: .seconds(60)
        )
        #expect(policy.nextDelay(uptime: .seconds(1)) == .seconds(2))
        #expect(policy.nextDelay(uptime: .seconds(1)) == nil)
        policy.reset()
        #expect(policy.nextDelay(uptime: .seconds(1)) == .seconds(2))
    }

    @Test("The standard ladder outlasts a slow login-time Nix store mount")
    func standardLadderCoverage() {
        let total = CollectorRetryPolicy.standardDelays.reduce(Duration.zero, +)
        #expect(total >= .seconds(60))
        #expect(CollectorRetryPolicy.standardDelays.count >= 3)
    }
}

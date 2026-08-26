import Foundation

/// Decides whether a collector that exited unexpectedly should be relaunched.
///
/// The collector can die for transient environmental reasons — most notably a
/// login-time launch racing the mount of the Nix store volume its toolchain
/// lives on — so a short ladder of increasingly spaced attempts recovers
/// without a manual reload. A collector that keeps dying shortly after launch
/// is a real fault and still lands in the failed state, while one that ran
/// stably earns a fresh budget before its next incident.
struct CollectorRetryPolicy {
    static let standardDelays: [Duration] = [
        .seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(40),
    ]
    static let standardStableRun: Duration = .seconds(60)

    let delays: [Duration]
    let stableRun: Duration
    private(set) var attempt = 0

    init(
        delays: [Duration] = Self.standardDelays,
        stableRun: Duration = Self.standardStableRun
    ) {
        self.delays = delays
        self.stableRun = stableRun
    }

    var attemptsAllowed: Int {
        delays.count
    }

    /// Returns how long to wait before the next relaunch, or nil once the
    /// budget is exhausted. `uptime` is how long the exiting collector ran;
    /// a run at least as long as `stableRun` restores the full budget first.
    mutating func nextDelay(uptime: Duration?) -> Duration? {
        if let uptime, uptime >= stableRun {
            attempt = 0
        }
        guard attempt < delays.count else { return nil }
        defer { attempt += 1 }
        return delays[attempt]
    }

    mutating func reset() {
        attempt = 0
    }
}

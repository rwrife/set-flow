import Foundation

/// Pure, durable rest-timer state machine.
///
/// The timer never decrements a counter: it anchors to wall-clock endpoints
/// (`endsAt` / `pausedRemaining`), so a snapshot restored after a relaunch —
/// or a clock jump — resolves to the same phase and remaining time derived
/// from the anchor. Notification delivery is an app-layer concern layered on
/// top of `endsAt`; denial of notification permission never affects the
/// in-app countdown, which reads only these durable anchors.
public struct RestTimer: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, CaseIterable, Sendable {
        case idle
        case running
        case paused
        case finished
    }

    /// Wall-clock epoch at which the current run was started (resume re-anchors).
    public private(set) var startedAt: Timestamp?
    /// Wall-clock epoch at which the current run must fire.
    public private(set) var endsAt: Timestamp?
    /// Full duration of the current run, used to clamp rewound clocks.
    public private(set) var duration: TimeInterval?
    /// Wall-clock epoch of the last pause.
    public private(set) var pausedAt: Timestamp?
    /// Milliseconds left frozen at the pause anchor.
    public private(set) var pausedRemainingMilliseconds: Int64?

    public init() {}

    /// Rebuilds a timer from persisted anchors verbatim (restore path used by
    /// the store; mutations afterwards go through the phase methods).
    public init(
        startedAt: Timestamp?,
        endsAt: Timestamp?,
        duration: TimeInterval?,
        pausedAt: Timestamp?,
        pausedRemainingMilliseconds: Int64?
    ) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.duration = duration
        self.pausedAt = pausedAt
        self.pausedRemainingMilliseconds = pausedRemainingMilliseconds
    }

    public static let idle = RestTimer()

    public var isIdle: Bool { startedAt == nil && pausedAt == nil && endsAt == nil }

    /// Starts (or restarts) a rest period of `duration` seconds anchored at `now`.
    public mutating func start(duration: TimeInterval, at now: Timestamp) {
        precondition(duration.isFinite && duration >= 0, "RestTimer duration must be finite and non-negative")
        startedAt = now
        endsAt = Timestamp(millisecondsSinceUnixEpoch: now.millisecondsSinceUnixEpoch + Int64((duration * 1_000).rounded()))
        self.duration = duration
        pausedAt = nil
        pausedRemainingMilliseconds = nil
    }

    /// Freezes the remaining time against the durable `endsAt` anchor.
    /// No-op unless running or already finished-while-armed.
    public mutating func pause(at now: Timestamp) {
        guard startedAt != nil, pausedAt == nil else { return }
        let remaining = remainingMilliseconds(at: now)
        pausedAt = now
        pausedRemainingMilliseconds = remaining
        endsAt = nil
    }

    /// Re-anchors `endsAt` from the frozen pause remainder.
    /// No-op unless paused.
    public mutating func resume(at now: Timestamp) {
        guard pausedAt != nil, let remaining = pausedRemainingMilliseconds else { return }
        startedAt = now
        endsAt = Timestamp(millisecondsSinceUnixEpoch: now.millisecondsSinceUnixEpoch + remaining)
        self.duration = Double(remaining) / 1_000
        pausedAt = nil
        pausedRemainingMilliseconds = nil
    }

    /// Returns the timer to the idle state, clearing all anchors.
    public mutating func cancel() {
        startedAt = nil
        endsAt = nil
        duration = nil
        pausedAt = nil
        pausedRemainingMilliseconds = nil
    }

    /// Derives the phase purely from anchors and `now`.
    public func phase(at now: Timestamp) -> Phase {
        if pausedAt != nil { return .paused }
        if let endsAt { return now >= endsAt ? .finished : .running }
        if startedAt != nil { return .running }
        return .idle
    }

    /// Milliseconds until `endsAt`, clamped to [0, duration]. A clock rewound
    /// behind the anchor is clamped to the full duration rather than inflating.
    public func remainingMilliseconds(at now: Timestamp) -> Int64 {
        switch phase(at: now) {
        case .idle, .finished:
            return 0
        case .paused:
            return max(0, pausedRemainingMilliseconds ?? 0)
        case .running:
            guard let endsAt else { return 0 }
            var remaining = endsAt.millisecondsSinceUnixEpoch - now.millisecondsSinceUnixEpoch
            if let duration {
                remaining = min(remaining, Int64((duration * 1_000).rounded()))
            }
            return max(0, remaining)
        }
    }

    /// True exactly once the run has elapsed while still armed.
    public func hasEligibleFireDeadline(at now: Timestamp) -> Bool {
        phase(at: now) == .finished
    }
}

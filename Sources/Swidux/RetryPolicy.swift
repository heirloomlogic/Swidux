//
//  RetryPolicy.swift
//  Swidux
//
//  How many times, and how patiently, a failed persistence flush is retried
//  before the stack gives up and says so.
//

import Foundation

/// What a ``StateWriter`` flush did.
///
/// A flush that fails puts its batch back into the writer's pending buffers, so
/// ``FlushOutcome/failed`` means "not on disk yet, and still held" — never
/// "dropped".
public enum FlushOutcome: Sendable, Equatable {
    /// The batch reached storage. The writer holds nothing from it.
    case persisted
    /// The save threw. The batch is back in the writer's pending buffers.
    case failed
}

/// How ``PersistencePlugin`` retries a flush whose save failed.
///
/// Retrying matters because the buffers are cleared at flush time: without it a
/// failed save only ever reaches disk if the user happens to touch the same
/// entity again, which is silent data loss. Retrying *forever* matters just as
/// much in the other direction — a write that can never succeed (disk full, a
/// model the container can't encode, a schema mismatch) must not keep the stack
/// busy indefinitely. So attempts are bounded, and running out is an event the
/// app can see rather than a silence.
public struct RetryPolicy: Sendable, Equatable {
    /// Total attempts for one batch, including the first. `1` disables retrying.
    public var maxAttempts: Int

    /// The wait before the second attempt. Each further wait doubles it.
    public var baseDelay: Duration

    /// The ceiling on that doubling.
    public var maxDelay: Duration

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - maxAttempts: Total attempts per batch, including the first. Values
    ///     below `1` are treated as `1`.
    ///   - baseDelay: The wait before the second attempt.
    ///   - maxDelay: The ceiling the doubling backoff clamps to.
    public init(maxAttempts: Int, baseDelay: Duration, maxDelay: Duration) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Five attempts over roughly seven seconds, then give up: long enough to
    /// ride out a transient lock or a busy disk, short enough that a genuinely
    /// doomed write is reported while the user is still in the session that
    /// made it.
    public static let `default` = RetryPolicy(
        maxAttempts: 5, baseDelay: .milliseconds(500), maxDelay: .seconds(30))

    /// Never retry — the pre-1.9 behaviour, minus the silence: the batch is
    /// still held rather than dropped, and exhaustion is still reported.
    public static let never = RetryPolicy(
        maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)

    /// The wait before the attempt that follows `failures` consecutive failures.
    ///
    /// `failures` is 1-based: `1` is the wait before the second attempt.
    func delay(afterFailures failures: Int) -> Duration {
        guard failures > 1 else { return baseDelay }
        // The result is clamped to `maxDelay` anyway, so the shift only has to
        // reach past any plausible ceiling — 2^20 × a millisecond is already
        // weeks. Capping it keeps the multiply away from overflow no matter
        // what `maxAttempts` an app chooses.
        let doublings = min(failures - 1, 20)
        return min(baseDelay * (1 << doublings), maxDelay)
    }
}

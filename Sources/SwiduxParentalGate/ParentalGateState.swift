//
//  ParentalGateState.swift
//  SwiduxParentalGate
//

import Foundation
import Swidux

/// The state for a parental gate challenge flow.
///
/// Hosted in the app's root state via `@Slice var parentalGate: ParentalGateState`.
@Swidux
public nonisolated struct ParentalGateState: Sendable, Equatable {
    /// Reason the sheet is currently gating, or `nil` when no gate is active.
    public var pendingReason: String? = nil
    /// Currently-presented math challenge, or `nil`.
    public var challenge: MathChallenge? = nil
    /// Number of incorrect attempts against the current challenge.
    public var attempts: Int = 0
    /// Reasons already passed this session.
    public var passedReasons: Set<String> = []
    /// Answers are refused until this time; `nil` when not in cooldown.
    ///
    /// Set after too many wrong answers in a row. Survives `.dismiss` and
    /// `.request` so the gate can't be reset by reopening it. Host UIs should
    /// disable the submit control and show a countdown while non-`nil`.
    public var cooldownUntil: Date? = nil

    /// Creates a parental-gate state with default values.
    ///
    /// - Parameters:
    ///   - pendingReason: Reason currently gating, or `nil`.
    ///   - challenge: Currently-presented challenge, or `nil`.
    ///   - attempts: Incorrect attempts against the current challenge.
    ///   - passedReasons: Reasons already passed this session.
    ///   - cooldownUntil: Time until which answers are refused, or `nil`.
    public init(
        pendingReason: String? = nil,
        challenge: MathChallenge? = nil,
        attempts: Int = 0,
        passedReasons: Set<String> = [],
        cooldownUntil: Date? = nil
    ) {
        self.pendingReason = pendingReason
        self.challenge = challenge
        self.attempts = attempts
        self.passedReasons = passedReasons
        self.cooldownUntil = cooldownUntil
    }

    /// Builds an initial state carrying the attempt count and cooldown that
    /// ``ParentalGatePlugin`` persisted to `store`.
    ///
    /// Pass the same store to the plugin's `keyValueStore:`. Everything else —
    /// the pending gate, the challenge, `passedReasons` — starts fresh; only
    /// the rate limit outlives the process. A persisted cooldown is re-armed
    /// the next time the gate is requested.
    public static func hydrated(from store: any KeyValueStore) -> ParentalGateState {
        guard let lockout = store.value(.parentalGateLockout) else { return ParentalGateState() }
        return ParentalGateState(attempts: max(0, lockout.attempts), cooldownUntil: lockout.cooldownUntil)
    }
}

/// The part of the gate that has to outlive the process: without it,
/// swiping the app away resets the attempt limit.
struct ParentalGateLockout: Codable, Equatable, Sendable {
    var attempts: Int
    var cooldownUntil: Date?

    init(_ state: ParentalGateState) {
        attempts = state.attempts
        cooldownUntil = state.cooldownUntil
    }
}

extension KVKey where Value == ParentalGateLockout {
    /// The persisted attempt count and cooldown deadline.
    static let parentalGateLockout = KVKey<ParentalGateLockout>("swidux.parentalGate.lockout")
}

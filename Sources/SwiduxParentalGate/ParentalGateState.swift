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
}

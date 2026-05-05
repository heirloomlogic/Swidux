//
//  ParentalGateState.swift
//  SwiduxParentalGate
//

/// The state for a parental gate challenge flow.
public struct ParentalGateState: Sendable, Equatable {
    /// Reason the sheet is currently gating, or `nil` when no gate is active.
    public var pendingReason: String?
    /// Currently-presented math challenge, or `nil`.
    public var challenge: MathChallenge?
    /// Number of incorrect attempts against the current challenge.
    public var attempts: Int
    /// Reasons already passed this session.
    public var passedReasons: Set<String>

    /// Creates a parental-gate state with default values.
    public init(
        pendingReason: String? = nil,
        challenge: MathChallenge? = nil,
        attempts: Int = 0,
        passedReasons: Set<String> = []
    ) {
        self.pendingReason = pendingReason
        self.challenge = challenge
        self.attempts = attempts
        self.passedReasons = passedReasons
    }
}

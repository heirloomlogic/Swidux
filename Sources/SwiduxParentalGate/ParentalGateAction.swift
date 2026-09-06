//
//  ParentalGateAction.swift
//  SwiduxParentalGate
//

/// Actions for the parental gate challenge flow.
public enum ParentalGateAction: Sendable {
    /// Present the gate for the given reason. If the reason has already been
    /// passed this session, dispatches `.answerAccepted` immediately instead.
    case request(reason: String)
    /// Dismiss the active gate without changing pass status.
    case dismiss
    /// Replace the current challenge with a fresh one from the challenge source.
    case regenerateChallenge
    /// Validate the supplied answer against the current challenge.
    case submitAnswer(Int)
    /// Notification that the reason has already been validated and added to `passedReasons`.
    case answerAccepted(reason: String)
    /// Notification that a wrong answer has already been counted.
    /// Reaching the attempt limit starts a cooldown synchronously on submission.
    case answerRejected
    /// The cooldown window elapsed; answers are accepted again.
    case cooldownExpired
}

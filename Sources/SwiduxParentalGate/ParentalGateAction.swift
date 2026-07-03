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
    /// The challenge was passed for the given reason; reason is added to `passedReasons`.
    case answerAccepted(reason: String)
    /// The submitted answer was wrong; `attempts` increments and a new challenge generates.
    /// Reaching the plugin's attempt limit starts a cooldown instead.
    case answerRejected
    /// The cooldown window elapsed; answers are accepted again.
    case cooldownExpired
}

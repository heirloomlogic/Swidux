//
//  ParentalGateAction.swift
//  SwiduxParentalGate
//

/// Actions for the parental gate challenge flow.
public enum ParentalGateAction: Sendable {
    case request(reason: String)
    case dismiss
    case regenerateChallenge
    case submitAnswer(Int)
    case answerAccepted(reason: String)
    case answerRejected
}

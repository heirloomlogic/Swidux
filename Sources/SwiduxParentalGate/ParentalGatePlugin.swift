//
//  ParentalGatePlugin.swift
//  SwiduxParentalGate
//

import Swidux

/// A Swidux plugin that guards actions behind a math challenge.
@MainActor
public struct ParentalGatePlugin<RootState, RootAction>: SwiduxPlugin {
    /// Root state type of the host app.
    public typealias State = RootState
    /// Root action type of the host app.
    public typealias Action = RootAction

    private let stateKeyPath: WritableKeyPath<RootState, ParentalGateState>
    private let toRootAction: @Sendable (ParentalGateAction) -> RootAction
    private let extractAction: @Sendable (RootAction) -> ParentalGateAction?
    private let challengeSource: ParentalChallengeSource

    /// Creates a parental-gate plugin wired into the host app.
    public init(
        state: WritableKeyPath<RootState, ParentalGateState>,
        action toRootAction: @escaping @Sendable (ParentalGateAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> ParentalGateAction?,
        challengeSource: ParentalChallengeSource = .standard
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.challengeSource = challengeSource
    }

    /// Routes parental-gate actions and returns effects for async work.
    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        let localEffect = reduceLocal(state: &state[keyPath: stateKeyPath], action: local)
        guard let localEffect else { return nil }
        let lift = toRootAction
        return { send in
            await localEffect { localAction in
                send(lift(localAction))
            }
        }
    }

    private func reduceLocal(
        state: inout ParentalGateState,
        action: ParentalGateAction
    ) -> Effect<ParentalGateAction>? {
        switch action {
        case .request(let reason):
            if state.passedReasons.contains(reason) {
                return { send in await send(.answerAccepted(reason: reason)) }
            }
            state.pendingReason = reason
            state.challenge = challengeSource.generate()
            state.attempts = 0

        case .dismiss:
            state.pendingReason = nil
            state.challenge = nil
            state.attempts = 0

        case .regenerateChallenge:
            state.challenge = challengeSource.generate()

        case .submitAnswer(let answer):
            guard let challenge = state.challenge, let reason = state.pendingReason else { return nil }
            guard answer == challenge.expected else {
                return { send in await send(.answerRejected) }
            }
            return { send in await send(.answerAccepted(reason: reason)) }

        case .answerAccepted(let reason):
            state.passedReasons.insert(reason)
            state.pendingReason = nil
            state.challenge = nil
            state.attempts = 0

        case .answerRejected:
            state.attempts += 1
            state.challenge = challengeSource.generate()
        }
        return nil
    }
}

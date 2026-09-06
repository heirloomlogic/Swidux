//
//  ParentalGatePlugin.swift
//  SwiduxParentalGate
//

import Foundation
import Swidux

/// A Swidux plugin that guards actions behind a math challenge.
///
/// Wrong answers are limited: after `attemptLimit` consecutive rejections the
/// gate enters a cooldown during which `.submitAnswer` is ignored — even with
/// the correct answer — and `.dismiss`/`.request` don't reset it. Host UIs
/// should disable the submit control and show a countdown while
/// ``ParentalGateState/cooldownUntil`` is non-`nil`.
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
    private let attemptLimit: Int
    private let cooldown: Duration
    private let now: @Sendable () -> Date

    /// Creates a parental-gate plugin wired into the host app.
    ///
    /// - Parameters:
    ///   - state: Key path to the ``ParentalGateState`` slice on the root state.
    ///   - toRootAction: Lifts a local gate action into the root action type.
    ///   - extractAction: Extracts a gate action from a root action, or `nil`.
    ///   - challengeSource: Source of math challenges; defaults to `.standard`.
    ///   - attemptLimit: Consecutive wrong answers before a cooldown starts.
    ///   - cooldown: How long answers are refused after the limit is reached.
    ///   - now: Clock read used for cooldown checks; injectable for tests.
    public init(
        state: WritableKeyPath<RootState, ParentalGateState>,
        action toRootAction: @escaping @Sendable (ParentalGateAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> ParentalGateAction?,
        challengeSource: ParentalChallengeSource = .standard,
        attemptLimit: Int = 3,
        cooldown: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.challengeSource = challengeSource
        self.attemptLimit = max(1, attemptLimit)
        self.cooldown = max(.zero, cooldown)
        self.now = now
    }

    /// Routes parental-gate actions and returns effects for async work.
    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        let localEffect = reduceLocal(state: &state[keyPath: stateKeyPath], action: local)
        guard let localEffect else { return nil }
        return localEffect.map(toRootAction)
    }

    private func reduceLocal(
        state: inout ParentalGateState,
        action: ParentalGateAction
    ) -> Effect<ParentalGateAction>? {
        switch action {
        case .request(let reason):
            if state.passedReasons.contains(reason) {
                return Effect { send in await send(.answerAccepted(reason: reason)) }
            }
            state.pendingReason = reason
            state.challenge = challengeSource.generate()

        case .dismiss:
            state.pendingReason = nil
            state.challenge = nil

        case .regenerateChallenge:
            guard state.pendingReason != nil else { return nil }
            state.challenge = challengeSource.generate()

        case .submitAnswer(let answer):
            if let until = state.cooldownUntil {
                // Answers are refused during cooldown — even correct ones —
                // so the limit can't be raced. `.cooldownExpired` clears it.
                guard now() >= until else { return nil }
                state.cooldownUntil = nil
            }
            guard let challenge = state.challenge, let reason = state.pendingReason else { return nil }
            if answer == challenge.expected {
                state.passedReasons.insert(reason)
                state.pendingReason = nil
                state.challenge = nil
                state.attempts = 0
                return Effect { send in await send(.answerAccepted(reason: reason)) }
            }

            // Commit the attempt synchronously. A delayed notification must
            // neither validate a different challenge nor bypass the limit.
            state.attempts += 1
            state.challenge = challengeSource.generate()
            let reachedLimit = state.attempts >= attemptLimit
            if reachedLimit {
                state.attempts = 0
                state.cooldownUntil = now().addingTimeInterval(cooldownInterval)
            }
            let cooldown = self.cooldown
            return Effect { send in
                await send(.answerRejected)
                if reachedLimit {
                    try await Task.sleep(for: cooldown)
                    await send(.cooldownExpired)
                }
            }

        case .answerAccepted, .answerRejected:
            // Notifications for the host, not commands that can mutate a newer
            // challenge or grant a reason that was never validated.
            break

        case .cooldownExpired:
            guard let until = state.cooldownUntil, now() >= until else { return nil }
            state.cooldownUntil = nil
            if state.pendingReason != nil { state.challenge = challengeSource.generate() }
        }
        return nil
    }

    private var cooldownInterval: TimeInterval {
        TimeInterval(cooldown.components.seconds)
            + TimeInterval(cooldown.components.attoseconds) * 1e-18
    }
}

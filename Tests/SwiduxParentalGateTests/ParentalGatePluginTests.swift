//
//  ParentalGatePluginTests.swift
//  SwiduxParentalGateTests
//
//  Tests for the ParentalGatePlugin reducer.
//

import Foundation
import Swidux
import Testing

@testable import SwiduxParentalGate

@Suite("ParentalGatePlugin")
@MainActor
struct ParentalGatePluginTests {
    struct TestState: Sendable, Equatable {
        var parental = ParentalGateState()
    }

    enum TestAction: Sendable {
        case parental(ParentalGateAction)
        case unrelated
    }

    let fixedChallenge = MathChallenge(left: 2, right: 3, op: .plus)  // expected = 5

    func makePlugin(
        attemptLimit: Int = 3,
        cooldown: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ParentalGatePlugin<TestState, TestAction> {
        ParentalGatePlugin(
            state: \.parental,
            action: TestAction.parental,
            extractAction: {
                if case .parental(let a) = $0 { return a }
                return nil
            },
            challengeSource: .fixed(fixedChallenge),
            attemptLimit: attemptLimit,
            cooldown: cooldown,
            now: now
        )
    }

    @Test("request sets pending reason and generates challenge")
    func requestSetsPendingReasonAndChallenge() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .parental(.request(reason: "settings"))
        )
        #expect(effect == nil)
        #expect(state.parental.pendingReason == "settings")
        #expect(state.parental.challenge == fixedChallenge)
        #expect(state.parental.attempts == 0)
    }

    @Test("dismiss clears state")
    func dismissClearsState() {
        let plugin = makePlugin()
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge
        state.parental.attempts = 2

        let effect = plugin.reduce(
            state: &state,
            action: .parental(.dismiss)
        )
        #expect(effect == nil)
        #expect(state.parental.pendingReason == nil)
        #expect(state.parental.challenge == nil)
        #expect(state.parental.attempts == 2)
    }

    @Test("correct answer returns answerAccepted effect")
    func correctAnswerReturnsAcceptedEffect() {
        let plugin = makePlugin()
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge

        let effect = plugin.reduce(
            state: &state,
            action: .parental(.submitAnswer(5))
        )
        #expect(effect != nil)
    }

    @Test("wrong answer returns answerRejected effect")
    func wrongAnswerReturnsRejectedEffect() {
        let plugin = makePlugin()
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge

        let effect = plugin.reduce(
            state: &state,
            action: .parental(.submitAnswer(99))
        )
        #expect(effect != nil)
    }

    @Test("a correct submission marks the reason as passed synchronously")
    func correctSubmissionMarksReasonPassed() {
        let plugin = makePlugin()
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge

        let effect = plugin.reduce(
            state: &state,
            action: .parental(.submitAnswer(5))
        )
        #expect(effect != nil)
        #expect(state.parental.passedReasons.contains("settings"))
        #expect(state.parental.pendingReason == nil)
        #expect(state.parental.challenge == nil)
    }

    @Test("already-passed reason dispatches immediate accept")
    func alreadyPassedReasonDispatchesImmediateAccept() {
        let plugin = makePlugin()
        var state = TestState()
        state.parental.passedReasons = ["settings"]

        let effect = plugin.reduce(
            state: &state,
            action: .parental(.request(reason: "settings"))
        )
        #expect(effect != nil)
        // State should not have been set to pending since it's already passed
        #expect(state.parental.pendingReason == nil)
    }

    // MARK: - Cooldown

    @Test("reaching the attempt limit starts a cooldown and resets attempts")
    func attemptLimitStartsCooldown() {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let plugin = makePlugin(attemptLimit: 3, cooldown: .seconds(30), now: { fixedNow })
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge
        state.parental.attempts = 2

        let effect = plugin.reduce(state: &state, action: .parental(.submitAnswer(99)))

        #expect(state.parental.cooldownUntil == fixedNow.addingTimeInterval(30))
        #expect(state.parental.attempts == 0)
        #expect(effect != nil, "a cooldown-expiry effect should be scheduled")
    }

    @Test("below the attempt limit no cooldown starts")
    func belowLimitNoCooldown() {
        let plugin = makePlugin(attemptLimit: 3)
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge

        let effect = plugin.reduce(state: &state, action: .parental(.submitAnswer(99)))

        #expect(state.parental.cooldownUntil == nil)
        #expect(state.parental.attempts == 1)
        #expect(effect != nil)
    }

    @Test("answers are refused during cooldown — even correct ones")
    func answersRefusedDuringCooldown() {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let plugin = makePlugin(now: { fixedNow })
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge
        state.parental.cooldownUntil = fixedNow.addingTimeInterval(10)
        let before = state.parental

        let effect = plugin.reduce(state: &state, action: .parental(.submitAnswer(5)))

        #expect(effect == nil)
        #expect(state.parental == before)
    }

    @Test("an elapsed cooldown clears on submit and the answer is evaluated")
    func elapsedCooldownClearsOnSubmit() {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let plugin = makePlugin(now: { fixedNow })
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge
        state.parental.cooldownUntil = fixedNow.addingTimeInterval(-1)

        let effect = plugin.reduce(state: &state, action: .parental(.submitAnswer(5)))

        #expect(state.parental.cooldownUntil == nil)
        #expect(effect != nil, "the correct answer should dispatch answerAccepted")
    }

    @Test("dismiss and re-request do not reset the cooldown")
    func dismissAndRequestPreserveCooldown() {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let until = fixedNow.addingTimeInterval(10)
        let plugin = makePlugin(now: { fixedNow })
        var state = TestState()
        state.parental.cooldownUntil = until

        _ = plugin.reduce(state: &state, action: .parental(.dismiss))
        #expect(state.parental.cooldownUntil == until)

        _ = plugin.reduce(state: &state, action: .parental(.request(reason: "settings")))
        #expect(state.parental.cooldownUntil == until)
    }

    @Test("cooldownExpired clears the cooldown and issues a fresh challenge")
    func cooldownExpiredClearsAndRegenerates() {
        let plugin = makePlugin()
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.cooldownUntil = Date()
        state.parental.challenge = nil

        let effect = plugin.reduce(state: &state, action: .parental(.cooldownExpired))

        #expect(effect == nil)
        #expect(state.parental.cooldownUntil == nil)
        #expect(state.parental.challenge == fixedChallenge)
    }

    @Test("the cooldown effect dispatches cooldownExpired after the window")
    func cooldownEffectDispatchesExpiry() async throws {
        let plugin = makePlugin(attemptLimit: 1, cooldown: .milliseconds(20))
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge

        let effect = plugin.reduce(state: &state, action: .parental(.submitAnswer(99)))
        let effectValue = try #require(effect)

        var dispatched: [TestAction] = []
        try await effectValue { action in dispatched.append(action) }

        guard case .parental(.cooldownExpired) = dispatched.last else {
            Issue.record("expected cooldownExpired, got \(dispatched)")
            return
        }
    }

    @Test("MathChallenge computes correct expected value for plus/minus/times")
    func mathChallengeExpectedValues() {
        let plus = MathChallenge(left: 10, right: 5, op: .plus)
        #expect(plus.expected == 15)

        let minus = MathChallenge(left: 10, right: 5, op: .minus)
        #expect(minus.expected == 5)

        let times = MathChallenge(left: 10, right: 5, op: .times)
        #expect(times.expected == 50)
    }

    @Test("the standard source never produces a negative or trivial answer")
    func standardSourceProducesReasonableChallenges() {
        for _ in 0..<200 {
            let challenge = ParentalChallengeSource.standard.generate()
            #expect(challenge.expected > 0, "\(challenge.left) \(challenge.op) \(challenge.right)")
            #expect(challenge.left > 0)
            #expect(challenge.right > 0)
        }
    }
}

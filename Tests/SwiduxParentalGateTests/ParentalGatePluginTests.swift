//
//  ParentalGatePluginTests.swift
//  SwiduxParentalGateTests
//
//  Tests for the ParentalGatePlugin reducer.
//

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

    func makePlugin() -> ParentalGatePlugin<TestState, TestAction> {
        ParentalGatePlugin(
            state: \.parental,
            action: TestAction.parental,
            extractAction: {
                if case .parental(let a) = $0 { return a }
                return nil
            },
            challengeSource: .fixed(fixedChallenge)
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
        #expect(state.parental.attempts == 0)
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

    @Test("answerAccepted marks reason as passed")
    func answerAcceptedMarksReasonPassed() {
        let plugin = makePlugin()
        var state = TestState()
        state.parental.pendingReason = "settings"
        state.parental.challenge = fixedChallenge

        let effect = plugin.reduce(
            state: &state,
            action: .parental(.answerAccepted(reason: "settings"))
        )
        #expect(effect == nil)
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

    @Test("MathChallenge computes correct expected value for plus/minus/times")
    func mathChallengeExpectedValues() {
        let plus = MathChallenge(left: 10, right: 5, op: .plus)
        #expect(plus.expected == 15)

        let minus = MathChallenge(left: 10, right: 5, op: .minus)
        #expect(minus.expected == 5)

        let times = MathChallenge(left: 10, right: 5, op: .times)
        #expect(times.expected == 50)
    }
}

import Foundation
import Testing

@testable import SwiduxParentalGate

extension ParentalGatePluginTests {
    @Test("Rapid wrong answers consume the limit before their notifications run")
    func rapidSubmissionsAreCountedSynchronously() {
        let now = Date()
        let plugin = makePlugin(attemptLimit: 2, now: { now })
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .parental(.request(reason: "settings")))
        _ = plugin.reduce(state: &state, action: .parental(.submitAnswer(99)))
        _ = plugin.reduce(state: &state, action: .parental(.dismiss))
        _ = plugin.reduce(state: &state, action: .parental(.request(reason: "settings")))
        _ = plugin.reduce(state: &state, action: .parental(.submitAnswer(99)))
        #expect(state.parental.cooldownUntil == now.addingTimeInterval(30))
        #expect(plugin.reduce(state: &state, action: .parental(.submitAnswer(5))) == nil)
        #expect(state.parental.passedReasons.isEmpty)
    }

    @Test("Delayed notifications cannot mutate a newer gate or expire its cooldown")
    func staleNotificationsDoNotChangeGate() {
        let now = Date()
        let plugin = makePlugin(now: { now })
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .parental(.request(reason: "new")))
        state.parental.cooldownUntil = now.addingTimeInterval(30)
        let before = state.parental
        _ = plugin.reduce(state: &state, action: .parental(.answerAccepted(reason: "old")))
        _ = plugin.reduce(state: &state, action: .parental(.answerRejected))
        _ = plugin.reduce(state: &state, action: .parental(.cooldownExpired))
        #expect(state.parental == before)
    }
}

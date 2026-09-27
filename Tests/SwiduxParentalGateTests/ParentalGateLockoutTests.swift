//
//  ParentalGateLockoutTests.swift
//  SwiduxParentalGateTests
//
//  The attempt limit has to hold across the two things a child can reach
//  without solving anything: the app switcher and the device clock.
//

import Foundation
import Swidux
import Synchronization
import Testing

@testable import SwiduxParentalGate

/// A wall clock the test can move, the way Settings > Date & Time can.
private final class MovableClock: Sendable {
    private let date: Mutex<Date>

    init(_ start: Date) { date = Mutex(start) }

    var now: Date { date.withLock { $0 } }

    func move(by interval: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

extension ParentalGatePluginTests {
    // MARK: - Relaunch

    @Test("attempts and the cooldown survive a relaunch when a store is supplied")
    func lockoutSurvivesRelaunch() async throws {
        let kv = InMemoryKeyValueStore()
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let plugin = makePlugin(attemptLimit: 2, now: { fixedNow }, keyValueStore: kv)
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .parental(.request(reason: "purchase")))

        let wrong = try #require(plugin.reduce(state: &state, action: .parental(.submitAnswer(99))))
        try await wrong { _ in }
        #expect(ParentalGateState.hydrated(from: kv).attempts == 1)

        // The limit's effect sleeps out the cooldown; the write comes first.
        let limit = try #require(plugin.reduce(state: &state, action: .parental(.submitAnswer(99))))
        let running = Task { try await limit { _ in } }
        for _ in 0..<400 where ParentalGateState.hydrated(from: kv).cooldownUntil == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        running.cancel()

        // Swiping the app away used to hand back a fresh set of guesses.
        var relaunched = TestState(parental: .hydrated(from: kv))
        #expect(relaunched.parental.cooldownUntil == fixedNow.addingTimeInterval(30))
        let fresh = makePlugin(attemptLimit: 2, now: { fixedNow }, keyValueStore: kv)
        _ = fresh.reduce(state: &relaunched, action: .parental(.request(reason: "purchase")))
        _ = fresh.reduce(state: &relaunched, action: .parental(.submitAnswer(5)))
        #expect(relaunched.parental.passedReasons.isEmpty)
    }

    @Test("without a store the limit is per process: nothing is written")
    func noStoreMeansPerProcessLimit() {
        let plugin = makePlugin(attemptLimit: 1)
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .parental(.request(reason: "purchase")))
        _ = plugin.reduce(state: &state, action: .parental(.submitAnswer(99)))

        #expect(state.parental.cooldownUntil != nil)
        #expect(ParentalGateState.hydrated(from: InMemoryKeyValueStore()) == ParentalGateState())
    }

    @Test("a hydrated cooldown is held to one cooldown and re-armed when the gate is next requested")
    func hydratedCooldownIsRearmed() async throws {
        let plugin = makePlugin(cooldown: .milliseconds(50))
        // A deadline from a previous process, set far ahead — by a clock that
        // has since moved back, or by an edited store. Nothing in this process
        // armed its expiry, and a host that disables Submit during a cooldown
        // would wait on it forever.
        var state = TestState(parental: ParentalGateState(cooldownUntil: Date(timeIntervalSinceNow: 86_400)))

        let rearm = try #require(plugin.reduce(state: &state, action: .parental(.request(reason: "purchase"))))
        #expect(try #require(state.parental.cooldownUntil) <= Date(timeIntervalSinceNow: 1))

        var expired = false
        try await rearm { action in
            if case .parental(.cooldownExpired) = action { expired = true }
            _ = plugin.reduce(state: &state, action: action)
        }
        #expect(expired)
        #expect(state.parental.cooldownUntil == nil)
    }

    // MARK: - Wall clock

    @Test("moving the clock forward does not skip the cooldown")
    func clockForwardDoesNotSkipCooldown() {
        let clock = MovableClock(Date(timeIntervalSince1970: 1_000_000))
        let plugin = makePlugin(attemptLimit: 1, now: { clock.now })
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .parental(.request(reason: "purchase")))
        _ = plugin.reduce(state: &state, action: .parental(.submitAnswer(99)))

        clock.move(by: 3_600)
        _ = plugin.reduce(state: &state, action: .parental(.submitAnswer(5)))

        #expect(state.parental.passedReasons.isEmpty)
        #expect(state.parental.cooldownUntil != nil)
    }

    @Test("moving the clock back does not leave the gate locked past the cooldown")
    func clockBackDoesNotExtendCooldown() async throws {
        let clock = MovableClock(Date(timeIntervalSince1970: 1_000_000))
        let plugin = makePlugin(attemptLimit: 1, cooldown: .milliseconds(50), now: { clock.now })
        var state = TestState()
        _ = plugin.reduce(state: &state, action: .parental(.request(reason: "purchase")))
        let limit = try #require(plugin.reduce(state: &state, action: .parental(.submitAnswer(99))))

        // An NTP correction lands mid-cooldown. The expiry still fires on
        // time; it must not be refused because the wall clock now reads an
        // hour before the deadline, with nothing left to send it again.
        clock.move(by: -3_600)
        try await limit { action in _ = plugin.reduce(state: &state, action: action) }

        #expect(state.parental.cooldownUntil == nil)
    }
}

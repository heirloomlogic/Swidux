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

/// A key-value store whose first write is slow — a Keychain `SecItemAdd` →
/// `errSecDuplicateItem` → `SecItemUpdate` under load — so a later write can
/// overtake it.
private final class SlowFirstWriteStore: KeyValueStore {
    private let backing = InMemoryKeyValueStore()
    private let writes = Mutex(0)
    private let landed = Mutex(0)

    /// Writes that have finished, slow one included.
    var completedWrites: Int { landed.withLock { $0 } }

    func value<Value>(_ key: KVKey<Value>) -> Value? { backing.value(key) }

    @discardableResult
    func setValue<Value>(_ value: Value?, for key: KVKey<Value>) -> Bool {
        let index = writes.withLock { count in
            count += 1
            return count
        }
        if index == 1 { Thread.sleep(forTimeInterval: 0.15) }
        defer { landed.withLock { $0 += 1 } }
        return backing.setValue(value, for: key)
    }

    @discardableResult
    func removeValue<Value>(for key: KVKey<Value>) -> Bool { backing.removeValue(for: key) }

    func contains<Value>(_ key: KVKey<Value>) -> Bool { backing.contains(key) }
}

/// A store root for the one test that needs the real effect runner: `Store`
/// runs every effect in its own task, which is what lets writes race.
@Swidux
nonisolated struct LockoutStoreRoot: Equatable, Sendable {
    @Slice var parentalGate: ParentalGateState = .init()
}

enum LockoutStoreAction: Sendable {
    case gate(ParentalGateAction)
}

@Suite("ParentalGate lockout persistence under the store")
@MainActor
struct ParentalGateLockoutStoreTests {
    @Test("the persisted lockout ends up matching state, whatever order the writes run in")
    func persistedLockoutFollowsDispatchOrder() async throws {
        let kv = SlowFirstWriteStore()
        let plugin = ParentalGatePlugin<LockoutStoreRoot, LockoutStoreAction>(
            state: \.parentalGate,
            action: LockoutStoreAction.gate,
            extractAction: { if case .gate(let a) = $0 { a } else { nil } },
            challengeSource: .fixed(MathChallenge(left: 2, right: 3, op: .plus)),
            attemptLimit: 2,
            keyValueStore: kv
        )
        let host = PluginHost<LockoutStoreRoot, LockoutStoreAction>()
        host.register(plugin)
        let store = Store(initialState: LockoutStoreRoot(), reducer: { _, _ in nil }, plugins: host)
        defer { store.cancelEffects() }

        store.send(.gate(.request(reason: "purchase")))
        store.send(.gate(.submitAnswer(99)))  // attempts 1, no cooldown — the slow write
        store.send(.gate(.submitAnswer(99)))  // the limit: attempts 0, cooldown
        let live = store.parentalGate.cooldownUntil
        #expect(live != nil)

        // What a relaunch would hydrate. Each change's write is its own
        // effect; if the slow first one lands last, the store says "one wrong
        // answer, no cooldown" and a force-quit hands back fresh guesses.
        for _ in 0..<400 where kv.completedWrites < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(kv.completedWrites >= 2)
        let relaunched = ParentalGateState.hydrated(from: kv)
        #expect(relaunched.cooldownUntil == live)
        #expect(relaunched.attempts == 0)
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

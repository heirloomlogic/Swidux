//
//  ParentalGatePlugin.swift
//  SwiduxParentalGate
//

import Foundation
import Swidux
import Synchronization

/// A Swidux plugin that guards actions behind a math challenge.
///
/// Wrong answers are limited: after `attemptLimit` consecutive rejections the
/// gate enters a cooldown during which `.submitAnswer` is ignored — even with
/// the correct answer — and `.dismiss`/`.request` don't reset it. Host UIs
/// should disable the submit control and show a countdown while
/// ``ParentalGateState/cooldownUntil`` is non-`nil`; the plugin always
/// delivers `.cooldownExpired` to clear it, re-arming the timer on every
/// `.request` made during a cooldown.
///
/// The limit is per process unless you pass a `keyValueStore`: without one,
/// force-quitting the app starts the next launch with no attempts counted and
/// no cooldown. With one, hydrate the slice from the same store with
/// ``ParentalGateState/hydrated(from:)``.
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
    private let lockoutWriter: LockoutWriter?
    private let cooldownClock = CooldownClock()

    /// Creates a parental-gate plugin wired into the host app.
    ///
    /// - Parameters:
    ///   - state: Key path to the ``ParentalGateState`` slice on the root state.
    ///   - toRootAction: Lifts a local gate action into the root action type.
    ///   - extractAction: Extracts a gate action from a root action, or `nil`.
    ///   - challengeSource: Source of math challenges; defaults to `.standard`.
    ///   - attemptLimit: Consecutive wrong answers before a cooldown starts.
    ///   - cooldown: How long answers are refused after the limit is reached.
    ///   - now: Wall-clock read that stamps ``ParentalGateState/cooldownUntil``;
    ///     injectable for tests. Once this process has seen a deadline, its
    ///     expiry runs on the monotonic clock, so moving the device clock
    ///     neither skips nor extends it.
    ///   - keyValueStore: Where the attempt count and cooldown are persisted so
    ///     they survive a relaunch, or `nil` to keep them in memory only.
    public init(
        state: WritableKeyPath<RootState, ParentalGateState>,
        action toRootAction: @escaping @Sendable (ParentalGateAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> ParentalGateAction?,
        challengeSource: ParentalChallengeSource = .standard,
        attemptLimit: Int = 3,
        cooldown: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() },
        keyValueStore: (any KeyValueStore)? = nil
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.challengeSource = challengeSource
        self.attemptLimit = max(1, attemptLimit)
        self.cooldown = max(.zero, cooldown)
        self.now = now
        self.lockoutWriter = keyValueStore.map(LockoutWriter.init)
    }

    /// Routes parental-gate actions and returns effects for async work.
    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        let before = ParentalGateLockout(state[keyPath: stateKeyPath])
        let lifted = reduceLocal(state: &state[keyPath: stateKeyPath], action: local)?.map(toRootAction)
        let after = ParentalGateLockout(state[keyPath: stateKeyPath])
        guard let lockoutWriter, after != before else { return lifted }
        lockoutWriter.stage(after)
        // Written before anything else the effect does: the limit's effect
        // then sleeps out the cooldown, and a force-quit mid-sleep is exactly
        // what the write has to survive.
        return Effect { send in
            lockoutWriter.flush()
            try await lifted?(send)
        }
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
            // A cooldown may have nothing counting it down: hydrated from a
            // previous launch, or its effect cancelled with the scene. Re-arm
            // it, so a host that disables Submit until `.cooldownExpired`
            // can't wait forever.
            guard let deadline = cooldownDeadline(&state) else { return nil }
            return expiry(at: deadline)

        case .dismiss:
            state.pendingReason = nil
            state.challenge = nil

        case .regenerateChallenge:
            guard state.pendingReason != nil else { return nil }
            state.challenge = challengeSource.generate()

        case .submitAnswer(let answer):
            if let deadline = cooldownDeadline(&state) {
                // Answers are refused during cooldown — even correct ones —
                // so the limit can't be raced. `.cooldownExpired` clears it.
                guard ContinuousClock.now >= deadline else { return nil }
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
            var deadline: ContinuousClock.Instant?
            if state.attempts >= attemptLimit {
                let until = now().addingTimeInterval(cooldownInterval)
                state.attempts = 0
                state.cooldownUntil = until
                deadline = cooldownClock.pin(until, remaining: cooldown)
            }
            return Effect { [deadline] send in
                await send(.answerRejected)
                if let deadline {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    await send(.cooldownExpired)
                }
            }

        case .answerAccepted, .answerRejected:
            // Notifications for the host, not commands that can mutate a newer
            // challenge or grant a reason that was never validated.
            break

        case .cooldownExpired:
            guard let deadline = cooldownDeadline(&state) else { return nil }
            // Early — a stale expiry from an earlier cooldown, or a deadline
            // re-pinned since this timer was armed. Wait out the rest rather
            // than drop it: nothing else may be left to send it.
            guard ContinuousClock.now >= deadline else { return expiry(at: deadline) }
            state.cooldownUntil = nil
            if state.pendingReason != nil { state.challenge = challengeSource.generate() }
        }
        return nil
    }

    /// The cooldown's deadline on the monotonic clock, or `nil` when there is
    /// no cooldown.
    ///
    /// A deadline this process set, or has already seen, keeps the instant it
    /// was pinned to, whatever the wall clock has done since. One seen for the
    /// first time — hydrated from a previous launch, or written by the host —
    /// is held to at most one cooldown from now, so a clock that has moved
    /// backward (or an edited store) can't lock the gate for longer.
    private func cooldownDeadline(_ state: inout ParentalGateState) -> ContinuousClock.Instant? {
        guard var until = state.cooldownUntil else { return nil }
        if let pinned = cooldownClock.deadline(for: until) { return pinned }
        let now = self.now()
        let latest = now.addingTimeInterval(cooldownInterval)
        if until > latest {
            until = latest
            state.cooldownUntil = latest
        }
        return cooldownClock.pin(until, remaining: .seconds(max(0, until.timeIntervalSince(now))))
    }

    /// Sleeps until `deadline`, then reports the cooldown as expired.
    private func expiry(at deadline: ContinuousClock.Instant) -> Effect<ParentalGateAction> {
        Effect { send in
            try await Task.sleep(until: deadline, clock: .continuous)
            await send(.cooldownExpired)
        }
    }

    private var cooldownInterval: TimeInterval {
        TimeInterval(cooldown.components.seconds)
            + TimeInterval(cooldown.components.attoseconds) * 1e-18
    }
}

/// Pins a cooldown's wall-clock deadline to the monotonic clock.
///
/// `cooldownUntil` is a `Date` because it has to survive a relaunch and drive
/// a countdown, but a `Date` comparison follows the device clock: moved
/// forward, it skips the cooldown; moved back, it extends it. Within a process
/// the plugin compares against the instant the deadline was pinned to instead.
@MainActor
private final class CooldownClock {
    private var pinned: (until: Date, deadline: ContinuousClock.Instant)?

    func deadline(for until: Date) -> ContinuousClock.Instant? {
        guard let pinned, pinned.until == until else { return nil }
        return pinned.deadline
    }

    func pin(_ until: Date, remaining: Duration) -> ContinuousClock.Instant {
        let deadline = ContinuousClock.now.advanced(by: remaining)
        pinned = (until, deadline)
        return deadline
    }
}

/// Persists the newest lockout, never an older one.
///
/// Each change is written by its own effect, and the store runs effects
/// concurrently, so two writes can land in either order: a slow Keychain
/// write of "one wrong answer" landing after "cooldown until T" would leave a
/// relaunch with no cooldown. So the reducer stages the value synchronously,
/// in dispatch order, and every flush writes whatever is newest *when it
/// holds the lock*. The last write to land is then always the newest value.
private final class LockoutWriter: Sendable {
    private let store: any KeyValueStore
    private let latest = Mutex<ParentalGateLockout?>(nil)
    private let writing = Mutex(())

    init(_ store: any KeyValueStore) {
        self.store = store
    }

    func stage(_ lockout: ParentalGateLockout) {
        latest.withLock { $0 = lockout }
    }

    func flush() {
        writing.withLock { _ in
            _ = store.setValue(latest.withLock { $0 }, for: .parentalGateLockout)
        }
    }
}

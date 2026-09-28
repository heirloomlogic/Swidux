//
//  EffectCancellation.swift
//  Swidux
//
//  Keyed effect cancellation. `cancellable(id:)` tags an effect with a
//  caller-supplied identity; `cancel(id:)` (and `Store.cancel(id:)`) cancels
//  every in-flight effect sharing that identity. Identity lives out of band —
//  static metadata plus a task-local context and the store registry keep
//  effect bodies independent of the store type.
//

import Foundation
import Synchronization

/// A `Sendable` type-erased hashable box.
///
/// Cancellation ids cross into `@Sendable` effect closures, so a bare
/// `AnyHashable` (which is not `Sendable`) will not do. This preserves the
/// `Sendable` guarantee the API already requires of every id.
struct AnyHashableSendable: Hashable, Sendable {
    let base: any Hashable & Sendable

    init(_ base: some Hashable & Sendable) {
        if let base = base as? AnyHashableSendable {
            self = base
        } else {
            self.base = base
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        AnyHashable(lhs.base) == AnyHashable(rhs.base)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(AnyHashable(base))
    }
}

/// Store-owned scopes are registered synchronously at dispatch and removed on completion.
@MainActor
protocol EffectCancellationRegistrar: AnyObject, Sendable {
    func register(_ scope: ActiveScope, token: UUID, in taskID: UUID, cancelInFlight: Bool, sparing: Set<UUID>)
    func unregister(_ taskID: UUID, scope: UUID)
    func cancelCancellable(id: AnyHashableSendable)
}

/// One running `cancellable(id:)` scope, as the store's registry holds it.
struct ActiveScope: Sendable {
    let id: AnyHashableSendable
    let cancellation: ScopeCancellation
    /// Dispatches the scope's `onCancel:` action through the send it was given.
    let onCancel: (@MainActor @Sendable () -> Void)?
    /// Tokens of the scopes this one is nested in. Cancelling any of them
    /// cancels this one too, so it reports as well.
    var enclosingScopes: Set<UUID> = []
}

/// Cancels the unit of work a scope runs in, and remembers that it did.
///
/// The flag, not `Task.isCancelled`, is what a scope's sends check: it is set
/// only by the store, so a stale result is dropped however the work was
/// cancelled, while the scope's own `onCancel:` report — dispatched on the
/// main actor, from whatever task asked for the cancellation — isn't mistaken
/// for one.
final class ScopeCancellation: Sendable {
    private struct State {
        var isCancelled = false
        var isFinished = false
        var cancelWork: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    /// Whether the store has cancelled this scope.
    var isCancelled: Bool { state.withLock(\.isCancelled) }

    /// Binds the work to cancel. Cancels it at once if the scope already was.
    func attach(_ task: Task<some Sendable, some Error>) {
        let cancelled = state.withLock { state in
            state.cancelWork = { task.cancel() }
            return state.isCancelled
        }
        if cancelled { task.cancel() }
    }

    /// Records that the scope's operation has returned or thrown, on the
    /// scope's own task, at once. The registry forgets the scope a main-actor
    /// hop later; a cancellation landing in between has nothing left to
    /// cancel, and must not report that it did.
    func finish() {
        state.withLock { $0.isFinished = true }
    }

    /// Cancels the scope's work. Returns `false` if it was already cancelled,
    /// or had already finished.
    @discardableResult
    func cancel() -> Bool {
        let work = state.withLock { state -> (@Sendable () -> Void)?? in
            guard !state.isCancelled, !state.isFinished else { return nil }
            state.isCancelled = true
            return .some(state.cancelWork)
        }
        guard let work else { return false }
        work?()
        return true
    }

    /// Wraps `send` so nothing is dispatched once the scope is cancelled —
    /// except an `onCancel:` report, which a nested scope sends through its
    /// enclosing scopes' guards just when they are cancelled too.
    func guarding<Action>(_ send: @escaping Send<Action>) -> Send<Action> {
        { [self] action in
            guard !isCancelled || Self.isDeliveringReport else { return }
            send(action)
        }
    }

    /// Set while the store dispatches `onCancel:` reports.
    @TaskLocal static var isDeliveringReport = false
}

/// Ambient context a wrapped effect uses to register and cancel itself.
///
/// The store binds this as a task-local around each effect body. The reference
/// to the store is `weak` on purpose: a cancellable effect must not keep its
/// store alive, or deinit-based teardown of a parked streaming effect could
/// never fire.
struct EffectContext: Sendable {
    weak var registrar: (any EffectCancellationRegistrar)?
    let taskID: UUID
    /// Tokens of the scopes the running code is nested in. A `cancelInFlight`
    /// scope spares them: cancelling one would cancel the scope itself.
    var enclosingScopes: Set<UUID> = []

    @TaskLocal static var current: EffectContext?
}

/// Tags an effect with a cancellation identity so it can later be cancelled by
/// ``cancel(id:)`` or `Store.cancel(id:)`.
///
/// ```swift
/// // Debounced search — each keystroke cancels the prior in-flight request:
/// return cancellable(id: SearchID(), cancelInFlight: true) { send in
///     try await Task.sleep(for: .milliseconds(300))
///     await send(.results(try await api.search(query)))
/// }
/// ```
///
/// Distinct ids are independent; two effects tagged with the same id are
/// cancelled together. The tag is dropped automatically when the effect
/// finishes. Top-level scopes register synchronously at dispatch; scopes
/// invoked inside another effect become active only at invocation, and run as
/// a child task, so cancelling one cancels that scope rather than the effect
/// hosting it. Use `Effect.map` to preserve metadata when lifting actions.
/// Outside a store-run effect (for example a direct call in a unit
/// test) there is no context to register with, and the effect simply runs.
///
/// Once cancelled, the effect's sends are dropped — including one from a
/// `catch` block — so a stale result can't be published. To clear an
/// in-flight flag when the effect is cancelled, pass `onCancel:` instead.
///
/// - Parameters:
///   - id: Any `Hashable & Sendable` value identifying the effect.
///   - cancelInFlight: When `true`, cancels any effect already running under
///     `id` before starting this one — the one-line debounce / latest-wins knob.
///   - operation: The effect to run.
/// - Returns: An `Effect` that is registered under `id` for as long as it runs.
public func cancellable<Action>(
    id: some Hashable & Sendable,
    cancelInFlight: Bool = false,
    _ operation: @escaping @Sendable (@escaping Send<Action>) async throws -> Void
) -> Effect<Action> {
    Effect(cancellation: .scope(AnyHashableSendable(id), cancelInFlight: cancelInFlight), operation: operation)
}

/// Tags an effect with a cancellation identity, and names the action the
/// store dispatches if it is cancelled.
///
/// A cancelled keyed effect can't send from its own `catch` block — its sends
/// are dropped so a stale result can't be published — so this is how it
/// reports the cancellation, typically to clear an in-flight flag:
///
/// ```swift
/// case .search(let query):
///     state.isSearching = true
///     return cancellable(id: SearchID(), onCancel: .searchCancelled) { send in
///         await send(.results(try await api.search(query)))
///     }
/// ```
///
/// The store dispatches `onCancel` when ``cancel(id:)``, `Store.cancel(id:)`,
/// or `Store.cancelEffects()` cancels the effect while it is running — right
/// away, or right after the action being dispatched when the cancellation
/// comes from a reducer. A scope nested in a cancelled scope is cancelled with
/// it and dispatches its own `onCancel` too, after the outer one's. It is not
/// dispatched when a `cancelInFlight` effect replaces this one: the action that
/// started the replacement is already handling that state.
///
/// - Parameters:
///   - id: Any `Hashable & Sendable` value identifying the effect.
///   - cancelInFlight: When `true`, cancels any effect already running under
///     `id` before starting this one.
///   - onCancel: The action dispatched when the effect is cancelled.
///   - operation: The effect to run.
/// - Returns: An `Effect` that is registered under `id` for as long as it runs.
public func cancellable<Action: Sendable>(
    id: some Hashable & Sendable,
    cancelInFlight: Bool = false,
    onCancel: Action,
    _ operation: @escaping @Sendable (@escaping Send<Action>) async throws -> Void
) -> Effect<Action> {
    Effect(
        cancellation: .scope(AnyHashableSendable(id), cancelInFlight: cancelInFlight),
        onCancel: { onCancel },
        operation: operation
    )
}

/// Cancels scopes active when the store dispatches this effect, or when it is
/// invoked dynamically inside another effect. Undeclared future work is unaffected.
public func cancel<Action>(id: some Hashable & Sendable) -> Effect<Action> {
    Effect(cancellation: .cancel(AnyHashableSendable(id)), operation: { _ in })
}

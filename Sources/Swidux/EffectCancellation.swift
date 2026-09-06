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
    func register(_ taskID: UUID, scope: UUID, id: AnyHashableSendable, cancelInFlight: Bool)
    func unregister(_ taskID: UUID, scope: UUID)
    func cancelCancellable(id: AnyHashableSendable, excluding taskID: UUID?)
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
/// invoked inside another effect become active only at invocation. Use
/// `Effect.map` to preserve metadata when lifting actions.
/// Outside a store-run effect (for example a direct call in a unit
/// test) there is no context to register with, and the effect simply runs.
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

/// Cancels scopes active when the store dispatches this effect, or when it is
/// invoked dynamically inside another effect. Undeclared future work is unaffected.
public func cancel<Action>(id: some Hashable & Sendable) -> Effect<Action> {
    Effect(cancellation: .cancel(AnyHashableSendable(id)), operation: { _ in })
}

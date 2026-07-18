//
//  EffectCancellation.swift
//  Swidux
//
//  Keyed effect cancellation. `cancellable(id:)` tags an effect with a
//  caller-supplied identity; `cancel(id:)` (and `Store.cancel(id:)`) cancels
//  every in-flight effect sharing that identity. Identity lives out of band —
//  a task-local context plus the store's effect registry — so the `Effect`
//  closure typealias and every reducer signature are untouched.
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

/// A store's effect registry, seen through the lens of cancellation.
///
/// `Store` is the only conformer. The protocol exists so the generic
/// ``cancellable(id:cancelInFlight:_:)`` and ``cancel(id:)`` helpers can reach
/// back into the store without knowing its `State`/`Action` types. Both members
/// are MainActor-isolated; effect bodies (which run off the MainActor) reach
/// them through an `await` hop.
@MainActor
protocol EffectCancellationRegistrar: AnyObject, Sendable {
    /// Tags the in-flight effect `taskID` with cancellation identity `id`. When
    /// `cancelInFlight` is true, first cancels any effect already running under
    /// `id`.
    func register(_ taskID: UUID, id: AnyHashableSendable, cancelInFlight: Bool)
    /// Cancels every in-flight effect currently running under `id`.
    func cancelCancellable(id: AnyHashableSendable)
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
/// finishes. Outside a store-run effect (for example a direct call in a unit
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
    _ operation: @escaping Effect<Action>
) -> Effect<Action> {
    let key = AnyHashableSendable(id)
    return { send in
        // No ambient context means this effect is running outside a store (for
        // example a direct call in a unit test) — just run it, un-registered.
        guard let context = EffectContext.current else {
            try await operation(send)
            return
        }
        await context.registrar?.register(context.taskID, id: key, cancelInFlight: cancelInFlight)
        try await operation(send)
    }
}

/// An effect that cancels every in-flight effect running under `id`.
///
/// ```swift
/// case .stopSpeaking:
///     return cancel(id: SpeechID())
/// ```
///
/// A no-op when nothing is running under `id`.
public func cancel<Action>(id: some Hashable & Sendable) -> Effect<Action> {
    let key = AnyHashableSendable(id)
    return { _ in
        await EffectContext.current?.registrar?.cancelCancellable(id: key)
    }
}

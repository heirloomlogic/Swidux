import Foundation

/// Dispatches an action back to the store from an effect.
public typealias Send<Action> = @MainActor @Sendable (Action) -> Void

/// Async work with cancellation metadata declared before the store starts it.
///
/// Construct work with `Effect { send in ... }`. Effects may throw; the store
/// logs errors other than `CancellationError`. Use ``map(_:)`` when lifting
/// an effect into a root action so its cancellation metadata is preserved.
public struct Effect<Action>: Sendable {
    private let operation: @Sendable (@escaping Send<Action>) async throws -> Void
    let cancellation: EffectCancellation?
    /// Makes the action a cancelled scope reports; see `cancellable(id:cancelInFlight:onCancel:_:)`.
    let onCancel: (@Sendable () -> Action)?

    /// Creates an effect whose operation runs on the store’s background task.
    public init(_ operation: @escaping @Sendable (@escaping Send<Action>) async throws -> Void) {
        self.operation = operation
        self.cancellation = nil
        self.onCancel = nil
    }

    init(
        cancellation: EffectCancellation,
        onCancel: (@Sendable () -> Action)? = nil,
        operation: @escaping @Sendable (@escaping Send<Action>) async throws -> Void
    ) {
        self.operation = operation
        self.cancellation = cancellation
        self.onCancel = onCancel
    }

    /// Runs an effect directly. Dynamically invoked cancellation scopes become
    /// active at this call; cancellation never applies to future undeclared work.
    public func callAsFunction(_ send: @escaping Send<Action>) async throws {
        try await run(send, declaredScope: nil)
    }

    /// The registry entry for this effect's scope, reporting through `send`.
    func activeScope(
        id: AnyHashableSendable,
        send: @escaping Send<Action>,
        enclosedBy enclosingScopes: Set<UUID> = []
    ) -> ActiveScope {
        var report: (@MainActor @Sendable () -> Void)?
        if let onCancel {
            report = { send(onCancel()) }
        }
        return ActiveScope(
            id: id, cancellation: ScopeCancellation(), onCancel: report, enclosingScopes: enclosingScopes)
    }

    /// Runs the operation. `declaredScope` is the scope the store registered
    /// for a top-level effect at dispatch; a scope invoked inside another
    /// effect registers itself here.
    func run(_ send: @escaping Send<Action>, declaredScope: (token: UUID, scope: ActiveScope)?) async throws {
        guard let cancellation, let context = EffectContext.current else {
            try await operation(send)
            return
        }
        switch cancellation {
        case .cancel(let id):
            await context.registrar?.cancelCancellable(id: id)
        case .scope(let id, let cancelInFlight):
            let (token, scope) =
                declaredScope ?? (UUID(), activeScope(id: id, send: send, enclosedBy: context.enclosingScopes))
            // This actor hop also prevents a declared scope from running before
            // the synchronous dispatch cycle has finished registering its tasks.
            await context.registrar?.register(
                scope, token: token, in: context.taskID,
                cancelInFlight: declaredScope == nil && cancelInFlight,
                sparing: context.enclosingScopes
            )
            do {
                try Task.checkCancellation()
                if declaredScope != nil {
                    // The store's task for this effect is the scope's unit of work.
                    defer { scope.cancellation.finish() }
                    try await operation(scope.cancellation.guarding(send))
                } else {
                    try await runInChildTask(scope, token: token, context: context, send: send)
                }
            } catch {
                await context.registrar?.unregister(context.taskID, scope: token)
                throw error
            }
            await context.registrar?.unregister(context.taskID, scope: token)
        }
    }

    /// Runs a scope invoked inside another effect as its own unit of work, so
    /// cancelling its id cancels only this scope — not the effect hosting it,
    /// nor that effect's other scopes. The host's cancellation still reaches it.
    private func runInChildTask(
        _ scope: ActiveScope,
        token: UUID,
        context: EffectContext,
        send: @escaping Send<Action>
    ) async throws {
        var nested = context
        nested.enclosingScopes.insert(token)
        let operation = operation
        let guardedSend = scope.cancellation.guarding(send)
        // An unstructured task inherits task-locals, so scopes nested in this
        // one see `nested` and spare this scope from `cancelInFlight`.
        let cancellation = scope.cancellation
        let child = EffectContext.$current.withValue(nested) {
            Task {
                defer { cancellation.finish() }
                try await operation(guardedSend)
            }
        }
        scope.cancellation.attach(child)
        try await withTaskCancellationHandler {
            try await child.value
        } onCancel: {
            child.cancel()
        }
    }

    /// Transforms dispatched actions while preserving cancellation metadata.
    public func map<MappedAction>(
        _ transform: @escaping @Sendable (Action) -> MappedAction
    ) -> Effect<MappedAction> {
        let mapped: @Sendable (@escaping Send<MappedAction>) async throws -> Void = { send in
            try await self.operation { action in send(transform(action)) }
        }
        guard let cancellation else { return Effect<MappedAction>(mapped) }
        var mappedOnCancel: (@Sendable () -> MappedAction)?
        if let onCancel {
            mappedOnCancel = { transform(onCancel()) }
        }
        return Effect<MappedAction>(cancellation: cancellation, onCancel: mappedOnCancel, operation: mapped)
    }
}

/// Static metadata lets a store register top-level work before scheduling it.
enum EffectCancellation: Sendable {
    case scope(AnyHashableSendable, cancelInFlight: Bool)
    case cancel(AnyHashableSendable)
}

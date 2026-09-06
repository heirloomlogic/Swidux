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

    /// Creates an effect whose operation runs on the store’s background task.
    public init(_ operation: @escaping @Sendable (@escaping Send<Action>) async throws -> Void) {
        self.operation = operation
        self.cancellation = nil
    }

    init(
        cancellation: EffectCancellation,
        operation: @escaping @Sendable (@escaping Send<Action>) async throws -> Void
    ) {
        self.operation = operation
        self.cancellation = cancellation
    }

    /// Runs an effect directly. Dynamically invoked cancellation scopes become
    /// active at this call; cancellation never applies to future undeclared work.
    public func callAsFunction(_ send: @escaping Send<Action>) async throws {
        try await run(send, registeredScope: nil)
    }

    func run(_ send: @escaping Send<Action>, registeredScope: UUID?) async throws {
        guard let cancellation, let context = EffectContext.current else {
            try await operation(send)
            return
        }
        switch cancellation {
        case .cancel(let id):
            await context.registrar?.cancelCancellable(id: id, excluding: nil)
        case .scope(let id, let cancelInFlight):
            let scope = registeredScope ?? UUID()
            // This actor hop also prevents a declared scope from running before
            // the synchronous dispatch cycle has finished registering its tasks.
            await context.registrar?.register(
                context.taskID, scope: scope, id: id,
                cancelInFlight: registeredScope == nil && cancelInFlight
            )
            do {
                try Task.checkCancellation()
                try await operation { action in
                    guard !Task.isCancelled else { return }
                    send(action)
                }
            } catch {
                await context.registrar?.unregister(context.taskID, scope: scope)
                throw error
            }
            await context.registrar?.unregister(context.taskID, scope: scope)
        }
    }

    /// Transforms dispatched actions while preserving cancellation metadata.
    public func map<MappedAction>(
        _ transform: @escaping @Sendable (Action) -> MappedAction
    ) -> Effect<MappedAction> {
        let mapped: @Sendable (@escaping Send<MappedAction>) async throws -> Void = { send in
            try await self.operation { action in send(transform(action)) }
        }
        if let cancellation {
            return Effect<MappedAction>(cancellation: cancellation, operation: mapped)
        }
        return Effect<MappedAction>(mapped)
    }
}

/// Static metadata lets a store register top-level work before scheduling it.
enum EffectCancellation: Sendable {
    case scope(AnyHashableSendable, cancelInFlight: Bool)
    case cancel(AnyHashableSendable)
}

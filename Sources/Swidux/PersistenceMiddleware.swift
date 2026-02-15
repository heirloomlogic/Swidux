//
//  PersistenceMiddleware.swift
//  Swidux
//
//  Observes state changes after each reducer call and batches
//  persistence writes behind a debounce timer.
//

import Foundation
import os

/// Coalescing persistence middleware.
///
/// After each reducer call, drains `ChangeSet`s from registered `EntityStore`s
/// into `StateWriter` buffers. Restarts a debounce timer on each drain. When the
/// timer fires, flushes all pending writes in a single `Task`.
///
/// ## Wiring
///
/// ```swift
/// let middleware = PersistenceMiddleware<AppState>(
///     writers: [
///         StateWriter(keyPath: \.decks) { writes, deletes in ... },
///         StateWriter(keyPath: \.cards) { writes, deletes in ... },
///     ],
///     debounce: .milliseconds(250)
/// )
/// ```
@MainActor
public final class PersistenceMiddleware<State> {

    private let writers: [StateWriter<State>]
    private let debounceInterval: Duration
    private let logger: Logger

    /// Active debounce task — cancelled and restarted on each change.
    private var debounceTask: Task<Void, Never>?

    public init(
        writers: [StateWriter<State>],
        debounce: Duration = .milliseconds(250),
        logger: Logger = Logger(subsystem: "persistence", category: "middleware")
    ) {
        self.writers = writers
        self.debounceInterval = debounce
        self.logger = logger
    }

    /// Called after every reducer invocation.
    ///
    /// Synchronously drains changelogs from each `EntityStore` (sub-microsecond).
    /// If any changes were drained, restarts the debounce timer. When the timer
    /// fires, flushes all accumulated writes in one batch.
    public func afterReduce(state: inout State) {
        var hasPending = false

        for writer in writers {
            if writer.drain(&state) {
                hasPending = true
            }
        }

        guard hasPending else { return }

        logger.debug("[PersistenceMiddleware] Changes drained, scheduling flush")

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }

            let work = self.writers.compactMap { $0.flush() }
            guard !work.isEmpty else { return }

            self.logger.debug("[PersistenceMiddleware] Flushing \(work.count) writer(s)")
            for w in work {
                await w()
            }
        }
    }
}

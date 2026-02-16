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

    /// Number of `afterReduce` calls since the last debounce flush.
    /// Used to detect probable dispatch loops.
    private var drainCount = 0

    /// Whether we've already logged a loop warning for this burst.
    private var hasLoggedLoopWarning = false

    /// Threshold above which `afterReduce` calls per debounce interval
    /// are considered a probable dispatch loop.
    private let loopWarningThreshold: Int

    /// Creates a persistence middleware with the given writers and debounce interval.
    ///
    /// - Parameters:
    ///   - writers: The state writers that drain and flush entity changes.
    ///   - debounce: How long to wait after the last change before flushing.
    ///   - loopThreshold: Number of `afterReduce` calls per debounce interval
    ///     that triggers a dispatch loop warning. Default is 100.
    ///   - logger: Logger used for debug output.
    public init(
        writers: [StateWriter<State>],
        debounce: Duration = .milliseconds(250),
        loopThreshold: Int = 100,
        logger: Logger = Logger(subsystem: "persistence", category: "middleware")
    ) {
        self.writers = writers
        self.debounceInterval = debounce
        self.loopWarningThreshold = loopThreshold
        self.logger = logger
    }

    /// Called after every reducer invocation.
    ///
    /// Synchronously drains changelogs from each `EntityStore` (sub-microsecond).
    /// If any changes were drained, restarts the debounce timer. When the timer
    /// fires, flushes all accumulated writes in one batch.
    public func afterReduce(state: inout State) {
        var hasPending = false

        for writer in writers where writer.drain(&state) {
            hasPending = true
        }

        guard hasPending else { return }

        // Dispatch loop detection
        drainCount += 1
        if drainCount > loopWarningThreshold && !hasLoggedLoopWarning {
            hasLoggedLoopWarning = true
            logger.warning(
                """
                [PersistenceMiddleware] afterReduce called \(self.drainCount) times \
                in a single debounce interval — possible dispatch loop. \
                Check that AppStore.send() guards @Observable property writes \
                with equality checks.
                """
            )
        }

        logger.debug("[PersistenceMiddleware] Changes drained, scheduling flush")

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }

            // Reset loop detection counters
            self.drainCount = 0
            self.hasLoggedLoopWarning = false

            let work = self.writers.compactMap { $0.flush() }
            guard !work.isEmpty else { return }

            self.logger.debug("[PersistenceMiddleware] Flushing \(work.count) writer(s)")
            for w in work {
                await w()
            }
        }
    }
}

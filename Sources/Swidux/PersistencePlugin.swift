//
//  PersistencePlugin.swift
//  Swidux
//
//  Observes state changes after each reducer call and batches
//  persistence writes behind a debounce timer.
//

import Foundation
import os

/// Coalescing persistence plugin.
///
/// After each reducer call, drains `ChangeSet`s from registered `EntityStore`s
/// into `StateWriter` buffers. Restarts a debounce timer on each drain. When the
/// timer fires, flushes all pending writes in a single `Task`.
///
/// ## Wiring
///
/// ```swift
/// let persistence = PersistencePlugin<AppState, AppAction>(
///     writers: [
///         StateWriter(keyPath: \.decks) { writes, deletes in ... },
///         StateWriter(keyPath: \.cards) { writes, deletes in ... },
///     ],
///     debounce: .milliseconds(250)
/// )
/// plugins.register(persistence)
/// ```
@MainActor
public final class PersistencePlugin<State, Action>: SwiduxPlugin {
    private let writers: [StateWriter<State>]
    private let debounceInterval: Duration
    private let logger: Logger

    /// Active debounce task — cancelled and restarted on each change.
    private var debounceTask: Task<Void, Never>?

    /// Number of `afterReduce` calls since the last debounce flush.
    ///
    /// Used to detect probable dispatch loops.
    private var drainCount = 0

    /// Whether we've already logged a loop warning for this burst.
    private var hasLoggedLoopWarning = false

    /// Threshold above which `afterReduce` calls per debounce interval
    /// are considered a probable dispatch loop.
    private let loopWarningThreshold: Int

    /// Creates a persistence plugin with the given writers and debounce interval.
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
        logger: Logger = Logger(subsystem: "persistence", category: "plugin")
    ) {
        self.writers = writers
        self.debounceInterval = debounce
        self.loopWarningThreshold = loopThreshold
        self.logger = logger
    }

    /// Immediately flushes all pending writes, cancelling any active debounce timer.
    ///
    /// Call this during app shutdown (e.g. `applicationWillTerminate`,
    /// `scenePhase == .background`) to ensure no buffered writes are lost.
    public func flush() async {
        debounceTask?.cancel()
        debounceTask = nil

        drainCount = 0
        hasLoggedLoopWarning = false

        let work = writers.compactMap { $0.flush() }
        for w in work {
            await w()
        }
    }

    /// Drains ChangeSets and schedules a debounced flush.
    ///
    /// Called by ``Store`` during undo/redo where no action value exists.
    /// Also called internally by ``afterReduce(state:action:)``.
    public func drainAndScheduleFlush(_ state: inout State) {
        var hasPending = false

        for writer in writers where writer.drain(&state) {
            hasPending = true
        }

        guard hasPending else { return }

        drainCount += 1
        if drainCount > loopWarningThreshold && !hasLoggedLoopWarning {
            hasLoggedLoopWarning = true
            logger.warning(
                """
                [PersistencePlugin] afterReduce called \(self.drainCount) times \
                in a single debounce interval — possible dispatch loop. \
                Check that AppStore.send() guards @Observable property writes \
                with equality checks.
                """
            )
        }

        logger.debug("[PersistencePlugin] Changes drained, scheduling flush")

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }

            self.drainCount = 0
            self.hasLoggedLoopWarning = false

            let work = self.writers.compactMap { $0.flush() }
            guard !work.isEmpty else { return }

            self.logger.debug("[PersistencePlugin] Flushing \(work.count) writer(s)")
            for w in work {
                await w()
            }
        }
    }

    /// Drains ChangeSets after every reducer invocation.
    ///
    /// Synchronously drains changelogs from each `EntityStore` (sub-microsecond).
    /// If any changes were drained, restarts the debounce timer. When the timer
    /// fires, flushes all accumulated writes in one batch.
    public func afterReduce(state: inout State, action: Action) {
        drainAndScheduleFlush(&state)
    }
}

/// Migration aid — use ``PersistencePlugin`` instead.
@available(*, deprecated, renamed: "PersistencePlugin")
public typealias PersistenceMiddleware<State> = PersistencePlugin<State, Never>

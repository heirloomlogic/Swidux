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
/// A flush whose save fails is retried on a doubling backoff, bounded by
/// ``RetryPolicy``. Without that a failed save is silent data loss: the buffers
/// are cleared at flush time, so the write would only ever reach storage if the
/// user happened to touch the same entity again. Running out of attempts is
/// reported through the writer rather than passing in silence, and the batch
/// stays pending so a later edit or an explicit ``flush()`` tries once more.
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

    /// Pending retry of a failed flush. Kept apart from ``debounceTask`` so
    /// cancelling one never silently drops the other — a retry cancelled by an
    /// unrelated edit would be exactly the lost write this exists to prevent.
    private var retryTask: Task<Void, Never>?

    /// How a failed flush is retried.
    private let retryPolicy: RetryPolicy

    /// One writer's standing with the retry budget.
    private struct RetryState {
        /// Consecutive failed flushes since the last success or new edit.
        var failures = 0
        /// Whether the budget is spent. Not derived from `failures`: an
        /// explicit flush forgives the verdict without forgiving the count, so
        /// a writer that has given up gets exactly one more attempt.
        var hasGivenUp = false
    }

    /// Retry bookkeeping per writer, index-aligned with ``writers``.
    private var retryStates: [RetryState]

    /// Tail of the chain of in-flight flush work. Every flush — debounce-fired
    /// or direct — awaits the previous one, so batches reach the database in
    /// order and ``flush()`` can deterministically wait for in-flight writes.
    private var flushTail: Task<Void, Never>?

    /// Number of `afterReduce` calls since the last debounce flush.
    ///
    /// Used to detect probable dispatch loops.
    private var drainCount = 0

    /// Whether we've already reported a loop warning for this burst.
    private var hasReportedLoopWarning = false

    /// Threshold above which `afterReduce` calls per debounce interval
    /// are considered a probable dispatch loop.
    private let loopWarningThreshold: Int

    /// Notified — at most once per burst, alongside the log — when the drain
    /// count crosses ``loopWarningThreshold``.
    ///
    /// A bare `Int` rather than a persistence-layer diagnostic type because
    /// core Swidux can't depend on `SwiduxPersistence`; the wrapping happens
    /// there, exactly as `StateWriter.onExhausted` hands out a bare `Error`.
    private let onLoopSuspected: (@MainActor (Int) -> Void)?

    /// Creates a persistence plugin with the given writers and debounce interval.
    ///
    /// - Parameters:
    ///   - writers: The state writers that drain and flush entity changes.
    ///   - debounce: How long to wait after the last change before flushing.
    ///   - retry: How a failed flush is retried. The buffers are cleared at
    ///     flush time, so without retrying a failed save reaches disk only if
    ///     the user happens to touch the same entity again.
    ///   - loopThreshold: Number of `afterReduce` calls per debounce interval
    ///     that triggers a dispatch loop warning. Default is 100.
    ///   - logger: Logger used for debug output.
    ///   - onLoopSuspected: Called with the drain count when that threshold is
    ///     crossed — at most once per burst, so a runaway loop can't hand the
    ///     app one callback per dispatch. The warning is logged either way.
    public init(
        writers: [StateWriter<State>],
        debounce: Duration = .milliseconds(250),
        retry: RetryPolicy = .default,
        loopThreshold: Int = 100,
        logger: Logger = Logger(subsystem: "persistence", category: "plugin"),
        onLoopSuspected: (@MainActor (Int) -> Void)? = nil
    ) {
        self.writers = writers
        self.debounceInterval = debounce
        self.retryPolicy = retry
        self.retryStates = Array(repeating: RetryState(), count: writers.count)
        self.loopWarningThreshold = loopThreshold
        self.logger = logger
        self.onLoopSuspected = onLoopSuspected
    }

    /// Immediately flushes all pending writes, cancelling any active debounce timer.
    ///
    /// Call this during app shutdown (e.g. `applicationWillTerminate`,
    /// `scenePhase == .background`) to ensure no buffered writes are lost.
    public func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        // An explicit flush is a fresh request to get everything to disk, so it
        // supersedes a scheduled retry and gives a writer that had already
        // given up **one** more attempt. Deliberately not a full budget reset:
        // this runs on backgrounding and before reads, and neither wants to
        // start a multi-second retry sequence. New user intent is what earns a
        // full budget — see `drainAndScheduleFlush`.
        retryTask?.cancel()
        retryTask = nil
        for index in retryStates.indices { retryStates[index].hasGivenUp = false }

        drainCount = 0
        hasReportedLoopWarning = false

        // Chains behind any in-flight debounce flush, so returning from
        // here guarantees every previously-buffered write has been persisted.
        await runFlushWork()?.value
    }

    /// Drains ChangeSets and schedules a debounced flush.
    ///
    /// Called by ``Store`` during undo/redo where no action value exists.
    /// Also called internally by ``afterReduce(state:action:)``.
    public func drainAndScheduleFlush(_ state: inout State) {
        var hasPending = false

        for index in writers.indices where writers[index].drain(&state) {
            hasPending = true
            // New intent for this entity type: whatever went wrong before, the
            // user is still editing, so the batch deserves a full budget.
            retryStates[index] = RetryState()
        }

        guard hasPending else { return }

        // The debounce flush about to be scheduled carries the re-buffered
        // batch too, so a separate retry tick would only duplicate it.
        retryTask?.cancel()
        retryTask = nil

        drainCount += 1
        if drainCount > loopWarningThreshold && !hasReportedLoopWarning {
            hasReportedLoopWarning = true
            logger.warning(
                """
                [PersistencePlugin] afterReduce called \(self.drainCount) times \
                in a single debounce interval — possible dispatch loop. \
                Look for an effect or plugin that dispatches an action on every \
                state change, feeding the cycle it reacts to.
                """
            )
            onLoopSuspected?(drainCount)
        }

        logger.debug("[PersistencePlugin] Changes drained, scheduling flush")

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }

            self.drainCount = 0
            self.hasReportedLoopWarning = false
            self.runFlushWork()
        }
    }

    /// Snapshots the writers' pending buffers and spawns the persistence work,
    /// chained behind any flush already in flight.
    ///
    /// Returns `nil` when there is nothing pending and nothing in flight.
    @discardableResult
    private func runFlushWork() -> Task<Void, Never>? {
        let work = writers.indices.compactMap { index in
            writers[index].flush().map { (index, $0) }
        }
        let previous = flushTail
        guard !work.isEmpty || previous != nil else { return nil }

        if !work.isEmpty {
            logger.debug("[PersistencePlugin] Flushing \(work.count) writer(s)")
        }
        let task = Task {
            await previous?.value
            var outcomes: [(index: Int, outcome: FlushOutcome)] = []
            outcomes.reserveCapacity(work.count)
            for (index, w) in work {
                outcomes.append((index, await w()))
            }
            self.recordOutcomes(outcomes)
        }
        flushTail = task
        return task
    }

    /// Folds one flush's outcomes into the retry bookkeeping and, if anything
    /// is still worth another attempt, schedules it.
    private func recordOutcomes(_ outcomes: [(index: Int, outcome: FlushOutcome)]) {
        // The soonest any still-retrying writer wants to be tried again. A
        // writer that has given up rides along on someone else's tick without
        // burning budget or scheduling one of its own.
        var nextDelay: Duration?

        for (index, outcome) in outcomes {
            guard outcome == .failed else {
                retryStates[index] = RetryState()
                continue
            }
            guard !retryStates[index].hasGivenUp else { continue }

            retryStates[index].failures += 1
            let failures = retryStates[index].failures
            guard failures < retryPolicy.maxAttempts else {
                retryStates[index].hasGivenUp = true
                logger.error(
                    """
                    [PersistencePlugin] Writer \(index) failed \(failures) consecutive saves — \
                    giving up. The batch is still held in memory and will be retried on the next \
                    edit or explicit flush, but it is not on disk.
                    """
                )
                writers[index].retryBudgetExhausted()
                continue
            }
            let delay = retryPolicy.delay(afterFailures: failures)
            nextDelay = nextDelay.map { min($0, delay) } ?? delay
        }

        guard let nextDelay else { return }
        scheduleRetry(after: nextDelay)
    }

    /// Re-attempts the re-buffered batches after `delay`.
    ///
    /// Separate from the debounce timer: a failed write has to reach disk even
    /// if the user never touches the app again.
    private func scheduleRetry(after delay: Duration) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.runFlushWork()
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

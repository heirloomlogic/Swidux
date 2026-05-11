import Foundation

/// A `SwiduxPlugin` that observes every dispatched action.
///
/// Hooks into `willReduce`, which fires once per action before any plugin or
/// reducer has mutated state. Emitting from the caller-supplied closure keeps
/// the destination (`os.Logger`, `print`, a test spy, an analytics service)
/// decoupled from the plugin itself — drop in any sink at construction.
///
/// Counter wires this plugin first so that the log line precedes undo
/// snapshots, persistence drains, and feature-flag handling. The cost is one
/// closure call per dispatch.
@MainActor
final class LoggingPlugin<State, Action>: SwiduxPlugin {
    private let log: @Sendable (Action) -> Void

    init(log: @escaping @Sendable (Action) -> Void) {
        self.log = log
    }

    func willReduce(state: State, action: Action) {
        log(action)
    }
}

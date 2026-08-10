//
//  PersistenceDiagnostic.swift
//  SwiduxPersistence
//
//  The non-failure channel. Conditions an app may want to act on that are not
//  errors — and so cannot honestly be routed through `onFailure`.
//

import Foundation

/// Something the persistence stack noticed that an app may want to act on, but
/// which is **not** a failure.
///
/// ``PersistenceFailure`` is deliberately scoped to operations that failed.
/// Duplicate rows are not a failure — they are a legitimate on-disk state under
/// CloudKit mirroring, which forbids unique constraints — and a probable
/// dispatch loop is a bug in the app, not in a save. Both were previously
/// visible only in Console. This is where they go instead.
///
/// Delivered to ``PersistenceCoordinator``'s `onDiagnostic` handler, always
/// after being logged.
///
/// ```swift
/// PersistenceCoordinator<AppState, AppAction>(
///     entities: [.entity(\.notes)],
///     container: container,
///     onDiagnostic: { diagnostic in
///         guard diagnostic.kind == .duplicateRowsCollapsed,
///               let count = diagnostic.duplicateCount else { return }
///         store.send(.offerDuplicateCleanup(count: count))
///     }
/// )
/// ```
///
/// ## Why a struct
///
/// A struct with static constructors rather than an enum, because the set of
/// things worth reporting will grow and a new one must not break an exhaustive
/// `switch` in app code. Match on ``kind`` and read the payload you expect; an
/// unrecognised diagnostic falls through harmlessly and still prints usefully.
///
/// The cost is that the payload properties are optional even though each kind
/// always carries its own — the price of not fixing the shape of the type at
/// 1.8.0. ``PersistenceFailure`` can afford a plain enum for its `Operation`
/// because "a save or a fetch failed" is genuinely closed; this isn't.
public struct PersistenceDiagnostic: Sendable, Equatable, CustomStringConvertible {
    /// Which condition was observed.
    ///
    /// Extensible by design — compare against the known values rather than
    /// assuming a closed set, because new ones may appear in a minor release.
    public struct Kind: Sendable, Equatable, Hashable {
        /// The stable identifier, suitable for logging or a telemetry key.
        public let rawValue: String

        /// Creates a kind. Public so an unrecognised value round-trips rather
        /// than being lost.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// A read found several rows sharing an `id` and collapsed them.
        ///
        /// Harmless but permanent without a `collapse:` resolver: writes and
        /// deletions converge across every matching row and reads collapse to
        /// one value per ID, but nothing is ever removed. Surfacing this is
        /// what lets an app *offer* the cleanup rather than leaving it to a
        /// developer who read the docs.
        public static let duplicateRowsCollapsed = Kind(rawValue: "duplicateRowsCollapsed")

        /// `afterReduce` fired far more often in one debounce interval than a
        /// user could plausibly cause — usually an effect or plugin dispatching
        /// on every state change, feeding the cycle it reacts to.
        public static let possibleDispatchLoop = Kind(rawValue: "possibleDispatchLoop")

        /// The set of IDs whose most recent flush attempt failed changed.
        ///
        /// Individual failures already arrive as ``PersistenceFailure``; this is
        /// the *accumulated* view, so an app can show and — when the set drains
        /// back to empty — clear a "not saved" indicator.
        public static let writesUnpersisted = Kind(rawValue: "writesUnpersisted")

        /// A merge left a stored value unapplied because an ``EditingHolds``
        /// hold was in force for that ID.
        ///
        /// Expected while the user is actually editing. Reported because a hold
        /// is the one exemption an app takes by hand, and therefore the one it
        /// can leak — and a leaked hold otherwise presents as a row that quietly
        /// stopped syncing.
        public static let mergeWithheld = Kind(rawValue: "mergeWithheld")

        /// A remote-change tick resolved persistent history into a bounded set
        /// of identities and merged only those.
        ///
        /// The healthy case, and the one worth watching: if it stops appearing,
        /// ticks have quietly fallen back to re-reading every table.
        public static let remoteChangesMerged = Kind(rawValue: "remoteChangesMerged")

        /// A tick could not narrow its work from persistent history and re-read
        /// every registered entity instead.
        ///
        /// Expected once per launch, and after a container rebuild. Repeatedly,
        /// it means something is preventing the watermark from advancing — a
        /// leaked editing hold, a failing read, or a store recording no usable
        /// history — and each of those has a different fix. See
        /// ``PersistenceDiagnostic/fallbackReason``.
        public static let historyUnavailable = Kind(rawValue: "historyUnavailable")

        /// Transactions older than the retention window were deleted.
        public static let historyPruned = Kind(rawValue: "historyPruned")
    }

    /// Which condition was observed.
    public let kind: Kind

    /// The domain entity type involved, e.g. `"Note"` — the same spelling
    /// ``PersistenceFailure/entityType`` uses, so the two channels agree.
    ///
    /// `nil` for ``Kind/possibleDispatchLoop``, which is stack-wide.
    public let entityType: String?

    /// How many rows were collapsed away, i.e. `rows - distinct IDs`.
    /// Set only for ``Kind/duplicateRowsCollapsed``.
    public let duplicateCount: Int?

    /// `afterReduce` calls counted in one debounce interval.
    /// Set only for ``Kind/possibleDispatchLoop``.
    public let drainCount: Int?

    /// Every ID whose most recent flush attempt failed — empty once they have
    /// all been persisted. Set only for ``Kind/writesUnpersisted``.
    public let unpersistedIDs: Set<UUID>?

    /// Every held ID whose stored value the merge declined to apply — never
    /// empty. Set only for ``Kind/mergeWithheld``.
    public let withheldIDs: Set<UUID>?

    /// How many rows a tick merged out of persistent history.
    /// Set only for ``Kind/remoteChangesMerged``.
    public let mergedCount: Int?

    /// How many history transactions were deleted.
    /// Set only for ``Kind/historyPruned``.
    public let prunedCount: Int?

    /// Why a tick fell back to re-reading everything, in prose.
    /// Set only for ``Kind/historyUnavailable``.
    public let fallbackReason: String?

    /// Creates a diagnostic. Prefer the static constructors, which fill in the
    /// payload each kind actually carries.
    public init(
        kind: Kind,
        entityType: String? = nil,
        duplicateCount: Int? = nil,
        drainCount: Int? = nil,
        unpersistedIDs: Set<UUID>? = nil,
        withheldIDs: Set<UUID>? = nil,
        mergedCount: Int? = nil,
        prunedCount: Int? = nil,
        fallbackReason: String? = nil
    ) {
        self.kind = kind
        self.entityType = entityType
        self.duplicateCount = duplicateCount
        self.drainCount = drainCount
        self.unpersistedIDs = unpersistedIDs
        self.withheldIDs = withheldIDs
        self.mergedCount = mergedCount
        self.prunedCount = prunedCount
        self.fallbackReason = fallbackReason
    }

    /// `count` rows of `entityType` were collapsed away on read.
    public static func duplicateRowsCollapsed(entityType: String, count: Int) -> Self {
        Self(kind: .duplicateRowsCollapsed, entityType: entityType, duplicateCount: count)
    }

    /// `afterReduce` fired `drainCount` times in a single debounce interval.
    public static func possibleDispatchLoop(drainCount: Int) -> Self {
        Self(kind: .possibleDispatchLoop, drainCount: drainCount)
    }

    /// The unpersisted set for `entityType` is now `ids` — empty means recovered.
    public static func writesUnpersisted(entityType: String, ids: Set<UUID>) -> Self {
        Self(kind: .writesUnpersisted, entityType: entityType, unpersistedIDs: ids)
    }

    /// A merge declined to apply storage's value for `ids` because each one was
    /// held for editing.
    public static func mergeWithheld(entityType: String, ids: Set<UUID>) -> Self {
        Self(kind: .mergeWithheld, entityType: entityType, withheldIDs: ids)
    }

    /// A tick merged `count` identities read out of persistent history.
    public static func remoteChangesMerged(count: Int) -> Self {
        Self(kind: .remoteChangesMerged, mergedCount: count)
    }

    /// A tick re-read every registered entity because `reason` stopped it
    /// narrowing the work.
    public static func historyUnavailable(reason: String) -> Self {
        Self(kind: .historyUnavailable, fallbackReason: reason)
    }

    /// `count` transactions older than the retention window were deleted.
    public static func historyPruned(count: Int) -> Self {
        Self(kind: .historyPruned, prunedCount: count)
    }

    /// A one-line summary, suitable for a log line or a `default:` branch that
    /// meets a kind it doesn't recognise.
    public var description: String {
        let entity = entityType ?? "?"
        switch kind {
        case .duplicateRowsCollapsed:
            return "\(entity): \(duplicateCount ?? 0) duplicate row(s) collapsed on read"
        case .possibleDispatchLoop:
            return "possible dispatch loop: \(drainCount ?? 0) drains in one debounce interval"
        case .writesUnpersisted:
            let ids = unpersistedIDs ?? []
            return ids.isEmpty
                ? "\(entity): all writes are now persisted"
                : "\(entity): \(ids.count) write(s) not on disk"
        case .mergeWithheld:
            return "\(entity): \((withheldIDs ?? []).count) remote change(s) withheld by an editing hold"
        case .remoteChangesMerged:
            return "merged \(mergedCount ?? 0) changed row(s) from persistent history"
        case .historyUnavailable:
            return "re-read every entity: \(fallbackReason ?? "history was unavailable")"
        case .historyPruned:
            return "pruned \(prunedCount ?? 0) history transaction(s)"
        default:
            // A kind from a newer version. Still worth printing.
            return kind.rawValue
        }
    }
}

/// Receives ``PersistenceDiagnostic`` values from the persistence stack.
public typealias PersistenceDiagnosticHandler = @Sendable (PersistenceDiagnostic) -> Void

/// Everywhere a registration reports to.
///
/// Bundled into one value because both channels travel together through the
/// same four closures on ``PersistedEntity`` — a second bare parameter would
/// have to be threaded through all of them again the next time a channel is
/// added. Supplied by ``PersistenceCoordinator`` at call time, which is what
/// keeps the registration free of any late-bound mutable state.
struct PersistenceObservers: Sendable {
    let onFailure: PersistenceFailureHandler
    let onDiagnostic: PersistenceDiagnosticHandler
}

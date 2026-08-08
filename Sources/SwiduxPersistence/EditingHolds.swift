//
//  EditingHolds.swift
//  SwiduxPersistence
//
//  The one exemption an app declares by hand: an entity being edited in a view
//  whose value has not been dispatched to the store yet.
//

import Foundation

/// IDs an app has declared it is editing, exempt from a re-hydration merge for
/// as long as the hold is in force.
///
/// Every other exemption is inferred: ``Swidux/EntityStore/changes``, the
/// writer's drained-but-unflushed buffers, and the failed-flush ledger all
/// describe writes the *store* has seen. A value still sitting in a view's local
/// `@State` is in none of them, so under
/// ``MergePolicy/preferRemote`` a remote edit can land underneath a half-typed
/// field and the user's next keystroke dispatches against a value that changed
/// out from under them.
///
/// A hold closes exactly that window, and nothing wider:
///
/// ```swift
/// TextEditor(text: $draft)
///     .holdsEntity(note.id, in: persistence.editing)
/// ```
///
/// Prefer that modifier — it takes the hold when the editor appears and gives it
/// back when the editor goes away, so there is no release to forget. Reach for
/// ``hold(_:)`` and ``release(_:)`` directly only where the editing session
/// isn't a view's lifetime.
///
/// ## What a hold is not
///
/// A hold **defers a remote change; it does not veto one.** Release it and the
/// next merge applies whatever storage holds, including a deletion made
/// elsewhere. The worst a leaked hold can do is strand one row at a stale
/// value, which is what ``MergePolicy/preferInMemory`` does on purpose. It is
/// not data loss, and it is not silent either: a merge that actually withheld a
/// differing value reports
/// ``PersistenceDiagnostic/mergeWithheld(entityType:ids:)``.
///
/// Two alternatives cost less and are often enough. `store.binding(_:sending:)`
/// dispatches on write, which makes the value a drained-but-unflushed one and
/// covers it already. ``MergePolicy/preferInMemory`` exempts a whole collection
/// permanently. A hold sits between them: remote-wins stays on everywhere else,
/// and here only while the user is actually typing.
@MainActor
public final class EditingHolds {
    /// Refcounted rather than a plain set: two views editing one entity is
    /// ordinary — a list row and a detail pane — and whichever disappears first
    /// must not release a hold the other still needs.
    private var depths: [UUID: Int] = [:]

    /// Creates an empty ledger. ``PersistenceCoordinator`` makes its own; an app
    /// normally uses that one rather than building this directly.
    public init() {}

    /// Every ID currently held, in no particular order.
    public var ids: Set<UUID> { Set(depths.keys) }

    /// Whether nothing at all is held.
    public var isEmpty: Bool { depths.isEmpty }

    /// Whether `id` is held by at least one holder.
    public func isHolding(_ id: UUID) -> Bool { depths[id] != nil }

    /// Exempts `id` from the merge until a matching ``release(_:)``.
    ///
    /// Balance every call. Prefer ``SwiftUI/View/holdsEntity(_:in:)``, which
    /// balances them for you.
    public func hold(_ id: UUID) {
        depths[id, default: 0] += 1
    }

    /// Gives back one hold on `id`, exempting it again once the last holder
    /// releases.
    ///
    /// Releasing an ID that isn't held is a no-op. It cannot leave a debt that
    /// swallows the next real hold — that would silently disarm the protection
    /// rather than merely wasting a call.
    public func release(_ id: UUID) {
        guard let depth = depths[id] else { return }
        depths[id] = depth > 1 ? depth - 1 : nil
    }

    /// Drops every hold at once.
    ///
    /// For a coarse "the editor closed" moment, and for recovering from a leak
    /// an app has detected via
    /// ``PersistenceDiagnostic/mergeWithheld(entityType:ids:)``.
    public func releaseAll() {
        depths.removeAll()
    }

    /// How many holders `id` has. Test seam for the refcounting.
    func depth(of id: UUID) -> Int { depths[id] ?? 0 }
}

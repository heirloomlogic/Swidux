//
//  EditingHoldModifier.swift
//  SwiduxPersistence
//
//  Ties an editing hold to a view's lifetime, so the release can't be forgotten.
//

import Foundation
import SwiftUI

extension View {
    /// Exempts `id` from re-hydration merges for as long as this view is on
    /// screen editing it.
    ///
    /// Use this wherever a view keeps an entity's value in local `@State` — a
    /// `TextField`, a `TextEditor`, a drag in progress — instead of dispatching
    /// every keystroke. The store cannot see that value, so without a hold a
    /// remote edit can land underneath it:
    ///
    /// ```swift
    /// TextEditor(text: $draft)
    ///     .holdsEntity(note.id, in: persistence.editing)
    ///     .onDisappear { store.send(.commitDraft(note.id, draft)) }
    /// ```
    ///
    /// The hold is taken when the view appears and given back when it goes away
    /// — or when `id` changes, which re-takes the hold on the new entity. Pass
    /// `nil` to hold nothing, so a `@FocusState`-driven id can arm and disarm
    /// the hold as focus moves:
    ///
    /// ```swift
    /// .holdsEntity(isFocused ? note.id : nil, in: persistence.editing)
    /// ```
    ///
    /// A hold defers a remote change rather than vetoing it: once released, the
    /// next merge applies whatever storage holds. See ``EditingHolds``.
    ///
    /// - Parameters:
    ///   - id: The entity being edited, or `nil` to hold nothing.
    ///   - holds: The ledger the merge consults — normally
    ///     ``PersistenceCoordinator/editing``.
    /// - Returns: This view, holding `id` for as long as it is on screen.
    public func holdsEntity(_ id: UUID?, in holds: EditingHolds) -> some View {
        task(id: id) {
            guard let id else { return }
            await maintainHold(on: id, in: holds)
        }
    }
}

/// Holds `id` until the calling task is cancelled, then gives the hold back.
///
/// Split out of the modifier so the release-on-cancellation contract — the
/// whole reason the modifier is the recommended path — is reachable from a test
/// without rendering a view.
@MainActor
func maintainHold(on id: UUID, in holds: EditingHolds) async {
    holds.hold(id)
    defer { holds.release(id) }
    // SwiftUI cancels a `.task(id:)` when its view disappears or its id
    // changes, which is exactly the span a hold should cover. `Task.sleep`
    // throws the moment that happens; the loop is only here to re-park on a
    // wake-up that wasn't a cancellation.
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60 * 60))
    }
}

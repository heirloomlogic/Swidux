//
//  EditingHoldsTests.swift
//  SwiduxPersistenceTests
//
//  Cover for #60: the editing-hold ledger and the view helper that owns a
//  hold's lifetime. The merge-side behaviour lives in
//  `PersistenceCoordinatorTests`; this suite is about the bookkeeping that
//  keeps a hold from leaking.
//

import Foundation
import Testing

@testable import SwiduxPersistence

@Suite("Editing holds")
@MainActor
struct EditingHoldsTests {
    @Test("a fresh ledger holds nothing")
    func emptyByDefault() {
        let holds = EditingHolds()

        #expect(holds.ids.isEmpty)
        #expect(holds.isEmpty)
        #expect(!holds.isHolding(UUID()))
    }

    @Test("a hold registers the ID, and releasing it frees it again")
    func holdAndRelease() {
        let holds = EditingHolds()
        let id = UUID()

        holds.hold(id)
        #expect(holds.isHolding(id))
        #expect(holds.ids == [id])

        holds.release(id)
        #expect(!holds.isHolding(id))
        #expect(holds.isEmpty)
    }

    @Test("overlapping holds compose — the ID is free only once the last one releases")
    func holdsAreRefcounted() {
        // Two views editing the same entity is legitimate (a list row and a
        // detail pane). Without refcounting, the first to disappear would
        // release a hold the other still needs.
        let holds = EditingHolds()
        let id = UUID()

        holds.hold(id)
        holds.hold(id)
        holds.release(id)

        #expect(holds.isHolding(id), "one holder is still editing")

        holds.release(id)
        #expect(!holds.isHolding(id))
    }

    @Test("releasing an ID that was never held is a no-op, and can't drive the count negative")
    func releasingAnUnheldIDIsHarmless() {
        let holds = EditingHolds()
        let id = UUID()

        holds.release(id)
        holds.release(id)
        #expect(holds.isEmpty)

        // A stray release must not leave a debt that swallows the next real
        // hold — that would silently disarm the protection.
        holds.hold(id)
        #expect(holds.isHolding(id))
    }

    @Test("holds are tracked per ID")
    func holdsAreIndependent() {
        let holds = EditingHolds()
        let edited = UUID()
        let other = UUID()

        holds.hold(edited)
        #expect(holds.ids == [edited])
        #expect(!holds.isHolding(other))
    }

    @Test("releaseAll clears every hold regardless of depth")
    func releaseAllClearsEverything() {
        let holds = EditingHolds()
        let first = UUID()
        let second = UUID()
        holds.hold(first)
        holds.hold(first)
        holds.hold(second)

        holds.releaseAll()

        #expect(holds.isEmpty)
    }

    // MARK: - Lifetime

    @Test("the view helper releases the hold it took when its task is cancelled")
    func maintainedHoldReleasesOnCancellation() async throws {
        // This is what makes the modifier leak-safe: SwiftUI cancels the
        // `.task` when the view disappears or the id changes, and the release
        // rides on that cancellation rather than on an app remembering to call
        // it.
        let holds = EditingHolds()
        let id = UUID()

        let task = Task { @MainActor in await maintainHold(on: id, in: holds) }
        try await poll(until: { holds.isHolding(id) })
        #expect(holds.isHolding(id), "the helper takes the hold as soon as it runs")

        task.cancel()
        await task.value

        #expect(!holds.isHolding(id), "and gives it back on cancellation")
    }

    @Test("a cancelled helper releases only its own hold")
    func maintainedHoldDoesNotStealAnotherHolder() async throws {
        let holds = EditingHolds()
        let id = UUID()
        holds.hold(id)  // a second editor, held by hand

        let task = Task { @MainActor in await maintainHold(on: id, in: holds) }
        try await poll(until: { holds.depth(of: id) == 2 })
        #expect(holds.depth(of: id) == 2, "both holders are counted")

        task.cancel()
        await task.value

        #expect(holds.isHolding(id), "the hand-held one outlives the helper's")
    }
}

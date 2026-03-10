# Swidux Code Patterns Reference

## Table of Contents

- [Effect.swift](#effectswift)
- [AppState.swift](#appstateswift)
- [AppAction.swift](#appactionswift)
- [AppEnvironment.swift](#appenvironmentswift)
- [Value Type (Domain Model)](#value-type-domain-model)
- [SwiftData Model](#swiftdata-model)
- [DB Actor](#db-actor)
- [Feature Reducer](#feature-reducer)
- [AppReducer](#appreducer)
- [AppStore](#appstore)
- [App Entry Point](#app-entry-point)
- [View Pattern](#view-pattern)
- [Controlled Component Pattern](#controlled-component-pattern)
- [Testing Pattern](#testing-pattern)
- [SwiftData Integration Test](#swiftdata-integration-test)

---

Copy-paste ready templates derived from [Adagio](file:///Users/sessions/HeirloomLogic/adagio), the canonical Swidux reference app. All patterns use:
- **iOS 18+ / macOS 15+** (`@Observable`, `@Environment(Type.self)`)
- **Swift 6.2+ Approachable Concurrency** (minimal explicit `@MainActor`)
- **Swift Testing** (`@Test`, `@Suite`)
- **EntityStore** for persisted collections, **PersistenceMiddleware** for automatic writes

---

## Effect.swift

```swift
import Foundation

/// Concrete typealiases specializing Swidux's generic effect system.
typealias Send = Swidux.Send<AppAction>
typealias Effect = Swidux.Effect<AppAction>
```

---

## AppState.swift

```swift
import Foundation
@_exported import Swidux

/// The root state value type passed to reducers.
/// EntityStores track their own changes — the persistence middleware drains them.
/// AppStore unpacks this into separate @Observable stored properties.
nonisolated struct AppState: Sendable {

    // MARK: - Persisted Entity Stores

    var items = EntityStore<Item>()
    var tags  = EntityStore<Tag>()

    // MARK: - Ephemeral UI State

    var ui = UIState()
}

// MARK: - UI State

/// Ephemeral state that is NOT persisted — navigation, selection, feature slices.
nonisolated struct UIState: Sendable {
    var selectedItemID: UUID?
    var isInspectorOpen: Bool = true

    // Feature slices
    var itemBrowser: ItemBrowserState = .init()
}

// MARK: - Feature State Slices

nonisolated struct ItemBrowserState: Sendable {
    var expandedIDs: Set<UUID> = []
    var editingID: UUID?
}

// MARK: - Convenience Accessors

extension AppState {
    var selectedItem: Item? {
        guard let id = ui.selectedItemID else { return nil }
        return items[id]
    }
}
```

---

## AppAction.swift

```swift
import Foundation

enum AppAction: Sendable {
    case itemBrowser(ItemBrowserAction)
    case inspector(InspectorAction)

    // Targeted inserts (for optimistic UI creates from effects)
    case itemInserted(Item)
}

// MARK: - Feature Actions

enum ItemBrowserAction: Sendable {
    // Selection
    case selectItem(UUID?)
    case restoreSelection

    // CRUD — mutate EntityStore, middleware persists
    case create
    case delete(UUID)
    case rename(UUID, newName: String)
    case reorder(fromIndex: Int, toIndex: Int)
}
```

---

## AppEnvironment.swift

```swift
import Foundation
import SwiftData
import os

struct AppEnvironment: Sendable {
    let analytics: any AnalyticsServiceProtocol
    let preferences: any PreferencesServiceProtocol
    let logger: Logger
    let modelContainer: ModelContainer?

    static func live(modelContainer: ModelContainer) -> AppEnvironment {
        AppEnvironment(
            analytics: AnalyticsService(),
            preferences: PreferencesService(),
            logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "app"),
            modelContainer: modelContainer
        )
    }

    static func mock() -> AppEnvironment {
        AppEnvironment(
            analytics: MockAnalyticsService(),
            preferences: MockPreferencesService(),
            logger: Logger(subsystem: "app.tests", category: "mock"),
            modelContainer: nil
        )
    }
}
```

---

## Value Type (Domain Model)

```swift
/// Domain value type — used in views and state.
/// The SwiftData persistence model is `ItemModel`.
nonisolated struct Item: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var sortIndex: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}
```

---

## SwiftData Model

SwiftData models are internal to persistence. Views never see them.

```swift
import SwiftData

@Model
final class ItemModel {
    @Attribute(.unique)
    var id: UUID

    var name: String
    var sortIndex: Int
    var createdAt: Date

    init(id: UUID = UUID(), name: String, sortIndex: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    /// Converts this persistence model to a domain value type.
    func toDomain() -> Item {
        Item(id: id, name: name, sortIndex: sortIndex, createdAt: createdAt)
    }

    /// Updates this persistence model from a domain value type.
    func update(from domain: Item) {
        name = domain.name
        sortIndex = domain.sortIndex
    }
}
```

---

## DB Actor

```swift
import SwiftData

// MARK: - Protocol

/// Protocol for item-related database operations.
/// Used by the persistence middleware for hydration, upserts, and deletes.
protocol ItemDBProtocol: Sendable {
    func fetchAll() async throws -> [Item]
    func upsert(_ item: Item) async throws
    func delete(id: UUID) async throws
}

// MARK: - Implementation

@ModelActor
actor ItemDB: ItemDBProtocol {

    func fetchAll() async throws -> [Item] {
        let descriptor = FetchDescriptor<ItemModel>(sortBy: [SortDescriptor(\.sortIndex)])
        return try modelContext.fetch(descriptor).map { $0.toDomain() }
    }

    func upsert(_ item: Item) async throws {
        if let existing = try findItem(item.id) {
            existing.update(from: item)
        } else {
            let model = ItemModel(id: item.id, name: item.name, sortIndex: item.sortIndex, createdAt: item.createdAt)
            modelContext.insert(model)
        }
        try modelContext.save()
    }

    func delete(id: UUID) async throws {
        guard let model = try findItem(id) else { return }
        modelContext.delete(model)
        try modelContext.save()
    }

    // MARK: - Private Helpers

    private func findItem(_ id: UUID) throws -> ItemModel? {
        var descriptor = FetchDescriptor<ItemModel>()
        descriptor.predicate = #Predicate { $0.id == id }
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

// MARK: - Mock

actor MockItemDB: ItemDBProtocol {
    func fetchAll() async throws -> [Item] { [] }
    func upsert(_ item: Item) async throws {}
    func delete(id: UUID) async throws {}
}
```

---

## Feature Reducer

Reducers are structs conforming to `SwiduxReducer`. They return `Effect?` — **`nil` for state-only changes, an effect for async work**. Persistence happens automatically via the middleware; effects are only for non-persistence work (analytics, network, preferences).

```swift
import Foundation

struct ItemBrowserReducer: SwiduxReducer {

    func reduce(
        state: inout AppState,
        action: ItemBrowserAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {

        // MARK: - Selection

        case .selectItem(let id):
            state.ui.selectedItemID = id
            // Persist selection preference via effect
            let preferences = environment.preferences
            return Effect { _ in
                await preferences.setSelectedItemID(id)
            }

        case .restoreSelection:
            let preferences = environment.preferences
            let allItems = state.items
            return Effect { send in
                if let id = await preferences.getSelectedItemID(),
                   allItems.contains(id) {
                    await send(.itemBrowser(.selectItem(id)))
                }
            }

        // MARK: - CRUD

        case .create:
            let analytics = environment.analytics
            // State-first — middleware persists
            let newItem = Item(
                name: "New Item",
                sortIndex: state.items.count
            )
            state.items[newItem.id] = newItem
            state.ui.selectedItemID = newItem.id
            return Effect { _ in
                await analytics.track(event: .itemCreated)
            }

        case .delete(let id):
            let analytics = environment.analytics
            if state.ui.selectedItemID == id {
                state.ui.selectedItemID = nil
            }
            // Remove from state — middleware detects deletion and persists
            state.items[id] = nil
            return Effect { _ in
                await analytics.track(event: .itemDeleted)
            }

        case .rename(let id, let newName):
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Update state — middleware detects change and persists
            state.items.modify(id) { $0.name = trimmed }

        case .reorder(let fromIndex, let toIndex):
            var sorted = state.items.values.sorted { $0.sortIndex < $1.sortIndex }
            guard fromIndex >= 0, fromIndex < sorted.count,
                  toIndex >= 0, toIndex < sorted.count
            else { return nil }
            let item = sorted.remove(at: fromIndex)
            sorted.insert(item, at: toIndex)
            for (i, reorderedItem) in sorted.enumerated() {
                state.items.modify(reorderedItem.id) { $0.sortIndex = i }
            }
        }

        return nil
    }
}
```

---

## AppReducer

```swift
import SwiftData

struct AppReducer: SwiduxReducer {
    let itemBrowser = ItemBrowserReducer()
    let inspector = InspectorReducer()

    // DB actors for hydration and StateWriter closures
    let itemDB: any ItemDBProtocol
    let tagDB:  any TagDBProtocol

    static func live(modelContainer: ModelContainer) -> AppReducer {
        AppReducer(
            itemDB: ItemDB(modelContainer: modelContainer),
            tagDB: TagDB(modelContainer: modelContainer)
        )
    }

    static func mock() -> AppReducer {
        AppReducer(
            itemDB: MockItemDB(),
            tagDB: MockTagDB()
        )
    }

    func reduce(
        state: inout AppState,
        action: AppAction,
        environment: AppEnvironment
    ) -> Effect? {
        switch action {

        // Targeted inserts (dispatched from effects for optimistic creates)
        case .itemInserted(let item):
            state.items[item.id] = item

        // Feature delegation
        case .itemBrowser(let action):
            return itemBrowser.reduce(state: &state, action: action, environment: environment)

        case .inspector(let action):
            return inspector.reduce(state: &state, action: action, environment: environment)
        }

        return nil
    }
}
```

---

## AppStore

```swift
import Observation
import SwiftData
import os

/// The single source of truth for app state.
/// Entity stores are separate stored properties so @Observable tracks each independently.
@Observable
final class AppStore: SwiduxDispatcher {

    // MARK: - Entity Stores (persisted via middleware)

    private(set) var items = EntityStore<Item>()
    private(set) var tags  = EntityStore<Tag>()

    // MARK: - Ephemeral State

    private(set) var ui = UIState()

    // MARK: - Dependencies

    private let environment: AppEnvironment
    private let reducer: AppReducer
    private let persistence: PersistenceMiddleware<AppState>

    // MARK: - Init

    init(
        initialState: AppState = .init(),
        environment: AppEnvironment,
        reducer: AppReducer
    ) {
        self.items = initialState.items
        self.tags  = initialState.tags
        self.ui    = initialState.ui

        self.environment = environment
        self.reducer = reducer

        // ⚠️ Writer ordering: leaves first, aggregates last
        self.persistence = PersistenceMiddleware(
            writers: [
                StateWriter(keyPath: \.tags) { [reducer] writes, deletes in
                    for tag in writes { try? await reducer.tagDB.upsert(tag) }
                    for id in deletes { try? await reducer.tagDB.delete(id: id) }
                },
                StateWriter(keyPath: \.items) { [reducer] writes, deletes in
                    for item in writes { try? await reducer.itemDB.upsert(item) }
                    for id in deletes  { try? await reducer.itemDB.delete(id: id) }
                },
            ],
            logger: environment.logger
        )
    }

    // MARK: - Dispatch

    func send(_ action: AppAction) {
        // Pack observable properties into AppState for the reducer
        var state = AppState(items: items, tags: tags, ui: ui)

        let effect = reducer.reduce(
            state: &state,
            action: action,
            environment: environment
        )

        // Drain changelogs and schedule persistence
        persistence.afterReduce(state: &state)

        // Unpack back to observable properties — guard with equality checks.
        // @Observable fires change notifications on every `set`, even if the
        // value is identical. Unconditional writes cause cascading re-renders.
        if items != state.items { items = state.items }
        if tags != state.tags   { tags = state.tags }
        if ui != state.ui       { ui = state.ui }

        // Use @concurrent to run the effect off the MainActor.
        // A bare Task { } inherits MainActor isolation here,
        // keeping the entire effect on the main thread.
        if let effect {
            let send: Send = { [weak self] action in
                self?.send(action)
            }
            Task { @concurrent in
                await effect(send)
            }
        }
    }

    // MARK: - Hydration

    /// Loads all persisted entities from the database into in-memory EntityStores.
    /// Call once from onAppear. Subsequent mutations flow through the reducer.
    func hydrate() async {
        do {
            async let fetchedItems = reducer.itemDB.fetchAll()
            async let fetchedTags  = reducer.tagDB.fetchAll()

            let (loadedItems, loadedTags) = try await (fetchedItems, fetchedTags)

            var itemStore = EntityStore<Item>()
            for item in loadedItems { itemStore[item.id] = item }

            var tagStore = EntityStore<Tag>()
            for tag in loadedTags { tagStore[tag.id] = tag }

            self.items = itemStore
            self.tags  = tagStore
        } catch {
            environment.logger.error("Hydration failed: \(error)")
        }
    }
}
```

---

## App Entry Point

```swift
import SwiftData
import SwiftUI

@main
struct MyApp: App {
    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([ItemModel.self, TagModel.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do { return try ModelContainer(for: schema, configurations: [config]) }
        catch { fatalError("Could not create ModelContainer: \(error)") }
    }()

    @State private var store: AppStore

    init() {
        let environment = AppEnvironment.live(modelContainer: sharedModelContainer)
        let reducer = AppReducer.live(modelContainer: sharedModelContainer)
        _store = State(initialValue: AppStore(environment: environment, reducer: reducer))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .onAppear {
                    Task {
                        await store.hydrate()
                        store.send(.itemBrowser(.restoreSelection))
                    }
                }
        }
    }
}
```

---

## View Pattern

```swift
import SwiftUI

struct ItemListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        // Sort once per body evaluation — avoid sorting inline in ForEach
        let sorted = store.items.values.sorted { $0.sortIndex < $1.sortIndex }
        List {
            ForEach(sorted) { item in
                ItemRow(item: item)
            }
        }
        .toolbar {
            Button("Add") { store.send(.itemBrowser(.create)) }
        }
    }
}

struct ItemRow: View {
    @Environment(AppStore.self) private var store
    let item: Item  // Value type, not @Model

    var body: some View {
        Text(item.name)
    }
}

#Preview {
    ItemListView()
        .environment(AppStore(environment: .mock(), reducer: .mock()))
}
```

---

## Controlled Component Pattern

```swift
// ✅ Store-bound — no local state
TextField("Name", text: Binding(
    get: { store.items[itemID]?.name ?? "" },
    set: { store.send(.itemBrowser(.rename(itemID, newName: $0))) }
))

// ❌ NEVER — local state + sync dance
@State private var text = ""
.onAppear { text = store.items[itemID]?.name ?? "" }
.onChange(of: text) { store.send(.itemBrowser(.rename(itemID, newName: $0))) }
```

---

## Testing Pattern

```swift
import Testing
@testable import MyApp

@Suite("ItemBrowser Reducer")
struct ItemBrowserReducerTests {

    @Test("create inserts item and selects it")
    func create() {
        var state = AppState()
        let reducer = ItemBrowserReducer()
        _ = reducer.reduce(state: &state, action: .create, environment: .mock())
        #expect(state.items.count == 1)
        #expect(state.ui.selectedItemID == state.items.values.first?.id)
    }

    @Test("delete removes item and clears selection")
    func delete() {
        var state = AppState()
        let item = Item(name: "Test")
        state.items[item.id] = item
        state.ui.selectedItemID = item.id

        let reducer = ItemBrowserReducer()
        _ = reducer.reduce(state: &state, action: .delete(item.id), environment: .mock())
        #expect(state.items.count == 0)
        #expect(state.ui.selectedItemID == nil)
    }

    @Test("rename updates item name via modify")
    func rename() {
        var state = AppState()
        let item = Item(name: "Old")
        state.items[item.id] = item

        let reducer = ItemBrowserReducer()
        _ = reducer.reduce(state: &state, action: .rename(item.id, newName: "New"), environment: .mock())
        #expect(state.items[item.id]?.name == "New")
    }
}
```

---

## SwiftData Integration Test

```swift
@Test("DB actor upserts and fetches")
func dbUpsertsAndFetches() async throws {
    let schema = Schema([ItemModel.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let db = ItemDB(modelContainer: container)

    let item = Item(name: "Test")
    try await db.upsert(item)
    let all = try await db.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].name == "Test")
}
```

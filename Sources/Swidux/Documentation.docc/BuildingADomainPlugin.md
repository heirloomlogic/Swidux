# Building a Domain Plugin

Create a self-contained feature plugin with its own state, actions, and effects.

## Overview

Domain plugins follow a consistent pattern: define feature state and actions, implement the ``SwiduxPlugin`` protocol using the `reduce` hook, and wire the plugin into the host app at registration time. This guide walks through building a plugin from scratch.

The example builds a fictional "Announcements" plugin that fetches a remote message and displays it.

## The Three Wiring Pieces

Every domain plugin stores three closures that bridge its local types to the host app's root types:

1. **State keypath** — `WritableKeyPath<RootState, FeatureState>` locates the plugin's state slice within root state.
2. **Action lifter** — `(FeatureAction) -> RootAction` wraps local actions into the root action enum.
3. **Action extractor** — `(RootAction) -> FeatureAction?` downcasts root actions to the plugin's local type, returning `nil` for actions that belong to other features.

These are closures, not protocols. The host app provides them at init — no associated-type gymnastics or conformance wiring needed.

## Step 1: Define Feature State

```swift
public struct AnnouncementState: Sendable, Equatable {
    public var message: String?
    public var isLoading: Bool
    public var error: String?

    public init(
        message: String? = nil,
        isLoading: Bool = false,
        error: String? = nil
    ) {
        self.message = message
        self.isLoading = isLoading
        self.error = error
    }
}
```

Keep state minimal — only what the UI needs to render and the reducer needs to decide.

## Step 2: Define Feature Actions

```swift
public enum AnnouncementAction: Sendable {
    case fetch
    case messageReceived(String?)
    case fetchFailed(String)
    case dismiss
}
```

Actions are the plugin's public API. The host app dispatches them by wrapping in the root action enum.

## Step 3: Define the Service

Inject async dependencies as a struct with closure properties. This makes testing trivial — swap closures instead of subclassing or mocking protocols. (Reach for a protocol instead only when third parties will implement the backend — see the service-shapes principle in <doc:DesignPrinciples>.)

```swift
public struct AnnouncementService: Sendable {
    public var fetch: @Sendable () async throws -> String?

    public init(fetch: @escaping @Sendable () async throws -> String?) {
        self.fetch = fetch
    }

    public static func mock(message: String? = "Test") -> Self {
        AnnouncementService { message }
    }
}
```

## Step 4: Implement the Plugin

```swift
import Swidux

@MainActor
public struct AnnouncementPlugin<RootState, RootAction>: SwiduxPlugin {
    public typealias State = RootState
    public typealias Action = RootAction

    private let stateKeyPath: WritableKeyPath<RootState, AnnouncementState>
    private let toRootAction: @Sendable (AnnouncementAction) -> RootAction
    private let extractAction: @Sendable (RootAction) -> AnnouncementAction?
    private let service: AnnouncementService

    public init(
        state: WritableKeyPath<RootState, AnnouncementState>,
        action toRootAction: @escaping @Sendable (AnnouncementAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> AnnouncementAction?,
        service: AnnouncementService
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.service = service
    }

    public func reduce(
        state: inout RootState,
        action: RootAction
    ) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        let localEffect = reduceLocal(
            state: &state[keyPath: stateKeyPath],
            action: local
        )
        guard let localEffect else { return nil }
        return localEffect.map(toRootAction)
    }

    private func reduceLocal(
        state: inout AnnouncementState,
        action: AnnouncementAction
    ) -> Effect<AnnouncementAction>? {
        switch action {
        case .fetch:
            state.isLoading = true
            let service = self.service
            return Effect { send in
                do {
                    let message = try await service.fetch()
                    await send(.messageReceived(message))
                } catch {
                    await send(.fetchFailed(error.localizedDescription))
                }
            }

        case .messageReceived(let message):
            state.message = message
            state.isLoading = false
            state.error = nil

        case .fetchFailed(let message):
            state.isLoading = false
            state.error = message

        case .dismiss:
            state.message = nil
        }
        return nil
    }
}
```

The public `reduce` method follows a fixed pattern: guard-extract the local action, delegate to a private `reduceLocal`, and lift any returned effect. The private `reduceLocal` is where feature logic lives — it looks like any standard Swidux reducer.

> Important: Domain plugins implement only `reduce`. The `willReduce` and `afterReduce` hooks are reserved for action-agnostic infrastructure like undo and persistence. See <doc:PluginArchitecture> for the full distinction.

## Step 5: Wire Into the Host App

### Add state and action

```swift
@Swidux
struct AppState: Equatable, Sendable {
    var items = EntityStore<Item>()
    // ...
    var announcements = AnnouncementState()
}

enum AppAction: Sendable {
    case items(ItemAction)
    // ...
    case announcements(AnnouncementAction)
}
```

### Register the plugin

```swift
plugins.register(AnnouncementPlugin(
    state: \.announcements,
    action: AppAction.announcements,
    extractAction: {
        if case .announcements(let a) = $0 { return a }
        return nil
    },
    service: .init { try await api.fetchAnnouncement() }
))
```

### Dispatch from views

```swift
store.send(.announcements(.fetch))
```

## The Effect Lifting Pattern

The lift pattern bridges `Effect<FeatureAction>` to `Effect<RootAction>`. It appears in every domain plugin's `reduce` method:

```swift
return localEffect.map(toRootAction)
```

`map` wraps each local action in the root enum and preserves the effect's cancellation metadata. Use it when lifting an effect so the store can register cancellation before starting its operation. Construct new work with `Effect { send in ... }`; invoke an effect directly in a test with `try await effect { action in ... }`.

## Testing Domain Plugins

Test plugins without a real app store. Define minimal `TestState` and `TestAction` types, instantiate the plugin with test wiring, and assert on state mutations and effect presence.

```swift
@Suite("AnnouncementPlugin")
@MainActor
struct AnnouncementPluginTests {
    struct TestState: Sendable, Equatable {
        var announcements = AnnouncementState()
    }

    enum TestAction: Sendable {
        case announcements(AnnouncementAction)
        case unrelated
    }

    func makePlugin(
        service: AnnouncementService = .mock()
    ) -> AnnouncementPlugin<TestState, TestAction> {
        AnnouncementPlugin(
            state: \.announcements,
            action: TestAction.announcements,
            extractAction: {
                if case .announcements(let a) = $0 { return a }
                return nil
            },
            service: service
        )
    }

    @Test("ignores unrelated actions")
    func ignoresUnrelated() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(state: &state, action: .unrelated)
        #expect(effect == nil)
    }

    @Test("messageReceived updates state")
    func messageReceived() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .announcements(.messageReceived("Hello"))
        )
        #expect(effect == nil)
        #expect(state.announcements.message == "Hello")
        #expect(state.announcements.isLoading == false)
    }

    @Test("fetch returns an effect")
    func fetchReturnsEffect() {
        let plugin = makePlugin()
        var state = TestState()
        let effect = plugin.reduce(
            state: &state,
            action: .announcements(.fetch)
        )
        #expect(effect != nil)
        #expect(state.announcements.isLoading == true)
    }
}
```

The `TestState` / `TestAction` harness is lightweight and reusable. Each plugin's test suite defines its own pair, keeping tests isolated from the real app's types.

## Next Steps

- <doc:PluginArchitecture> — Understand the lifecycle hooks and core-vs-domain distinction
- <doc:ArchitectureGuide> — The snapshot pattern and `@Observable` performance

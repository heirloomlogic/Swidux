//
//  TestFixtures.swift
//  SwiduxTests
//
//  Shared test infrastructure for all Swidux tests.
//

import Foundation
import Swidux

// MARK: - Test Entity

/// Minimal entity for testing EntityStore and StateWriter.
struct TestEntity: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String = "default") {
        self.id = id
        self.name = name
    }
}

// MARK: - Test State

/// Root state containing one or two EntityStores for middleware tests.
struct TestState: Sendable, Equatable {
    var items: EntityStore<TestEntity> = EntityStore()
    var extras: EntityStore<TestEntity> = EntityStore()
}

// MARK: - Test Action

/// Simple action enum for reducer/dispatcher tests.
enum TestAction: Sendable, Equatable {
    case insert(TestEntity)
    case delete(UUID)
    case rename(UUID, String)
    case noOp
    case effectAction(String)
}

// MARK: - Waiting

/// Polls `condition` on the main actor until it holds or `timeout` elapses.
///
/// Debounce timers, flush tasks and notification delivery all complete on their
/// own schedule, so tests wait for an observable state rather than sleeping a
/// fixed span and hoping. A sleep that is generous on an idle machine is not
/// generous on a loaded CI runner, and the failure it produces looks like a
/// product bug rather than a scheduling one.
///
/// Returns as soon as the condition holds; on timeout it returns too, leaving
/// the caller's `#expect` to report the failure with a useful message.
@MainActor
func poll(until condition: () -> Bool, timeout: Duration = .seconds(2)) async throws {
    var waited = Duration.zero
    while !condition(), waited < timeout {
        try await Task.sleep(for: .milliseconds(5))
        waited += .milliseconds(5)
    }
}

// MARK: - Test Environment

/// Minimal environment for reducer tests.
///
/// Includes a shared `InMemoryKeyValueStore` so tests that exercise effects
/// touching preferences can assert against the same instance.
struct TestEnvironment: Sendable {
    var keyValue: any KeyValueStore = InMemoryKeyValueStore()
}

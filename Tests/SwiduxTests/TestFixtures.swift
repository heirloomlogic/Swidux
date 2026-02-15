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
struct TestState: Sendable {
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

// MARK: - Test Environment

/// Empty environment for reducer tests.
struct TestEnvironment: Sendable {}

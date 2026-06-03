//
//  ContainerFactory.swift
//  SwiduxPersistence
//
//  The single point of `ModelContainer` construction. Local, in-memory, and
//  (via `SwiduxCloudKitSync`) CloudKit containers all funnel through
//  `makeContainer`, so `ModelConfiguration` is built in exactly one place.
//

import Foundation
import SwiftData

/// Builds the SwiftData container the persistence plugin manages.
public enum ContainerFactory {
    /// Builds a container for `models` with the given storage options.
    ///
    /// - Parameters:
    ///   - models: The generated `{Type}Model` types in the schema.
    ///   - cloudKitDatabase: CloudKit mirroring mode. `.none` for local-only.
    ///   - url: On-disk store URL. `nil` uses SwiftData's default. Ignored when
    ///     `inMemory` is `true`.
    ///   - inMemory: Build an in-memory store (tests, previews).
    /// - Returns: A configured `ModelContainer` for the schema.
    /// - Throws: Any error thrown by `ModelContainer`/`ModelConfiguration` construction.
    public static func makeContainer(
        models: [any PersistentModel.Type],
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .none,
        url: URL? = nil,
        inMemory: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: cloudKitDatabase)
        } else if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: cloudKitDatabase)
        } else {
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: cloudKitDatabase)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// A local-only (no CloudKit) container.
    public static func makeLocalContainer(
        models: [any PersistentModel.Type],
        url: URL? = nil
    ) throws -> ModelContainer {
        try makeContainer(models: models, cloudKitDatabase: .none, url: url)
    }

    /// An in-memory container — for tests and previews.
    public static func makeInMemoryContainer(
        models: [any PersistentModel.Type]
    ) throws -> ModelContainer {
        try makeContainer(models: models, inMemory: true)
    }
}

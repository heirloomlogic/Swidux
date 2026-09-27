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
    /// A CloudKit-mirrored container is checked against the one CloudKit rule
    /// `@Persisted` can't satisfy for you: every relationship needs an inverse,
    /// and a `@Relation` has none. Rather than let SwiftData fail to load the
    /// store — Core Data error 134060, which some hosts turn into an abort —
    /// this throws ``CloudKitIncompatibleSchema`` naming each relationship. A
    /// local-only container is not checked.
    ///
    /// - Returns: A configured `ModelContainer` for the schema.
    /// - Throws: ``CloudKitIncompatibleSchema`` for a mirrored container over a
    ///   schema with a one-sided relationship; otherwise any error thrown by
    ///   `ModelContainer`/`ModelConfiguration` construction.
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
        // A container identifier is set exactly when SwiftData will attach the
        // mirror: an explicit `.private(_:)`, or `.automatic` in an app with the
        // iCloud entitlement. `.none` — and `.automatic` without an entitlement,
        // which mirrors nothing — leave it nil, and are left alone.
        if configuration.cloudKitContainerIdentifier != nil {
            let oneSided = CloudKitIncompatibleSchema.oneSidedRelationships(in: schema)
            guard oneSided.isEmpty else {
                throw CloudKitIncompatibleSchema(oneSidedRelationships: oneSided)
            }
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

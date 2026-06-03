//
//  CloudContainerFactory.swift
//  SwiduxCloudKitSync
//
//  Builds the SwiftData container in the requested sync mode. The same on-disk
//  store URL is used for both modes, so toggling sync never moves or loses
//  local rows — only the CloudKit mirror is attached or detached.
//

import Foundation
import SwiduxPersistence
import SwiftData

/// Builds local-only or CloudKit-mirrored containers for a fixed schema.
public enum CloudContainerFactory {
    /// Builds a container for the given models in the requested ``SyncMode``.
    ///
    /// - Parameters:
    ///   - models: The generated `{Type}Model` types in the schema.
    ///   - mode: `.localOnly` omits CloudKit; `.iCloud` mirrors to the private DB.
    ///   - url: On-disk store URL. Pass the *same* URL for both modes so toggling
    ///     reuses the local store.
    ///   - cloudKitContainerID: Optional explicit CloudKit container id; `nil`
    ///     uses `.automatic`.
    /// - Returns: A `ModelContainer` in the requested `SyncMode`.
    /// - Throws: Any error thrown by `ContainerFactory.makeContainer`.
    public static func makeContainer(
        models: [any PersistentModel.Type],
        mode: SyncMode,
        url: URL? = nil,
        cloudKitContainerID: String? = nil
    ) throws -> ModelContainer {
        let database: ModelConfiguration.CloudKitDatabase
        switch mode {
        case .localOnly:
            database = .none
        case .iCloud:
            database = cloudKitContainerID.map { .private($0) } ?? .automatic
        }
        // Container/configuration construction lives in one place.
        return try ContainerFactory.makeContainer(models: models, cloudKitDatabase: database, url: url)
    }
}

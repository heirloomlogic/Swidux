//
//  CloudKitSchemaTests.swift
//  SwiduxPersistenceTests
//
//  A `@Relation` is one-sided, and CloudKit mirroring refuses any relationship
//  without an inverse: SwiftData's store load fails with Core Data error 134060
//  ("CloudKit integration requires that all relationships have an inverse"),
//  and on an unsigned host the process then aborts. The factory checks the
//  schema first and throws something an app can read.
//

import Foundation
import SwiftData
import Testing

@testable import SwiduxPersistence

/// A fresh on-disk store location, so no test shares a file with another.
private func temporaryStoreURL() throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "swidux-cloudkit-schema-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "store.sqlite")
}

@Suite("CloudKit schema check")
struct CloudKitSchemaTests {
    @Test("a mirrored container over a @Relation model throws a readable error instead of failing to load")
    func aOneSidedRelationIsRefusedBeforeLoading() throws {
        let error = #expect(throws: CloudKitIncompatibleSchema.self) {
            try ContainerFactory.makeContainer(
                models: [BookModel.self, ChapterModel.self, ColophonModel.self],
                cloudKitDatabase: .private("iCloud.com.heirloomlogic.swidux.schemacheck"),
                url: try temporaryStoreURL())
        }
        // A subset, not an exact list: SwiftData's `Schema` also takes in any
        // other model in the module that relates to these, and a one-sided
        // relationship there is refused just the same.
        let named = Set(error?.oneSidedRelationships ?? [])
        #expect(
            named.isSuperset(of: [
                .init(entity: "BookModel", name: "chapters", destination: "ChapterModel"),
                .init(entity: "BookModel", name: "colophon", destination: "ColophonModel"),
            ]),
            "\(named)")
        let message = error?.localizedDescription ?? ""
        #expect(message.contains("BookModel.chapters"), "\(message)")
        #expect(message.contains("@Inline") && message.contains("@ForeignKey"), "\(message)")
    }

    @Test("a local container over the same models is unaffected")
    func aLocalContainerIsNotChecked() throws {
        let container = try ContainerFactory.makeContainer(
            models: [BookModel.self, ChapterModel.self, ColophonModel.self], url: try temporaryStoreURL())
        #expect(container.configurations.first?.cloudKitContainerIdentifier == nil)
    }
}

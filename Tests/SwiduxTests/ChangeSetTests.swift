//
//  ChangeSetTests.swift
//  SwiduxTests
//

import Foundation
import Testing

@testable import Swidux

@Suite("ChangeSet")
struct ChangeSetTests {

    @Test("Fresh ChangeSet is empty")
    func freshIsEmpty() {
        let cs = ChangeSet()
        #expect(cs.isEmpty)
        #expect(cs.upserts.isEmpty)
        #expect(cs.deletions.isEmpty)
    }

    @Test("Adding an upsert makes it non-empty")
    func upsertMakesNonEmpty() {
        var cs = ChangeSet()
        cs.upserts.insert(UUID())
        #expect(!cs.isEmpty)
    }

    @Test("Adding a deletion makes it non-empty")
    func deletionMakesNonEmpty() {
        var cs = ChangeSet()
        cs.deletions.insert(UUID())
        #expect(!cs.isEmpty)
    }

    @Test("Equatable conformance — equal")
    func equatableEqual() {
        let id = UUID()
        var a = ChangeSet()
        a.upserts.insert(id)
        var b = ChangeSet()
        b.upserts.insert(id)
        #expect(a == b)
    }

    @Test("Equatable conformance — not equal")
    func equatableNotEqual() {
        var a = ChangeSet()
        a.upserts.insert(UUID())
        var b = ChangeSet()
        b.deletions.insert(UUID())
        #expect(a != b)
    }
}

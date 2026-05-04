//
//  SemanticVersionTests.swift
//  SwiduxKillswitchTests
//
//  Tests for SemanticVersion parsing and comparison.
//

import Testing

@testable import SwiduxKillswitch

@Suite("SemanticVersion")
struct SemanticVersionTests {
    @Test("parses major.minor.patch")
    func parseMajorMinorPatch() {
        let v = SemanticVersion("3.8.0")
        #expect(v != nil)
        #expect(v?.major == 3)
        #expect(v?.minor == 8)
        #expect(v?.patch == 0)
        #expect(v?.prerelease.isEmpty == true)
    }

    @Test("parses prerelease")
    func parsePrerelease() {
        let v = SemanticVersion("4.0.0-beta.1")
        #expect(v != nil)
        #expect(v?.major == 4)
        #expect(v?.minor == 0)
        #expect(v?.patch == 0)
        #expect(
            v?.prerelease == [
                .alphanumeric("beta"),
                .numeric(1),
            ]
        )
    }

    @Test("rejects malformed", arguments: ["", "1", "1.2", "a.b.c", "1.2.3.4"])
    func rejectsMalformed(input: String) {
        #expect(SemanticVersion(input) == nil)
    }

    @Test("strips build metadata")
    func stripsBuildMetadata() {
        let v = SemanticVersion("1.2.3+sha.abc")
        #expect(v != nil)
        #expect(v?.major == 1)
        #expect(v?.minor == 2)
        #expect(v?.patch == 3)
        #expect(v?.prerelease.isEmpty == true)
    }

    @Test("ordering by patch")
    func orderingByPatch() {
        let a = SemanticVersion("1.0.0")!
        let b = SemanticVersion("1.0.1")!
        #expect(a < b)
    }

    @Test("ordering by minor")
    func orderingByMinor() {
        let a = SemanticVersion("1.0.9")!
        let b = SemanticVersion("1.1.0")!
        #expect(a < b)
    }

    @Test("ordering by major")
    func orderingByMajor() {
        let a = SemanticVersion("1.9.9")!
        let b = SemanticVersion("2.0.0")!
        #expect(a < b)
    }

    @Test("stable outranks prerelease")
    func stableOutranksPrerelease() {
        let pre = SemanticVersion("1.0.0-beta.1")!
        let stable = SemanticVersion("1.0.0")!
        #expect(pre < stable)
    }

    @Test("equality ignores build metadata")
    func equalityIgnoresBuildMetadata() {
        let a = SemanticVersion("1.2.3")!
        let b = SemanticVersion("1.2.3+sha.abc")!
        #expect(a == b)
    }
}

//
//  KillswitchVerdictTests.swift
//  SwiduxKillswitchTests
//
//  Tests for killswitch verdict evaluation.
//

import Foundation
import Testing

@testable import SwiduxKillswitch

@Suite("KillswitchVerdict")
struct KillswitchVerdictTests {
    @Test("allowed when empty config")
    func allowedWhenEmptyConfig() {
        let config = KillswitchConfig()
        let verdict = KillswitchVerdict.evaluate(config, against: "1.0.0")
        #expect(verdict == .allowed)
    }

    @Test("blocked when below minimum")
    func blockedWhenBelowMinimum() {
        let config = KillswitchConfig(minimumSupportedVersion: "2.0.0")
        let verdict = KillswitchVerdict.evaluate(config, against: "1.5.0")
        #expect(verdict == .blocked(title: nil, message: nil, updateURL: nil))
    }

    @Test("allowed at minimum")
    func allowedAtMinimum() {
        let config = KillswitchConfig(minimumSupportedVersion: "2.0.0")
        let verdict = KillswitchVerdict.evaluate(config, against: "2.0.0")
        #expect(verdict == .allowed)
    }

    @Test("blocked in blocklist")
    func blockedInBlocklist() {
        let config = KillswitchConfig(blockedVersions: ["1.3.0", "1.4.0"])
        let verdict = KillswitchVerdict.evaluate(config, against: "1.3.0")
        #expect(verdict == .blocked(title: nil, message: nil, updateURL: nil))
    }

    @Test("allowed when not in blocklist")
    func allowedWhenNotInBlocklist() {
        let config = KillswitchConfig(blockedVersions: ["1.3.0", "1.4.0"])
        let verdict = KillswitchVerdict.evaluate(config, against: "1.5.0")
        #expect(verdict == .allowed)
    }

    @Test("blocked in range")
    func blockedInRange() {
        let config = KillswitchConfig(blockedRanges: ["1.0.0..<2.0.0"])
        let verdict = KillswitchVerdict.evaluate(config, against: "1.5.0")
        #expect(verdict == .blocked(title: nil, message: nil, updateURL: nil))
    }

    @Test("allowed at exclusive upper bound")
    func allowedAtExclusiveUpperBound() {
        let config = KillswitchConfig(blockedRanges: ["1.0.0..<2.0.0"])
        let verdict = KillswitchVerdict.evaluate(config, against: "2.0.0")
        #expect(verdict == .allowed)
    }

    @Test("unparseable version -> allowed (fail-open)")
    func unparseableVersionAllowed() {
        let config = KillswitchConfig(minimumSupportedVersion: "2.0.0")
        let verdict = KillswitchVerdict.evaluate(config, against: "not-a-version")
        #expect(verdict == .allowed)
    }

    @Test("uses config title and message when blocked")
    func usesConfigTitleAndMessage() {
        let config = KillswitchConfig(
            minimumSupportedVersion: "2.0.0",
            blockedTitle: "Update Required",
            blockedMessage: "Please update to continue.",
            updateURL: "https://example.com/update"
        )
        let verdict = KillswitchVerdict.evaluate(config, against: "1.0.0")
        #expect(
            verdict
                == .blocked(
                    title: "Update Required",
                    message: "Please update to continue.",
                    updateURL: URL(static: "https://example.com/update")
                )
        )
    }
}

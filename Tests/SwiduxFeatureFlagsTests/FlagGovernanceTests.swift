//
//  FlagGovernanceTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FlagGovernance")
struct FlagGovernanceTests {
    enum Layout: String { case control, treatment }

    // A fixed clock so tests don't depend on the wall clock.
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static func days(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }

    static let current = FlagDescriptor.bool(
        BoolFlag("current"), owner: "growth", expires: days(30), purpose: "still live"
    )
    static let expiredRecently = FlagDescriptor.variant(
        VariantFlag<Layout>("layout", default: .control),
        owner: "checkout", expires: days(-2), purpose: "layout A/B"
    )
    static let expiredLongAgo = FlagDescriptor.value(
        ValueFlag<Int>("max", default: 5), owner: "platform", expires: days(-40), purpose: "cap"
    )

    // MARK: - Factories single-source the key

    @Test("typed factories copy the key from the flag declaration")
    func factoriesSingleSourceKey() {
        #expect(Self.current.key == "current")
        #expect(Self.expiredRecently.key == "layout")
        #expect(Self.expiredLongAgo.key == "max")
    }

    // MARK: - expired(in:asOf:)

    @Test("expired selects only past-expiry flags, oldest first")
    func expiredSelectsAndSorts() {
        let manifest = [Self.current, Self.expiredRecently, Self.expiredLongAgo]
        let expired = FlagGovernance.expired(in: manifest, asOf: Self.now)
        #expect(expired.map(\.key) == ["max", "layout"])
    }

    @Test("a flag is expired the instant it reaches its expiry")
    func boundaryIsExpired() {
        let onTheDot = FlagDescriptor.bool(
            BoolFlag("edge"), owner: "x", expires: Self.now, purpose: "boundary"
        )
        #expect(FlagGovernance.expired(in: [onTheDot], asOf: Self.now).count == 1)
    }

    // MARK: - expirationReport

    @Test("report is nil when every flag is current")
    func reportNilWhenAllCurrent() {
        #expect(FlagGovernance.expirationReport([Self.current], asOf: Self.now) == nil)
    }

    @Test("report names each expired flag and its owner")
    func reportNamesFlagAndOwner() throws {
        let manifest = [Self.current, Self.expiredRecently, Self.expiredLongAgo]
        let report = try #require(FlagGovernance.expirationReport(manifest, asOf: Self.now))
        #expect(report.contains("layout"))
        #expect(report.contains("owner: checkout"))
        #expect(report.contains("max"))
        #expect(report.contains("owner: platform"))
        // The current flag must not appear.
        #expect(!report.contains("current"))
    }
}

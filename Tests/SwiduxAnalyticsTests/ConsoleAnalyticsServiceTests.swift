//
//  ConsoleAnalyticsServiceTests.swift
//  SwiduxAnalyticsTests
//

import Foundation
import Testing

@testable import SwiduxAnalytics

@Suite("ConsoleAnalyticsService")
struct ConsoleAnalyticsServiceTests {
    @Test("formats scalar values")
    func formatsScalars() {
        #expect(consoleAnalyticsDescription(.string("pro")) == "pro")
        #expect(consoleAnalyticsDescription(.int(5)) == "5")
        #expect(consoleAnalyticsDescription(.bool(true)) == "true")
        #expect(consoleAnalyticsDescription(.bool(false)) == "false")
        #expect(consoleAnalyticsDescription(.null) == "null")
    }

    @Test("formats a date as ISO-8601")
    func formatsDate() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(consoleAnalyticsDescription(.date(date)) == "1970-01-01T00:00:00Z")
    }

    @Test("formats nested arrays and dicts with sorted keys")
    func formatsNested() {
        let value: AnalyticsValue = .dict([
            "b": .int(2),
            "a": .array([.string("x"), .bool(false)]),
        ])
        #expect(consoleAnalyticsDescription(value) == "{a: [x, false], b: 2}")
    }

    @Test("formats a property bag with sorted keys")
    func formatsPropertyBag() {
        let props: [String: AnalyticsValue] = ["tier": "pro", "amount": 5]
        #expect(consoleAnalyticsPropertiesDescription(props) == "amount=5, tier=pro")
        #expect(consoleAnalyticsPropertiesDescription([:]) == "{}")
    }

    @Test("every protocol method runs without crashing")
    func smokeAllMethods() async {
        let service = ConsoleAnalyticsService()
        await service.track(AnalyticsEvent("opened", ["count": 1]))
        await service.identify(userID: "u1", properties: ["tier": "pro"])
        await service.alias(newID: "u1", previousID: "anon")
        await service.reset()
        await service.flush()
    }
}

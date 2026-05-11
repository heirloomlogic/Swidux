//
//  FlagValueTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FlagValue")
struct FlagValueTests {
    @Test("decodes JSON bool")
    func decodesBool() throws {
        let data = "true".data(using: .utf8)!
        let value = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(value == .bool(true))
    }

    @Test("decodes JSON int")
    func decodesInt() throws {
        let data = "42".data(using: .utf8)!
        let value = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(value == .int(42))
    }

    @Test("decodes JSON double")
    func decodesDouble() throws {
        let data = "3.14".data(using: .utf8)!
        let value = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(value == .double(3.14))
    }

    @Test("decodes JSON string")
    func decodesString() throws {
        let data = "\"hello\"".data(using: .utf8)!
        let value = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(value == .string("hello"))
    }

    @Test("encodes round-trip")
    func encodeRoundTrip() throws {
        let cases: [FlagValue] = [.bool(true), .int(42), .double(3.14), .string("x")]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(FlagValue.self, from: data)
            #expect(decoded == original)
        }
    }
}

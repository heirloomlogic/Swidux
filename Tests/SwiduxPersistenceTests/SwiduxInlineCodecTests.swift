//
//  SwiduxInlineCodecTests.swift
//  SwiduxPersistenceTests
//

import Foundation
import Testing

@testable import SwiduxPersistence

@Suite("SwiduxInlineCodec")
struct SwiduxInlineCodecTests {
    private struct Payload: Codable, Equatable {
        var value: Int
    }

    @Test("decodes a valid blob")
    func decodesValidBlob() throws {
        let data = try JSONEncoder().encode(Payload(value: 7))
        let decoded = SwiduxInlineCodec.decode(
            Payload.self, from: data, decoder: JSONDecoder(), model: "TestModel", property: "payload"
        )
        #expect(decoded == Payload(value: 7))
    }

    @Test("empty data is a quiet nil — the CloudKit column default")
    func emptyDataIsNil() {
        let decoded = SwiduxInlineCodec.decode(
            Payload.self, from: Data(), decoder: JSONDecoder(), model: "TestModel", property: "payload"
        )
        #expect(decoded == nil)
    }

    @Test("an undecodable blob returns nil so the accessor falls back")
    func undecodableBlobFallsBack() {
        let decoded = SwiduxInlineCodec.decode(
            Payload.self, from: Data("garbage".utf8), decoder: JSONDecoder(),
            model: "TestModel", property: "payload"
        )
        #expect(decoded == nil)
    }
}

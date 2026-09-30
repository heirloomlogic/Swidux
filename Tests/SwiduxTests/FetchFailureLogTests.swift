//
//  FetchFailureLogTests.swift
//  SwiduxTests
//
//  What the remote-config channels log when a fetch fails, and when they
//  stay quiet.
//

import Foundation
import Testing

@testable import Swidux

@Suite("FetchFailureLog")
struct FetchFailureLogTests {
    private let endpoint = URL(static: "https://config.example.test/counter/killswitch")

    @Test("the first failure is logged with the channel, the endpoint, and the error")
    func firstFailureIsLogged() throws {
        let log = FetchFailureLog(channel: "Killswitch", category: "test")

        let line = try #require(log.failed(URLError(.notConnectedToInternet), endpoint: endpoint))

        #expect(line.contains("Killswitch"))
        #expect(line.contains("https://config.example.test/counter/killswitch"))
        #expect(line.contains("URLError \(URLError.Code.notConnectedToInternet.rawValue)"))
        #expect(log.lastLogged == line)
    }

    @Test("a failure identical to the last one logged is not logged again")
    func repeatedFailureIsSuppressed() {
        let log = FetchFailureLog(channel: "Killswitch", category: "test")
        let first = log.failed(URLError(.timedOut), endpoint: endpoint)

        #expect(log.failed(URLError(.timedOut), endpoint: endpoint) == nil)
        #expect(log.lastLogged == first)
    }

    @Test("a different failure is logged")
    func differentFailureIsLogged() {
        let log = FetchFailureLog(channel: "Killswitch", category: "test")
        _ = log.failed(URLError(.timedOut), endpoint: endpoint)

        let second = log.failed(URLError(.cannotFindHost), endpoint: endpoint)

        #expect(second != nil)
        #expect(log.lastLogged == second)
    }

    @Test("after a success, the same failure is logged again")
    func successResetsTheRepeatCheck() {
        let log = FetchFailureLog(channel: "Killswitch", category: "test")
        _ = log.failed(URLError(.timedOut), endpoint: endpoint)

        log.succeeded()

        #expect(log.lastLogged == nil)
        #expect(log.failed(URLError(.timedOut), endpoint: endpoint) != nil)
    }

    @Test(
        "a cancelled fetch is not a failure worth logging",
        arguments: [CancellationError() as any Error, URLError(.cancelled)]
    )
    func cancellationIsNotLogged(error: any Error) {
        let log = FetchFailureLog(channel: "Killswitch", category: "test")
        let earlier = log.failed(URLError(.timedOut), endpoint: endpoint)

        #expect(log.failed(error, endpoint: endpoint) == nil)
        #expect(log.lastLogged == earlier)
    }

    @Test("the endpoint is logged without its query, fragment, or credentials")
    func endpointIsRedacted() throws {
        let log = FetchFailureLog(channel: "Feature flags", category: "test")
        let secretive = URL(static: "https://user:hunter2@config.example.test/app/flags?token=s3cret#frag")

        let line = try #require(log.failed(URLError(.timedOut), endpoint: secretive))

        #expect(line.contains("https://config.example.test/app/flags"))
        for secret in ["user", "hunter2", "token", "s3cret", "frag"] {
            #expect(!line.contains(secret), "leaked \(secret) into \(line)")
        }
    }

    @Test("a service without a known endpoint still logs the error")
    func missingEndpoint() throws {
        let log = FetchFailureLog(channel: "Feature flags", category: "test")

        let line = try #require(log.failed(URLError(.timedOut), endpoint: nil))

        #expect(line.hasPrefix("Feature flags fetch failed:"))
    }

    @Test("a decoding failure names the key path and the reason")
    func decodingFailureIsSummarized() throws {
        struct Wire: Decodable { let flags: [String: Int] }
        let decodingError = try #require(
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(Wire.self, from: Data(#"{"flags":{"a":"x"}}"#.utf8))
            }
        )
        let log = FetchFailureLog(channel: "Feature flags", category: "test")

        let line = try #require(log.failed(decodingError, endpoint: endpoint))

        #expect(line.contains("flags.a"))
        #expect(!line.contains("\"x\""))
    }
}

//
//  BoundedResponseTests.swift
//  SwiduxTests
//
//  The deadline half of `BoundedResponse`: a transfer that never goes idle,
//  and one that never starts, both end on time.
//

import Foundation
import Synchronization
import Testing

@testable import Swidux

@Suite("BoundedResponse deadline")
struct BoundedResponseTests {
    @Test("a body trickled faster than the idle timeout is abandoned at the deadline")
    func tricklingBodyTimesOut() async throws {
        let (result, elapsed) = try await fetch("trickle", deadline: .milliseconds(300))

        // A byte every 20 ms resets `timeoutInterval` forever; only the
        // deadline ends this.
        #expect(elapsed < .seconds(5), "still in flight until the watchdog cancelled it")
        #expect(throws: URLError(.timedOut)) { try result.get() }
    }

    @Test("a response whose headers never arrive is abandoned at the deadline")
    func silentServerTimesOut() async throws {
        let (result, elapsed) = try await fetch("silent", deadline: .milliseconds(300))

        #expect(elapsed < .seconds(5), "still in flight until the watchdog cancelled it")
        #expect(throws: URLError(.timedOut)) { try result.get() }
    }

    @Test("a prompt response is returned whole, deadline or not")
    func promptResponseIsUnaffected() async throws {
        let (withDeadline, _) = try await fetch("ok", deadline: .seconds(5))
        let (withoutDeadline, _) = try await fetch("ok", deadline: nil)

        #expect(try withDeadline.get() == StagedTransferProtocol.body)
        #expect(try withoutDeadline.get() == StagedTransferProtocol.body)
    }

    @Test(
        "a timeout that isn't a usable deadline means no deadline, not a trap",
        arguments: [TimeInterval.infinity, .greatestFiniteMagnitude, 1e19, .nan, 0, -1]
    )
    func unusableTimeoutMeansNoDeadline(seconds: TimeInterval) {
        // `fetchTimeout: .infinity` used to mean "no timeout" to
        // `URLRequest.timeoutInterval`; `Duration.seconds(_:)` traps on it.
        #expect(BoundedResponse.deadline(forTimeout: seconds) == nil)
    }

    @Test("an ordinary timeout becomes the same deadline")
    func ordinaryTimeoutIsTheDeadline() {
        #expect(BoundedResponse.deadline(forTimeout: 10) == .seconds(10))
        #expect(BoundedResponse.deadline(forTimeout: 0.25) == .milliseconds(250))
    }

    @Test("a non-2xx status is named in the error, not just classified")
    func errorNamesTheStatus() async throws {
        let (result, _) = try await fetch("missing", deadline: .seconds(5))

        let error = #expect(throws: URLError.self) { try result.get() }
        #expect(error?.code == .badServerResponse)
        #expect(error?.localizedDescription.contains("HTTP 404") == true)
    }

    @Test(
        "a response marked as the endpoint's unseeded default draws a warning",
        arguments: ["default", "Default", " default "]
    )
    func unseededDefaultIsFlagged(source: String) throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(static: "https://config.example.test/Counter/killswitch?token=s3cret"),
                statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["x-config-source": source]
            )
        )

        let warning = try #require(BoundedResponse.unseededDefaultWarning(for: response))

        #expect(warning.contains("https://config.example.test/Counter/killswitch"))
        #expect(!warning.contains("s3cret"))
    }

    @Test(
        "a seeded, unmarked, or error response draws no unseeded-default warning",
        arguments: [["X-Config-Source": "kv"], ["X-Config-Source": "error"], [:]]
    )
    func otherSourcesAreQuiet(headers: [String: String]) throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(static: "https://config.example.test/counter/killswitch"),
                statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
            )
        )

        #expect(BoundedResponse.unseededDefaultWarning(for: response) == nil)
    }

    /// Fetches `path` from the staged protocol, cancelling it from outside if
    /// it is still running after 5 s — so a missing deadline fails the test
    /// instead of hanging the run.
    private func fetch(
        _ path: String,
        deadline: Duration?
    ) async throws -> (Result<Data, any Error>, Duration) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StagedTransferProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try #require(URL(string: "https://example.test/\(path)")))
        request.timeoutInterval = 60

        let clock = ContinuousClock()
        let started = clock.now
        let transfer = Task {
            try await BoundedResponse.data(for: request, session: session, limit: 1_000_000, deadline: deadline)
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            transfer.cancel()
        }
        let result = await transfer.result
        watchdog.cancel()
        return (result, clock.now - started)
    }
}

/// Serves one of four transfers by path: `ok` answers at once, `missing`
/// answers 404, `trickle` answers 200 and then sends a byte every 20 ms until
/// stopped, and `silent` never answers at all.
private final class StagedTransferProtocol: URLProtocol {
    static let body = Data(#"{"minimumSupportedVersion":"2.0.0"}"#.utf8)

    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return }
        switch url.lastPathComponent {
        case "silent":
            return
        case "missing":
            let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
            client?.urlProtocol(self, didReceive: notFound ?? response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("Not Found".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case "trickle":
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            trickle()
        default:
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private func trickle() {
        // URLProtocol opts out of Sendable; `stopped` is the only state the
        // timer touches, and it is behind a lock.
        nonisolated(unsafe) let stub = self
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
            guard !stub.stopped.withLock({ $0 }) else { return }
            stub.client?.urlProtocol(stub, didLoad: Data(" ".utf8))
            stub.trickle()
        }
    }
}

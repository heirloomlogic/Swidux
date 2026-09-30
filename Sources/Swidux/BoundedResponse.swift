//
//  BoundedResponse.swift
//  Swidux
//
//  One capped, streamed response reader for the remote-config channels.
//  Lived twice — byte-identical — in `SwiduxKillswitch` and `SwiduxFeatureFlags`,
//  which is one copy too many for a size guard: a fix to either would have had
//  to be noticed and repeated in the other, and the failure mode of missing it
//  is a module that buffers a hostile payload whole.
//

import Foundation
import os

/// Logs what `BoundedResponse` notices about a response it still accepts.
private let logger = Logger(subsystem: "swidux", category: "remoteconfig")

/// Fetches a response body while enforcing a byte cap during the transfer.
///
/// The remote-config channels (killswitch, feature flags) both pull a small JSON
/// document from an endpoint the app doesn't control at runtime. A plain
/// `data(for:)` would buffer whatever the endpoint sends before anyone could
/// object, so the body is streamed and abandoned the moment it grows past the
/// cap.
public enum BoundedResponse {
    /// Fetches `request`, refusing anything larger than `limit` or slower than
    /// `deadline`.
    ///
    /// Three guards, in the order that spends the least on a bad response:
    ///
    /// 1. A non-2xx status throws `URLError.badServerResponse`, with the status
    ///    in its description, **before the body is read at all** — an error
    ///    page is not a config, however well it decodes.
    /// 2. A declared `Content-Length` above the cap throws
    ///    `URLError.dataLengthExceedsMaximum` immediately, without transferring
    ///    the body.
    /// 3. Otherwise bytes accumulate and the transfer is abandoned as soon as
    ///    the count exceeds `limit`, so the process never holds more than the
    ///    cap plus one chunk.
    ///
    /// The deadline covers the whole exchange, headers and body together.
    /// `URLRequest.timeoutInterval` can't do that job: it is an *idle* timeout,
    /// reset by every packet, so a response that trickles in a byte at a time
    /// never trips it, and `URLSession.shared` allows a transfer seven days.
    /// When the deadline passes, the transfer is cancelled and the call throws
    /// `URLError.timedOut`.
    ///
    /// - Note: `URLSession.bytes(for:)` yields one byte at a time — it is the
    ///   only public streaming read, and its buffering keeps that cheaper than
    ///   it looks (roughly 100 ms to reach a 1 MB cap, nearly all of it inside
    ///   the transfer). It is *not* free, which is the other half of why the cap
    ///   is checked against a declared `Content-Length` first: a well-behaved
    ///   oversized response costs one round trip and no iteration at all.
    ///
    /// - Parameters:
    ///   - request: The request to fetch.
    ///   - session: The session to fetch with.
    ///   - limit: The maximum accepted body size, in bytes.
    ///   - deadline: The longest the whole exchange may take, or `nil` to rely
    ///     on the session's own timeouts alone.
    /// - Returns: The response body, never larger than `limit`.
    /// - Throws: `URLError.badServerResponse` for a non-2xx status,
    ///   `URLError.dataLengthExceedsMaximum` past the cap, `URLError.timedOut`
    ///   past the deadline, and whatever the transport throws.
    public static func data(
        for request: URLRequest,
        session: URLSession,
        limit: Int,
        deadline: Duration? = nil
    ) async throws -> Data {
        guard let deadline else {
            return try await transfer(request, session: session, limit: limit)
        }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await transfer(request, session: session, limit: limit) }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw URLError(.timedOut)
            }
            // The first child to finish decides. Cancelling the other tears
            // the transfer down — `bytes(for:)` and its iterator both honour
            // task cancellation — and the group waits for that before it
            // returns, so nothing outlives the call.
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw URLError(.timedOut) }
            return data
        }
    }

    /// The deadline for a `fetchTimeout` given in seconds, or `nil` when the
    /// value can't be one.
    ///
    /// `URLRequest.timeoutInterval` accepts anything, and `.infinity` or
    /// `.greatestFiniteMagnitude` there reads as "no timeout". The same value
    /// passed to `Duration.seconds(_:)` traps. So a non-finite value, one past
    /// a century (effectively forever, and short of `Duration`'s range), or
    /// one that isn't positive means no deadline, the same thing it always
    /// meant to the idle timeout.
    package static func deadline(forTimeout seconds: TimeInterval) -> Duration? {
        let century: TimeInterval = 100 * 365 * 24 * 3600
        guard seconds.isFinite, seconds > 0, seconds <= century else { return nil }
        return .seconds(seconds)
    }

    /// The warning for a 2xx response marked `X-Config-Source: default`, or
    /// `nil` for any other.
    ///
    /// A config worker can mark a response built from its fallback, served
    /// because nothing is stored under the requested key. That is usually a
    /// typo in the app ID of the URL, which the fallback hides: it decodes, so
    /// the fetch succeeds with no rules. Debug builds log this at warning level.
    package static func unseededDefaultWarning(for response: HTTPURLResponse) -> String? {
        let source = response.value(forHTTPHeaderField: "X-Config-Source")
        guard source?.trimmingCharacters(in: .whitespaces).lowercased() == "default" else { return nil }
        let endpoint = response.url.map(FetchFailureLog.loggable) ?? "The config endpoint"
        return """
            \(endpoint) served its unseeded default (X-Config-Source: default). \
            Check the app ID in the URL, or seed the key.
            """
    }

    /// The capped read itself, with no deadline of its own.
    private static func transfer(
        _ request: URLRequest,
        session: URLSession,
        limit: Int
    ) async throws -> Data {
        guard limit >= 0 else { throw URLError(.dataLengthExceedsMaximum) }
        let (bytes, response) = try await session.bytes(for: request, delegate: SecureConfigRedirects())
        // Dropping the iterator does not promise transport cancellation.
        // Close the transfer on every early rejection as well as normal EOF.
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(
                .badServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "The server answered HTTP \(http.statusCode)."]
            )
        }
        #if DEBUG
        if let warning = unseededDefaultWarning(for: http) {
            logger.warning("\(warning, privacy: .public)")
        }
        #endif
        if response.expectedContentLength > Int64(limit) {
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), limit))
        }
        let chunkSize = 65_536
        var chunk = [UInt8]()
        chunk.reserveCapacity(chunkSize)
        for try await byte in bytes {
            guard data.count + chunk.count < limit else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            chunk.append(byte)
            if chunk.count == chunkSize {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                if data.count > limit {
                    throw URLError(.dataLengthExceedsMaximum)
                }
            }
        }
        data.append(contentsOf: chunk)
        if data.count > limit {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return data
    }
}

/// HTTPS requests cannot acquire an insecure hop through a redirect, even when
/// the host app permits insecure loads. Local HTTP stays local for development.
final class SecureConfigRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url else { return completionHandler(nil) }
        let isHTTPS = url.scheme?.lowercased() == "https"
        let isLocalHTTP =
            response.url?.scheme?.lowercased() == "http"
            && url.scheme?.lowercased() == "http"
            && ["localhost", "127.0.0.1"].contains(url.host()?.lowercased())
        completionHandler(isHTTPS || isLocalHTTP ? request : nil)
    }
}

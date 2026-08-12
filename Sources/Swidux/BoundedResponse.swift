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

/// Fetches a response body while enforcing a byte cap during the transfer.
///
/// The remote-config channels (killswitch, feature flags) both pull a small JSON
/// document from an endpoint the app doesn't control at runtime. A plain
/// `data(for:)` would buffer whatever the endpoint sends before anyone could
/// object, so the body is streamed and abandoned the moment it grows past the
/// cap.
public enum BoundedResponse {
    /// Fetches `request`, refusing anything larger than `limit`.
    ///
    /// Three guards, in the order that spends the least on a bad response:
    ///
    /// 1. A non-2xx status throws `URLError.badServerResponse` **before the body
    ///    is read at all** — an error page is not a config, however well it
    ///    decodes.
    /// 2. A declared `Content-Length` above the cap throws
    ///    `URLError.dataLengthExceedsMaximum` immediately, without transferring
    ///    the body.
    /// 3. Otherwise bytes accumulate and the transfer is abandoned as soon as
    ///    the count exceeds `limit`, so the process never holds more than the
    ///    cap plus one chunk.
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
    /// - Returns: The response body, never larger than `limit`.
    /// - Throws: `URLError.badServerResponse` for a non-2xx status,
    ///   `URLError.dataLengthExceedsMaximum` past the cap, and whatever the
    ///   transport throws.
    public static func data(
        for request: URLRequest,
        session: URLSession,
        limit: Int
    ) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
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

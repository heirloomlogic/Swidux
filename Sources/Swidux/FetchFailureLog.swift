//
//  FetchFailureLog.swift
//  Swidux
//
//  The error log for the remote-config channels' failed fetches.
//

import Foundation
import Synchronization
import os

/// Logs a remote-config channel's failed fetches, once per distinct failure.
///
/// Both remote-config plugins (killswitch, feature flags) keep failing open
/// when a fetch fails: they hold on to what they had. Without a log line, a
/// wrong endpoint URL or an app ID the server doesn't know stays invisible
/// for the life of the build. Each failure is logged at error level with the
/// endpoint and a summary of the error. A failure identical to the last one
/// logged is skipped until a fetch succeeds, so a device that stays offline
/// logs the outage once rather than on every retry. A cancelled fetch isn't
/// logged: it is how an effect ends when its scene goes away.
package final class FetchFailureLog: Sendable {
    private let channel: String
    private let logger: Logger
    private let last = Mutex<String?>(nil)

    /// - Parameters:
    ///   - channel: How the line names the channel, such as `"Killswitch"`.
    ///   - category: The `os.Logger` category under the `swidux` subsystem.
    package init(channel: String, category: String) {
        self.channel = channel
        self.logger = Logger(subsystem: "swidux", category: category)
    }

    /// The line most recently logged since the last success, or `nil`.
    package var lastLogged: String? {
        last.withLock { $0 }
    }

    /// Logs a failed fetch unless it was a cancellation or repeats the last
    /// failure logged.
    ///
    /// - Parameters:
    ///   - error: What the fetch threw.
    ///   - endpoint: Where the fetch went, when the service knows. Logged
    ///     without its query, fragment, or credentials.
    /// - Returns: The line logged, or `nil` if nothing was.
    @discardableResult
    package func failed(_ error: any Error, endpoint: URL?) -> String? {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return nil
        }
        let source = endpoint.map { " from \(Self.loggable($0))" } ?? ""
        let line = """
            \(channel) fetch\(source) failed: \(Self.summary(of: error)). \
            The plugin keeps the config it already had, if any.
            """
        let isNew = last.withLock { last in
            guard last != line else { return false }
            last = line
            return true
        }
        guard isNew else { return nil }
        logger.error("\(line, privacy: .public)")
        return line
    }

    /// Records a successful fetch, so the next failure is logged even if it
    /// matches the last one.
    package func succeeded() {
        last.withLock { $0 = nil }
    }

    /// `url` without its query, fragment, user, or password — the parts that
    /// can carry a token.
    package static func loggable(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "(unparseable URL)"
        }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? "(unparseable URL)"
    }

    /// A one-line description of `error` that names the cause but not the
    /// config's values.
    ///
    /// A decoding failure reports its key path and reason; the stock
    /// `localizedDescription` says only that the data isn't in the correct
    /// format. A `URLError` reports its message and code; its `description`
    /// includes the failing URL, query and all.
    static func summary(of error: any Error) -> String {
        if let error = error as? DecodingError {
            let context: DecodingError.Context
            switch error {
            case .typeMismatch(_, let found), .valueNotFound(_, let found), .keyNotFound(_, let found),
                .dataCorrupted(let found):
                context = found
            @unknown default:
                return error.localizedDescription
            }
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "decoding failed\(path.isEmpty ? "" : " at \(path)"): \(context.debugDescription)"
        }
        if let error = error as? URLError {
            return "\(error.localizedDescription) (URLError \(error.code.rawValue))"
        }
        return String(describing: error)
    }
}

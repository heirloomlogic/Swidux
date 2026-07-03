//
//  SwiduxInlineCodec.swift
//  SwiduxPersistence
//
//  Decode helper for @Inline blob columns in macro-generated models.
//

import Foundation
import os

/// Logs @Inline decode failures in macro-generated model accessors.
private let logger = Logger(subsystem: "swidux.persistence", category: "inline")

/// Decoding support the `@Persisted` macro emits into generated `{Type}Model`
/// accessors for `@Inline` blob columns. Not meant to be called directly.
public enum SwiduxInlineCodec {
    /// Decodes an `@Inline` blob, returning `nil` (so the generated accessor
    /// falls back to the domain default) instead of throwing.
    ///
    /// Empty data stays quiet — it's the CloudKit-safe column default, hit
    /// whenever a row materializes before its blob syncs. A non-empty blob
    /// that fails to decode logs an error first: it means schema drift or
    /// corruption, and the next save will overwrite the old payload with the
    /// fallback, so the log line is the only trace the data ever existed.
    ///
    /// - Parameters:
    ///   - type: The domain type stored in the blob.
    ///   - data: The raw blob column contents.
    ///   - decoder: The model's shared blob decoder.
    ///   - model: The generated model's name, for the log line.
    ///   - property: The blob property's name, for the log line.
    /// - Returns: The decoded value, or `nil` when empty or undecodable.
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        decoder: JSONDecoder,
        model: StaticString,
        property: StaticString
    ) -> T? {
        guard !data.isEmpty else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            logger.error(
                """
                @Inline decode failed for \(model, privacy: .public).\(property, privacy: .public) \
                (\(data.count) bytes) — falling back to the default value. \
                \(String(describing: error), privacy: .public)
                """
            )
            return nil
        }
    }
}

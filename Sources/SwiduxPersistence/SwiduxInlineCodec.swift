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
    /// Decodes an `@Inline` blob. Empty data returns `nil` so generated
    /// accessors can use the domain default while a CloudKit blob is pending.
    /// Corrupt non-empty data is logged and thrown, preserving the original
    /// payload instead of replacing it with a fallback on the next save.
    ///
    /// - Parameters:
    ///   - type: The domain type stored in the blob.
    ///   - data: The raw blob column contents.
    ///   - decoder: The model's shared blob decoder.
    ///   - model: The generated model's name, for the log line.
    ///   - property: The blob property's name, for the log line.
    /// - Returns: The decoded value, or `nil` when the column is empty.
    /// - Throws: The decoding error for a non-empty invalid payload.
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        decoder: JSONDecoder,
        model: StaticString,
        property: StaticString
    ) throws -> T? {
        guard !data.isEmpty else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            logger.error(
                """
                @Inline decode failed for \(model, privacy: .public).\(property, privacy: .public) \
                (\(data.count) bytes). \
                \(String(describing: error), privacy: .private)
                """
            )
            throw error
        }
    }
}

//
//  Bucketing.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Pure functions for stable feature-flag bucketing.
///
/// Uses FNV-1a over the UTF-8 bytes of `id + ":" + flagKey`, modulo 100.
/// Same input always produces the same bucket — buckets are stable forever
/// per `(id, flagKey)` pair.
///
/// FNV-1a chosen because it's simple, dependency-free, and matches
/// GrowthBook's algorithm so apps migrating from GrowthBook get compatible
/// buckets.
public enum Bucketing {
    /// Returns a bucket in `[0, 100)` for the given identity and flag key.
    public static func bucket(id: String, flagKey: String) -> Int {
        var hash: UInt32 = 0x811c_9dc5
        let prime: UInt32 = 0x0100_0193
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* prime
        }
        hash ^= UInt32(UInt8(ascii: ":"))
        hash = hash &* prime
        for byte in flagKey.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* prime
        }
        return Int(hash % 100)
    }

    /// Maps a bucket onto a weighted variant index.
    ///
    /// Walks cumulative weights; returns the first index whose cumulative
    /// weight strictly exceeds `bucket`. Falls back to the last index if
    /// weights don't sum to exactly 100 (defensive).
    public static func variantIndex(bucket: Int, weights: [Int]) -> Int {
        var cumulative = 0
        for (index, weight) in weights.enumerated() {
            cumulative += weight
            if bucket < cumulative { return index }
        }
        return weights.count - 1
    }
}

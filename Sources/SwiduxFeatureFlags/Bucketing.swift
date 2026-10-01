//
//  Bucketing.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Pure functions for stable feature-flag bucketing.
///
/// A bucket is the 32-bit FNV-1a hash of the UTF-8 bytes of
/// `id + ":" + flagKey`, passed through murmur3's `fmix32` finalizer and
/// taken modulo 10,000. Rollout and weight percentages cover 100 buckets per
/// point, so a 1% rollout is buckets `0..<100`. The same input always
/// produces the same bucket.
///
/// The finalizer keeps one ID's buckets for different flags independent, so
/// two flags' small cohorts overlap at the rate chance predicts. Without it,
/// the low bits of an FNV-1a hash depend only on the low bits of the input
/// bytes, and one flag's bucket partly determines another's.
///
/// This is not GrowthBook's bucketing (different input layout, finalizer,
/// and string encoding), so buckets don't carry over from GrowthBook.
///
/// > Important: Changing this function re-buckets every user and reshuffles
/// > every running experiment, so it changes only in a major release.
public enum Bucketing {
    private static let bucketCount = 10_000
    /// Buckets per percentage point of a rollout or variant weight.
    private static let bucketsPerPercent = bucketCount / 100

    /// Returns a bucket in `[0, 10_000)` for the given identity and flag key.
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
        return Int(fmix32(hash) % UInt32(bucketCount))
    }

    /// Whether `bucket` falls inside a `rollout` percentage (0–100).
    ///
    /// A rollout below 0 behaves as 0 and one above 100 as 100.
    public static func isInRollout(bucket: Int, rollout: Int) -> Bool {
        bucket < min(max(rollout, 0), 100) * bucketsPerPercent
    }

    /// Maps a bucket onto a weighted variant index.
    ///
    /// `weights` are percentages. Walks cumulative weights and returns the
    /// first index whose cumulative weight covers `bucket`. Falls back to the
    /// last index if the weights sum to less than 100 (defensive).
    ///
    /// > Important: `weights` must be non-empty — an empty array returns `-1`,
    /// > which is not a valid index. Callers evaluating remote config must
    /// > guard for emptiness first (decoded ``FeatureFlagsConfig`` enforces
    /// > non-empty variants at the wire boundary).
    public static func variantIndex(bucket: Int, weights: [Int]) -> Int {
        var cumulative = 0
        for (index, weight) in weights.enumerated() {
            cumulative += weight
            if bucket < cumulative * bucketsPerPercent { return index }
        }
        return weights.count - 1
    }

    /// murmur3's 32-bit finalizer: spreads every input bit across the output.
    private static func fmix32(_ value: UInt32) -> UInt32 {
        var hash = value
        hash ^= hash >> 16
        hash = hash &* 0x85eb_ca6b
        hash ^= hash >> 13
        hash = hash &* 0xc2b2_ae35
        hash ^= hash >> 16
        return hash
    }
}

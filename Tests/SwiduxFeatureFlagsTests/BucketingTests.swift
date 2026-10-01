//
//  BucketingTests.swift
//  SwiduxFeatureFlagsTests
//

import Testing

@testable import SwiduxFeatureFlags

@Suite("Bucketing")
struct BucketingTests {
    @Test("same input always produces same bucket")
    func deterministic() {
        let a = Bucketing.bucket(id: "user-123", flagKey: "checkout")
        let b = Bucketing.bucket(id: "user-123", flagKey: "checkout")
        #expect(a == b)
    }

    /// Changing the hash re-buckets every existing user and silently
    /// reshuffles running experiments, so it may only change in a major
    /// release. These values were computed outside Swift, from the algorithm
    /// as written in the `Bucketing` doc comment.
    @Test("buckets are pinned to the shipped hash")
    func goldenBuckets() {
        #expect(Bucketing.bucket(id: "user-123", flagKey: "checkout") == 2577)
        #expect(
            Bucketing.bucket(id: "11111111-1111-1111-1111-111111111111", flagKey: "new_onboarding")
                == 9032
        )
        #expect(Bucketing.bucket(id: "device-1", flagKey: "k") == 8905)
        #expect(Bucketing.bucket(id: "", flagKey: "") == 9405)
        #expect(Bucketing.bucket(id: "ünïcødé", flagKey: "🚩") == 657)
    }

    @Test("bucket is in [0, 10_000)")
    func boundedRange() {
        for i in 0..<1000 {
            let bucket = Bucketing.bucket(id: "user-\(i)", flagKey: "flag")
            #expect(bucket >= 0)
            #expect(bucket < 10_000)
        }
    }

    @Test("different flag keys give independent buckets for same user")
    func independentPerFlag() {
        let buckets = (0..<10).map { i in
            Bucketing.bucket(id: "user-fixed", flagKey: "flag-\(i)")
        }
        #expect(Set(buckets).count > 1)
    }

    @Test("uniform distribution across 10000 users for a single flag")
    func distribution() {
        var counts = [Int](repeating: 0, count: 10)
        for i in 0..<10_000 {
            let bucket = Bucketing.bucket(id: "user-\(i)", flagKey: "flag")
            counts[bucket / 1_000] += 1
        }
        for count in counts {
            #expect(count > 750 && count < 1250)
        }
    }

    @Test("isInRollout covers 100 buckets per rollout percent")
    func rolloutBoundaries() {
        #expect(!Bucketing.isInRollout(bucket: 0, rollout: 0))
        #expect(Bucketing.isInRollout(bucket: 0, rollout: 1))
        #expect(Bucketing.isInRollout(bucket: 99, rollout: 1))
        #expect(!Bucketing.isInRollout(bucket: 100, rollout: 1))
        #expect(Bucketing.isInRollout(bucket: 4_999, rollout: 50))
        #expect(!Bucketing.isInRollout(bucket: 5_000, rollout: 50))
        #expect(Bucketing.isInRollout(bucket: 9_999, rollout: 100))
    }

    @Test("isInRollout treats out-of-range rollouts as 0 or 100")
    func rolloutOutOfRange() {
        #expect(!Bucketing.isInRollout(bucket: 0, rollout: -5))
        #expect(!Bucketing.isInRollout(bucket: 0, rollout: .min))
        #expect(Bucketing.isInRollout(bucket: 9_999, rollout: 250))
        #expect(Bucketing.isInRollout(bucket: 9_999, rollout: .max))
    }

    @Test("variantIndex scales percent weights onto 10,000 buckets")
    func variantAssignment() {
        let weights = [50, 25, 25]
        #expect(Bucketing.variantIndex(bucket: 0, weights: weights) == 0)
        #expect(Bucketing.variantIndex(bucket: 4_999, weights: weights) == 0)
        #expect(Bucketing.variantIndex(bucket: 5_000, weights: weights) == 1)
        #expect(Bucketing.variantIndex(bucket: 7_499, weights: weights) == 1)
        #expect(Bucketing.variantIndex(bucket: 7_500, weights: weights) == 2)
        #expect(Bucketing.variantIndex(bucket: 9_999, weights: weights) == 2)
    }

    @Test("variantIndex skips zero-weight variants and keeps the last as the remainder")
    func variantRemainder() {
        #expect(Bucketing.variantIndex(bucket: 0, weights: [0, 100]) == 1)
        #expect(Bucketing.variantIndex(bucket: 9_999, weights: [100, 0]) == 0)
        #expect(Bucketing.variantIndex(bucket: 9_999, weights: [1, 99]) == 1)
        #expect(Bucketing.variantIndex(bucket: 99, weights: [1, 99]) == 0)
        #expect(Bucketing.variantIndex(bucket: 100, weights: [1, 99]) == 1)
        // Weights that fall short of 100 (built in code, not decoded) send
        // the uncovered buckets to the last variant.
        #expect(Bucketing.variantIndex(bucket: 9_999, weights: [30, 30]) == 1)
    }

    /// Without a finalizer, the low 4 bits of an FNV-1a hash for one flag
    /// fix the low 4 bits for any other flag with the same ID, so only 16 of
    /// the 256 combinations ever occur.
    @Test("low bits of one flag's bucket say nothing about another flag's")
    func lowBitsIndependentAcrossFlags() {
        var combinations = Set<Int>()
        for i in 0..<10_000 {
            let a = Bucketing.bucket(id: "user-\(i)", flagKey: "checkout") % 16
            let b = Bucketing.bucket(id: "user-\(i)", flagKey: "onboarding") % 16
            combinations.insert(a * 16 + b)
        }
        #expect(combinations.count == 256)
    }

    /// The 1.x hash (FNV-1a modulo 100) left small cohorts of different
    /// flags far from independent: at 1% most pairs of flags shared no users
    /// at all. The IDs are fixed, so the counts are deterministic. The bounds
    /// leave room around the independent rate (N × p²), and the 1.x hash
    /// falls outside them at both 1% and 2%.
    @Test("small cohorts of different flags overlap at about the independent rate")
    func smallCohortsOverlapIndependently() {
        let keys = ["checkout", "onboarding", "new_paywall", "dark_mode"]
        let pairs = keys.indices.flatMap { a in (a + 1..<keys.count).map { b in (a, b) } }
        let userCount = 200_000
        var overlapAt1 = [Int](repeating: 0, count: pairs.count)
        var overlapAt2 = [Int](repeating: 0, count: pairs.count)
        for i in 0..<userCount {
            let id = "user-\(i)"
            let buckets = keys.map { Bucketing.bucket(id: id, flagKey: $0) }
            for (index, (a, b)) in pairs.enumerated() {
                let both = max(buckets[a], buckets[b])
                if Bucketing.isInRollout(bucket: both, rollout: 1) { overlapAt1[index] += 1 }
                if Bucketing.isInRollout(bucket: both, rollout: 2) { overlapAt2[index] += 1 }
            }
        }

        #expect(overlapAt1.allSatisfy { $0 > 0 }, "1% overlaps per pair: \(overlapAt1)")
        for (percent, overlap) in [(1, overlapAt1), (2, overlapAt2)] {
            let expected = Double(pairs.count * userCount * percent * percent) / 10_000
            let observed = Double(overlap.reduce(0, +))
            #expect(
                (0.75 * expected...1.25 * expected).contains(observed),
                "\(percent)% overlap \(observed), independent rate \(expected)"
            )
        }
    }
}

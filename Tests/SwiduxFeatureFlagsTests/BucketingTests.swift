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

    @Test("bucket is in [0, 100)")
    func boundedRange() {
        for i in 0..<1000 {
            let bucket = Bucketing.bucket(id: "user-\(i)", flagKey: "flag")
            #expect(bucket >= 0)
            #expect(bucket < 100)
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
            counts[bucket / 10] += 1
        }
        for count in counts {
            #expect(count > 750 && count < 1250)
        }
    }

    @Test("variantIndex picks correct weighted bucket")
    func variantAssignment() {
        #expect(Bucketing.variantIndex(bucket: 37, weights: [50, 25, 25]) == 0)
        #expect(Bucketing.variantIndex(bucket: 60, weights: [50, 25, 25]) == 1)
        #expect(Bucketing.variantIndex(bucket: 80, weights: [50, 25, 25]) == 2)
        #expect(Bucketing.variantIndex(bucket: 99, weights: [50, 25, 25]) == 2)
        #expect(Bucketing.variantIndex(bucket: 0, weights: [50, 25, 25]) == 0)
    }
}

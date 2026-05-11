# SwiduxFeatureFlags Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the unified `SwiduxFeatureFlags` plugin per the design at `docs/plans/2026-05-10-feature-flags-design.md`.

**Architecture:** New `SwiduxFeatureFlags` SwiftPM target alongside existing domain plugins. Plugin owns a `FeatureFlagsState` slice; reads happen via typed `FlagKey` against state; bucketing is pure FNV-1a; service protocol abstracts the backend with a built-in `HTTPFeatureFlagsService` that fetches a Swidux-defined JSON wire format.

**Tech Stack:** Swift 6.2, SwiftPM, Swidux core (`@Swidux` macro, `SwiduxPlugin`, `KeyValueStore`), `URLSession`, Swift Testing (`@Test`, `#expect`).

**Reference:** All design decisions, wire format, evaluation order, and lifecycle hooks live in `docs/plans/2026-05-10-feature-flags-design.md`. Read it before starting.

**Conventions to follow** (mirror existing plugin packages — `Sources/SwiduxAnalytics/`, `Sources/SwiduxKillswitch/`):

- File header: `//\n//  Filename.swift\n//  SwiduxFeatureFlags\n//`
- One type per file, named after the type
- `@MainActor` on the plugin class
- DocC-style triple-slash comments on public API
- Tests use `@Suite("Type")`, `@MainActor` where needed, `import Testing`, `@testable import SwiduxFeatureFlags`
- Commit per task with `feat:` / `test:` / `docs:` prefix

---

### Task 1: Add `SwiduxFeatureFlags` package target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SwiduxFeatureFlags/.gitkeep` (empty)
- Create: `Tests/SwiduxFeatureFlagsTests/.gitkeep` (empty)

**Step 1: Add product entry**

In `Package.swift`, add to `products` array:

```swift
.library(name: "SwiduxFeatureFlags", targets: ["SwiduxFeatureFlags"]),
```

**Step 2: Add target entry**

In `Package.swift`, add to `targets` array (after `SwiduxAnalytics` target):

```swift
.target(
    name: "SwiduxFeatureFlags",
    dependencies: ["Swidux"],
    plugins: [
        .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
    ]
),
```

**Step 3: Add test target entry**

In `Package.swift`, add to `targets` array (after `SwiduxAnalyticsTests` target):

```swift
.testTarget(
    name: "SwiduxFeatureFlagsTests",
    dependencies: ["Swidux", "SwiduxFeatureFlags"],
    plugins: [
        .plugin(name: "SwiftFormatBuildToolPlugin", package: "SwiftFormatPlugin")
    ]
),
```

**Step 4: Create directory placeholders**

```bash
mkdir -p Sources/SwiduxFeatureFlags Tests/SwiduxFeatureFlagsTests
touch Sources/SwiduxFeatureFlags/.gitkeep Tests/SwiduxFeatureFlagsTests/.gitkeep
```

**Step 5: Verify the package resolves**

Run: `swift build --target SwiduxFeatureFlags`
Expected: builds (with warning about empty target, which is fine)

**Step 6: Commit**

```bash
git add Package.swift Sources/SwiduxFeatureFlags Tests/SwiduxFeatureFlagsTests
git commit -m "Add SwiduxFeatureFlags package target scaffolding"
```

---

### Task 2: Implement `FlagValue` sum type

**Files:**
- Create: `Sources/SwiduxFeatureFlags/FlagValue.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/FlagValueTests.swift`

**Step 1: Write the failing tests**

Create `Tests/SwiduxFeatureFlagsTests/FlagValueTests.swift`:

```swift
//
//  FlagValueTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FlagValue")
struct FlagValueTests {
    @Test("decodes JSON bool")
    func decodesBool() throws {
        let data = "true".data(using: .utf8)!
        let value = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(value == .bool(true))
    }

    @Test("decodes JSON int")
    func decodesInt() throws {
        let data = "42".data(using: .utf8)!
        let value = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(value == .int(42))
    }

    @Test("decodes JSON double")
    func decodesDouble() throws {
        let data = "3.14".data(using: .utf8)!
        let value = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(value == .double(3.14))
    }

    @Test("decodes JSON string")
    func decodesString() throws {
        let data = "\"hello\"".data(using: .utf8)!
        let value = try JSONDecoder().decode(FlagValue.self, from: data)
        #expect(value == .string("hello"))
    }

    @Test("encodes round-trip")
    func encodeRoundTrip() throws {
        let cases: [FlagValue] = [.bool(true), .int(42), .double(3.14), .string("x")]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(FlagValue.self, from: data)
            #expect(decoded == original)
        }
    }
}
```

**Step 2: Run to verify it fails**

Run: `swift test --filter SwiduxFeatureFlagsTests.FlagValue`
Expected: FAIL — `FlagValue` not defined.

**Step 3: Implement `FlagValue`**

Create `Sources/SwiduxFeatureFlags/FlagValue.swift`:

```swift
//
//  FlagValue.swift
//  SwiduxFeatureFlags
//

import Foundation

/// A typed value for a feature flag — boolean, integer, double, or string.
///
/// Closed enum so the wire format and evaluation paths can never produce a
/// runtime `Any`. Constructed by decoding the JSON wire format or supplied
/// programmatically as a local override.
public enum FlagValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "FlagValue must be Bool, Int, Double, or String"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }
}
```

**Step 4: Run to verify pass**

Run: `swift test --filter SwiduxFeatureFlagsTests.FlagValue`
Expected: PASS (5 tests)

**Step 5: Commit**

```bash
git add Sources/SwiduxFeatureFlags/FlagValue.swift Tests/SwiduxFeatureFlagsTests/FlagValueTests.swift
git commit -m "Add FlagValue sum type with JSON Codable"
```

---

### Task 3: Implement `FeatureFlagsConfig` wire format

**Files:**
- Create: `Sources/SwiduxFeatureFlags/FeatureFlagsConfig.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/FeatureFlagsConfigTests.swift`

The wire format from the design doc:

```json
{
  "version": 1,
  "flags": {
    "new_onboarding": { "type": "boolean", "rollout": 25 },
    "checkout_layout": {
      "type": "variant",
      "variants": [
        { "value": "control", "weight": 50 },
        { "value": "treatment", "weight": 50 }
      ]
    },
    "max_free_uploads": { "type": "value", "value": 5 }
  }
}
```

**Step 1: Write failing tests**

Create `Tests/SwiduxFeatureFlagsTests/FeatureFlagsConfigTests.swift`:

```swift
//
//  FeatureFlagsConfigTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsConfig")
struct FeatureFlagsConfigTests {
    @Test("decodes complete example with all three flag types")
    func decodesExample() throws {
        let json = """
        {
          "version": 1,
          "flags": {
            "new_onboarding": { "type": "boolean", "rollout": 25 },
            "checkout_layout": {
              "type": "variant",
              "variants": [
                { "value": "control", "weight": 50 },
                { "value": "treatment", "weight": 50 }
              ]
            },
            "max_free_uploads": { "type": "value", "value": 5 }
          }
        }
        """
        let config = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        #expect(config.version == 1)
        #expect(config.flags.count == 3)

        guard case .boolean(let rollout) = config.flags["new_onboarding"] else {
            Issue.record("expected boolean flag"); return
        }
        #expect(rollout == 25)

        guard case .variant(let variants) = config.flags["checkout_layout"] else {
            Issue.record("expected variant flag"); return
        }
        #expect(variants.count == 2)
        #expect(variants[0].value == "control")
        #expect(variants[0].weight == 50)

        guard case .value(.int(let n)) = config.flags["max_free_uploads"] else {
            Issue.record("expected value flag"); return
        }
        #expect(n == 5)
    }

    @Test("decoding fails for unknown version")
    func rejectsUnknownVersion() {
        let json = """
        { "version": 99, "flags": {} }
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        }
    }

    @Test("empty config is decodable and has no flags")
    func emptyConfig() throws {
        let json = "{ \"version\": 1, \"flags\": {} }"
        let config = try JSONDecoder().decode(FeatureFlagsConfig.self, from: Data(json.utf8))
        #expect(config.flags.isEmpty)
    }

    @Test(".empty static returns empty config")
    func staticEmpty() {
        #expect(FeatureFlagsConfig.empty.flags.isEmpty)
    }
}
```

**Step 2: Run to verify fail**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsConfig`
Expected: FAIL — `FeatureFlagsConfig` undefined.

**Step 3: Implement the wire format**

Create `Sources/SwiduxFeatureFlags/FeatureFlagsConfig.swift`:

```swift
//
//  FeatureFlagsConfig.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Wire-format root for a Swidux feature-flags JSON config.
///
/// Apps host the JSON wherever they like (CDN, Worker, file server) and
/// point the `HTTPFeatureFlagsService` at the URL. The plugin caches the
/// last successful fetch in `KeyValueStore` and falls back to it on failure.
public struct FeatureFlagsConfig: Sendable, Equatable, Codable {
    /// Schema version. Currently `1`. Plugin rejects unknown versions.
    public let version: Int

    /// Flag definitions keyed by stable string key.
    public let flags: [String: FlagDefinition]

    /// An empty config — no flags. Used as initial state and as a safe fallback.
    public static let empty = FeatureFlagsConfig(version: 1, flags: [:])

    public init(version: Int = 1, flags: [String: FlagDefinition]) {
        self.version = version
        self.flags = flags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "unsupported feature-flags config version \(version)"
            )
        }
        self.version = version
        self.flags = try container.decode([String: FlagDefinition].self, forKey: .flags)
    }

    private enum CodingKeys: String, CodingKey { case version, flags }
}

/// One flag's definition in the wire format. Three shapes: boolean rollout,
/// weighted variants, and remote-config scalar values.
public enum FlagDefinition: Sendable, Equatable, Codable {
    /// Boolean flag with rollout percentage (0–100). 0 = off everyone,
    /// 100 = on everyone, in between = stable rollout bucket.
    case boolean(rollout: Int)
    /// Weighted variant assignment. Weights must sum to 100.
    case variant(variants: [Variant])
    /// Remote-config scalar value.
    case value(FlagValue)

    public struct Variant: Sendable, Equatable, Codable {
        public let value: String
        public let weight: Int

        public init(value: String, weight: Int) {
            self.value = value
            self.weight = weight
        }
    }

    private enum CodingKeys: String, CodingKey { case type, rollout, variants, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "boolean":
            let rollout = try container.decode(Int.self, forKey: .rollout)
            self = .boolean(rollout: rollout)
        case "variant":
            let variants = try container.decode([Variant].self, forKey: .variants)
            self = .variant(variants: variants)
        case "value":
            let value = try container.decode(FlagValue.self, forKey: .value)
            self = .value(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown flag type \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .boolean(let rollout):
            try container.encode("boolean", forKey: .type)
            try container.encode(rollout, forKey: .rollout)
        case .variant(let variants):
            try container.encode("variant", forKey: .type)
            try container.encode(variants, forKey: .variants)
        case .value(let value):
            try container.encode("value", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}
```

**Step 4: Run to verify pass**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsConfig`
Expected: PASS (4 tests)

**Step 5: Commit**

```bash
git add Sources/SwiduxFeatureFlags/FeatureFlagsConfig.swift Tests/SwiduxFeatureFlagsTests/FeatureFlagsConfigTests.swift
git commit -m "Add FeatureFlagsConfig wire-format Codable types"
```

---

### Task 4: Implement typed `FlagKey` family

Mirrors the `KVKey` pattern — host apps declare typed keys as static properties.

**Files:**
- Create: `Sources/SwiduxFeatureFlags/FlagKey.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/FlagKeyTests.swift`

**Step 1: Write failing tests**

Create `Tests/SwiduxFeatureFlagsTests/FlagKeyTests.swift`:

```swift
//
//  FlagKeyTests.swift
//  SwiduxFeatureFlagsTests
//

import Testing

@testable import SwiduxFeatureFlags

@Suite("FlagKey")
struct FlagKeyTests {
    enum Variant: String { case control, treatment }

    @Test("BoolFlag exposes its key")
    func boolFlagKey() {
        let flag = BoolFlag("new_onboarding")
        #expect(flag.key == "new_onboarding")
    }

    @Test("VariantFlag exposes its key and default")
    func variantFlagKey() {
        let flag = VariantFlag<Variant>("checkout", default: .control)
        #expect(flag.key == "checkout")
        #expect(flag.defaultValue == .control)
    }

    @Test("ValueFlag exposes its key and default")
    func valueFlagKey() {
        let flag = ValueFlag<Int>("max_uploads", default: 5)
        #expect(flag.key == "max_uploads")
        #expect(flag.defaultValue == 5)
    }
}
```

**Step 2: Run to verify fail**

Run: `swift test --filter SwiduxFeatureFlagsTests.FlagKey`
Expected: FAIL — types undefined.

**Step 3: Implement the typed flag keys**

Create `Sources/SwiduxFeatureFlags/FlagKey.swift`:

```swift
//
//  FlagKey.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Typed key for a boolean feature flag.
public struct BoolFlag: Sendable, Hashable {
    public let key: String
    public init(_ key: String) { self.key = key }
}

/// Typed key for a variant (A/B) flag.
///
/// `Variant` must be `RawRepresentable<String>` so the wire-format string
/// decodes into the host's enum. If the JSON ships a variant the enum
/// doesn't know about, reads return `defaultValue` — fail-safe by construction.
public struct VariantFlag<Variant>: Sendable
where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
    public let key: String
    public let defaultValue: Variant
    public init(_ key: String, default defaultValue: Variant) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

/// Typed key for a remote-tunable scalar value flag.
///
/// `Value` must be one of the four `FlagValue` payload types (`Bool`, `Int`,
/// `Double`, `String`). The plugin's read API enforces this via overloads.
public struct ValueFlag<Value: Sendable>: Sendable {
    public let key: String
    public let defaultValue: Value
    public init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }
}
```

**Step 4: Run to verify pass**

Run: `swift test --filter SwiduxFeatureFlagsTests.FlagKey`
Expected: PASS (3 tests)

**Step 5: Commit**

```bash
git add Sources/SwiduxFeatureFlags/FlagKey.swift Tests/SwiduxFeatureFlagsTests/FlagKeyTests.swift
git commit -m "Add typed FlagKey family (BoolFlag, VariantFlag, ValueFlag)"
```

---

### Task 5: Implement FNV-1a bucketing

Pure function. Stable per `(bucketingID, flagKey)` pair forever. Property-based tests confirm distribution.

**Files:**
- Create: `Sources/SwiduxFeatureFlags/Bucketing.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/BucketingTests.swift`

**Step 1: Write failing tests**

Create `Tests/SwiduxFeatureFlagsTests/BucketingTests.swift`:

```swift
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
        // not all the same
        #expect(Set(buckets).count > 1)
    }

    @Test("uniform distribution across 10000 users for a single flag")
    func distribution() {
        var counts = [Int](repeating: 0, count: 10)  // 10 deciles
        for i in 0..<10_000 {
            let bucket = Bucketing.bucket(id: "user-\(i)", flagKey: "flag")
            counts[bucket / 10] += 1
        }
        // each decile should hold roughly 1000 users; allow ±25%
        for count in counts {
            #expect(count > 750 && count < 1250)
        }
    }

    @Test("variantIndex picks correct weighted bucket")
    func variantAssignment() {
        // bucket=37, weights [50, 25, 25] → cumulative [50, 75, 100] → index 0
        #expect(Bucketing.variantIndex(bucket: 37, weights: [50, 25, 25]) == 0)
        // bucket=60 → index 1
        #expect(Bucketing.variantIndex(bucket: 60, weights: [50, 25, 25]) == 1)
        // bucket=80 → index 2
        #expect(Bucketing.variantIndex(bucket: 80, weights: [50, 25, 25]) == 2)
        // bucket=99 (last) → index 2
        #expect(Bucketing.variantIndex(bucket: 99, weights: [50, 25, 25]) == 2)
        // bucket=0 → index 0
        #expect(Bucketing.variantIndex(bucket: 0, weights: [50, 25, 25]) == 0)
    }
}
```

**Step 2: Run to verify fail**

Run: `swift test --filter SwiduxFeatureFlagsTests.Bucketing`
Expected: FAIL — `Bucketing` undefined.

**Step 3: Implement bucketing**

Create `Sources/SwiduxFeatureFlags/Bucketing.swift`:

```swift
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
/// FNV-1a chosen because it's simple, dependency-free, and matches GrowthBook's
/// algorithm so apps migrating from GrowthBook get compatible buckets.
public enum Bucketing {
    /// Returns a bucket in `[0, 100)` for the given identity and flag key.
    public static func bucket(id: String, flagKey: String) -> Int {
        var hash: UInt32 = 0x811c_9dc5
        let prime: UInt32 = 0x0100_0193

        func feed(_ s: String) {
            for byte in s.utf8 {
                hash ^= UInt32(byte)
                hash = hash &* prime
            }
        }
        feed(id)
        feed(":")
        feed(flagKey)

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
```

**Step 4: Run to verify pass**

Run: `swift test --filter SwiduxFeatureFlagsTests.Bucketing`
Expected: PASS (5 tests)

**Step 5: Commit**

```bash
git add Sources/SwiduxFeatureFlags/Bucketing.swift Tests/SwiduxFeatureFlagsTests/BucketingTests.swift
git commit -m "Add FNV-1a bucketing and weighted variant assignment"
```

---

### Task 6: Implement `FeatureFlagsAction` enum

Action enum is pure data, but we'll add tests anyway to lock the case shapes.

**Files:**
- Create: `Sources/SwiduxFeatureFlags/FeatureFlagsAction.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/FeatureFlagsActionTests.swift`

**Step 1: Write failing tests**

Create `Tests/SwiduxFeatureFlagsTests/FeatureFlagsActionTests.swift`:

```swift
//
//  FeatureFlagsActionTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsAction")
struct FeatureFlagsActionTests {
    @Test("action is Sendable and Equatable across all cases")
    func allCases() {
        let cases: [FeatureFlagsAction] = [
            .refresh,
            .refreshSucceeded(.empty, fetchedAt: Date(timeIntervalSince1970: 0)),
            .refreshFailed("oops"),
            .setLocalOverride(key: "k", value: .bool(true)),
            .clearLocalOverride(key: "k"),
            .clearAllLocalOverrides,
            .recordExposure(key: "k"),
        ]
        // Equatable spot-check
        #expect(FeatureFlagsAction.refresh == FeatureFlagsAction.refresh)
        #expect(cases.count == 7)
    }
}
```

**Step 2: Run to verify fail**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsAction`
Expected: FAIL — undefined.

**Step 3: Implement action enum**

Create `Sources/SwiduxFeatureFlags/FeatureFlagsAction.swift`:

```swift
//
//  FeatureFlagsAction.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Actions handled by ``FeatureFlagsPlugin``.
public enum FeatureFlagsAction: Sendable, Equatable {
    /// Trigger a fetch. Debounced against `lastFetchedAt + minInterval`
    /// when the plugin's `refreshPolicy` is `.automatic`.
    case refresh

    /// Service returned a fresh config. Plugin updates state and
    /// persists to `KeyValueStore`.
    case refreshSucceeded(FeatureFlagsConfig, fetchedAt: Date)

    /// Service threw. Plugin keeps last-known-good config.
    case refreshFailed(String)

    /// Set a local override that beats remote evaluation.
    case setLocalOverride(key: String, value: FlagValue)

    /// Remove a single local override.
    case clearLocalOverride(key: String)

    /// Remove all local overrides.
    case clearAllLocalOverrides

    /// Record that a flag was applied to the user (variant shown).
    /// Plugin dedupes per session and fires the optional `onExposure` callback.
    case recordExposure(key: String)
}
```

**Step 4: Run to verify pass**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsAction`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiduxFeatureFlags/FeatureFlagsAction.swift Tests/SwiduxFeatureFlagsTests/FeatureFlagsActionTests.swift
git commit -m "Add FeatureFlagsAction enum"
```

---

### Task 7: Implement `FeatureFlagsState`

The state slice. Uses `@Swidux` macro for observation. Includes a hydration helper that pulls install ID and last-known config from `KeyValueStore`.

**Files:**
- Create: `Sources/SwiduxFeatureFlags/FeatureFlagsState.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/FeatureFlagsStateTests.swift`

**Step 1: Write failing tests**

Create `Tests/SwiduxFeatureFlagsTests/FeatureFlagsStateTests.swift`:

```swift
//
//  FeatureFlagsStateTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Swidux
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsState")
struct FeatureFlagsStateTests {
    @Test("default initializer sets empty config and generates install ID")
    func defaultInit() {
        let state = FeatureFlagsState()
        #expect(state.config == .empty)
        #expect(state.lastFetchedAt == nil)
        #expect(state.localOverrides.isEmpty)
        #expect(state.exposedKeys.isEmpty)
        // installID is a UUID (zero is invalid)
        #expect(state.installID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    @Test("hydrated reads install ID from key-value store")
    func hydratedRecallsInstallID() {
        let store = InMemoryKeyValueStore()
        let original = UUID()
        store.setValue(original.uuidString, for: .featureFlagsInstallID)

        let state = FeatureFlagsState.hydrated(from: store)
        #expect(state.installID == original)
    }

    @Test("hydrated generates and persists install ID when missing")
    func hydratedGeneratesInstallID() {
        let store = InMemoryKeyValueStore()
        let state = FeatureFlagsState.hydrated(from: store)
        let persisted: String? = store.value(.featureFlagsInstallID)
        #expect(persisted == state.installID.uuidString)
    }

    @Test("hydrated recalls last-known config")
    func hydratedRecallsConfig() {
        let store = InMemoryKeyValueStore()
        let config = FeatureFlagsConfig(version: 1, flags: [
            "x": .boolean(rollout: 50)
        ])
        let data = try! JSONEncoder().encode(config)
        store.setData(data, for: .featureFlagsConfig)

        let state = FeatureFlagsState.hydrated(from: store)
        #expect(state.config == config)
    }

    @Test("hydrated falls back to defaultConfig when no cache")
    func hydratedUsesDefault() {
        let store = InMemoryKeyValueStore()
        let fallback = FeatureFlagsConfig(version: 1, flags: ["fb": .boolean(rollout: 10)])
        let state = FeatureFlagsState.hydrated(from: store, defaultConfig: fallback)
        #expect(state.config == fallback)
    }
}
```

**Note:** This test references `KVKey` extensions and a `setData`/`data` API that may not exist yet on `KeyValueStore`. Check `Sources/Swidux/KeyValueStore.swift` first — if `KeyValueStore` only handles JSON-encoded values via `setValue<T: Codable>`, we'll store the config under a `Codable` key directly and skip raw `Data` access. Adapt the tests accordingly. The intent is unchanged: **install ID and config are persisted via `KeyValueStore`.**

**Step 2: Verify the `KeyValueStore` API shape**

Run: `cat Sources/Swidux/KeyValueStore.swift`

Identify: how does one declare typed keys? (Look for `KVKey` extension pattern.) How does one write values? (`setValue(_:for:)`?) Adjust the test to match. If the existing API only handles `Codable` values, declare `KVKey` extensions for `String` (install ID) and `FeatureFlagsConfig` (config) and use `setValue` / `value(_:)` directly.

**Step 3: Run tests, expect fail**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsState`
Expected: FAIL — types undefined.

**Step 4: Implement state and KVKey extensions**

Create `Sources/SwiduxFeatureFlags/FeatureFlagsState.swift`:

```swift
//
//  FeatureFlagsState.swift
//  SwiduxFeatureFlags
//

import Foundation
import Swidux

/// State slice owned by ``FeatureFlagsPlugin``. Hosted in the app's root
/// state via `@Slice var featureFlags: FeatureFlagsState`.
@Swidux
public nonisolated struct FeatureFlagsState: Equatable, Sendable {
    /// Last successfully fetched (or hydrated) config.
    public var config: FeatureFlagsConfig

    /// Timestamp of the last successful fetch. `nil` until first fetch.
    public var lastFetchedAt: Date?

    /// Last fetch error message — for debug UI only, never user-facing.
    public var lastFetchError: String?

    /// `true` while a refresh effect is in flight.
    public var isFetching: Bool

    /// Local overrides — beat remote evaluation.
    public var localOverrides: [String: FlagValue]

    /// Session-scoped set of flags whose exposure has already been recorded.
    /// Reset on every app launch.
    public var exposedKeys: Set<String>

    /// Stable per-install identity used for bucketing when no `userIDKeyPath`
    /// resolves to a non-nil value.
    public var installID: UUID

    public init(
        config: FeatureFlagsConfig = .empty,
        lastFetchedAt: Date? = nil,
        lastFetchError: String? = nil,
        isFetching: Bool = false,
        localOverrides: [String: FlagValue] = [:],
        exposedKeys: Set<String> = [],
        installID: UUID = UUID()
    ) {
        self.config = config
        self.lastFetchedAt = lastFetchedAt
        self.lastFetchError = lastFetchError
        self.isFetching = isFetching
        self.localOverrides = localOverrides
        self.exposedKeys = exposedKeys
        self.installID = installID
    }

    /// Builds an initial state by reading the install ID and last-known
    /// config from the supplied key-value store. Generates and persists
    /// a new install ID if none is stored.
    public static func hydrated(
        from store: any KeyValueStore,
        defaultConfig: FeatureFlagsConfig? = nil
    ) -> FeatureFlagsState {
        let installID: UUID
        if let stored: String = store.value(.featureFlagsInstallID),
           let uuid = UUID(uuidString: stored) {
            installID = uuid
        } else {
            installID = UUID()
            store.setValue(installID.uuidString, for: .featureFlagsInstallID)
        }

        let config: FeatureFlagsConfig =
            store.value(.featureFlagsConfig)
            ?? defaultConfig
            ?? .empty

        return FeatureFlagsState(config: config, installID: installID)
    }
}

extension KVKey where Value == String {
    /// Install-scoped UUID used for bucketing. Persisted on first generation.
    public static let featureFlagsInstallID = KVKey<String>("swidux.featureFlags.installID")
}

extension KVKey where Value == FeatureFlagsConfig {
    /// Last successfully fetched feature-flags config. Hydrated at startup.
    public static let featureFlagsConfig = KVKey<FeatureFlagsConfig>("swidux.featureFlags.config")
}
```

**Step 5: Run tests, expect pass**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsState`
Expected: PASS

**Step 6: Commit**

```bash
git add Sources/SwiduxFeatureFlags/FeatureFlagsState.swift Tests/SwiduxFeatureFlagsTests/FeatureFlagsStateTests.swift
git commit -m "Add FeatureFlagsState slice with KeyValueStore hydration"
```

---

### Task 8: Implement `FeatureFlagsService` protocol + `HTTPFeatureFlagsService`

The service protocol is one method. The HTTP implementation is the built-in.

**Files:**
- Create: `Sources/SwiduxFeatureFlags/FeatureFlagsService.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/HTTPFeatureFlagsServiceTests.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/MockFeatureFlagsService.swift`

**Step 1: Write the mock service helper (reusable across plugin tests)**

Create `Tests/SwiduxFeatureFlagsTests/MockFeatureFlagsService.swift`:

```swift
//
//  MockFeatureFlagsService.swift
//  SwiduxFeatureFlagsTests
//

import Foundation

@testable import SwiduxFeatureFlags

/// Test-only service that returns a preconfigured config or throws.
final class MockFeatureFlagsService: FeatureFlagsService, @unchecked Sendable {
    enum Outcome {
        case success(FeatureFlagsConfig)
        case failure(any Error)
    }

    var outcome: Outcome
    private(set) var fetchCount: Int = 0

    init(outcome: Outcome) { self.outcome = outcome }

    func fetch() async throws -> FeatureFlagsConfig {
        fetchCount += 1
        switch outcome {
        case .success(let config): return config
        case .failure(let error): throw error
        }
    }
}
```

**Step 2: Write failing tests for `HTTPFeatureFlagsService`**

Create `Tests/SwiduxFeatureFlagsTests/HTTPFeatureFlagsServiceTests.swift`:

```swift
//
//  HTTPFeatureFlagsServiceTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("HTTPFeatureFlagsService")
struct HTTPFeatureFlagsServiceTests {
    @Test("decodes a valid JSON response")
    func decodesValidResponse() async throws {
        let json = """
        { "version": 1, "flags": { "f": { "type": "boolean", "rollout": 50 } } }
        """
        let url = URL(string: "https://example.test/flags.json")!
        let session = StubURLSession.with(data: Data(json.utf8), response: .ok(url: url))

        let service = HTTPFeatureFlagsService(url: url, session: session)
        let config = try await service.fetch()

        #expect(config.version == 1)
        #expect(config.flags.count == 1)
    }

    @Test("throws on non-2xx response")
    func throwsOnHTTPError() async {
        let url = URL(string: "https://example.test/flags.json")!
        let session = StubURLSession.with(data: Data(), response: .status(500, url: url))
        let service = HTTPFeatureFlagsService(url: url, session: session)

        await #expect(throws: (any Error).self) {
            _ = try await service.fetch()
        }
    }

    @Test("throws on malformed JSON")
    func throwsOnMalformedJSON() async {
        let url = URL(string: "https://example.test/flags.json")!
        let session = StubURLSession.with(data: Data("not json".utf8), response: .ok(url: url))
        let service = HTTPFeatureFlagsService(url: url, session: session)

        await #expect(throws: (any Error).self) {
            _ = try await service.fetch()
        }
    }
}

// MARK: - URLSession stub helpers

private enum StubURLSession {
    static func with(data: Data, response: HTTPURLResponse) -> URLSession {
        URLProtocolStub.installer = { (data, response) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }
}

private extension HTTPURLResponse {
    static func ok(url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
    static func status(_ code: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var installer: (() -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (data, response) = URLProtocolStub.installer?() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

**Step 3: Run, expect fail**

Run: `swift test --filter SwiduxFeatureFlagsTests.HTTPFeatureFlagsService`
Expected: FAIL — `FeatureFlagsService` and `HTTPFeatureFlagsService` undefined.

**Step 4: Implement service protocol and HTTP service**

Create `Sources/SwiduxFeatureFlags/FeatureFlagsService.swift`:

```swift
//
//  FeatureFlagsService.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Provider-agnostic feature-flags backend.
///
/// Implementations need only fetch the wire-format config. Caching,
/// hydration, and evaluation are owned by the plugin so they are identical
/// regardless of backend. Built-in: ``HTTPFeatureFlagsService``. Third-party
/// adapters (LaunchDarkly, GrowthBook, Statsig) conform without changing
/// the plugin.
public protocol FeatureFlagsService: Sendable {
    func fetch() async throws -> FeatureFlagsConfig
}

/// Default service: fetches the JSON wire format from a URL.
///
/// Apps host their flags JSON wherever convenient — static file on a CDN,
/// Cloudflare Worker, their own backend. Zero infrastructure required.
public struct HTTPFeatureFlagsService: FeatureFlagsService {
    public let url: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(
        url: URL,
        session: URLSession = .shared,
        decoder: JSONDecoder = .init()
    ) {
        self.url = url
        self.session = session
        self.decoder = decoder
    }

    public func fetch() async throws -> FeatureFlagsConfig {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        return try decoder.decode(FeatureFlagsConfig.self, from: data)
    }
}
```

**Step 5: Run, expect pass**

Run: `swift test --filter SwiduxFeatureFlagsTests.HTTPFeatureFlagsService`
Expected: PASS (3 tests)

**Step 6: Commit**

```bash
git add Sources/SwiduxFeatureFlags/FeatureFlagsService.swift Tests/SwiduxFeatureFlagsTests/HTTPFeatureFlagsServiceTests.swift Tests/SwiduxFeatureFlagsTests/MockFeatureFlagsService.swift
git commit -m "Add FeatureFlagsService protocol and HTTP-backed implementation"
```

---

### Task 9: Implement `FeatureFlagsPlugin` skeleton + `.refresh` flow

This task does the plugin in two slices because the file is large. Slice 1: plugin scaffolding, init, and `.refresh` / `.refreshSucceeded` / `.refreshFailed` handling. Slice 2 (next task): overrides + exposure.

**Files:**
- Create: `Sources/SwiduxFeatureFlags/FeatureFlagsPlugin.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/FeatureFlagsPluginTests.swift`
- Create: `Sources/SwiduxFeatureFlags/RefreshPolicy.swift`

**Step 1: Add RefreshPolicy**

Create `Sources/SwiduxFeatureFlags/RefreshPolicy.swift`:

```swift
//
//  RefreshPolicy.swift
//  SwiduxFeatureFlags
//

import Foundation

/// Controls how `FeatureFlagsAction.refresh` behaves.
public enum RefreshPolicy: Sendable {
    /// Every `.refresh` triggers a fetch. No debouncing.
    case manual
    /// Debounce against `lastFetchedAt + minInterval`. Default 5 minutes.
    case automatic(minInterval: TimeInterval)

    public static let automatic: RefreshPolicy = .automatic(minInterval: 300)
}
```

**Step 2: Write failing tests for `.refresh` flow**

Create `Tests/SwiduxFeatureFlagsTests/FeatureFlagsPluginTests.swift`:

```swift
//
//  FeatureFlagsPluginTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Swidux
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsPlugin")
@MainActor
struct FeatureFlagsPluginTests {
    // MARK: - Test fixtures

    struct TestState: Sendable, Equatable {
        var featureFlags = FeatureFlagsState()
        var userID: String? = nil
    }

    enum TestAction: Sendable, Equatable {
        case featureFlags(FeatureFlagsAction)
        case unrelated
    }

    func makePlugin(
        service: any FeatureFlagsService = MockFeatureFlagsService(outcome: .success(.empty)),
        userIDKeyPath: KeyPath<TestState, String?>? = nil,
        refreshPolicy: RefreshPolicy = .manual,
        defaultConfig: FeatureFlagsConfig? = nil,
        keyValueStore: any KeyValueStore = InMemoryKeyValueStore(),
        onExposure: (@Sendable (String, FlagValue) -> Void)? = nil
    ) -> FeatureFlagsPlugin<TestState, TestAction> {
        FeatureFlagsPlugin(
            state: \.featureFlags,
            action: TestAction.featureFlags,
            extractAction: {
                if case .featureFlags(let a) = $0 { return a }
                return nil
            },
            service: service,
            userIDKeyPath: userIDKeyPath,
            refreshPolicy: refreshPolicy,
            defaultConfig: defaultConfig,
            keyValueStore: keyValueStore,
            onExposure: onExposure
        )
    }

    // MARK: - .refresh

    @Test(".refresh hits the service and dispatches refreshSucceeded")
    func refreshSuccess() async {
        let config = FeatureFlagsConfig(version: 1, flags: ["f": .boolean(rollout: 50)])
        let service = MockFeatureFlagsService(outcome: .success(config))
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        #expect(state.featureFlags.isFetching)

        var dispatched: [TestAction] = []
        await effect?({ action in dispatched.append(action) })

        #expect(service.fetchCount == 1)
        #expect(dispatched.count == 1)
        guard case .featureFlags(.refreshSucceeded(let received, _)) = dispatched[0] else {
            Issue.record("expected refreshSucceeded"); return
        }
        #expect(received == config)
    }

    @Test(".refresh dispatches refreshFailed on service error")
    func refreshFailure() async {
        let service = MockFeatureFlagsService(outcome: .failure(URLError(.notConnectedToInternet)))
        let plugin = makePlugin(service: service)
        var state = TestState()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        var dispatched: [TestAction] = []
        await effect?({ action in dispatched.append(action) })

        #expect(dispatched.count == 1)
        guard case .featureFlags(.refreshFailed) = dispatched[0] else {
            Issue.record("expected refreshFailed"); return
        }
    }

    @Test(".refreshSucceeded updates state with new config and clears isFetching")
    func refreshSucceededUpdatesState() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.isFetching = true
        let config = FeatureFlagsConfig(version: 1, flags: ["x": .boolean(rollout: 100)])
        let now = Date()

        _ = plugin.reduce(state: &state, action: .featureFlags(.refreshSucceeded(config, fetchedAt: now)))

        #expect(state.featureFlags.config == config)
        #expect(state.featureFlags.lastFetchedAt == now)
        #expect(state.featureFlags.isFetching == false)
        #expect(state.featureFlags.lastFetchError == nil)
    }

    @Test(".refreshFailed records error message and clears isFetching")
    func refreshFailedUpdatesState() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.isFetching = true

        _ = plugin.reduce(state: &state, action: .featureFlags(.refreshFailed("boom")))

        #expect(state.featureFlags.isFetching == false)
        #expect(state.featureFlags.lastFetchError == "boom")
    }

    @Test("automatic policy debounces refresh inside minInterval")
    func automaticDebounce() async {
        let service = MockFeatureFlagsService(outcome: .success(.empty))
        let plugin = makePlugin(service: service, refreshPolicy: .automatic(minInterval: 300))
        var state = TestState()
        state.featureFlags.lastFetchedAt = Date()  // just now

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        await effect?({ _ in })

        #expect(service.fetchCount == 0)  // debounced, no fetch
    }

    @Test("manual policy never debounces")
    func manualNeverDebounces() async {
        let service = MockFeatureFlagsService(outcome: .success(.empty))
        let plugin = makePlugin(service: service, refreshPolicy: .manual)
        var state = TestState()
        state.featureFlags.lastFetchedAt = Date()

        let effect = plugin.reduce(state: &state, action: .featureFlags(.refresh))
        await effect?({ _ in })

        #expect(service.fetchCount == 1)
    }
}
```

**Step 3: Run, expect fail**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsPlugin`
Expected: FAIL — `FeatureFlagsPlugin` undefined.

**Step 4: Implement plugin scaffolding + refresh flow**

Create `Sources/SwiduxFeatureFlags/FeatureFlagsPlugin.swift`:

```swift
//
//  FeatureFlagsPlugin.swift
//  SwiduxFeatureFlags
//

import Foundation
import Swidux

/// A Swidux plugin for feature flags + A/B variants + remote-tunable values.
///
/// State lives in ``FeatureFlagsState``. Reads happen via typed ``BoolFlag`` /
/// ``VariantFlag`` / ``ValueFlag`` against the store. Bucketing is pure FNV-1a
/// against the configured identity. The wire format is fetched by
/// ``FeatureFlagsService`` (default: ``HTTPFeatureFlagsService``) and cached
/// in `KeyValueStore`.
@MainActor
public final class FeatureFlagsPlugin<RootState, RootAction>: SwiduxPlugin {
    public typealias State = RootState
    public typealias Action = RootAction

    private let stateKeyPath: WritableKeyPath<RootState, FeatureFlagsState>
    private let toRootAction: @Sendable (FeatureFlagsAction) -> RootAction
    private let extractAction: @Sendable (RootAction) -> FeatureFlagsAction?
    private let service: any FeatureFlagsService
    private let userIDKeyPath: KeyPath<RootState, String?>?
    private let refreshPolicy: RefreshPolicy
    private let keyValueStore: any KeyValueStore
    private let onExposure: (@Sendable (String, FlagValue) -> Void)?

    /// Creates the plugin and wires it into the host's root state and action types.
    public init(
        state: WritableKeyPath<RootState, FeatureFlagsState>,
        action toRootAction: @escaping @Sendable (FeatureFlagsAction) -> RootAction,
        extractAction: @escaping @Sendable (RootAction) -> FeatureFlagsAction?,
        service: any FeatureFlagsService,
        userIDKeyPath: KeyPath<RootState, String?>? = nil,
        refreshPolicy: RefreshPolicy = .automatic,
        defaultConfig: FeatureFlagsConfig? = nil,
        keyValueStore: any KeyValueStore,
        onExposure: (@Sendable (String, FlagValue) -> Void)? = nil
    ) {
        self.stateKeyPath = state
        self.toRootAction = toRootAction
        self.extractAction = extractAction
        self.service = service
        self.userIDKeyPath = userIDKeyPath
        self.refreshPolicy = refreshPolicy
        self.keyValueStore = keyValueStore
        self.onExposure = onExposure
        _ = defaultConfig  // consumed by FeatureFlagsState.hydrated at host wiring time
    }

    public func reduce(state: inout RootState, action: RootAction) -> Effect<RootAction>? {
        guard let local = extractAction(action) else { return nil }
        return reduceLocal(state: &state[keyPath: stateKeyPath], action: local)
    }

    private func reduceLocal(
        state: inout FeatureFlagsState,
        action: FeatureFlagsAction
    ) -> Effect<RootAction>? {
        switch action {
        case .refresh:
            if shouldDebounce(state: state) { return nil }
            state.isFetching = true
            let service = self.service
            let lift = self.toRootAction
            return { send in
                do {
                    let config = try await service.fetch()
                    await send(lift(.refreshSucceeded(config, fetchedAt: Date())))
                } catch {
                    await send(lift(.refreshFailed(String(describing: error))))
                }
            }

        case .refreshSucceeded(let config, let fetchedAt):
            state.config = config
            state.lastFetchedAt = fetchedAt
            state.lastFetchError = nil
            state.isFetching = false
            let store = self.keyValueStore
            return { _ in
                await MainActor.run {
                    store.setValue(config, for: .featureFlagsConfig)
                }
            }

        case .refreshFailed(let message):
            state.lastFetchError = message
            state.isFetching = false
            return nil

        case .setLocalOverride, .clearLocalOverride, .clearAllLocalOverrides, .recordExposure:
            // Implemented in the next task.
            return nil
        }
    }

    private func shouldDebounce(state: FeatureFlagsState) -> Bool {
        guard case .automatic(let minInterval) = refreshPolicy,
              let lastFetched = state.lastFetchedAt else {
            return false
        }
        return Date().timeIntervalSince(lastFetched) < minInterval
    }
}
```

**Step 5: Run, expect pass**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsPlugin`
Expected: PASS (6 tests)

**Step 6: Commit**

```bash
git add Sources/SwiduxFeatureFlags/FeatureFlagsPlugin.swift Sources/SwiduxFeatureFlags/RefreshPolicy.swift Tests/SwiduxFeatureFlagsTests/FeatureFlagsPluginTests.swift
git commit -m "Add FeatureFlagsPlugin with refresh flow and debouncing"
```

---

### Task 10: Add overrides and exposure handling to plugin

Extends the plugin to handle `.setLocalOverride` / `.clearLocalOverride` / `.clearAllLocalOverrides` / `.recordExposure`.

**Files:**
- Modify: `Sources/SwiduxFeatureFlags/FeatureFlagsPlugin.swift`
- Modify: `Tests/SwiduxFeatureFlagsTests/FeatureFlagsPluginTests.swift`

**Step 1: Append failing tests**

Add to `FeatureFlagsPluginTests.swift`:

```swift
    // MARK: - Overrides

    @Test("setLocalOverride writes into state")
    func setLocalOverride() {
        let plugin = makePlugin()
        var state = TestState()

        _ = plugin.reduce(state: &state, action: .featureFlags(.setLocalOverride(key: "k", value: .bool(true))))

        #expect(state.featureFlags.localOverrides["k"] == .bool(true))
    }

    @Test("clearLocalOverride removes a single key")
    func clearLocalOverride() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.localOverrides = ["a": .bool(true), "b": .int(1)]

        _ = plugin.reduce(state: &state, action: .featureFlags(.clearLocalOverride(key: "a")))

        #expect(state.featureFlags.localOverrides == ["b": .int(1)])
    }

    @Test("clearAllLocalOverrides empties the map")
    func clearAllLocalOverrides() {
        let plugin = makePlugin()
        var state = TestState()
        state.featureFlags.localOverrides = ["a": .bool(true)]

        _ = plugin.reduce(state: &state, action: .featureFlags(.clearAllLocalOverrides))

        #expect(state.featureFlags.localOverrides.isEmpty)
    }

    // MARK: - Exposure

    @Test("recordExposure inserts key and fires onExposure once")
    func recordExposureFiresOnce() async {
        let counter = ExposureCounter()
        let plugin = makePlugin(onExposure: { key, value in
            counter.record(key: key, value: value)
        })
        var state = TestState()
        state.featureFlags.config = FeatureFlagsConfig(version: 1, flags: [
            "k": .boolean(rollout: 100)
        ])

        let effect1 = plugin.reduce(state: &state, action: .featureFlags(.recordExposure(key: "k")))
        await effect1?({ _ in })

        #expect(state.featureFlags.exposedKeys.contains("k"))
        #expect(counter.count == 1)

        let effect2 = plugin.reduce(state: &state, action: .featureFlags(.recordExposure(key: "k")))
        await effect2?({ _ in })

        #expect(counter.count == 1)  // deduped
    }

    @Test("recordExposure for unknown key does not fire callback")
    func recordExposureUnknownKey() async {
        let counter = ExposureCounter()
        let plugin = makePlugin(onExposure: { key, value in counter.record(key: key, value: value) })
        var state = TestState()  // config is .empty

        let effect = plugin.reduce(state: &state, action: .featureFlags(.recordExposure(key: "nope")))
        await effect?({ _ in })

        #expect(counter.count == 0)
        #expect(state.featureFlags.exposedKeys.contains("nope") == false)
    }
}

// MARK: - Helpers

@MainActor
final class ExposureCounter {
    private(set) var count = 0
    private(set) var records: [(String, FlagValue)] = []
    func record(key: String, value: FlagValue) {
        count += 1
        records.append((key, value))
    }
}
```

**Step 2: Run, expect fail**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsPlugin`
Expected: FAIL on the new tests.

**Step 3: Extend plugin to handle these actions**

In `Sources/SwiduxFeatureFlags/FeatureFlagsPlugin.swift`, replace the catch-all stub case in `reduceLocal` with concrete handling. The replacement looks like:

```swift
        case .setLocalOverride(let key, let value):
            state.localOverrides[key] = value
            return nil

        case .clearLocalOverride(let key):
            state.localOverrides.removeValue(forKey: key)
            return nil

        case .clearAllLocalOverrides:
            state.localOverrides.removeAll()
            return nil

        case .recordExposure(let key):
            // Dedup. Only fire callback for known flags whose evaluation
            // resolves to a concrete value.
            guard !state.exposedKeys.contains(key) else { return nil }
            guard let evaluation = evaluateForExposure(state: state, key: key) else {
                return nil
            }
            state.exposedKeys.insert(key)
            let callback = self.onExposure
            return { _ in
                await MainActor.run { callback?(key, evaluation) }
            }
        }
    }

    /// Resolves the value to record for an exposure. Returns nil if the flag
    /// is not present in the config (defensive — exposure for an unknown flag
    /// is meaningless).
    ///
    /// Local overrides take precedence so QA-toggled flags still record exposures.
    private func evaluateForExposure(state: FeatureFlagsState, key: String) -> FlagValue? {
        if let override = state.localOverrides[key] { return override }
        guard let definition = state.config.flags[key] else { return nil }
        switch definition {
        case .boolean(let rollout):
            let bucket = Bucketing.bucket(id: state.installID.uuidString, flagKey: key)
            return .bool(bucket < rollout)
        case .variant(let variants):
            let bucket = Bucketing.bucket(id: state.installID.uuidString, flagKey: key)
            let weights = variants.map { $0.weight }
            let index = Bucketing.variantIndex(bucket: bucket, weights: weights)
            return .string(variants[index].value)
        case .value(let value):
            return value
        }
    }
```

**Note:** The bucketing here uses `installID` because `evaluateForExposure` runs from a state slice without access to the root state. This is acceptable — exposure analytics will record the bucket the user was actually in, and the read API (next task) will use the configured `userIDKeyPath` for live reads. Document this trade-off as a code comment.

**Step 4: Run, expect pass**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsPlugin`
Expected: PASS (now 11 tests).

**Step 5: Commit**

```bash
git add Sources/SwiduxFeatureFlags/FeatureFlagsPlugin.swift Tests/SwiduxFeatureFlagsTests/FeatureFlagsPluginTests.swift
git commit -m "Add local overrides and exposure recording to FeatureFlagsPlugin"
```

---

### Task 11: Implement read API on `FeatureFlagsState`

Pure synchronous reads. Called from views via `store.featureFlags.isEnabled(.flag)`.

The read API takes the bucketing identity as a parameter (the host wires it through). For ergonomics, we provide an extension that resolves identity from a closure passed at hydration time — but the simpler approach for v1 is:

- Public read API on `FeatureFlagsState` that accepts an explicit `bucketingID: String` parameter.
- Convenience overloads with no `bucketingID` parameter use `installID` as default.
- Apps that want user-ID-based bucketing read it via the keypath at the call site, or wire a small helper extension on their `Store`.

**Files:**
- Modify: `Sources/SwiduxFeatureFlags/FeatureFlagsState.swift`
- Create: `Tests/SwiduxFeatureFlagsTests/FeatureFlagsReadTests.swift`

**Step 1: Write failing tests**

Create `Tests/SwiduxFeatureFlagsTests/FeatureFlagsReadTests.swift`:

```swift
//
//  FeatureFlagsReadTests.swift
//  SwiduxFeatureFlagsTests
//

import Foundation
import Testing

@testable import SwiduxFeatureFlags

@Suite("FeatureFlagsState read API")
struct FeatureFlagsReadTests {
    enum CheckoutVariant: String { case control, treatment }

    func makeState(flags: [String: FlagDefinition], overrides: [String: FlagValue] = [:]) -> FeatureFlagsState {
        FeatureFlagsState(
            config: FeatureFlagsConfig(version: 1, flags: flags),
            localOverrides: overrides,
            installID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }

    // MARK: - Boolean

    @Test("isEnabled returns Swift default when flag missing")
    func boolMissing() {
        let state = makeState(flags: [:])
        #expect(state.isEnabled(BoolFlag("nope"), default: false) == false)
        #expect(state.isEnabled(BoolFlag("nope"), default: true) == true)
    }

    @Test("isEnabled rollout=100 always true")
    func boolFullRollout() {
        let state = makeState(flags: ["f": .boolean(rollout: 100)])
        #expect(state.isEnabled(BoolFlag("f"), default: false) == true)
    }

    @Test("isEnabled rollout=0 always false")
    func boolNoRollout() {
        let state = makeState(flags: ["f": .boolean(rollout: 0)])
        #expect(state.isEnabled(BoolFlag("f"), default: true) == false)
    }

    @Test("local override beats remote rollout")
    func boolOverride() {
        let state = makeState(flags: ["f": .boolean(rollout: 0)], overrides: ["f": .bool(true)])
        #expect(state.isEnabled(BoolFlag("f"), default: false) == true)
    }

    // MARK: - Variant

    @Test("variant returns Swift default when flag missing")
    func variantMissing() {
        let state = makeState(flags: [:])
        #expect(state.variant(of: VariantFlag<CheckoutVariant>("nope", default: .control)) == .control)
    }

    @Test("variant returns Swift default when JSON variant doesn't match enum")
    func variantUnknownString() {
        let state = makeState(flags: [
            "checkout": .variant(variants: [.init(value: "wizard", weight: 100)])
        ])
        #expect(state.variant(of: VariantFlag<CheckoutVariant>("checkout", default: .control)) == .control)
    }

    @Test("variant local override beats remote")
    func variantOverride() {
        let state = makeState(
            flags: ["checkout": .variant(variants: [.init(value: "control", weight: 100)])],
            overrides: ["checkout": .string("treatment")]
        )
        #expect(state.variant(of: VariantFlag<CheckoutVariant>("checkout", default: .control)) == .treatment)
    }

    // MARK: - Value

    @Test("value returns Swift default when flag missing")
    func valueMissing() {
        let state = makeState(flags: [:])
        #expect(state.value(of: ValueFlag<Int>("max", default: 5)) == 5)
    }

    @Test("value returns config value")
    func valueFromConfig() {
        let state = makeState(flags: ["max": .value(.int(10))])
        #expect(state.value(of: ValueFlag<Int>("max", default: 5)) == 10)
    }

    @Test("value local override beats remote")
    func valueOverride() {
        let state = makeState(flags: ["max": .value(.int(10))], overrides: ["max": .int(99)])
        #expect(state.value(of: ValueFlag<Int>("max", default: 5)) == 99)
    }
}
```

**Step 2: Run, expect fail**

Run: `swift test --filter SwiduxFeatureFlagsTests.FeatureFlagsState_read`
(Filter syntax may differ; if so, use `swift test --filter "FeatureFlagsState read API"` or just run the full suite.)
Expected: FAIL — read methods undefined.

**Step 3: Implement read API**

Append to `Sources/SwiduxFeatureFlags/FeatureFlagsState.swift`:

```swift
// MARK: - Read API

extension FeatureFlagsState {
    /// Reads a boolean flag. Evaluation order:
    /// 1. Local override (if any),
    /// 2. Remote config (rollout bucketing against `bucketingID`),
    /// 3. Swift-side `default`.
    public func isEnabled(
        _ flag: BoolFlag,
        bucketingID: String? = nil,
        default defaultValue: Bool = false
    ) -> Bool {
        if case .bool(let v) = localOverrides[flag.key] { return v }
        guard case .boolean(let rollout) = config.flags[flag.key] else {
            return defaultValue
        }
        if rollout >= 100 { return true }
        if rollout <= 0 { return false }
        let id = bucketingID ?? installID.uuidString
        return Bucketing.bucket(id: id, flagKey: flag.key) < rollout
    }

    /// Reads a variant flag.
    public func variant<Variant>(
        of flag: VariantFlag<Variant>,
        bucketingID: String? = nil
    ) -> Variant where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
        // Local override wins.
        if case .string(let raw) = localOverrides[flag.key],
           let parsed = Variant(rawValue: raw) {
            return parsed
        }
        guard case .variant(let variants) = config.flags[flag.key], !variants.isEmpty else {
            return flag.defaultValue
        }
        let id = bucketingID ?? installID.uuidString
        let bucket = Bucketing.bucket(id: id, flagKey: flag.key)
        let index = Bucketing.variantIndex(bucket: bucket, weights: variants.map(\.weight))
        return Variant(rawValue: variants[index].value) ?? flag.defaultValue
    }

    /// Reads a value flag (`Bool`).
    public func value(of flag: ValueFlag<Bool>) -> Bool {
        if case .bool(let v) = localOverrides[flag.key] { return v }
        if case .value(.bool(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }

    /// Reads a value flag (`Int`).
    public func value(of flag: ValueFlag<Int>) -> Int {
        if case .int(let v) = localOverrides[flag.key] { return v }
        if case .value(.int(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }

    /// Reads a value flag (`Double`).
    public func value(of flag: ValueFlag<Double>) -> Double {
        if case .double(let v) = localOverrides[flag.key] { return v }
        if case .value(.double(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }

    /// Reads a value flag (`String`).
    public func value(of flag: ValueFlag<String>) -> String {
        if case .string(let v) = localOverrides[flag.key] { return v }
        if case .value(.string(let v)) = config.flags[flag.key] { return v }
        return flag.defaultValue
    }
}
```

**Step 4: Run, expect pass**

Run: `swift test`
Expected: PASS (all FeatureFlags tests).

**Step 5: Commit**

```bash
git add Sources/SwiduxFeatureFlags/FeatureFlagsState.swift Tests/SwiduxFeatureFlagsTests/FeatureFlagsReadTests.swift
git commit -m "Add read API for boolean, variant, and value flags"
```

---

### Task 12: Implement `recordsExposure` view modifier

Small SwiftUI helper. Calls `store.send(.featureFlags(.recordExposure(key:)))` from `.onAppear`.

**Files:**
- Create: `Sources/SwiduxFeatureFlags/ExposureModifier.swift`

This task has no test (UI modifier, trivially correct). Verify by reading.

**Step 1: Implement the modifier**

Create `Sources/SwiduxFeatureFlags/ExposureModifier.swift`:

```swift
//
//  ExposureModifier.swift
//  SwiduxFeatureFlags
//

import SwiftUI
import Swidux

extension View {
    /// Records an exposure for the given flag when this view appears.
    ///
    /// Sugar over dispatching `.featureFlags(.recordExposure(key:))`. The
    /// plugin dedupes per session, so it's safe to attach this modifier
    /// to any view that displays a treatment.
    ///
    /// ```swift
    /// if store.featureFlags.variant(of: .checkoutLayout) == .wizard {
    ///     WizardView()
    ///         .recordsExposure(of: .checkoutLayout, store: store)
    /// }
    /// ```
    public func recordsExposure<RootState, RootAction, Variant>(
        of flag: VariantFlag<Variant>,
        store: Store<RootState, RootAction>,
        action: @escaping (FeatureFlagsAction) -> RootAction
    ) -> some View where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
        self.onAppear {
            store.send(action(.recordExposure(key: flag.key)))
        }
    }

    /// Records an exposure for a boolean flag when this view appears.
    public func recordsExposure<RootState, RootAction>(
        of flag: BoolFlag,
        store: Store<RootState, RootAction>,
        action: @escaping (FeatureFlagsAction) -> RootAction
    ) -> some View {
        self.onAppear {
            store.send(action(.recordExposure(key: flag.key)))
        }
    }
}
```

**Note:** The `action:` parameter is the host's action lifter (e.g. `AppAction.featureFlags`). This keeps the modifier independent of the host's action enum without a typealias.

**Step 2: Verify it builds**

Run: `swift build --target SwiduxFeatureFlags`
Expected: builds clean.

**Step 3: Commit**

```bash
git add Sources/SwiduxFeatureFlags/ExposureModifier.swift
git commit -m "Add .recordsExposure SwiftUI view modifier"
```

---

### Task 13: DocC catalog

Mirror `Sources/SwiduxAnalytics/Documentation.docc/` shape — root catalog file plus articles.

**Files:**
- Create: `Sources/SwiduxFeatureFlags/Documentation.docc/SwiduxFeatureFlags.md`
- Create: `Sources/SwiduxFeatureFlags/Documentation.docc/WiringFeatureFlags.md`
- Create: `Sources/SwiduxFeatureFlags/Documentation.docc/WireFormatReference.md`
- Create: `Sources/SwiduxFeatureFlags/Documentation.docc/BucketingAndIdentity.md`
- Create: `Sources/SwiduxFeatureFlags/Documentation.docc/ExposureTracking.md`

**Step 1: Inspect the existing analytics catalog**

Run: `ls Sources/SwiduxAnalytics/Documentation.docc/`. Read one of the articles to copy the structure and front-matter conventions.

**Step 2: Write the four articles**

Each article should be 100–250 words, code-example-driven, written in the same voice as the existing Swidux documentation. Topics:

- **`SwiduxFeatureFlags.md`** — package overview, when to use it, table of contents.
- **`WiringFeatureFlags.md`** — full wiring example: state slice, action enum case, plugin registration, hydration, scenePhase refresh trigger.
- **`WireFormatReference.md`** — full JSON schema with all three flag types, example file, hosting recommendations.
- **`BucketingAndIdentity.md`** — install ID vs userID, FNV-1a, stable-bucket guarantee, what changes at login.
- **`ExposureTracking.md`** — when to record exposure, action vs view modifier, wiring to AnalyticsPlugin.

**Step 3: Build docs to verify**

Run: `swift package generate-documentation --target SwiduxFeatureFlags`
Expected: builds without warnings about missing symbols.

**Step 4: Commit**

```bash
git add Sources/SwiduxFeatureFlags/Documentation.docc
git commit -m "Add DocC catalog for SwiduxFeatureFlags"
```

---

### Task 14: Update swidux-ref skill

Add a "feature flags" entry to the "When to use what" table and a code template to `swidux-patterns.md`.

**Files:**
- Modify: `.agent/skills/swidux-ref/SKILL.md`
- Modify: `.agent/skills/swidux-ref/swidux-patterns.md`

**Step 1: Add table row**

In `SKILL.md`, in the "When to use what" table, add a row after the Paywall row:

```markdown
| Add feature flags / A/B variants / remote config | Wire `FeatureFlagsPlugin`; declare typed flags via `BoolFlag` / `VariantFlag` / `ValueFlag`; read with `store.featureFlags.isEnabled(.myFlag)` |
```

**Step 2: Append a wiring template to `swidux-patterns.md`**

Add a new section "FeatureFlagsPlugin wiring" with a copy-pasteable example showing:
1. State slice (`@Slice var featureFlags`).
2. Action case (`case featureFlags(FeatureFlagsAction)`).
3. Plugin registration with all parameters.
4. Typed flag-key declaration.
5. Read at a call site.
6. Exposure tracking.

**Step 3: Commit**

```bash
git add .agent/skills/swidux-ref
git commit -m "Update swidux-ref with FeatureFlagsPlugin entry"
```

---

### Task 15: Counter example app — feature-flags demo screen

Wire the plugin into `Examples/Counter` with a small demo screen showing all three flag types. Uses a static JSON shipped in the bundle (no network).

**Files:**
- Modify: `Examples/Counter/Counter/AppState.swift`
- Modify: `Examples/Counter/Counter/AppAction.swift`
- Modify: `Examples/Counter/Counter/AppStore.swift`
- Create: `Examples/Counter/Counter/FeatureFlagsView.swift`
- Create: `Examples/Counter/Counter/Resources/feature-flags.json`

**Step 1: Inspect the example app**

Run: `ls Examples/Counter/Counter/`. Read `AppState.swift`, `AppStore.swift` to understand the wiring.

**Step 2: Add the slice**

In `AppState.swift`, add `@Slice var featureFlags: FeatureFlagsState = .init()`.

In `AppAction.swift`, add `case featureFlags(FeatureFlagsAction)`.

**Step 3: Wire the plugin**

In `AppStore.swift`'s `configured` extension, register `FeatureFlagsPlugin` with a `BundledFeatureFlagsService` (a tiny test-only service that loads the JSON from the bundle):

```swift
struct BundledFeatureFlagsService: FeatureFlagsService {
    let bundle: Bundle
    let resourceName: String

    func fetch() async throws -> FeatureFlagsConfig {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw URLError(.fileDoesNotExist)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FeatureFlagsConfig.self, from: data)
    }
}
```

**Step 4: Bundle the JSON**

Create `Examples/Counter/Counter/Resources/feature-flags.json` with all three flag types.

**Step 5: Build the demo view**

Create `FeatureFlagsView.swift` showing:
- A boolean flag rendered as a Toggle (read-only display).
- A variant flag rendered as a Picker (read-only display).
- A value flag rendered as a stepper-style read-only display.
- A "Refresh" button that dispatches `.featureFlags(.refresh)`.
- A debug section listing local overrides with toggle controls.

**Step 6: Verify the example builds and runs**

Open the Counter Xcode project and build. Run on simulator and confirm the screen renders as expected.

**Step 7: Commit**

```bash
git add Examples/Counter
git commit -m "Add feature-flags demo screen to Counter example"
```

---

### Task 16: Final verification

**Step 1: Run the full test suite**

Run: `swift test`
Expected: ALL tests pass across every target.

**Step 2: Run `swift build` for all targets**

Run: `swift build`
Expected: clean build, no warnings.

**Step 3: Inspect git log**

Run: `git log --oneline origin/main..HEAD`
Expected: a clean sequence of feature-scoped commits, one per task.

**Step 4: Bring the design and implementation docs into sync if anything drifted**

If implementation choices diverged from the design doc, add a short "Implementation notes" section at the bottom of `docs/plans/2026-05-10-feature-flags-design.md` covering the divergences and the reasoning. Commit that.

```bash
git add docs/plans/2026-05-10-feature-flags-design.md
git commit -m "Note design/implementation divergences"
```

**Step 5: Push branch and open PR**

Only if explicitly asked — do not push without confirmation.

---

## Checklist for the executor

Before claiming done:

- [ ] Every task's tests pass.
- [ ] `swift build` is clean across all targets.
- [ ] DocC builds without missing-symbol warnings.
- [ ] Counter example runs and demo screen renders all three flag types.
- [ ] No `TODO` / `FIXME` / `print` / `assertionFailure` left in production code.
- [ ] No file touches `UserDefaults.standard` directly — must go through `KeyValueStore`.
- [ ] No reducer arm calls `await` or `try`; all I/O is in effects.
- [ ] No hand-written `@Observable` companion classes — every state slice uses `@Swidux` / `@Slice`.

//
//  FlagExposure.swift
//  SwiduxFeatureFlags
//

/// A typed request to record that the user was shown a flag's value.
///
/// Build one with a `FeatureFlagsAction.recordExposure(of:)` factory. It
/// carries the flag's Swift type so ``FeatureFlagsPlugin`` evaluates the
/// exposure through the same path as the read: an override the read
/// ignores is ignored here too, a remote variant the app's enum can't parse
/// records nothing, and an explicit `bucketingID` buckets the same way.
public struct FlagExposure: Sendable, Equatable {
    /// Evaluates a flag against `(config, localOverrides, bucketingID)`.
    typealias Evaluation = @Sendable (FeatureFlagsConfig, [String: FlagValue], String) -> FlagValue?

    /// Wire-format key of the exposed flag.
    public let key: String

    /// The bucketing identity the read used, or `nil` for the plugin's
    /// default identity.
    public let bucketingID: String?

    /// The typed flag key's type. With `key`, it fully determines `evaluate`,
    /// which is why equality can ignore the closure.
    private let flagType: ObjectIdentifier

    /// The read path, rendered as a ``FlagValue``. `nil` when the read falls
    /// back to the Swift-side default, i.e. the flag isn't in the config or
    /// its remote value doesn't fit the flag's type.
    let evaluate: Evaluation

    init<Flag>(
        key: String,
        bucketingID: String?,
        flagType: Flag.Type,
        evaluate: @escaping Evaluation
    ) {
        self.key = key
        self.bucketingID = bucketingID
        self.flagType = ObjectIdentifier(flagType)
        self.evaluate = evaluate
    }

    /// Two exposures are equal when they name the same key, flag type, and
    /// bucketing identity — and so evaluate identically.
    public static func == (lhs: FlagExposure, rhs: FlagExposure) -> Bool {
        lhs.key == rhs.key && lhs.bucketingID == rhs.bucketingID && lhs.flagType == rhs.flagType
    }
}

extension FeatureFlagsAction {
    /// Records that the user was shown a boolean flag's value.
    ///
    /// Pass the same `bucketingID` the read used, if any.
    public static func recordExposure(
        of flag: BoolFlag,
        bucketingID: String? = nil
    ) -> FeatureFlagsAction {
        .recordFlagExposure(
            FlagExposure(key: flag.key, bucketingID: bucketingID, flagType: BoolFlag.self) {
                config, overrides, id in
                FlagEvaluator.isEnabled(flag, config: config, localOverrides: overrides, bucketingID: id)
                    .map(FlagValue.bool)
            }
        )
    }

    /// Records that the user was shown a variant flag's value.
    ///
    /// Pass the same `bucketingID` the read used, if any. Records nothing
    /// when the read fell back to the flag's default because the flag is
    /// missing or its remote variant isn't one `Variant` can parse: the user
    /// was assigned an arm they weren't shown, so counting them in either
    /// arm would skew the experiment.
    public static func recordExposure<Variant>(
        of flag: VariantFlag<Variant>,
        bucketingID: String? = nil
    ) -> FeatureFlagsAction where Variant: RawRepresentable & Sendable, Variant.RawValue == String {
        .recordFlagExposure(
            FlagExposure(key: flag.key, bucketingID: bucketingID, flagType: VariantFlag<Variant>.self) {
                config, overrides, id in
                FlagEvaluator.variant(of: flag, config: config, localOverrides: overrides, bucketingID: id)
                    .map { .string($0.rawValue) }
            }
        )
    }

    /// Records that the user was shown a `Bool` value flag's value.
    public static func recordExposure(of flag: ValueFlag<Bool>) -> FeatureFlagsAction {
        .recordFlagExposure(
            FlagExposure(key: flag.key, bucketingID: nil, flagType: ValueFlag<Bool>.self) {
                config, overrides, _ in
                FlagEvaluator.value(of: flag, config: config, localOverrides: overrides).map(FlagValue.bool)
            }
        )
    }

    /// Records that the user was shown an `Int` value flag's value.
    public static func recordExposure(of flag: ValueFlag<Int>) -> FeatureFlagsAction {
        .recordFlagExposure(
            FlagExposure(key: flag.key, bucketingID: nil, flagType: ValueFlag<Int>.self) {
                config, overrides, _ in
                FlagEvaluator.value(of: flag, config: config, localOverrides: overrides).map(FlagValue.int)
            }
        )
    }

    /// Records that the user was shown a `Double` value flag's value.
    public static func recordExposure(of flag: ValueFlag<Double>) -> FeatureFlagsAction {
        .recordFlagExposure(
            FlagExposure(key: flag.key, bucketingID: nil, flagType: ValueFlag<Double>.self) {
                config, overrides, _ in
                FlagEvaluator.value(of: flag, config: config, localOverrides: overrides).map(FlagValue.double)
            }
        )
    }

    /// Records that the user was shown a `String` value flag's value.
    public static func recordExposure(of flag: ValueFlag<String>) -> FeatureFlagsAction {
        .recordFlagExposure(
            FlagExposure(key: flag.key, bucketingID: nil, flagType: ValueFlag<String>.self) {
                config, overrides, _ in
                FlagEvaluator.value(of: flag, config: config, localOverrides: overrides).map(FlagValue.string)
            }
        )
    }
}

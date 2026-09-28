//
//  MockFeatureFlagsService.swift
//  SwiduxFeatureFlagsTests
//

import Foundation

@testable import SwiduxFeatureFlags

/// A custom service whose fetch never returns and ignores cancellation, like
/// an SDK call against an endpoint that never answers.
actor HangingFeatureFlagsService: FeatureFlagsService {
    /// Held, never resumed — dropping them would trip the leak checker.
    private var parked: [CheckedContinuation<Void, Never>] = []

    func fetch() async throws -> FeatureFlagsConfig {
        await withCheckedContinuation { parked.append($0) }
        return .empty
    }
}

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

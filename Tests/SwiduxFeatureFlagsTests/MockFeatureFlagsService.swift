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

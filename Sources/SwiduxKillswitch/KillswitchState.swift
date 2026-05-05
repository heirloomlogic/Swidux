//
//  KillswitchState.swift
//  SwiduxKillswitch
//
//  Observable state for the killswitch feature.
//

import Foundation

/// The killswitch feature's state slice.
public struct KillswitchState: Sendable, Equatable {
    /// Latest evaluated verdict; defaults to `.unknown`.
    public var verdict: KillswitchVerdict
    /// Timestamp of the last successful fetch, or `nil`.
    public var lastFetch: Date?
    /// Human-readable description of the last fetch failure, or `nil`.
    public var fetchError: String?

    /// Creates a killswitch state with default values.
    public init(
        verdict: KillswitchVerdict = .unknown,
        lastFetch: Date? = nil,
        fetchError: String? = nil
    ) {
        self.verdict = verdict
        self.lastFetch = lastFetch
        self.fetchError = fetchError
    }
}

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

    /// `true` when the verdict is `.blocked`.
    public var isBlocked: Bool {
        if case .blocked = verdict { return true }
        return false
    }

    /// `true` when the verdict is `.blocked` and includes an update URL.
    public var canOpenUpdateURL: Bool {
        if case .blocked(_, _, let url) = verdict { return url != nil }
        return false
    }

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

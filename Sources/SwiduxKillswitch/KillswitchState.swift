//
//  KillswitchState.swift
//  SwiduxKillswitch
//
//  Observable state for the killswitch feature.
//

import Foundation
import Swidux

/// The killswitch feature's state slice.
///
/// Hosted in the app's root state via `@Slice var killswitch: KillswitchState`.
@Swidux
public nonisolated struct KillswitchState: Sendable, Equatable {
    /// Latest evaluated verdict; defaults to `.unknown`.
    public var verdict: KillswitchVerdict = .unknown
    /// Timestamp of the last successful fetch, or `nil`.
    public var lastFetch: Date? = nil
    /// Human-readable description of the last fetch failure, or `nil`.
    public var fetchError: String? = nil
    /// `true` while a network fetch is in flight.
    ///
    /// A `.fetch` or `.forceFetch` dispatched meanwhile is dropped, so two
    /// requests can't overlap and apply in completion order rather than issue
    /// order, with a slow, stale answer overwriting a newer verdict and its
    /// cache. Cleared by the fetch's own outcome:
    /// `.verdictReceived(_, fromNetwork: true)` or `.fetchFailed`.
    public var isFetching: Bool = false

    /// `true` when the verdict is `.blocked`.
    public var isBlocked: Bool { verdict.isBlocked }

    /// `true` when the verdict is `.blocked` and includes an update URL with
    /// an openable scheme (`https`, `itms-apps`, `macappstore`).
    public var canOpenUpdateURL: Bool {
        verdict.openableUpdateURL != nil
    }

    /// Creates a killswitch state with default values.
    public init(
        verdict: KillswitchVerdict = .unknown,
        lastFetch: Date? = nil,
        fetchError: String? = nil,
        isFetching: Bool = false
    ) {
        self.verdict = verdict
        self.lastFetch = lastFetch
        self.fetchError = fetchError
        self.isFetching = isFetching
    }
}

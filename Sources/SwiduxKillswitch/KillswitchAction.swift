//
//  KillswitchAction.swift
//  SwiduxKillswitch
//
//  Actions for the killswitch feature.
//

/// Actions that drive the killswitch feature.
public enum KillswitchAction: Sendable {
    /// Fetch config, using cache when fresh.
    case fetch
    /// Fetch config from the network, bypassing the cache freshness check.
    case forceFetch
    /// A verdict was received from evaluating fetched config.
    case verdictReceived(KillswitchVerdict)
    /// The fetch failed with an error message.
    case fetchFailed(String)
    /// Open the update URL from the current blocked verdict.
    case openUpdateURL
}

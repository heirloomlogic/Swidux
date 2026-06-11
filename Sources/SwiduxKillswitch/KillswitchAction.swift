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
    ///
    /// `fromNetwork` is `true` only when the config came from a live fetch —
    /// cache-served verdicts must not refresh the freshness window, or a
    /// session that polls `.fetch` more often than `cacheLifetime` would
    /// never consult the network again.
    case verdictReceived(KillswitchVerdict, fromNetwork: Bool)
    /// The fetch failed with an error message.
    case fetchFailed(String)
    /// Open the update URL from the current blocked verdict.
    case openUpdateURL
}

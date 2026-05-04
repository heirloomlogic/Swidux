//
//  KillswitchAction.swift
//  SwiduxKillswitch
//
//  Actions for the killswitch feature.
//

/// Actions that drive the killswitch feature.
public enum KillswitchAction: Sendable {
    /// Trigger a remote config fetch.
    case fetch
    /// A verdict was received from evaluating fetched config.
    case verdictReceived(KillswitchVerdict)
    /// The fetch failed with an error message.
    case fetchFailed(String)
    /// Open the update URL from the current blocked verdict.
    case openUpdateURL
}

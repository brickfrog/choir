///|
pub(all) enum NetworkProtocol {
  NetworkDns
  NetworkTcp
  NetworkUdp
  NetworkQuic
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NetworkTarget {
  protocol : NetworkProtocol
  host : String
  port : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxNetworkProfile {
  NetworkDisabled
  NetworkAllowlisted(Array[NetworkTarget])
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum NetworkPolicyBlockReason {
  NetworkEnabledProfileNotAdmitted
  EmptyAllowlistIsNotDenyAll
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum InitialNetworkDecision {
  InitialNetworkAccepted
  InitialNetworkRejected(NetworkPolicyBlockReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn evaluate_initial_network_profile(
  profile : SandboxNetworkProfile,
) -> InitialNetworkDecision {
  match profile {
    NetworkDisabled => InitialNetworkAccepted
    NetworkAllowlisted(targets) =>
      if targets.length() == 0 {
        InitialNetworkRejected(EmptyAllowlistIsNotDenyAll)
      } else {
        InitialNetworkRejected(NetworkEnabledProfileNotAdmitted)
      }
  }
}

///|
pub fn validate_initial_network_profile(
  profile : SandboxNetworkProfile,
) -> Result[Unit, @types.ChoirError] {
  match evaluate_initial_network_profile(profile) {
    InitialNetworkAccepted => Ok(())
    InitialNetworkRejected(EmptyAllowlistIsNotDenyAll) =>
      Err(
        @types.ChoirError::policy_blocked(
          "empty sandbox allowlist is not a deny-all network policy",
        ),
      )
    InitialNetworkRejected(NetworkEnabledProfileNotAdmitted) =>
      Err(
        @types.ChoirError::policy_blocked(
          "network-enabled sandbox profiles are not admitted by the initial adapter",
        ),
      )
  }
}

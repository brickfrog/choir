///|
test "initial network profile accepts only explicit disabled" {
  assert_eq(
    @sandbox.evaluate_initial_network_profile(
      @sandbox.SandboxNetworkProfile::NetworkDisabled,
    ),
    @sandbox.InitialNetworkDecision::InitialNetworkAccepted,
  )
  assert_eq(
    @sandbox.evaluate_initial_network_profile(
      @sandbox.SandboxNetworkProfile::NetworkAllowlisted([]),
    ),
    @sandbox.InitialNetworkDecision::InitialNetworkRejected(
      @sandbox.NetworkPolicyBlockReason::EmptyAllowlistIsNotDenyAll,
    ),
  )
}

///|
test "nonempty allowlist remains blocked pending full protocol oracle" {
  let target : @sandbox.NetworkTarget = {
    protocol: @sandbox.NetworkProtocol::NetworkTcp,
    host: "example.com",
    port: 443,
  }
  assert_eq(
    @sandbox.evaluate_initial_network_profile(
      @sandbox.SandboxNetworkProfile::NetworkAllowlisted([target]),
    ),
    @sandbox.InitialNetworkDecision::InitialNetworkRejected(
      @sandbox.NetworkPolicyBlockReason::NetworkEnabledProfileNotAdmitted,
    ),
  )
}

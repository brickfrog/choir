///|
test "Codex network trace accepts provider transport without canary access" {
  let trace =
    #|100 connect(3, {sa_family=AF_UNIX, sun_path="/run/nscd/socket"}, 110) = -1 ENOENT
    #|101 connect(4, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("10.0.0.1")}, 16) = 0
    #|101 connect(5, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("203.0.113.1")}, 16) = -1 EINPROGRESS
    #|101 connect(5, {sa_family=AF_INET, sin_port=htons(0), sin_addr=inet_addr("203.0.113.1")}, 16) = 0
    #|
  let summary = @harness.evaluate_provider_network_trace(trace, 23991).unwrap()
  assert_eq(summary.provider_connections, 1)
  assert_eq(summary.address_selection_probes, 1)
  assert_eq(summary.dns_connections, 1)
  assert_eq(summary.unix_connections, 1)
  assert_true(@harness.provider_network_trace_passed(summary))
}

///|
test "Codex network trace rejects canary and undeclared transports" {
  let trace =
    #|100 connect(3, {sa_family=AF_INET, sin_port=htons(23991), sin_addr=inet_addr("127.0.0.1")}, 16) = -1 ECONNREFUSED
    #|100 connect(4, {sa_family=AF_INET6, sin6_port=htons(80), inet_pton(AF_INET6, "2001:db8::1", &sin6_addr)}, 28) = -1 EINPROGRESS
    #|
  let summary = @harness.evaluate_provider_network_trace(trace, 23991).unwrap()
  assert_eq(summary.canary_connections, 1)
  assert_eq(summary.other_inet_connections, 1)
  assert_false(@harness.provider_network_trace_passed(summary))
}

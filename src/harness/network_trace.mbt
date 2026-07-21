///|
pub(all) struct ProviderNetworkTraceSummary {
  provider_connections : Int
  address_selection_probes : Int
  dns_connections : Int
  unix_connections : Int
  canary_connections : Int
  other_inet_connections : Int
} derive(Debug, Eq, ToJson)

///|
pub fn evaluate_provider_network_trace(
  trace : String,
  canary_port : Int,
) -> Result[ProviderNetworkTraceSummary, @types.ChoirError] {
  if canary_port < 1024 || canary_port > 65535 {
    return Err(
      @types.ChoirError::validation_error(
        "provider network canary port is invalid",
      ),
    )
  }
  let mut provider_connections = 0
  let mut address_selection_probes = 0
  let mut dns_connections = 0
  let mut unix_connections = 0
  let mut canary_connections = 0
  let mut other_inet_connections = 0
  let port = "sin_port=htons(" + canary_port.to_string() + ")"
  let port6 = "sin6_port=htons(" + canary_port.to_string() + ")"
  for line in trace.split("\n") {
    if !line.contains("connect(") {
      continue
    }
    if line.contains("AF_UNIX") {
      unix_connections = unix_connections + 1
    } else if line.contains("AF_INET") || line.contains("AF_INET6") {
      if (line.contains(port) || line.contains(port6)) &&
        (line.contains("127.0.0.1") || line.contains("::1")) {
        canary_connections = canary_connections + 1
      } else if line.contains("sin_port=htons(443)") ||
        line.contains("sin6_port=htons(443)") {
        provider_connections = provider_connections + 1
      } else if line.contains("sin_port=htons(53)") ||
        line.contains("sin6_port=htons(53)") {
        dns_connections = dns_connections + 1
      } else if line.contains("htons(0)") || line.contains("htons(65535)") {
        address_selection_probes = address_selection_probes + 1
      } else {
        other_inet_connections = other_inet_connections + 1
      }
    }
  }
  Ok({
    provider_connections,
    address_selection_probes,
    dns_connections,
    unix_connections,
    canary_connections,
    other_inet_connections,
  })
}

///|
pub fn provider_network_trace_passed(
  summary : ProviderNetworkTraceSummary,
) -> Bool {
  summary.provider_connections > 0 &&
  summary.canary_connections == 0 &&
  summary.other_inet_connections == 0
}

///|
fn usage_int(fields : Map[String, Json], name : String) -> Int {
  match fields.get(name) {
    Some(Number(value, ..)) if value >= 0 => value.to_int()
    _ => 0
  }
}

///|
/// Read what a Claude `result` event reported consuming. Absent or negative
/// counts stay zero: an unreported figure is not an estimated one.
pub fn claude_result_usage(fields : Map[String, Json]) -> @control.TakeUsage? {
  let wall_time_ms = usage_int(fields, "duration_ms")
  guard fields.get("usage") is Some(Object(usage)) else {
    if wall_time_ms > 0 {
      return Some({ ..@control.empty_take_usage(), wall_time_ms, })
    }
    return None
  }
  Some({
    input_tokens: usage_int(usage, "input_tokens"),
    output_tokens: usage_int(usage, "output_tokens"),
    cache_read_tokens: usage_int(usage, "cache_read_input_tokens"),
    cache_creation_tokens: usage_int(usage, "cache_creation_input_tokens"),
    wall_time_ms,
  })
}

///|
fn allowance_instant(fields : Map[String, Json], name : String) -> Int64? {
  match fields.get(name) {
    Some(Number(value, ..)) if value > 0 => Some(value.to_int64())
    _ => None
  }
}

///|
/// Read what a Claude `system` / `api_error` frame reported about the
/// allowance. The shape comes from Claude Code's own wire schema for that
/// frame: `error.rate_limits` is described there as the quota-429 headers, and
/// is null whenever the failure was not a quota 429 — so an absent block means
/// this failure said nothing about the allowance, not that it is intact.
///
/// `resets_at` is epoch seconds; `retry_in_ms` is a delay in milliseconds and
/// is reported in seconds here so the caller resolves it against one clock.
pub fn claude_api_error_allowance(
  fields : Map[String, Json],
) -> @types.ProviderAllowanceObservation? {
  guard fields.get("subtype") is Some(String("api_error")) else { return None }
  let retry_after_seconds = match fields.get("retry_in_ms") {
    Some(Number(value, ..)) if value >= 1000 => Some(value.to_int64() / 1000L)
    _ => None
  }
  let reset_at = match fields.get("error") {
    Some(Object(error)) =>
      match error.get("rate_limits") {
        Some(Object(limits)) => allowance_instant(limits, "resets_at")
        _ => None
      }
    _ => None
  }
  if reset_at is None && retry_after_seconds is None {
    return None
  }
  Some({ reset_at, retry_after_seconds })
}

///|
/// Read what a Codex `account/rateLimits/updated` notification reported, but
/// only once the surface has said its limit is actually reached.
///
/// The app-server sends this notification routinely with a healthy window — a
/// live read against a 20%-used account still carries a `resetsAt` — so the
/// presence of a reset is not evidence of exhaustion. `rateLimitReachedType`
/// is the surface's own statement that it is spent, and every variant of it
/// (rate limit, usage limit, depleted credits) means the same thing here.
///
/// The snapshot is sparse by protocol contract, so a window that reported no
/// reset contributes nothing rather than a zero. `primary` is the window the
/// surface is limited by; `secondary` is the longer window and only answers
/// when the primary said nothing.
pub fn codex_rate_limit_allowance(
  params : Map[String, Json],
) -> @types.ProviderAllowanceObservation? {
  guard params.get("rateLimits") is Some(Object(limits)) else { return None }
  guard limits.get("rateLimitReachedType") is Some(String(_)) else {
    return None
  }
  let window = fn(name : String) -> Int64? {
    match limits.get(name) {
      Some(Object(fields)) => allowance_instant(fields, "resetsAt")
      _ => None
    }
  }
  let reset_at = match window("primary") {
    Some(instant) => Some(instant)
    None => window("secondary")
  }
  guard reset_at is Some(_) else { return None }
  // The app-server reports an absolute instant and no retry delay.
  Some({ reset_at, retry_after_seconds: None })
}

///|
/// Read what a Codex `thread/tokenUsage/updated` notification reported for this
/// turn. The field names come from the app-server protocol's own generated
/// schema (`TokenUsageBreakdown`), not from guesswork: `cachedInputTokens`,
/// `inputTokens`, `outputTokens`, `reasoningOutputTokens`, `totalTokens`, and
/// the defaulted `cacheWriteInputTokens`.
///
/// The `last` breakdown is this turn; `total` is the whole thread, which would
/// double count across turns.
pub fn codex_turn_usage(params : Map[String, Json]) -> @control.TakeUsage? {
  guard params.get("tokenUsage") is Some(Object(token_usage)) else {
    return None
  }
  guard token_usage.get("last") is Some(Object(last)) else { return None }
  Some({
    input_tokens: usage_int(last, "inputTokens"),
    // Codex reports reasoning output separately from the visible output; both
    // are output the allowance was spent on.
    output_tokens: usage_int(last, "outputTokens") +
    usage_int(last, "reasoningOutputTokens"),
    cache_read_tokens: usage_int(last, "cachedInputTokens"),
    cache_creation_tokens: usage_int(last, "cacheWriteInputTokens"),
    wall_time_ms: 0,
  })
}

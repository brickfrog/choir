///|
/// Provider output is untrusted text that may carry a session id, a token, or
/// a path. Classification needs a few words of it; durable state must not
/// retain the rest. This keeps a bounded, single-line excerpt with anything
/// that looks like a secret or an absolute path removed.
pub fn redact_provider_excerpt(output : String) -> String {
  let kept = StringBuilder::new()
  let mut length = 0
  for token in provider_excerpt_tokens(output) {
    if length >= 160 {
      break
    }
    if provider_token_is_sensitive(token) {
      continue
    }
    if length > 0 {
      kept.write_string(" ")
      length = length + 1
    }
    kept.write_string(token)
    length = length + token.length()
  }
  kept.to_string()
}

///|
fn provider_excerpt_tokens(output : String) -> Array[String] {
  let tokens : Array[String] = []
  for line in output.split("\n") {
    for raw in line.to_owned().split(" ") {
      let token = raw.trim().to_owned()
      if token != "" {
        tokens.push(token)
      }
    }
  }
  tokens
}

///|
/// A token is dropped when it could carry an identifier rather than describe a
/// condition: absolute paths, URLs, anything key-shaped, and any long opaque
/// run of characters.
fn provider_token_is_sensitive(token : String) -> Bool {
  token.has_prefix("/") ||
  token.has_prefix("~") ||
  token.contains("://") ||
  token.contains("@") ||
  token.contains("=") ||
  token.length() > 24
}

///|
/// Classify what a provider surface reported. Only an explicit statement
/// counts: an unrecognized failure stays `ProviderUnavailable` rather than
/// being guessed into an allowance state that would defer work indefinitely.
pub fn classify_provider_availability(
  exit_code : Int,
  output : String,
  reset_at? : Int64? = None,
  retry_after_seconds? : Int64? = None,
  now? : Int64 = 0L,
) -> @control.ProviderAvailability {
  if exit_code == 0 {
    return @control.ProviderAvailability::ProviderAvailable
  }
  let lowered = output.to_lower()
  if provider_output_reports_allowance(lowered) {
    return @control.ProviderAvailability::ProviderAllowanceExhausted(reset_at)
  }
  match retry_after_seconds {
    Some(seconds) if seconds > 0L && now > 0L =>
      return @control.ProviderAvailability::ProviderRetryAfter(now + seconds)
    _ => ()
  }
  @control.ProviderAvailability::ProviderUnavailable
}

///|
fn provider_output_reports_allowance(lowered : String) -> Bool {
  lowered.contains("usage limit") ||
  lowered.contains("rate limit") ||
  lowered.contains("quota exceeded") ||
  lowered.contains("out of credit") ||
  lowered.contains("insufficient_quota") ||
  lowered.contains("too many requests")
}

///|
test "provider classification names an exhausted allowance, never guesses one" {
  assert_eq(
    classify_provider_availability(0, "ok"),
    @control.ProviderAvailability::ProviderAvailable,
  )
  // An unrecognized failure is unavailable, not an invented allowance state.
  assert_eq(
    classify_provider_availability(1, "segmentation fault"),
    @control.ProviderAvailability::ProviderUnavailable,
  )
  assert_eq(
    classify_provider_availability(1, "Claude usage limit reached"),
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  // Trusted reset evidence is retained when the provider supplied it.
  assert_eq(
    classify_provider_availability(
      1,
      "Rate limit exceeded",
      reset_at=Some(5_000L),
    ),
    @control.ProviderAvailability::ProviderAllowanceExhausted(Some(5_000L)),
  )
  // A retry-after is resolved to an absolute instant against the clock.
  assert_eq(
    classify_provider_availability(
      1,
      "service unavailable",
      retry_after_seconds=Some(30L),
      now=1_000L,
    ),
    @control.ProviderAvailability::ProviderRetryAfter(1_030L),
  )
  // Allowance evidence wins over a retry hint: it names the actual condition.
  assert_eq(
    classify_provider_availability(
      1,
      "too many requests",
      retry_after_seconds=Some(30L),
      now=1_000L,
    ),
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
}

///|
test "deferral waits only on trusted reset evidence" {
  let admits = fn(availability, now) {
    @control.provider_availability_admits_dispatch(availability, now)
  }
  assert_true(admits(@control.ProviderAvailability::ProviderAvailable, 10L))
  // An unavailable surface retries under the ordinary bounded recovery path.
  assert_true(admits(@control.ProviderAvailability::ProviderUnavailable, 10L))
  // An exhausted allowance with no reset evidence is never given an invented
  // one: it waits rather than burning the next Take against a spent surface.
  assert_false(
    admits(@control.ProviderAvailability::ProviderAllowanceExhausted(None), 10L),
  )
  assert_false(
    admits(
      @control.ProviderAvailability::ProviderAllowanceExhausted(Some(100L)),
      99L,
    ),
  )
  assert_true(
    admits(
      @control.ProviderAvailability::ProviderAllowanceExhausted(Some(100L)),
      100L,
    ),
  )
  assert_false(
    admits(@control.ProviderAvailability::ProviderRetryAfter(100L), 99L),
  )
  assert_true(
    admits(@control.ProviderAvailability::ProviderRetryAfter(100L), 100L),
  )
}

///|
test "a retained excerpt describes the condition without carrying identifiers" {
  let excerpt = redact_provider_excerpt(
    "Error: usage limit reached for session sess_01HQ8XKZ9ABCDEFGHJKMNPQRST\n" +
    "see https://example.invalid/limits or /home/justin/.claude/creds.json\n" +
    "token=sk-ant-secret contact ops@example.invalid",
  )
  assert_true(excerpt.contains("usage limit reached"))
  assert_false(excerpt.contains("sess_01HQ8XKZ9ABCDEFGHJKMNPQRST"))
  assert_false(excerpt.contains("https://"))
  assert_false(excerpt.contains("/home/justin"))
  assert_false(excerpt.contains("sk-ant-secret"))
  assert_false(excerpt.contains("ops@example.invalid"))
  assert_true(excerpt.length() <= 200)
  // The excerpt still classifies, which is the only reason it is retained.
  assert_eq(
    classify_provider_availability(1, excerpt),
    @control.ProviderAvailability::ProviderAllowanceExhausted(None),
  )
}

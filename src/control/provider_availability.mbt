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
/// being guessed into an allowance state, which would make the Part wait on a
/// condition the surface never claimed instead of retrying under the ordinary
/// bounded recovery path.
pub fn classify_provider_availability(
  exit_code : Int,
  output : String,
  reset_at? : Int64? = None,
  retry_after_seconds? : Int64? = None,
  now? : Int64 = 0L,
) -> ProviderAvailability {
  if exit_code == 0 {
    return ProviderAvailability::ProviderAvailable
  }
  // A reset instant reaches here only from a surface that stated its allowance
  // is spent, so it names the condition on its own. That is stronger evidence
  // than matching words in untrusted output, and it is checked first so a
  // structured statement is not discarded because the failure text happened to
  // be phrased in words this classifier does not know.
  if reset_at is Some(_) {
    return ProviderAvailability::ProviderAllowanceExhausted(reset_at)
  }
  let lowered = output.to_lower()
  if provider_output_reports_allowance(lowered) {
    return ProviderAvailability::ProviderAllowanceExhausted(None)
  }
  match retry_after_seconds {
    Some(seconds) if seconds > 0L && now > 0L =>
      return ProviderAvailability::ProviderRetryAfter(now + seconds)
    _ => ()
  }
  ProviderAvailability::ProviderUnavailable
}

///|
/// How long a surface that reported a spent allowance and named no reset
/// instant stays deferred, and how that interval grows when the same surface
/// keeps reporting one.
///
/// The type exists so that the schedule cannot express "wait forever": every
/// bound is positive and the interval is capped, so a deferral always names an
/// instant at which the surface is re-checked. Fields are private; the only
/// way to obtain one is `provider_recheck_policy`, which rejects bounds that
/// would bound nothing.
pub struct ProviderRecheckPolicy {
  base_seconds : Int64
  growth : Int64
  ceiling_seconds : Int64
}

///|
fn provider_recheck_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("provider re-check policy: " + detail)
}

///|
/// Build a re-check schedule from validated bounds.
///
/// A non-positive first interval re-checks a spent surface immediately and
/// burns the recovery budget against it; a growth below one shrinks the
/// interval instead of backing off; a ceiling under the first interval is not
/// a ceiling. Each is rejected rather than silently corrected, because a
/// schedule nobody can read is how "bounded" quietly becomes "never".
pub fn provider_recheck_policy(
  base_seconds~ : Int64,
  growth~ : Int64,
  ceiling_seconds~ : Int64,
) -> Result[ProviderRecheckPolicy, @types.ChoirError] {
  if base_seconds <= 0L {
    return Err(provider_recheck_error("first interval is not positive"))
  }
  if growth < 1L {
    return Err(provider_recheck_error("growth would shrink the interval"))
  }
  if ceiling_seconds < base_seconds {
    return Err(provider_recheck_error("ceiling is below the first interval"))
  }
  Ok({ base_seconds, growth, ceiling_seconds })
}

///|
/// How long the `prior_deferrals + 1`-th consecutive deferral of one surface
/// waits. The growth is applied per prior deferral and clamped to the ceiling
/// before it can overflow, so the answer is always a finite number of seconds.
fn provider_recheck_interval_seconds(
  policy : ProviderRecheckPolicy,
  prior_deferrals : Int,
) -> Int64 {
  let mut seconds = policy.base_seconds
  let mut remaining = prior_deferrals
  while remaining > 0 {
    if seconds > policy.ceiling_seconds / policy.growth {
      return policy.ceiling_seconds
    }
    seconds = seconds * policy.growth
    remaining = remaining - 1
  }
  if seconds > policy.ceiling_seconds {
    policy.ceiling_seconds
  } else {
    seconds
  }
}

///|
/// The instant a surface that reported `availability` at `observed_at` may be
/// dispatched to again, or `None` when nothing is being waited for.
fn provider_availability_deferred_until(
  availability : ProviderAvailability,
  observed_at : Int64,
  prior_deferrals : Int,
  policy : ProviderRecheckPolicy,
) -> Int64? {
  match availability {
    ProviderAvailable | ProviderUnavailable => None
    ProviderAllowanceExhausted(Some(reset)) => Some(reset)
    // No reset evidence: still nothing is invented about when the allowance
    // returns, but the observation ages out on Choir's own schedule so the
    // surface is asked again rather than written off.
    ProviderAllowanceExhausted(None) =>
      Some(
        observed_at + provider_recheck_interval_seconds(policy, prior_deferrals),
      )
    ProviderRetryAfter(instant) => Some(instant)
  }
}

///|
/// Whether a surface may serve a new dispatch at this clock reading.
///
/// REVISION of the earlier rule, which admitted no dispatch at any clock
/// reading once a surface reported a spent allowance without naming a reset
/// instant. Refusing to invent an instant was right: Choir does not know when
/// the allowance returns, and pretending to would burn the next Take against a
/// spent surface. Concluding that the only alternative was waiting forever was
/// not — a Part that left a surface that way could never return to it, and a
/// Part whose every admitted surface answered that way was parked with nothing
/// scheduled to wake it.
///
/// So an allowance with no reset evidence is now deferred until `observed_at`
/// plus a capped interval that grows per consecutive deferral of that surface.
/// That interval still claims no knowledge of when the allowance resets; it
/// only declines to treat one observation as permanent. Trusted evidence is
/// unchanged and always wins: a reported reset instant and a retry-after defer
/// until exactly that instant.
pub fn provider_availability_admits_dispatch(
  availability : ProviderAvailability,
  observed_at~ : Int64,
  prior_deferrals~ : Int,
  policy~ : ProviderRecheckPolicy,
  now~ : Int64,
) -> Bool {
  match
    provider_availability_deferred_until(
      availability, observed_at, prior_deferrals, policy,
    ) {
    None => true
    Some(instant) => now >= instant
  }
}

///|
/// One provider surface, the last thing it told Choir about itself, and when
/// it said so.
///
/// Selecting where the next Take runs needs more than the surface that just
/// failed: a Part that already left a spent surface must not be sent back to
/// it while it is still spent. It also needs the date, because an observation
/// with no reset instant expires on the re-check schedule rather than standing
/// for the Part's lifetime.
pub(all) struct ProviderSurfaceObservation {
  surface : ProviderSurfaceId
  availability : ProviderAvailability
  observed_at : Int64
}

///|
/// Choose which admitted surface the next bounded recovery attempt runs on,
/// once `current` has said it cannot serve.
///
/// Authority comes from the captured contract and nowhere else: only a
/// surface the contract admitted can be returned, in the order the contract
/// named them, so recovery never changes which provider a Take was authorized
/// to spend. A candidate is skipped when any observation of it still defers
/// dispatch at `now`, which is what keeps two spent surfaces from handing the
/// same Part back and forth; an observation that has aged past its re-check
/// interval no longer suppresses its surface, so a Part can return to a
/// surface it previously left. `None` means every admitted surface is either
/// the one that just failed or is still deferred, so the caller must wait.
pub fn select_admitted_provider_surface(
  current : ProviderSurfaceId,
  admitted : Array[ProviderSurfaceId],
  observed : Array[ProviderSurfaceObservation],
  policy : ProviderRecheckPolicy,
  now : Int64,
) -> ProviderSurfaceId? {
  for candidate in admitted {
    if candidate == current {
      continue
    }
    let mut admits = true
    // Observations arrive oldest first, so the ones already counted for this
    // candidate are exactly the deferrals that preceded the one being read.
    let mut prior_deferrals = 0
    for observation in observed {
      if observation.surface == candidate {
        if !provider_availability_admits_dispatch(
            observation.availability,
            observed_at=observation.observed_at,
            prior_deferrals~,
            policy~,
            now~,
          ) {
          admits = false
        }
        prior_deferrals = prior_deferrals + 1
      }
    }
    if admits {
      return Some(candidate)
    }
  }
  None
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
    ProviderAvailability::ProviderAvailable,
  )
  // An unrecognized failure is unavailable, not an invented allowance state.
  assert_eq(
    classify_provider_availability(1, "segmentation fault"),
    ProviderAvailability::ProviderUnavailable,
  )
  assert_eq(
    classify_provider_availability(1, "Claude usage limit reached"),
    ProviderAvailability::ProviderAllowanceExhausted(None),
  )
  // Trusted reset evidence is retained when the provider supplied it.
  assert_eq(
    classify_provider_availability(
      1,
      "Rate limit exceeded",
      reset_at=Some(5_000L),
    ),
    ProviderAvailability::ProviderAllowanceExhausted(Some(5_000L)),
  )
  // A retry-after is resolved to an absolute instant against the clock.
  assert_eq(
    classify_provider_availability(
      1,
      "service unavailable",
      retry_after_seconds=Some(30L),
      now=1_000L,
    ),
    ProviderAvailability::ProviderRetryAfter(1_030L),
  )
  // Allowance evidence wins over a retry hint: it names the actual condition.
  assert_eq(
    classify_provider_availability(
      1,
      "too many requests",
      retry_after_seconds=Some(30L),
      now=1_000L,
    ),
    ProviderAvailability::ProviderAllowanceExhausted(None),
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
    ProviderAvailability::ProviderAllowanceExhausted(None),
  )
}

///|
/// Remove credentials from a URL's userinfo while keeping the rest readable.
///
/// Git error text quotes the remote it failed against, and a token-in-URL
/// remote — `https://x-access-token:TOKEN@host/owner/repo` — therefore carries
/// the credential into anything that persists that text. The host, path, and
/// the error itself are what make the diagnostic worth keeping, so only the
/// userinfo between `://` and the next `@` is replaced.
///
/// Applied to whole lines rather than to a parsed URL: the input is arbitrary
/// process output, not a URL, and a parser that failed to recognize one shape
/// would silently pass the credential through.
pub fn redact_url_credentials(text : String) -> String {
  let out = StringBuilder::new()
  let chars = text.to_array()
  let mut index = 0
  while index < chars.length() {
    if url_scheme_separator_at(chars, index) {
      out.write_string("://")
      index = index + 3
      // Userinfo ends at `@`, but only within this authority: a `/`, space, or
      // quote first means there was no userinfo to remove.
      let mut scan = index
      let mut at = -1
      while scan < chars.length() {
        let char = chars[scan]
        if char == '@' {
          at = scan
          break
        }
        if char == '/' ||
          char == ' ' ||
          char == '"' ||
          char == '\'' ||
          char == '\n' {
          break
        }
        scan = scan + 1
      }
      if at >= 0 {
        out.write_string("<redacted>@")
        index = at + 1
      }
    } else {
      out.write_char(chars[index])
      index = index + 1
    }
  }
  out.to_string()
}

///|
fn url_scheme_separator_at(chars : Array[Char], index : Int) -> Bool {
  index + 2 < chars.length() &&
  chars[index] == ':' &&
  chars[index + 1] == '/' &&
  chars[index + 2] == '/'
}

///|
/// A token-in-URL remote puts the credential in every git error that quotes
/// it, and those errors are persisted to disk and shown in diagnostics.
test "a persisted git diagnostic keeps the host but not the credential" {
  let redacted = redact_url_credentials(
    "fatal: could not read from 'https://x-access-token:ghs_SECRETVALUE@github.com/owner/repo.git'\n" +
    "remote: Invalid username or password",
  )
  assert_false(redacted.contains("ghs_SECRETVALUE"))
  assert_false(redacted.contains("x-access-token"))
  // What makes the diagnostic worth keeping survives.
  assert_true(redacted.contains("github.com/owner/repo.git"))
  assert_true(redacted.contains("Invalid username or password"))
  assert_true(redacted.contains("<redacted>@github.com"))
}

///|
test "URL redaction leaves text that carries no credential alone" {
  fn unchanged(text : String) raise {
    assert_eq(redact_url_credentials(text), text)
  }
  // No userinfo to remove.
  unchanged("fatal: repository 'https://github.com/owner/repo.git' not found")
  unchanged("error: failed to push some refs to 'git@github.com:owner/repo'")
  unchanged("")
  unchanged("no url here at all")
  // An `@` after the path is part of the path, not userinfo, so the authority
  // scan must stop at the first `/`.
  unchanged("https://github.com/owner/repo/blob/main/a@b.txt")
  // Several remotes in one message are each redacted.
  let many = redact_url_credentials(
    "https://user:pw@a.example/x and https://tok@b.example/y",
  )
  assert_eq(
    many, "https://<redacted>@a.example/x and https://<redacted>@b.example/y",
  )
}

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
/// One provider surface and the last thing it told Choir about itself.
///
/// Selecting where the next Take runs needs more than the surface that just
/// failed: a Part that already left a spent surface must not be sent back to
/// it while it is still spent.
pub(all) struct ProviderSurfaceObservation {
  surface : ProviderSurfaceId
  availability : ProviderAvailability
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
/// same Part back and forth. `None` means every admitted surface is either the
/// one that just failed or is itself deferred, so the caller must wait.
pub fn select_admitted_provider_surface(
  current : ProviderSurfaceId,
  admitted : Array[ProviderSurfaceId],
  observed : Array[ProviderSurfaceObservation],
  now : Int64,
) -> ProviderSurfaceId? {
  for candidate in admitted {
    if candidate == current {
      continue
    }
    let mut admits = true
    for observation in observed {
      if observation.surface == candidate &&
        !provider_availability_admits_dispatch(observation.availability, now) {
        admits = false
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
test "deferral waits only on trusted reset evidence" {
  let admits = fn(availability, now) {
    provider_availability_admits_dispatch(availability, now)
  }
  assert_true(admits(ProviderAvailability::ProviderAvailable, 10L))
  // An unavailable surface retries under the ordinary bounded recovery path.
  assert_true(admits(ProviderAvailability::ProviderUnavailable, 10L))
  // An exhausted allowance with no reset evidence is never given an invented
  // one: it waits rather than burning the next Take against a spent surface.
  assert_false(
    admits(ProviderAvailability::ProviderAllowanceExhausted(None), 10L),
  )
  assert_false(
    admits(ProviderAvailability::ProviderAllowanceExhausted(Some(100L)), 99L),
  )
  assert_true(
    admits(ProviderAvailability::ProviderAllowanceExhausted(Some(100L)), 100L),
  )
  assert_false(admits(ProviderAvailability::ProviderRetryAfter(100L), 99L))
  assert_true(admits(ProviderAvailability::ProviderRetryAfter(100L), 100L))
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

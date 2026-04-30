///|
fn parse_review_state(json : Json) -> ReviewState {
  let mut review = ReviewState::None_
  guard json is Object(obj) else { return review }
  guard obj.get("reviews") is Some(Array(reviews)) else { return review }
  for r in reviews {
    guard r is Object(rev) else { continue }
    match rev.get("state") {
      Some(String("APPROVED")) => review = ReviewState::Approved
      Some(String("CHANGES_REQUESTED")) =>
        review = ReviewState::ChangesRequested
      Some(String("COMMENTED")) =>
        if review == ReviewState::None_ {
          review = ReviewState::Commented
        }
      _ => ()
    }
  }
  review
}

///|
fn parse_head_ref_oid(json : Json) -> String {
  guard json is Object(obj) else { return "" }
  match obj.get("headRefOid") {
    Some(String(v)) => v
    _ => ""
  }
}

///|
fn review_body_noise_subject(body : String) -> String {
  let trimmed = body.trim().to_owned()
  if trimmed.has_prefix("[") {
    match trimmed.find("]") {
      Some(idx) => trimmed[idx + 1:].trim().to_owned()
      None => trimmed
    }
  } else {
    trimmed
  }
}

///|
fn review_body_is_noise(body : String) -> Bool {
  let normalized = review_body_noise_subject(body).to_lower()
  if normalized.has_prefix("pull request overview") {
    return true
  }
  // Copilot template uses "## Pull request overview" (markdown H2); plain-text prefix check misses it.
  if normalized.has_prefix("## pull request overview") {
    return true
  }
  false
}

///|
fn push_review_body(bodies : Array[String], body : String) -> Unit {
  let trimmed = body.trim().to_owned()
  if trimmed == "" || review_body_is_noise(trimmed) || bodies.contains(trimmed) {
    return
  }
  bodies.push(trimmed)
}

///|
fn parse_review_bodies(json : Json) -> String {
  let bodies : Array[String] = []
  guard json is Object(obj) else { return "" }
  match obj.get("reviews") {
    Some(Array(reviews)) =>
      for r in reviews {
        guard r is Object(rev) else { continue }
        match rev.get("body") {
          Some(String(v)) => push_review_body(bodies, v)
          _ => ()
        }
      }
    _ => ()
  }
  // Include inline code comments if present
  match obj.get("inline_comments") {
    Some(Array(comments)) =>
      for c in comments {
        guard c is Object(comment) else { continue }
        let path = match comment.get("path") {
          Some(String(v)) => v
          _ => ""
        }
        let line = match comment.get("line") {
          Some(Number(n, ..)) => n.to_int()
          _ => 0
        }
        let body = match comment.get("body") {
          Some(String(v)) => v
          _ => ""
        }
        if body != "" {
          let prefix = if path != "" && line > 0 {
            "[" + path + ":" + line.to_string() + "] "
          } else if path != "" {
            "[" + path + "] "
          } else {
            ""
          }
          push_review_body(bodies, prefix + body)
        }
      }
    _ => ()
  }
  bodies.join("\n---\n")
}

///|
fn json_str_upper(v : Json) -> String {
  match v {
    String(s) => s.to_upper()
    _ => ""
  }
}

///|
fn rollup_conclusion_failure(s : String) -> Bool {
  s == "FAILURE" || s == "ERROR" || s == "TIMED_OUT"
}

///|
fn rollup_state_pending(s : String) -> Bool {
  s == "PENDING" ||
  s == "IN_PROGRESS" ||
  s == "EXPECTED" ||
  s == "QUEUED" ||
  s == "WAITING" ||
  s == "REQUESTED"
}

///|
fn rollup_conclusion_success(s : String) -> Bool {
  s == "SUCCESS" || s == "SKIPPED" || s == "NEUTRAL"
}

///|
/// Aggregate GitHub `statusCheckRollup` into a coarse status for the PR head.
fn parse_ci_rollup(json : Json) -> CiRollupStatus {
  guard json is Object(obj) else { return Unknown }
  guard obj.get("statusCheckRollup") is Some(Array(checks)) else {
    return Unknown
  }
  if checks.length() == 0 {
    return Unknown
  }
  let mut any_failure = false
  let mut any_pending = false
  let mut all_have_success = true
  let mut saw_check = false
  for check in checks {
    guard check is Object(c) else { continue }
    saw_check = true
    let conclusion = match c.get("conclusion") {
      Some(v) => json_str_upper(v)
      None => ""
    }
    let state = match c.get("state") {
      Some(v) => json_str_upper(v)
      None => ""
    }
    let status = match c.get("status") {
      Some(v) => json_str_upper(v)
      None => ""
    }
    if rollup_conclusion_failure(conclusion) || rollup_state_failure(state) {
      any_failure = true
      all_have_success = false
      continue
    }
    if conclusion == "" {
      if rollup_state_pending(state) || rollup_status_incomplete(status) {
        any_pending = true
      }
      all_have_success = false
      continue
    }
    if rollup_conclusion_success(conclusion) {
      continue
    }
    all_have_success = false
  }
  if !saw_check {
    return Unknown
  }
  if any_failure {
    return Failure
  }
  if any_pending {
    return InProgress
  }
  if all_have_success {
    Success
  } else {
    Unknown
  }
}

///|
fn rollup_state_failure(s : String) -> Bool {
  s == "FAILURE" || s == "ERROR"
}

///|
fn rollup_status_incomplete(s : String) -> Bool {
  s == "IN_PROGRESS" ||
  s == "QUEUED" ||
  s == "PENDING" ||
  s == "WAITING" ||
  s == "REQUESTED"
}

///|
fn parse_pr_is_open(json : Json) -> Bool {
  guard json is Object(obj) else { return true }
  match obj.get("state") {
    Some(String("OPEN")) => true
    Some(String(_)) => false
    _ => true
  }
}

///|
/// Recognize GitHub Copilot bots that post on the PR issue thread (issue comments).
fn gh_login_is_copilot_issue_comment_author(login : String) -> Bool {
  let l = login.to_lower()
  l == "copilot-pull-request-reviewer" ||
  l == "copilot-pull-request-reviewer[bot]" ||
  l == "github-copilot" ||
  l == "github-copilot[bot]" ||
  l == "copilot-swe-agent" ||
  l == "copilot-swe-agent[bot]"
}

///|
/// Parse `gh pr view --json reviews` output; true if any review's author.login is a Copilot bot.
/// This covers the common case where Copilot reviews via inline threads rather than REST issue comments.
pub fn parse_copilot_in_reviews(json_text : String) -> Bool {
  let json = @json.parse(json_text) catch { _ => return false }
  guard json is Object(obj) else { return false }
  guard obj.get("reviews") is Some(Array(reviews)) else { return false }
  for r in reviews {
    guard r is Object(rev) else { continue }
    match rev.get("author") {
      Some(Object(author)) =>
        match author.get("login") {
          Some(String(login)) =>
            if gh_login_is_copilot_issue_comment_author(login) {
              return true
            }
          _ => ()
        }
      _ => ()
    }
  }
  false
}

///|
/// Parse `gh api ... --jq "[.[] | .user.login]"` output; true if any login is Copilot.
pub fn parse_issue_comment_logins_for_copilot_present(
  json_text : String,
) -> Bool {
  if json_text.trim() == "" {
    return false
  }
  let json = @json.parse(json_text) catch { _ => return false }
  guard json is Array(logins) else { return false }
  for l in logins {
    match l {
      String(s) =>
        if gh_login_is_copilot_issue_comment_author(s) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
pub fn parse_gh_pr_view_output(
  data : String,
) -> (Bool, ReviewState, String, CiRollupStatus, String, Bool) {
  let json = @json.parse(data) catch {
    _ => return (false, None_, "", Unknown, "", true)
  }
  (
    true,
    parse_review_state(json),
    parse_head_ref_oid(json),
    parse_ci_rollup(json),
    parse_review_bodies(json),
    parse_pr_is_open(json),
  )
}

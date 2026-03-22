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
fn parse_review_bodies(json : Json) -> String {
  let bodies : Array[String] = []
  guard json is Object(obj) else { return "" }
  match obj.get("reviews") {
    Some(Array(reviews)) =>
      for r in reviews {
        guard r is Object(rev) else { continue }
        match rev.get("body") {
          Some(String(v)) => if v != "" { bodies.push(v) }
          _ => ()
        }
      }
    _ => ()
  }
  match obj.get("comments") {
    Some(Array(comments)) =>
      for c in comments {
        guard c is Object(comment) else { continue }
        match comment.get("body") {
          Some(String(v)) => if v != "" { bodies.push(v) }
          _ => ()
        }
      }
    _ => ()
  }
  bodies.join("\n---\n")
}

///|
fn parse_ci_failed(json : Json) -> Bool {
  guard json is Object(obj) else { return false }
  guard obj.get("statusCheckRollup") is Some(Array(checks)) else {
    return false
  }
  for check in checks {
    guard check is Object(c) else { continue }
    match c.get("conclusion") {
      Some(String("FAILURE")) | Some(String("ERROR")) => return true
      _ => ()
    }
    match c.get("state") {
      Some(String("FAILURE")) | Some(String("ERROR")) => return true
      _ => ()
    }
  }
  false
}

///|
pub fn parse_gh_pr_view_output(
  data : String,
) -> (ReviewState, String, Bool, String) {
  let json = @json.parse(data) catch { _ => return (None_, "", false, "") }
  (
    parse_review_state(json),
    parse_head_ref_oid(json),
    parse_ci_failed(json),
    parse_review_bodies(json),
  )
}

///|
/// Poll a PR by shelling out to gh and capturing output via temp file.
/// Avoids pipe deadlock by not using pipe stdout capture.
pub async fn gh_poll_pr(pr_number : Int) -> (ReviewState, String, Bool, String) {
  let tmp = "/tmp/choir-poll-" + pr_number.to_string() + ".json"
  let exit_code = @process.run("sh", [
    "-c",
    "gh pr view " +
    pr_number.to_string() +
    " --json reviews,headRefOid,statusCheckRollup,comments > " +
    tmp +
    " 2>/dev/null",
  ]) catch {
    e => {
      @io.write_stderr(
        "[poller] gh pr view failed for PR #" +
        pr_number.to_string() +
        ": " +
        e.to_string() +
        "\n",
      )
      -1
    }
  }
  if exit_code != 0 {
    @io.write_stderr(
      "[poller] gh exit=" +
      exit_code.to_string() +
      " for PR #" +
      pr_number.to_string() +
      "\n",
    )
    return (None_, "", false, "")
  }
  let output = @io.read_file(tmp)
  if output == "" {
    return (None_, "", false, "")
  }
  parse_gh_pr_view_output(output)
}

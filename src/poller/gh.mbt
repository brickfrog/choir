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
  guard obj.get("reviews") is Some(Array(reviews)) else { return "" }
  for r in reviews {
    guard r is Object(rev) else { continue }
    match rev.get("body") {
      Some(String(v)) => if v != "" { bodies.push(v) }
      _ => ()
    }
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
pub async fn gh_poll_pr(pr_number : Int) -> (ReviewState, String, Bool, String) {
  let (read_end, write_end) = @pipe.pipe() catch {
    e => {
      @io.write_stderr(
        "[poller] pipe() failed for PR #" +
        pr_number.to_string() +
        ": " +
        e.to_string() +
        "\n",
      )
      return (None_, "", false, "")
    }
  }
  let exit_code = @process.run(
    "gh",
    [
      "pr",
      "view",
      pr_number.to_string(),
      "--json",
      "reviews,headRefOid,statusCheckRollup",
    ],
    stdout=write_end,
  ) catch {
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
  let buf = FixedArray::make(65536, (0 : Byte))
  let mut total = 0
  for ;; {
    if total >= buf.length() {
      break
    }
    let n = read_end.read(buf, offset=total, max_len=buf.length() - total) catch {
      _ => 0
    }
    if n == 0 {
      break
    }
    total = total + n
  }
  read_end.close()
  if exit_code != 0 {
    @io.write_stderr(
      "[poller] gh exit=" +
      exit_code.to_string() +
      " for PR #" +
      pr_number.to_string() +
      " (read " +
      total.to_string() +
      " bytes)\n",
    )
    return (None_, "", false, "")
  }
  let output = @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total])
  parse_gh_pr_view_output(output)
}

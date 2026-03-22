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
pub async fn gh_poll_pr(pr_number : Int) -> (ReviewState, String, Bool, String) {
  let (reader, writer) = @process.read_from_process() catch {
    e => {
      @sys.write_stderr(
        "[poller] pipe failed for PR #" +
        pr_number.to_string() +
        ": " +
        e.to_string() +
        "\n",
      )
      return (None_, "", false, "")
    }
  }
  let (err_reader, err_writer) = @process.read_from_process() catch {
    _ => return (None_, "", false, "")
  }
  let pid = @process.spawn_orphan(
    "gh",
    [
      "pr",
      "view",
      pr_number.to_string(),
      "--json",
      "reviews,headRefOid,statusCheckRollup,comments",
    ],
    stdout=writer,
    stderr=err_writer,
  ) catch {
    e => {
      @sys.write_stderr(
        "[poller] gh spawn failed for PR #" +
        pr_number.to_string() +
        ": " +
        e.to_string() +
        "\n",
      )
      reader.close()
      return (None_, "", false, "")
    }
  }
  let buf = FixedArray::make(65536, (0 : Byte))
  let mut total = 0
  for ;; {
    if total >= buf.length() {
      break
    }
    let n = reader.read(buf, offset=total, max_len=buf.length() - total) catch {
      _ => 0
    }
    if n == 0 {
      break
    }
    total = total + n
  }
  reader.close()
  // Read stderr
  let err_buf = FixedArray::make(4096, (0 : Byte))
  let mut err_total = 0
  for ;; {
    if err_total >= err_buf.length() {
      break
    }
    let n = err_reader.read(
      err_buf,
      offset=err_total,
      max_len=err_buf.length() - err_total,
    ) catch {
      _ => 0
    }
    if n == 0 {
      break
    }
    err_total = err_total + n
  }
  err_reader.close()
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  if exit_code != 0 || total == 0 {
    let err_text = @utf8.decode_lossy(
      err_buf.unsafe_reinterpret_as_bytes()[:err_total],
    )
    @sys.write_stderr(
      "[poller] gh exit=" +
      exit_code.to_string() +
      " for PR #" +
      pr_number.to_string() +
      " stdout=" +
      total.to_string() +
      "b stderr=" +
      err_text.trim().to_string() +
      "\n",
    )
    if total == 0 {
      return (None_, "", false, "")
    }
  }
  let output = @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total])
  parse_gh_pr_view_output(output)
}

///|
async fn drain_reader_from_process(
  reader : @process.ReadFromProcess,
  max_bytes : Int,
) -> (String, Int) {
  let buf = FixedArray::make(max_bytes, (0 : Byte))
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
  (@utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total]), total)
}

///|
async fn fetch_inline_comments(pr_number : Int) -> String {
  @exec.capture_stdout("gh", [
    "api",
    "repos/{owner}/{repo}/pulls/" + pr_number.to_string() + "/comments",
    "--jq",
    "[.[] | {path, body}]",
  ])
}

///|
/// Returns `(exit_code, stdout)` so callers can log non-success without treating as definitive false.
async fn fetch_issue_comment_logins(pr_number : Int) -> (Int, String) {
  let (reader, writer) = @process.read_from_process() catch {
    _ => return (-1, "")
  }
  let pid = @process.spawn_orphan(
    "gh",
    [
      "api",
      "repos/{owner}/{repo}/issues/" + pr_number.to_string() + "/comments",
      "--jq",
      "[.[] | .user.login]",
    ],
    stdout=writer,
  ) catch {
    _ => {
      reader.close()
      return (-1, "")
    }
  }
  let (output, _total) = drain_reader_from_process(reader, 65536)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  (exit_code, output)
}

///|
/// When `skip_issue_comment_fetch` is true (Copilot already seen on this PR), skips the extra
/// `gh api .../issues/{n}/comments` call to reduce rate-limit load.
pub async fn gh_poll_pr(
  pr_number : Int,
  skip_issue_comment_fetch : Bool,
) -> (Bool, ReviewState, String, CiRollupStatus, String, Bool, Bool) {
  let (reader, writer) = @process.read_from_process() catch {
    e => {
      @sys.write_stderr(
        "[poller] pipe failed for PR #" +
        pr_number.to_string() +
        ": " +
        e.to_string() +
        "\n",
      )
      return (false, None_, "", Unknown, "", true, false)
    }
  }
  let (err_reader, err_writer) = @process.read_from_process() catch {
    _ => return (false, None_, "", Unknown, "", true, false)
  }
  let pid = @process.spawn_orphan(
    "gh",
    [
      "pr",
      "view",
      pr_number.to_string(),
      "--json",
      "reviews,headRefOid,statusCheckRollup,state",
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
      return (false, None_, "", Unknown, "", true, false)
    }
  }
  let (output, total) = drain_reader_from_process(reader, 65536)
  let (err_text_raw, _err_total) = drain_reader_from_process(err_reader, 4096)
  let exit_code = @process.wait_pid(pid) catch { _ => -1 }
  if exit_code != 0 || total == 0 {
    let err_text = err_text_raw
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
      return (false, None_, "", Unknown, "", true, false)
    }
  }
  // Fetch inline code review comments (separate API)
  let inline_output = fetch_inline_comments(pr_number)
  let merged = merge_inline_comments(output, inline_output)
  let exit_ok = exit_code == 0 && total > 0
  let (json_ok, review, sha, ci_rollup, review_bodies, is_open) = parse_gh_pr_view_output(
    merged,
  )
  let copilot_issue_comment_seen = if skip_issue_comment_fetch {
    false
  } else {
    let (issue_exit, issue_logins_json) = fetch_issue_comment_logins(pr_number)
    if issue_exit != 0 {
      @sys.write_stderr(
        "[poller] gh api issue-comments exit=" +
        issue_exit.to_string() +
        " for PR #" +
        pr_number.to_string() +
        " — Copilot issue-comment presence unknown this tick\n",
      )
    }
    parse_issue_comment_logins_for_copilot_present(issue_logins_json)
  }
  (
    exit_ok && json_ok,
    review,
    sha,
    ci_rollup,
    review_bodies,
    is_open,
    copilot_issue_comment_seen,
  )
}

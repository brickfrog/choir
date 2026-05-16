///|
test "gh_fallback_classify truth table" {
  @debug.assert_eq(
    gh_fallback_classify(0, "{\"ok\":true}\n"),
    Fresh("{\"ok\":true}\n"),
  )
  @debug.assert_eq(gh_fallback_classify(124, ""), Stall)
  @debug.assert_eq(gh_fallback_classify(0, "  \n"), EmptyOutput)
  @debug.assert_eq(gh_fallback_classify(2, "boom"), Error(2))
}

///|
async fn gh_fallback_fresh_capture(cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  if cmd.program != "timeout" {
    return (2, "expected bounded gh")
  }
  (
    0, "{\"number\":7,\"url\":\"https://github.com/o/r/pull/7\",\"state\":\"OPEN\",\"reviews\":[],\"headRefOid\":\"sha\",\"statusCheckRollup\":[]}",
  )
}

///|
async test "gh_pr_view_with_fallback returns fresh gh output" {
  let ps = PollerState::new()
  let got = gh_pr_view_with_fallback(7, ps, capture=gh_fallback_fresh_capture)
  assert_false(got.stale)
  assert_eq(got.age_sec, 0)
  assert_true(got.data.contains("\"number\":7"))
}

///|
async fn gh_fallback_stall_capture(_cmd : @workspace.Command) -> (Int, String) {
  @async.sleep(0)
  (124, "")
}

///|
fn gh_fallback_state_with_pr() -> PollerState {
  let ps = PollerState::new()
  ps.track_recovered(
    7,
    "main.leaf",
    "main.leaf",
    "main",
    "https://github.com/o/r/pull/7",
    100L,
    Approved,
    "Looks fine.",
    "abc123",
    Success,
    true,
  )
  match ps.get(7) {
    Some(tracked) =>
      ps.restore({
        ..tracked,
        unresolved_thread_ids: [
          { id: "thread-1", is_outdated: false, author_login: "copilot" },
        ],
        unresolved_thread_ids_fetched: true,
      })
    None => ()
  }
  ps
}

///|
async test "gh_pr_view_with_fallback returns stale snapshot when tracked" {
  let ps = gh_fallback_state_with_pr()
  let got = gh_pr_view_with_fallback(7, ps, capture=gh_fallback_stall_capture, now_sec=fn() {
    130L
  })
  assert_true(got.stale)
  assert_eq(got.age_sec, 30)
  assert_true(got.data.contains("\"number\":7"))
  assert_true(got.data.contains("\"headRefOid\":\"abc123\""))
  assert_true(got.data.contains("\"unresolved_threads\":1"))
  assert_true(got.data.contains("\"copilot_issue_comment_seen\":true"))
}

///|
async test "gh_pr_view_with_fallback returns empty stale without tracked PR" {
  let ps = PollerState::new()
  let got = gh_pr_view_with_fallback(99, ps, capture=gh_fallback_stall_capture)
  assert_true(got.stale)
  assert_eq(got.age_sec, 0)
  assert_eq(got.data, "")
}

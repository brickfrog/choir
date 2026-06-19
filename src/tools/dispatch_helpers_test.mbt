///|
fn test_counter_path(name : String) -> String {
  "/tmp/choir-delivery-retry-" +
  name +
  "-" +
  @sys.get_pid().to_string() +
  ".count"
}

///|
fn test_sleep_path(name : String) -> String {
  "/tmp/choir-delivery-retry-" +
  name +
  "-" +
  @sys.get_pid().to_string() +
  ".sleep"
}

///|
fn read_counter(path : String) -> Int {
  let content = @sys.read_file(path)
  let mut count = 0
  for line in content.split("\n") {
    if line.to_owned().trim().to_owned() != "" {
      count = count + 1
    }
  }
  count
}

///|
fn increment_counter(path : String) -> Int {
  ignore(@sys.append_file_sync(path, "1\n"))
  read_counter(path)
}

///|
fn reset_test_files(name : String) -> Unit {
  ignore(@sys.delete_file_sync(test_counter_path(name)))
  ignore(@sys.delete_file_sync(test_sleep_path(name)))
}

///|
async fn runner_fail_three_then_succeed(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let attempt = increment_counter(test_counter_path("success"))
  let statuses = []
  for _ in cmds {
    statuses.push(if attempt <= 3 { 1 } else { 0 })
  }
  statuses
}

///|
async fn record_sleep_success(ms : Int) -> Unit {
  ignore(
    @sys.append_file_sync(test_sleep_path("success"), ms.to_string() + "\n"),
  )
  @async.sleep(0)
}

///|
async fn no_op_sleep(_ms : Int) -> Unit {
  @async.sleep(0)
}

///|
async fn runner_always_fail(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  ignore(increment_counter(test_counter_path("failure")))
  let statuses = []
  for _ in cmds {
    statuses.push(1)
  }
  statuses
}

///|
async fn runner_always_succeed(cmds : Array[@workspace.Command]) -> Array[Int] {
  @async.sleep(0)
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async fn record_sleep_failure(ms : Int) -> Unit {
  ignore(
    @sys.append_file_sync(test_sleep_path("failure"), ms.to_string() + "\n"),
  )
  @async.sleep(0)
}

///|
async fn runner_throw_three_then_succeed(
  cmds : Array[@workspace.Command],
) -> Array[Int] {
  @async.sleep(0)
  let attempt = increment_counter(test_counter_path("throws"))
  if attempt <= 3 {
    fail("simulated runner exception")
  }
  let statuses = []
  for _ in cmds {
    statuses.push(0)
  }
  statuses
}

///|
async fn record_sleep_throws(ms : Int) -> Unit {
  ignore(
    @sys.append_file_sync(test_sleep_path("throws"), ms.to_string() + "\n"),
  )
  @async.sleep(0)
}

///|
fn sample_delivery(text : String) -> @message.DeliveryMethod {
  let target = @types.LocalTarget::parse("zellij-pane:test:terminal_1").unwrap()
  @message.DeliveryMethod::LocalTerminalInput(target, text)
}

///|
fn delivery_log_project_dir(name : String) -> String {
  "/tmp/choir-delivery-" +
  name +
  "-" +
  @sys.get_pid().to_string() +
  "-" +
  @env.now().reinterpret_as_int64().to_string()
}

///|
async test "execute_delivery retries local terminal command with exponential backoff" {
  reset_test_files("success")
  let result = execute_delivery(
    sample_delivery("hello retry"),
    runner_fail_three_then_succeed,
    sleep_fn=record_sleep_success,
  )
  match result {
    Ok(_) => ()
    Err(e) => fail("expected delivery success after retries: " + e.message())
  }
  assert_eq(read_counter(test_counter_path("success")), 4)
  assert_eq(@sys.read_file(test_sleep_path("success")), "1000\n2000\n4000\n")
}

///|
async test "execute_delivery logs successful local terminal delivery" {
  let project_dir = delivery_log_project_dir("local-success")
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let result = execute_delivery(
    sample_delivery("hello success"),
    runner_always_succeed,
    project_dir~,
  )
  match result {
    Ok(_) => ()
    Err(e) => fail("expected delivery success: " + e.message())
  }
  let log = @sys.read_file(project_dir + "/.choir/delivery.log")
  assert_true(log.contains("[delivery-success]"))
  assert_true(log.contains("target=zellij-pane:test:terminal_1"))
}

///|
async test "execute_delivery logs successful teams inbox delivery" {
  let project_dir = delivery_log_project_dir("teams-success")
  assert_true(@sys.create_dir_all(project_dir + "/.choir"))
  let inbox_path = project_dir + "/inbox/default.json"
  let delivery = @message.DeliveryMethod::TeamsInbox(
    inbox_path,
    "{\"content\":\"hello\"}",
    fallback_target=None,
  )
  let result = execute_delivery(
    delivery,
    runner_always_succeed,
    project_dir~,
    sleep_fn=no_op_sleep,
  )
  match result {
    Ok(_) => ()
    Err(e) => fail("expected teams delivery success: " + e.message())
  }
  let log = @sys.read_file(project_dir + "/.choir/delivery.log")
  assert_true(log.contains("[delivery-success]"))
  assert_true(log.contains("target=teams:" + inbox_path))
}

///|
async test "execute_delivery returns error after exhausting retries" {
  reset_test_files("failure")
  let result = execute_delivery(
    sample_delivery("hello failure"),
    runner_always_fail,
    sleep_fn=record_sleep_failure,
  )
  match result {
    Ok(_) => fail("expected delivery failure")
    Err(e) => assert_true(e.message().contains("delivery command failed"))
  }
  assert_eq(read_counter(test_counter_path("failure")), 4)
  assert_eq(@sys.read_file(test_sleep_path("failure")), "1000\n2000\n4000\n")
}

///|
async test "execute_delivery retries and sleeps when runner throws" {
  reset_test_files("throws")
  let result = execute_delivery(
    sample_delivery("hello throws"),
    runner_throw_three_then_succeed,
    sleep_fn=record_sleep_throws,
  )
  match result {
    Ok(_) => ()
    Err(e) =>
      fail("expected delivery success after thrown retries: " + e.message())
  }
  assert_eq(read_counter(test_counter_path("throws")), 4)
  assert_eq(@sys.read_file(test_sleep_path("throws")), "1000\n2000\n4000\n")
}

///|
test "parse_unresolved_threads_response returns only unresolved threads" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_abc","isResolved":false,"path":"src/foo.mbt","comments":{"nodes":[{"body":"fix this"}]}},{"id":"PRRT_def","isResolved":true,"path":"src/bar.mbt","comments":{"nodes":[{"body":"already fixed"}]}}]}}}}}
  let (count, text) = parse_unresolved_threads_response(json)
  assert_eq(count, 1)
  assert_true(text.contains("PRRT_abc"))
  assert_true(text.contains("fix this"))
  assert_false(text.contains("already fixed"))
  assert_false(text.contains("PRRT_def"))
}

///|
test "parse_unresolved_threads_response empty on all resolved" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_xyz","isResolved":true,"path":"src/foo.mbt","comments":{"nodes":[{"body":"done"}]}}]}}}}}
  let (count, text) = parse_unresolved_threads_response(json)
  assert_eq(count, 0)
  assert_eq(text, "")
}

///|
test "parse_unresolved_threads_response includes outdated unresolved threads" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_old","isResolved":false,"isOutdated":true,"path":"src/foo.mbt","comments":{"nodes":[{"body":"stale comment"}]}},{"id":"PRRT_new","isResolved":false,"isOutdated":false,"path":"src/bar.mbt","comments":{"nodes":[{"body":"active comment"}]}}]}}}}}
  let (count, text) = parse_unresolved_threads_response(json)
  assert_eq(count, 2)
  assert_true(text.contains("PRRT_new"))
  assert_true(text.contains("active comment"))
  assert_true(text.contains("PRRT_old"))
  assert_true(text.contains("stale comment"))
}

///|
test "parse_unresolved_threads_response empty on parse error" {
  let (count, text) = parse_unresolved_threads_response("not json")
  assert_eq(count, 0)
  assert_eq(text, "")
}

///|
test "parse_review_thread_refs_response preserves isOutdated true and false" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_old","isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer[bot]"}}]}},{"id":"PRRT_new","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"octocat"}}]}},{"id":"PRRT_done","isResolved":true,"isOutdated":true}]}}}}}
  match parse_review_thread_refs_response(json) {
    Some(refs) => {
      assert_eq(refs.length(), 2)
      assert_eq(refs[0], @poller.ReviewThreadRef::{
        id: "PRRT_old",
        is_outdated: true,
        author_login: "copilot-pull-request-reviewer[bot]",
      })
      assert_eq(refs[1], @poller.ReviewThreadRef::{
        id: "PRRT_new",
        is_outdated: false,
        author_login: "octocat",
      })
    }
    None => fail("expected review thread refs")
  }
}

///|
test "parse_review_thread_refs_response defaults missing comment author to empty login" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_unknown","isResolved":false,"isOutdated":true,"comments":{"nodes":[]}}]}}}}}
  match parse_review_thread_refs_response(json) {
    Some(refs) => {
      assert_eq(refs.length(), 1)
      assert_eq(refs[0], @poller.ReviewThreadRef::{
        id: "PRRT_unknown",
        is_outdated: true,
        author_login: "",
      })
    }
    None => fail("expected missing author to be a non-Copilot thread ref")
  }
}

///|
test "parse_review_thread_refs_response distinguishes empty nodes from malformed json" {
  let empty =
    #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}
  match parse_review_thread_refs_response(empty) {
    Some(refs) => @debug.assert_eq(refs, [])
    None => fail("expected empty nodes to parse as an empty snapshot")
  }
  match parse_review_thread_refs_response("not json") {
    None => ()
    Some(_) => fail("expected malformed JSON to fail parsing")
  }
  match parse_review_thread_refs_response("{\"data\":{}}") {
    None => ()
    Some(_) => fail("expected missing reviewThreads nodes to fail parsing")
  }
}

///|
test "iso8601_to_epoch_seconds parses canonical and fractional UTC timestamps" {
  @debug.assert_eq(
    iso8601_to_epoch_seconds("2026-05-27T12:05:27Z"),
    Some(1779883527L),
  )
  @debug.assert_eq(
    iso8601_to_epoch_seconds("2026-05-27T12:05:27.243Z"),
    Some(1779883527L),
  )
}

///|
test "iso8601_to_epoch_seconds orders parsed epoch seconds" {
  match
    (
      iso8601_to_epoch_seconds("2026-05-27T12:05:27Z"),
      iso8601_to_epoch_seconds("2026-05-27T12:05:28Z"),
    ) {
    (Some(left), Some(right)) => assert_true(left < right)
    _ => fail("expected both timestamps to parse")
  }
}

///|
test "iso8601_to_epoch_seconds rejects invalid timestamps" {
  @debug.assert_eq(iso8601_to_epoch_seconds("invalid"), None)
}

///|
test "parse_pr_review_commit_timestamps_response reads review and commit timestamps" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"latestReviews":{"nodes":[{"submittedAt":"2026-05-23T10:00:00Z"}]},"commits":{"nodes":[{"commit":{"pushedDate":"2026-05-23T10:00:01Z","committedDate":"2026-05-23T10:00:01Z"}}]}}}}}
  match parse_pr_review_commit_timestamps_response(json) {
    Some(timestamps) => {
      @debug.assert_eq(
        timestamps.latest_review_at,
        Some("2026-05-23T10:00:00Z"),
      )
      @debug.assert_eq(
        timestamps.latest_commit_at,
        Some("2026-05-23T10:00:01Z"),
      )
    }
    None => fail("expected timestamps")
  }
}

///|
test "parse_pr_review_commit_timestamps_response allows empty reviews" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"latestReviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"pushedDate":"2026-05-23T10:00:01Z","committedDate":"2026-05-23T10:00:01Z"}}]}}}}}
  match parse_pr_review_commit_timestamps_response(json) {
    Some(timestamps) => {
      @debug.assert_eq(timestamps.latest_review_at, None)
      @debug.assert_eq(
        timestamps.latest_commit_at,
        Some("2026-05-23T10:00:01Z"),
      )
    }
    None => fail("expected timestamps with no latest review")
  }
}

///|
test "parse_pr_review_commit_timestamps_response falls back to committedDate" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"latestReviews":{"nodes":[{"submittedAt":"2026-05-23T10:00:00Z"}]},"commits":{"nodes":[{"commit":{"pushedDate":null,"committedDate":"2026-05-23T10:00:02Z"}}]}}}}}
  match parse_pr_review_commit_timestamps_response(json) {
    Some(timestamps) =>
      @debug.assert_eq(
        timestamps.latest_commit_at,
        Some("2026-05-23T10:00:02Z"),
      )
    None => fail("expected committedDate fallback")
  }
}

///|
test "parse_pr_review_commit_timestamps_response rejects graphql error bodies" {
  let error_body =
    #|{"errors":[{"type":"INVALID_GRAPHQL","message":"syntax error"}]}
  match parse_pr_review_commit_timestamps_response(error_body) {
    None => ()
    Some(_) => fail("expected GraphQL errors body to fail parsing")
  }
  match parse_pr_review_commit_timestamps_response("{\"data\":null}") {
    None => ()
    Some(_) => fail("expected missing data body to fail parsing")
  }
}

///|
async test "fetch_pr_review_commit_timestamps_with_repo emits balanced graphql query" {
  let expected_query = "query($owner: String!, $repo: String!, $pr: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { latestReviews(first: 1) { nodes { submittedAt } } commits(last: 1) { nodes { commit { pushedDate committedDate } } } } } }"
  let seen : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    seen.push(cmd)
    assert_eq(cmd.program, "timeout")
    assert_true(cmd.args.contains("graphql"))
    assert_true(cmd.args.contains("query=" + expected_query))
    assert_true(cmd.args.contains("owner=brickfrog"))
    assert_true(cmd.args.contains("repo=choir"))
    assert_true(cmd.args.contains("pr=42"))
    (
      0,
      (
        #|{"data":{"repository":{"pullRequest":{"latestReviews":{"nodes":[{"submittedAt":"2026-05-23T10:00:00Z"}]},"commits":{"nodes":[{"commit":{"pushedDate":"2026-05-23T10:00:01Z","committedDate":"2026-05-23T10:00:01Z"}}]}}}}}
      ),
    )
  }
  match
    fetch_pr_review_commit_timestamps_with_repo(
      42, "brickfrog", "choir", "/tmp/repo", capture,
    ) {
    Some(timestamps) =>
      @debug.assert_eq(
        timestamps.latest_commit_at,
        Some("2026-05-23T10:00:01Z"),
      )
    None => fail("expected timestamps")
  }
  assert_eq(seen.length(), 1)
}

///|
test "iso8601_to_epoch_seconds treats zero fractional seconds as same instant" {
  @debug.assert_eq(
    iso8601_to_epoch_seconds("2026-05-27T12:05:27.000Z"),
    iso8601_to_epoch_seconds("2026-05-27T12:05:27Z"),
  )
}

///|
test "parse_gh_repo_view_output extracts owner and repo" {
  match
    parse_gh_repo_view_output(
      "{\"owner\":{\"login\":\"brickfrog\"},\"name\":\"choir\"}",
    ) {
    Some((owner, repo)) => {
      assert_eq(owner, "brickfrog")
      assert_eq(repo, "choir")
    }
    None => fail("expected owner/repo")
  }
}

///|
test "parse_gh_repo_view_output returns None on malformed json" {
  @debug.assert_eq(parse_gh_repo_view_output("{\"owner\":{},\"name\":1}"), None)
}

///|
async fn mock_capture_repo_view_unavailable(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "timeout" &&
    cmd.args.length() >= 4 &&
    cmd.args[0] == "30s" &&
    cmd.args[1] == "gh" &&
    cmd.args[2] == "repo" &&
    cmd.args[3] == "view" {
    return (1, "")
  }
  (0, "")
}

///|
async test "fetch_unresolved_review_threads fails_closed_when_gh_repo_view_unavailable" {
  let (count, text) = fetch_unresolved_review_threads(
    7, "/tmp", mock_capture_repo_view_unavailable,
  )
  assert_eq(count, 1)
  assert_eq(text, review_thread_fetch_failed_marker)
}

///|
async fn mock_capture_repo_ok_graphql_fails(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "timeout" &&
    cmd.args.length() >= 4 &&
    cmd.args[0] == "30s" &&
    cmd.args[1] == "gh" &&
    cmd.args[2] == "repo" &&
    cmd.args[3] == "view" {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.args.contains("graphql") {
    return (1, "graphql request failed")
  }
  (0, "")
}

///|
async test "fetch_unresolved_review_threads fails_closed_when_graphql_nonzero_after_repo_view" {
  let (count, text) = fetch_unresolved_review_threads(
    99, "/tmp", mock_capture_repo_ok_graphql_fails,
  )
  assert_eq(count, 1)
  assert_eq(text, review_thread_fetch_failed_marker)
}

///|
async test "fetch_unresolved_review_threads uses bounded gh for count fetch" {
  let seen : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    seen.push(cmd)
    assert_eq(cmd.program, "timeout")
    assert_true(cmd.args.length() >= 3)
    assert_eq(cmd.args[0], "30s")
    assert_eq(cmd.args[1], "gh")
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.args.contains("graphql") {
      assert_true(cmd.args.join(" ").contains("reviewThreads(first: 100)"))
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[]}}}}}",
      )
    }
    (1, "unexpected command")
  }
  let (count, text) = fetch_unresolved_review_threads(5, "/tmp/repo", capture)
  assert_eq(count, 0)
  assert_eq(text, "")
  assert_eq(seen.length(), 2)
}

///|
async test "fetch_unresolved_review_thread_refs uses bounded gh and parses author logins" {
  let seen : Array[@workspace.Command] = []
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    seen.push(cmd)
    assert_eq(cmd.program, "timeout")
    assert_true(cmd.args.length() >= 3)
    assert_eq(cmd.args[0], "30s")
    assert_eq(cmd.args[1], "gh")
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    if cmd.args.contains("graphql") {
      assert_true(cmd.args.join(" ").contains("comments(first: 1)"))
      assert_true(cmd.args.join(" ").contains("nodes { author { login } }"))
      return (
        0, "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[{\"id\":\"PRRT_old\",\"isResolved\":false,\"isOutdated\":true,\"comments\":{\"nodes\":[{\"author\":{\"login\":\"copilot-pull-request-reviewer[bot]\"}}]}}]}}}}}",
      )
    }
    (1, "unexpected command")
  }
  match fetch_unresolved_review_thread_refs(5, "/tmp/repo", capture) {
    Some(refs) => {
      assert_eq(refs.length(), 1)
      assert_eq(refs[0], @poller.ReviewThreadRef::{
        id: "PRRT_old",
        is_outdated: true,
        author_login: "copilot-pull-request-reviewer[bot]",
      })
    }
    None => fail("expected thread refs")
  }
  assert_eq(seen.length(), 2)
}

///|
async test "fetch_unresolved_review_thread_refs returns None on malformed graphql body" {
  let capture = async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.args.contains("repo") && cmd.args.contains("view") {
      return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
    }
    (0, "not json")
  }
  match fetch_unresolved_review_thread_refs(5, "/tmp/repo", capture) {
    None => ()
    Some(_) => fail("expected malformed GraphQL body to fail fetching")
  }
}

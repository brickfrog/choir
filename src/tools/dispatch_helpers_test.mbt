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
    if line.to_string().trim().to_string() != "" {
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
test "parse_unresolved_threads_response skips outdated threads" {
  let json =
    #|{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_old","isResolved":false,"isOutdated":true,"path":"src/foo.mbt","comments":{"nodes":[{"body":"stale comment"}]}},{"id":"PRRT_new","isResolved":false,"isOutdated":false,"path":"src/bar.mbt","comments":{"nodes":[{"body":"active comment"}]}}]}}}}}
  let (count, text) = parse_unresolved_threads_response(json)
  assert_eq(count, 1)
  assert_true(text.contains("PRRT_new"))
  assert_true(text.contains("active comment"))
  assert_false(text.contains("PRRT_old"))
  assert_false(text.contains("stale comment"))
}

///|
test "parse_unresolved_threads_response empty on parse error" {
  let (count, text) = parse_unresolved_threads_response("not json")
  assert_eq(count, 0)
  assert_eq(text, "")
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
  assert_eq(parse_gh_repo_view_output("{\"owner\":{},\"name\":1}"), None)
}

///|
async fn mock_capture_repo_view_unavailable(
  cmd : @workspace.Command,
) -> (Int, String) {
  @async.sleep(0)
  if cmd.program == "gh" &&
    cmd.args.length() >= 3 &&
    cmd.args[0] == "repo" &&
    cmd.args[1] == "view" {
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
  if cmd.program == "gh" &&
    cmd.args.length() >= 3 &&
    cmd.args[0] == "repo" &&
    cmd.args[1] == "view" {
    return (0, "{\"owner\":{\"login\":\"o\"},\"name\":\"r\"}")
  }
  if cmd.program == "gh" && cmd.args.contains("graphql") {
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

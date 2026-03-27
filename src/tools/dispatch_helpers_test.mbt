///|
fn test_counter_path(name : String) -> String {
  "/tmp/choir-delivery-retry-" + name + ".count"
}

///|
fn test_sleep_path(name : String) -> String {
  "/tmp/choir-delivery-retry-" + name + ".sleep"
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
    Err(e) => fail("expected delivery success after retries: " + e)
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
    Err(e) => assert_true(e.contains("delivery command failed"))
  }
  assert_eq(read_counter(test_counter_path("failure")), 4)
  assert_eq(@sys.read_file(test_sleep_path("failure")), "1000\n2000\n4000\n")
}

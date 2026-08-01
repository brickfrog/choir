///|
fn closed_process_stdin_for_test() -> &@process.ProcessInput {
  let (reader, writer) = @process.write_to_process() catch {
    _ => abort("stdin pipe failed")
  }
  writer.close()
  reader
}

///|
fn bounded_process_test_environment() -> Map[String, String] {
  { "PATH": "/usr/bin:/bin" }
}

///|
async test "real exec integration: bounded process accepts empty output at a zero-byte cap" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let result = capture_bounded_process(
    "/usr/bin/printf",
    [""],
    bounded_process_test_environment(),
    closed_process_stdin_for_test(),
    "/tmp",
    5000,
    0,
    fn() { false },
  )
  assert_eq(result.unwrap(), NativeProcessCompleted(0, ""))
}

///|
async test "real exec integration: bounded process exceeds a zero-byte cap on the first byte" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let witnessed_pid = @ref.new(0)
  let outcome = capture_bounded_process(
    "/usr/bin/printf",
    ["x"],
    bounded_process_test_environment(),
    closed_process_stdin_for_test(),
    "/tmp",
    5000,
    0,
    fn() { false },
    started=fn(pid) {
      witnessed_pid.val = pid
      Ok(())
    },
  ).unwrap()
  assert_true(outcome is NativeProcessOutputExceeded(_))
  assert_false(@sys.pgid_has_non_zombie_process(witnessed_pid.val))
}

///|
async test "real exec integration: bounded process captures exact-limit output" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let outcome = capture_bounded_process(
    "/usr/bin/printf",
    ["hello"],
    bounded_process_test_environment(),
    closed_process_stdin_for_test(),
    "/tmp",
    5000,
    5,
    fn() { false },
  ).unwrap()
  assert_eq(outcome, NativeProcessCompleted(0, "hello"))
}

///|
async test "real exec integration: yes exceeds its cap and is reaped" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let witnessed_pid = @ref.new(0)
  let outcome = capture_bounded_process(
    "/usr/bin/yes",
    [],
    bounded_process_test_environment(),
    closed_process_stdin_for_test(),
    "/tmp",
    5000,
    4096,
    fn() { false },
    started=fn(pid) {
      witnessed_pid.val = pid
      Ok(())
    },
  ).unwrap()
  match outcome {
    NativeProcessOutputExceeded(tail) => assert_true(tail.length() <= 4096)
    _ => fail("expected output-exceeded outcome")
  }
  assert_true(witnessed_pid.val > 1)
  assert_false(@sys.pgid_has_non_zombie_process(witnessed_pid.val))
}

///|
async test "real exec integration: sleep interruption kills and reaps its group" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let probes = @ref.new(0)
  let witnessed_pid = @ref.new(0)
  let outcome = capture_bounded_process(
    "/usr/bin/sleep",
    ["30"],
    bounded_process_test_environment(),
    closed_process_stdin_for_test(),
    "/tmp",
    5000,
    4096,
    fn() {
      probes.val = probes.val + 1
      probes.val >= 2
    },
    started=fn(pid) {
      witnessed_pid.val = pid
      Ok(())
    },
  ).unwrap()
  assert_true(outcome is NativeProcessInterrupted(_))
  assert_false(@sys.pgid_has_non_zombie_process(witnessed_pid.val))
}

///|
async test "real exec integration: sleep timeout kills and reaps its group" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let witnessed_pid = @ref.new(0)
  let outcome = capture_bounded_process(
    "/usr/bin/sleep",
    ["30"],
    bounded_process_test_environment(),
    closed_process_stdin_for_test(),
    "/tmp",
    1000,
    4096,
    fn() { false },
    started=fn(pid) {
      witnessed_pid.val = pid
      Ok(())
    },
  ).unwrap()
  assert_true(outcome is NativeProcessTimedOut(_))
  assert_false(@sys.pgid_has_non_zombie_process(witnessed_pid.val))
}

///|
async test "real exec integration: interruption removes same-group descendants" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let probes = @ref.new(0)
  let witnessed_pid = @ref.new(0)
  let outcome = capture_bounded_process(
    "/bin/sh",
    ["-c", "/usr/bin/sleep 30 & wait"],
    bounded_process_test_environment(),
    closed_process_stdin_for_test(),
    "/tmp",
    5000,
    4096,
    fn() {
      probes.val = probes.val + 1
      probes.val >= 3
    },
    started=fn(pid) {
      witnessed_pid.val = pid
      Ok(())
    },
  ).unwrap()
  assert_true(outcome is NativeProcessInterrupted(_))
  assert_false(@sys.pgid_has_non_zombie_process(witnessed_pid.val))
}

///|
async test "real exec integration: a rejected start is still cleaned up" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let witnessed_pid = @ref.new(0)
  let result = capture_bounded_process(
    "/usr/bin/sleep",
    ["30"],
    bounded_process_test_environment(),
    closed_process_stdin_for_test(),
    "/tmp",
    5000,
    4096,
    fn() { false },
    started=fn(pid) {
      witnessed_pid.val = pid
      Err(@types.ChoirError::workspace_error("pid witness rejected"))
    },
  )
  assert_true(result is Err(_))
  assert_true(witnessed_pid.val > 1)
  assert_false(@sys.pgid_has_non_zombie_process(witnessed_pid.val))
}

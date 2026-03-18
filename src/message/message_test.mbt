///|
test "format message" {
  let msg = @message.format_message("main.worker-1", "done with research")
  assert_eq(msg, "[from: main.worker-1] done with research")
}

///|
test "format failure" {
  let msg = @message.format_failure("main.feature-a", "compilation error")
  assert_eq(msg, "[FAILED: main.feature-a] compilation error")
}

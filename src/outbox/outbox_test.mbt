///|
fn sample_outbox_message() -> OutboxMessage {
  let target = @types.LocalTarget::parse("zellij-pane:s:terminal_9").unwrap()
  OutboxMessage::new(
    "msg-1",
    "sender",
    "recipient",
    "hello",
    @types.Status::Success,
    @message.DeliveryMethod::LocalTerminalInput(target, "[from: sender] hello"),
    100L,
    200L,
  )
}

///|
test "load_recipient_outbox_from_content keeps latest snapshot per message id" {
  let first = sample_outbox_message()
  let second = first.record_failed_attempt(101L, "temporary failure")
  let content = build_outbox_snapshot_line(first) +
    "\nnot-json\n" +
    build_outbox_snapshot_line(second)
  let messages = load_recipient_outbox_from_content(content)
  assert_eq(messages.length(), 1)
  let message = messages[0]
  assert_eq(message.message_id, "msg-1")
  assert_eq(message.delivery_state, Pending)
  assert_eq(message.delivery_attempts, 1)
  @debug.assert_eq(message.last_attempt_at, Some(101L))
  @debug.assert_eq(message.last_error, Some("temporary failure"))
}

///|
test "compact_recipient_outbox rewrites latest snapshots only" {
  let project_dir = "/tmp/choir-outbox-compact-" +
    @sys.get_pid().to_string() +
    "-" +
    @types.sanitize_agent_id(@env.now().reinterpret_as_int64().to_string())
  let first = sample_outbox_message()
  let second = first.mark_delivered(120L)
  assert_true(append_outbox_snapshot(@sys.append_file_sync, project_dir, first))
  assert_true(
    append_outbox_snapshot(@sys.append_file_sync, project_dir, second),
  )
  assert_true(
    compact_recipient_outbox(
      @sys.read_file, @sys.write_file_atomic, project_dir, "recipient",
    ),
  )
  let content = @sys.read_file(recipient_outbox_path(project_dir, "recipient"))
  let mut nonempty_lines = 0
  for line in content.split("\n") {
    if line.to_owned().trim().to_owned() != "" {
      nonempty_lines = nonempty_lines + 1
    }
  }
  assert_eq(nonempty_lines, 1)
  let messages = load_recipient_outbox_from_content(content)
  assert_eq(messages.length(), 1)
  assert_eq(messages[0].delivery_state, Delivered)
  assert_eq(messages[0].delivery_attempts, 1)
}

///|
test "OutboxMessage is_actionable respects pending state and expiry" {
  let pending = sample_outbox_message()
  assert_true(pending.is_actionable(150L))
  assert_false(pending.is_actionable(200L))
  assert_false(pending.mark_delivered(150L).is_actionable(151L))
  assert_eq(pending.mark_expired().delivery_state, Expired)
}

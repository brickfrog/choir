///|
test "worker_no_handoff_decision emits stalled directly after threshold" {
  assert_eq(
    worker_no_handoff_decision(
      @types.Role::Worker,
      120L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::EmitStalled,
  )
}

///|
test "worker_no_handoff_decision skips once stalled was emitted" {
  assert_eq(
    worker_no_handoff_decision(
      @types.Role::Worker,
      121L,
      false,
      false,
      true,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
}

///|
test "worker_no_handoff_decision skips delivered workers" {
  assert_eq(
    worker_no_handoff_decision(
      @types.Role::Worker,
      999L,
      true,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
}

///|
test "worker_no_handoff_decision skips non-worker roles" {
  for role in [@types.Role::Root, @types.Role::TL, @types.Role::Dev] {
    assert_eq(
      worker_no_handoff_decision(role, 999L, false, false, false, 120L, 120L),
      WorkerNoHandoffDecision::DoNothing,
    )
  }
}

///|
test "worker_no_handoff_decision idle threshold zero disables path" {
  assert_eq(
    worker_no_handoff_decision(
      @types.Role::Worker,
      999L,
      false,
      false,
      false,
      0L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    worker_no_handoff_decision(
      @types.Role::Worker,
      999L,
      false,
      true,
      false,
      0L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
}

///|
test "worker_no_handoff_decision ignores removed escalate threshold" {
  assert_eq(
    worker_no_handoff_decision(
      @types.Role::Worker,
      999L,
      false,
      false,
      false,
      120L,
      0L,
    ),
    WorkerNoHandoffDecision::EmitStalled,
  )
}

///|
test "leaf_pre_tdd_stall_decision truth table" {
  let working = @phase.WorkflowState::Dev(@phase.DevLifecycle::Working)
  let review_owned = @phase.WorkflowState::Dev(
    @phase.DevLifecycle::ReviewOwned(
      pr_number=12,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
    ),
  )
  assert_eq(
    leaf_pre_tdd_stall_decision(
      @types.Role::Worker,
      working,
      None,
      999L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_pre_tdd_stall_decision(
      @types.Role::Dev,
      review_owned,
      None,
      999L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_pre_tdd_stall_decision(
      @types.Role::Dev,
      working,
      Some(@types.LeafTddPhase::Done),
      999L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_pre_tdd_stall_decision(
      @types.Role::Dev,
      working,
      None,
      119L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_pre_tdd_stall_decision(
      @types.Role::Dev,
      working,
      None,
      120L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::Prod,
  )
  assert_eq(
    leaf_pre_tdd_stall_decision(
      @types.Role::Dev,
      working,
      Some(@types.LeafTddPhase::Green),
      240L,
      false,
      true,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::EmitStalled,
  )
  assert_eq(
    leaf_pre_tdd_stall_decision(
      @types.Role::Dev,
      working,
      None,
      240L,
      false,
      true,
      true,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
}

///|
test "leaf_no_handoff_decision truth table" {
  let review_owned = @phase.WorkflowState::Dev(
    @phase.DevLifecycle::ReviewOwned(
      pr_number=12,
      state=@phase.ReviewOwnership::ApprovedAwaitingMerge,
    ),
  )
  let working = @phase.WorkflowState::Dev(@phase.DevLifecycle::Working)
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Worker,
      review_owned,
      true,
      999L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      working,
      true,
      999L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      review_owned,
      false,
      999L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      review_owned,
      true,
      119L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      review_owned,
      true,
      120L,
      false,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::EmitStalled,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      review_owned,
      true,
      239L,
      false,
      true,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::EmitStalled,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      review_owned,
      true,
      240L,
      false,
      true,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::EmitStalled,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      review_owned,
      true,
      240L,
      false,
      true,
      false,
      120L,
      0L,
    ),
    WorkerNoHandoffDecision::EmitStalled,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      review_owned,
      true,
      240L,
      true,
      false,
      false,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      review_owned,
      true,
      999L,
      false,
      false,
      false,
      0L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
  assert_eq(
    leaf_no_handoff_decision(
      @types.Role::Dev,
      review_owned,
      true,
      240L,
      false,
      true,
      true,
      120L,
      120L,
    ),
    WorkerNoHandoffDecision::DoNothing,
  )
}

///|
test "leaf no-handoff messages include fix-push headers and pane tail" {
  let pre_tdd_prod = leaf_pre_tdd_stall_prod_text
  assert_true(pre_tdd_prod.contains("tdd_intent"))
  assert_true(pre_tdd_prod.contains("file_pr"))
  assert_true(pre_tdd_prod.contains("notify_parent --status failure"))

  let pre_tdd_stalled = leaf_pre_tdd_stalled_parent_message(
    "leaf-a",
    240L,
    Some(@types.LeafTddPhase::Green),
    "line 1\nline 2",
  )
  assert_true(
    pre_tdd_stalled.contains("[LEAF STALLED BEFORE TDD/file_pr] leaf-a"),
  )
  assert_true(pre_tdd_stalled.contains("TDD phase is green"))
  assert_true(pre_tdd_stalled.contains("Pane tail:\nline 1\nline 2"))

  let prod = leaf_stalled_no_handoff_prod_message("leaf-a")
  assert_true(prod.contains("[LEAF POST-FIX-PUSH HANDOFF] leaf-a"))
  assert_true(prod.contains("notify_parent --status success"))
  assert_true(prod.contains("Do not idle waiting for more events"))

  let stalled = leaf_stalled_no_handoff_parent_message(
    "leaf-a", 240L, "line 1\nline 2",
  )
  assert_true(stalled.contains("[LEAF STALLED AFTER FIX-PUSH] leaf-a"))
  assert_true(stalled.contains("idle 240s"))
  assert_true(stalled.contains("Pane tail:\nline 1\nline 2"))
}

///|
test "worker no-handoff messages include event headers slug and tail" {
  let stalled = worker_stalled_no_handoff_message(
    "sarcasmotron", 240L, "line 1\nline 2",
  )
  assert_true(stalled.contains("[WORKER STALLED — no handoff] sarcasmotron"))
  assert_true(stalled.contains("idle 240s"))
  assert_true(stalled.contains("Pane tail:\nline 1\nline 2"))

  let exited = worker_exited_without_notify_message("sarcasmotron", "last")
  assert_true(exited.contains("[WORKER EXITED WITHOUT NOTIFY] sarcasmotron"))
  assert_true(exited.contains("exited/killed without calling notify_parent"))
  assert_true(exited.contains("Last pane:\nlast"))
}

///|
test "worker_no_handoff_pane_tail keeps last forty lines" {
  let lines : Array[String] = []
  for i = 0; i < 45; i = i + 1 {
    lines.push("line-" + i.to_string())
  }
  let tail = worker_no_handoff_pane_tail(lines.join("\n"))
  assert_false(tail.has_prefix("line-0"))
  assert_false(tail.has_prefix("line-4"))
  assert_true(tail.has_prefix("line-5\n"))
  assert_true(tail.contains("line-44"))
}

///|
test "worker_no_handoff_pane_tail caps long text" {
  let pieces : Array[String] = []
  for _i = 0; _i < 2100; _i = _i + 1 {
    pieces.push("x")
  }
  let screen = "prefix-" + pieces.join("")
  let tail = worker_no_handoff_pane_tail(screen)
  assert_eq(tail.length(), worker_no_handoff_tail_max_chars)
  assert_false(tail.contains("prefix"))
}

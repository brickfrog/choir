///|
fn hooks_test_gate_state_reader(enabled_at_unix : Int64) -> (String) -> String {
  fn(path : String) -> String {
    if path.has_suffix("/.choir/state/audit-gate.json") {
      "{\"enabled_at_unix\":" + enabled_at_unix.to_string() + "}\n"
    } else {
      ""
    }
  }
}

///|
fn hooks_test_gate_path_exists(path : String) -> Bool {
  path.has_suffix("/.choir/state/audit-gate.json")
}

///|
fn hooks_test_receipt_for_tree(
  tree_sha : String,
  findings_count : Int,
) -> String {
  let receipt : @types.AuditReceipt = {
    sha: "commit-sha",
    tree_sha,
    branch: "main",
    audited_at: 1L,
    agent_id: "main.tl",
    findings_count,
    findings: Some(""),
  }
  receipt.to_json().stringify() + "\n"
}

///|
async test "audit_receipt_advisory_state_for_tracked_pr maps gate and receipt states" {
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let tree = "9999999999999999999999999999999999999999"
  let other_tree = "1111111111111111111111111111111111111111"
  let not_required = audit_receipt_advisory_state_for_tracked_pr(
    "/repo",
    "feature/base",
    "main",
    head,
    100L,
    async fn(_) {
      @async.sleep(0)
      (1, "")
    },
    hooks_test_gate_state_reader(1L),
    hooks_test_gate_path_exists,
  )
  assert_eq(not_required, @types.AuditReceiptState::NotRequired)

  let gate_load_error = audit_receipt_advisory_state_for_tracked_pr(
    "/repo",
    "main",
    "main",
    head,
    100L,
    async fn(_) {
      @async.sleep(0)
      (1, "")
    },
    fn(_) { "" },
    fn(_) { false },
  )
  assert_eq(gate_load_error, @types.AuditReceiptState::Pending(head_sha=head))

  let grandfathered = audit_receipt_advisory_state_for_tracked_pr(
    "/repo",
    "main",
    "main",
    head,
    99L,
    async fn(_) {
      @async.sleep(0)
      (1, "")
    },
    hooks_test_gate_state_reader(100L),
    hooks_test_gate_path_exists,
  )
  assert_eq(grandfathered, @types.AuditReceiptState::NotRequired)

  let valid = audit_receipt_advisory_state_for_tracked_pr(
    "/repo",
    "main",
    "main",
    head,
    100L,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" {
        (0, tree + "\n")
      } else {
        (0, hooks_test_receipt_for_tree(tree, 0))
      }
    },
    hooks_test_gate_state_reader(1L),
    hooks_test_gate_path_exists,
  )
  assert_eq(valid, @types.AuditReceiptState::Valid)

  let findings = audit_receipt_advisory_state_for_tracked_pr(
    "/repo",
    "main",
    "main",
    head,
    100L,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" {
        (0, tree + "\n")
      } else {
        (0, hooks_test_receipt_for_tree(tree, 3))
      }
    },
    hooks_test_gate_state_reader(1L),
    hooks_test_gate_path_exists,
  )
  assert_eq(
    findings,
    @types.AuditReceiptState::FindingsRemain(
      head_sha=@tools.file_pr_short_sha(tree),
      count=3,
    ),
  )

  let missing = audit_receipt_advisory_state_for_tracked_pr(
    "/repo",
    "main",
    "main",
    head,
    100L,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" {
        (0, tree + "\n")
      } else {
        (1, "")
      }
    },
    hooks_test_gate_state_reader(1L),
    hooks_test_gate_path_exists,
  )
  assert_eq(
    missing,
    @types.AuditReceiptState::Pending(head_sha=@tools.file_pr_short_sha(tree)),
  )

  let invalid = audit_receipt_advisory_state_for_tracked_pr(
    "/repo",
    "main",
    "main",
    head,
    100L,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" {
        (0, tree + "\n")
      } else {
        (0, "{not json")
      }
    },
    hooks_test_gate_state_reader(1L),
    hooks_test_gate_path_exists,
  )
  assert_eq(
    invalid,
    @types.AuditReceiptState::Pending(head_sha=@tools.file_pr_short_sha(tree)),
  )

  let stale = audit_receipt_advisory_state_for_tracked_pr(
    "/repo",
    "main",
    "main",
    head,
    100L,
    async fn(cmd : @workspace.Command) -> (Int, String) {
      @async.sleep(0)
      if cmd.program == "git" {
        (0, tree + "\n")
      } else {
        (0, hooks_test_receipt_for_tree(other_tree, 0))
      }
    },
    hooks_test_gate_state_reader(1L),
    hooks_test_gate_path_exists,
  )
  assert_eq(stale, @types.AuditReceiptState::Pending(head_sha=tree))

  let tree_unavailable = audit_receipt_advisory_state_for_tracked_pr(
    "/repo",
    "main",
    "main",
    head,
    100L,
    async fn(_) {
      @async.sleep(0)
      (1, "")
    },
    hooks_test_gate_state_reader(1L),
    hooks_test_gate_path_exists,
  )
  assert_eq(
    tree_unavailable,
    @types.AuditReceiptState::Pending(head_sha=@tools.file_pr_short_sha(head)),
  )
}

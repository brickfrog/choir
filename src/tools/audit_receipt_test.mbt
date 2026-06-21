///|
test "plan_write_audit_receipt emits typed JSON payload" {
  let sha = "abcdef1234567890abcdef1234567890abcdef12"
  let tree_sha = "9999999999999999999999999999999999999999"
  let plan = plan_write_audit_receipt(
    {
      caller_id: "main.tl",
      sha,
      tree_sha,
      branch: "feature/workflow-gates",
      findings_count: 0,
      findings: "",
    },
    1770000000L,
  ).unwrap()
  assert_eq(plan.path, ".choir/state/audit-receipts/999999999999.json")
  let decoded : @types.AuditReceipt = @json.from_json(
    @json.parse(plan.content) catch {
      _ => {
        fail("receipt JSON did not parse")
        return
      }
    },
  ) catch {
    _ => {
      fail("receipt JSON did not decode")
      return
    }
  }
  @debug.assert_eq(decoded, plan.receipt)
  assert_eq(decoded.sha, sha)
  assert_eq(decoded.tree_sha, tree_sha)
  assert_eq(decoded.findings_count, 0)
}

///|
test "plan_write_audit_receipt trims identity fields before writing" {
  let plan = plan_write_audit_receipt(
    {
      caller_id: " main.tl ",
      sha: " abcdef1234567890abcdef1234567890abcdef12 ",
      tree_sha: " 9999999999999999999999999999999999999999 ",
      branch: " feature/workflow-gates ",
      findings_count: 0,
      findings: "",
    },
    1770000000L,
  ).unwrap()
  assert_eq(plan.path, ".choir/state/audit-receipts/999999999999.json")
  assert_eq(plan.receipt.sha, "abcdef1234567890abcdef1234567890abcdef12")
  assert_eq(plan.receipt.tree_sha, "9999999999999999999999999999999999999999")
  assert_eq(plan.receipt.branch, "feature/workflow-gates")
  assert_eq(plan.receipt.agent_id, "main.tl")
}

///|
test "interpret_write_audit_receipt writes typed receipt through injected fs" {
  let writes : Array[(String, String)] = []
  let mut mkdir_path = ""
  let resp = interpret_write_audit_receipt(
    {
      caller_id: "main.tl",
      sha: "fedcba654321fedcba654321fedcba654321fedc",
      tree_sha: "1111111111111111111111111111111111111111",
      branch: "feature/workflow-gates",
      findings_count: 2,
      findings: "Finding 1: keep this visible",
    },
    "/repo",
    fn(path) {
      mkdir_path = path
      true
    },
    fn(path, content) {
      writes.push((path, content))
      true
    },
    now_sec=fn() { 1770000001L },
  )
  match resp {
    @types.Response::Ok(fields) => {
      let map = fields.to_json_map()
      @debug.assert_eq(map.get("status"), Some("ok".to_json()))
      @debug.assert_eq(
        map.get("path"),
        Some(".choir/state/audit-receipts/111111111111.json".to_json()),
      )
      @debug.assert_eq(
        map.get("tree_sha"),
        Some("1111111111111111111111111111111111111111".to_json()),
      )
      @debug.assert_eq(map.get("findings_count"), Some(Int::to_json(2)))
    }
    @types.Response::Err(msg) => fail("expected write response: " + msg)
  }
  assert_eq(mkdir_path, "/repo/.choir/state/audit-receipts")
  assert_eq(writes.length(), 1)
  let (path, content) = writes[0]
  assert_eq(path, "/repo/.choir/state/audit-receipts/111111111111.json")
  let decoded : @types.AuditReceipt = @json.from_json(
    @json.parse(content) catch {
      _ => {
        fail("written receipt JSON did not parse")
        return
      }
    },
  ) catch {
    _ => {
      fail("written receipt JSON did not decode")
      return
    }
  }
  assert_eq(decoded.agent_id, "main.tl")
  assert_eq(decoded.sha, "fedcba654321fedcba654321fedcba654321fedc")
  assert_eq(decoded.tree_sha, "1111111111111111111111111111111111111111")
  assert_eq(decoded.findings_count, 2)
  @debug.assert_eq(decoded.findings, Some("Finding 1: keep this visible"))
}

///|
async test "dispatch write_audit_receipt routes injected filesystem capabilities" {
  let writes : Array[(String, String)] = []
  let dirs : Array[String] = []
  let resp = dispatch(
    ToolRequest::WriteAuditReceipt({
      caller_id: "main.tl",
      sha: "abcdef1234567890abcdef1234567890abcdef12",
      tree_sha: "9999999999999999999999999999999999999999",
      branch: "feature/dispatch",
      findings_count: 0,
      findings: "",
    }),
    project_dir="/repo",
    create_dir_all=fn(path) {
      dirs.push(path)
      true
    },
    write_file_atomic=fn(path, content) {
      writes.push((path, content))
      true
    },
  )
  match resp {
    @types.Response::Ok(_) => ()
    @types.Response::Err(msg) => fail("expected dispatch success: " + msg)
  }
  @debug.assert_eq(dirs, ["/repo/.choir/state/audit-receipts"])
  assert_eq(writes.length(), 1)
  let (path, content) = writes[0]
  assert_eq(path, "/repo/.choir/state/audit-receipts/999999999999.json")
  assert_true(
    content.contains(
      "\"tree_sha\":\"9999999999999999999999999999999999999999\"",
    ),
  )
  assert_true(content.contains("\"findings_count\":0"))
}

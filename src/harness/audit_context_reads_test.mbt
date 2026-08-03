///|
test "retained Claude pages preserve exact audit context coverage" {
  let digest = "a".repeat(64)
  let first_page = "{\"digest\":\"" +
    digest +
    "\",\"cursor\":0,\"total\":200000,\"content\":\"x\",\"next_cursor\":131072,\"eof\":false}"
  let last_page = "{\"digest\":\"" +
    digest +
    "\",\"cursor\":131072,\"total\":200000,\"content\":\"y\",\"next_cursor\":null,\"eof\":true}"
  let output = [
    "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"r1\",\"name\":\"mcp__choir_sandbox__read_audit_context\",\"input\":{\"digest\":\"" +
    digest +
    "\",\"cursor\":0}}]}}",
    "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"r1\",\"content\":" +
    first_page.to_json().stringify() +
    "}]}}",
    "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"r2\",\"name\":\"mcp__choir_sandbox__read_audit_context\",\"input\":{\"digest\":\"" +
    digest +
    "\",\"cursor\":131072}}]}}",
    "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"r2\",\"content\":" +
    last_page.to_json().stringify() +
    "}]}}",
  ].join("\n")
  let retained = @harness.retained_audit_context_reads_by_execution(output)
  assert_eq(retained.length(), 2)
  assert_eq(
    @control.validate_audit_context_read_coverage(@control.Digest(digest), [
      retained["r1"],
      retained["r2"],
    ]).unwrap(),
    200000,
  )
}

///|
test "retained pages preserve a stale response as a failed read" {
  let digest = "b".repeat(64)
  let stale = "c".repeat(64)
  let output = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"r1\",\"name\":\"mcp__choir_sandbox__read_audit_context\",\"input\":{\"digest\":\"" +
    digest +
    "\",\"cursor\":0}}]}}\n" +
    "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"r1\",\"content\":\"{\\\"digest\\\":\\\"" +
    stale +
    "\\\",\\\"cursor\\\":0,\\\"total\\\":0,\\\"next_cursor\\\":null,\\\"eof\\\":true}\"}]}}"
  let retained = @harness.retained_audit_context_reads_by_execution(output)
  assert_eq(retained.length(), 1)
  assert_false(retained["r1"].succeeded)
  assert_true(
    @control.validate_audit_context_read_coverage(@control.Digest(digest), [
      retained["r1"],
    ])
    is Err(_),
  )
}

///|
test "a failed Claude read cannot satisfy coverage with valid-looking content" {
  let digest = "d".repeat(64)
  let page = "{\"digest\":\"" +
    digest +
    "\",\"cursor\":0,\"total\":0,\"next_cursor\":null,\"eof\":true}"
  let output = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"r1\",\"name\":\"mcp__choir_sandbox__read_audit_context\",\"input\":{\"digest\":\"" +
    digest +
    "\",\"cursor\":0}}]}}\n" +
    "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"r1\",\"content\":" +
    page.to_json().stringify() +
    ",\"is_error\":true}]}}"
  let retained = @harness.retained_audit_context_reads_by_execution(output)
  assert_eq(retained.length(), 0)
  assert_true(
    @control.validate_audit_context_read_coverage(
      @control.Digest(digest),
      retained.values().collect(),
    )
    is Err(_),
  )
}

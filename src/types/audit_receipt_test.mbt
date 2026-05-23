///|
test "AuditReceipt JSON round trip" {
  let receipt : AuditReceipt = {
    sha: "abcdef1234567890abcdef1234567890abcdef12",
    branch: "feature/workflow-gates",
    audited_at: 1770000000L,
    agent_id: "main.tl",
    findings_count: 0,
    findings: Some(""),
  }
  let encoded = receipt.to_json().stringify()
  let parsed = @json.parse(encoded) catch {
    _ => {
      fail("encoded AuditReceipt did not parse")
      return
    }
  }
  let decoded : AuditReceipt = @json.from_json(parsed) catch {
    _ => {
      fail("encoded AuditReceipt did not decode")
      return
    }
  }
  @debug.assert_eq(decoded, receipt)
}

///|
test "AuditReceipt JSON decodes legacy receipt without findings body" {
  let body = "{" +
    "\"sha\":\"abcdef1234567890abcdef1234567890abcdef12\"," +
    "\"branch\":\"feature/workflow-gates\"," +
    "\"audited_at\":1770000000," +
    "\"agent_id\":\"main.tl\"," +
    "\"findings_count\":0" +
    "}"
  let parsed = @json.parse(body) catch {
    _ => {
      fail("legacy receipt JSON did not parse")
      return
    }
  }
  let decoded : AuditReceipt = @json.from_json(parsed) catch {
    _ => {
      fail("legacy receipt JSON did not decode")
      return
    }
  }
  assert_eq(decoded.sha, "abcdef1234567890abcdef1234567890abcdef12")
  assert_eq(decoded.branch, "feature/workflow-gates")
  assert_eq(decoded.audited_at, 1770000000L)
  assert_eq(decoded.agent_id, "main.tl")
  assert_eq(decoded.findings_count, 0)
  @debug.assert_eq(decoded.findings, None)
}

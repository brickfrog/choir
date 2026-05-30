///|
test "AuditReceipt JSON round trip" {
  let receipt : AuditReceipt = {
    sha: "abcdef1234567890abcdef1234567890abcdef12",
    tree_sha: "9999999999999999999999999999999999999999",
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
test "AuditReceipt JSON rejects receipt without tree sha" {
  let body = "{" +
    "\"sha\":\"abcdef1234567890abcdef1234567890abcdef12\"," +
    "\"branch\":\"feature/workflow-gates\"," +
    "\"audited_at\":1770000000," +
    "\"agent_id\":\"main.tl\"," +
    "\"findings_count\":0" +
    "}"
  let parsed = @json.parse(body) catch {
    _ => {
      fail("receipt JSON did not parse")
      return
    }
  }
  let _decoded : AuditReceipt = @json.from_json(parsed) catch { _ => return }
  fail("receipt without tree_sha should not decode")
}

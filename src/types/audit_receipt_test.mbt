///|
test "AuditReceipt JSON round trip" {
  let receipt : AuditReceipt = {
    sha: "abcdef1234567890abcdef1234567890abcdef12",
    branch: "feature/workflow-gates",
    audited_at: 1770000000L,
    agent_id: "main.tl",
    findings_count: 0,
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

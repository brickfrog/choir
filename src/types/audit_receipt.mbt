///|
pub(all) struct AuditReceipt {
  sha : String
  branch : String
  audited_at : Int64
  agent_id : String
  findings_count : Int
  findings : String?
} derive(Debug, Eq, ToJson)

///|
pub impl FromJson for AuditReceipt with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError(
      (path, "AuditReceipt::from_json: expected object"),
    )
  }
  let sha = match json_field_string(fields, "sha") {
    Some(value) => value
    None =>
      raise @json.JsonDecodeError(
        (path.add_key("sha"), "AuditReceipt::from_json: missing field sha"),
      )
  }
  let branch = match json_field_string(fields, "branch") {
    Some(value) => value
    None =>
      raise @json.JsonDecodeError(
        (
          path.add_key("branch"),
          "AuditReceipt::from_json: missing field branch",
        ),
      )
  }
  let audited_at = match json_field_int64(fields, "audited_at") {
    Some(value) => value
    None =>
      raise @json.JsonDecodeError(
        (
          path.add_key("audited_at"),
          "AuditReceipt::from_json: missing field audited_at",
        ),
      )
  }
  let agent_id = match json_field_string(fields, "agent_id") {
    Some(value) => value
    None =>
      raise @json.JsonDecodeError(
        (
          path.add_key("agent_id"),
          "AuditReceipt::from_json: missing field agent_id",
        ),
      )
  }
  let findings_count = match json_field_int(fields, "findings_count") {
    Some(value) => value
    None =>
      raise @json.JsonDecodeError(
        (
          path.add_key("findings_count"),
          "AuditReceipt::from_json: missing field findings_count",
        ),
      )
  }
  let findings = json_field_string(fields, "findings")
  { sha, branch, audited_at, agent_id, findings_count, findings }
}

///|
pub(all) struct AuditReceipt {
  sha : String
  branch : String
  audited_at : Int64
  agent_id : String
  findings_count : Int
  findings : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AuditReceipt {
  sha : String
  branch : String
  audited_at : Int64
  agent_id : String
  findings_count : Int
} derive(Debug, Eq, ToJson, FromJson)

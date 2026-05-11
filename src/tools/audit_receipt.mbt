///|
pub(all) struct AuditReceiptWritePlan {
  path : String
  receipt : @types.AuditReceipt
  content : String
} derive(Debug, Eq)

///|

///|
/// Validate that `sha` looks like a git SHA — lowercase hex of length 40
/// (SHA-1) or 64 (SHA-256). This is a defense against path traversal in
/// `file_pr_audit_receipt_path_for_head` which derives the on-disk file
/// name from the sha; an unvalidated `../../etc/foo` would escape the
/// `.choir/audit-receipts/` directory with a forced .json suffix.
fn audit_receipt_validate_sha_format(sha : String) -> Bool {
  if sha.length() != 40 && sha.length() != 64 {
    return false
  }
  for i = 0; i < sha.length(); i = i + 1 {
    let c = sha[i]
    let is_digit = c >= '0' && c <= '9'
    let is_lower_hex = c >= 'a' && c <= 'f'
    if !is_digit && !is_lower_hex {
      return false
    }
  }
  true
}

///|
pub fn plan_write_audit_receipt(
  args : WriteAuditReceiptArgs,
  audited_at : Int64,
) -> Result[AuditReceiptWritePlan, @types.ChoirError] {
  let sha = args.sha.trim().to_owned()
  let branch = args.branch.trim().to_owned()
  let caller_id = args.caller_id.trim().to_owned()
  if sha == "" {
    return Err(@types.ChoirError::validation_error("sha cannot be empty"))
  }
  if !audit_receipt_validate_sha_format(sha) {
    return Err(
      @types.ChoirError::validation_error(
        "sha must be a lowercase-hex git SHA (40 or 64 chars); got " +
        sha.length().to_string() +
        " chars",
      ),
    )
  }
  if branch == "" {
    return Err(@types.ChoirError::validation_error("branch cannot be empty"))
  }
  if caller_id == "" {
    return Err(@types.ChoirError::validation_error("caller_id cannot be empty"))
  }
  if audited_at <= 0L {
    return Err(
      @types.ChoirError::validation_error("audited_at must be positive"),
    )
  }
  if args.findings_count < 0 {
    return Err(
      @types.ChoirError::validation_error(
        "findings_count must be zero or positive",
      ),
    )
  }
  let path = file_pr_audit_receipt_path_for_head(sha)
  let receipt : @types.AuditReceipt = {
    sha,
    branch,
    audited_at,
    agent_id: caller_id,
    findings_count: args.findings_count,
  }
  Ok({ path, receipt, content: receipt.to_json().stringify() + "\n" })
}

///|
pub fn interpret_write_audit_receipt(
  args : WriteAuditReceiptArgs,
  project_dir : String,
  create_dir_all : (String) -> Bool,
  fs_writer : (String, String) -> Bool,
  now_sec? : () -> Int64 = @poller.now_sec,
) -> @types.Response {
  let plan = match plan_write_audit_receipt(args, now_sec()) {
    Ok(p) => p
    Err(e) => return @types.Response::Err(e.message())
  }
  let receipts_dir = project_dir + "/.choir/audit-receipts"
  if !create_dir_all(receipts_dir) {
    return @types.Response::Err(
      "failed to create audit receipt directory: .choir/audit-receipts",
    )
  }
  if !fs_writer(project_dir + "/" + plan.path, plan.content) {
    return @types.Response::Err("failed to write audit receipt: " + plan.path)
  }
  @types.Response::ok_values({
    "status": "ok".to_json(),
    "path": plan.path.to_json(),
    "sha": plan.receipt.sha.to_json(),
    "findings_count": plan.receipt.findings_count.to_json(),
  })
}

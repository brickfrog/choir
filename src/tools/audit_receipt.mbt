///|
pub(all) struct AuditReceiptWritePlan {
  path : String
  receipt : @types.AuditReceipt
  content : String
} derive(Debug, Eq)

///|
pub fn plan_write_audit_receipt(
  args : WriteAuditReceiptArgs,
  audited_at : Int64,
) -> Result[AuditReceiptWritePlan, @types.ChoirError] {
  if args.sha.trim() == "" {
    return Err(@types.ChoirError::validation_error("sha cannot be empty"))
  }
  if args.branch.trim() == "" {
    return Err(@types.ChoirError::validation_error("branch cannot be empty"))
  }
  if args.caller_id.trim() == "" {
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
  let receipt : @types.AuditReceipt = {
    sha: args.sha,
    branch: args.branch,
    audited_at,
    agent_id: args.caller_id,
    findings_count: args.findings_count,
  }
  let path = file_pr_audit_receipt_path_for_head(args.sha)
  Ok({ path, receipt, content: receipt.to_json().stringify() + "\n" })
}

///|
fn write_audit_receipt_default_create_dir(path : String) -> Bool {
  @sys.create_dir_all(path)
}

///|
fn write_audit_receipt_default_writer(path : String, content : String) -> Bool {
  @sys.write_file_atomic(path, content)
}

///|
pub fn interpret_write_audit_receipt(
  args : WriteAuditReceiptArgs,
  project_dir : String,
  now_sec? : () -> Int64 = @poller.now_sec,
  create_dir_all? : (String) -> Bool = write_audit_receipt_default_create_dir,
  fs_writer? : (String, String) -> Bool = write_audit_receipt_default_writer,
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

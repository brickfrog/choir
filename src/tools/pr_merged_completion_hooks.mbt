///|
pub(all) enum AuditEnforcementOutcome {
  Audited
  UnauditedBlocked
  UnauditedWarned
  NotApplicable
} derive(Debug, Eq)

///|
pub fn pr_merged_completion_hook_input(
  event : @hooks.HookEvent,
  pr : @poller.TrackedPR,
) -> @hooks.HookInput {
  {
    event,
    session_id: None,
    agent_id: Some(pr.agent_id),
    pr_number: Some(pr.pr_number),
    pr_url: Some(pr.pr_url),
    branch: Some(pr.branch),
    parent_branch: Some(pr.parent_branch),
    merge_provenance: Some("external_observation"),
    role: None,
    tool_name: None,
    tool_args: None,
    tool_result_status: None,
    exit_reason: None,
    suspend_reason: None,
  }
}

///|
fn parse_detected_default_branch(output : String) -> String? {
  let trimmed = output.trim().to_owned()
  let prefix = "origin/"
  if trimmed.has_prefix(prefix) {
    let branch = trimmed[prefix.length():].to_owned()
    if branch == "" {
      None
    } else {
      Some(branch)
    }
  } else if trimmed == "" {
    None
  } else {
    Some(trimmed)
  }
}

///|
pub async fn detect_default_branch_for_wave_complete(
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> String? {
  let cmd : @workspace.Command = {
    program: "git",
    args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
    workdir: Some(project_dir),
  }
  let (exit_code, output) = capture(cmd)
  if exit_code == 0 {
    parse_detected_default_branch(output)
  } else {
    None
  }
}

///|
async fn pr_merged_parent_branch_is_wave_complete(
  project_dir : String,
  parent_branch : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  pr_merged_default_branch_for_wave_complete(
    project_dir, parent_branch, capture,
  )
  is Some(_)
}

///|
pub async fn pr_merged_default_branch_for_wave_complete(
  project_dir : String,
  parent_branch : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> String? {
  if parent_branch == "" {
    return None
  }
  match detect_default_branch_for_wave_complete(project_dir, capture) {
    Some(default_branch) =>
      if parent_branch == default_branch {
        Some(default_branch)
      } else {
        None
      }
    None =>
      if parent_branch == "main" || parent_branch == "master" {
        Some(parent_branch)
      } else {
        None
      }
  }
}

///|
pub fn project_relative_path(project_dir : String, rel_path : String) -> String {
  if project_dir == "" || project_dir == "." {
    rel_path
  } else {
    project_dir + "/" + rel_path
  }
}

///|
pub fn detect_unaudited_integration_merge(
  receipt_path : String,
  file_exists : (String) -> Bool,
  require_audit : Bool,
) -> AuditEnforcementOutcome {
  if receipt_path == "" {
    return AuditEnforcementOutcome::NotApplicable
  }
  if file_exists(receipt_path) {
    AuditEnforcementOutcome::Audited
  } else if require_audit {
    AuditEnforcementOutcome::UnauditedBlocked
  } else {
    AuditEnforcementOutcome::UnauditedWarned
  }
}

///|
pub fn audit_enforcement_allows_auto_pull(
  outcome : AuditEnforcementOutcome,
) -> Bool {
  match outcome {
    UnauditedBlocked => false
    Audited | UnauditedWarned | NotApplicable => true
  }
}

///|
pub fn valid_merge_audit_receipt_exists(
  receipt_path : String,
  default_branch : String,
  head_sha : String,
  audit_receipt_exists : (String) -> Bool,
  audit_receipt_read : (String) -> String,
) -> Bool {
  if default_branch == "" || !audit_receipt_exists(receipt_path) {
    return false
  }
  let body = audit_receipt_read(receipt_path)
  match merge_pr_required_audit_receipt_validation(head_sha, Some(body)) {
    MergePrAuditReceiptValidation::MergeAuditReceiptValid => true
    _ => false
  }
}

///|
pub async fn detect_pr_merged_audit_enforcement(
  project_dir : String,
  require_integration_audit : Bool,
  pr : @poller.TrackedPR,
  capture : async (@workspace.Command) -> (Int, String),
  audit_receipt_exists : (String) -> Bool,
  audit_receipt_read : (String) -> String,
) -> AuditEnforcementOutcome {
  let default_branch = match
    pr_merged_default_branch_for_wave_complete(
      project_dir,
      pr.parent_branch,
      capture,
    ) {
    Some(branch) => branch
    None => return AuditEnforcementOutcome::NotApplicable
  }
  let head_sha = pr.last_sha.trim().to_owned()
  // AUDIT: Empty-SHA fail-closed is gated behind confirmed integration merge default_branch resolution.
  if head_sha == "" {
    if require_integration_audit {
      return AuditEnforcementOutcome::UnauditedBlocked
    }
    return AuditEnforcementOutcome::UnauditedWarned
  }
  let receipt_rel_path = file_pr_audit_receipt_path_for_head(head_sha)
  let receipt_path = project_relative_path(project_dir, receipt_rel_path)
  let receipt_is_valid = valid_merge_audit_receipt_exists(
    receipt_path, default_branch, head_sha, audit_receipt_exists, audit_receipt_read,
  )
  let outcome = detect_unaudited_integration_merge(
    receipt_path,
    fn(path) { path == receipt_path && receipt_is_valid },
    require_integration_audit,
  )
  outcome
}

///|
pub async fn fire_pr_merged_completion_hooks(
  project_dir : String,
  pr : @poller.TrackedPR,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  hook_capture? : async (String, String, String?) -> (Int, String) = @exec.capture_hook_script_merged,
  path_exists? : (String) -> Bool = @exec.path_entry_exists,
  xdg_config_home? : String? = @exec.hook_xdg_config_home(),
  home? : String = @exec.hook_home(),
) -> Unit {
  if @hooks.resolve_hook_script_path(
      project_dir,
      @hooks.HookEvent::PrMerged.script_name(),
      xdg_config_home,
      home,
      path_exists,
    )
    is Some(_) {
    fire_hook_async(
      @hooks.HookEvent::PrMerged,
      pr_merged_completion_hook_input(@hooks.HookEvent::PrMerged, pr),
      project_dir,
      hook_capture~,
      path_exists~,
      xdg_config_home~,
      home~,
    ) catch {
      _ => ()
    }
  }
  if @hooks.resolve_hook_script_path(
      project_dir,
      @hooks.HookEvent::WaveComplete.script_name(),
      xdg_config_home,
      home,
      path_exists,
    )
    is Some(_) {
    let is_wave_complete = pr_merged_parent_branch_is_wave_complete(
      project_dir,
      pr.parent_branch,
      capture,
    ) catch {
      _ => false
    }
    if !is_wave_complete {
      return
    }
    fire_hook_async(
      @hooks.HookEvent::WaveComplete,
      pr_merged_completion_hook_input(@hooks.HookEvent::WaveComplete, pr),
      project_dir,
      hook_capture~,
      path_exists~,
      xdg_config_home~,
      home~,
    ) catch {
      _ => ()
    }
  }
}

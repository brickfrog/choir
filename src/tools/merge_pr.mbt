///|
/// Ordered host-side steps for `merge_pr` preflight (poller read is synchronous;
/// thread fetch uses `capture`). Matches `interpret_merge_pr_preflight`.
pub(all) enum MergePrPreflightHostStep {
  PollerSnapshot
  FetchUnresolvedReviewThreads
} derive(Debug, Eq)

///|
pub fn merge_pr_preflight_host_steps() -> Array[MergePrPreflightHostStep] {
  [
    MergePrPreflightHostStep::PollerSnapshot,
    MergePrPreflightHostStep::FetchUnresolvedReviewThreads,
  ]
}

///|
pub(all) enum MergePrAuditReceiptValidation {
  MergeAuditReceiptValid
  MergeAuditReceiptMissing(String)
  MergeAuditReceiptInvalid(String)
  MergeAuditReceiptStale(String, String)
  MergeAuditReceiptFindingsRemain(String, Int)
} derive(Debug, Eq)

///|
pub(all) enum MergePrAuditGateStatus {
  MergeAuditGateReceiptBlocked(MergePrAuditReceiptValidation)
  MergeAuditGateHeadUnavailable
} derive(Debug, Eq)

///|
fn merge_pr_parse_audit_receipt(receipt_body : String) -> @types.AuditReceipt? {
  let parsed = @json.parse(receipt_body.trim().to_owned()) catch {
    _ => return None
  }
  let receipt : @types.AuditReceipt = @json.from_json(parsed) catch {
    _ => return None
  }
  if receipt.sha == "" ||
    receipt.branch == "" ||
    receipt.audited_at <= 0L ||
    receipt.agent_id == "" ||
    receipt.findings_count < 0 {
    return None
  }
  Some(receipt)
}

///|
fn MergePrAuditGateStatus::to_wire_string(
  self : MergePrAuditGateStatus,
) -> String {
  match self {
    MergeAuditGateReceiptBlocked(validation) =>
      match validation {
        MergeAuditReceiptValid => "pass"
        MergeAuditReceiptMissing(_) => "receipt_missing"
        MergeAuditReceiptInvalid(_) => "receipt_invalid"
        MergeAuditReceiptStale(_, _) => "receipt_stale"
        MergeAuditReceiptFindingsRemain(_, _) => "receipt_findings_remain"
      }
    MergeAuditGateHeadUnavailable => "head_unavailable"
  }
}

///|
pub fn merge_pr_audit_receipt_validation(
  parent_branch : String,
  current_head : String,
  receipt_body : String?,
) -> MergePrAuditReceiptValidation {
  if !file_pr_audit_receipt_required(parent_branch) {
    return MergeAuditReceiptValid
  }
  merge_pr_required_audit_receipt_validation(current_head, receipt_body)
}

///|
pub fn merge_pr_required_audit_receipt_validation(
  current_head : String,
  receipt_body : String?,
) -> MergePrAuditReceiptValidation {
  let short_sha = file_pr_short_sha(current_head)
  let receipt = match receipt_body {
    Some(body) if body.trim() != "" => body
    _ => return MergeAuditReceiptMissing(short_sha)
  }
  match merge_pr_parse_audit_receipt(receipt) {
    Some(parsed) if parsed.sha == current_head =>
      if parsed.findings_count == 0 {
        MergeAuditReceiptValid
      } else {
        MergeAuditReceiptFindingsRemain(short_sha, parsed.findings_count)
      }
    Some(parsed) => MergeAuditReceiptStale(parsed.sha, current_head)
    None => MergeAuditReceiptInvalid(short_sha)
  }
}

///|
fn merge_pr_audit_receipt_validation_summary(
  validation : MergePrAuditReceiptValidation,
) -> String {
  match validation {
    MergeAuditReceiptValid => "valid audit receipt"
    MergeAuditReceiptMissing(short_sha) =>
      "missing audit receipt for HEAD " + short_sha
    MergeAuditReceiptInvalid(short_sha) =>
      "malformed audit receipt for HEAD " + short_sha
    MergeAuditReceiptStale(audited_sha, current_sha) =>
      "stale audit receipt (audit ran on " +
      audited_sha +
      ", current HEAD is " +
      current_sha +
      ")"
    MergeAuditReceiptFindingsRemain(short_sha, count) =>
      "audit receipt for HEAD " +
      short_sha +
      " reports " +
      count.to_string() +
      " finding(s)"
  }
}

///|
pub fn merge_pr_audit_gate_policy_block_message(
  pr_number : Int,
  status : MergePrAuditGateStatus,
) -> String? {
  match status {
    MergeAuditGateHeadUnavailable =>
      Some(
        "policy blocked: audit receipt gate cannot determine PR #" +
        pr_number.to_string() +
        " head SHA from tracked poller state. Wait for a poller snapshot with last_sha before merging.",
      )
    MergeAuditGateReceiptBlocked(MergeAuditReceiptValid) => None
    MergeAuditGateReceiptBlocked(validation) => {
      let summary = merge_pr_audit_receipt_validation_summary(validation)
      Some(
        "policy blocked: audit receipt gate blocked PR #" +
        pr_number.to_string() +
        ": " +
        summary +
        ". Run `/audit` until findings_count == 0, then retry merge_pr.",
      )
    }
  }
}

///|
pub fn parse_github_owner_repo_from_url(raw : String) -> (String, String)? {
  let value = raw.trim().to_owned()
  let mut path = if value.has_prefix("https://github.com/") {
    value["https://github.com/".length():].to_owned()
  } else if value.has_prefix("http://github.com/") {
    value["http://github.com/".length():].to_owned()
  } else if value.has_prefix("git@github.com:") {
    value["git@github.com:".length():].to_owned()
  } else if value.has_prefix("ssh://git@github.com/") {
    value["ssh://git@github.com/".length():].to_owned()
  } else {
    return None
  }
  if path.has_suffix(".git") {
    path = path[:path.length() - ".git".length()].to_owned()
  }
  let parts = []
  for part in path.split("/") {
    parts.push(part.to_owned())
  }
  if parts.length() < 2 {
    return None
  }
  let owner = parts[0]
  let repo = parts[1]
  if owner == "" || repo == "" {
    None
  } else {
    Some((owner, repo))
  }
}

///|
fn merge_pr_owner_repo_from_tracked(
  poller_state : @poller.PollerState?,
  pr_number : Int,
) -> (String, String)? {
  match poller_state {
    Some(ps) =>
      match ps.get(pr_number) {
        Some(tracked) => parse_github_owner_repo_from_url(tracked.pr_url)
        None => None
      }
    None => None
  }
}

///|
async fn merge_pr_owner_repo(
  pr_number : Int,
  poller_state : @poller.PollerState?,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[(String, String), @types.ChoirError] {
  match merge_pr_owner_repo_from_tracked(poller_state, pr_number) {
    Some(pair) => Ok(pair)
    None => {
      let cmd : @workspace.Command = {
        program: "git",
        args: ["remote", "get-url", "origin"],
        workdir: Some(project_dir),
      }
      let (exit_code, output) = capture(cmd)
      if exit_code != 0 || output.trim().to_owned() == "" {
        return Err(
          @types.ChoirError::validation_error(
            "merge blocked: could not resolve GitHub repository owner/name from tracked PR URL or origin remote",
          ),
        )
      }
      match parse_github_owner_repo_from_url(output) {
        Some(pair) => Ok(pair)
        None =>
          Err(
            @types.ChoirError::validation_error(
              "merge blocked: origin remote is not a GitHub repository URL",
            ),
          )
      }
    }
  }
}

///|
pub fn merge_pr_reviews_command(
  owner : String,
  repo : String,
  pr_number : Int,
  project_dir : String,
) -> @workspace.Command {
  {
    program: "gh",
    args: [
      "api",
      "repos/" +
      owner +
      "/" +
      repo +
      "/pulls/" +
      pr_number.to_string() +
      "/reviews",
    ],
    workdir: Some(project_dir),
  }
}

///|
fn merge_pr_review_reviewer_key(
  fields : Map[String, Json],
  fallback_index : Int,
) -> String {
  match fields.get("user") {
    Some(Object(user)) =>
      match user.get("login") {
        Some(String(login)) =>
          if login != "" {
            "user:" + login
          } else {
            "review:" + fallback_index.to_string()
          }
        _ => "review:" + fallback_index.to_string()
      }
    _ => "review:" + fallback_index.to_string()
  }
}

///|
fn merge_pr_review_submitted_at(fields : Map[String, Json]) -> String {
  match fields.get("submitted_at") {
    Some(String(value)) => value
    _ => ""
  }
}

///|
/// Parse a GitHub `submitted_at` string (ISO-8601 UTC) into Unix seconds.
/// `None` when the string is empty or not a recognized shape. Today GitHub
/// emits fixed-width `YYYY-MM-DDTHH:MM:SSZ` and a lexicographic compare is
/// coincidentally ordered — but we don't want that coincidence to be a
/// load-bearing invariant.
fn merge_pr_parse_submitted_at(s : String) -> Int64? {
  if s == "" {
    return None
  }
  Some(@tempo.DateTime::parse(s).to_unix_seconds()) catch {
    _ => None
  }
}

///|
fn merge_pr_should_replace_review_state(
  latest_times : Map[String, String],
  latest_indexes : Map[String, Int],
  key : String,
  submitted_at : String,
  index : Int,
) -> Bool {
  match latest_times.get(key) {
    None => true
    Some(prev_time) => {
      let now_ts = merge_pr_parse_submitted_at(submitted_at)
      let prev_ts = merge_pr_parse_submitted_at(prev_time)
      match (now_ts, prev_ts) {
        (Some(a), Some(b)) => a >= b
        _ =>
          // One or both timestamps unparseable — fall back to array-order
          // to preserve the existing last-wins-in-response semantics.
          match latest_indexes.get(key) {
            Some(prev_index) => index >= prev_index
            None => true
          }
      }
    }
  }
}

///|
pub fn merge_pr_review_gate_block_message(
  pr_number : Int,
  reviews_json : String,
) -> Result[String?, @types.ChoirError] {
  let json = @json.parse(reviews_json) catch {
    _ =>
      return Err(
        @types.ChoirError::validation_error(
          "merge blocked: invalid JSON from GitHub PR reviews API",
        ),
      )
  }
  guard json is Array(reviews) else {
    return Err(
      @types.ChoirError::validation_error(
        "merge blocked: unexpected GitHub PR reviews response shape",
      ),
    )
  }
  let latest_states : Map[String, String] = {}
  let latest_times : Map[String, String] = {}
  let latest_indexes : Map[String, Int] = {}
  for i = 0; i < reviews.length(); i = i + 1 {
    let review = reviews[i]
    match review {
      Object(fields) => {
        let state = match fields.get("state") {
          Some(String(value)) => value
          _ => ""
        }
        if state != "" {
          let key = merge_pr_review_reviewer_key(fields, i)
          let submitted_at = merge_pr_review_submitted_at(fields)
          if merge_pr_should_replace_review_state(
              latest_times, latest_indexes, key, submitted_at, i,
            ) {
            latest_states.set(key, state)
            latest_times.set(key, submitted_at)
            latest_indexes.set(key, i)
          }
        }
      }
      _ => ()
    }
  }
  for state in latest_states.values() {
    if state == "CHANGES_REQUESTED" {
      return Ok(
        Some(
          "PR #" +
          pr_number.to_string() +
          " has a GitHub review requesting changes. Address it before merging.",
        ),
      )
    }
  }
  Ok(None)
}

///|
async fn enforce_merge_pr_github_review_gate(
  pr_number : Int,
  poller_state : @poller.PollerState?,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[Unit, @types.ChoirError] {
  let (owner, repo) = match
    merge_pr_owner_repo(pr_number, poller_state, project_dir, capture) {
    Ok(pair) => pair
    Err(e) => return Err(e)
  }
  let cmd = merge_pr_reviews_command(owner, repo, pr_number, project_dir)
  let (exit_code, output) = capture(cmd)
  if exit_code != 0 || output.trim().to_owned() == "" {
    return Err(
      @types.ChoirError::validation_error(
        "merge blocked: could not fetch GitHub review state for PR #" +
        pr_number.to_string(),
      ),
    )
  }
  match merge_pr_review_gate_block_message(pr_number, output) {
    Ok(Some(msg)) => Err(@types.ChoirError::validation_error(msg))
    Ok(None) => Ok(())
    Err(e) => Err(e)
  }
}

///|
fn merge_pr_verify_results_for_tracked(
  project_dir : String,
  tracked : @poller.TrackedPR,
  task_contract : @types.TaskContract?,
) -> Array[@types.VerifyCheckResult] {
  match task_contract {
    Some(contract) =>
      @evidence.verify_results_for_required_at_head_with_ci(
        project_dir,
        tracked.agent_id,
        contract.verify,
        tracked.last_sha,
        @types.task_contract_verify_satisfied_by_native_ci(contract),
      )
    None => []
  }
}

///|
fn merge_pr_missing_task_contract_error(
  pr_number : Int,
  agent_id : String,
) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "merge_pr: server task contract unavailable for tracked agent '" +
    agent_id +
    "' on PR #" +
    pr_number.to_string() +
    "; refusing to evaluate merge verify gate as empty",
  )
}

///|
/// `merge_pr` preflight: GitHub changes-requested reviews are checked first,
/// then the poller snapshot, unresolved review-thread fetch, and
/// `merge_pr_preflight_block_message` must all pass.
pub async fn interpret_merge_pr_preflight(
  pr_number : Int,
  poller_state : @poller.PollerState?,
  project_dir : String,
  caller_id : String,
  capture : async (@workspace.Command) -> (Int, String),
  task_contract_reader? : (String) -> @types.TaskContract? = fn(_) { None },
  review_mode? : @types.ReviewMode = @types.ReviewMode::SinglePass,
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
) -> Result[Unit, @types.ChoirError] {
  ignore(caller_id)
  match
    enforce_merge_pr_github_review_gate(
      pr_number, poller_state, project_dir, capture,
    ) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let poller_tracked = match poller_state {
    Some(ps) => ps.get(pr_number)
    None => None
  }
  let (thread_count, thread_text) = fetch_unresolved_review_threads(
    pr_number, project_dir, capture,
  )
  let policy_decision = match poller_tracked {
    Some(tracked) => {
      let task_contract_raw = match task_contract_reader(tracked.agent_id) {
        Some(contract) => Some(contract)
        None =>
          return Err(
            merge_pr_missing_task_contract_error(pr_number, tracked.agent_id),
          )
      }
      let task_contract = @types.task_contract_with_normalized_verify(
        task_contract_raw, moon_verify_target,
      )
      let verify_results = merge_pr_verify_results_for_tracked(
        project_dir, tracked, task_contract,
      )
      Some(
        @poller.merge_policy_decision_for_tracked_pr(
          tracked,
          Some(thread_count),
          task_contract~,
          review_mode~,
          verify_results~,
        ),
      )
    }
    None => None
  }
  match
    merge_pr_preflight_block_message(
      pr_number,
      poller_tracked,
      thread_count,
      thread_text,
      policy_decision,
      review_mode~,
    ) {
    Some(msg) => Err(@types.ChoirError::validation_error(msg))
    None => Ok(())
  }
}

///|
/// Pre-merge gating for `merge_pr`: poller review state is checked first, then
/// unresolved GraphQL review threads. Returns `Some(err)` when the merge must
/// not proceed; `None` when checks pass.
pub fn merge_pr_preflight_block_message(
  pr_number : Int,
  poller_tracked : @poller.TrackedPR?,
  unresolved_thread_count : Int,
  unresolved_thread_text : String,
  policy_decision : @policy.MergeDecision?,
  review_mode? : @types.ReviewMode = @types.ReviewMode::SinglePass,
  audit_gate_status? : MergePrAuditGateStatus? = None,
) -> String? {
  match poller_tracked {
    Some(tracked) =>
      if tracked.last_review_state == @poller.ReviewState::ChangesRequested &&
        !(review_mode == @types.ReviewMode::SinglePass &&
        tracked.changes_requested_since == 0L &&
        tracked.last_sha != "") {
        return Some(
          "PR #" +
          pr_number.to_string() +
          " has unresolved review comments (ChangesRequested). " +
          "Wait for the owning agent to push fixes.",
        )
      }
    None => ()
  }
  match policy_decision {
    Some(@policy.MergeDecision::ThreadsUnresolvedButFixed(count~, head_sha~)) =>
      return Some(
        "policy blocked: " +
        count.to_string() +
        " unresolved review thread(s) remain after fixes at " +
        head_sha +
        ". Use resolve_my_review_threads(pr_number: \"" +
        pr_number.to_string() +
        "\") from the parent/server path before merging.",
      )
    Some(@policy.MergeDecision::Blocked(reason~)) =>
      return Some(
        "policy blocked: " +
        reason +
        ". Address the blocking policy condition before merging.",
      )
    Some(@policy.MergeDecision::Wait(reason~)) =>
      return Some(
        "policy wait: " + reason + ". Wait for the policy condition to clear.",
      )
    Some(@policy.MergeDecision::NeedsHuman(reason~)) =>
      return Some(
        "policy requires human check: " +
        reason +
        ". Request the required human check before merging.",
      )
    _ => ()
  }
  match audit_gate_status {
    Some(status) =>
      match merge_pr_audit_gate_policy_block_message(pr_number, status) {
        Some(msg) => return Some(msg)
        None => ()
      }
    None => ()
  }
  if unresolved_thread_count > 0 {
    if unresolved_thread_text == review_thread_fetch_failed_marker {
      return Some(
        "merge blocked: gh unavailable (could not fetch review thread state) — contact TL to manually advance lifecycle.",
      )
    }
    return Some(
      "PR #" +
      pr_number.to_string() +
      " has " +
      unresolved_thread_count.to_string() +
      " unresolved review thread(s). Address or resolve them before merging:\n" +
      unresolved_thread_text +
      "\nUse resolve_my_review_threads(pr_number: \"" +
      pr_number.to_string() +
      "\") to mark threads resolved.",
    )
  }
  None
}

///|
async fn merge_pr_audit_receipt_validation_for_head(
  parent_branch : String,
  project_dir : String,
  head_sha : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> MergePrAuditReceiptValidation {
  let receipt_path = file_pr_audit_receipt_path_for_head(head_sha)
  let (exit_code, receipt_body) = capture({
    program: "cat",
    args: [receipt_path],
    workdir: Some(project_dir),
  })
  merge_pr_audit_receipt_validation(
    parent_branch,
    head_sha,
    if exit_code == 0 {
      Some(receipt_body)
    } else {
      None
    },
  )
}

///|
fn merge_pr_audit_block_error(
  project_dir : String,
  pr_number : Int,
  status : MergePrAuditGateStatus,
  append_file : (String, String) -> Bool,
) -> @types.ChoirError {
  @moontrace.info("merge_pr", fields=[
    @moontrace.field("pr", pr_number),
    @moontrace.field("outcome", "audit_block"),
    @moontrace.field("audit_gate", status.to_wire_string()),
  ])
  merge_pr_delivery_log_line(
    append_file,
    project_dir,
    "merge_pr pr=" +
    pr_number.to_string() +
    " outcome=audit_block audit_gate=" +
    status.to_wire_string(),
  )
  @types.ChoirError::validation_error(
    merge_pr_preflight_block_message(
      pr_number,
      None,
      0,
      "",
      None,
      audit_gate_status=Some(status),
    ).unwrap_or("policy blocked: audit receipt gate blocked merge"),
  )
}

///|
fn merge_pr_parent_branch_mismatch_error(
  project_dir : String,
  pr_number : Int,
  requested_parent_branch : String,
  tracked_parent_branch : String,
  append_file : (String, String) -> Bool,
) -> @types.ChoirError {
  @moontrace.info("merge_pr", fields=[
    @moontrace.field("pr", pr_number),
    @moontrace.field("outcome", "parent_branch_mismatch"),
    @moontrace.field("requested_parent_branch", requested_parent_branch),
    @moontrace.field("tracked_parent_branch", tracked_parent_branch),
  ])
  merge_pr_delivery_log_line(
    append_file,
    project_dir,
    "merge_pr pr=" +
    pr_number.to_string() +
    " outcome=parent_branch_mismatch requested_parent_branch=" +
    requested_parent_branch +
    " tracked_parent_branch=" +
    tracked_parent_branch,
  )
  @types.ChoirError::validation_error(
    "policy blocked: merge_pr parent_branch mismatch for PR #" +
    pr_number.to_string() +
    ": caller requested '" +
    requested_parent_branch +
    "' but tracked poller state says '" +
    tracked_parent_branch +
    "'. Retry merge_pr with parent_branch='" +
    tracked_parent_branch +
    "'.",
  )
}

///|
pub async fn merge_pr_require_audit_receipt(
  parent_branch : String,
  project_dir : String,
  pr_number : Int,
  head_sha : String,
  gate_state : MergeGateState,
  pr_first_seen_unix : Int64,
  capture : async (@workspace.Command) -> (Int, String),
  append_file? : (String, String) -> Bool = fn(_, _) { false },
) -> Result[Unit, @types.ChoirError] {
  if !file_pr_audit_receipt_required(parent_branch) {
    return Ok(())
  }
  if !merge_pr_audit_gate_required(gate_state, pr_first_seen_unix) {
    return Ok(())
  }
  if head_sha.trim().to_owned() == "" {
    return Err(
      merge_pr_audit_block_error(
        project_dir,
        pr_number,
        MergeAuditGateHeadUnavailable,
        append_file,
      ),
    )
  }
  let validation = merge_pr_audit_receipt_validation_for_head(
    parent_branch, project_dir, head_sha, capture,
  )
  match validation {
    MergeAuditReceiptValid => Ok(())
    _ =>
      Err(
        merge_pr_audit_block_error(
          project_dir,
          pr_number,
          MergeAuditGateReceiptBlocked(validation),
          append_file,
        ),
      )
  }
}

///|
/// TL-facing re-check snapshot after actionable CI poller transitions
/// (`CIFailureCleared`, `CILatestHeadRollupSucceeded`). Honest about review state,
/// CI rollup, and unresolved threads; does not claim merge or call `merge_pr`.
/// `unresolved_thread_count` is `None` when the GraphQL fetch was not performed.
pub fn format_tl_pr_recheck_summary(
  tracked : @poller.TrackedPR,
  project_dir : String,
  unresolved_thread_count : Int?,
  task_contract? : @types.TaskContract? = None,
  verify_results? : Array[@types.VerifyCheckResult] = [],
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
) -> String {
  let review = match tracked.last_review_state {
    None_ => "none"
    Commented => "commented"
    Approved => "approved"
    ChangesRequested => "changes_requested"
  }
  let ci = match tracked.last_ci_rollup {
    Unknown => "unknown"
    NoChecks => "no_checks"
    InProgress => "in_progress"
    Success => "success"
    Failure => "failure"
  }
  let threads_line = match unresolved_thread_count {
    Some(n) => "Unresolved inline review threads (GraphQL): " + n.to_string()
    None => "Unresolved inline review threads (GraphQL): not fetched"
  }
  let copilot_line = if tracked.copilot_issue_comment_seen {
    "GitHub Copilot issue comment (REST): seen"
  } else {
    "GitHub Copilot issue comment (REST): not seen"
  }
  let gate = @poller.tl_tracked_pr_recheck_gate_line(
    tracked, unresolved_thread_count,
  )

  let task_contract = @types.task_contract_with_normalized_verify(
    task_contract, moon_verify_target,
  )
  let verify_results = if verify_results.length() > 0 {
    verify_results
  } else {
    merge_pr_verify_results_for_tracked(project_dir, tracked, task_contract)
  }
  let advisory = @poller.advisory_evaluation_summary_line(
    tracked,
    unresolved_thread_count,
    task_contract~,
    review_mode=tracked.review_mode,
    verify_results~,
  )
  let policy = @poller.merge_policy_summary_line(
    tracked,
    unresolved_thread_count,
    task_contract~,
    review_mode=tracked.review_mode,
    verify_results~,
  )

  "PR re-check summary (Choir snapshot; not merge approval):\n" +
  "- GitHub review rollup: " +
  review +
  "\n" +
  "- " +
  threads_line +
  "\n" +
  "- " +
  copilot_line +
  "\n" +
  "- Latest head CI rollup: " +
  ci +
  "\n" +
  "- " +
  gate +
  "\n" +
  "- " +
  advisory +
  "\n" +
  "- " +
  policy
}

///|
/// Map `gh pr merge` stderr (or log) captured after a failed merge attempt into
/// the user-facing error string. Pure policy: conflict/not-mergeable vs other.
pub fn merge_pr_merge_failure_message(
  pr_number : Int,
  gh_stderr_trimmed : String,
) -> String {
  let lower = gh_stderr_trimmed.to_lower()
  if lower.contains("conflict") || lower.contains("not mergeable") {
    "merge conflict on PR #" + pr_number.to_string() + ": " + gh_stderr_trimmed
  } else if gh_stderr_trimmed.length() > 0 {
    "merge failed for PR #" + pr_number.to_string() + ": " + gh_stderr_trimmed
  } else {
    "merge failed for PR #" + pr_number.to_string()
  }
}

///|
/// `TLEvent::PRMerged` `url` field: slug from tracked branch when known, else
/// a stable `PR-{n}` placeholder (matches prior dispatch behavior).
pub fn merge_pr_pr_merged_event_url_slug(
  pr_number : Int,
  tracked_branch : String?,
) -> String {
  match tracked_branch {
    Some(branch) => @phase.extract_slug(branch)
    None => "PR-" + pr_number.to_string()
  }
}

///|
/// Pure plan for `merge_pr` after the merge command succeeds: `TLEvent::PRMerged`
/// payload (url slug from tracked branch when poller is available), whether to
/// untrack the PR and persist poller state, and the tool success response.
pub(all) struct MergePrPostSuccessPlan {
  tl_event : @phase.TLEvent
  poller_untrack_and_write_state : Bool
  response : @types.Response
}

///|
pub fn merge_pr_post_success_plan(
  pr_number : Int,
  poller_available : Bool,
  tracked_branch : String?,
) -> MergePrPostSuccessPlan {
  let branch_for_slug = if poller_available { tracked_branch } else { None }
  let slug = merge_pr_pr_merged_event_url_slug(pr_number, branch_for_slug)
  let tl_event = @phase.TLEvent::PRMerged(number=pr_number, url=slug)
  {
    tl_event,
    poller_untrack_and_write_state: poller_available,
    response: @types.Response::ok_values({ "status": String::to_json("merged") }),
  }
}

///|
/// Mutex key for per-parent-branch merge serialization (matches prior inline
/// `merge_pr` behavior).
pub fn merge_pr_mutex_name(parent_branch : String) -> String {
  "branch:" + parent_branch
}

///|
/// TTL passed to `MutexRegistry::acquire` for merge serialization.
pub let merge_pr_mutex_ttl_sec : Int64 = 120L

///|
pub fn merge_pr_serialization_busy_message() -> String {
  "merge serialization lock held by another agent, retry shortly"
}

///|
/// Same busy notice but annotated with the caller's queue position at the
/// moment of the failed acquire. `position == 0` (shouldn't happen on busy)
/// or `position == 1` is suppressed; `position >= 2` means "N callers ahead
/// of you" and is appended so operators can tell apart 'first in line' from
/// 'backed up behind a queue'.
pub fn merge_pr_serialization_busy_message_with_position(
  position : Int,
) -> String {
  if position <= 1 {
    merge_pr_serialization_busy_message()
  } else {
    merge_pr_serialization_busy_message() +
    " (position " +
    position.to_string() +
    " in queue)"
  }
}

///|
/// Ordered host steps for `merge_pr` after preflight: `gh pr merge` then
/// `git fetch` (see `merge_pr_commands` in `pr.mbt`).
pub(all) enum MergePrHostStep {
  GhPrMerge
  GitFetch
} derive(Debug, Eq)

///|
pub fn merge_pr_host_step_sequence() -> Array[MergePrHostStep] {
  [MergePrHostStep::GhPrMerge, MergePrHostStep::GitFetch]
}

///|
fn merge_pr_agent_local_config_paths(
  project_dir : String,
  agent_id : String,
  registry : @registry.AgentRegistry?,
) -> Array[String] {
  let agent_workspace = match registry {
    Some(reg) =>
      match reg.get_opt(agent_id) {
        Some(agent) => Some(agent.workspace)
        None => None
      }
    None => None
  }
  @workspace.local_config_candidate_paths_for_agent_workspace(
    project_dir,
    agent_workspace,
    @phase.extract_slug(agent_id),
    agent_id=Some(agent_id),
  )
}

///|
fn merge_pr_local_config_error_detail(e : @types.ChoirError) -> String {
  let message = e.message()
  match message.strip_prefix("config error: ") {
    Some(detail) => detail.to_owned()
    None => message
  }
}

///|
fn merge_pr_local_merge_strategy_for_agent(
  project_dir : String,
  agent_id : String,
  registry : @registry.AgentRegistry?,
  read_file : (String) -> String,
) -> Result[@types.MergeStrategy?, @types.ChoirError] {
  for path in merge_pr_agent_local_config_paths(project_dir, agent_id, registry) {
    let content = read_file(path)
    if content == "" {
      continue
    }
    match @config.parse_local_config(content) {
      Ok(local_cfg) =>
        match local_cfg.merge_strategy {
          Some(strategy) => return Ok(Some(strategy))
          None => ()
        }
      Err(e) =>
        return Err(
          @types.ChoirError::config_error(
            "invalid local config " +
            path +
            ": " +
            merge_pr_local_config_error_detail(e),
          ),
        )
    }
  }
  Ok(None)
}

///|
fn merge_pr_effective_merge_strategy(
  project_dir : String,
  pr_number : Int,
  caller_id : String,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  read_file : (String) -> String,
  global_merge_strategy : @types.MergeStrategy,
) -> Result[@types.MergeStrategy, @types.ChoirError] {
  match poller_state {
    Some(ps) =>
      match ps.get(pr_number) {
        Some(tracked) =>
          match
            merge_pr_local_merge_strategy_for_agent(
              project_dir,
              tracked.agent_id,
              registry,
              read_file,
            ) {
            Ok(Some(strategy)) => return Ok(strategy)
            Ok(None) => ()
            Err(e) => return Err(e)
          }
        None => ()
      }
    None => ()
  }
  match
    merge_pr_local_merge_strategy_for_agent(
      project_dir, caller_id, registry, read_file,
    ) {
    Ok(Some(strategy)) => Ok(strategy)
    Ok(None) => Ok(global_merge_strategy)
    Err(e) => Err(e)
  }
}

///|
/// If the mutex is busy, returns before running the merge. Otherwise acquires
/// the mutex, runs the merge, and on either success or failure releases the
/// mutex after capturing any failure output. Holding the mutex across failure
/// capture prevents a concurrent caller from interleaving a merge against the
/// same parent_branch while we examine the previous failure.
pub async fn interpret_merge_pr_merge_host(
  parent_branch : String,
  pr_number : Int,
  caller_id : String,
  merge_strategy : @types.MergeStrategy,
  mutex_registry : @registry.MutexRegistry?,
  now_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  match_head_sha? : String? = None,
) -> Result[Unit, @types.ChoirError] {
  let mutex_name = merge_pr_mutex_name(parent_branch)
  match mutex_registry {
    Some(reg) => {
      let (acquired, queue_position) = reg.acquire(
        mutex_name, caller_id, merge_pr_mutex_ttl_sec, now_sec,
      )
      if !acquired {
        ignore(reg.release(mutex_name, caller_id, now_sec))
        return Err(
          @types.ChoirError::validation_error(
            merge_pr_serialization_busy_message_with_position(queue_position),
          ),
        )
      }
    }
    None => ()
  }
  let cmds = merge_pr_commands(pr_number, merge_strategy, match_head_sha~)
  let merge_result = run_strict(runner, cmds, capture~)
  let final_result = match merge_result {
    Err(_) => {
      let (_, output) = capture(
        merge_pr_command(pr_number, merge_strategy, match_head_sha~),
      )
      let trimmed = output.trim().to_owned()
      Err(
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(pr_number, trimmed),
        ),
      )
    }
    Ok(_) => Ok(())
  }
  // Hold the mutex across failure-capture so a concurrent caller cannot interleave a merge against the same parent branch while we examine the previous failure.
  match mutex_registry {
    Some(reg) => ignore(reg.release(mutex_name, caller_id, now_sec))
    None => ()
  }
  final_result
}

///|
/// Tracked branch string for `merge_pr_post_success_plan` when the poller is
/// present and lists this PR; `None` when the poller is absent or has no entry.
pub fn merge_pr_tracked_branch_for_post_success(
  poller_state : @poller.PollerState?,
  pr_number : Int,
) -> String? {
  match poller_state {
    Some(ps) =>
      match ps.get(pr_number) {
        Some(tracked) => Some(tracked.branch)
        None => None
      }
    None => None
  }
}

///|
fn merge_pr_tracked_for_post_success(
  poller_state : @poller.PollerState?,
  pr_number : Int,
) -> @poller.TrackedPR? {
  match poller_state {
    Some(ps) =>
      match ps.get(pr_number) {
        Some(tracked) => Some(tracked)
        None => None
      }
    None => None
  }
}

///|
/// Bound the `gh pr view --json body` invocation in 30s of `timeout(1)`. The
/// repo's gh-discipline (choir-vj3) flags `gh pr view --json` as a known
/// indefinite-hang surface; wrapping with `timeout` ensures a stalled call
/// surfaces as a non-zero exit instead of blocking merge_pr's post-success
/// side effects (and the tool response).
pub fn merge_pr_pr_body_command(
  project_dir : String,
  pr_number : Int,
) -> @workspace.Command {
  {
    program: "timeout",
    args: ["30s", "gh", "pr", "view", pr_number.to_string(), "--json", "body"],
    workdir: Some(project_dir),
  }
}

///|
pub fn merge_pr_pr_body_from_view_json(output : String) -> String? {
  let json = @json.parse(output) catch { _ => return None }
  guard json is Object(fields) else { return None }
  match fields.get("body") {
    Some(String(body)) => Some(body)
    _ => Some("")
  }
}

///|
fn merge_pr_closes_literal_at(s : String, i : Int) -> Bool {
  let len = "Closes".length()
  if i < 0 || i + len > s.length() {
    false
  } else {
    let token = s[i:i + len].to_owned()
    token == "Closes" || token == "closes"
  }
}

///|
fn merge_pr_regex_whitespace(c : UInt16) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
fn merge_pr_issue_id_char(c : UInt16) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.'
}

///|
fn merge_pr_push_unique_issue_id(ids : Array[String], id : String) -> Unit {
  if id != "" && !ids.contains(id) {
    ids.push(id)
  }
}

///|
/// Extract issue ids matching the task's literal regex
/// `[Cc]loses\s+(choir-[a-z0-9.-]+)`, plus any additional ids that follow on
/// the same line separated by commas or whitespace
/// (`Closes choir-a, choir-b choir-c`). Stops collecting when a non-id,
/// non-separator character is encountered (e.g. end of line, prose).
pub fn merge_pr_closes_issue_ids_from_body(body : String) -> Array[String] {
  let ids : Array[String] = []
  let closes_len = "Closes".length()
  let prefix = "choir-"
  let prefix_len = prefix.length()
  let mut i = 0
  while i < body.length() {
    if merge_pr_closes_literal_at(body, i) {
      let mut j = i + closes_len
      if j < body.length() && merge_pr_regex_whitespace(body[j]) {
        while j < body.length() && merge_pr_regex_whitespace(body[j]) {
          j = j + 1
        }
        if j + prefix_len < body.length() &&
          body[j:j + prefix_len].to_owned() == prefix {
          let mut k = j + prefix_len
          while k < body.length() && merge_pr_issue_id_char(body[k]) {
            k = k + 1
          }
          if k > j + prefix_len {
            merge_pr_push_unique_issue_id(ids, body[j:k].to_owned())
            // Continue scanning the same Closes line for additional ids
            // separated by `,` and/or whitespace until we hit something
            // that is not a separator and not the start of a `choir-` id.
            let mut cursor = k
            while cursor < body.length() {
              while cursor < body.length() &&
                    (
                      merge_pr_regex_whitespace(body[cursor]) ||
                      body[cursor] == ','
                    ) {
                cursor = cursor + 1
              }
              if cursor + prefix_len <= body.length() &&
                body[cursor:cursor + prefix_len].to_owned() == prefix {
                let mut m = cursor + prefix_len
                while m < body.length() && merge_pr_issue_id_char(body[m]) {
                  m = m + 1
                }
                if m > cursor + prefix_len {
                  merge_pr_push_unique_issue_id(ids, body[cursor:m].to_owned())
                  cursor = m
                  continue
                }
              }
              break
            }
            i = cursor
            continue
          }
        }
      }
    }
    i = i + 1
  }
  ids
}

///|
pub fn merge_pr_beads_close_completed_via_pr_command(
  project_dir : String,
  issue_id : String,
  pr_number : Int,
) -> @workspace.Command {
  {
    program: "bd",
    args: [
      "close",
      issue_id,
      "--reason",
      "completed via PR #" + pr_number.to_string(),
    ],
    workdir: Some(project_dir),
  }
}

///|
pub fn merge_pr_git_checkout_command(
  project_dir : String,
  branch : String,
) -> @workspace.Command {
  { program: "git", args: ["checkout", branch], workdir: Some(project_dir) }
}

///|
pub fn merge_pr_git_delete_local_branch_command(
  project_dir : String,
  branch : String,
) -> @workspace.Command {
  { program: "git", args: ["branch", "-D", branch], workdir: Some(project_dir) }
}

///|
fn merge_pr_delivery_log_line(
  append_file : (String, String) -> Bool,
  project_dir : String,
  line : String,
) -> Unit {
  ignore(
    @poller.append_delivery_log_line(
      append_file,
      project_dir,
      "[poller] " + line,
    ),
  )
}

///|
pub fn merge_pr_beads_show_status_and_open_children(
  output : String,
) -> Result[(String, Bool), @types.ChoirError] {
  let json = @json.parse(output) catch {
    _ =>
      return Err(@types.ChoirError::validation_error("invalid beads show JSON"))
  }
  let fields = match json {
    Array(items) =>
      if items.length() == 0 {
        return Err(@types.ChoirError::validation_error("empty beads show JSON"))
      } else {
        match items[0] {
          Object(obj) => obj
          _ =>
            return Err(
              @types.ChoirError::validation_error(
                "unexpected beads show JSON shape",
              ),
            )
        }
      }
    Object(obj) => obj
    _ =>
      return Err(
        @types.ChoirError::validation_error("unexpected beads show JSON shape"),
      )
  }
  let status = match fields.get("status") {
    Some(String(s)) => s
    _ => ""
  }
  let mut has_open_children = false
  match fields.get("epic_closeable") {
    Some(False) => has_open_children = true
    _ => ()
  }
  match fields.get("dependents") {
    Some(Array(children)) =>
      for child in children {
        match child {
          Object(child_fields) => {
            let child_status = match child_fields.get("status") {
              Some(String(s)) => s
              _ => ""
            }
            if child_status != "" && child_status != "closed" {
              has_open_children = true
            }
          }
          _ => ()
        }
      }
    _ => ()
  }
  Ok((status, has_open_children))
}

///|
fn merge_pr_agent_branch_for_wave_scan(
  registry : @registry.AgentRegistry?,
  agent_id : String,
) -> String {
  match registry {
    Some(reg) =>
      match (Some(reg.get(agent_id)) catch { _ => None }) {
        Some(agent) => agent.branch
        None => agent_id
      }
    None => agent_id
  }
}

///|
fn merge_pr_beads_issue_id_for_wave_agent(
  agent_id : String,
  task_contract_reader : (String) -> @types.TaskContract?,
) -> String? {
  match task_contract_reader(agent_id) {
    Some(contract) => contract.beads_issue_id
    None => None
  }
}

///|
fn merge_pr_wave_beads_issue_ids_for_feature_branch(
  project_dir : String,
  registry : @registry.AgentRegistry?,
  feature_branch : String,
  task_contract_reader : (String) -> @types.TaskContract?,
) -> Array[String] {
  let ids : Array[String] = []
  if feature_branch == "" {
    return ids
  }
  let branch_prefix = feature_branch + "."
  for wave_id in list_wave_ids(project_dir) {
    match load_wave_index(project_dir, wave_id) {
      Ok(idx) =>
        for agent_id in idx.agent_ids {
          let agent_branch = merge_pr_agent_branch_for_wave_scan(
            registry, agent_id,
          )
          if agent_branch.has_prefix(branch_prefix) {
            match
              merge_pr_beads_issue_id_for_wave_agent(
                agent_id, task_contract_reader,
              ) {
              Some(id) => merge_pr_push_unique_issue_id(ids, id)
              None => ()
            }
          }
        }
      Err(_) => ()
    }
  }
  ids
}

///|
async fn merge_pr_body_closing_issue_ids(
  project_dir : String,
  pr_number : Int,
  capture : async (@workspace.Command) -> (Int, String),
  append_file : (String, String) -> Bool,
) -> Array[String] {
  let ids : Array[String] = []
  let (exit_code, output) = capture(
    merge_pr_pr_body_command(project_dir, pr_number),
  )
  if exit_code != 0 {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr beads body_scan failed pr=" +
      pr_number.to_string() +
      " exit=" +
      exit_code.to_string(),
    )
    return ids
  }
  match merge_pr_pr_body_from_view_json(output) {
    Some(body) =>
      for id in merge_pr_closes_issue_ids_from_body(body) {
        merge_pr_push_unique_issue_id(ids, id)
      }
    None =>
      merge_pr_delivery_log_line(
        append_file,
        project_dir,
        "merge_pr beads body_scan invalid_json pr=" + pr_number.to_string(),
      )
  }
  ids
}

///|
async fn merge_pr_close_bead_if_not_closed_without_open_children(
  project_dir : String,
  pr_number : Int,
  issue_id : String,
  capture : async (@workspace.Command) -> (Int, String),
  append_file : (String, String) -> Bool,
) -> Unit {
  let (show_exit, show_output) = capture(
    beads_readonly_show_command(project_dir, issue_id),
  )
  if show_exit != 0 {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr beads close skipped issue=" +
      issue_id +
      " outcome=show_failed exit=" +
      show_exit.to_string(),
    )
    return
  }
  match merge_pr_beads_show_status_and_open_children(show_output) {
    Ok((status, has_open_children)) => {
      if status == "closed" {
        merge_pr_delivery_log_line(
          append_file,
          project_dir,
          "merge_pr beads close skipped issue=" +
          issue_id +
          " outcome=already_closed",
        )
        return
      }
      if has_open_children {
        merge_pr_delivery_log_line(
          append_file,
          project_dir,
          "merge_pr beads close skipped issue=" +
          issue_id +
          " outcome=open_children",
        )
        return
      }
    }
    Err(_) => {
      merge_pr_delivery_log_line(
        append_file,
        project_dir,
        "merge_pr beads close skipped issue=" +
        issue_id +
        " outcome=show_parse_failed",
      )
      return
    }
  }
  let (close_exit, _) = capture(
    merge_pr_beads_close_completed_via_pr_command(
      project_dir, issue_id, pr_number,
    ),
  )
  if close_exit == 0 {
    let audit_ok = run_beads_best_effort(
      beads_audit_record_command(
        project_dir,
        Some(issue_id),
        "tool_call",
        "merge_pr",
        "closed via PR #" + pr_number.to_string(),
      ),
      capture,
    )
    if !audit_ok {
      merge_pr_delivery_log_line(
        append_file,
        project_dir,
        "merge_pr beads audit issue=" +
        issue_id +
        " outcome=audit_failed pr=" +
        pr_number.to_string(),
      )
    }
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr beads close issue=" +
      issue_id +
      " outcome=closed pr=" +
      pr_number.to_string(),
    )
  } else {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr beads close issue=" +
      issue_id +
      " outcome=close_failed exit=" +
      close_exit.to_string(),
    )
  }
}

///|
async fn merge_pr_close_feature_beads(
  project_dir : String,
  pr_number : Int,
  feature_branch : String?,
  registry : @registry.AgentRegistry?,
  capture : async (@workspace.Command) -> (Int, String),
  append_file : (String, String) -> Bool,
  task_contract_reader : (String) -> @types.TaskContract?,
) -> Unit {
  let issue_ids : Array[String] = []
  match feature_branch {
    Some(branch) =>
      for
        id in merge_pr_wave_beads_issue_ids_for_feature_branch(
          project_dir, registry, branch, task_contract_reader,
        ) {
        merge_pr_push_unique_issue_id(issue_ids, id)
      }
    None => ()
  }
  for
    id in merge_pr_body_closing_issue_ids(
      project_dir, pr_number, capture, append_file,
    ) {
    merge_pr_push_unique_issue_id(issue_ids, id)
  }
  if issue_ids.length() == 0 {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr beads close skipped pr=" +
      pr_number.to_string() +
      " outcome=no_issue_ids",
    )
    return
  }
  for issue_id in issue_ids {
    merge_pr_close_bead_if_not_closed_without_open_children(
      project_dir, pr_number, issue_id, capture, append_file,
    )
  }
}

///|
fn merge_pr_cleanup_agent(
  project_dir : String,
  agent : @types.Agent,
  read_lifecycle : (String, String) -> @phase.AgentLifecycle?,
) -> @types.Agent {
  let agent_id = agent.agent_id.to_string()
  match read_lifecycle(project_dir, agent_id) {
    Some(lifecycle) =>
      @phase.agent_with_lifecycle_leaf_teardown_metadata(
        agent, lifecycle, project_dir,
      )
    None => agent
  }
}

///|
async fn merge_pr_run_cleanup_command(
  project_dir : String,
  label : String,
  cmd : @workspace.Command,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  append_file : (String, String) -> Bool,
) -> Bool {
  let statuses = runner([cmd]) catch {
    e => {
      merge_pr_delivery_log_line(
        append_file,
        project_dir,
        "merge_pr cleanup " + label + " failed exception=" + e.to_string(),
      )
      return false
    }
  }
  let status = if statuses.length() > 0 { statuses[0] } else { -1 }
  if status == 0 {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr cleanup " + label + " outcome=ok",
    )
    true
  } else {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr cleanup " + label + " outcome=failed exit=" + status.to_string(),
    )
    false
  }
}

///|
fn merge_pr_leaf_cleanup_worktree_path(
  project_dir : String,
  tracked : @poller.TrackedPR?,
  registry : @registry.AgentRegistry?,
  branch : String,
  read_lifecycle : (String, String) -> @phase.AgentLifecycle?,
) -> String {
  match tracked {
    Some(t) =>
      match registry {
        Some(reg) =>
          match (Some(reg.get(t.agent_id)) catch { _ => None }) {
            Some(agent) => {
              let cleanup_agent = merge_pr_cleanup_agent(
                project_dir, agent, read_lifecycle,
              )
              if @types.is_supervisor_role(cleanup_agent.role) {
                return ""
              } else if @types.is_choir_managed_worktree_path(
                  project_dir,
                  cleanup_agent.workspace,
                ) {
                return cleanup_agent.workspace
              }
            }
            None => ()
          }
        None => ()
      }
    None => ()
  }
  let fallback = @workspace.worktree_path(
    project_dir,
    @phase.extract_slug(branch),
  )
  if @types.is_choir_managed_worktree_path(project_dir, fallback) {
    fallback
  } else {
    ""
  }
}

///|
fn merge_pr_leaf_cleanup_refuses_tracked_supervisor(
  project_dir : String,
  tracked : @poller.TrackedPR?,
  registry : @registry.AgentRegistry?,
  read_lifecycle : (String, String) -> @phase.AgentLifecycle?,
) -> Bool {
  match (tracked, registry) {
    (Some(t), Some(reg)) =>
      match (Some(reg.get(t.agent_id)) catch { _ => None }) {
        Some(agent) =>
          @types.is_supervisor_role(
            merge_pr_cleanup_agent(project_dir, agent, read_lifecycle).role,
          )
        None => false
      }
    _ => false
  }
}

///|
test "merge_pr_leaf_cleanup_worktree_path refuses supervisor target" {
  let project_dir = "/repo"
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("root"),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "feature/root-pr",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let ps = @poller.PollerState::new()
  ps.track(1, "root", "feature/root-pr.leaf", "feature/root-pr", "url", 0L)
  let tracked = ps.get(1)
  assert_eq(
    merge_pr_leaf_cleanup_worktree_path(
      project_dir,
      tracked,
      Some(reg),
      "feature/root-pr.leaf",
      fn(_, _) { None },
    ),
    "",
  )
  assert_true(
    merge_pr_leaf_cleanup_refuses_tracked_supervisor(
      project_dir,
      tracked,
      Some(reg),
      fn(_, _) { None },
    ),
  )
}

///|
test "merge_pr_leaf_cleanup_worktree_path never returns project root" {
  let project_dir = "/repo"
  let reg = @registry.AgentRegistry::new()
  ignore(
    reg.upsert({
      agent_id: @types.AgentId("main.leaf"),
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some("main"),
      workspace: project_dir,
      branch: "feature/demo.leaf",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let ps = @poller.PollerState::new()
  ps.track(2, "main.leaf", "feature/demo.leaf", "feature/demo", "url", 0L)
  let path = merge_pr_leaf_cleanup_worktree_path(
    project_dir,
    ps.get(2),
    Some(reg),
    "feature/demo.leaf",
    fn(_, _) { None },
  )
  assert_eq(path, "/repo/.choir/worktrees/leaf")
  assert_false(path == project_dir)
}

///|
async fn merge_pr_cleanup_leaf_success(
  project_dir : String,
  tracked : @poller.TrackedPR?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  append_file : (String, String) -> Bool,
  path_exists : (String) -> Bool,
  read_lifecycle : (String, String) -> @phase.AgentLifecycle?,
) -> Unit {
  let branch = match tracked {
    Some(t) => t.branch
    None => ""
  }
  if branch == "" {
    merge_pr_delivery_log_line(
      append_file, project_dir, "merge_pr cleanup leaf skipped outcome=no_branch",
    )
    return
  }
  if merge_pr_leaf_cleanup_refuses_tracked_supervisor(
      project_dir, tracked, registry, read_lifecycle,
    ) {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr cleanup leaf skipped outcome=supervisor_agent branch=" + branch,
    )
    return
  }
  let worktree_path = merge_pr_leaf_cleanup_worktree_path(
    project_dir, tracked, registry, branch, read_lifecycle,
  )
  if worktree_path == "" {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr cleanup leaf_worktree skipped outcome=unsafe_path branch=" +
      branch,
    )
  } else if path_exists(worktree_path) {
    ignore(
      merge_pr_run_cleanup_command(
        project_dir,
        "leaf_worktree path=" + worktree_path,
        @workspace.git_worktree_remove(worktree_path),
        runner,
        append_file,
      ),
    )
  } else {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr cleanup leaf_worktree skipped path=" +
      worktree_path +
      " outcome=missing",
    )
  }
  ignore(
    merge_pr_run_cleanup_command(
      project_dir,
      "leaf_branch branch=" + branch,
      merge_pr_git_delete_local_branch_command(project_dir, branch),
      runner,
      append_file,
    ),
  )
}

///|
async fn merge_pr_cleanup_feature_success(
  project_dir : String,
  feature_branch : String?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  append_file : (String, String) -> Bool,
) -> Unit {
  let branch = feature_branch.unwrap_or("")
  if branch == "" || branch == "main" || branch == "HEAD" {
    merge_pr_delivery_log_line(
      append_file, project_dir, "merge_pr cleanup feature_branch skipped outcome=no_feature_branch",
    )
    return
  }
  // If the parent worktree is currently on the feature branch, git refuses to
  // delete the branch we're standing on. Check out main first; if that fails
  // (dirty working tree, network issue, anything), skip the branch-delete —
  // a noisy "cannot delete current branch" failure is not the cleanup we
  // want to ship.
  let checkout_ok = merge_pr_run_cleanup_command(
    project_dir,
    "checkout_main",
    merge_pr_git_checkout_command(project_dir, "main"),
    runner,
    append_file,
  )
  if !checkout_ok {
    merge_pr_delivery_log_line(
      append_file,
      project_dir,
      "merge_pr cleanup feature_branch skipped outcome=checkout_main_failed branch=" +
      branch,
    )
    return
  }
  ignore(
    merge_pr_run_cleanup_command(
      project_dir,
      "feature_branch branch=" + branch,
      merge_pr_git_delete_local_branch_command(project_dir, branch),
      runner,
      append_file,
    ),
  )
}

///|
async fn interpret_merge_pr_post_success_side_effects(
  project_dir : String,
  parent_branch : String,
  pr_number : Int,
  tracked : @poller.TrackedPR?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  append_file : (String, String) -> Bool,
  path_exists : (String) -> Bool,
  read_lifecycle : (String, String) -> @phase.AgentLifecycle?,
  task_contract_reader : (String) -> @types.TaskContract?,
) -> Unit {
  if parent_branch == "main" {
    let feature_branch = match tracked {
      Some(t) => Some(t.branch)
      None => None
    }
    // Only treat this as an integration merge when the source side actually
    // is a `feature/*` branch. A non-feature → main PR (hotfix/*, release/*,
    // some hand-rolled topic branch) might still contain `Closes choir-XXX`
    // lines, but we should not auto-close beads or delete the wrong branch
    // based on that — the wave-registry semantics only apply to feature/*.
    let is_feature_integration = match feature_branch {
      Some(b) => b.has_prefix("feature/")
      None => false
    }
    if is_feature_integration {
      merge_pr_close_feature_beads(
        project_dir, pr_number, feature_branch, registry, capture, append_file, task_contract_reader,
      )
      merge_pr_cleanup_feature_success(
        project_dir, feature_branch, runner, append_file,
      )
    } else {
      merge_pr_delivery_log_line(
        append_file,
        project_dir,
        "merge_pr cleanup integration skipped outcome=non_feature_source pr=" +
        pr_number.to_string() +
        " source=" +
        feature_branch.unwrap_or("<unknown>"),
      )
    }
  } else if parent_branch.has_prefix("feature/") {
    merge_pr_cleanup_leaf_success(
      project_dir, tracked, registry, runner, append_file, path_exists, read_lifecycle,
    )
  }
}

///|
/// After `interpret_merge_pr_merge_host` succeeds: resolve tracked branch,
/// build `merge_pr_post_success_plan`, apply the TL lifecycle event, optionally
/// untrack and persist poller state, return the tool response.
pub fn interpret_merge_pr_post_success(
  project_dir : String,
  caller_id : String,
  pr_number : Int,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
) -> @types.Response {
  let tracked_branch = merge_pr_tracked_branch_for_post_success(
    poller_state, pr_number,
  )
  let plan = merge_pr_post_success_plan(
    pr_number,
    poller_state is Some(_),
    tracked_branch,
  )
  let tl_effects = @phase.plan_tl_event_for_scope(
    project_dir,
    caller_id,
    plan.tl_event,
    registry~,
  )
  @phase.interpret_lifecycle_effects(project_dir, tl_effects, registry~)
  if plan.poller_untrack_and_write_state {
    match poller_state {
      Some(ps) => {
        match ps.get(pr_number) {
          Some(_) => ps.mark_merged_observed(pr_number)
          None => ()
        }
        ps.untrack(pr_number)
        ignore(ps.write_state_file(project_dir))
      }
      None => ()
    }
  }
  plan.response
}

///|
/// End-to-end `merge_pr`: preflight, mutex-bracketed merge host, then
/// post-success TL lifecycle and poller untrack. Dispatcher delegates here;
/// behavior matches the prior `ToolRequest::MergePr` inline arm.
pub async fn interpret_merge_pr(
  merge_args : MergePrArgs,
  project_dir : String,
  poller_state : @poller.PollerState?,
  mutex_registry : @registry.MutexRegistry?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  append_file : (String, String) -> Bool,
  path_exists : (String) -> Bool,
  read_lifecycle? : (String, String) -> @phase.AgentLifecycle? = @phase.read_lifecycle,
  read_file? : (String) -> String = fn(_) { "" },
  write_file_atomic? : (String, String) -> Bool = fn(_, _) { false },
  merge_strategy? : @types.MergeStrategy = @types.Config::default().merge_strategy,
  merge_gate_now_sec_fn? : () -> Int64 = @poller.now_sec,
  task_contract_reader? : (String) -> @types.TaskContract? = fn(_) { None },
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
) -> @types.Response {
  match
    interpret_merge_pr_preflight(
      merge_args.pr_number,
      poller_state,
      project_dir,
      merge_args.caller_id,
      capture,
      task_contract_reader~,
      review_mode=merge_args.review_mode.unwrap_or(
        @types.ReviewMode::SinglePass,
      ),
      moon_verify_target~,
    ) {
    Err(e) => @types.Response::Err(e.message())
    Ok(_) => {
      let effective_merge_strategy = merge_pr_effective_merge_strategy(
        project_dir,
        merge_args.pr_number,
        merge_args.caller_id,
        poller_state,
        registry,
        read_file,
        merge_strategy,
      )
      let effective_merge_strategy = match effective_merge_strategy {
        Ok(strategy) => strategy
        Err(e) => return @types.Response::Err(e.message())
      }
      let tracked_for_merge = match poller_state {
        Some(ps) => ps.get(merge_args.pr_number)
        None => None
      }
      let effective_parent_branch = match tracked_for_merge {
        Some(tracked) if tracked.parent_branch.trim().to_owned() != "" => {
          let requested = merge_args.parent_branch.trim().to_owned()
          let tracked_parent = tracked.parent_branch.trim().to_owned()
          if requested != "" && requested != tracked_parent {
            return @types.Response::Err(
              merge_pr_parent_branch_mismatch_error(
                project_dir,
                merge_args.pr_number,
                requested,
                tracked_parent,
                append_file,
              ).message(),
            )
          }
          tracked_parent
        }
        _ => merge_args.parent_branch
      }
      let mut merge_match_head_sha : String? = None
      if file_pr_audit_receipt_required(effective_parent_branch) {
        let gate_state = match
          load_or_initialize_gate_state(
            project_dir, merge_gate_now_sec_fn, read_file, write_file_atomic,
          ) {
          Ok(state) => state
          Err(e) => return @types.Response::Err(e.message())
        }
        match tracked_for_merge {
          Some(tracked) =>
            match
              merge_pr_require_audit_receipt(
                effective_parent_branch,
                project_dir,
                merge_args.pr_number,
                tracked.last_sha,
                gate_state,
                tracked.first_seen,
                capture,
                append_file~,
              ) {
              Err(e) => return @types.Response::Err(e.message())
              Ok(_) => merge_match_head_sha = Some(tracked.last_sha)
            }
          None =>
            return @types.Response::Err(
              merge_pr_audit_block_error(
                project_dir,
                merge_args.pr_number,
                MergeAuditGateHeadUnavailable,
                append_file,
              ).message(),
            )
        }
      }
      match
        interpret_merge_pr_merge_host(
          effective_parent_branch,
          merge_args.pr_number,
          merge_args.caller_id,
          effective_merge_strategy,
          mutex_registry,
          @poller.now_sec(),
          runner,
          capture,
          match_head_sha=merge_match_head_sha,
        ) {
        Err(e) => @types.Response::Err(e.message())
        Ok(_) => {
          let tracked = merge_pr_tracked_for_post_success(
            poller_state,
            merge_args.pr_number,
          )
          let resp = interpret_merge_pr_post_success(
            project_dir,
            merge_args.caller_id,
            merge_args.pr_number,
            poller_state,
            registry,
          )
          if resp.is_ok() {
            interpret_merge_pr_post_success_side_effects(
              project_dir,
              effective_parent_branch,
              merge_args.pr_number,
              tracked,
              registry,
              runner,
              capture,
              append_file,
              path_exists,
              read_lifecycle,
              task_contract_reader,
            )
          }
          resp
        }
      }
    }
  }
}

///|
/// GraphQL mutation body for `resolve_review_thread` (thread id is passed as a
/// variable; matches historical `ToolRequest::ResolveReviewThread` dispatch).
pub fn resolve_review_thread_graphql_mutation() -> String {
  "mutation($threadId: ID!) { resolveReviewThread(input: { threadId: $threadId }) { thread { isResolved } } }"
}

///|
/// `gh api graphql` command for resolving a review thread (routing-only callers
/// supply `project_dir` and `capture`).
pub fn resolve_review_thread_gh_command(
  project_dir : String,
  thread_id : String,
) -> @workspace.Command {
  bounded_gh_command(project_dir, [
    "api",
    "graphql",
    "-f",
    "query=" + resolve_review_thread_graphql_mutation(),
    "-F",
    "threadId=" + thread_id,
  ])
}

///|
/// Interpret `gh` exit code and JSON body for `resolve_review_thread`. Preserves
/// exact user-facing strings from the prior inline dispatch arm.
pub fn interpret_resolve_review_thread_result(
  exit_code : Int,
  output : String,
  thread_id : String,
) -> @types.Response {
  if exit_code != 0 {
    let trimmed = output.trim().to_owned()
    return @types.Response::Err(
      if trimmed != "" {
        "resolve_review_thread failed: " + trimmed
      } else {
        "resolve_review_thread failed (exit " + exit_code.to_string() + ")"
      },
    )
  }
  if output.trim().to_owned() == "" {
    return @types.Response::Err(
      "resolve_review_thread failed: empty response from gh",
    )
  }
  let json = @json.parse(output) catch {
    _ =>
      return @types.Response::Err(
        "resolve_review_thread: invalid JSON in gh response",
      )
  }
  guard json is Object(root) else {
    return @types.Response::Err(
      "resolve_review_thread: unexpected response shape",
    )
  }
  match root.get("errors") {
    Some(Array(errs)) =>
      if errs.length() > 0 {
        let msg = match errs[0] {
          Object(e) =>
            match e.get("message") {
              Some(String(v)) => v
              _ => "GraphQL error"
            }
          _ => "GraphQL error"
        }
        return @types.Response::Err("resolve_review_thread failed: " + msg)
      }
    _ => ()
  }
  let is_resolved = match root.get("data") {
    Some(Object(data)) =>
      match data.get("resolveReviewThread") {
        Some(Object(rt)) =>
          match rt.get("thread") {
            Some(Object(thread)) =>
              match thread.get("isResolved") {
                Some(True) => true
                _ => false
              }
            _ => false
          }
        _ => false
      }
    _ => false
  }
  if !is_resolved {
    return @types.Response::Err(
      "resolve_review_thread: thread was not marked resolved (check permissions)",
    )
  }
  @types.Response::ok_values({
    "status": String::to_json("ok"),
    "thread_id": String::to_json(thread_id),
    "resolved": Bool::to_json(true),
  })
}

///|
/// `resolve_review_thread`: capture GraphQL result and map to the tool response.
pub async fn interpret_resolve_review_thread(
  resolve_args : ResolveReviewThreadArgs,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  let cmd = resolve_review_thread_gh_command(
    project_dir,
    resolve_args.thread_id,
  )
  let (exit_code, output) = capture(cmd)
  interpret_resolve_review_thread_result(
    exit_code,
    output,
    resolve_args.thread_id,
  )
}

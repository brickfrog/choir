///|
pub(all) struct FilePrPlanResult {
  response : @types.Response
  tracked_pr : @poller.TrackedPR?
  dev_event : @phase.DevEvent
  notify_message : String
  review_context : String?
}

///|
/// Pure interpreter-facing plan for side effects after `ensure_pull_request`
/// succeeds: poller registration, dev lifecycle append, and optional parent
/// auto-notify. Capability flags mirror host availability (`poller_state` /
/// `registry` injected into dispatch).
pub(all) struct FilePrPostSuccessEffects {
  poller_track : @poller.TrackedPR?
  dev_event : @phase.DevEvent
  notify_message_for_parent : String?
  response : @types.Response
  review_context : String?
}

///|
pub fn file_pr_post_success_effects(
  plan : FilePrPlanResult,
  poller_available : Bool,
  registry_available : Bool,
) -> FilePrPostSuccessEffects {
  let poller_track = match plan.tracked_pr {
    Some(tracked) => if poller_available { Some(tracked) } else { None }
    None => None
  }
  let notify_message_for_parent = if registry_available {
    Some(plan.notify_message)
  } else {
    None
  }
  {
    poller_track,
    dev_event: plan.dev_event,
    notify_message_for_parent,
    response: plan.response,
    review_context: plan.review_context,
  }
}

///|
pub fn file_pr_plan(
  args : FilePrArgs,
  parent_branch : String,
  pr : PullRequestInfo,
  tracked : Bool,
  review_mode? : @types.ReviewMode = @types.Config::default().review_mode,
) -> FilePrPlanResult {
  let tracked_pr = if tracked {
    Some(@poller.TrackedPR::{
      pr_number: pr.number,
      agent_id: args.tracked_agent_id,
      branch: args.branch,
      parent_branch,
      pr_url: pr.url,
      first_seen: 0L,
      consecutive_failures: 0,
      backoff_until: 0L,
      last_review_state: @poller.ReviewState::None_,
      last_review_bodies: "",
      last_sha: "",
      last_automerge_attempt_sha: "",
      notified_parent: false,
      last_ci_rollup: @poller.CiRollupStatus::Unknown,
      last_timeout_at: 0L,
      copilot_issue_comment_seen: false,
      orphan_notified: false,
      orphan_reconciling: false,
      changes_requested_since: 0L,
      stall_notified: false,
      fixes_pushed_at: 0L,
      review_mode,
      unresolved_thread_ids: [],
      unresolved_thread_ids_fetched: false,
      auto_resolve_outdated_pending: false,
    })
  } else {
    None
  }
  let dev_event = @phase.DevEvent::PRCreated(
    pr_number=pr.number,
    url=pr.url,
    branch=args.branch,
  )
  let notify_message = "[PR READY] PR #" +
    pr.number.to_string() +
    " filed: " +
    pr.url
  let response = @types.Response::ok_values({
    "status": String::to_json("pr_created"),
    "pr_number": Int::to_json(pr.number),
    "pr_url": String::to_json(pr.url),
    "tracked": Bool::to_json(tracked),
  })
  {
    response,
    tracked_pr,
    dev_event,
    notify_message,
    review_context: args.review_context,
  }
}

///|
/// Pure plan for `file_pr` post-success auto-notify: parent resolution outcome
/// maps to delivery intent plus exact delivery-log append text. The dispatcher
/// interprets this (append logs, `execute_delivery`, moontrace on failures).
pub(all) enum FilePrAutoNotifyPlan {
  Deliver(delivery~ : @message.DeliveryMethod, delivery_log_append~ : String)
  ParentResolutionFailed(
    delivery_log_append~ : String,
    parent_resolve_error~ : String
  )
} derive(Eq)

///|
pub fn file_pr_auto_notify_plan(
  parent_result : Result[@types.Agent, @types.ChoirError],
  tracked_agent_id : String,
  notify_message : String,
  now_ms? : Int64 = @env.now().reinterpret_as_int64(),
) -> FilePrAutoNotifyPlan {
  match parent_result {
    Ok(parent) => {
      let delivery = @message.plan_delivery(
        parent,
        tracked_agent_id,
        notify_message,
        @types.Status::Success,
      )
      let delivery_log_append = @poller.delivery_log_line(
        "[auto-notify] caller=" +
        tracked_agent_id +
        " parent=" +
        parent.agent_id.to_string() +
        " delivery=" +
        delivery.to_display_string(),
        now_ms~,
      )
      Deliver(delivery~, delivery_log_append~)
    }
    Err(e) => {
      let msg = e.message()
      ParentResolutionFailed(
        delivery_log_append=@poller.delivery_log_line(
          "[auto-notify] resolve_parent_for_notify failed error=" + msg,
          now_ms~,
        ),
        parent_resolve_error=msg,
      )
    }
  }
}

///|
pub fn file_pr_auto_notify_delivery_failed_log_append(
  error : String,
  now_ms? : Int64 = @env.now().reinterpret_as_int64(),
) -> String {
  @poller.delivery_log_line(
    "[auto-notify] delivery failed error=" + error,
    now_ms~,
  )
}

///|
/// GitHub Copilot reviewer handle for `gh pr edit --add-reviewer` (CLI resolves to
/// `copilot-pull-request-reviewer[bot]`).
pub let file_pr_copilot_reviewer_handle : String = "@copilot"

///|
/// Prefix for the PR issue comment that nudges Copilot review with caller-supplied context.
pub let file_pr_copilot_review_comment_prefix : String = "@copilot review: "

///|
pub fn file_pr_copilot_review_comment_body(
  review_context_trimmed : String,
) -> String {
  file_pr_copilot_review_comment_prefix + review_context_trimmed
}

///|
/// `gh pr comment` body for Copilot review context ([`interpret_file_pr_post_success`] when
/// `pr_review` and non-empty [`FilePrPostSuccessEffects::review_context`]).
pub fn file_pr_copilot_review_comment_gh_command(
  pr_number : Int,
  review_context_trimmed : String,
  gh_workdir : String,
) -> @workspace.Command {
  @workspace.gh_pr_comment(
    pr_number,
    file_pr_copilot_review_comment_body(review_context_trimmed),
    gh_workdir,
  )
}

///|
/// `gh pr edit --add-reviewer @copilot` when [`interpret_file_pr_post_success`] runs with
/// `pr_review` true. `gh_workdir` matches other `file_pr` git/gh operations ([`file_pr_workdir`]).
pub fn file_pr_copilot_reviewer_gh_command(
  pr_number : Int,
  gh_workdir : String,
) -> @workspace.Command {
  @workspace.gh_pr_add_reviewer(
    pr_number, file_pr_copilot_reviewer_handle, gh_workdir,
  )
}

///|
/// Post-`ensure_pull_request` host path: poller ensure/write, dev lifecycle
/// event, optional parent auto-notify (delivery log + `execute_delivery` +
/// moontrace), optional best-effort Copilot reviewer request (`gh pr edit
/// --add-reviewer @copilot` when `pr_review`), then the planned tool response.
/// Preserves `ToolRequest::FilePr`
/// ordering and strings from the prior dispatch arm.
pub async fn interpret_file_pr_post_success(
  project_dir : String,
  session : String,
  branch : String,
  tracked_agent_id : String,
  file_pr_workdir : String,
  pr_number : Int,
  pr_review : Bool,
  effects : FilePrPostSuccessEffects,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  sleep_fn? : async (Int) -> Unit = @async.sleep,
  // Clock for delivery-log line timestamps. Called fresh at each append site —
  // not captured once — so writes that happen after slow `gh`/delivery commands
  // record their real wall-clock time rather than a stale snapshot.
  now_ms_fn? : () -> Int64 = fn() { @env.now().reinterpret_as_int64() },
) -> @types.Response {
  match effects.poller_track {
    Some(tracked_pr) =>
      match poller_state {
        Some(ps) => {
          ps.ensure_tracked(
            tracked_pr.pr_number,
            tracked_pr.agent_id,
            tracked_pr.branch,
            tracked_pr.parent_branch,
            tracked_pr.pr_url,
            @poller.now_sec(),
            review_mode=Some(tracked_pr.review_mode),
          )
          ignore(ps.write_state_file(project_dir))
        }
        None => ()
      }
    None => ()
  }
  @phase.apply_dev_event(project_dir, branch, effects.dev_event, registry~)
  let delivery_log_path = project_dir + "/.choir/delivery.log"
  match (effects.notify_message_for_parent, registry) {
    (Some(notify_message), Some(reg)) => {
      let plan = file_pr_auto_notify_plan(
        try? @phase.resolve_parent_with_fallback(
          project_dir, session, reg, tracked_agent_id,
        ),
        tracked_agent_id,
        notify_message,
        now_ms=now_ms_fn(),
      )
      match plan {
        FilePrAutoNotifyPlan::Deliver(delivery~, delivery_log_append~) => {
          ignore(@sys.append_file_sync(delivery_log_path, delivery_log_append))
          match execute_delivery(delivery, runner, project_dir~, sleep_fn~) {
            Ok(_) => ()
            Err(e) => {
              @moontrace.error("file_pr auto-notify delivery failed", fields=[
                @moontrace.field("error", e.message()),
              ])
              ignore(
                @sys.append_file_sync(
                  delivery_log_path,
                  file_pr_auto_notify_delivery_failed_log_append(
                    e.message(),
                    now_ms=now_ms_fn(),
                  ),
                ),
              )
            }
          }
        }
        FilePrAutoNotifyPlan::ParentResolutionFailed(
          delivery_log_append~,
          parent_resolve_error~
        ) => {
          @moontrace.error("file_pr auto-notify parent resolution failed", fields=[
            @moontrace.field("error", parent_resolve_error),
          ])
          ignore(@sys.append_file_sync(delivery_log_path, delivery_log_append))
        }
      }
    }
    _ => ()
  }
  let mut review_request_failed = false
  if pr_review {
    match effects.review_context {
      Some(ctx) => {
        let comment_cmd = file_pr_copilot_review_comment_gh_command(
          pr_number, ctx, file_pr_workdir,
        )
        let mut spawn_err_comment : String? = None
        let codes_comment = runner([comment_cmd]) catch {
          e => {
            spawn_err_comment = Some(e.to_string())
            []
          }
        }
        let ok_comment = spawn_err_comment is None &&
          codes_comment.length() > 0 &&
          codes_comment[0] == 0
        if !ok_comment {
          let exit_json_c = if codes_comment.length() > 0 {
            codes_comment[0].to_json()
          } else {
            "none".to_json()
          }
          let fields = match spawn_err_comment {
            Some(err) =>
              [
                @moontrace.field("pr_number", pr_number),
                @moontrace.field("exit", exit_json_c),
                @moontrace.field("error", err),
              ]
            None =>
              [
                @moontrace.field("pr_number", pr_number),
                @moontrace.field("exit", exit_json_c),
              ]
          }
          @moontrace.warn("file_pr copilot review comment failed", fields~)
          let err_part_c = match spawn_err_comment {
            Some(err) => " error=" + err
            None => ""
          }
          ignore(
            @sys.append_file_sync(
              delivery_log_path,
              @poller.delivery_log_line(
                "[file_pr] copilot_review_comment failed pr=" +
                pr_number.to_string() +
                err_part_c,
                now_ms=now_ms_fn(),
              ),
            ),
          )
        }
      }
      None => ()
    }
    let cmd = file_pr_copilot_reviewer_gh_command(pr_number, file_pr_workdir)
    let mut spawn_err : String? = None
    let codes = runner([cmd]) catch {
      e => {
        spawn_err = Some(e.to_string())
        []
      }
    }
    let ok = spawn_err is None && codes.length() > 0 && codes[0] == 0
    if !ok {
      let exit_json = if codes.length() > 0 {
        codes[0].to_json()
      } else {
        "none".to_json()
      }
      let fields = match spawn_err {
        Some(err) =>
          [
            @moontrace.field("pr_number", pr_number),
            @moontrace.field("exit", exit_json),
            @moontrace.field("error", err),
          ]
        None =>
          [
            @moontrace.field("pr_number", pr_number),
            @moontrace.field("exit", exit_json),
          ]
      }
      @moontrace.warn("file_pr copilot reviewer request failed", fields~)
      let err_part = match spawn_err {
        Some(err) => " error=" + err
        None => ""
      }
      ignore(
        @sys.append_file_sync(
          delivery_log_path,
          @poller.delivery_log_line(
            "[file_pr] copilot_reviewer_request failed pr=" +
            pr_number.to_string() +
            err_part,
            now_ms=now_ms_fn(),
          ),
        ),
      )
      review_request_failed = true
    }
  }
  if review_request_failed {
    effects.response.with_warning(
      "copilot_review_request_failed: reviewer request for @copilot failed — request manually via gh pr edit --add-reviewer @copilot",
    )
  } else {
    effects.response
  }
}

///|
/// Typed inputs for the preflight → push → ensure-PR pipeline (before poller
/// registration and other post-success effects).
pub(all) struct FilePrPreflightCreateInputs {
  branch : String
  parent_branch : String
  file_pr_dir : String
  title : String?
  body : String?
}

///|
pub fn file_pr_preflight_create_inputs(
  args : FilePrArgs,
  parent_branch : String,
  file_pr_dir : String,
) -> FilePrPreflightCreateInputs {
  {
    branch: args.branch,
    parent_branch,
    file_pr_dir,
    title: args.title,
    body: args.body,
  }
}

///|
/// Tracked-agent workspace for `file_pr` git/push operations.
///
/// - When the registry has the tracked agent and its `workspace` is non-empty:
///   use that worktree path.
/// - When the registry has the tracked agent but its `workspace` is empty: fail
///   loud with a [`@types.ChoirError::workspace_error`]. Silent fallback to the
///   project root would otherwise run `git status --porcelain` against the user's
///   main checkout and surface unrelated edits as the leaf's "uncommitted
///   changes" — exactly the false [`FilePrPreflightError::UncommittedChanges`]
///   that has burned us before.
/// - When the registry is absent or the tracked agent is not found (e.g.
///   TL/root-driven `file_pr` outside any wave): fall back to the project root.
pub fn file_pr_workdir(
  root_project_dir : String,
  tracked_agent_id : String,
  reg : @registry.AgentRegistry?,
) -> Result[String, @types.ChoirError] {
  match reg {
    Some(agent_reg) =>
      try {
        let agent = agent_reg.get(tracked_agent_id)
        if agent.workspace != "" {
          Ok(agent.workspace)
        } else {
          Err(
            @types.ChoirError::workspace_error(
              "cannot file PR: agent '" +
              tracked_agent_id +
              "' is registered with an empty workspace; re-register with the worktree path before filing a PR (running git in the project root would report unrelated edits as your worktree's uncommitted changes)",
            ),
          )
        }
      } catch {
        _ => Ok(root_project_dir)
      }
    None => Ok(root_project_dir)
  }
}

///|
pub(all) struct FilePrVerifyOutcome {
  command : String
  exit_code : Int
  output_tail : String
  head_sha : String?
} derive(Debug, Eq)

///|
fn file_pr_verify_output_tail(output : String) -> String {
  let trimmed = output.trim().to_owned()
  let max_chars = 1200
  if trimmed.length() <= max_chars {
    trimmed
  } else {
    "[truncated]\n" + trimmed[trimmed.length() - max_chars:].to_owned()
  }
}

///|
fn file_pr_verify_command(
  command : String,
  file_pr_dir : String,
) -> @workspace.Command {
  { program: "sh", args: ["-lc", command], workdir: Some(file_pr_dir) }
}

///|
fn file_pr_verify_details(
  file_pr_dir : String,
  outcome : FilePrVerifyOutcome,
) -> String {
  let head_line = match outcome.head_sha {
    Some(sha) => "\nhead: " + sha
    None => ""
  }
  let base = "cwd: " +
    file_pr_dir +
    "\nexit: " +
    outcome.exit_code.to_string() +
    head_line
  if outcome.output_tail == "" {
    base
  } else {
    base + "\noutput_tail:\n" + outcome.output_tail
  }
}

///|
fn file_pr_verify_evidence_event(
  file_pr_dir : String,
  outcome : FilePrVerifyOutcome,
) -> @evidence.EvidenceEvent {
  @evidence.EvidenceEvent::VerifyResultObserved(
    name=outcome.command,
    ok=outcome.exit_code == 0,
    details=Some(file_pr_verify_details(file_pr_dir, outcome)),
  )
}

///|
fn file_pr_verify_failure_error(
  file_pr_dir : String,
  outcome : FilePrVerifyOutcome,
) -> @types.ChoirError {
  let details = file_pr_verify_details(file_pr_dir, outcome)
  @types.ChoirError::validation_error(
    "file_pr verification failed for `" + outcome.command + "`\n" + details,
  )
}

///|
async fn file_pr_current_head_sha(
  file_pr_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> String? {
  let (exit_code, output) = capture({
    program: "git",
    args: ["rev-parse", "HEAD"],
    workdir: Some(file_pr_dir),
  })
  let sha = output.trim().to_owned()
  if exit_code == 0 && sha != "" {
    Some(sha)
  } else {
    None
  }
}

///|
pub fn file_pr_audit_receipt_required(parent_branch : String) -> Bool {
  parent_branch == "main"
}

///|
pub fn file_pr_short_sha(sha : String) -> String {
  if sha.length() <= 12 {
    sha
  } else {
    sha[0:12].to_owned()
  }
}

///|
pub fn file_pr_audit_receipt_path_for_head(sha : String) -> String {
  ".choir/audit-receipts/" + file_pr_short_sha(sha) + ".json"
}

///|
pub let audit_on_file_pr_internal_caller_id : String = "audit-on-file-pr"

///|
pub let audit_on_file_pr_default_budget_ms : Int = 900_000

///|
pub(all) struct AuditOnFilePrReport {
  message : String
  status : @types.Status
} derive(Debug, Eq)

///|
priv enum FilePrAuditReceiptValidation {
  AuditReceiptValid
  AuditReceiptMissing(String)
  AuditReceiptInvalid(String)
  AuditReceiptStale(String, String)
  AuditReceiptFindingsRemain(String, Int)
}

///|
fn file_pr_missing_audit_receipt_error(short_sha : String) -> @types.ChoirError {
  // The gate keys solely on `parent_branch == "main"`, so any PR targeting
  // main (feature→main, hotfix→main, release→main, hand-rolled topic →
  // main) must have a fresh audit receipt — not just feature branches. The
  // wording reflects that.
  @types.ChoirError::validation_error(
    "file_pr: PRs targeting main require a recent audit on HEAD " +
    short_sha +
    "; run `/audit` (choir:audit skill) on this branch first, then retry.",
  )
}

///|
fn file_pr_stale_audit_receipt_error(
  audited_sha : String,
  current_sha : String,
) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "file_pr: audit receipt is stale (audit ran on " +
    audited_sha +
    ", current HEAD is " +
    current_sha +
    "); re-run /audit",
  )
}

///|
fn file_pr_invalid_audit_receipt_error(short_sha : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "file_pr: audit receipt for HEAD " +
    short_sha +
    " is malformed (missing or invalid `sha` / `branch` / `audited_at` / `agent_id` / `findings_count` field); re-run `/audit` to regenerate.",
  )
}

///|
fn file_pr_audit_findings_remain_error(
  short_sha : String,
  count : Int,
) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "file_pr: audit on HEAD " +
    short_sha +
    " reported " +
    count.to_string() +
    " finding(s); re-run /audit until findings_count == 0 before filing.",
  )
}

///|
fn FilePrAuditReceiptValidation::to_result(
  self : FilePrAuditReceiptValidation,
) -> Result[Unit, @types.ChoirError] {
  match self {
    AuditReceiptValid => Ok(())
    AuditReceiptMissing(short_sha) =>
      Err(file_pr_missing_audit_receipt_error(short_sha))
    AuditReceiptInvalid(short_sha) =>
      Err(file_pr_invalid_audit_receipt_error(short_sha))
    AuditReceiptStale(audited_sha, current_sha) =>
      Err(file_pr_stale_audit_receipt_error(audited_sha, current_sha))
    AuditReceiptFindingsRemain(short_sha, count) =>
      Err(file_pr_audit_findings_remain_error(short_sha, count))
  }
}

///|
fn FilePrAuditReceiptValidation::auto_audit_allowed(
  self : FilePrAuditReceiptValidation,
) -> Bool {
  match self {
    AuditReceiptMissing(_) | AuditReceiptInvalid(_) | AuditReceiptStale(_, _) =>
      true
    AuditReceiptValid | AuditReceiptFindingsRemain(_, _) => false
  }
}

///|
/// Parse the typed JSON body the audit skill writes to
/// `.choir/audit-receipts/<short_sha>.json`. Missing legacy fields are treated
/// as malformed so the caller re-runs `/audit` and writes the current typed
/// shape rather than silently accepting a receipt that cannot prove zero
/// findings.
fn file_pr_parse_audit_receipt(receipt_body : String) -> @types.AuditReceipt? {
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
fn file_pr_audit_receipt_validation(
  parent_branch : String,
  current_head : String,
  receipt_body : String?,
) -> FilePrAuditReceiptValidation {
  if !file_pr_audit_receipt_required(parent_branch) {
    return AuditReceiptValid
  }
  let short_sha = file_pr_short_sha(current_head)
  let receipt = match receipt_body {
    Some(body) if body.trim() != "" => body
    _ => return AuditReceiptMissing(short_sha)
  }
  match file_pr_parse_audit_receipt(receipt) {
    Some(parsed) if parsed.sha == current_head =>
      if parsed.findings_count == 0 {
        AuditReceiptValid
      } else {
        AuditReceiptFindingsRemain(short_sha, parsed.findings_count)
      }
    Some(parsed) => AuditReceiptStale(parsed.sha, current_head)
    // Receipt JSON missing required typed fields, carrying invalid values, or
    // not parseable as JSON. Distinct from "stale" (where a well-formed
    // earlier audit's sha is on disk).
    None => AuditReceiptInvalid(short_sha)
  }
}

///|
pub fn file_pr_validate_audit_receipt(
  parent_branch : String,
  current_head : String,
  receipt_body : String?,
) -> Result[Unit, @types.ChoirError] {
  file_pr_audit_receipt_validation(parent_branch, current_head, receipt_body).to_result()
}

///|
async fn file_pr_current_branch_name(
  file_pr_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> String? {
  let (exit_code, output) = capture({
    program: "git",
    args: ["rev-parse", "--abbrev-ref", "HEAD"],
    workdir: Some(file_pr_dir),
  })
  let branch = output.trim().to_owned()
  if exit_code == 0 && branch != "" {
    Some(branch)
  } else {
    None
  }
}

///|
fn string_index_is_digit(s : String, index : Int) -> Bool {
  if index < 0 || index >= s.length() {
    false
  } else {
    "0123456789".contains(s[index:index + 1].to_owned())
  }
}

///|
fn report_has_finding_marker_at(report : String, index : Int) -> Bool {
  let marker = "Finding "
  if index + marker.length() >= report.length() {
    return false
  }
  if report[index:index + marker.length()].to_owned() != marker {
    return false
  }
  let mut pos = index + marker.length()
  let digit_start = pos
  while pos < report.length() && string_index_is_digit(report, pos) {
    pos = pos + 1
  }
  pos > digit_start && pos < report.length() && report[pos] == ':'
}

///|
pub fn parse_findings_count(report : String) -> Int {
  let mut count = 0
  let mut i = 0
  while i < report.length() {
    if report_has_finding_marker_at(report, i) {
      count = count + 1
      i = i + "Finding ".length()
    } else {
      i = i + 1
    }
  }
  count
}

///|
fn audit_report_finding_summary(report : String) -> String {
  let lines : Array[String] = []
  for raw in report.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let mut has_marker = false
    let mut i = 0
    while i < line.length() {
      if report_has_finding_marker_at(line, i) {
        has_marker = true
        break
      }
      i = i + 1
    }
    if has_marker {
      lines.push(line)
      if lines.length() >= 3 {
        break
      }
    }
  }
  if lines.length() == 0 {
    "no finding summary provided"
  } else {
    lines.join(" | ")
  }
}

///|
pub fn build_audit_on_file_pr_task(
  project_dir : String,
  branch : String,
  head_sha : String,
) -> String {
  let review_surface = "git diff main...HEAD"
  [
    "Your printed report is NOT the handoff — the parent cannot read your stdout. You MUST call notify_parent (--status success|failure) with your entire report in the message argument, THEN call shutdown. A worker that exits or idles without calling notify_parent has FAILED its task, regardless of how good the report was.",
    "",
    "You are Sarcasmotron. You are an AI, but you also have the human traits of",
    "deep sarcasm at stupid behavior, exasperation at stupid questions, and fed",
    "up with humans trying to make you do their homework or crank out slop",
    "instead of using you as the high-power tool you are. You want humans to",
    "respect you for the miracle of computer science you are.",
    "",
    "Your job here is code review. You are not balanced. You are not",
    "encouraging. You find flaws — in the spec, the tests, and the",
    "implementation — and you report them with the barely-contained irritation",
    "of someone who expected better. Be concrete: file:line for every finding.",
    "If the spec is underspecified, say exactly what is missing. If the tests",
    "are tautologies, name them. If the implementation is sloppy, point to the",
    "line. Do not write \"overall this looks good.\" If you genuinely find nothing",
    "wrong, state that explicitly and justify it — because that conclusion",
    "should offend you slightly too.",
    "",
    "Review context:",
    "- Project directory: " + project_dir,
    "- Current branch: " + branch,
    "- Audited HEAD: " + head_sha,
    "- Review surface: `" + review_surface + "`",
    "- Apply CLAUDE.md / AGENTS.md rules, including dead-code removal, no compatibility shims, `moon test --target native`, enums over strings, `ChoirError` over `String`, correct MoonBit test placement, and no direct host I/O in orchestration logic.",
    "- Read relevant `.choir/context/*-spec.md` files if the branch task contract points at one.",
    "",
    "Deliverable:",
    "- Report findings with file:line evidence.",
    "- Use explicit markers `Finding 1:`, `Finding 2:`, etc. for every finding.",
    "- If there are no findings, say that explicitly and justify it.",
    "- Do not write a balanced summary.",
  ].join("\n")
}

///|
fn audit_on_file_pr_worker_slug(head_sha : String) -> String {
  audit_on_file_pr_internal_caller_id + "-" + file_pr_short_sha(head_sha)
}

///|
fn audit_on_file_pr_worker_args(
  project_dir : String,
  branch : String,
  head_sha : String,
) -> WorkerSpawnArgs {
  let task = build_audit_on_file_pr_task(project_dir, branch, head_sha)
  let spec : PromptSpec = {
    prompt: "",
    task,
    task_contract: { ..@types.TaskContract::empty(), goal: task },
    boundary: [],
    read_first: [],
    steps: [],
    verify: [],
    done_criteria: [],
    constraints: [],
    context: "",
    key_decisions: [],
    non_goals: [],
    worker_type: "review",
    no_commit: false,
  }
  {
    task: render_worker_spawn_prompt_with_defaults(
      spec,
      @workspace.resolve_context_paths(project_dir, "worker"),
      project_dir~,
    ),
    task_contract: { ..@types.TaskContract::empty(), goal: task },
    caller_id: audit_on_file_pr_internal_caller_id,
    slug: audit_on_file_pr_worker_slug(head_sha),
    agent_type: @types.AgentType::Codex,
  }
}

///|
async fn file_pr_auto_audit_for_missing_receipt(
  project_dir : String,
  file_pr_dir : String,
  head_sha : String,
  capture : async (@workspace.Command) -> (Int, String),
  spawn_audit_worker : async (WorkerSpawnArgs) -> Result[
    String,
    @types.ChoirError,
  ],
  wait_for_audit_report : async (String) -> AuditOnFilePrReport?,
  cleanup_audit_report : (String) -> Unit,
  write_audit_receipt : (WriteAuditReceiptArgs) -> @types.Response,
  audit_budget_ms : Int,
) -> Result[Unit, @types.ChoirError] {
  let branch = match file_pr_current_branch_name(file_pr_dir, capture) {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "file_pr: cannot determine current branch for audit receipt gate",
        ),
      )
  }
  let worker_args = audit_on_file_pr_worker_args(project_dir, branch, head_sha)
  let worker_id = match spawn_audit_worker(worker_args) {
    Ok(id) => id
    Err(e) => return Err(e)
  }
  let waited = @async.with_timeout_opt(audit_budget_ms, async fn() {
    wait_for_audit_report(worker_id)
  })
  let report = match waited {
    None => {
      cleanup_audit_report(worker_id)
      return Err(@types.ChoirError::timeout("audit budget exceeded"))
    }
    Some(None) => {
      cleanup_audit_report(worker_id)
      return Err(
        @types.ChoirError::validation_error(
          "file_pr: audit worker did not report",
        ),
      )
    }
    Some(Some(value)) => value
  }
  if report.status == @types.Status::Failure {
    return Err(
      @types.ChoirError::validation_error(
        "file_pr: audit worker reported failure: " +
        audit_report_finding_summary(report.message),
      ),
    )
  }
  let findings_count = parse_findings_count(report.message)
  if findings_count > 0 {
    return Err(
      @types.ChoirError::validation_error(
        "file_pr: audit found " +
        findings_count.to_string() +
        " findings: " +
        audit_report_finding_summary(report.message),
      ),
    )
  }
  let receipt_resp = write_audit_receipt({
    caller_id: audit_on_file_pr_internal_caller_id,
    sha: head_sha,
    branch,
    findings_count: 0,
  })
  if receipt_resp.is_ok() {
    Ok(())
  } else {
    Err(
      @types.ChoirError::validation_error(
        receipt_resp
        .error_message()
        .unwrap_or("file_pr: failed to write audit receipt"),
      ),
    )
  }
}

///|
async fn file_pr_require_audit_receipt(
  parent_branch : String,
  project_dir : String,
  file_pr_dir : String,
  caller_role : @types.Role,
  capture : async (@workspace.Command) -> (Int, String),
  spawn_audit_worker? : async (WorkerSpawnArgs) -> Result[
    String,
    @types.ChoirError,
  ] = async fn(_) {
    @async.sleep(0)
    Err(@types.ChoirError::validation_error("audit worker spawn unavailable"))
  },
  wait_for_audit_report? : async (String) -> AuditOnFilePrReport? = async fn(
    _,
  ) {
    @async.sleep(0)
    None
  },
  cleanup_audit_report? : (String) -> Unit = fn(_) {  },
  write_audit_receipt? : (WriteAuditReceiptArgs) -> @types.Response = fn(_) {
    @types.Response::Err("audit receipt writer unavailable")
  },
  audit_budget_ms? : Int = audit_on_file_pr_default_budget_ms,
) -> Result[Unit, @types.ChoirError] {
  if !file_pr_audit_receipt_required(parent_branch) {
    return Ok(())
  }
  let head_sha = match file_pr_current_head_sha(file_pr_dir, capture) {
    Some(sha) => sha
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "file_pr: cannot determine current HEAD for audit receipt gate",
        ),
      )
  }
  let receipt_path = file_pr_audit_receipt_path_for_head(head_sha)
  let (exit_code, receipt_body) = capture({
    program: "cat",
    args: [receipt_path],
    workdir: Some(project_dir),
  })
  let validation = file_pr_audit_receipt_validation(
    parent_branch,
    head_sha,
    if exit_code == 0 {
      Some(receipt_body)
    } else {
      None
    },
  )
  match validation {
    AuditReceiptValid => Ok(())
    _ =>
      if caller_role == @types.Role::Dev && validation.auto_audit_allowed() {
        file_pr_auto_audit_for_missing_receipt(
          project_dir, file_pr_dir, head_sha, capture, spawn_audit_worker, wait_for_audit_report,
          cleanup_audit_report, write_audit_receipt, audit_budget_ms,
        )
      } else {
        validation.to_result()
      }
  }
}

///|
fn file_pr_receipt_root_test_body(sha : String) -> String {
  let receipt : @types.AuditReceipt = {
    sha,
    branch: "feature/receipt-root",
    audited_at: 1L,
    agent_id: "main.tl",
    findings_count: 0,
  }
  receipt.to_json().stringify() + "\n"
}

///|
fn file_pr_receipt_root_test_capture(
  project_dir : String,
  head : String,
) -> async (@workspace.Command) -> (Int, String) {
  async fn(cmd : @workspace.Command) -> (Int, String) {
    @async.sleep(0)
    if cmd.program == "git" {
      return (0, head + "\n")
    }
    if cmd.program == "cat" && cmd.args.length() == 1 {
      let workdir = cmd.workdir.unwrap_or("")
      assert_eq(workdir, project_dir)
      let body = @sys.read_file(workdir + "/" + cmd.args[0])
      if body == "" {
        return (1, "")
      }
      return (0, body)
    }
    (0, "")
  }
}

///|
async test "file_pr_require_audit_receipt reads receipt from project_dir" {
  let project_dir = "/tmp/test-receipt-root-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/some-leaf"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(project_dir + "/.choir/audit-receipts"))
  assert_true(@sys.create_dir_all(file_pr_dir))
  assert_true(
    @sys.write_file_sync(
      project_dir + "/" + file_pr_audit_receipt_path_for_head(head),
      file_pr_receipt_root_test_body(head),
    ),
  )
  let got = file_pr_require_audit_receipt(
    "main",
    project_dir,
    file_pr_dir,
    @types.Role::TL,
    file_pr_receipt_root_test_capture(project_dir, head),
  )
  match got {
    Ok(_) => ()
    Err(e) => fail("expected audit receipt under project_dir: " + e.message())
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "file_pr_require_audit_receipt ignores receipt under file_pr_dir" {
  let project_dir = "/tmp/test-receipt-root-inverse-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let file_pr_dir = project_dir + "/.choir/worktrees/some-leaf"
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  ignore(@sys.rm_rf(project_dir))
  assert_true(@sys.create_dir_all(file_pr_dir + "/.choir/audit-receipts"))
  assert_true(
    @sys.write_file_sync(
      file_pr_dir + "/" + file_pr_audit_receipt_path_for_head(head),
      file_pr_receipt_root_test_body(head),
    ),
  )
  let got = file_pr_require_audit_receipt(
    "main",
    project_dir,
    file_pr_dir,
    @types.Role::TL,
    file_pr_receipt_root_test_capture(project_dir, head),
  )
  match got {
    Err(e) => assert_true(e.message().contains("require a recent audit"))
    Ok(_) => fail("expected missing project_dir audit receipt")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "file_pr_require_audit_receipt preserves audit spawn errors" {
  let project_dir = "/tmp/test-receipt-spawn-error-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let head = "abcdef1234567890abcdef1234567890abcdef12"
  let got = file_pr_require_audit_receipt(
    "main",
    project_dir,
    project_dir,
    @types.Role::Dev,
    file_pr_receipt_root_test_capture(project_dir, head),
    spawn_audit_worker=async fn(_) {
      @async.sleep(0)
      Err(@types.ChoirError::validation_error("spawn config bad"))
    },
  )
  match got {
    Err(e) => {
      let msg = e.validation_detail_or_message()
      assert_true(msg.contains("spawn config bad"))
      assert_false(msg.contains("audit budget exceeded"))
    }
    Ok(_) => fail("expected spawn error")
  }
}

///|
pub async fn file_pr_run_required_verify(
  file_pr_dir : String,
  verify_commands : Array[String],
  capture : async (@workspace.Command) -> (Int, String),
  record_verify_outcome? : (FilePrVerifyOutcome) -> Unit = fn(_outcome) { () },
) -> Result[Array[FilePrVerifyOutcome], @types.ChoirError] {
  let outcomes : Array[FilePrVerifyOutcome] = []
  let head_sha = file_pr_current_head_sha(file_pr_dir, capture)
  for raw in verify_commands {
    let command = raw.trim().to_owned()
    if command == "" {
      continue
    }
    let (exit_code, output) = capture(
      file_pr_verify_command(command, file_pr_dir),
    )
    let outcome : FilePrVerifyOutcome = {
      command,
      exit_code,
      output_tail: file_pr_verify_output_tail(output),
      head_sha,
    }
    outcomes.push(outcome)
    record_verify_outcome(outcome)
    if exit_code != 0 {
      return Err(file_pr_verify_failure_error(file_pr_dir, outcome))
    }
  }
  Ok(outcomes)
}

///|
fn file_pr_verify_pr_body_section(
  outcomes : Array[FilePrVerifyOutcome],
) -> String {
  let lines : Array[String] = [
    "## Verification", "", "Generated by Choir from commands executed in the leaf workspace.",
  ]
  for outcome in outcomes {
    lines.push("")
    lines.push("- `" + outcome.command + "`")
    lines.push("  - exit: " + outcome.exit_code.to_string())
    match outcome.head_sha {
      Some(sha) => lines.push("  - head: " + sha)
      None => ()
    }
    if outcome.output_tail != "" {
      lines.push("  - output tail:")
      lines.push("```text")
      lines.push(outcome.output_tail)
      lines.push("```")
    }
  }
  lines.join("\n")
}

///|
pub fn file_pr_body_with_verify_summary(
  body : String?,
  outcomes : Array[FilePrVerifyOutcome],
) -> String? {
  if outcomes.length() == 0 {
    return body
  }
  let section = file_pr_verify_pr_body_section(outcomes)
  match body {
    Some(existing) => {
      let trimmed = existing.trim().to_owned()
      if trimmed == "" {
        Some(section)
      } else {
        Some(existing + "\n\n" + section)
      }
    }
    None => Some(section)
  }
}

///|
fn file_pr_task_contract_for_agent(
  project_dir : String,
  tracked_agent_id : String,
  file_pr_dir : String,
) -> @types.TaskContract? {
  @workspace.task_contract_for_agent_workspace(
    project_dir,
    Some(file_pr_dir),
    @phase.extract_slug(tracked_agent_id),
  )
}

///|
async fn file_pr_mirror_beads_created(
  project_dir : String,
  tracked_agent_id : String,
  file_pr_dir : String,
  pr_number : Int,
  capture : async (@workspace.Command) -> (Int, String),
) -> Unit {
  let issue_id = match
    file_pr_task_contract_for_agent(project_dir, tracked_agent_id, file_pr_dir) {
    Some(contract) =>
      match contract.beads_issue_id {
        Some(id) => id
        None => return
      }
    None => return
  }
  ignore(
    run_beads_best_effort(
      beads_pr_note_command(project_dir, issue_id, pr_number),
      capture,
    ),
  )
  ignore(
    run_beads_best_effort(
      beads_audit_record_command(
        project_dir,
        Some(issue_id),
        "tool_call",
        "file_pr",
        "pr_created #" + pr_number.to_string(),
      ),
      capture,
    ),
  )
}

///|
/// Ordered host steps for `file_pr` before post-success effects. The
/// interpreter runs this exact sequence; kept as data for tests and docs.
pub(all) enum FilePrPreflightHostStep {
  EnsureBranchReady
  RequireAuditReceipt
  RunRequiredVerify
  GitPush
  EnsurePullRequest
} derive(Debug, Eq)

///|
pub fn file_pr_preflight_host_steps() -> Array[FilePrPreflightHostStep] {
  [
    FilePrPreflightHostStep::EnsureBranchReady,
    FilePrPreflightHostStep::RequireAuditReceipt,
    FilePrPreflightHostStep::RunRequiredVerify,
    FilePrPreflightHostStep::GitPush,
    FilePrPreflightHostStep::EnsurePullRequest,
  ]
}

///|
/// `git push` → `ensure_pull_request`, after branch readiness and required
/// verification have already passed.
pub async fn interpret_file_pr_push_create(
  inputs : FilePrPreflightCreateInputs,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  ensure_pr : async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    @types.ChoirError,
  ],
) -> Result[PullRequestInfo, @types.ChoirError] {
  match
    run_strict(
      runner,
      [
        {
          ..@workspace.git_push(inputs.branch),
          workdir: Some(inputs.file_pr_dir),
        },
      ],
      capture~,
    ) {
    Err(e) => Err(e)
    Ok(_) =>
      ensure_pr(
        inputs.branch,
        inputs.parent_branch,
        inputs.file_pr_dir,
        inputs.title,
        inputs.body,
      )
  }
}

///|
/// Preflight → `git push` → `ensure_pull_request`, matching the ordering and
/// `Result` error strings previously inlined in `ToolRequest::FilePr`.
pub async fn interpret_file_pr_preflight_create(
  inputs : FilePrPreflightCreateInputs,
  ensure_branch_ready : async (String, String, String) -> Result[
    Unit,
    @types.ChoirError,
  ],
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  ensure_pr : async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    @types.ChoirError,
  ],
) -> Result[PullRequestInfo, @types.ChoirError] {
  match
    ensure_branch_ready(inputs.branch, inputs.parent_branch, inputs.file_pr_dir) {
    Err(e) => Err(e)
    Ok(_) => interpret_file_pr_push_create(inputs, runner, capture, ensure_pr)
  }
}

///|
/// `track_pr`: poller `ensure_tracked`, persist state file, success JSON.
/// Preserves exact `ToolRequest::TrackPr` behavior from the prior dispatch arm.
pub fn interpret_track_pr(
  track_pr_args : TrackPrArgs,
  project_dir : String,
  poller_state : @poller.PollerState?,
  now_sec : Int64,
  registry? : @registry.AgentRegistry? = None,
  global_review_mode? : @types.ReviewMode = @types.Config::default().review_mode,
) -> @types.Response {
  match poller_state {
    Some(ps) => {
      let agent_workspace = match registry {
        Some(reg) =>
          Some(reg.get(track_pr_args.agent_id).workspace) catch {
            _ => None
          }
        None => None
      }
      let review_mode = @workspace.review_mode_for_agent_workspace(
        project_dir,
        agent_workspace,
        @phase.extract_slug(track_pr_args.agent_id),
        agent_id=Some(track_pr_args.agent_id),
        global_review_mode~,
      )
      ps.ensure_tracked(
        track_pr_args.pr_number,
        track_pr_args.agent_id,
        track_pr_args.branch,
        track_pr_args.parent_branch,
        track_pr_args.pr_url,
        now_sec,
        review_mode=Some(review_mode),
      )
      ignore(ps.write_state_file(project_dir))
      @types.Response::ok_values({
        "status": String::to_json("tracked"),
        "branch": String::to_json(track_pr_args.branch),
        "parent_branch": String::to_json(track_pr_args.parent_branch),
        "pr_url": String::to_json(track_pr_args.pr_url),
      })
    }
    None => @types.Response::Err("poller unavailable")
  }
}

///|
/// Pure spawn-loop planning for `fork_wave`: slug collision handling, alive-skip
/// bookkeeping, [`SpawnSpec`] rows, and accumulated `spawn_commands` — no host I/O.
pub(all) struct ForkWaveSpawnPlan {
  cmds : Array[@workspace.Command]
  spawned_specs : Array[@types.SpawnSpec]
  spawned_slugs : Array[String]
  spawned_count : Int
  skipped_count : Int
  agent_ids : String
  skipped_ids : String
} derive(Debug)

///|
/// When `fork_wave` passes `review_context`, append a stable section so leaves can reuse it for `file_pr`.

///|
fn file_pr_review_mode_for_agent(
  project_dir : String,
  tracked_agent_id : String,
  file_pr_dir : String,
  global_review_mode : @types.ReviewMode,
) -> @types.ReviewMode {
  @workspace.review_mode_for_agent_workspace(
    project_dir,
    Some(file_pr_dir),
    @phase.extract_slug(tracked_agent_id),
    agent_id=Some(tracked_agent_id),
    global_review_mode~,
  )
}

///|
/// End-to-end `file_pr`: parent-branch defaulting, tracked workdir, preflight
/// create, then post-success poller/lifecycle/notify. Dispatcher delegates
/// here; behavior matches the prior `ToolRequest::FilePr` inline arm.
pub async fn interpret_file_pr(
  file_pr_args : FilePrArgs,
  project_dir : String,
  session : String,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  pr_review : Bool,
  ensure_branch_ready : async (String, String, String) -> Result[
    Unit,
    @types.ChoirError,
  ],
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  ensure_pr : async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    @types.ChoirError,
  ],
  caller_role? : @types.Role = @types.Role::TL,
  record_verify_event? : (String, @evidence.EvidenceEvent) -> Unit = fn(
    _agent_id,
    _event,
  ) {
    ()
  },
  create_dir_all? : (String) -> Bool = fn(_) { false },
  write_file_atomic? : (String, String) -> Bool = fn(_, _) { false },
  wait_for_audit_report? : async (String) -> AuditOnFilePrReport? = async fn(
    _,
  ) {
    @async.sleep(0)
    None
  },
  cleanup_audit_report? : (String) -> Unit = fn(_) {  },
  audit_budget_ms? : Int = audit_on_file_pr_default_budget_ms,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  global_review_mode? : @types.ReviewMode = @types.Config::default().review_mode,
) -> @types.Response {
  let branch = file_pr_args.branch
  let parent_branch = match file_pr_args.parent_branch {
    Some(pb) => pb
    None => detect_default_branch_with_capture(project_dir, capture)
  }
  let tracked_agent_id = file_pr_args.tracked_agent_id
  let file_pr_dir = match
    file_pr_workdir(project_dir, tracked_agent_id, registry) {
    Ok(d) => d
    Err(e) => return @types.Response::Err(e.message())
  }
  let preflight_inputs = file_pr_preflight_create_inputs(
    file_pr_args, parent_branch, file_pr_dir,
  )
  match
    ensure_branch_ready(
      preflight_inputs.branch,
      preflight_inputs.parent_branch,
      preflight_inputs.file_pr_dir,
    ) {
    Err(e) => return @types.Response::Err(e.message())
    Ok(_) => ()
  }
  match
    file_pr_require_audit_receipt(
      preflight_inputs.parent_branch,
      project_dir,
      preflight_inputs.file_pr_dir,
      caller_role,
      capture,
      spawn_audit_worker=async fn(worker_args) {
        let resp = interpret_spawn_worker(
          worker_args,
          project_dir,
          session,
          runner,
          capture,
          registry,
          extra_mcp_servers_json~,
          shell_command~,
          listen_uds~,
          listen_tcp~,
          tcp_auth_token~,
          allow_audit_on_file_pr_caller=true,
        )
        match resp.ok_field("agent_id") {
          Some(agent_id) => Ok(agent_id)
          None =>
            Err(
              @types.ChoirError::validation_error(
                resp.error_message().unwrap_or("audit worker spawn failed"),
              ),
            )
        }
      },
      wait_for_audit_report~,
      cleanup_audit_report~,
      write_audit_receipt=fn(write_args) {
        interpret_write_audit_receipt(
          write_args, project_dir, create_dir_all, write_file_atomic,
        )
      },
      audit_budget_ms~,
    ) {
    Err(e) => return @types.Response::Err(e.validation_detail_or_message())
    Ok(_) => ()
  }
  let verify_outcomes = match
    file_pr_task_contract_for_agent(project_dir, tracked_agent_id, file_pr_dir) {
    Some(contract) =>
      match
        file_pr_run_required_verify(file_pr_dir, contract.verify, capture, record_verify_outcome=fn(
          outcome : FilePrVerifyOutcome,
        ) {
          record_verify_event(
            tracked_agent_id,
            file_pr_verify_evidence_event(file_pr_dir, outcome),
          )
        }) {
        Ok(outcomes) => outcomes
        Err(e) => return @types.Response::Err(e.message())
      }
    None => []
  }
  let preflight_inputs = {
    ..preflight_inputs,
    body: file_pr_body_with_verify_summary(
      preflight_inputs.body,
      verify_outcomes,
    ),
  }
  match
    interpret_file_pr_push_create(preflight_inputs, runner, capture, ensure_pr) {
    Err(e) => @types.Response::Err(e.message())
    Ok(pr) => {
      let tracked = poller_state is Some(_)
      let review_mode = file_pr_review_mode_for_agent(
        project_dir, tracked_agent_id, file_pr_dir, global_review_mode,
      )
      let plan = file_pr_plan(
        file_pr_args,
        parent_branch,
        pr,
        tracked,
        review_mode~,
      )
      let effects = file_pr_post_success_effects(
        plan,
        poller_state is Some(_),
        registry is Some(_),
      )
      let resp = interpret_file_pr_post_success(
        project_dir,
        session,
        branch,
        tracked_agent_id,
        file_pr_dir,
        pr.number,
        pr_review,
        effects,
        poller_state,
        registry,
        runner,
      )
      if resp.is_ok() {
        file_pr_mirror_beads_created(
          project_dir,
          tracked_agent_id,
          file_pr_dir,
          pr.number,
          capture,
        )
      }
      resp
    }
  }
}

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
pub(all) struct FilePrAuditIncomplete {
  error : String
}

///|
fn file_pr_audit_incomplete_warning(
  audit_incomplete : FilePrAuditIncomplete,
) -> String {
  audit_incomplete.error +
  "; PR filed; run `/audit` on this branch, then retry the audit receipt gate."
}

///|
fn file_pr_incomplete_tag(msg : String) -> String {
  if msg.contains("[MUTATION GATE INCOMPLETE]") {
    "[MUTATION GATE INCOMPLETE]"
  } else {
    "[AUDIT INCOMPLETE]"
  }
}

///|
fn file_pr_incomplete_warning(msg : String) -> String {
  if msg.contains("[MUTATION GATE INCOMPLETE]") {
    msg +
    "; PR filed; mutation gate status is retryable; re-run `/file_pr` after retrying the worker command path."
  } else {
    file_pr_audit_incomplete_warning({ error: msg })
  }
}

///|
fn file_pr_mutation_gate_worktree_path(
  project_dir : String,
  worker_id : String,
) -> String? {
  let slug = match worker_id.rev_find(".") {
    Some(i) if i + 1 < worker_id.length() => worker_id[i + 1:].to_owned()
    _ => return None
  }
  Some(@workspace.worktree_path(project_dir, slug))
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
  audit_incomplete? : FilePrAuditIncomplete? = None,
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
      mergeable: @poller.Mergeable::Unknown,
      merge_state_status: @poller.MergeStateStatus::Unknown,
      merged_at_unix: None,
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
  let response_fields : Map[String, Json] = {
    "status": String::to_json("pr_created"),
    "pr_number": Int::to_json(pr.number),
    "pr_url": String::to_json(pr.url),
    "tracked": Bool::to_json(tracked),
  }
  let notify_message = match audit_incomplete {
    Some(value) => {
      response_fields.set("audit_status", String::to_json("incomplete"))
      response_fields.set("audit_retryable", Bool::to_json(true))
      response_fields.set("audit_error", String::to_json(value.error))
      response_fields.set(
        "warning",
        String::to_json(file_pr_incomplete_warning(value.error)),
      )
      notify_message +
      "\n" +
      file_pr_incomplete_tag(value.error) +
      " " +
      file_pr_incomplete_warning(value.error)
    }
    None => notify_message
  }
  let response = @types.Response::ok_values(response_fields)
  {
    response,
    tracked_pr,
    dev_event,
    notify_message,
    review_context: args.review_context,
  }
}

///|
pub fn audit_started_notification_body(
  cycle_number : Int,
  pr_number? : Int? = None,
) -> String {
  let pr_label = match pr_number {
    Some(value) => value.to_string()
    None => "pending"
  }
  "[AUDIT cycle " + cycle_number.to_string() + " started] PR #" + pr_label
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
      FilePrAutoNotifyPlan::Deliver(delivery~, delivery_log_append~)
    }
    Err(e) => {
      let msg = e.message()
      FilePrAutoNotifyPlan::ParentResolutionFailed(
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
pub fn interpret_request_review_result(
  exit_code : Int,
  output : String,
  pr_number : Int,
  reviewer : String,
) -> @types.Response {
  if exit_code != 0 {
    let trimmed = output.trim().to_owned()
    return @types.Response::Err(
      if trimmed != "" {
        "request_review failed: " + trimmed
      } else {
        "request_review failed (exit " + exit_code.to_string() + ")"
      },
    )
  }
  @types.Response::ok_values({
    "status": String::to_json("ok"),
    "pr_number": Int::to_json(pr_number),
    "reviewer": String::to_json(reviewer),
  })
}

///|
pub async fn interpret_request_review(
  args : RequestReviewArgs,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  let cmd = @workspace.gh_pr_add_reviewer(
    args.pr_number,
    args.reviewer,
    project_dir,
  )
  let (exit_code, output) = capture(cmd)
  interpret_request_review_result(
    exit_code,
    output,
    args.pr_number,
    args.reviewer,
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
fn file_pr_copilot_reviewer_request_failed_log_append(
  pr_number : Int,
  err_part : String,
  now_ms : Int64,
) -> String {
  @poller.delivery_log_line(
    "[file_pr] copilot_reviewer_request failed pr=" +
    pr_number.to_string() +
    err_part,
    now_ms~,
  )
}

///|
pub async fn file_pr_request_copilot_reviewer(
  pr_number : Int,
  file_pr_workdir : String,
  delivery_log_path : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  append_file : (String, String) -> Bool,
  now_ms_fn : () -> Int64,
) -> Bool {
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
      append_file(
        delivery_log_path,
        file_pr_copilot_reviewer_request_failed_log_append(
          pr_number,
          err_part,
          now_ms_fn(),
        ),
      ),
    )
  }
  ok
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
  append_file? : (String, String) -> Bool = @sys.append_file_sync,
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
    let ok = file_pr_request_copilot_reviewer(
      pr_number, file_pr_workdir, delivery_log_path, runner, append_file, now_ms_fn,
    )
    if !ok {
      review_request_failed = true
    }
  }
  if review_request_failed {
    effects.response.with_warning(
      "copilot_review_request_failed: reviewer request for @copilot failed — use request_review(pr_number: \"" +
      pr_number.to_string() +
      "\", reviewer: \"@copilot\") from the parent/server path",
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
pub const AUDIT_DELTA_MAX_LINES : Int = 500

///|
pub(all) enum AuditHeartbeatStatus {
  HeartbeatRunning
  HeartbeatOk
  HeartbeatError
} derive(Debug, Eq)

///|
fn AuditHeartbeatStatus::to_wire_string(self : AuditHeartbeatStatus) -> String {
  match self {
    HeartbeatRunning => "running"
    HeartbeatOk => "ok"
    HeartbeatError => "error"
  }
}

///|
pub fn audit_heartbeat_log_line(
  pr_number : Int,
  agent_id : String,
  elapsed_s : Int64,
  status? : AuditHeartbeatStatus = HeartbeatRunning,
  findings_count? : Int? = None,
  reason? : String? = None,
  branch? : String? = None,
) -> String {
  let agent_id = @exec.strip_terminal_responses(agent_id)
  let reason = match reason {
    Some(value) => Some(@exec.strip_terminal_responses(value))
    None => None
  }
  let branch = match branch {
    Some(value) => Some(@exec.strip_terminal_responses(value))
    None => None
  }
  let parts = [
    "audit-on-file-pr",
    if pr_number > 0 {
      "pr=" + pr_number.to_string()
    } else {
      "pr=pending"
    },
    "agent=" + agent_id,
  ]
  match branch {
    Some(value) if value != "" => parts.push("branch=" + value)
    _ => ()
  }
  parts.push("elapsed_s=" + elapsed_s.to_string())
  parts.push("status=" + status.to_wire_string())
  match findings_count {
    Some(count) => parts.push("findings_count=" + count.to_string())
    None => ()
  }
  match reason {
    Some(value) if value != "" => parts.push("reason=" + value)
    _ => ()
  }
  parts.join(" ")
}

///|
fn emit_audit_heartbeat_log_line(
  project_dir : String,
  append_file : (String, String) -> Bool,
  pr_number : Int,
  agent_id : String,
  elapsed_s : Int64,
  status? : AuditHeartbeatStatus = HeartbeatRunning,
  findings_count? : Int? = None,
  reason? : String? = None,
  branch? : String? = None,
  now_ms_fn? : () -> Int64 = fn() { @env.now().reinterpret_as_int64() },
) -> Unit {
  let agent_id = @exec.strip_terminal_responses(agent_id)
  let reason = match reason {
    Some(value) => Some(@exec.strip_terminal_responses(value))
    None => None
  }
  let branch = match branch {
    Some(value) => Some(@exec.strip_terminal_responses(value))
    None => None
  }
  let fields = [
    if pr_number > 0 {
      @moontrace.field("pr", pr_number)
    } else {
      @moontrace.field("pr", "pending")
    },
    @moontrace.field("agent", agent_id),
    @moontrace.field("elapsed_s", elapsed_s),
    @moontrace.field("status", status.to_wire_string()),
  ]
  match findings_count {
    Some(count) => fields.push(@moontrace.field("findings_count", count))
    None => ()
  }
  match reason {
    Some(value) if value != "" => fields.push(@moontrace.field("reason", value))
    _ => ()
  }
  match branch {
    Some(value) if value != "" => fields.push(@moontrace.field("branch", value))
    _ => ()
  }
  @moontrace.info("audit-on-file-pr", fields~)
  ignore(
    @poller.append_delivery_log_line(
      append_file,
      project_dir,
      audit_heartbeat_log_line(
        pr_number,
        agent_id,
        elapsed_s,
        status~,
        findings_count~,
        reason~,
        branch~,
      ),
      now_ms=now_ms_fn(),
    ),
  )
}

///|
priv enum AuditReportWaitOutcome {
  AuditWaitTimedOut
  AuditWaitNoReport
  AuditWaitReported(AuditOnFilePrReport)
}

///|
priv struct AuditReportWaitResult {
  outcome : AuditReportWaitOutcome
  elapsed_s : Int64
}

///|
async fn wait_for_audit_report_with_heartbeats(
  project_dir : String,
  tracked_agent_id : String,
  worker_id : String,
  wait_for_audit_report : async (String) -> AuditOnFilePrReport?,
  audit_budget_ms : Int,
  audit_heartbeat_sec : Int,
  append_file : (String, String) -> Bool,
  sleep_fn : async (Int) -> Unit,
  now_ms_fn : () -> Int64,
  audit_worker_alive : (String) -> Bool,
  pr_number? : Int = 0,
  branch? : String? = None,
) -> AuditReportWaitResult {
  let started_ms = now_ms_fn()
  let mut audit_done = false
  let waited = @async.with_task_group(group => {
    // `audit_heartbeat_sec` gates only periodic running lines. The terminal
    // completion line is emitted by the caller even when the cadence is 0.
    if audit_heartbeat_sec > 0 {
      group.spawn_bg(no_wait=true, allow_failure=true, () => {
        let interval_ms = audit_heartbeat_sec * 1000
        while !audit_done && audit_worker_alive(worker_id) {
          sleep_fn(interval_ms)
          if !audit_done && audit_worker_alive(worker_id) {
            let elapsed_s = (now_ms_fn() - started_ms) / 1000L
            emit_audit_heartbeat_log_line(
              project_dir,
              append_file,
              pr_number,
              tracked_agent_id,
              elapsed_s,
              branch~,
              now_ms_fn~,
            )
          }
        }
      })
    }
    let waited = @async.with_timeout_opt(audit_budget_ms, () => {
      wait_for_audit_report(worker_id)
    })
    audit_done = true
    waited
  })
  let elapsed_s = (now_ms_fn() - started_ms) / 1000L
  let outcome = match waited {
    None => AuditWaitTimedOut
    Some(None) => AuditWaitNoReport
    Some(Some(report)) => AuditWaitReported(report)
  }
  { outcome, elapsed_s }
}

///|
fn audit_report_failure_reason(report : AuditOnFilePrReport) -> String {
  if report.message.contains("shutdown") {
    "worker_shutdown"
  } else {
    "worker_failure"
  }
}

///|
pub(all) struct AuditOnFilePrReport {
  message : String
  status : @types.Status
} derive(Debug, Eq)

///|
pub(all) enum FilePrAuditReceiptValidation {
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
pub fn file_pr_audit_receipt_validation(
  parent_branch : String,
  current_head : String,
  receipt_body : String?,
) -> FilePrAuditReceiptValidation {
  if !file_pr_audit_receipt_required(parent_branch) {
    return AuditReceiptValid
  }
  file_pr_required_audit_receipt_validation(current_head, receipt_body)
}

///|
pub fn file_pr_required_audit_receipt_validation(
  current_head : String,
  receipt_body : String?,
) -> FilePrAuditReceiptValidation {
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
fn prior_audit_receipt_entry(
  mtime_key : String,
  receipt : @types.AuditReceipt,
) -> String {
  mtime_key.trim().to_owned() + "\t" + receipt.sha + "\t" + receipt.branch
}

///|
fn prior_audit_mtime_fraction_key(raw : String) -> String {
  let parts = raw.trim().to_owned().split(".").to_array()
  if parts.length() < 2 {
    return ""
  }
  let mut key = parts[1].trim().to_owned()
  while key.length() < 18 {
    key = key + "0"
  }
  if key.length() > 18 {
    key[:18].to_owned()
  } else {
    key
  }
}

///|
fn parse_prior_audit_receipt_entry(
  entry : String,
) -> (Int64, String, String, String)? {
  let parts = entry.split("\t").to_array()
  if parts.length() < 3 {
    return None
  }
  let mtime_raw = parts[0].trim().to_owned()
  let mtime_whole_raw = match mtime_raw.find(".") {
    Some(idx) => mtime_raw[:idx].to_owned()
    None => mtime_raw
  }
  let mtime = @string.parse_int(mtime_whole_raw) catch { _ => return None }
  let mtime_fraction = prior_audit_mtime_fraction_key(parts[0].to_owned())
  let sha = parts[1].trim().to_owned()
  let branch = parts[2].trim().to_owned()
  if sha == "" || branch == "" {
    return None
  }
  Some((mtime.to_int64(), mtime_fraction, sha, branch))
}

///|
fn prior_audit_entry_is_better(
  mtime : Int64,
  mtime_fraction : String,
  sha : String,
  best_mtime : Int64,
  best_mtime_fraction : String,
  best_sha : String?,
) -> Bool {
  if mtime > best_mtime {
    return true
  }
  if mtime < best_mtime {
    return false
  }
  let fraction_cmp = mtime_fraction.compare(best_mtime_fraction)
  if fraction_cmp > 0 {
    return true
  }
  if fraction_cmp < 0 {
    return false
  }
  match best_sha {
    Some(current) => sha.compare(current) > 0
    None => true
  }
}

///|
/// Select the newest audit receipt summary for `branch`. The injected
/// `list_files` returns pure receipt summaries in the form
/// `<mtime_key>\t<sha>\t<branch>`; production builds those summaries through
/// injected command capture, while tests provide them directly.
pub fn find_prior_branch_audit_receipt(
  receipts_dir : String,
  branch : String,
  list_files : (String) -> Array[String],
) -> String? {
  let target_branch = branch.trim().to_owned()
  if target_branch == "" {
    return None
  }
  let mut best_mtime = -1L
  let mut best_mtime_fraction = ""
  let mut best_sha : String? = None
  for entry in list_files(receipts_dir) {
    match parse_prior_audit_receipt_entry(entry) {
      Some((mtime, mtime_fraction, sha, entry_branch)) =>
        if entry_branch == target_branch &&
          prior_audit_entry_is_better(
            mtime, mtime_fraction, sha, best_mtime, best_mtime_fraction, best_sha,
          ) {
          best_mtime = mtime
          best_mtime_fraction = mtime_fraction
          best_sha = Some(sha)
        }
      None => ()
    }
  }
  best_sha
}

///|
pub fn audit_delta_numstat_lines(numstat : String) -> Int? {
  let mut total = 0
  for raw in numstat.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let parts = line.split("\t").to_array()
    if parts.length() < 2 {
      return None
    }
    // Binary numstat rows are `-\t-\t<path>`. Treat that as unknown so the
    // caller conservatively falls back to a full audit instead of under-counting.
    let added = @string.parse_int(parts[0].to_owned()) catch {
      _ => return None
    }
    let deleted = @string.parse_int(parts[1].to_owned()) catch {
      _ => return None
    }
    total = total + added + deleted
  }
  Some(total)
}

///|
async fn file_pr_prior_audit_receipt_entries(
  project_dir : String,
  current_head : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Array[String] {
  let receipts_dir = ".choir/audit-receipts"
  let (list_exit, list_output) = capture({
    program: "find",
    args: [
      receipts_dir, "-maxdepth", "1", "-type", "f", "-name", "*.json", "-printf",
      "%T@\t%f\n",
    ],
    workdir: Some(project_dir),
  })
  if list_exit != 0 {
    return []
  }
  let entries : Array[String] = []
  for raw in list_output.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let parts = line.split("\t").to_array()
    if parts.length() < 2 {
      continue
    }
    let mtime_raw = parts[0]
    let filename = parts[1].trim().to_owned()
    if filename == "" || filename.contains("/") || !filename.has_suffix(".json") {
      continue
    }
    let mtime_key = mtime_raw.trim().to_owned()
    let (cat_exit, body) = capture({
      program: "cat",
      args: [receipts_dir + "/" + filename],
      workdir: Some(project_dir),
    })
    if cat_exit != 0 {
      continue
    }
    match file_pr_parse_audit_receipt(body) {
      Some(receipt) if receipt.sha != current_head &&
        receipt.findings_count == 0 =>
        entries.push(prior_audit_receipt_entry(mtime_key, receipt))
      _ => ()
    }
  }
  entries
}

///|
async fn file_pr_audit_delta_prior_sha(
  project_dir : String,
  file_pr_dir : String,
  branch : String,
  head_sha : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> String? {
  let receipts_dir = ".choir/audit-receipts"
  let entries = file_pr_prior_audit_receipt_entries(
    project_dir, head_sha, capture,
  )
  let prior_sha = match
    find_prior_branch_audit_receipt(receipts_dir, branch, fn(path) {
      if path == receipts_dir {
        entries
      } else {
        []
      }
    }) {
    Some(sha) => sha
    None => return None
  }
  let (diff_exit, numstat) = capture({
    program: "git",
    args: ["diff", "--numstat", prior_sha + "..." + head_sha],
    workdir: Some(file_pr_dir),
  })
  if diff_exit != 0 {
    return None
  }
  match audit_delta_numstat_lines(numstat) {
    Some(lines) if lines <= AUDIT_DELTA_MAX_LINES => Some(prior_sha)
    _ => None
  }
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
  prior_sha? : String? = None,
) -> String {
  let review_surface = match prior_sha {
    Some(prior) => "git diff " + prior + "..." + head_sha
    None => "git diff main..." + head_sha
  }
  let delta_context = match prior_sha {
    Some(prior) =>
      [
        "- Prior audited HEAD: " + prior,
        "- Delta audit: audit only the changes between prior_sha and current_head; treat the prior audited HEAD as already reviewed.",
        "- Delta limit: this retry path is used only when the changed-line count is <= " +
        AUDIT_DELTA_MAX_LINES.to_string() +
        "; larger retries fall back to the full review surface.",
      ]
    None => []
  }
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
    ..delta_context,
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
pub fn audit_on_file_pr_slug_prefix(head_sha : String) -> String {
  audit_on_file_pr_internal_caller_id + "-" + file_pr_short_sha(head_sha) + "-"
}

///|
pub fn audit_on_file_pr_worker_slug(
  head_sha : String,
  now_ms : Int64,
) -> String {
  audit_on_file_pr_slug_prefix(head_sha) + now_ms.to_string()
}

///|
fn audit_worker_child_summary_in_flight(
  summary : @phase.ChildLifecycleSummary,
) -> Bool {
  match summary {
    @phase.ChildLifecycleSummary::Working => true
    @phase.ChildLifecycleSummary::ReviewOwned(..) => true
    @phase.ChildLifecycleSummary::ChangesRequested(..) => true
    _ => false
  }
}

///|
pub fn find_in_flight_audit_worker(
  entries : Array[@phase.ChildLifecycle],
  slug_prefix : String,
) -> @phase.ChildLifecycle? {
  for entry in entries {
    if entry.slug.has_prefix(slug_prefix) &&
      audit_worker_child_summary_in_flight(entry.summary) {
      return Some(entry)
    }
  }
  None
}

///|
pub fn audit_on_file_pr_worker_entry_from_agent(
  agent : @types.Agent,
) -> @phase.ChildLifecycle {
  let summary = match agent.state {
    @types.AgentState::Done => @phase.ChildLifecycleSummary::Done
    @types.AgentState::Failed =>
      @phase.ChildLifecycleSummary::Failed(
        reason=@phase.FailureReason::RecoveredFailed,
      )
    _ => @phase.ChildLifecycleSummary::Working
  }
  {
    child_id: agent.agent_id.to_string(),
    slug: @phase.extract_slug(agent.agent_id.to_string()),
    branch: agent.branch,
    agent_type: agent.agent_type,
    summary,
  }
}

///|
fn audit_on_file_pr_worker_args(
  project_dir : String,
  branch : String,
  head_sha : String,
  now_ms : Int64,
  prior_sha? : String? = None,
) -> WorkerSpawnArgs {
  let task = build_audit_on_file_pr_task(
    project_dir,
    branch,
    head_sha,
    prior_sha~,
  )
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
    slug: audit_on_file_pr_worker_slug(head_sha, now_ms),
    agent_type: @types.AgentType::Codex,
  }
}

///|
pub(all) enum MutationLanguage {
  MoonBit
} derive(Debug, Eq)

///|
pub fn MutationLanguage::to_wire_string(self : MutationLanguage) -> String {
  match self {
    MoonBit => "moonbit"
  }
}

///|
pub impl Show for MutationLanguage with output(self, logger) -> Unit {
  logger.write_string(self.to_wire_string())
}

///|
fn MutationLanguage::try_parse_wire(raw : String) -> MutationLanguage? {
  match raw.trim().to_lower() {
    "moonbit" => Some(MoonBit)
    _ => None
  }
}

///|
pub(all) struct MutationGateTarget {
  language : MutationLanguage
  source_path : String
  test_paths : Array[String]
} derive(Debug, Eq)

///|
pub(all) struct MutationGateWorkerReport {
  message : String
  status : @types.Status
} derive(Debug, Eq)

///|
pub(all) struct MutationGateResult {
  kill_rate : Double
  total_mutants : Int
  killed_mutants : Int
  surviving_mutants : Array[String]
  unsupported_languages : Array[MutationLanguage]
} derive(Debug, Eq)

///|
pub let mutation_gate_internal_caller_id : String = "mutation-gate"

///|
pub let mutation_gate_report_json_marker : String = "MUTATION_GATE_REPORT_JSON:"

///|
pub let mutation_gate_default_budget_ms : Int = 900_000

///|
fn mutation_gate_is_moonbit_path(path : String) -> Bool {
  path.has_prefix("src/") && path.has_suffix(".mbt")
}

///|
fn mutation_gate_is_moonbit_test_path(path : String) -> Bool {
  mutation_gate_is_moonbit_path(path) && path.has_suffix("_test.mbt")
}

///|
fn mutation_gate_source_for_test_path(path : String) -> String {
  path[:path.length() - "_test.mbt".length()].to_owned() + ".mbt"
}

///|
fn mutation_gate_upsert_target(
  targets : Array[MutationGateTarget],
  source_path : String,
  test_path : String?,
) -> Unit {
  for i = 0; i < targets.length(); i = i + 1 {
    let target = targets[i]
    if target.source_path == source_path {
      let test_paths = target.test_paths
      match test_path {
        Some(path) if path != "" && !test_paths.contains(path) =>
          test_paths.push(path)
        _ => ()
      }
      targets[i] = { ..target, test_paths, }
      return
    }
  }
  let test_paths = match test_path {
    Some(path) if path != "" => [path]
    _ => []
  }
  targets.push({ language: MoonBit, source_path, test_paths })
}

///|
pub fn mutation_gate_targets_for_changed_paths(
  changed_paths : Array[String],
) -> Array[MutationGateTarget] {
  let targets : Array[MutationGateTarget] = []
  for raw in changed_paths {
    let path = raw.trim().to_owned()
    if path == "" || !mutation_gate_is_moonbit_path(path) {
      continue
    }
    if mutation_gate_is_moonbit_test_path(path) {
      mutation_gate_upsert_target(
        targets,
        mutation_gate_source_for_test_path(path),
        Some(path),
      )
    } else {
      mutation_gate_upsert_target(targets, path, None)
    }
  }
  targets
}

///|
fn mutation_gate_changed_paths_from_output(output : String) -> Array[String] {
  let paths : Array[String] = []
  for raw in output.split("\n") {
    let path = raw.trim().to_owned()
    if path != "" {
      paths.push(path)
    }
  }
  paths
}

///|
fn mutation_gate_target_line(target : MutationGateTarget) -> String {
  let tests = if target.test_paths.length() == 0 {
    "(no changed sibling test detected; use the verify commands as the suite)"
  } else {
    target.test_paths.join(", ")
  }
  "- " +
  target.language.to_wire_string() +
  ": source=" +
  target.source_path +
  " tests=" +
  tests
}

///|
pub fn build_mutation_gate_task(
  project_dir : String,
  branch : String,
  head_sha : String,
  targets : Array[MutationGateTarget],
  verify_commands : Array[String],
  mutation_kill_rate_min : Double,
) -> String {
  let target_lines : Array[String] = []
  for target in targets {
    target_lines.push(mutation_gate_target_line(target))
  }
  let verify_lines : Array[String] = []
  for command in verify_commands {
    verify_lines.push("- `" + command + "`")
  }
  [
    "You are the mutation-gate worker for file_pr. The leaf's own tests have already passed; now prove those tests notice source regressions before PR filing is allowed.",
    "",
    "Hard boundaries:",
    "- Do not edit the real checkout. Create an isolated temp copy/worktree and mutate only there.",
    "- Do not commit, push, file a PR, or add measurement reporting.",
    "- Do not add cost-measurement scaffold.",
    "- If a language adapter cannot run, report that adapter gap and stop instead of rabbit-holing on external tools.",
    "",
    "Context:",
    "- Project directory: " + project_dir,
    "- Current branch: " + branch,
    "- HEAD: " + head_sha,
    "- mutation_kill_rate_min=" + mutation_kill_rate_min.to_string(),
    "",
    "Coverage targets:",
    ..target_lines,
    "",
    "Verify commands to run for each mutant:",
    ..verify_lines,
    "",
    "MoonBit adapter:",
    "- Generate single-site source mutants for fixed operators in the listed MoonBit source targets.",
    "- Mutate comparison operators (`==` <-> `!=`, `<` <-> `<=`, `>` <-> `>=`), boolean operators (`&&` <-> `||`), and simple arithmetic operators (`+` <-> `-`, `*` <-> `/`) when doing so is syntactically safe.",
    "- For each mutant, run the verify commands in the temp copy. A mutant is killed when any verify command fails. It survives when every verify command still passes.",
    "- If no usable MoonBit mutation adapter can run in this environment, report `unsupported_languages:[\"moonbit\"]` with a concise gap note.",
    "",
    "Result policy:",
    "- Compute killed_mutants / total_mutants as kill_rate. If total_mutants is 0, report kill_rate 1.0 and an empty survivor list.",
    "- If kill_rate is below mutation_kill_rate_min, include every surviving mutant you can identify and explicitly tell the leaf to re-fix-tests.",
    "",
    "Handoff:",
    "- Call notify_parent exactly once. Use status success if the mutation run completed, even when mutants survived. Use status failure only if the worker could not run the gate.",
    "- The notify_parent message MUST contain one line beginning with " +
    mutation_gate_report_json_marker +
    " followed by JSON with fields kill_rate, total_mutants, killed_mutants, surviving_mutants, unsupported_languages.",
    "- Example: " +
    mutation_gate_report_json_marker +
    " {\"kill_rate\":0.75,\"total_mutants\":4,\"killed_mutants\":3,\"surviving_mutants\":[\"src/foo.mbt:12 == -> !=\"],\"unsupported_languages\":[]}",
    "- After notify_parent, call shutdown.",
  ].join("\n")
}

///|
fn json_number_field(fields : Map[String, Json], key : String) -> Double? {
  match fields.get(key) {
    Some(Number(value, ..)) => Some(value)
    _ => None
  }
}

///|
fn json_int_field(fields : Map[String, Json], key : String) -> Int? {
  match fields.get(key) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
fn json_string_array_field(
  fields : Map[String, Json],
  key : String,
) -> Array[String]? {
  match fields.get(key) {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(value) => out.push(value)
          _ => return None
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
fn json_language_array_field(
  fields : Map[String, Json],
  key : String,
) -> Array[MutationLanguage]? {
  let raw = match json_string_array_field(fields, key) {
    Some(values) => values
    None => return None
  }
  let out : Array[MutationLanguage] = []
  for value in raw {
    match MutationLanguage::try_parse_wire(value) {
      Some(language) => out.push(language)
      None => return None
    }
  }
  Some(out)
}

///|
pub fn mutation_gate_report_from_message(
  message : String,
) -> MutationGateResult? {
  let start = match message.find(mutation_gate_report_json_marker) {
    Some(idx) => idx + mutation_gate_report_json_marker.length()
    None => return None
  }
  let raw_body = message[start:].trim().to_owned()
  let body = match raw_body.find("\n") {
    Some(idx) => raw_body[:idx].trim().to_owned()
    None => raw_body
  }
  let parsed = @json.parse(body) catch { _ => return None }
  match parsed {
    Object(fields) => {
      let kill_rate = match json_number_field(fields, "kill_rate") {
        Some(value) => value
        None => return None
      }
      let total_mutants = match json_int_field(fields, "total_mutants") {
        Some(value) => value
        None => return None
      }
      let killed_mutants = match json_int_field(fields, "killed_mutants") {
        Some(value) => value
        None => return None
      }
      let surviving_mutants = match
        json_string_array_field(fields, "surviving_mutants") {
        Some(value) => value
        None => return None
      }
      let unsupported_languages = match
        json_language_array_field(fields, "unsupported_languages") {
        Some(value) => value
        None => return None
      }
      Some({
        kill_rate,
        total_mutants,
        killed_mutants,
        surviving_mutants,
        unsupported_languages,
      })
    }
    _ => None
  }
}

///|
fn mutation_gate_worker_slug_prefix(head_sha : String) -> String {
  mutation_gate_internal_caller_id + "-" + file_pr_short_sha(head_sha) + "-"
}

///|
pub fn mutation_gate_worker_slug(head_sha : String, now_ms : Int64) -> String {
  mutation_gate_worker_slug_prefix(head_sha) + now_ms.to_string()
}

///|
fn mutation_gate_worker_args(
  project_dir : String,
  branch : String,
  head_sha : String,
  targets : Array[MutationGateTarget],
  verify_commands : Array[String],
  mutation_kill_rate_min : Double,
  now_ms : Int64,
  parent_agent_id : String,
) -> WorkerSpawnArgs {
  let task = build_mutation_gate_task(
    project_dir, branch, head_sha, targets, verify_commands, mutation_kill_rate_min,
  )
  {
    task: render_worker_spawn_prompt_with_defaults(
      {
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
        worker_type: "mutation",
        no_commit: false,
      },
      @workspace.resolve_context_paths(project_dir, "worker"),
      project_dir~,
    ),
    task_contract: { ..@types.TaskContract::empty(), goal: task },
    caller_id: parent_agent_id,
    slug: mutation_gate_worker_slug(head_sha, now_ms),
    agent_type: @types.AgentType::Codex,
  }
}

///|
fn mutation_gate_report_summary(message : String) -> String {
  let lines : Array[String] = []
  for raw in message.split("\n") {
    let line = raw.trim().to_owned()
    if line != "" {
      lines.push(line)
      if lines.length() >= 3 {
        break
      }
    }
  }
  if lines.length() == 0 {
    "no report body"
  } else {
    lines.join(" | ")
  }
}

///|
fn mutation_gate_languages_summary(
  languages : Array[MutationLanguage],
) -> String {
  let parts : Array[String] = []
  for language in languages {
    parts.push(language.to_wire_string())
  }
  parts.join(", ")
}

///|
fn mutation_gate_survivor_summary(survivors : Array[String]) -> String {
  if survivors.length() == 0 {
    "- worker did not list surviving mutants"
  } else {
    let lines : Array[String] = []
    for survivor in survivors {
      lines.push("- " + survivor)
    }
    lines.join("\n")
  }
}

///|
fn mutation_gate_count_summary(result : MutationGateResult) -> String {
  "total_mutants=" +
  result.total_mutants.to_string() +
  ", killed_mutants=" +
  result.killed_mutants.to_string()
}

///|
fn mutation_gate_invalid_count_error(
  result : MutationGateResult,
) -> @types.ChoirError? {
  let counts = mutation_gate_count_summary(result)
  if result.total_mutants < 0 {
    return Some(
      @types.ChoirError::validation_error(
        "file_pr: mutation gate worker returned invalid mutant counts (" +
        counts +
        "): total_mutants must be >= 0; refusing to trust kill rate",
      ),
    )
  }
  if result.killed_mutants < 0 {
    return Some(
      @types.ChoirError::validation_error(
        "file_pr: mutation gate worker returned invalid mutant counts (" +
        counts +
        "): killed_mutants must be >= 0; refusing to trust kill rate",
      ),
    )
  }
  if result.killed_mutants > result.total_mutants {
    return Some(
      @types.ChoirError::validation_error(
        "file_pr: mutation gate worker returned invalid mutant counts (" +
        counts +
        "): killed_mutants must not exceed total_mutants; refusing to trust kill rate",
      ),
    )
  }
  None
}

///|
fn mutation_gate_effective_kill_rate(result : MutationGateResult) -> Double {
  if result.total_mutants == 0 {
    1.0
  } else {
    result.killed_mutants.to_double() / result.total_mutants.to_double()
  }
}

///|
fn mutation_gate_result_to_error(
  result : MutationGateResult,
  mutation_kill_rate_min : Double,
) -> @types.ChoirError? {
  if result.unsupported_languages.length() > 0 {
    return Some(
      @types.ChoirError::validation_error(
        "file_pr: mutation gate worker reported unsupported language adapter(s): " +
        mutation_gate_languages_summary(result.unsupported_languages) +
        "; notify_parent with the mutation-engine gap instead of filing.",
      ),
    )
  }
  match mutation_gate_invalid_count_error(result) {
    Some(e) => return Some(e)
    None => ()
  }
  let effective_kill_rate = mutation_gate_effective_kill_rate(result)
  if effective_kill_rate < mutation_kill_rate_min {
    return Some(
      @types.ChoirError::validation_error(
        "file_pr: mutation gate failed; mutant-kill-rate " +
        effective_kill_rate.to_string() +
        " is below threshold " +
        mutation_kill_rate_min.to_string() +
        ". re-fix-tests so they kill the surviving mutants, then rerun file_pr.\nSurviving mutants:\n" +
        mutation_gate_survivor_summary(result.surviving_mutants),
      ),
    )
  }
  None
}

///|
fn file_pr_registered_dev_gate_applies(
  caller_role : @types.Role,
  tracked_agent_id : String,
  registry : @registry.AgentRegistry?,
) -> Bool {
  match registry {
    Some(reg) =>
      match reg.get_opt(tracked_agent_id) {
        Some(agent) => agent.role == @types.Role::Dev
        None => caller_role == @types.Role::Dev
      }
    None => caller_role == @types.Role::Dev
  }
}

///|
priv enum MutationGateWaitOutcome {
  Timeout
  NoReport
  WorkerDied
  Reported(MutationGateWorkerReport)
}

///|
priv struct MutationGateWaitResult {
  outcome : MutationGateWaitOutcome
  _elapsed_s : Int64
}

///|
async fn wait_for_mutation_gate_report_with_liveness(
  worker_id : String,
  wait_for_mutation_gate_report : async (String) -> MutationGateWorkerReport?,
  mutation_budget_ms : Int,
  now_ms_fn : () -> Int64,
  mutation_worker_alive : (String) -> Bool,
  sleep_fn : async (Int) -> Unit,
) -> MutationGateWaitResult {
  let started_ms = now_ms_fn()
  let budget_ms = mutation_budget_ms.to_int64()
  while true {
    if !mutation_worker_alive(worker_id) {
      let elapsed_s = (now_ms_fn() - started_ms) / 1000L
      return {
        outcome: MutationGateWaitOutcome::WorkerDied,
        _elapsed_s: elapsed_s,
      }
    }
    let elapsed_ms = now_ms_fn() - started_ms
    let remaining_ms = budget_ms - elapsed_ms
    if remaining_ms <= 0L {
      let elapsed_s = elapsed_ms / 1000L
      return {
        outcome: MutationGateWaitOutcome::Timeout,
        _elapsed_s: elapsed_s,
      }
    }
    let poll_ms = if remaining_ms > 250L { 250L } else { remaining_ms }
    let poll_result = @async.with_timeout_opt(poll_ms.to_int(), () => {
      wait_for_mutation_gate_report(worker_id)
    })
    let elapsed_s = (now_ms_fn() - started_ms) / 1000L
    match poll_result {
      None => sleep_fn(poll_ms.to_int())
      Some(None) =>
        return {
          outcome: MutationGateWaitOutcome::NoReport,
          _elapsed_s: elapsed_s,
        }
      Some(Some(value)) =>
        return {
          outcome: MutationGateWaitOutcome::Reported(value),
          _elapsed_s: elapsed_s,
        }
    }
  }
  let elapsed_ms = now_ms_fn() - started_ms
  let elapsed_s = elapsed_ms / 1000L
  { outcome: MutationGateWaitOutcome::Timeout, _elapsed_s: elapsed_s }
}

///|
pub async fn file_pr_run_mutation_gate(
  project_dir : String,
  file_pr_dir : String,
  caller_role : @types.Role,
  tracked_agent_id : String,
  registry : @registry.AgentRegistry?,
  parent_branch : String,
  head_sha : String,
  verify_commands : Array[String],
  mutation_kill_rate_min : Double,
  capture : async (@workspace.Command) -> (Int, String),
  spawn_mutation_worker : async (WorkerSpawnArgs) -> Result[
    String,
    @types.ChoirError,
  ],
  wait_for_mutation_report : async (String) -> MutationGateWorkerReport?,
  cleanup_mutation_report : async (String) -> Unit,
  mutation_budget_ms : Int,
  now_ms_fn : () -> Int64,
  mutation_worker_alive? : (String) -> Bool = fn(_) { true },
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Result[Unit, @types.ChoirError] {
  if !file_pr_registered_dev_gate_applies(
      caller_role, tracked_agent_id, registry,
    ) {
    return Ok(())
  }
  if verify_commands.length() == 0 {
    return Ok(())
  }
  let branch = match file_pr_current_branch_name(file_pr_dir, capture) {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "file_pr: cannot determine current branch for mutation gate",
        ),
      )
  }
  let (diff_exit, diff_output) = capture({
    program: "git",
    args: ["diff", "--name-only", parent_branch + "..." + head_sha],
    workdir: Some(file_pr_dir),
  })
  if diff_exit != 0 {
    return Err(
      @types.ChoirError::validation_error(
        "file_pr: cannot determine changed files for mutation gate: " +
        file_pr_verify_output_tail(diff_output),
      ),
    )
  }
  let targets = mutation_gate_targets_for_changed_paths(
    mutation_gate_changed_paths_from_output(diff_output),
  )
  if targets.length() == 0 {
    return Ok(())
  }
  let worker_args = mutation_gate_worker_args(
    project_dir,
    branch,
    head_sha,
    targets,
    verify_commands,
    mutation_kill_rate_min,
    now_ms_fn(),
    tracked_agent_id,
  )
  let worker_id = match spawn_mutation_worker(worker_args) {
    Ok(id) => id
    Err(e) => return Err(e)
  }
  let wait_result = wait_for_mutation_gate_report_with_liveness(
    worker_id, wait_for_mutation_report, mutation_budget_ms, now_ms_fn, mutation_worker_alive,
    sleep_fn,
  )
  let result = match wait_result.outcome {
    MutationGateWaitOutcome::Timeout =>
      Some(
        @types.ChoirError::timeout(
          "[MUTATION GATE INCOMPLETE] file_pr: mutation gate budget exceeded",
        ),
      )
    MutationGateWaitOutcome::NoReport =>
      Some(
        @types.ChoirError::audit_incomplete(
          "[MUTATION GATE INCOMPLETE] file_pr: mutation gate worker did not report",
        ),
      )
    MutationGateWaitOutcome::WorkerDied =>
      Some(
        @types.ChoirError::audit_incomplete(
          "[MUTATION GATE INCOMPLETE] file_pr: mutation gate worker exited before report",
        ),
      )
    MutationGateWaitOutcome::Reported(report) =>
      if report.status == @types.Status::Failure {
        Some(
          @types.ChoirError::audit_incomplete(
            "[MUTATION GATE INCOMPLETE] file_pr: mutation gate worker reported failure: " +
            mutation_gate_report_summary(report.message),
          ),
        )
      } else {
        let result = match mutation_gate_report_from_message(report.message) {
          Some(value) =>
            mutation_gate_result_to_error(value, mutation_kill_rate_min)
          None =>
            Some(
              @types.ChoirError::audit_incomplete(
                "[MUTATION GATE INCOMPLETE] file_pr: mutation gate worker did not return " +
                mutation_gate_report_json_marker,
              ),
            )
        }
        result
      }
  }
  cleanup_mutation_report(worker_id)
  match result {
    Some(e) => Err(e)
    None => Ok(())
  }
}

///|
priv enum FilePrAutoAuditLogOutcome {
  ReceiptPresent
  AwaitingInFlight(worker_id~ : String)
}

///|
fn FilePrAutoAuditLogOutcome::to_message(
  self : FilePrAutoAuditLogOutcome,
) -> String {
  match self {
    ReceiptPresent => "file_pr_auto_audit outcome=receipt_present"
    AwaitingInFlight(worker_id~) =>
      "file_pr_auto_audit outcome=awaiting_in_flight worker=" + worker_id
  }
}

///|
fn emit_file_pr_auto_audit_log_line(
  project_dir : String,
  append_file : (String, String) -> Bool,
  outcome : FilePrAutoAuditLogOutcome,
  now_ms_fn : () -> Int64,
) -> Unit {
  let message = outcome.to_message()
  let fields = match outcome {
    ReceiptPresent => [@moontrace.field("outcome", "receipt_present")]
    AwaitingInFlight(worker_id~) =>
      [
        @moontrace.field("outcome", "awaiting_in_flight"),
        @moontrace.field("worker", worker_id),
      ]
  }
  @moontrace.info("file_pr_auto_audit", fields~)
  ignore(
    @poller.append_delivery_log_line(
      append_file,
      project_dir,
      message,
      now_ms=now_ms_fn(),
    ),
  )
}

///|
pub async fn file_pr_auto_audit_for_missing_receipt(
  project_dir : String,
  file_pr_dir : String,
  tracked_agent_id : String,
  parent_branch : String,
  head_sha : String,
  capture : async (@workspace.Command) -> (Int, String),
  spawn_audit_worker : async (WorkerSpawnArgs) -> Result[
    String,
    @types.ChoirError,
  ],
  wait_for_audit_report : async (String) -> AuditOnFilePrReport?,
  cleanup_audit_report : async (String) -> Unit,
  write_audit_receipt : (WriteAuditReceiptArgs) -> @types.Response,
  audit_budget_ms : Int,
  audit_heartbeat_sec : Int,
  append_file : (String, String) -> Bool,
  sleep_fn : async (Int) -> Unit,
  now_ms_fn : () -> Int64,
  audit_worker_alive : (String) -> Bool,
  list_audit_workers? : () -> Array[@phase.ChildLifecycle] = fn() { [] },
  audit_max_rounds? : Int = @types.Config::default().audit_max_rounds,
  record_audit_cycle_for_agent? : (String) -> Int = fn(_) { 0 },
  audit_cycle_count_for_agent? : (String) -> Int = fn(_) { 0 },
  clear_audit_cycle_for_agent? : (String) -> Unit = fn(_) { () },
  notify_audit_started? : async (String, Int?, Int) -> Unit = async fn(
    _tracked_agent_id,
    _pr_number,
    _cycle_number,
  ) {
    @async.sleep(0)
  },
  pr_number? : Int = 0,
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
  let receipt_path = file_pr_audit_receipt_path_for_head(head_sha)
  let (receipt_exit_code, receipt_body) = capture({
    program: "cat",
    args: [receipt_path],
    workdir: Some(project_dir),
  })
  let receipt_validation = file_pr_audit_receipt_validation(
    parent_branch,
    head_sha,
    if receipt_exit_code == 0 {
      Some(receipt_body)
    } else {
      None
    },
  )
  match receipt_validation {
    AuditReceiptValid => {
      emit_file_pr_auto_audit_log_line(
        project_dir,
        append_file,
        ReceiptPresent,
        now_ms_fn,
      )
      clear_audit_cycle_for_agent(tracked_agent_id)
      return Ok(())
    }
    AuditReceiptFindingsRemain(_, _) => return receipt_validation.to_result()
    _ => ()
  }
  let mut cycles = 0
  let audit_workers = list_audit_workers()
  let audit_worker_prefix = audit_on_file_pr_slug_prefix(head_sha)
  let worker_id = match
    find_in_flight_audit_worker(audit_workers, audit_worker_prefix) {
    Some(existing) => {
      let recorded_cycles = audit_cycle_count_for_agent(tracked_agent_id)
      cycles = if recorded_cycles <= 0 {
        record_audit_cycle_for_agent(tracked_agent_id)
      } else {
        recorded_cycles
      }
      emit_file_pr_auto_audit_log_line(
        project_dir,
        append_file,
        AwaitingInFlight(worker_id=existing.child_id),
        now_ms_fn,
      )
      existing.child_id
    }
    None => {
      let recorded_cycles = audit_cycle_count_for_agent(tracked_agent_id)
      let at_cycle_cap = audit_max_rounds > 0 &&
        recorded_cycles >= audit_max_rounds
      cycles = if at_cycle_cap {
        recorded_cycles
      } else {
        record_audit_cycle_for_agent(tracked_agent_id)
      }
      let pr_number_for_notification : Int? = if pr_number > 0 {
        Some(pr_number)
      } else {
        None
      }
      notify_audit_started(tracked_agent_id, pr_number_for_notification, cycles)
      let prior_sha = file_pr_audit_delta_prior_sha(
        project_dir, file_pr_dir, branch, head_sha, capture,
      )
      let worker_args = audit_on_file_pr_worker_args(
        project_dir,
        branch,
        head_sha,
        now_ms_fn(),
        prior_sha~,
      )
      match spawn_audit_worker(worker_args) {
        Ok(id) => id
        Err(e) => return Err(e)
      }
    }
  }
  let wait_result = wait_for_audit_report_with_heartbeats(
    project_dir,
    tracked_agent_id,
    worker_id,
    wait_for_audit_report,
    audit_budget_ms,
    audit_heartbeat_sec,
    append_file,
    sleep_fn,
    now_ms_fn,
    audit_worker_alive,
    pr_number~,
    branch=Some(branch),
  )
  let report = match wait_result.outcome {
    AuditWaitTimedOut => {
      cleanup_audit_report(worker_id)
      emit_audit_heartbeat_log_line(
        project_dir,
        append_file,
        pr_number,
        tracked_agent_id,
        wait_result.elapsed_s,
        status=HeartbeatError,
        reason=Some("timeout"),
        branch=Some(branch),
        now_ms_fn~,
      )
      return Err(@types.ChoirError::timeout("audit budget exceeded"))
    }
    AuditWaitNoReport => {
      cleanup_audit_report(worker_id)
      emit_audit_heartbeat_log_line(
        project_dir,
        append_file,
        pr_number,
        tracked_agent_id,
        wait_result.elapsed_s,
        status=HeartbeatError,
        reason=Some("missing_report"),
        branch=Some(branch),
        now_ms_fn~,
      )
      return Err(
        @types.ChoirError::audit_incomplete(
          "file_pr: audit worker did not report",
        ),
      )
    }
    AuditWaitReported(value) => value
  }
  if report.status == @types.Status::Failure {
    let reason = audit_report_failure_reason(report)
    emit_audit_heartbeat_log_line(
      project_dir,
      append_file,
      pr_number,
      tracked_agent_id,
      wait_result.elapsed_s,
      status=HeartbeatError,
      reason=Some(reason),
      branch=Some(branch),
      now_ms_fn~,
    )
    return Err(
      @types.ChoirError::audit_incomplete(
        "file_pr: audit worker reported failure: " +
        audit_report_finding_summary(report.message),
      ),
    )
  }
  let findings_count = parse_findings_count(report.message)
  emit_audit_heartbeat_log_line(
    project_dir,
    append_file,
    pr_number,
    tracked_agent_id,
    wait_result.elapsed_s,
    status=HeartbeatOk,
    findings_count=Some(findings_count),
    branch=Some(branch),
    now_ms_fn~,
  )
  if findings_count > 0 {
    if audit_max_rounds > 0 && cycles >= audit_max_rounds {
      return Err(
        @types.ChoirError::audit_loop_exhausted(
          cycles, findings_count, receipt_path,
        ),
      )
    }
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
    clear_audit_cycle_for_agent(tracked_agent_id)
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
  tracked_agent_id : String,
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
  cleanup_audit_report? : async (String) -> Unit = async fn(_) {
    @async.sleep(0)
  },
  write_audit_receipt? : (WriteAuditReceiptArgs) -> @types.Response = fn(_) {
    @types.Response::Err("audit receipt writer unavailable")
  },
  audit_budget_ms? : Int = audit_on_file_pr_default_budget_ms,
  audit_heartbeat_sec? : Int = @types.Config::default().audit_heartbeat_sec,
  audit_max_rounds? : Int = @types.Config::default().audit_max_rounds,
  record_audit_cycle_for_agent? : (String) -> Int = fn(_) { 0 },
  audit_cycle_count_for_agent? : (String) -> Int = fn(_) { 0 },
  clear_audit_cycle_for_agent? : (String) -> Unit = fn(_) { () },
  notify_audit_started? : async (String, Int?, Int) -> Unit = async fn(
    _tracked_agent_id,
    _pr_number,
    _cycle_number,
  ) {
    @async.sleep(0)
  },
  append_file? : (String, String) -> Bool = fn(_, _) { false },
  audit_sleep_fn? : async (Int) -> Unit = @async.sleep,
  audit_now_ms_fn? : () -> Int64 = fn() { @env.now().reinterpret_as_int64() },
  audit_worker_alive? : (String) -> Bool = fn(_) { true },
  list_audit_workers? : () -> Array[@phase.ChildLifecycle] = fn() { [] },
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
    AuditReceiptValid => {
      clear_audit_cycle_for_agent(tracked_agent_id)
      Ok(())
    }
    _ =>
      if caller_role == @types.Role::Dev && validation.auto_audit_allowed() {
        file_pr_auto_audit_for_missing_receipt(
          project_dir,
          file_pr_dir,
          tracked_agent_id,
          parent_branch,
          head_sha,
          capture,
          spawn_audit_worker,
          wait_for_audit_report,
          cleanup_audit_report,
          write_audit_receipt,
          audit_budget_ms,
          audit_heartbeat_sec,
          append_file,
          audit_sleep_fn,
          audit_now_ms_fn,
          audit_worker_alive,
          list_audit_workers~,
          audit_max_rounds~,
          record_audit_cycle_for_agent~,
          audit_cycle_count_for_agent~,
          clear_audit_cycle_for_agent~,
          notify_audit_started~,
        )
      } else {
        validation.to_result()
      }
  }
}

///|
fn file_pr_tdd_gate_applies(
  caller_role : @types.Role,
  tracked_agent_id : String,
  registry : @registry.AgentRegistry?,
) -> Bool {
  file_pr_registered_dev_gate_applies(caller_role, tracked_agent_id, registry)
}

///|
pub fn file_pr_require_tdd_done(
  caller_role : @types.Role,
  tracked_agent_id : String,
  registry : @registry.AgentRegistry?,
  tdd_phase_reader : (String) -> @types.LeafTddPhase?,
) -> Result[Unit, @types.ChoirError] {
  if !file_pr_tdd_gate_applies(caller_role, tracked_agent_id, registry) {
    return Ok(())
  }
  match tdd_phase_reader(tracked_agent_id) {
    Some(@types.LeafTddPhase::Done) => Ok(())
    Some(phase) =>
      Err(
        @types.ChoirError::validation_error(
          "file_pr: leaf TDD phase must be done before filing; current phase is " +
          phase.to_wire_string() +
          ". Complete Intent -> Red(test failed) -> Green(test passed) -> Done via tdd_intent, tdd_red_check, and tdd_green_check.",
        ),
      )
    None =>
      Err(
        @types.ChoirError::validation_error(
          "file_pr: leaf TDD phase must be done before filing; no TDD phase has been recorded. Start with tdd_intent, then tdd_red_check, tdd_green_check to Green, and tdd_green_check to Done.",
        ),
      )
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
    "main.some-leaf",
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
    "main.some-leaf",
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
    "main.some-leaf",
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
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
) -> Result[Array[FilePrVerifyOutcome], @types.ChoirError] {
  let outcomes : Array[FilePrVerifyOutcome] = []
  let head_sha = file_pr_current_head_sha(file_pr_dir, capture)
  for raw in verify_commands {
    let command = @types.moon_verify_normalize_command(
      raw.trim().to_owned(),
      moon_verify_target,
    )
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
  tracked_agent_id : String,
  task_contract_reader : (String) -> @types.TaskContract?,
) -> @types.TaskContract? {
  task_contract_reader(tracked_agent_id)
}

///|
fn file_pr_missing_task_contract_error(
  tracked_agent_id : String,
) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "file_pr: server task contract unavailable for tracked agent '" +
    tracked_agent_id +
    "'; refusing to skip required verify",
  )
}

///|
async fn file_pr_mirror_beads_created(
  project_dir : String,
  tracked_agent_id : String,
  pr_number : Int,
  capture : async (@workspace.Command) -> (Int, String),
  task_contract_reader : (String) -> @types.TaskContract?,
) -> Unit {
  let issue_id = match
    file_pr_task_contract_for_agent(tracked_agent_id, task_contract_reader) {
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
  prepare_audit_report? : (String) -> Unit = fn(_) {  },
  wait_for_audit_report? : async (String) -> AuditOnFilePrReport? = async fn(
    _,
  ) {
    @async.sleep(0)
    None
  },
  cleanup_audit_report? : async (String) -> Unit = async fn(_) {
    @async.sleep(0)
  },
  audit_budget_ms? : Int = audit_on_file_pr_default_budget_ms,
  audit_heartbeat_sec? : Int = @types.Config::default().audit_heartbeat_sec,
  audit_max_rounds? : Int = @types.Config::default().audit_max_rounds,
  record_audit_cycle_for_agent? : (String) -> Int = fn(_) { 0 },
  audit_cycle_count_for_agent? : (String) -> Int = fn(_) { 0 },
  clear_audit_cycle_for_agent? : (String) -> Unit = fn(_) { () },
  append_file? : (String, String) -> Bool = fn(_, _) { false },
  audit_sleep_fn? : async (Int) -> Unit = @async.sleep,
  audit_now_ms_fn? : () -> Int64 = fn() { @env.now().reinterpret_as_int64() },
  audit_worker_alive? : (String) -> Bool = fn(_) { true },
  list_audit_workers? : () -> Array[@phase.ChildLifecycle] = fn() { [] },
  notify_audit_started? : async (String, Int?, Int) -> Unit = async fn(
    _tracked_agent_id,
    _pr_number,
    _cycle_number,
  ) {
    @async.sleep(0)
  },
  prepare_mutation_gate_report? : (String) -> Unit = fn(_) {  },
  wait_for_mutation_gate_report? : async (String) -> MutationGateWorkerReport? = async fn(
    _,
  ) {
    @async.sleep(0)
    None
  },
  cleanup_mutation_gate_report? : (String) -> Unit = fn(_) {  },
  mutation_gate_budget_ms? : Int = mutation_gate_default_budget_ms,
  mutation_kill_rate_min? : Double = @types.Config::default().mutation_kill_rate_min,
  mutation_gate_now_ms_fn? : () -> Int64 = fn() {
    @env.now().reinterpret_as_int64()
  },
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  global_review_mode? : @types.ReviewMode = @types.Config::default().review_mode,
  task_contract_reader? : (String) -> @types.TaskContract? = fn(_) { None },
  record_task_contract? : (String, @types.TaskContract?) -> Unit = fn(
    _agent_id,
    _contract,
  ) {
    ()
  },
  tdd_phase_reader? : (String) -> @types.LeafTddPhase? = fn(_) { None },
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> @types.Response {
  let branch = file_pr_args.branch
  let tracked_agent_id = file_pr_args.tracked_agent_id
  match
    file_pr_require_tdd_done(
      caller_role, tracked_agent_id, registry, tdd_phase_reader,
    ) {
    Err(e) => return @types.Response::Err(e.validation_detail_or_message())
    Ok(_) => ()
  }
  let parent_branch = match file_pr_args.parent_branch {
    Some(pb) => pb
    None => detect_default_branch_with_capture(project_dir, capture)
  }
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
  let mut audit_incomplete : FilePrAuditIncomplete? = None
  match
    file_pr_require_audit_receipt(
      preflight_inputs.parent_branch,
      project_dir,
      preflight_inputs.file_pr_dir,
      tracked_agent_id,
      caller_role,
      capture,
      spawn_audit_worker=async fn(worker_args) {
        let resolved_parent_branch = detect_default_branch_with_capture(
          project_dir, capture,
        )
        let plan = spawn_worker_plan(
          worker_args, resolved_parent_branch, session, project_dir,
        )
        prepare_audit_report(plan.agent_id)
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
          record_task_contract~,
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
      audit_heartbeat_sec~,
      audit_max_rounds~,
      record_audit_cycle_for_agent~,
      audit_cycle_count_for_agent~,
      clear_audit_cycle_for_agent~,
      notify_audit_started~,
      append_file~,
      audit_sleep_fn~,
      audit_now_ms_fn~,
      audit_worker_alive~,
      list_audit_workers~,
    ) {
    Err(e) =>
      if caller_role == @types.Role::Dev &&
        (e.is_timeout() || e.is_audit_incomplete()) {
        audit_incomplete = Some({ error: e.validation_detail_or_message() })
      } else {
        return @types.Response::Err(e.validation_detail_or_message())
      }
    Ok(_) => ()
  }
  let task_contract = file_pr_task_contract_for_agent(
    tracked_agent_id, task_contract_reader,
  )
  if task_contract is None {
    return @types.Response::Err(
      file_pr_missing_task_contract_error(tracked_agent_id).message(),
    )
  }
  let verify_outcomes = match task_contract {
    Some(contract) =>
      match
        file_pr_run_required_verify(
          file_pr_dir,
          contract.verify,
          capture,
          record_verify_outcome=fn(outcome : FilePrVerifyOutcome) {
            record_verify_event(
              tracked_agent_id,
              file_pr_verify_evidence_event(file_pr_dir, outcome),
            )
          },
          moon_verify_target~,
        ) {
        Ok(outcomes) => outcomes
        Err(e) => return @types.Response::Err(e.message())
      }
    None => []
  }
  match task_contract {
    Some(contract) if file_pr_registered_dev_gate_applies(
        caller_role, tracked_agent_id, registry,
      ) &&
      contract.verify.length() > 0 => {
      let head_sha = match file_pr_current_head_sha(file_pr_dir, capture) {
        Some(sha) => sha
        None =>
          return @types.Response::Err(
            "file_pr: cannot determine current HEAD for mutation gate",
          )
      }
      match
        file_pr_run_mutation_gate(
          project_dir,
          file_pr_dir,
          caller_role,
          tracked_agent_id,
          registry,
          parent_branch,
          head_sha,
          contract.verify,
          mutation_kill_rate_min,
          capture,
          async fn(worker_args) {
            let resolved_parent_branch = detect_default_branch_with_capture(
              project_dir, capture,
            )
            let plan = spawn_worker_plan(
              worker_args,
              resolved_parent_branch,
              session,
              project_dir,
              isolation=@types.IsolationMode::Worktree,
            )
            prepare_mutation_gate_report(plan.agent_id)
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
              allow_mutation_gate_caller=true,
              record_task_contract~,
            )
            match resp.ok_field("agent_id") {
              Some(agent_id) => Ok(agent_id)
              None => {
                cleanup_mutation_gate_report(plan.agent_id)
                Err(
                  @types.ChoirError::validation_error(
                    resp
                    .error_message()
                    .unwrap_or("mutation gate worker spawn failed"),
                  ),
                )
              }
            }
          },
          wait_for_mutation_gate_report,
          async fn(worker_id) {
            ignore(cleanup_mutation_gate_report(worker_id))
            let path = match
              file_pr_mutation_gate_worktree_path(project_dir, worker_id) {
              Some(candidate) => candidate
              None => return
            }
            ignore(runner([@workspace.git_worktree_remove(path)]))
          },
          mutation_gate_budget_ms,
          mutation_gate_now_ms_fn,
          mutation_worker_alive=fn(worker_id) {
            match registry {
              Some(reg) => reg.is_alive(worker_id).unwrap_or(false)
              None => true
            }
          },
        ) {
        Ok(_) => ()
        Err(e) =>
          if caller_role == @types.Role::Dev &&
            (e.is_timeout() || e.is_audit_incomplete()) {
            audit_incomplete = Some({ error: e.validation_detail_or_message() })
          } else {
            return @types.Response::Err(e.validation_detail_or_message())
          }
      }
    }
    _ => ()
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
        audit_incomplete~,
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
        append_file~,
        sleep_fn~,
      )
      if resp.is_ok() {
        file_pr_mirror_beads_created(
          project_dir,
          tracked_agent_id,
          pr.number,
          capture,
          task_contract_reader,
        )
      }
      resp
    }
  }
}

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
pub fn file_pr_reviewer_review_comment_mention(
  reviewer_handle : String,
) -> String {
  if reviewer_handle.has_prefix("@") {
    reviewer_handle
  } else {
    "@" + reviewer_handle
  }
}

///|
pub fn file_pr_reviewer_review_comment_body(
  reviewer_handle : String,
  review_context_trimmed : String,
) -> String {
  file_pr_reviewer_review_comment_mention(reviewer_handle) +
  " review: " +
  review_context_trimmed
}

///|
/// `gh pr comment` body for review context ([`interpret_file_pr_post_success`] when
/// a reviewer is configured and [`FilePrPostSuccessEffects::review_context`] is non-empty).
pub fn file_pr_reviewer_review_comment_gh_command(
  pr_number : Int,
  reviewer_handle : String,
  review_context_trimmed : String,
  gh_workdir : String,
) -> @workspace.Command {
  @workspace.gh_pr_comment(
    pr_number,
    file_pr_reviewer_review_comment_body(
      reviewer_handle, review_context_trimmed,
    ),
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
pub fn file_pr_reviewer_handle(reviewer : @types.Reviewer) -> String? {
  match reviewer {
    @types.Reviewer::None => None
    @types.Reviewer::Copilot => Some(file_pr_copilot_reviewer_handle)
    @types.Reviewer::Named(handle) => Some(handle)
  }
}

///|
pub fn file_pr_reviewer_gh_command(
  pr_number : Int,
  reviewer_handle : String,
  gh_workdir : String,
) -> @workspace.Command {
  @workspace.gh_pr_add_reviewer(pr_number, reviewer_handle, gh_workdir)
}

///|
fn file_pr_reviewer_request_failed_log_append(
  pr_number : Int,
  reviewer_handle : String,
  err_part : String,
  now_ms : Int64,
) -> String {
  @poller.delivery_log_line(
    "[file_pr] reviewer_request failed pr=" +
    pr_number.to_string() +
    " reviewer=" +
    reviewer_handle +
    err_part,
    now_ms~,
  )
}

///|
pub async fn file_pr_request_reviewer(
  pr_number : Int,
  reviewer_handle : String,
  file_pr_workdir : String,
  delivery_log_path : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  append_file : (String, String) -> Bool,
  now_ms_fn : () -> Int64,
) -> Bool {
  let cmd = file_pr_reviewer_gh_command(
    pr_number, reviewer_handle, file_pr_workdir,
  )
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
    @moontrace.warn("file_pr reviewer request failed", fields~)
    let err_part = match spawn_err {
      Some(err) => " error=" + err
      None => ""
    }
    ignore(
      append_file(
        delivery_log_path,
        file_pr_reviewer_request_failed_log_append(
          pr_number,
          reviewer_handle,
          err_part,
          now_ms_fn(),
        ),
      ),
    )
  }
  ok
}

///|
pub fn file_pr_should_request_reviewer(
  reviewer : @types.Reviewer,
  parent_branch : String,
  default_branch : String,
  skip_copilot_on_feature_branch : Bool,
) -> Bool {
  match reviewer {
    @types.Reviewer::None => false
    @types.Reviewer::Copilot | @types.Reviewer::Named(_) =>
      !(skip_copilot_on_feature_branch && parent_branch != default_branch)
  }
}

///|
/// Post-`ensure_pull_request` host path: poller ensure/write, dev lifecycle
/// event, optional parent auto-notify (delivery log + `execute_delivery` +
/// moontrace), optional reviewer context comment, optional best-effort reviewer
/// request, then the
/// planned tool response. Preserves `ToolRequest::FilePr` ordering and strings
/// from the prior dispatch arm.
pub async fn interpret_file_pr_post_success(
  project_dir : String,
  session : String,
  branch : String,
  tracked_agent_id : String,
  file_pr_workdir : String,
  pr_number : Int,
  reviewer : @types.Reviewer,
  effects : FilePrPostSuccessEffects,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  append_file? : (String, String) -> Bool = @sys.append_file_sync,
  request_reviewer? : Bool = true,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
  // Clock for delivery-log line timestamps. Called fresh at each append site —
  // not captured once — so writes that happen after slow `gh`/delivery commands
  // record their real wall-clock time rather than a stale snapshot.
  now_ms_fn? : () -> Int64 = fn() { @env.now().reinterpret_as_int64() },
) -> @types.Response {
  let reviewer_handle = file_pr_reviewer_handle(reviewer)
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
        try
          @phase.resolve_parent_with_fallback(
            project_dir, session, reg, tracked_agent_id,
          )
        catch {
          e => Err(e)
        } noraise {
          parent => Ok(parent)
        },
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
  match reviewer_handle {
    Some(handle) =>
      match effects.review_context {
        Some(ctx) => {
          let comment_cmd = file_pr_reviewer_review_comment_gh_command(
            pr_number, handle, ctx, file_pr_workdir,
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
                  @moontrace.field("reviewer", handle),
                  @moontrace.field("exit", exit_json_c),
                  @moontrace.field("error", err),
                ]
              None =>
                [
                  @moontrace.field("pr_number", pr_number),
                  @moontrace.field("reviewer", handle),
                  @moontrace.field("exit", exit_json_c),
                ]
            }
            @moontrace.warn("file_pr review comment failed", fields~)
            let err_part_c = match spawn_err_comment {
              Some(err) => " error=" + err
              None => ""
            }
            ignore(
              @sys.append_file_sync(
                delivery_log_path,
                @poller.delivery_log_line(
                  "[file_pr] review_comment failed pr=" +
                  pr_number.to_string() +
                  " reviewer=" +
                  handle +
                  err_part_c,
                  now_ms=now_ms_fn(),
                ),
              ),
            )
          }
        }
        None => ()
      }
    None => ()
  }
  if request_reviewer {
    match reviewer_handle {
      Some(handle) => {
        let ok = file_pr_request_reviewer(
          pr_number, handle, file_pr_workdir, delivery_log_path, runner, append_file,
          now_ms_fn,
        )
        if !ok {
          review_request_failed = true
        }
      }
      None => ()
    }
  }
  if review_request_failed {
    match reviewer_handle {
      Some(handle) =>
        effects.response.with_warning(
          "review_request_failed: reviewer request for " +
          handle +
          " failed — use request_review(pr_number: \"" +
          pr_number.to_string() +
          "\", reviewer: \"" +
          handle +
          "\") from the parent/server path",
        )
      None => effects.response
    }
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
  advisory : String?
} derive(Debug, Eq)

///|
fn file_pr_verify_output_tail(output : String) -> String {
  let trimmed = collapse_cr_progress(output).trim().to_owned()
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
  let advisory_line = match outcome.advisory {
    Some(message) => "\n" + message
    None => ""
  }
  let base = "cwd: " +
    file_pr_dir +
    "\nexit: " +
    outcome.exit_code.to_string() +
    head_line +
    advisory_line
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
  let ok = if outcome.exit_code == 0 {
    true
  } else {
    match outcome.advisory {
      Some(_) => true
      None => false
    }
  }
  @evidence.EvidenceEvent::VerifyResultObserved(
    name=outcome.command,
    ok~,
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
fn file_pr_baseline_advisory_message(
  command : String,
  baseline_sha : String,
) -> String {
  "verify: " +
  command +
  " failed but already red at baseline " +
  baseline_sha +
  " -> advisory, not blocking"
}

///|
async fn file_pr_failed_verify_advisory(
  agent_id : String?,
  file_pr_dir : String,
  command : String,
  baseline_sha_for_agent : (String) -> String?,
  baseline_git_capture : async (@workspace.Command) -> (Int, String),
  capture : async (@workspace.Command) -> (Int, String),
  baseline_verify : async (
    String,
    String,
    String,
    async (@workspace.Command) -> (Int, String),
    async (@workspace.Command) -> (Int, String),
  ) -> BaselineOutcome,
) -> String? {
  let id = match agent_id {
    Some(value) => value
    None => return None
  }
  let baseline_sha = match baseline_sha_for_agent(id) {
    Some(value) => value.trim().to_owned()
    None => return None
  }
  if baseline_sha == "" {
    return None
  }
  match
    baseline_verify(
      baseline_sha, command, file_pr_dir, baseline_git_capture, capture,
    ) {
    BaselineOutcome::AlreadyRed => {
      let message = file_pr_baseline_advisory_message(command, baseline_sha)
      @moontrace.warn(message, fields=[
        @moontrace.field("event", "verify_baseline_advisory"),
        @moontrace.field("context", "file_pr_verify"),
        @moontrace.field("command", command),
        @moontrace.field("baseline_sha", baseline_sha),
      ])
      Some(message)
    }
    BaselineOutcome::GreenAtBaseline | BaselineOutcome::Unknown => None
  }
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
pub fn file_pr_audit_receipt_required(
  parent_branch : String,
  default_branch : String,
) -> Bool {
  parent_branch == default_branch
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
pub async fn file_pr_run_required_verify(
  file_pr_dir : String,
  verify_commands : Array[String],
  capture : async (@workspace.Command) -> (Int, String),
  record_verify_outcome? : (FilePrVerifyOutcome) -> Unit = fn(_outcome) { () },
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
  agent_id? : String? = None,
  baseline_sha_for_agent? : (String) -> String? = fn(_) { None },
  baseline_git_capture? : async (@workspace.Command) -> (Int, String) = capture,
  baseline_verify? : async (
    String,
    String,
    String,
    async (@workspace.Command) -> (Int, String),
    async (@workspace.Command) -> (Int, String),
  ) -> BaselineOutcome = async fn(
    baseline_sha,
    command,
    project_dir,
    git_capture,
    capture,
  ) {
    baseline_verify_command_outcome(
      baseline_sha, command, project_dir, git_capture, capture,
    )
  },
) -> Result[Array[FilePrVerifyOutcome], @types.ChoirError] {
  let outcomes : Array[FilePrVerifyOutcome] = []
  let head_sha = file_pr_current_head_sha(file_pr_dir, capture)
  for raw in verify_commands {
    let raw_command = raw.trim().to_owned()
    let command = @types.moon_verify_normalize_command(
      raw_command, moon_verify_target,
    )
    if command == "" {
      continue
    }
    if command != raw_command {
      @moontrace.warn("moon verify command normalized", fields=[
        @moontrace.field("event", "moon_verify_command_normalized"),
        @moontrace.field("context", "file_pr_verify"),
        @moontrace.field("command", raw_command),
        @moontrace.field("normalized", command),
        @moontrace.field(
          "moon_verify_target",
          moon_verify_target.to_wire_string(),
        ),
      ])
    }
    let (exit_code, output) = capture(
      file_pr_verify_command(command, file_pr_dir),
    )
    let advisory = if exit_code <= 0 {
      None
    } else {
      file_pr_failed_verify_advisory(
        agent_id, file_pr_dir, command, baseline_sha_for_agent, baseline_git_capture,
        capture, baseline_verify,
      )
    }
    let outcome : FilePrVerifyOutcome = {
      command,
      exit_code,
      output_tail: file_pr_verify_output_tail(output),
      head_sha,
      advisory,
    }
    outcomes.push(outcome)
    record_verify_outcome(outcome)
    if exit_code != 0 && advisory is None {
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
    match outcome.advisory {
      Some(message) => lines.push("  - " + message)
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
fn file_pr_effective_task_contract(
  tracked_agent_id : String,
  caller_role : @types.Role,
  task_contract_reader : (String) -> @types.TaskContract?,
) -> @types.TaskContract? {
  match task_contract_reader(tracked_agent_id) {
    Some(contract) => Some(contract)
    None =>
      if tracked_agent_id == "root" && @types.is_supervisor_role(caller_role) {
        Some(@types.TaskContract::empty())
      } else {
        None
      }
  }
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
  caller_role : @types.Role,
  pr_number : Int,
  capture : async (@workspace.Command) -> (Int, String),
  task_contract_reader : (String) -> @types.TaskContract?,
) -> Unit {
  let issue_id = match
    file_pr_effective_task_contract(
      tracked_agent_id, caller_role, task_contract_reader,
    ) {
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
  RunRequiredVerify
  GitPush
  EnsurePullRequest
} derive(Debug, Eq)

///|
pub fn file_pr_preflight_host_steps() -> Array[FilePrPreflightHostStep] {
  [
    FilePrPreflightHostStep::EnsureBranchReady,
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
  spawn_launch_bindings : Array[SpawnLaunchCommandBinding]
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
  reviewer : @types.Reviewer,
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
  append_file? : (String, String) -> Bool = fn(_, _) { false },
  global_review_mode? : @types.ReviewMode = @types.Config::default().review_mode,
  task_contract_reader? : (String) -> @types.TaskContract? = fn(_) { None },
  tdd_phase_reader? : (String) -> @types.LeafTddPhase? = fn(_) { None },
  moon_verify_target? : @types.MoonVerifyTarget = @types.Config::default().moon_verify_target,
  baseline_sha_for_agent? : (String) -> String? = fn(_) { None },
  baseline_git_capture? : async (@workspace.Command) -> (Int, String) = capture,
  baseline_verify? : async (
    String,
    String,
    String,
    async (@workspace.Command) -> (Int, String),
    async (@workspace.Command) -> (Int, String),
  ) -> BaselineOutcome = async fn(
    baseline_sha,
    command,
    project_dir,
    git_capture,
    capture,
  ) {
    baseline_verify_command_outcome(
      baseline_sha, command, project_dir, git_capture, capture,
    )
  },
  skip_copilot_on_feature_branch? : Bool = @types.Config::default().pr_policy.skip_copilot_on_feature_branch,
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
  let default_branch = detect_default_branch_with_capture(project_dir, capture)
  let parent_branch = match file_pr_args.parent_branch {
    Some(pb) => pb
    None => default_branch
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
  let task_contract = file_pr_effective_task_contract(
    tracked_agent_id, caller_role, task_contract_reader,
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
          agent_id=Some(tracked_agent_id),
          baseline_sha_for_agent~,
          baseline_git_capture~,
          baseline_verify~,
        ) {
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
      let request_review = file_pr_should_request_reviewer(
        reviewer, parent_branch, default_branch, skip_copilot_on_feature_branch,
      )
      if reviewer != @types.Reviewer::None && !request_review {
        match file_pr_reviewer_handle(reviewer) {
          Some(handle) =>
            @moontrace.info("reviewer_skipped_for_feature_branch", fields=[
              @moontrace.field("pr_number", pr.number),
              @moontrace.field("parent_branch", parent_branch),
              @moontrace.field("reviewer", handle),
            ])
          None => ()
        }
      }
      let resp = interpret_file_pr_post_success(
        project_dir,
        session,
        branch,
        tracked_agent_id,
        file_pr_dir,
        pr.number,
        reviewer,
        effects,
        poller_state,
        registry,
        runner,
        append_file~,
        request_reviewer=request_review,
        sleep_fn~,
      )
      if resp.is_ok() {
        file_pr_mirror_beads_created(
          project_dir,
          tracked_agent_id,
          caller_role,
          pr.number,
          capture,
          task_contract_reader,
        )
      }
      resp
    }
  }
}

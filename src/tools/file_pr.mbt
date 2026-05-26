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
fn file_pr_mutation_gate_worktree_path(
  project_dir : String,
  worker_id : String,
) -> String? {
  let slug = @phase.extract_slug(worker_id)
  if slug.length() == 0 {
    return None
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
    "Process discipline (mandatory; bypassing this causes orphan subprocess trees):",
    "- If the adapter gap is detected, run this sequence only once: notify_parent --status failure -> shutdown -> exit. No lingering, no further subprocess calls.",
    "- EXIT IMMEDIATELY after that sequence. Do not \"verify cleanup\" via further subprocess calls.",
    "- Do not background any subprocess. No `&`, no `nohup`, no `setsid`, no `disown`. Every subprocess must be foreground and synchronously awaited.",
    "- Do not write a helper script that outlives this shell. If you need a state machine, inline it in the shell session you control directly.",
    "- Bound every subprocess with `timeout 60s` (e.g. `timeout 60s moon test --target native --release`). Even a single unbounded `moon test` can run for 30+ minutes.",
    "- Wrap your ENTIRE mutation loop with `timeout 600s` (10 min cap). The 60s per-subprocess bounds protect individual hangs; the 600s outer bound protects against unbounded N-mutant loops. If your script structure can't be cleanly wrapped, use a wall-clock check before each iteration that exits when `start_time + 600s < now`.",
    "- If the adapter gap is detected, your only remaining actions are: (a) call notify_parent --status failure ONCE, (b) shutdown, (c) exit. Do not run any verify command, do not run any mutant, do not poll for more information.",
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
    "- Call notify_parent exactly once. Use `notify_parent --status success` if the mutation run completed, even when mutants survived. Use `notify_parent --status failure` only if the worker could not run the gate.",
    "- The notify_parent message MUST contain one line beginning with " +
    mutation_gate_report_json_marker +
    " followed by JSON with fields kill_rate, total_mutants, killed_mutants, surviving_mutants, unsupported_languages.",
    "- Example: " +
    mutation_gate_report_json_marker +
    " {\"kill_rate\":0.75,\"total_mutants\":4,\"killed_mutants\":3,\"surviving_mutants\":[\"src/foo.mbt:12 == -> !=\"],\"unsupported_languages\":[]}",
    "- After notify_parent, call shutdown, then exit.",
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
async fn wait_for_mutation_gate_report_with_liveness(
  worker_id : String,
  wait_for_mutation_gate_report : async (String) -> MutationGateWorkerReport?,
  mutation_budget_ms : Int,
  now_ms_fn : () -> Int64,
  mutation_worker_alive : (String) -> Bool,
  sleep_fn : async (Int) -> Unit,
) -> MutationGateWaitOutcome {
  async fn drain_report() -> MutationGateWorkerReport? {
    match
      @async.with_timeout_opt(1, () => wait_for_mutation_gate_report(worker_id)) {
      Some(Some(report)) => Some(report)
      _ => None
    }
  }
  let started_ms = now_ms_fn()
  let budget_ms = mutation_budget_ms.to_int64()
  while true {
    if !mutation_worker_alive(worker_id) {
      match drain_report() {
        Some(report) => return MutationGateWaitOutcome::Reported(report)
        None => return MutationGateWaitOutcome::WorkerDied
      }
    }
    let elapsed_ms = now_ms_fn() - started_ms
    let remaining_ms = budget_ms - elapsed_ms
    if remaining_ms <= 0L {
      match drain_report() {
        Some(report) => return MutationGateWaitOutcome::Reported(report)
        None => return MutationGateWaitOutcome::Timeout
      }
    }
    let poll_ms = if remaining_ms > 250L { 250L } else { remaining_ms }
    let poll_result = @async.with_timeout_opt(poll_ms.to_int(), () => {
      wait_for_mutation_gate_report(worker_id)
    })
    match poll_result {
      None => sleep_fn(poll_ms.to_int())
      Some(None) => return MutationGateWaitOutcome::NoReport
      Some(Some(value)) => return MutationGateWaitOutcome::Reported(value)
    }
  }
  MutationGateWaitOutcome::Timeout
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
  cancel_worker? : (String) -> Unit = fn(_) {  },
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
    Err(e) =>
      return Err(
        @types.ChoirError::mutation_gate_incomplete(
          "[MUTATION GATE INCOMPLETE] file_pr: mutation gate worker spawn failed: " +
          e.validation_detail_or_message(),
        ),
      )
  }
  let wait_result = wait_for_mutation_gate_report_with_liveness(
    worker_id, wait_for_mutation_report, mutation_budget_ms, now_ms_fn, mutation_worker_alive,
    sleep_fn,
  )
  let mut should_cancel_worker = false
  let result = match wait_result {
    MutationGateWaitOutcome::Timeout => {
      should_cancel_worker = true
      Some(
        @types.ChoirError::timeout(
          "[MUTATION GATE INCOMPLETE] file_pr: mutation gate budget exceeded",
        ),
      )
    }
    MutationGateWaitOutcome::NoReport => {
      should_cancel_worker = true
      Some(
        @types.ChoirError::mutation_gate_incomplete(
          "[MUTATION GATE INCOMPLETE] file_pr: mutation gate worker did not report",
        ),
      )
    }
    MutationGateWaitOutcome::WorkerDied => {
      should_cancel_worker = true
      Some(
        @types.ChoirError::mutation_gate_incomplete(
          "[MUTATION GATE INCOMPLETE] file_pr: mutation gate worker exited before report",
        ),
      )
    }
    MutationGateWaitOutcome::Reported(report) =>
      if report.status == @types.Status::Failure {
        should_cancel_worker = true
        Some(
          @types.ChoirError::mutation_gate_incomplete(
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
              @types.ChoirError::mutation_gate_incomplete(
                "[MUTATION GATE INCOMPLETE] file_pr: mutation gate worker did not return " +
                mutation_gate_report_json_marker,
              ),
            )
        }
        // Reaching this arm means the worker REPORTED but the gate did not
        // clear (kill_rate below threshold OR malformed report). Reporting
        // is not the same as exiting — the prompt instructs the worker to
        // call shutdown after notify_parent, but the chain can hang on a
        // stuck timeout-wrapped subprocess. Cancel for consistency with
        // the other mutation_gate_incomplete branches.
        if result is Some(_) {
          should_cancel_worker = true
        }
        result
      }
  }
  if should_cancel_worker {
    cancel_worker(worker_id)
  }
  cleanup_mutation_report(worker_id)
  match result {
    Some(e) => Err(e)
    None => Ok(())
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
  append_file? : (String, String) -> Bool = fn(_, _) { false },
  prepare_mutation_gate_report? : (String) -> Unit = fn(_) {  },
  wait_for_mutation_gate_report? : async (String) -> MutationGateWorkerReport? = async fn(
    _,
  ) {
    @async.sleep(0)
    None
  },
  cancel_mutation_gate_worker? : (String) -> Unit = fn(_) {  },
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
              isolation=@types.IsolationMode::Worktree,
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
          cancel_worker=cancel_mutation_gate_worker,
          mutation_worker_alive=fn(worker_id) {
            match registry {
              Some(reg) => reg.is_alive(worker_id).unwrap_or(false)
              None => true
            }
          },
        ) {
        Ok(_) => ()
        Err(e) => return @types.Response::Err(e.validation_detail_or_message())
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

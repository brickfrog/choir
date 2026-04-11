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
      notified_parent: false,
      last_ci_rollup: @poller.CiRollupStatus::Unknown,
      last_timeout_at: 0L,
      copilot_issue_comment_seen: false,
      orphan_notified: false,
      orphan_reconciling: false,
      changes_requested_since: 0L,
      stall_notified: false,
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
) -> FilePrAutoNotifyPlan {
  match parent_result {
    Ok(parent) => {
      let delivery = @message.plan_delivery(
        parent,
        tracked_agent_id,
        notify_message,
        @types.Status::Success,
      )
      let delivery_log_append = "[auto-notify] caller=" +
        tracked_agent_id +
        " parent=" +
        parent.agent_id.to_string() +
        " delivery=" +
        delivery.to_display_string() +
        "\n"
      Deliver(delivery~, delivery_log_append~)
    }
    Err(e) => {
      let msg = e.message()
      ParentResolutionFailed(
        delivery_log_append="[auto-notify] resolve_parent_for_notify failed error=" +
          msg +
          "\n",
        parent_resolve_error=msg,
      )
    }
  }
}

///|
pub fn file_pr_auto_notify_delivery_failed_log_append(error : String) -> String {
  "[auto-notify] delivery failed error=" + error + "\n"
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
  read_chainlink_issue_id? : (String, String?, String) -> String? = @workspace.chainlink_issue_id_for_agent_workspace,
  write_back_pr? : async (String, String, Int) -> Unit = @chainlink.write_back_pr,
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
                  file_pr_auto_notify_delivery_failed_log_append(e.message()),
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
  let tracked_agent_workspace = agent_workspace_from_registry(
    registry, tracked_agent_id,
  )
  match
    read_chainlink_issue_id(
      project_dir,
      tracked_agent_workspace,
      @phase.extract_slug(tracked_agent_id),
    ) {
    Some(issue_id) =>
      match effects.response.ok_field("pr_url") {
        Some(pr_url) =>
          write_back_pr(issue_id, pr_url, pr_number) catch {
            _ =>
              @sys.write_stderr(
                "[chainlink] warn: PR write-back failed for issue " +
                issue_id +
                "\n",
              )
          }
        None => ()
      }
    None => ()
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
              "[file_pr] copilot_review_comment failed pr=" +
              pr_number.to_string() +
              err_part_c +
              "\n",
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
          "[file_pr] copilot_reviewer_request failed pr=" +
          pr_number.to_string() +
          err_part +
          "\n",
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
/// Tracked-agent workspace for `file_pr` git/push operations: use the agent's
/// `workspace` when present in the registry, else the project root.
pub fn file_pr_workdir(
  root_project_dir : String,
  tracked_agent_id : String,
  reg : @registry.AgentRegistry?,
) -> String {
  match reg {
    Some(agent_reg) =>
      try {
        let agent = agent_reg.get(tracked_agent_id)
        if agent.workspace != "" {
          agent.workspace
        } else {
          root_project_dir
        }
      } catch {
        _ => root_project_dir
      }
    None => root_project_dir
  }
}

///|
fn agent_workspace_from_registry(
  reg : @registry.AgentRegistry?,
  agent_id : String,
) -> String? {
  match reg {
    Some(agent_reg) =>
      try {
        let agent = agent_reg.get(agent_id)
        if agent.workspace != "" {
          Some(agent.workspace)
        } else {
          None
        }
      } catch {
        _ => None
      }
    None => None
  }
}

///|
/// Ordered host steps for `file_pr` before post-success effects. The
/// interpreter runs this exact sequence; kept as data for tests and docs.
pub(all) enum FilePrPreflightHostStep {
  EnsureBranchReady
  GitPush
  EnsurePullRequest
} derive(Debug, Eq)

///|
pub fn file_pr_preflight_host_steps() -> Array[FilePrPreflightHostStep] {
  [
    FilePrPreflightHostStep::EnsureBranchReady,
    FilePrPreflightHostStep::GitPush,
    FilePrPreflightHostStep::EnsurePullRequest,
  ]
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
    Ok(_) =>
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
}

///|
/// `track_pr`: poller `ensure_tracked`, persist state file, success JSON.
/// Preserves exact `ToolRequest::TrackPr` behavior from the prior dispatch arm.
pub fn interpret_track_pr(
  track_pr_args : TrackPrArgs,
  project_dir : String,
  poller_state : @poller.PollerState?,
  now_sec : Int64,
) -> @types.Response {
  match poller_state {
    Some(ps) => {
      ps.ensure_tracked(
        track_pr_args.pr_number,
        track_pr_args.agent_id,
        track_pr_args.branch,
        track_pr_args.parent_branch,
        track_pr_args.pr_url,
        now_sec,
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
}

///|
/// When `fork_wave` passes `review_context`, append a stable section so leaves can reuse it for `file_pr`.

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
) -> @types.Response {
  let branch = file_pr_args.branch
  let parent_branch = match file_pr_args.parent_branch {
    Some(pb) => pb
    None => detect_default_branch_with_capture(project_dir, capture)
  }
  let tracked_agent_id = file_pr_args.tracked_agent_id
  let file_pr_dir = file_pr_workdir(project_dir, tracked_agent_id, registry)
  let preflight_inputs = file_pr_preflight_create_inputs(
    file_pr_args, parent_branch, file_pr_dir,
  )
  match
    interpret_file_pr_preflight_create(
      preflight_inputs, ensure_branch_ready, runner, capture, ensure_pr,
    ) {
    Err(e) => @types.Response::Err(e.message())
    Ok(pr) => {
      let tracked = poller_state is Some(_)
      let plan = file_pr_plan(file_pr_args, parent_branch, pr, tracked)
      let effects = file_pr_post_success_effects(
        plan,
        poller_state is Some(_),
        registry is Some(_),
      )
      interpret_file_pr_post_success(
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
    }
  }
}

///|
pub impl Show for FilePrAutoNotifyPlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for FilePrPreflightHostStep with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

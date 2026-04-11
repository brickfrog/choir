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
/// Pure plan for `notify_parent`: optional parent resolution (when the registry
/// is present) maps to delivery + success lifecycle, a resolve error, or the
/// no-registry best-effort path. The dispatcher runs `execute_delivery` and
/// `apply_dev_event` only for the planned variant.
pub(all) enum NotifyParentPlan {
  NoRegistry(dev_event~ : @phase.DevEvent, response~ : @types.Response)
  ParentResolveFailed(error_message~ : String)
  Deliver(
    delivery~ : @message.DeliveryMethod,
    dev_event_on_success~ : @phase.DevEvent,
    response_ok~ : @types.Response
  )
}

///|
pub fn notify_parent_plan(
  args : CallerMessageArgs,
  parent_resolution : Result[@types.Agent, @types.ChoirError]?,
) -> NotifyParentPlan {
  match parent_resolution {
    None => {
      let dev_event = @phase.DevEvent::NotifyParentSuccess(message=args.message)
      NoRegistry(
        dev_event~,
        response=@types.Response::ok_values({
          "status": String::to_json("notified"),
        }),
      )
    }
    Some(Err(e)) => ParentResolveFailed(error_message=e.message())
    Some(Ok(parent)) => {
      let delivery = @message.plan_delivery(
        parent,
        args.caller_id,
        args.message,
        args.status,
      )
      let dev_event_on_success = @phase.DevEvent::NotifyParentSuccess(
        message=args.message,
      )
      Deliver(
        delivery~,
        dev_event_on_success~,
        response_ok=@types.Response::ok_values({
          "status": String::to_json("notified"),
        }),
      )
    }
  }
}

///|
/// Exact `.choir/delivery.log` line for `send_message` (matches historical
/// dispatch formatting).
pub fn send_message_delivery_log_append(
  target_id : String,
  agent : @types.Agent,
  delivery : @message.DeliveryMethod,
) -> String {
  "[send_message] target=" +
  target_id +
  " terminal_target=" +
  agent.terminal_target.map(@types.LocalTarget::to_string).unwrap_or("NONE") +
  " delivery=" +
  delivery.to_display_string() +
  "\n"
}

///|
/// Pure plan for `send_message`: optional registry lookup maps to a no-registry
/// best-effort ok, target lookup error, or delivery + log line + success
/// response. The host appends `delivery_log_append` then runs `execute_delivery`.
pub(all) enum SendMessagePlan {
  NoRegistry(response~ : @types.Response)
  RegistryLookupFailed(error_message~ : String)
  Deliver(
    delivery~ : @message.DeliveryMethod,
    delivery_log_append~ : String,
    response_ok~ : @types.Response
  )
}

///|
pub fn send_message_plan(
  target_id : String,
  sender_id : String,
  message : String,
  status : @types.Status,
  registry_lookup : Result[@types.Agent, @types.ChoirError]?,
) -> SendMessagePlan {
  match registry_lookup {
    None =>
      NoRegistry(
        response=@types.Response::ok_values({
          "status": String::to_json("sent"),
        }),
      )
    Some(Err(e)) => RegistryLookupFailed(error_message=e.message())
    Some(Ok(agent)) => {
      let delivery = @message.plan_delivery(agent, sender_id, message, status)
      let delivery_log_append = send_message_delivery_log_append(
        target_id, agent, delivery,
      )
      Deliver(
        delivery~,
        delivery_log_append~,
        response_ok=@types.Response::ok_values({
          "status": String::to_json("sent"),
        }),
      )
    }
  }
}

///|
/// Effectful `send_message` adapter: delivery-log append, `execute_delivery`,
/// moontrace on failure. Preserves historical `ToolRequest::SendMessage` flow.
pub async fn interpret_send_message(
  plan : SendMessagePlan,
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> @types.Response {
  match plan {
    SendMessagePlan::NoRegistry(response~) => response
    SendMessagePlan::RegistryLookupFailed(error_message~) =>
      @types.Response::Err(error_message)
    SendMessagePlan::Deliver(delivery~, delivery_log_append~, response_ok~) => {
      ignore(
        @sys.append_file_sync(
          project_dir + "/.choir/delivery.log",
          delivery_log_append,
        ),
      )
      match execute_delivery(delivery, runner, project_dir~, sleep_fn~) {
        Ok(_) => response_ok
        Err(e) => {
          @moontrace.error("send_message delivery failed", fields=[
            @moontrace.field("error", e.message()),
          ])
          @types.Response::Err(e.message())
        }
      }
    }
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
pub fn fork_wave_leaf_task_with_review_context(
  base_task : String,
  review_context : String?,
) -> String {
  match review_context {
    None => base_task
    Some(rc) => {
      let t = rc.trim().to_string()
      if t == "" {
        base_task
      } else {
        base_task + "\n\n## CHOIR_REVIEW_CONTEXT\n" + t + "\n"
      }
    }
  }
}

///|
/// Build [`ForkWaveSpawnPlan`] from resolved tool args and `child_spawn_depth`.
/// Uses `slugify_task` for per-leaf slugs; behavior matches the historical
/// `ToolRequest::ForkWave` inline loop in `dispatch`.
pub fn fork_wave_spawn_plan(
  fork_wave_args : ForkWaveArgs,
  child_spawn_depth : Int,
  registry : @registry.AgentRegistry?,
  project_dir : String,
  session : String,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  chainlink_enrichment_issue? : @types.ChainlinkIssue? = None,
) -> ForkWaveSpawnPlan {
  let agent_ids = StringBuilder::new()
  let skipped_ids = StringBuilder::new()
  let cmds : Array[@workspace.Command] = []
  let spawned_specs : Array[@types.SpawnSpec] = []
  let spawned_slugs : Array[String] = []
  let mut spawned_count = 0
  let mut skipped_count = 0
  let seen_slugs : Map[String, Int] = {}
  for i = 0; i < fork_wave_args.count; i = i + 1 {
    let raw_slug = if fork_wave_args.has_per_leaf_tasks {
      slugify_task(fork_wave_args.tasks[i], i)
    } else {
      fork_wave_args.slug_prefix + "-" + i.to_string()
    }
    let slug = match seen_slugs.get(raw_slug) {
      Some(count) => {
        seen_slugs.set(raw_slug, count + 1)
        raw_slug + "-" + i.to_string()
      }
      None => {
        seen_slugs.set(raw_slug, 1)
        raw_slug
      }
    }
    let agent_id = fork_wave_args.parent_branch + "." + slug
    let already_alive = match registry {
      Some(reg) =>
        try {
          match reg.get(agent_id).state {
            @types.AgentState::Active | @types.AgentState::Completing => true
            _ => false
          }
        } catch {
          _ => false
        }
      None => false
    }
    if already_alive {
      if skipped_count > 0 {
        skipped_ids.write_string(",")
      }
      skipped_ids.write_string(agent_id)
      skipped_count = skipped_count + 1
      continue
    }
    if spawned_count > 0 {
      agent_ids.write_string(",")
    }
    agent_ids.write_string(agent_id)
    spawned_count = spawned_count + 1
    spawned_slugs.push(slug)
    let leaf_task = fork_wave_leaf_task_with_review_context(
      fork_wave_args.tasks[i],
      fork_wave_args.review_context,
    )
    let mut task_contract = fork_wave_args.task_contracts[i]
    match chainlink_enrichment_issue {
      Some(issue) =>
        task_contract = @contract.merge_chainlink_into_task_contract(
          issue, task_contract,
        )
      None => ()
    }
    let spec = @types.SpawnSpec::{
      slug,
      role: fork_wave_args.child_role,
      agent_type: fork_wave_args.agent_type,
      task: leaf_task,
      task_contract: Some(task_contract),
      isolation: @types.IsolationMode::Worktree,
      parent_id: fork_wave_args.caller_id,
      parent_branch: fork_wave_args.parent_branch,
      reuse_workspace: false,
      workspace_slug: None,
      reuse_git_branch: None,
      spawn_depth: child_spawn_depth,
      automerge: fork_wave_args.automerge,
      chainlink_issue_id: fork_wave_args.chainlink_issue_id,
    }
    spawned_specs.push(spec)
    for
      cmd in @workspace.spawn_commands(
        spec,
        project_dir,
        session,
        parent_session_id=fork_wave_args.parent_session_id,
        extra_mcp_servers_json~,
        shell_command~,
        listen_uds~,
        listen_tcp~,
        tcp_auth_token~,
      ) {
      cmds.push(cmd)
    }
  }
  {
    cmds,
    spawned_specs,
    spawned_slugs,
    spawned_count,
    skipped_count,
    agent_ids: agent_ids.to_string(),
    skipped_ids: skipped_ids.to_string(),
  }
}

///|
/// Default parent branch when the tool passed `"main"`: detect the repository
/// default via `detect_default_branch_with_capture`. Preserves prior dispatch
/// behavior.
pub async fn fork_wave_resolve_args_parent_branch(
  fork_wave_args : ForkWaveArgs,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> ForkWaveArgs {
  let resolved_parent = if fork_wave_args.parent_branch == "main" {
    detect_default_branch_with_capture(project_dir, capture)
  } else {
    fork_wave_args.parent_branch
  }
  { ..fork_wave_args, parent_branch: resolved_parent }
}

///|
/// Caller spawn_depth from the registry when present and the agent exists.
pub fn fork_wave_caller_spawn_depth_from_registry(
  registry : @registry.AgentRegistry?,
  caller_id : String,
) -> Int? {
  match registry {
    Some(reg) => Some(reg.get(caller_id).spawn_depth) catch { _ => None }
    None => None
  }
}

///|
/// Child spawn depth for `fork_wave_spawn_plan` from caller depth and leaf role.
pub fn fork_wave_child_spawn_depth(
  caller_spawn_depth : Int?,
  child_role : @types.Role,
) -> Int {
  if child_role == @types.Role::TL {
    caller_spawn_depth.unwrap_or(0) + 1
  } else {
    caller_spawn_depth.unwrap_or(0)
  }
}

///|
/// Map `interpret fork_wave_plan` result to the tool response. On
/// [`ForkWaveError::CommandFailed`], re-runs capture on the failing command
/// (typically merged stdout/stderr via `capture_command_output`, not stderr-only).
/// Preserves exact `ToolRequest::ForkWave` strings.
pub async fn fork_wave_response_from_interpret_result(
  interpret_result : Result[@types.Response, ForkWaveError],
  capture_output : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  match interpret_result {
    Ok(r) => r
    Err(CommandFailed(status~, failing_cmd~)) => {
      let detail = match failing_cmd {
        Some(cmd) => {
          let (_, output) = capture_output(cmd)
          output.trim().to_string()
        }
        None => ""
      }
      if detail != "" {
        @types.Response::Err(
          "spawn failed (exit " + status.to_string() + "): " + detail,
        )
      } else {
        @types.Response::Err("command failed with status " + status.to_string())
      }
    }
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
/// Single entry point (from dispatch) for `fork_wave` pre-spawn / effect-phase
/// wiring: parent-branch defaulting, caller spawn-depth resolution, spawn plan,
/// scaffold gate + spawn via `interpret`, and spawn failure response mapping.
/// The `capture` injectable is shared for default-branch detection and for
/// re-capture on spawn failure. Post-spawn is [`interpret_fork_wave_post_spawn`].
pub async fn interpret_fork_wave_spawn_effect_phase(
  fork_wave_args : ForkWaveArgs,
  project_dir : String,
  session : String,
  registry : @registry.AgentRegistry?,
  capture : async (@workspace.Command) -> (Int, String),
  git_capture : async (String, Array[String]) -> String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
  chainlink_fetch? : (async (String) -> @types.ChainlinkIssue?)? = None,
) -> (@types.Response, ForkWaveArgs, ForkWaveSpawnPlan) {
  let fork_wave_args = fork_wave_resolve_args_parent_branch(
    fork_wave_args, project_dir, capture,
  )
  let caller_spawn_depth = fork_wave_caller_spawn_depth_from_registry(
    registry,
    fork_wave_args.caller_id,
  )
  let child_spawn_depth = fork_wave_child_spawn_depth(
    caller_spawn_depth,
    fork_wave_args.child_role,
  )

  // Chainlink enrichment
  let mut enrichment_issue : @types.ChainlinkIssue? = None
  match (fork_wave_args.chainlink_issue_id, chainlink_fetch) {
    (Some(id), Some(fetch)) =>
      match fetch(id) {
        Some(issue) => enrichment_issue = Some(issue)
        None =>
          @sys.write_stderr(
            "warning: failed to fetch chainlink issue #\{id} for enrichment\n",
          )
      }
    _ => ()
  }

  let spawn_plan = fork_wave_spawn_plan(
    fork_wave_args,
    child_spawn_depth,
    registry,
    project_dir,
    session,
    extra_mcp_servers_json~,
    shell_command~,
    listen_uds~,
    listen_tcp~,
    tcp_auth_token~,
    chainlink_enrichment_issue=enrichment_issue,
  )
  let plan = fork_wave_plan(
    project_dir,
    spawn_plan.cmds,
    spawn_plan.spawned_count,
    spawn_plan.skipped_count,
    spawn_plan.agent_ids,
    spawn_plan.skipped_ids,
  )
  let interpret_result = interpret(plan, git_capture~, runner~)
  let resp = fork_wave_response_from_interpret_result(interpret_result, capture)
  (resp, fork_wave_args, spawn_plan)
}

///|
/// Registry row for a spawned leaf after `fork_wave` host spawn succeeds (before
/// pane resolution overwrites `terminal_target`). Pure; matches the prior inline
/// `ToolRequest::ForkWave` upsert shape.
pub fn fork_wave_spawned_registry_agent(
  spec : @types.SpawnSpec,
  project_dir : String,
  session : String,
) -> @types.Agent {
  let agent_id = @workspace.canonical_agent_id(spec)
  let terminal_target = @workspace.local_target_for(
    session,
    spec.slug,
    spec.isolation,
  )
  {
    agent_id,
    role: spec.role,
    agent_type: spec.agent_type,
    state: @types.AgentState::Spawning,
    parent: Some(spec.parent_id),
    terminal_target: Some(terminal_target),
    host: @types.Host::Local,
    workspace: @workspace.worktree_path(
      project_dir,
      @workspace.spawn_workspace_dir_slug(spec),
    ),
    branch: @workspace.spawn_git_branch(spec),
    spawn_depth: spec.spawn_depth,
  }
}

///|
/// Ordered host-side phases for `fork_wave` after `interpret` succeeds with
/// `spawned_count > 0`. The interpreter runs this sequence.
pub(all) enum ForkWavePostSpawnHostStep {
  RegistryUpsertSpawnedSpecs
  PerSlugTeamRegisterAndTlEventAndPaneResolve
  RegistryTerminalTargetUpsertFromPanes
} derive(Debug, Eq)

///|
pub fn fork_wave_post_spawn_host_steps() -> Array[ForkWavePostSpawnHostStep] {
  [
    ForkWavePostSpawnHostStep::RegistryUpsertSpawnedSpecs,
    ForkWavePostSpawnHostStep::PerSlugTeamRegisterAndTlEventAndPaneResolve,
    ForkWavePostSpawnHostStep::RegistryTerminalTargetUpsertFromPanes,
  ]
}

///|
/// Post-spawn registry/team/TL/pane/terminal sequence for `fork_wave` when the
/// spawn effect phase returned ok and at least one leaf was spawned. Preserves
/// ordering and defaults (including `resolve_zellij_pane_id` capture) from the
/// prior inline `ToolRequest::ForkWave` arm.
pub async fn interpret_fork_wave_post_spawn(
  fork_wave_args : ForkWaveArgs,
  spawn_plan : ForkWaveSpawnPlan,
  project_dir : String,
  session : String,
  registry : @registry.AgentRegistry?,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
  claim_lock? : async (String, String) -> Bool = @chainlink.claim_lock,
  create_subissue? : async (String, String) -> Int? = async fn(
    parent_id : String,
    title : String,
  ) {
    @chainlink.create_subissue(parent_id, title)
  },
  write_plan_comment? : async (String, String) -> Unit = async fn(
    issue_id : String,
    text : String,
  ) {
    @chainlink.write_plan_comment(issue_id, text)
  },
  write_subissue_id? : (String, String, String) -> Bool = @workspace.write_chainlink_subissue_id,
) -> Unit {
  let resolved_pane_ids : Array[(String, String)] = []
  match registry {
    Some(reg) =>
      for spec in spawn_plan.spawned_specs {
        ignore(
          reg.upsert(
            fork_wave_spawned_registry_agent(spec, project_dir, session),
          ),
        )
      }
    None => ()
  }
  for spec in spawn_plan.spawned_specs {
    match spec.chainlink_issue_id {
      Some(parent_id) => {
        let branch = @workspace.spawn_git_branch(spec)
        let effective_id = if spawn_plan.spawned_count > 1 {
          let title = if spec.task.length() <= 80 {
            spec.task
          } else {
            spec.task[:80].to_string()
          }
          let created_subissue = create_subissue(parent_id, title) catch {
            _ => None
          }
          match created_subissue {
            Some(sub_id) => {
              let subissue_id = sub_id.to_string()
              if !write_subissue_id(project_dir, spec.slug, subissue_id) {
                @sys.write_stderr(
                  "[chainlink] warn: failed to persist subissue id " +
                  subissue_id +
                  " for " +
                  spec.slug +
                  "\n",
                )
              }
              subissue_id
            }
            None => parent_id
          }
        } else {
          parent_id
        }
        write_plan_comment(effective_id, spec.task) catch {
          _ => ()
        }
        let ok = claim_lock(effective_id, branch) catch { _ => false }
        if !ok {
          @sys.write_stderr(
            "[chainlink] warn: lock claim failed for issue " +
            effective_id +
            "\n",
          )
        }
      }
      None => ()
    }
  }
  for slug in spawn_plan.spawned_slugs {
    let _ = @workspace.register_team_member(
      fork_wave_args.caller_id,
      slug,
      @config.agent_type_to_string(fork_wave_args.agent_type),
    )
    let tl_effects = @phase.plan_tl_event_for_scope(
      project_dir,
      fork_wave_args.caller_id,
      @phase.TLEvent::ChildSpawned(child_id=slug),
      registry~,
    )
    @phase.interpret_lifecycle_effects(project_dir, tl_effects, registry~)
    let agent_id = @workspace.branch_name(fork_wave_args.parent_branch, slug)
    match resolve_zellij_pane_id(session, slug, capture~) {
      Some(pane_id) => resolved_pane_ids.push((agent_id, pane_id))
      None => ()
    }
  }
  match registry {
    Some(reg) =>
      for pair in resolved_pane_ids {
        let (agent_id, pane_id) = pair
        try {
          let agent = reg.get(agent_id)
          let target = @workspace.zellij_pane_target(session, pane_id)
          ignore(reg.upsert({ ..agent, terminal_target: Some(target) }))
        } catch {
          _ => ()
        }
      }
    None => ()
  }
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
/// Ordered host-side steps for `merge_pr` preflight when `force` is false
/// (poller read is synchronous; thread fetch uses `capture`). Matches
/// `interpret_merge_pr_preflight`.
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
/// `merge_pr` preflight when `force` is false: poller snapshot first, unresolved
/// review-thread fetch second, then `merge_pr_preflight_block_message`. When
/// `force` is true, skips all checks (same as the historical inline gate).
pub async fn interpret_merge_pr_preflight(
  force : Bool,
  pr_number : Int,
  poller_state : @poller.PollerState?,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
  registry : @registry.AgentRegistry?,
) -> Result[Unit, @types.ChoirError] {
  if force {
    return Ok(())
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
      let task_contract = match registry {
        Some(reg) =>
          @workspace.task_contract_for_agent_workspace(
            project_dir,
            Some(reg.get(tracked.agent_id).workspace) catch {
              _ => None
            },
            @phase.extract_slug(tracked.agent_id),
          )
        None => None
      }
      Some(
        @poller.merge_policy_decision_for_tracked_pr(
          tracked,
          Some(thread_count),
          task_contract~,
        ),
      )
    }
    None => None
  }
  match
    merge_pr_preflight_block_message(
      pr_number, poller_tracked, thread_count, thread_text, policy_decision,
    ) {
    Some(msg) => Err(@types.ChoirError::validation_error(msg))
    None => Ok(())
  }
}

///|
/// Pre-merge gating for `merge_pr` when `force` is false: poller review state
/// is checked first, then unresolved GraphQL review threads. Returns `Some(err)`
/// when the merge must not proceed; `None` when checks pass.
pub fn merge_pr_preflight_block_message(
  pr_number : Int,
  poller_tracked : @poller.TrackedPR?,
  unresolved_thread_count : Int,
  unresolved_thread_text : String,
  policy_decision : @policy.MergeDecision?,
) -> String? {
  match poller_tracked {
    Some(tracked) =>
      if tracked.last_review_state == @poller.ReviewState::ChangesRequested {
        return Some(
          "PR #" +
          pr_number.to_string() +
          " has unresolved review comments (ChangesRequested). " +
          "Wait for the owning agent to push fixes, or pass force=true to override.",
        )
      }
    None => ()
  }
  match policy_decision {
    Some(@policy.MergeDecision::Blocked(reason~)) =>
      return Some(
        "policy blocked: " +
        reason +
        ". Address the blocking policy condition before merging, or pass force=true to override.",
      )
    Some(@policy.MergeDecision::Wait(reason~)) =>
      return Some(
        "policy wait: " +
        reason +
        ". Wait for the policy condition to clear, or pass force=true to override.",
      )
    Some(@policy.MergeDecision::NeedsHuman(reason~)) =>
      return Some(
        "policy requires human check: " +
        reason +
        ". Request the required human check before merging, or pass force=true to override.",
      )
    _ => ()
  }
  if unresolved_thread_count > 0 {
    return Some(
      "PR #" +
      pr_number.to_string() +
      " has " +
      unresolved_thread_count.to_string() +
      " unresolved review thread(s). Address or resolve them before merging:\n" +
      unresolved_thread_text +
      "\nUse resolve_review_thread to mark threads resolved, or pass force=true to override.",
    )
  }
  None
}

///|
/// TL-facing re-check snapshot after actionable CI poller transitions
/// (`CIFailureCleared`, `CILatestHeadRollupSucceeded`). Honest about review state,
/// CI rollup, and unresolved threads; does not claim merge or call `merge_pr`.
/// `unresolved_thread_count` is `None` when the GraphQL fetch was not performed.
pub fn format_tl_pr_recheck_summary(
  tracked : @poller.TrackedPR,
  _project_dir : String,
  unresolved_thread_count : Int?,
  task_contract? : @types.TaskContract? = None,
) -> String {
  ignore(task_contract)
  let review = match tracked.last_review_state {
    None_ => "none"
    Commented => "commented"
    Approved => "approved"
    ChangesRequested => "changes_requested"
  }
  let ci = match tracked.last_ci_rollup {
    Unknown => "unknown"
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

  let advisory = @poller.advisory_evaluation_summary_line(
    tracked,
    unresolved_thread_count,
    task_contract~,
  )
  let policy = @poller.merge_policy_summary_line(
    tracked,
    unresolved_thread_count,
    task_contract~,
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
/// Mutex bracket + strict command run + failure capture/mapping. Preserves the
/// historical sequence: acquire (optional) → `run_strict(merge_pr_commands)` →
/// release → on `run_strict` failure, ignore its string and derive the user
/// error from a fresh `capture(merge_pr_command)` only.
pub async fn interpret_merge_pr_merge_host(
  parent_branch : String,
  pr_number : Int,
  caller_id : String,
  mutex_registry : @registry.MutexRegistry?,
  now_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[Unit, @types.ChoirError] {
  let mutex_name = merge_pr_mutex_name(parent_branch)
  match mutex_registry {
    Some(reg) => {
      let (acquired, _) = reg.acquire(
        mutex_name, caller_id, merge_pr_mutex_ttl_sec, now_sec,
      )
      if !acquired {
        ignore(reg.release(mutex_name, caller_id))
        return Err(
          @types.ChoirError::validation_error(
            merge_pr_serialization_busy_message(),
          ),
        )
      }
    }
    None => ()
  }
  let cmds = merge_pr_commands(pr_number)
  let merge_result = run_strict(runner, cmds, capture~)
  match mutex_registry {
    Some(reg) => ignore(reg.release(mutex_name, caller_id))
    None => ()
  }
  match merge_result {
    Err(_) => {
      let (_, output) = capture(merge_pr_command(pr_number))
      let trimmed = output.trim().to_string()
      Err(
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(pr_number, trimmed),
        ),
      )
    }
    Ok(_) => Ok(())
  }
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
/// After `interpret_merge_pr_merge_host` succeeds: resolve tracked branch,
/// build `merge_pr_post_success_plan`, apply the TL lifecycle event, optionally
/// untrack and persist poller state, return the tool response.
pub async fn interpret_merge_pr_post_success(
  project_dir : String,
  caller_id : String,
  pr_number : Int,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  read_chainlink_issue_id? : (String, String?, String) -> String? = @workspace.chainlink_issue_id_for_agent_workspace,
  write_back_merge? : async (String, Int, String) -> Unit = @chainlink.write_back_merge,
  release_lock? : async (String) -> Bool = @chainlink.release_lock,
) -> @types.Response {
  let tracked = match poller_state {
    Some(ps) => ps.get(pr_number)
    None => None
  }
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
        ps.untrack(pr_number)
        ignore(ps.write_state_file(project_dir))
      }
      None => ()
    }
  }
  match tracked {
    Some(pr) =>
      match
        read_chainlink_issue_id(
          project_dir,
          agent_workspace_from_registry(registry, pr.agent_id),
          @phase.extract_slug(pr.agent_id),
        ) {
        Some(issue_id) => {
          write_back_merge(issue_id, pr_number, pr.branch) catch {
            _ =>
              @sys.write_stderr(
                "[chainlink] warn: merge write-back failed for issue " +
                issue_id +
                "\n",
              )
          }
          let released = release_lock(issue_id) catch { _ => false }
          if !released {
            @sys.write_stderr(
              "[chainlink] warn: lock release failed for issue " +
              issue_id +
              "\n",
            )
          }
        }
        None => ()
      }
    None => ()
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
) -> @types.Response {
  match
    interpret_merge_pr_preflight(
      merge_args.force,
      merge_args.pr_number,
      poller_state,
      project_dir,
      capture,
      registry,
    ) {
    Err(e) => @types.Response::Err(e.message())
    Ok(_) =>
      match
        interpret_merge_pr_merge_host(
          merge_args.parent_branch,
          merge_args.pr_number,
          merge_args.caller_id,
          mutex_registry,
          @poller.now_sec(),
          runner,
          capture,
        ) {
        Err(e) => @types.Response::Err(e.message())
        Ok(_) =>
          interpret_merge_pr_post_success(
            project_dir,
            merge_args.caller_id,
            merge_args.pr_number,
            poller_state,
            registry,
          )
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
  {
    program: "gh",
    args: [
      "api",
      "graphql",
      "-f",
      "query=" + resolve_review_thread_graphql_mutation(),
      "-F",
      "threadId=" + thread_id,
    ],
    workdir: Some(project_dir),
  }
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
    let trimmed = output.trim().to_string()
    return @types.Response::Err(
      if trimmed != "" {
        "resolve_review_thread failed: " + trimmed
      } else {
        "resolve_review_thread failed (exit " + exit_code.to_string() + ")"
      },
    )
  }
  if output.trim().to_string() == "" {
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

///|
/// Pure `ToolRequest::Shutdown` response when `caller_id` is absent (best-effort ok).
pub fn shutdown_missing_caller_response() -> @types.Response {
  @types.Response::ok_values({ "status": String::to_json("shutdown") })
}

///|
/// User-facing error when poller blocks shutdown during a critical PR phase.
pub fn shutdown_poller_block_message(pr_number : Int) -> String {
  "cannot shutdown: PR #" +
  pr_number.to_string() +
  " has changes requested — push fixes first"
}

///|
/// Pure predicate: workspace path qualifies for choir-managed worktree removal on
/// shutdown (matches `agent.workspace.contains(".choir/worktrees/")` in dispatch).
pub fn shutdown_intent_remove_choir_worktree(workspace : String) -> Bool {
  workspace.contains(".choir/worktrees/")
}

///|
/// Optional pane-close command for `kill_agent` when the agent has a terminal target.
pub fn kill_agent_pane_close_command(
  agent : @types.Agent,
) -> @workspace.Command? {
  match agent.terminal_target {
    Some(t) => Some(@workspace.local_close_target(t))
    None => None
  }
}

///|
/// Optional `git worktree remove` command for `kill_agent` when the workspace path
/// is a choir-managed worktree (same predicate as `shutdown_intent_remove_choir_worktree`).
pub fn kill_agent_worktree_remove_command(
  agent : @types.Agent,
) -> @workspace.Command? {
  if shutdown_intent_remove_choir_worktree(agent.workspace) {
    Some(@workspace.git_worktree_remove(agent.workspace))
  } else {
    None
  }
}

///|
/// Success JSON for `kill_agent` after registry failure state is applied.
pub fn kill_agent_ok_response(agent_id : String) -> @types.Response {
  @types.Response::ok_values({
    "status": String::to_json("killed"),
    "agent_id": String::to_json(agent_id),
  })
}

///|
/// Adapter-side ordering for `kill_agent`: pane close attempt, then worktree
/// remove attempt (each may be skipped when the corresponding command is absent).
pub(all) enum KillAgentAdapterHostStep {
  PaneClose
  WorktreeRemove
} derive(Debug, Eq)

///|
pub fn kill_agent_adapter_host_steps() -> Array[KillAgentAdapterHostStep] {
  [
    KillAgentAdapterHostStep::PaneClose,
    KillAgentAdapterHostStep::WorktreeRemove,
  ]
}

///|
/// Effectful `kill_agent` adapter: optional pane close, optional worktree remove,
/// registry failed state, warning log, success response. Preserves historical
/// `ToolRequest::KillAgent` control flow while keeping `dispatch` as a thin caller.
pub async fn interpret_kill_agent(
  args : KillAgentArgs,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  read_chainlink_issue_id? : (String, String?, String) -> String? = @workspace.chainlink_issue_id_for_agent_workspace,
  release_lock? : async (String) -> Bool = @chainlink.release_lock,
) -> @types.Response {
  match registry {
    None => @types.Response::Err("no agent registry available")
    Some(reg) => {
      let agent = reg.get(args.agent_id) catch {
        _ => return @types.Response::Err("agent not found: " + args.agent_id)
      }
      let mut pane_close_failed = false
      match kill_agent_pane_close_command(agent) {
        Some(cmd) => {
          let codes = runner([cmd]) catch { _ => [-1] }
          if codes.length() > 0 && codes[0] != 0 {
            pane_close_failed = true
            @moontrace.warn("kill_agent pane close failed", fields=[
              @moontrace.field("agent_id", args.agent_id),
              @moontrace.field("exit", codes[0]),
              @moontrace.field("cmd", cmd.to_string()),
            ])
          }
        }
        None => ()
      }
      match kill_agent_worktree_remove_command(agent) {
        Some(cmd) => {
          let _ = runner([cmd])
          ()
        }
        None => ()
      }
      match
        read_chainlink_issue_id(
          ".",
          Some(agent.workspace),
          @phase.extract_slug(args.agent_id),
        ) {
        Some(issue_id) => {
          let released = release_lock(issue_id) catch { _ => false }
          if !released {
            @sys.write_stderr(
              "[chainlink] warn: lock release failed for issue " +
              issue_id +
              "\n",
            )
          }
        }
        None => ()
      }
      ignore(reg.set_state(args.agent_id, @types.AgentState::Failed)) catch {
        _ => ()
      }
      @moontrace.warn("agent killed", fields=[
        @moontrace.field("agent_id", args.agent_id),
        @moontrace.field("reason", args.reason),
      ])
      let response = kill_agent_ok_response(args.agent_id)
      if pane_close_failed {
        response.with_warning(
          "pane close failed — zellij tab/pane may still be open",
        )
      } else {
        response
      }
    }
  }
}

///|
/// Pure post-lifecycle plan for `shutdown`: maps `lifecycle_exit_policy` and
/// Dev-vs-non-Dev workflow to the tool response, whether to append `ExitRequested`,
/// and whether the interpreter may attempt `git worktree remove` for choir paths.
pub(all) struct ShutdownExitPlan {
  response : @types.Response
  apply_dev_exit_requested : Bool
  attempt_worktree_cleanup : Bool
}

///|
pub fn shutdown_exit_plan(
  lifecycle : @phase.AgentLifecycle,
) -> ShutdownExitPlan {
  let dev_may_request_exit = match lifecycle.workflow {
    @phase.WorkflowState::Dev(_) => true
    _ => false
  }
  match @phase.lifecycle_exit_policy(lifecycle) {
    @phase.LifecycleExitPolicy::Blocked(reason~) =>
      ShutdownExitPlan::{
        response: @types.Response::Err(@phase.exit_block_reason_message(reason)),
        apply_dev_exit_requested: false,
        attempt_worktree_cleanup: false,
      }
    @phase.LifecycleExitPolicy::Deferred(message~) =>
      ShutdownExitPlan::{
        response: @types.Response::ok_values({
          "status": String::to_json("deferred"),
          "warning": String::to_json(message),
        }),
        apply_dev_exit_requested: dev_may_request_exit,
        attempt_worktree_cleanup: false,
      }
    @phase.LifecycleExitPolicy::Allowed =>
      ShutdownExitPlan::{
        response: @types.Response::ok_values({
          "status": String::to_json("shutdown"),
        }),
        apply_dev_exit_requested: dev_may_request_exit,
        attempt_worktree_cleanup: true,
      }
  }
}

///|
/// Adapter-side ordering for `shutdown`: poller gate, registry role, lifecycle
/// read, optional dev exit event, optional worktree removal (matches dispatch).
pub(all) enum ShutdownAdapterHostStep {
  PollerCriticalPhaseRead
  RegistryRoleLookup
  LifecycleRead
  DevExitEventApply
  WorktreeCleanupAttempt
} derive(Debug, Eq)

///|
pub fn shutdown_adapter_host_steps() -> Array[ShutdownAdapterHostStep] {
  [
    ShutdownAdapterHostStep::PollerCriticalPhaseRead,
    ShutdownAdapterHostStep::RegistryRoleLookup,
    ShutdownAdapterHostStep::LifecycleRead,
    ShutdownAdapterHostStep::DevExitEventApply,
    ShutdownAdapterHostStep::WorktreeCleanupAttempt,
  ]
}

///|
/// When the poller is present and reports a critical-phase PR for this agent,
/// returns that PR number so the host can block shutdown (same read as inline
/// `critical_phase_pr_number` in dispatch).
pub fn shutdown_poller_block_pr_number(
  poller_state : @poller.PollerState?,
  caller_id : String,
) -> Int? {
  match poller_state {
    Some(ps) => ps.critical_phase_pr_number(caller_id)
    None => None
  }
}

///|
/// Registry-backed role for shutdown lifecycle reads: missing registry or agent
/// falls back to `Dev` (matches dispatch).
pub fn shutdown_registry_role_for_caller(
  registry : @registry.AgentRegistry?,
  caller_id : String,
) -> @types.Role {
  match registry {
    Some(reg) => reg.get(caller_id).role catch { _ => @types.Role::Dev }
    None => @types.Role::Dev
  }
}

///|
/// Format the handoff comment body written to a Chainlink issue on leaf shutdown.
/// Pure; no I/O.
pub fn format_handoff_comment(
  slug : String,
  role : @types.Role,
  branch : String,
  pr_number : Int?,
) -> String {
  let branch_display = if branch == "" { "(unknown)" } else { branch }
  let pr_display = match pr_number {
    Some(n) => "#" + n.to_string()
    None => "(none)"
  }
  "[\{slug}] [\{role.to_wire_string()}] shutdown\nbranch: \{branch_display}\npr: \{pr_display}"
}

///|
/// Extract the PR number from a [`DevLifecycle`] when the workflow carries one
/// (e.g. `ReviewOwned`, `ChangesRequested`, `ExitRequestedDeferred`). Returns
/// `None` for phases without a PR (`Working`, `Exitable`, `Done`, `Failed`).
pub fn dev_lifecycle_pr_number(dev_lifecycle : @phase.DevLifecycle) -> Int? {
  match dev_lifecycle {
    @phase.DevLifecycle::ReviewOwned(pr_number~, ..) => Some(pr_number)
    @phase.DevLifecycle::ChangesRequested(pr_number~, ..) => Some(pr_number)
    @phase.DevLifecycle::ExitRequestedDeferred(pr_number~, ..) =>
      Some(pr_number)
    _ => None
  }
}

///|
/// Extract the PR number from a [`WorkflowState`] when the workflow carries one.
/// For `Dev(DevLifecycle)`, extracts from `ReviewOwned`, `ChangesRequested`,
/// and `ExitRequestedDeferred` variants. For `Supervisor(SupervisorLifecycle)`,
/// extracts from `OwnPRFiled`.
pub fn workflow_state_pr_number(workflow : @phase.WorkflowState) -> Int? {
  match workflow {
    @phase.WorkflowState::Dev(dev) => dev_lifecycle_pr_number(dev)
    @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::OwnPRFiled(number~, ..)
    ) => Some(number)
    _ => None
  }
}

///|
/// Async helper: write a handoff comment to a Chainlink issue via the CLI.
/// Failure is silent (log nothing, return Unit).
pub async fn write_chainlink_handoff(
  issue_id : String,
  comment : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let cmd : @workspace.Command = {
    program: "chainlink",
    args: ["issue", "comment", issue_id, comment, "--kind", "handoff"],
    workdir: None,
  }
  let _ = runner([cmd])
  ()
}

///|
/// Effectful shutdown adapter: poller gate, lifecycle + `shutdown_exit_plan`,
/// dev exit event, optional Chainlink handoff comment, worktree cleanup.
/// Chainlink issue ID and handoff fields are resolved BEFORE worktree cleanup
/// to avoid the race where `git worktree remove` deletes the worktree
/// (including `.chainlink_issue_id` / `config.local.toml`) before the handoff
/// comment can be written. The optional `chainlink_write_handoff` injectable
/// allows tests to verify the handoff without a real Chainlink CLI.
pub async fn interpret_shutdown(
  args : ShutdownArgs,
  project_dir : String,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  chainlink_write_handoff? : (async (String, String) -> Unit)? = None,
) -> @types.Response {
  let caller_id = match args.caller_id {
    Some(v) => v
    None => return shutdown_missing_caller_response()
  }
  match shutdown_poller_block_pr_number(poller_state, caller_id) {
    Some(pr_number) =>
      return @types.Response::Err(shutdown_poller_block_message(pr_number))
    None => ()
  }
  let role = shutdown_registry_role_for_caller(registry, caller_id)
  let lifecycle = @phase.read_or_default_lifecycle(project_dir, caller_id, role)
  let plan = shutdown_exit_plan(lifecycle)
  if plan.apply_dev_exit_requested {
    ignore(
      apply_dev_event_checked(
        project_dir,
        caller_id,
        @phase.DevEvent::ExitRequested,
        registry~,
      ),
    )
  }
  // Resolve handoff fields BEFORE worktree cleanup to avoid the race where
  // `git worktree remove` deletes the worktree (and the chainlink issue id
  // file / config.local.toml within it) before we can read them.
  let handoff : (String, String)? = match plan.response {
    @types.Response::Err(_) => None
    @types.Response::Ok(_) => {
      let slug = @phase.extract_slug(caller_id)
      let agent_workspace = agent_workspace_from_registry(registry, caller_id)
      let chainlink_issue_id = @workspace.chainlink_issue_id_for_agent_workspace(
        project_dir, agent_workspace, slug,
      )
      match chainlink_issue_id {
        Some(issue_id) => {
          let branch = match registry {
            Some(reg) => reg.get(caller_id).branch catch { _ => "" }
            None => ""
          }
          let pr_number = workflow_state_pr_number(lifecycle.workflow)
          let comment = format_handoff_comment(slug, role, branch, pr_number)
          Some((issue_id, comment))
        }
        None => None
      }
    }
  }
  // Now safe to run worktree cleanup — handoff data already captured.
  if plan.attempt_worktree_cleanup {
    match registry {
      Some(reg) =>
        try {
          let agent = reg.get(caller_id)
          if shutdown_intent_remove_choir_worktree(agent.workspace) {
            let _ = runner([@workspace.git_worktree_remove(agent.workspace)])
            ()
          }
        } catch {
          _ => ()
        }
      None => ()
    }
  }
  // Write Chainlink handoff comment using pre-resolved data.
  match handoff {
    Some((issue_id, comment)) =>
      match chainlink_write_handoff {
        Some(injected) => injected(issue_id, comment) catch { _ => () }
        None =>
          write_chainlink_handoff(issue_id, comment, runner) catch {
            _ => ()
          }
      }
    None => ()
  }
  plan.response
}

///|
/// Resolved parent id for `cancel_wave` when `caller_id` is omitted from the
/// tool request (matches historical `dispatch` default).
pub fn cancel_wave_resolved_caller_id(caller_id : String?) -> String {
  match caller_id {
    Some(v) => v
    None => "main"
  }
}

///|
/// Children targeted by `cancel_wave`: `Spawning` or `Active` only.
pub fn cancel_wave_non_terminal_agents(
  children : Array[@types.Agent],
) -> Array[@types.Agent] {
  children.filter(fn(agent) {
    agent.state == @types.AgentState::Spawning ||
    agent.state == @types.AgentState::Active
  })
}

///|
/// User-facing error when `force=false` and the poller reports a critical-phase
/// PR for the agent (stable `cancel_wave` wording).
pub fn cancel_wave_poller_block_message(
  agent_id : String,
  pr_number : Int,
) -> String {
  "cancel_wave: agent " +
  agent_id +
  " is blocked by PR #" +
  pr_number.to_string() +
  " with changes requested -- use force=true to override"
}

///|
/// Preflight when `force=false`: first matching non-terminal agent in iteration
/// order yields a block message; `None` means proceed. Poller absence skips the
/// gate (same as inline `cancel_wave`).
pub fn cancel_wave_preflight_block_message(
  force : Bool,
  non_terminal : Array[@types.Agent],
  poller_state : @poller.PollerState?,
) -> String? {
  if force {
    return None
  }
  let ps = match poller_state {
    Some(p) => p
    None => return None
  }
  for agent in non_terminal {
    let agent_id_str = agent.agent_id.to_string()
    match ps.critical_phase_pr_number(agent_id_str) {
      Some(pr_number) =>
        return Some(cancel_wave_poller_block_message(agent_id_str, pr_number))
      None => ()
    }
  }
  None
}

///|
/// Success JSON for `cancel_wave` after per-agent teardown.
pub fn cancel_wave_ok_response(cancelled : Int) -> @types.Response {
  @types.Response::ok_values({
    "status": String::to_json("ok"),
    "cancelled": Int::to_json(cancelled),
  })
}

///|
/// Per-agent host steps for `cancel_wave` (ordering matches dispatch).
pub(all) enum CancelWavePerAgentHostStep {
  PaneClose
  WorktreeRemove
  RegistryFailed
  PollerUntrack
} derive(Debug, Eq)

///|
pub fn cancel_wave_per_agent_host_steps() -> Array[CancelWavePerAgentHostStep] {
  [
    CancelWavePerAgentHostStep::PaneClose,
    CancelWavePerAgentHostStep::WorktreeRemove,
    CancelWavePerAgentHostStep::RegistryFailed,
    CancelWavePerAgentHostStep::PollerUntrack,
  ]
}

///|
/// Effectful `cancel_wave` adapter: preflight gate, per-agent pane/worktree/
/// registry/poller steps, optional poller persistence. Preserves historical
/// `ToolRequest::CancelWave` control flow while keeping `dispatch` as a thin caller.
pub async fn interpret_cancel_wave(
  args : CancelWaveArgs,
  caller_id : String?,
  project_dir : String,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> @types.Response {
  match registry {
    None => @types.Response::Err("no agent registry available")
    Some(reg) => {
      let resolved_caller = cancel_wave_resolved_caller_id(caller_id)
      let children = reg.children(resolved_caller)
      let non_terminal = cancel_wave_non_terminal_agents(children)
      match
        cancel_wave_preflight_block_message(
          args.force,
          non_terminal,
          poller_state,
        ) {
        Some(msg) => return @types.Response::Err(msg)
        None => ()
      }
      let mut cancelled = 0
      let mut poller_changed = false
      for agent in non_terminal {
        let agent_id_str = agent.agent_id.to_string()
        match agent.terminal_target {
          Some(t) => {
            let kill_cmd = @workspace.local_close_target(t)
            let _ = runner([kill_cmd])
            ()
          }
          None => ()
        }
        if agent.workspace.contains(".choir/worktrees/") {
          let _ = runner([@workspace.git_worktree_remove(agent.workspace)])
          ()
        }
        let _ = reg.set_state(agent_id_str, @types.AgentState::Failed)
        match poller_state {
          Some(ps) => {
            let untracked = ps.untrack_by_agent_id(agent_id_str)
            if untracked > 0 {
              poller_changed = true
            }
          }
          None => ()
        }
        cancelled += 1
      }
      if poller_changed {
        match poller_state {
          Some(ps) => ignore(ps.write_state_file(project_dir))
          None => ()
        }
      }
      cancel_wave_ok_response(cancelled)
    }
  }
}

///|
/// Pure plan for `spawn_worker` after default-branch resolution: spawn spec,
/// canonical id, terminal target, registry upsert row, and success response.
pub(all) struct SpawnWorkerPlan {
  spec : @types.SpawnSpec
  agent_id : String
  terminal_target : @types.LocalTarget
  registry_agent : @types.Agent
  ok_response : @types.Response
}

///|
pub fn spawn_worker_ok_response(agent_id : String) -> @types.Response {
  @types.Response::ok_values({
    "status": String::to_json("spawned"),
    "agent_id": String::to_json(agent_id),
    "agent_ids": String::to_json(agent_id),
  })
}

///|
/// Build [`SpawnWorkerPlan`] from tool args and resolved parent branch (from
/// [`detect_default_branch_with_capture`] or an injected value in tests).
pub fn spawn_worker_plan(
  worker_args : WorkerSpawnArgs,
  resolved_parent_branch : String,
  session : String,
  project_dir : String,
) -> SpawnWorkerPlan {
  let spec = @types.SpawnSpec::{
    slug: worker_args.slug,
    role: @types.Role::Worker,
    agent_type: worker_args.agent_type,
    task: worker_args.task,
    task_contract: Some(worker_args.task_contract),
    isolation: @types.IsolationMode::Inline,
    parent_id: worker_args.caller_id,
    parent_branch: resolved_parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    chainlink_issue_id: None,
  }
  let agent_id = @workspace.canonical_agent_id(spec)
  let terminal_target = @workspace.local_target_for(
    session,
    spec.slug,
    spec.isolation,
  )
  let registry_agent = @types.Agent::{
    agent_id,
    role: @types.Role::Worker,
    agent_type: worker_args.agent_type,
    state: @types.AgentState::Active,
    parent: Some(worker_args.caller_id),
    terminal_target: Some(terminal_target),
    host: @types.Host::Local,
    workspace: project_dir,
    branch: agent_id,
    spawn_depth: 0,
  }
  {
    spec,
    agent_id,
    terminal_target,
    registry_agent,
    ok_response: spawn_worker_ok_response(agent_id),
  }
}

///|
/// `spawn_worker` host path: resolve default branch, build plan, spawn
/// commands, registry upsert, success response. Preserves historical
/// `ToolRequest::SpawnWorker` control flow while keeping `dispatch` as a thin caller.
pub async fn interpret_spawn_worker(
  worker_args : WorkerSpawnArgs,
  project_dir : String,
  session : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  registry : @registry.AgentRegistry?,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> @types.Response {
  let resolved_parent_branch = detect_default_branch_with_capture(
    project_dir, capture,
  )
  let plan = spawn_worker_plan(
    worker_args, resolved_parent_branch, session, project_dir,
  )
  let cmds = @workspace.spawn_commands(
    plan.spec,
    project_dir,
    session,
    parent_session_id=None,
    extra_mcp_servers_json~,
    shell_command~,
    listen_uds~,
    listen_tcp~,
    tcp_auth_token~,
  )
  match run_strict(runner, cmds, capture~) {
    Ok(_) => {
      match registry {
        Some(reg) => ignore(reg.upsert(plan.registry_agent))
        None => ()
      }
      plan.ok_response
    }
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
/// Pure plan for `spawn_remote`: fixed Dev/Claude worktree spec and success JSON
/// (agent id, slug, ssh host). The interpreter runs `remote_spawn_commands` then
/// `run_strict`.
pub(all) struct SpawnRemotePlan {
  spec : @types.SpawnSpec
  ok_response : @types.Response
}

///|
pub fn spawn_remote_plan(args : RemoteSpawnArgs) -> SpawnRemotePlan {
  let spec = @types.SpawnSpec::{
    slug: args.slug,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: args.task,
    task_contract: Some(args.task_contract),
    isolation: @types.IsolationMode::Worktree,
    parent_id: args.caller_id,
    parent_branch: args.parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    chainlink_issue_id: None,
  }
  let ok_response = @types.Response::ok_values({
    "status": String::to_json("spawned"),
    "agent_id": String::to_json(
      @workspace.branch_name(args.parent_branch, args.slug),
    ),
    "slug": String::to_json(args.slug),
    "host": String::to_json(args.ssh_target),
  })
  { spec, ok_response }
}

///|
/// Remote spawn path: plan, `remote_spawn_commands`, `run_strict`. Preserves
/// `ToolRequest::SpawnRemote` control flow while keeping `dispatch` thin.
pub async fn interpret_spawn_remote(
  spawn_args : RemoteSpawnArgs,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  extra_mcp_servers_json? : String? = None,
) -> @types.Response {
  let plan = spawn_remote_plan(spawn_args)
  let cmds = @workspace.remote_spawn_commands(
    plan.spec,
    spawn_args.ssh_target,
    spawn_args.repo_url,
    spawn_args.tcp_addr,
    parent_session_id=spawn_args.parent_session_id,
    extra_mcp_servers_json~,
  )
  match run_strict(runner, cmds, capture~) {
    Ok(_) => plan.ok_response
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
/// Pure plan for `spawn_gemini`: fixed Dev/Gemini worktree spec and success JSON
/// (`status`, `agent_id`, `slug`). The interpreter runs `spawn_commands` then
/// `run_strict`.
pub(all) struct SpawnGeminiPlan {
  spec : @types.SpawnSpec
  ok_response : @types.Response
}

///|
pub fn spawn_gemini_plan(args : SpawnGeminiArgs) -> SpawnGeminiPlan {
  let spec = @types.SpawnSpec::{
    slug: args.slug,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: args.task,
    task_contract: Some(args.task_contract),
    isolation: @types.IsolationMode::Worktree,
    parent_id: args.caller_id,
    parent_branch: args.parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
    automerge: None,
    chainlink_issue_id: None,
  }
  let ok_response = @types.Response::ok_values({
    "status": String::to_json("spawned"),
    "agent_id": String::to_json(
      @workspace.branch_name(args.parent_branch, args.slug),
    ),
    "slug": String::to_json(args.slug),
  })
  { spec, ok_response }
}

///|
/// Local Gemini leaf spawn: plan, `spawn_commands`, `run_strict`. Preserves
/// `ToolRequest::SpawnGemini` control flow while keeping `dispatch` thin.
pub async fn interpret_spawn_gemini(
  spawn_args : SpawnGeminiArgs,
  project_dir : String,
  session : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> @types.Response {
  let plan = spawn_gemini_plan(spawn_args)
  let cmds = @workspace.spawn_commands(
    plan.spec,
    project_dir,
    session,
    parent_session_id=spawn_args.parent_session_id,
    extra_mcp_servers_json~,
    shell_command~,
    listen_uds~,
    listen_tcp~,
    tcp_auth_token~,
  )
  match run_strict(runner, cmds, capture~) {
    Ok(_) => plan.ok_response
    Err(e) => @types.Response::Err(e.message())
  }
}

///|
/// Pure validation plus reuse [`SpawnSpec`] for `rescue_leaf` after the salvaged
/// agent is loaded from the registry. No I/O. Error strings match historical
/// `ToolRequest::RescueLeaf` dispatch behavior.
pub(all) struct RescueLeafSpawnPlan {
  from_agent_id : String
  to_id : String
  salvage_slug : String
  git_branch : String
  spec : @types.SpawnSpec
}

///|
/// Second `remove_child_from_supervisor_lifecycle` call uses `salvage_slug` when
/// it differs from the full salvaged agent id (matches inline dispatch).
pub fn rescue_leaf_remove_supervisor_alias(
  salvage_slug : String,
  from_agent_id : String,
) -> Bool {
  salvage_slug != from_agent_id
}

///|
pub fn rescue_leaf_spawn_plan(
  args : RescueLeafArgs,
  from_agent : @types.Agent,
) -> Result[RescueLeafSpawnPlan, @types.ChoirError] {
  let from_agent_id = args.from_agent_id
  if from_agent.role != @types.Role::Dev {
    return Err(
      @types.ChoirError::validation_error(
        "rescue_leaf only supports dev leaves",
      ),
    )
  }
  match from_agent.parent {
    Some(p) =>
      if p != args.caller_id {
        return Err(
          @types.ChoirError::validation_error(
            "caller_id must match the salvaged leaf parent",
          ),
        )
      }
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "salvaged leaf has no parent in registry",
        ),
      )
  }
  if !from_agent.workspace.contains(".choir/worktrees/") {
    return Err(
      @types.ChoirError::validation_error(
        "salvaged leaf has no choir worktree path to reuse",
      ),
    )
  }
  let parent_prefix = match @workspace.parent_branch(from_agent_id) {
    Some(pb) => pb
    None =>
      return Err(
        @types.ChoirError::validation_error(
          "invalid from_agent_id (expected nested branch like parent.child)",
        ),
      )
  }
  let to_id = @workspace.branch_name(parent_prefix, args.new_slug)
  let salvage_slug = @phase.extract_slug(from_agent_id)
  let git_branch = if from_agent.branch != "" {
    from_agent.branch
  } else {
    from_agent_id
  }
  let spec = @types.SpawnSpec::{
    slug: args.new_slug,
    role: @types.Role::Dev,
    agent_type: args.agent_type,
    task: args.task,
    task_contract: Some(args.task_contract),
    isolation: @types.IsolationMode::Worktree,
    parent_id: args.caller_id,
    parent_branch: parent_prefix,
    reuse_workspace: true,
    workspace_slug: Some(salvage_slug),
    reuse_git_branch: Some(git_branch),
    spawn_depth: 0,
    automerge: None,
    chainlink_issue_id: None,
  }
  match @workspace.validate_reuse_spawn_spec(spec) {
    Err(e) => Err(@types.ChoirError::validation_error(e))
    Ok(_) => Ok({ from_agent_id, to_id, salvage_slug, git_branch, spec })
  }
}

///|
pub fn rescue_leaf_ok_response(
  to_id : String,
  from_agent_id : String,
  new_slug : String,
) -> @types.Response {
  @types.Response::ok_values({
    "status": String::to_json("spawned"),
    "agent_id": String::to_json(to_id),
    "from_agent_id": String::to_json(from_agent_id),
    "slug": String::to_json(new_slug),
  })
}

///|
/// User-facing error when lifecycle handoff fails after spawn succeeded (matches
/// historical `ToolRequest::RescueLeaf` wording).
pub fn rescue_leaf_handoff_failure_message(detail : String) -> String {
  "rescue_leaf: replacement spawned but lifecycle handoff failed — manual repair may be needed: " +
  detail
}

///|
/// User-facing error when superseded lifecycle cannot be persisted (matches
/// historical dispatch wording).
pub fn rescue_leaf_superseded_persist_failure_message(
  from_agent_id : String,
) -> String {
  "failed to persist superseded lifecycle for " + from_agent_id
}

///|
/// Registry/poller guards, load salvaged agent, `rescue_leaf_spawn_plan`,
/// `spawn_commands`, `run_strict`, then the existing post-spawn interpreter.
/// Preserves historical `ToolRequest::RescueLeaf` ordering and error strings.
pub async fn interpret_rescue_leaf(
  rescue_args : RescueLeafArgs,
  project_dir : String,
  session : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  registry : @registry.AgentRegistry?,
  poller_state : @poller.PollerState?,
  extra_mcp_servers_json? : String? = None,
  shell_command? : String? = None,
  listen_uds? : String = ".choir/server.sock",
  listen_tcp? : String? = None,
  tcp_auth_token? : String? = None,
) -> @types.Response {
  let reg = match registry {
    Some(r) => r
    None =>
      return @types.Response::Err("agent registry unavailable for rescue_leaf")
  }
  let ps = match poller_state {
    Some(p) => p
    None => return @types.Response::Err("poller unavailable for rescue_leaf")
  }
  let from_agent = try reg.get(rescue_args.from_agent_id) catch {
    e => return tool_response_err_from_caught(e)
  } noraise {
    a => a
  }
  let plan = match rescue_leaf_spawn_plan(rescue_args, from_agent) {
    Err(e) => return @types.Response::Err(e.message())
    Ok(p) => p
  }
  let cmds = @workspace.spawn_commands(
    plan.spec,
    project_dir,
    session,
    parent_session_id=rescue_args.parent_session_id,
    extra_mcp_servers_json~,
    shell_command~,
    listen_uds~,
    listen_tcp~,
    tcp_auth_token~,
  )
  match run_strict(runner, cmds, capture~) {
    Err(e) => return @types.Response::Err(e.message())
    Ok(_) => ()
  }
  interpret_rescue_leaf_post_spawn(
    rescue_args, plan, project_dir, session, reg, ps, registry,
  )
}

///|
/// Ordered host-side steps for `rescue_leaf` after `run_strict` succeeds. The
/// interpreter runs this sequence; `SupervisorRemoveChildAliasIfNeeded` may
/// no-op when `rescue_leaf_remove_supervisor_alias` is false.
pub(all) enum RescueLeafPostSpawnHostStep {
  LifecycleHandoff
  PollerTransferOwnerAndWriteState
  MarkSuperseded
  RegistryRemoveOld
  SupervisorRemoveChildFromAgent
  SupervisorRemoveChildAliasIfNeeded
  TeamRegisterMember
  TlEventChildSpawned
  PaneResolveAndUpsertTerminal
} derive(Debug, Eq)

///|
pub fn rescue_leaf_post_spawn_host_steps() -> Array[RescueLeafPostSpawnHostStep] {
  [
    RescueLeafPostSpawnHostStep::LifecycleHandoff,
    RescueLeafPostSpawnHostStep::PollerTransferOwnerAndWriteState,
    RescueLeafPostSpawnHostStep::MarkSuperseded,
    RescueLeafPostSpawnHostStep::RegistryRemoveOld,
    RescueLeafPostSpawnHostStep::SupervisorRemoveChildFromAgent,
    RescueLeafPostSpawnHostStep::SupervisorRemoveChildAliasIfNeeded,
    RescueLeafPostSpawnHostStep::TeamRegisterMember,
    RescueLeafPostSpawnHostStep::TlEventChildSpawned,
    RescueLeafPostSpawnHostStep::PaneResolveAndUpsertTerminal,
  ]
}

///|
/// Post-spawn effect sequence for `rescue_leaf` after `run_strict` succeeds:
/// lifecycle handoff, poller transfer/write, superseded mark, registry remove,
/// supervisor cleanup, team registration, TL event, pane resolution/upsert, and
/// success response. Preserves exact ordering and error behavior of the prior
/// inline `dispatch` arm.
pub async fn interpret_rescue_leaf_post_spawn(
  rescue_args : RescueLeafArgs,
  plan : RescueLeafSpawnPlan,
  project_dir : String,
  session : String,
  reg : @registry.AgentRegistry,
  ps : @poller.PollerState,
  registry : @registry.AgentRegistry?,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> @types.Response {
  match
    @phase.handoff_dev_workflow_to_new_agent(
      project_dir,
      plan.from_agent_id,
      plan.to_id,
      @types.Role::Dev,
    ) {
    Err(e) =>
      return @types.Response::Err(
        rescue_leaf_handoff_failure_message(e.validation_detail_or_message()),
      )
    Ok(_) => ()
  }
  ignore(ps.transfer_owner(plan.from_agent_id, plan.to_id, plan.git_branch, ""))
  ignore(ps.write_state_file(project_dir))
  if !@phase.mark_agent_rescued_superseded(
      project_dir,
      plan.from_agent_id,
      @types.Role::Dev,
    ) {
    return @types.Response::Err(
      rescue_leaf_superseded_persist_failure_message(plan.from_agent_id),
    )
  }
  try reg.remove(plan.from_agent_id) catch {
    e => return tool_response_err_from_caught(e)
  } noraise {
    _ => ()
  }
  @phase.remove_child_from_supervisor_lifecycle(
    project_dir,
    rescue_args.caller_id,
    plan.from_agent_id,
  )
  if rescue_leaf_remove_supervisor_alias(plan.salvage_slug, plan.from_agent_id) {
    @phase.remove_child_from_supervisor_lifecycle(
      project_dir,
      rescue_args.caller_id,
      plan.salvage_slug,
    )
  }
  let _ = @workspace.register_team_member(
    rescue_args.caller_id,
    rescue_args.new_slug,
    @config.agent_type_to_string(rescue_args.agent_type),
  )
  let rescue_tl_effects = @phase.plan_tl_event_for_scope(
    project_dir,
    rescue_args.caller_id,
    @phase.TLEvent::ChildSpawned(child_id=rescue_args.new_slug),
    registry~,
  )
  @phase.interpret_lifecycle_effects(project_dir, rescue_tl_effects, registry~)
  let resolved_pane_ids : Array[(String, String)] = []
  match resolve_zellij_pane_id(session, rescue_args.new_slug, capture~) {
    Some(pane_id) => resolved_pane_ids.push((plan.to_id, pane_id))
    None => ()
  }
  match registry {
    Some(r2) =>
      for pair in resolved_pane_ids {
        let (agent_id, pane_id) = pair
        try {
          let agent = r2.get(agent_id)
          let target = @workspace.zellij_pane_target(session, pane_id)
          ignore(r2.upsert({ ..agent, terminal_target: Some(target) }))
        } catch {
          _ => ()
        }
      }
    None => ()
  }
  rescue_leaf_ok_response(plan.to_id, plan.from_agent_id, rescue_args.new_slug)
}

///|
pub impl Show for FilePrAutoNotifyPlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for NotifyParentPlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SendMessagePlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SpawnWorkerPlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SpawnRemotePlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SpawnGeminiPlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for RescueLeafSpawnPlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for FilePrPreflightHostStep with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ForkWavePostSpawnHostStep with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for MergePrPreflightHostStep with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for MergePrHostStep with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for KillAgentAdapterHostStep with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for ShutdownAdapterHostStep with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for CancelWavePerAgentHostStep with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for RescueLeafPostSpawnHostStep with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

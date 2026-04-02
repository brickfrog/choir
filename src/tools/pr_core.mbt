///|
pub(all) struct FilePrPlanResult {
  response : @types.Response
  tracked_pr : @poller.TrackedPR?
  dev_event : @phase.DevEvent
  notify_message : String
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
      last_ci_failed: false,
      last_timeout_at: 0L,
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
  { response, tracked_pr, dev_event, notify_message }
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
} derive(Show, Eq)

///|
pub fn file_pr_auto_notify_plan(
  parent_result : Result[@types.Agent, @types.ChoirError],
  tracked_agent_id : String,
  notify_message : String,
) -> FilePrAutoNotifyPlan {
  match parent_result {
    Ok(parent) => {
      let delivery = @message.plan_delivery(
        parent, tracked_agent_id, notify_message, "success",
      )
      let delivery_log_append = "[auto-notify] caller=" +
        tracked_agent_id +
        " parent=" +
        parent.agent_id.to_string() +
        " delivery=" +
        delivery.to_string() +
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
} derive(Show)

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
  delivery.to_string() +
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
} derive(Show)

///|
pub fn send_message_plan(
  target_id : String,
  sender_id : String,
  message : String,
  status : String,
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
          @moontrace.error(
            "send_message delivery failed",
            fields=@moontrace.fields([("error", e.to_json())]),
          )
          @types.Response::Err(e)
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
/// Ordered host steps for `file_pr` before post-success effects. The
/// interpreter runs this exact sequence; kept as data for tests and docs.
pub(all) enum FilePrPreflightHostStep {
  EnsureBranchReady
  GitPush
  EnsurePullRequest
} derive(Eq, Show)

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
  ensure_branch_ready : async (String, String, String) -> Result[Unit, String],
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  ensure_pr : async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    String,
  ],
) -> Result[PullRequestInfo, String] {
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
/// Ordered host-side steps for `merge_pr` preflight when `force` is false
/// (poller read is synchronous; thread fetch uses `capture`). Matches
/// `interpret_merge_pr_preflight`.
pub(all) enum MergePrPreflightHostStep {
  PollerSnapshot
  FetchUnresolvedReviewThreads
} derive(Eq, Show)

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
) -> Result[Unit, String] {
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
  match
    merge_pr_preflight_block_message(
      pr_number, poller_tracked, thread_count, thread_text,
    ) {
    Some(msg) => Err(msg)
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
} derive(Eq, Show)

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
) -> Result[Unit, String] {
  let mutex_name = merge_pr_mutex_name(parent_branch)
  match mutex_registry {
    Some(reg) => {
      let (acquired, _) = reg.acquire(
        mutex_name, caller_id, merge_pr_mutex_ttl_sec, now_sec,
      )
      if !acquired {
        ignore(reg.release(mutex_name, caller_id))
        return Err(merge_pr_serialization_busy_message())
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
      Err(merge_pr_merge_failure_message(pr_number, trimmed))
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
  @phase.apply_tl_event(project_dir, caller_id, plan.tl_event, registry~)
  if plan.poller_untrack_and_write_state {
    match poller_state {
      Some(ps) => {
        ps.untrack(pr_number)
        ignore(ps.write_state_file(project_dir))
      }
      None => ()
    }
  }
  plan.response
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
} derive(Eq, Show)

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
) -> @types.Response {
  match registry {
    None => @types.Response::Err("no agent registry available")
    Some(reg) =>
      match reg.get(args.agent_id) {
        Ok(agent) => {
          match kill_agent_pane_close_command(agent) {
            Some(cmd) => {
              let _ = runner([cmd])
              ()
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
          let _ = reg.set_state(args.agent_id, @types.AgentState::Failed)
          @moontrace.warn(
            "agent killed",
            fields=@moontrace.fields([
              ("agent_id", args.agent_id.to_json()),
              ("reason", args.reason.to_json()),
            ]),
          )
          kill_agent_ok_response(args.agent_id)
        }
        Err(_) => @types.Response::Err("agent not found: " + args.agent_id)
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
} derive(Eq, Show)

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
    Some(reg) =>
      match reg.get(caller_id) {
        Ok(agent) => agent.role
        Err(_) => @types.Role::Dev
      }
    None => @types.Role::Dev
  }
}

///|
/// Effectful shutdown adapter: poller gate, lifecycle + `shutdown_exit_plan`,
/// dev exit event, worktree cleanup. Preserves the historical `ToolRequest::Shutdown`
/// control flow while keeping `dispatch` as a thin caller.
pub async fn interpret_shutdown(
  args : ShutdownArgs,
  project_dir : String,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
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
      @phase.apply_dev_event_checked(
        project_dir,
        caller_id,
        @phase.DevEvent::ExitRequested,
      ),
    )
  }
  if plan.attempt_worktree_cleanup {
    match registry {
      Some(reg) =>
        match reg.get(caller_id) {
          Ok(agent) =>
            if shutdown_intent_remove_choir_worktree(agent.workspace) {
              let _ = runner([@workspace.git_worktree_remove(agent.workspace)])
              ()
            }
          Err(_) => ()
        }
      None => ()
    }
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
} derive(Eq, Show)

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
} derive(Show)

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
    isolation: @types.IsolationMode::Inline,
    parent_id: worker_args.caller_id,
    parent_branch: resolved_parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
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
    Err(e) => @types.Response::Err(e)
  }
}

///|
/// Pure plan for `spawn_remote`: fixed Dev/Claude worktree spec and success JSON
/// (agent id, slug, ssh host). The interpreter runs `remote_spawn_commands` then
/// `run_strict`.
pub(all) struct SpawnRemotePlan {
  spec : @types.SpawnSpec
  ok_response : @types.Response
} derive(Show)

///|
pub fn spawn_remote_plan(args : RemoteSpawnArgs) -> SpawnRemotePlan {
  let spec = @types.SpawnSpec::{
    slug: args.slug,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Claude,
    task: args.task,
    isolation: @types.IsolationMode::Worktree,
    parent_id: args.caller_id,
    parent_branch: args.parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
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
    Err(e) => @types.Response::Err(e)
  }
}

///|
/// Pure plan for `spawn_gemini`: fixed Dev/Gemini worktree spec and success JSON
/// (`status`, `agent_id`, `slug`). The interpreter runs `spawn_commands` then
/// `run_strict`.
pub(all) struct SpawnGeminiPlan {
  spec : @types.SpawnSpec
  ok_response : @types.Response
} derive(Show)

///|
pub fn spawn_gemini_plan(args : SpawnGeminiArgs) -> SpawnGeminiPlan {
  let spec = @types.SpawnSpec::{
    slug: args.slug,
    role: @types.Role::Dev,
    agent_type: @types.AgentType::Gemini,
    task: args.task,
    isolation: @types.IsolationMode::Worktree,
    parent_id: args.caller_id,
    parent_branch: args.parent_branch,
    reuse_workspace: false,
    workspace_slug: None,
    reuse_git_branch: None,
    spawn_depth: 0,
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
    Err(e) => @types.Response::Err(e)
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
} derive(Show)

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
) -> Result[RescueLeafSpawnPlan, String] {
  let from_agent_id = args.from_agent_id
  if from_agent.role != @types.Role::Dev {
    return Err("rescue_leaf only supports dev leaves")
  }
  match from_agent.parent {
    Some(p) =>
      if p != args.caller_id {
        return Err("caller_id must match the salvaged leaf parent")
      }
    None => return Err("salvaged leaf has no parent in registry")
  }
  if !from_agent.workspace.contains(".choir/worktrees/") {
    return Err("salvaged leaf has no choir worktree path to reuse")
  }
  let parent_prefix = match @workspace.parent_branch(from_agent_id) {
    Some(pb) => pb
    None =>
      return Err(
        "invalid from_agent_id (expected nested branch like parent.child)",
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
    isolation: @types.IsolationMode::Worktree,
    parent_id: args.caller_id,
    parent_branch: parent_prefix,
    reuse_workspace: true,
    workspace_slug: Some(salvage_slug),
    reuse_git_branch: Some(git_branch),
    spawn_depth: 0,
  }
  match @workspace.validate_reuse_spawn_spec(spec) {
    Err(e) => Err(e)
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
  let from_agent = match reg.get(rescue_args.from_agent_id) {
    Ok(a) => a
    Err(e) => return @types.Response::Err(e.message())
  }
  let plan = match rescue_leaf_spawn_plan(rescue_args, from_agent) {
    Err(e) => return @types.Response::Err(e)
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
    Err(e) => return @types.Response::Err(e)
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
} derive(Eq, Show)

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
      return @types.Response::Err(rescue_leaf_handoff_failure_message(e))
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
  match reg.remove(plan.from_agent_id) {
    Ok(_) => ()
    Err(e) => return @types.Response::Err(e.message())
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
  @phase.apply_tl_event(
    project_dir,
    rescue_args.caller_id,
    @phase.TLEvent::ChildSpawned(child_id=rescue_args.new_slug),
    registry~,
  )
  let resolved_pane_ids : Array[(String, String)] = []
  match resolve_zellij_pane_id(session, rescue_args.new_slug, capture~) {
    Some(pane_id) => resolved_pane_ids.push((plan.to_id, pane_id))
    None => ()
  }
  match registry {
    Some(r2) =>
      for pair in resolved_pane_ids {
        let (agent_id, pane_id) = pair
        match r2.get(agent_id) {
          Ok(agent) => {
            let target = @workspace.zellij_pane_target(session, pane_id)
            ignore(r2.upsert({ ..agent, terminal_target: Some(target) }))
          }
          Err(_) => ()
        }
      }
    None => ()
  }
  rescue_leaf_ok_response(plan.to_id, plan.from_agent_id, rescue_args.new_slug)
}

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
/// Pure predicate: workspace path qualifies for choir-managed worktree removal.
/// This accepts only managed leaf/review worktree paths, never the project root.
pub fn shutdown_intent_remove_choir_worktree(workspace : String) -> Bool {
  @types.is_choir_managed_worktree_path(".", workspace)
}

///|
pub fn shutdown_safe_choir_worktree_path(
  project_dir : String,
  workspace : String,
) -> Bool {
  @types.is_choir_managed_worktree_path(project_dir, workspace)
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
  project_dir? : String = ".",
) -> @workspace.Command? {
  if shutdown_safe_choir_worktree_path(project_dir, agent.workspace) {
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
/// remove attempt, then the owned process-group kill (recorded pgid from
/// `.choir/run/pids/<sanitized-agent-id>`), then pidfile removal. Pane close and
/// worktree remove may be skipped when the corresponding input is absent;
/// pgroup kill and pidfile removal are skipped when no pidfile exists.
pub(all) enum KillAgentAdapterHostStep {
  PaneClose
  WorktreeRemove
  PgroupKill
  PidFileRemove
} derive(Debug, Eq)

///|
pub impl Show for KillAgentAdapterHostStep with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn kill_agent_adapter_host_steps() -> Array[KillAgentAdapterHostStep] {
  [
    KillAgentAdapterHostStep::PaneClose,
    KillAgentAdapterHostStep::WorktreeRemove,
    KillAgentAdapterHostStep::PgroupKill,
    KillAgentAdapterHostStep::PidFileRemove,
  ]
}

///|
/// Success JSON for `kill_agent` when the target was a queued pending wave id
/// (no agent process to terminate; just the KV entry to clean up).
pub fn kill_pending_wave_ok_response(wave_id : String) -> @types.Response {
  @types.Response::ok_values({
    "status": String::to_json("killed_pending_wave"),
    "wave_id": String::to_json(wave_id),
  })
}

///|
fn kill_agent_target_agent(
  agent : @types.Agent,
  project_dir : String,
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
/// Effectful `kill_agent` adapter: optional pane close, optional worktree remove,
/// owned process-group kill + pidfile removal, registry failed state, warning
/// log, success response. Preserves historical `ToolRequest::KillAgent` control
/// flow while keeping `dispatch` as a thin caller.
///
/// Pending-wave handling (Feature 1):
/// 1. If `args.agent_id` matches a `pending-wave--<id>` KV entry, delete it
///    and return `killed_pending_wave` without touching the registry.
/// 2. Otherwise, propagate failure to every pending wave that names this
///    `agent_id` as a dep before continuing with the normal kill sequence.
pub async fn interpret_kill_agent(
  args : KillAgentArgs,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  project_dir? : String = ".",
  // Dispatch injects the production Beads capture; the interpreter default
  // keeps direct adapter tests hermetic when a local config names a bead.
  capture? : async (@workspace.Command) -> (Int, String) = async fn(_) {
    @async.sleep(0)
    (0, "")
  },
  read_agent_pgid? : (String) -> Int? = fn(agent_id) {
    @workspace.parse_agent_pgid(
      @sys.read_file(@workspace.agent_pid_file_path(project_dir, agent_id)),
    )
  },
  // Dispatch supplies production host effects; direct interpreter tests stay pure.
  kill_pgid? : (Int) -> Unit = fn(_) { () },
  remove_pid_file? : (String) -> Unit = fn(_) { () },
  read_lifecycle? : (String, String) -> @phase.AgentLifecycle? = @phase.read_lifecycle,
) -> @types.Response {
  // File existence is the source of truth for "is this id a pending wave"
  // — delete the entry whether or not its JSON parses. A partial/corrupt
  // file would otherwise fall through to the registry-kill path and orphan
  // the pending KV row (statusline would keep counting it as queued).
  let pending_path = pending_wave_kv_path(project_dir, args.agent_id)
  if @sys.path_entry_exists(pending_path) {
    let parsed_ok = read_pending_wave(project_dir, args.agent_id) is Some(_)
    delete_pending_wave(project_dir, args.agent_id)
    @moontrace.warn("pending wave killed", fields=[
      @moontrace.field("wave_id", args.agent_id),
      @moontrace.field("reason", args.reason),
      @moontrace.field("parseable", parsed_ok),
    ])
    return kill_pending_wave_ok_response(args.agent_id)
  }
  match registry {
    None => @types.Response::Err("no agent registry available")
    Some(reg) => {
      let agent = reg.get(args.agent_id) catch {
        _ => return @types.Response::Err("agent not found: " + args.agent_id)
      }
      let target_agent = kill_agent_target_agent(
        agent, project_dir, read_lifecycle,
      )
      let guard_role = target_agent.role
      // Role::Dev and Role::Worker are always killable; only TL is refused.
      // The persisted lifecycle role can correct a stale registry refresh that
      // accidentally wrote supervisor metadata onto an existing leaf row.
      if @types.is_supervisor_role(guard_role) {
        @moontrace.warn("kill_agent refused: target is supervisor", fields=[
          @moontrace.field("agent_id", args.agent_id),
          @moontrace.field("role", guard_role.to_wire_string()),
          @moontrace.field("registry_role", agent.role.to_wire_string()),
        ])
        return @types.Response::Err("kill_agent refused: target is supervisor")
      }
      for pw in pending_waves_naming_dep(project_dir, args.agent_id) {
        mark_pending_wave_failed(
          project_dir,
          registry,
          runner,
          pw,
          args.agent_id,
        )
      }
      let mut pane_close_failed = false
      match kill_agent_pane_close_command(target_agent) {
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
      match kill_agent_worktree_remove_command(target_agent, project_dir~) {
        Some(cmd) => {
          let _ = runner([cmd])
          ()
        }
        None => ()
      }
      // Owned-handle kill: the spawn wrapper records the setsid process-group
      // id in `.choir/run/pids/<sanitized-agent-id>` (launch.mbt), so signaling
      // that group covers the whole agent tree — including the mcp-stdio shim,
      // which additionally sets PR_SET_PDEATHSIG. Agents without a pidfile
      // (bare `register` joins, never spawned by us) own no process we may
      // kill; the response warning records that below.
      let killed_pgid = read_agent_pgid(args.agent_id)
      match killed_pgid {
        Some(pgid) => {
          kill_pgid(pgid)
          remove_pid_file(args.agent_id)
        }
        None => ()
      }
      @moontrace.warn("kill_agent pgroup kill", fields=[
        @moontrace.field("agent_id", args.agent_id),
        @moontrace.field("pgid", killed_pgid.unwrap_or(0)),
      ])
      ignore(reg.set_state(args.agent_id, @types.AgentState::Failed)) catch {
        _ => ()
      }
      ignore(
        mirror_beads_state_for_agent(
          project_dir,
          registry,
          args.agent_id,
          "lifecycle",
          "killed",
          "Choir kill_agent: " + args.reason,
          "kill_agent",
          capture,
        ),
      )
      @moontrace.warn("agent killed", fields=[
        @moontrace.field("agent_id", args.agent_id),
        @moontrace.field("reason", args.reason),
      ])
      let response = kill_agent_ok_response(args.agent_id)
      if pane_close_failed {
        let warning = match killed_pgid {
          Some(_) =>
            "pane close failed — zellij tab/pane may still linger, but the agent process group was killed"
          None =>
            "pane close failed — no process handle found; the agent process may survive"
        }
        response.with_warning(warning)
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
fn shutdown_exit_requested_deferred_releasable(
  lifecycle : @phase.AgentLifecycle,
  poller_state : @poller.PollerState?,
) -> Bool {
  let has_merge_receipt = fn(pr_number : Int) -> Bool {
    match poller_state {
      Some(ps) => ps.merged_observed(pr_number)
      None => false
    }
  }
  match lifecycle.workflow {
    @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(pr_number~, state~)
    ) =>
      match state {
        @phase.ReviewOwnership::OpenUnreviewed(..) =>
          has_merge_receipt(pr_number)
        @phase.ReviewOwnership::FixesAwaitingReview(..) =>
          has_merge_receipt(pr_number)
        @phase.ReviewOwnership::ApprovedAwaitingMerge => true
      }
    _ => false
  }
}

///|
pub fn shutdown_exit_plan(
  lifecycle : @phase.AgentLifecycle,
  poller_state? : @poller.PollerState? = None,
) -> ShutdownExitPlan {
  let dev_may_request_exit = match lifecycle.workflow {
    @phase.WorkflowState::Dev(_) => true
    _ => false
  }
  if shutdown_exit_requested_deferred_releasable(lifecycle, poller_state) {
    return ShutdownExitPlan::{
      response: @types.Response::ok_values({
        "status": String::to_json("shutdown"),
      }),
      apply_dev_exit_requested: false,
      attempt_worktree_cleanup: true,
    }
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
/// Adapter-side ordering for `shutdown`: pane close first, then poller gate,
/// registry role, lifecycle read, optional dev exit event, optional worktree
/// removal, and Beads mirror (matches dispatch).
pub(all) enum ShutdownAdapterHostStep {
  PaneClose
  PollerCriticalPhaseRead
  RegistryRoleLookup
  LifecycleRead
  DevExitEventApply
  WorktreeCleanupAttempt
  BeadsLifecycleMirror
} derive(Debug, Eq)

///|
pub impl Show for ShutdownAdapterHostStep with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn shutdown_adapter_host_steps() -> Array[ShutdownAdapterHostStep] {
  [
    ShutdownAdapterHostStep::PaneClose,
    ShutdownAdapterHostStep::PollerCriticalPhaseRead,
    ShutdownAdapterHostStep::RegistryRoleLookup,
    ShutdownAdapterHostStep::LifecycleRead,
    ShutdownAdapterHostStep::DevExitEventApply,
    ShutdownAdapterHostStep::WorktreeCleanupAttempt,
    ShutdownAdapterHostStep::BeadsLifecycleMirror,
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
/// Effectful shutdown adapter: pane close first, then poller gate, lifecycle +
/// `shutdown_exit_plan`, dev exit event, worktree cleanup, Beads lifecycle
/// mirror.
pub async fn interpret_shutdown(
  args : ShutdownArgs,
  project_dir : String,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout_with_stderr_on_error,
) -> @types.Response {
  let caller_id = match args.caller_id {
    Some(v) => v
    None => return shutdown_missing_caller_response()
  }
  match registry {
    Some(reg) =>
      try {
        let agent = reg.get(caller_id)
        if !@types.is_supervisor_role(agent.role) {
          match kill_agent_pane_close_command(agent) {
            Some(cmd) => {
              let codes = runner([cmd]) catch { _ => [-1] }
              if codes.length() > 0 && codes[0] != 0 {
                @moontrace.trace("shutdown pane close failed", fields=[
                  @moontrace.field("agent_id", caller_id),
                  @moontrace.field("exit", codes[0]),
                ])
              }
            }
            None => ()
          }
        }
      } catch {
        _ => ()
      }
    None => ()
  }
  match shutdown_poller_block_pr_number(poller_state, caller_id) {
    Some(pr_number) =>
      return @types.Response::Err(shutdown_poller_block_message(pr_number))
    None => ()
  }
  let role = shutdown_registry_role_for_caller(registry, caller_id)
  let lifecycle = @phase.read_or_default_lifecycle(project_dir, caller_id, role)
  let plan = shutdown_exit_plan(lifecycle, poller_state~)

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
  let may_cleanup_workspace = plan.attempt_worktree_cleanup &&
    !@types.is_supervisor_role(role)
  if may_cleanup_workspace {
    match registry {
      Some(reg) =>
        try {
          let agent = reg.get(caller_id)
          if shutdown_safe_choir_worktree_path(project_dir, agent.workspace) {
            let _ = runner([@workspace.git_worktree_remove(agent.workspace)])
            ()
          }
        } catch {
          _ => ()
        }
      None => ()
    }
  }
  if may_cleanup_workspace {
    ignore(
      mirror_beads_state_for_agent(
        project_dir, registry, caller_id, "lifecycle", "shutdown", "Choir agent shutdown",
        "shutdown", capture,
      ),
    )
  }
  plan.response
}

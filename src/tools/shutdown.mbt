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
pub impl Show for KillAgentAdapterHostStep with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

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
pub impl Show for ShutdownAdapterHostStep with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

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

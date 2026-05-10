///|
/// Register a pane for idle watchdog monitoring.
/// Starts a `zellij subscribe` process that streams pane viewport updates
/// to a snapshot file, replacing the old dump-screen polling approach.
pub fn ServerState::watch_pane(self : ServerState, agent_id : String) -> Unit {
  let agent = self.registry.get(agent_id) catch { _ => return }
  let target = match agent.terminal_target {
    Some(t) => t
    None => return
  }
  self.pane_watcher.watch_pane(agent_id, target, @poller.now_sec())
}

///|
/// Stop the zellij subscribe process for an agent and clean up state.
fn ServerState::stop_subscribe(self : ServerState, agent_id : String) -> Unit {
  self.pane_watcher.stop_subscribe(agent_id)
}

///|
fn ServerState::current_lifecycle(
  self : ServerState,
  agent_id : String,
) -> @phase.AgentLifecycle {
  try self.registry.get(agent_id) catch {
    _ =>
      match @phase.read_lifecycle(self.config.project_dir, agent_id) {
        Some(lifecycle) => lifecycle
        None => @phase.lifecycle_for_role(agent_id, @types.Role::Dev)
      }
  } noraise {
    agent =>
      @phase.read_or_default_lifecycle(
        self.config.project_dir,
        agent_id,
        agent.role,
      )
  }
}

///|
pub fn ServerState::transfer_leaf_ownership(
  self : ServerState,
  from_agent_id : String,
  to_agent_id : String,
) -> Int raise @types.ChoirError {
  if from_agent_id == to_agent_id {
    return 0
  }
  let from_agent = self.registry.get(from_agent_id)
  let to_agent = self.registry.get(to_agent_id)
  if from_agent.parent != to_agent.parent {
    raise @types.ChoirError::validation_error(
      "cannot transfer ownership across different parents",
    )
  }
  if from_agent.role != to_agent.role {
    raise @types.ChoirError::validation_error(
      "cannot transfer ownership across different roles",
    )
  }
  match from_agent.role {
    @types.Role::Dev | @types.Role::Worker => ()
    _ =>
      raise @types.ChoirError::validation_error(
        "ownership transfer only supports leaf roles",
      )
  }
  let transferred = self.poller.transfer_owner(
    from_agent_id,
    to_agent_id,
    to_agent.branch,
    @workspace.parent_branch(to_agent.branch).unwrap_or(""),
  )
  let from_lifecycle = self.current_lifecycle(from_agent_id)
  let to_lifecycle = self.current_lifecycle(to_agent_id)
  let workflow = match (from_lifecycle.workflow, to_lifecycle.workflow) {
    (@phase.WorkflowState::Dev(from_dev), @phase.WorkflowState::Dev(_)) =>
      @phase.WorkflowState::Dev(from_dev)
    (@phase.WorkflowState::Worker(from_worker), @phase.WorkflowState::Worker(_)) =>
      @phase.WorkflowState::Worker(from_worker)
    _ => to_lifecycle.workflow
  }
  let carried_lifecycle = {
    ..to_lifecycle,
    agent_id: to_agent_id,
    role: to_agent.role,
    workflow,
  }
  ignore(
    @phase.persist_lifecycle(
      self.config.project_dir,
      self.registry,
      carried_lifecycle,
    ),
  )
  @phase.sync_parent_child_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    to_agent_id,
    carried_lifecycle,
  )
  @phase.remove_parent_child_lifecycle(
    self.config.project_dir,
    self.registry,
    from_agent_id,
  )
  transferred
}

///|
fn ServerState::clear_agent_runtime_tracking(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.stop_subscribe(agent_id)
  self.pending_disconnects.remove(agent_id)
}

///|
pub let disconnect_auto_rescue_review_grace_sec : Int64 = 300L

///|
pub let disconnect_auto_rescue_slug_prefix : String = "auto-rescue-pr-"

///|
pub(all) struct DisconnectAutoRescuePlan {
  pr_number : Int
  new_slug : String
  task : String
  agent_type : @types.AgentType
} derive(Debug, Eq)

///|
pub(all) enum DisconnectAutoRescueDecision {
  Rescue(plan~ : DisconnectAutoRescuePlan)
  NoRescue
} derive(Debug, Eq)

///|
fn disconnect_auto_rescue_pr_number(lifecycle : @phase.AgentLifecycle) -> Int? {
  match lifecycle.workflow {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ReviewOwned(pr_number~, ..))
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number~, ..)
    )
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(pr_number~, ..)
    ) => Some(pr_number)
    _ => None
  }
}

///|
fn disconnect_auto_rescue_agent_type(
  agent_type : @types.AgentType,
) -> @types.AgentType {
  match agent_type {
    @types.AgentType::Unknown => @types.AgentType::CursorAgent
    other => other
  }
}

///|
fn disconnect_auto_rescue_task(pr_number : Int) -> String {
  "PR " +
  pr_number.to_string() +
  ": address Copilot review threads then notify_parent"
}

///|
pub fn disconnect_auto_rescue_decision(
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  tracked : @poller.TrackedPR?,
  unresolved_thread_count : Int,
  now : Int64,
) -> DisconnectAutoRescueDecision {
  if agent.role != @types.Role::Dev {
    return NoRescue
  }
  let agent_id = agent.agent_id.to_string()
  if @phase.extract_slug(agent_id).has_prefix(
      disconnect_auto_rescue_slug_prefix,
    ) {
    return NoRescue
  }
  let pr_number = match disconnect_auto_rescue_pr_number(lifecycle) {
    Some(n) => n
    None => return NoRescue
  }
  let tracked = match tracked {
    Some(t) if t.agent_id == agent_id && t.pr_number == pr_number => t
    _ => return NoRescue
  }
  let copilot_review_still_pending = !tracked.copilot_issue_comment_seen &&
    now - tracked.first_seen < disconnect_auto_rescue_review_grace_sec
  if unresolved_thread_count <= 0 && !copilot_review_still_pending {
    return NoRescue
  }
  let new_slug = disconnect_auto_rescue_slug_prefix + pr_number.to_string()
  Rescue(plan={
    pr_number,
    new_slug,
    task: disconnect_auto_rescue_task(pr_number),
    agent_type: disconnect_auto_rescue_agent_type(agent.agent_type),
  })
}

///|
fn disconnect_auto_rescue_args(
  plan : DisconnectAutoRescuePlan,
  caller_id : String,
  from_agent_id : String,
) -> @tools.RescueLeafArgs {
  {
    task: plan.task,
    task_contract: { ..@types.TaskContract::empty(), goal: plan.task },
    caller_id,
    from_agent_id,
    new_slug: plan.new_slug,
    agent_type: plan.agent_type,
    parent_session_id: None,
  }
}

///|
async fn ServerState::auto_rescue_disconnected_review_leaf(
  self : ServerState,
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  let pr_number = match disconnect_auto_rescue_pr_number(lifecycle) {
    Some(n) => n
    None => return false
  }
  let tracked = self.poller.get(pr_number)
  let (thread_count, _) = @tools.fetch_unresolved_review_threads(
    pr_number,
    self.config.project_dir,
    capture,
  )
  let decision = disconnect_auto_rescue_decision(
    agent,
    lifecycle,
    tracked,
    thread_count,
    @poller.now_sec(),
  )
  match decision {
    NoRescue => false
    Rescue(plan~) => {
      let from_agent_id = agent.agent_id.to_string()
      let caller_id = match agent.parent {
        Some(parent_id) => parent_id
        None => return false
      }
      let resp = @tools.interpret_rescue_leaf(
        disconnect_auto_rescue_args(plan, caller_id, from_agent_id),
        self.config.project_dir,
        self.config.terminal_session,
        runner,
        capture,
        Some(self.registry),
        Some(self.poller),
        extra_mcp_servers_json=self.config.extra_mcp_servers_json,
        shell_command=self.config.shell_command,
        listen_uds=self.config.listen_uds,
        listen_tcp=self.config.listen_tcp,
        tcp_auth_token=self.config.tcp_auth_token,
      )
      if resp.is_ok() {
        self.clear_agent_runtime_tracking(from_agent_id)
        match resp.ok_field("agent_id") {
          Some(new_agent_id) => self.watch_pane(new_agent_id)
          None => ()
        }
        true
      } else {
        @moontrace.warn("auto rescue failed", fields=[
          @moontrace.field("agent_id", from_agent_id),
          @moontrace.field("pr_number", pr_number),
          @moontrace.field(
            "error",
            resp.error_message().unwrap_or("unknown error"),
          ),
        ])
        false
      }
    }
  }
}

///|
async fn ServerState::reconcile_external_merge_with_runner(
  self : ServerState,
  agent_id : String,
  pr_number : Int,
  branch : String,
  parent_branch : String,
  pr_url : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  notify_parent? : Bool = true,
) -> Unit {
  let agent = try self.registry.get(agent_id) catch {
    _ =>
      @phase.resolve_agent_with_fallback(
        self.config.project_dir,
        self.config.terminal_session,
        self.registry,
        agent_id,
      )
  } noraise {
    resolved => resolved
  }
  let lifecycle = self.current_lifecycle(agent_id)
  let effects = plan_external_merge_finalization(
    agent,
    lifecycle,
    pr_number,
    branch,
    parent_branch,
    pr_url,
    notify_parent~,
  )
  self.interpret_teardown_effects(effects, runner)
}

///|
async fn ServerState::finalize_agent_with_runner(
  self : ServerState,
  agent_id : String,
  exit_reason : @types.ExitReason,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  notify_parent? : Bool = false,
  close_target? : Bool = true,
  remove_worktree? : Bool = true,
) -> Unit {
  try self.registry.get(agent_id) catch {
    _ => self.clear_agent_runtime_tracking(agent_id)
  } noraise {
    agent => {
      let lifecycle = self.current_lifecycle(agent_id)
      let effects = plan_finalize(
        agent,
        lifecycle,
        exit_reason,
        notify_parent~,
        close_target~,
        remove_worktree~,
      )
      self.interpret_teardown_effects(effects, runner)
    }
  }
}

///|
pub async fn ServerState::fail_agent_with_runner(
  self : ServerState,
  agent_id : String,
  reason : @phase.FailureReason,
  parent_message : String,
  exit_reason : @types.ExitReason,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  close_target? : Bool = false,
) -> Unit {
  @async.sleep(0)
  try self.registry.get(agent_id) catch {
    _ => self.clear_agent_runtime_tracking(agent_id)
  } noraise {
    agent => {
      let lifecycle = self.current_lifecycle(agent_id)
      let parent = match agent.parent {
        Some(pid) =>
          try self.resolve_parent_by_id(pid) catch {
            _ => None
          } noraise {
            p => Some(p)
          }
        None => None
      }
      let effects = plan_fail(
        agent,
        lifecycle,
        reason,
        parent_message,
        exit_reason,
        parent,
        close_target~,
      )
      self.interpret_teardown_effects(effects, runner)
    }
  }
}

///|
pub async fn ServerState::interpret_teardown_effects(
  self : ServerState,
  effects : Array[TeardownEffect],
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  for effect in effects {
    match effect {
      PersistLifecycle(agent_id~, lifecycle~, trigger~) => {
        let prev = self.current_lifecycle(agent_id)
        if @phase.persist_lifecycle(
            self.config.project_dir,
            self.registry,
            lifecycle,
          ) {
          ignore(
            append_lifecycle_event(
              self.config.project_dir,
              agent_id,
              prev,
              lifecycle,
              trigger,
            ),
          )
        }
      }
      SyncParentLifecycle(agent_id~, lifecycle~) =>
        @phase.sync_parent_child_lifecycle(
          self.config.project_dir,
          self.config.terminal_session,
          self.registry,
          agent_id,
          lifecycle,
        )
      NotifyParent(parent_id~, agent_id~, message~, status~) =>
        try {
          let parent = self.resolve_parent_by_id(parent_id)
          ignore(
            self.durable_deliver_to_agent(
              parent, agent_id, message, status, runner,
            ),
          )
        } catch {
          _ => ()
        }
      RemoveTeamMember(parent_id~, slug~) =>
        ignore(@workspace.remove_team_member(parent_id, slug))
      FireHook(agent_id~, role~, exit_reason~) =>
        @tools.fire_hook_async(
          @hooks.HookEvent::AgentExit,
          {
            event: @hooks.HookEvent::AgentExit,
            session_id: None,
            agent_id: Some(agent_id),
            role: Some(role),
            tool_name: None,
            tool_args: None,
            tool_result_status: None,
            exit_reason: Some(exit_reason),
            suspend_reason: None,
          },
          self.config.project_dir,
        )
      RemoveWorktree(path) =>
        ignore(runner([@workspace.git_worktree_remove(path)]) catch { _ => [] })
      CloseTerminal(target) => {
        let cmd = @workspace.local_close_target(target)
        try {
          let codes = runner([cmd])
          if codes.length() == 0 || codes[0] != 0 {
            @moontrace.warn("CloseTerminal failed", fields=[
              @moontrace.field(
                "exit",
                if codes.length() > 0 {
                  codes[0]
                } else {
                  -1
                },
              ),
              @moontrace.field("cmd", cmd.to_string()),
            ])
          }
        } catch {
          err =>
            @moontrace.warn("CloseTerminal failed", fields=[
              @moontrace.field("error", err.to_string()),
              @moontrace.field("cmd", cmd.to_string()),
            ])
        }
      }
      InjectTerminalMessage(target, message) =>
        ignore(
          @tools.execute_delivery(
            @message.DeliveryMethod::LocalTerminalInput(target, message),
            runner,
          ) catch {
            _ => Ok(())
          },
        )
      ClearRuntimeTracking(agent_id) =>
        self.clear_agent_runtime_tracking(agent_id)
      WatchPane(agent_id~) =>
        try self.registry.get(agent_id) catch {
          _ => ()
        } noraise {
          agent =>
            match agent.terminal_target {
              Some(_) => self.watch_pane(agent_id)
              None => ()
            }
        }
      UpdateDevLifecycle(agent_id~, event~) =>
        ignore(
          @tools.apply_dev_event_checked(
            self.config.project_dir,
            agent_id,
            event,
            registry=Some(self.registry),
          ),
        )
      DeliverToParentMerged(
        leaf_id~,
        pr_number~,
        branch~,
        parent_branch~,
        url~,
        source~,
        merge_execution_mode~,
        parent_id~
      ) => {
        match parent_id {
          Some(pid) =>
            try {
              let parent = self.resolve_parent_by_id(pid)
              let body = merged_pr_parent_message(
                pr_number,
                leaf_id,
                branch,
                parent_branch,
                url,
                source,
                merge_execution_mode~,
              )
              ignore(
                self.durable_deliver_to_agent(
                  parent,
                  leaf_id,
                  body,
                  @types.Status::Success,
                  runner,
                ),
              )
            } catch {
              _ => ()
            }
          None => ()
        }
        ignore(source)
      }
      ParentFailureTerminalEchoIfNeeded(
        parent_id~,
        agent_id~,
        parent_message~,
        reason~
      ) =>
        try {
          let p = self.resolve_parent_by_id(parent_id)
          let delivery = @message.plan_delivery(
            p,
            agent_id,
            parent_message,
            @types.Status::Failure,
          )
          let already_terminal = match delivery {
            @message.DeliveryMethod::LocalTerminalInput(_, _) => true
            _ => false
          }
          let is_self_reported = match reason {
            @phase.FailureReason::ChildFailure(_) => true
            _ => false
          }
          if !is_self_reported && !already_terminal {
            match p.terminal_target {
              Some(target) => {
                let reason_str = reason.to_wire_string()
                let msg = @message.format_failure(agent_id, reason_str)
                ignore(
                  @tools.execute_delivery(
                    @message.DeliveryMethod::LocalTerminalInput(target, msg),
                    runner,
                  ) catch {
                    _ => Ok(())
                  },
                )
              }
              None => ()
            }
          }
        } catch {
          _ => ()
        }
      RefreshPR(pr_number) => self.refresh_pr_with_runner(pr_number, runner)
    }
  }
}

///|
/// Check for idle agents by dumping pane screens and comparing hashes.
/// If a pane's screen hasn't changed for `timeout` seconds, kill the agent.
pub async fn ServerState::check_idle_agents(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_ids = self.pane_watcher.watched_agents()
  for agent_id in agent_ids {
    let agent = try self.registry.get(agent_id) catch {
      _ => {
        self.stop_subscribe(agent_id)
        continue
      }
    } noraise {
      a => a
    }
    if agent.state != @types.AgentState::Active {
      self.stop_subscribe(agent_id)
      continue
    }
    if agent.role == @types.Role::Root || agent.role == @types.Role::TL {
      continue
    }
    // `ReviewOwned` devs are watchdog-exempt (idle while waiting for TL merge /
    // review). Dispatch still warns the parent when `notify_parent` is blocked on
    // unresolved threads.
    if @phase.lifecycle_idle_watchdog_exempt(self.current_lifecycle(agent_id)) {
      continue
    }
    match agent.terminal_target {
      Some(_) => ()
      None => continue
    }

    // Check if idle too long
    match self.pane_watcher.check_idle(agent_id, now, timeout) {
      Some(screen) => {
        ignore(screen) // We could extract failure reason from screen if desired, but watchdog just kills it
        // Kill the agent
        @moontrace.warn("watchdog killing idle agent", fields=[
          @moontrace.field("agent", agent_id),
          @moontrace.field("idle_sec", timeout),
        ])
        let message = "[WATCHDOG] agent " +
          agent_id +
          " killed after " +
          timeout.to_string() +
          "s idle (no pane output change)"
        self.fail_agent_with_runner(
          agent_id,
          @phase.FailureReason::WatchdogTimeout,
          message,
          @types.ExitReason::Shutdown,
          runner,
          close_target=true,
        )
      }
      None => continue
    }
  }
}

///|
pub fn ServerState::list_agents(self : ServerState) -> Array[@types.Agent] {
  self.registry.list()
}

///|
pub fn ServerState::get_agent(
  self : ServerState,
  agent_id : String,
) -> @types.Agent raise @types.ChoirError {
  self.registry.get(agent_id)
}

///|
/// Called when a connection closes. Detects unexpected agent death and notifies parent.
/// Review-owned agents are preserved; agent-owned disconnects fail.
pub fn disconnect_pr_recovery_candidate(agent : @types.Agent) -> Bool {
  agent.role == @types.Role::Dev && agent.branch.trim() != ""
}

///|
pub async fn ServerState::handle_disconnect_with_runner(
  self : ServerState,
  agent_id : String,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> Unit {
  let agent = self.registry.get(agent_id) catch { _ => return }
  let lifecycle = self.current_lifecycle(agent_id)
  match agent.state {
    Done | Failed =>
      match agent.terminal_target {
        Some(target) =>
          self.interpret_teardown_effects([CloseTerminal(target)], runner)
        None => ()
      }
    Completing => {
      let exit_reason = match lifecycle.process {
        @phase.ProcessState::Finalizing(reason=@phase.FinalizeReason::Merged) =>
          @types.ExitReason::Merged
        @phase.ProcessState::Finalizing(
          reason=@phase.FinalizeReason::DisconnectFinalized
        ) => @types.ExitReason::Disconnected
        _ => @types.ExitReason::Shutdown
      }
      self.finalize_agent_with_runner(
        agent_id,
        exit_reason,
        runner,
        notify_parent=false,
        close_target=false,
        remove_worktree=false,
      )
    }
    _ =>
      if self.auto_rescue_disconnected_review_leaf(
          agent, lifecycle, runner, capture,
        ) {
        ()
      } else {
        match @phase.lifecycle_disconnect_policy(lifecycle) {
          @phase.LifecycleDisconnectPolicy::Preserve => ()
          @phase.LifecycleDisconnectPolicy::FinalizeDone(..) =>
            self.finalize_agent_with_runner(
              agent_id,
              @types.ExitReason::Disconnected,
              runner,
              notify_parent=false,
              close_target=false,
              remove_worktree=false,
            )
          @phase.LifecycleDisconnectPolicy::Ignore => ()
          @phase.LifecycleDisconnectPolicy::Fail(reason=default_reason) => {
            // Before failing: check if a dev leaf filed a PR via raw `gh pr create`
            // (bypassing file_pr). Restrict this to branch-owning dev agents so
            // top-level TLs/workers with empty branches cannot steal tracked PR ownership.
            let recovered_pr = if disconnect_pr_recovery_candidate(agent) {
              @runtime.find_pr_for_branch_in_provider(
                self.recovery_provider,
                self.config.project_dir,
                agent.branch,
              )
            } else {
              None
            }
            match recovered_pr {
              Some((pr_number, pr_url)) => {
                let parent_branch = match
                  @workspace.parent_branch(agent.branch) {
                  Some(pb) => pb
                  None => "main"
                }
                @tools.apply_dev_event(
                  self.config.project_dir,
                  agent_id,
                  @phase.DevEvent::PRCreated(
                    pr_number~,
                    url=pr_url,
                    branch=agent.branch,
                  ),
                  registry=Some(self.registry),
                )
                self.poller.ensure_tracked(
                  pr_number,
                  agent_id,
                  agent.branch,
                  parent_branch,
                  pr_url,
                  @poller.now_sec(),
                )
                ignore(self.poller.write_state_file(self.config.project_dir))
              }
              None => {
                let snapshot = self.pane_watcher.read_viewport(agent_id)
                let screen = @runtime.extract_viewport_text(snapshot)
                let (reason, msg) = if screen != "" {
                  let classified = @phase.classify_failure(screen)
                  match classified {
                    @phase.FailureReason::ChildFailure(_) =>
                      (
                        default_reason,
                        "[FAILED: " +
                        agent_id +
                        "] disconnected unexpectedly - agent may have crashed or run out of context",
                      )
                    _ =>
                      (
                        classified,
                        "[FAILED: " +
                        agent_id +
                        "] " +
                        @phase.failure_reason_message(classified),
                      )
                  }
                } else {
                  (
                    default_reason,
                    "[FAILED: " +
                    agent_id +
                    "] disconnected unexpectedly - agent may have crashed or run out of context",
                  )
                }
                self.fail_agent_with_runner(
                  agent_id,
                  reason,
                  msg,
                  @types.ExitReason::Disconnected,
                  runner,
                )
              }
            }
          }
        }
      }
  }
}

///|
pub async fn ServerState::handle_disconnect(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.handle_disconnect_with_runner(agent_id, runner=@exec.run_sequence)
}

///|
/// Schedule a disconnect instead of firing immediately.
/// The pending disconnect is resolved on the next poller tick after the grace period.
pub fn ServerState::schedule_disconnect(
  self : ServerState,
  agent_id : String,
  now : Int64,
) -> Unit {
  self.pending_disconnects.set(agent_id, now)
}

///|
/// Clear a pending disconnect (called when an agent re-registers).
pub fn ServerState::clear_pending_disconnect(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.pending_disconnects.remove(agent_id)
}

///|
/// Process pending disconnects older than grace_seconds. Fire handle_disconnect for stale ones.
pub async fn ServerState::process_pending_disconnects_with_runner(
  self : ServerState,
  now : Int64,
  grace_seconds : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> Unit {
  let stale : Array[String] = []
  for agent_id, disconnect_time in self.pending_disconnects {
    if now - disconnect_time >= grace_seconds {
      stale.push(agent_id)
    }
  }
  for agent_id in stale {
    self.pending_disconnects.remove(agent_id)
    self.handle_disconnect_with_runner(agent_id, runner~, capture~)
  }
}

///|
pub async fn ServerState::process_pending_disconnects(
  self : ServerState,
  now : Int64,
  grace_seconds : Int64,
) -> Unit {
  self.process_pending_disconnects_with_runner(
    now,
    grace_seconds,
    runner=@exec.run_sequence,
  )
}

///|

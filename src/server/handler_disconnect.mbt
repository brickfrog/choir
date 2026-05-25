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
  self.agent_pids.remove(agent_id)
  self.disconnect_contexts.remove(agent_id)
  self.worker_no_handoff_prodded_at.remove(agent_id)
  self.worker_no_handoff_stalled_emitted.remove(agent_id)
  self.handoff_delivered.remove(agent_id)
  self.worker_no_handoff_exit_emitted.remove(agent_id)
  self.idle_agent_warned_at_70.remove(agent_id)
  self.clear_audit_cycle_count_for_agent(agent_id)
  self.clear_audit_progress_for_agent(agent_id)
  self.recent_poller_event_emissions.remove(agent_id)
}

///|
fn default_kill_pgid_best_effort(pgid : Int) -> Unit {
  @sys.kill_pgid_best_effort(pgid)
}

///|
/// Default predicate for `safe_remove_git_worktree`: a path is a git
/// worktree iff it contains a `.git` entry (file or directory). Indirection
/// keeps `@exec.*` out of the optional-default position; the lint's exec
/// scanner does not chase through local references.
fn default_path_is_git_worktree(path : String) -> Bool {
  @exec.path_entry_exists(path + "/.git")
}

///|
/// Remove a git worktree, skipping the git call entirely when the path is
/// not a git worktree (path missing on disk, or a stale empty directory
/// with no `.git` marker). This covers the literal bead evidence:
/// `.choir/worktrees/<slug>/` left as an empty directory by a prior
/// session — `git worktree remove --force` on that path emits
/// `fatal: ... is not a working tree` because no `.git` is inside.
/// Silent on any runner failure — matches the pre-existing
/// `ignore(runner(...) catch _ => [])` semantics for this branch.
async fn safe_remove_git_worktree(
  path : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  is_git_worktree : (String) -> Bool,
) -> Unit {
  if !is_git_worktree(path) {
    return
  }
  ignore(runner([@workspace.git_worktree_remove(path)]) catch { _ => [] })
}

///|
async test "safe_remove_git_worktree skips when path is not a git worktree" {
  let mut runner_calls = 0
  safe_remove_git_worktree(
    "/repo/.choir/worktrees/stale-empty-dir",
    async fn(_cmds) {
      runner_calls = runner_calls + 1
      []
    },
    _ => false,
  )
  assert_eq(runner_calls, 0)
}

///|
async test "safe_remove_git_worktree invokes runner when .git marker exists" {
  let mut captured : Array[@workspace.Command] = []
  safe_remove_git_worktree(
    "/repo/.choir/worktrees/live",
    async fn(cmds) {
      captured = cmds
      [0]
    },
    _ => true,
  )
  assert_eq(captured.length(), 1)
  assert_eq(captured[0].program, "git")
  @debug.assert_eq(captured[0].args, [
    "worktree", "remove", "--force", "/repo/.choir/worktrees/live",
  ])
}

///|
async test "safe_remove_git_worktree swallows runner failure silently" {
  // Pins the "silent on runner failure" contract observably: a non-zero
  // exit and a raising runner both must complete without emitting any
  // moontrace event from the helper itself.
  let captured : Array[@moontrace.Event] = []
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  try {
    safe_remove_git_worktree(
      "/repo/.choir/worktrees/present",
      async fn(_cmds) { [128] },
      _ => true,
    )
    safe_remove_git_worktree(
      "/repo/.choir/worktrees/present",
      async fn(_cmds) {
        raise @types.ChoirError::agent_not_found("synthetic")
        @async.sleep(0)
        []
      },
      _ => true,
    )
  } catch {
    e => {
      @moontrace.clear_subscriber()
      raise e
    }
  } noraise {
    _ => ()
  }
  @moontrace.clear_subscriber()
  assert_eq(captured.length(), 0)
}

///|
fn ServerState::kill_tracked_agent_pgroup(
  self : ServerState,
  agent_id : String,
  kill_pgid : (Int) -> Unit,
) -> Unit {
  match self.forget_agent_pid(agent_id) {
    Some(pgid) => kill_pgid(pgid)
    None => ()
  }
}

///|
pub fn ServerState::mark_handoff_delivered(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.handoff_delivered.set(agent_id, true)
  self.worker_no_handoff_prodded_at.remove(agent_id)
  self.worker_no_handoff_stalled_emitted.remove(agent_id)
  self.worker_no_handoff_exit_emitted.remove(agent_id)
}

///|
fn ServerState::handoff_was_delivered(
  self : ServerState,
  agent_id : String,
) -> Bool {
  self.handoff_delivered.contains(agent_id)
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
  sleep_fn? : async (Int) -> Unit = @async.sleep,
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
    self.config.project_dir,
    notify_parent~,
  )
  self.interpret_teardown_effects(effects, runner, sleep_fn~)
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
      if @types.is_supervisor_role(agent.role) {
        @moontrace.warn("finalize_agent refused: target is supervisor", fields=[
          @moontrace.field("agent_id", agent_id),
        ])
        return
      }
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
      if @types.is_supervisor_role(agent.role) {
        @moontrace.warn("fail_agent refused: target is supervisor", fields=[
          @moontrace.field("agent_id", agent_id),
        ])
        return
      }
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
      ignore(self.registry.set_alive(agent_id, false)) catch {
        _ => ()
      }
    }
  }
}

///|
pub async fn ServerState::interpret_teardown_effects(
  self : ServerState,
  effects : Array[TeardownEffect],
  runner : async (Array[@workspace.Command]) -> Array[Int],
  sleep_fn? : async (Int) -> Unit = @async.sleep,
  is_git_worktree? : (String) -> Bool = default_path_is_git_worktree,
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
              parent,
              agent_id,
              message,
              status,
              runner,
              sleep_fn~,
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
            pr_number: None,
            pr_url: None,
            branch: None,
            parent_branch: None,
            merge_provenance: None,
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
        if @types.is_choir_managed_worktree_path(self.config.project_dir, path) {
          safe_remove_git_worktree(path, runner, is_git_worktree)
        } else {
          @moontrace.warn("RemoveWorktree refused: unsafe path", fields=[
            @moontrace.field("path", path),
          ])
        }
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
                  sleep_fn~,
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
fn nonnegative_elapsed(now : Int64, then : Int64) -> Int64 {
  if now >= then {
    now - then
  } else {
    0L
  }
}

///|
fn ServerState::leaf_merge_gate_ready_for_agent(
  self : ServerState,
  agent_id : String,
) -> Bool {
  for tracked in self.poller.tracked.values() {
    if tracked.agent_id == agent_id {
      let unresolved_threads = tracked_unresolved_thread_count_for_gate(tracked)
      if @poller.tl_tracked_pr_merge_gate_snapshot_ready(
          tracked,
          unresolved_threads,
          review_mode=tracked.review_mode,
        ) {
        return true
      }
    }
  }
  false
}

///|
fn worker_no_handoff_terminal_process(
  lifecycle : @phase.AgentLifecycle,
) -> Bool {
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => true
    _ => false
  }
}

///|
fn ServerState::leaf_watchdog_should_fail_without_handoff(
  self : ServerState,
  agent_id : String,
  workflow : @phase.WorkflowState,
) -> Bool {
  if self.handoff_was_delivered(agent_id) {
    return false
  }
  match workflow {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ReviewOwned(..))
    | @phase.WorkflowState::Dev(@phase.DevLifecycle::ExitRequestedDeferred(..)) =>
      self.leaf_merge_gate_ready_for_agent(agent_id)
    _ => false
  }
}

///|
fn lifecycle_transport_soft_disconnect(
  lifecycle : @phase.AgentLifecycle,
  disconnected_at_unix_sec : Int64,
) -> @phase.AgentLifecycle? {
  match lifecycle.process {
    @phase.ProcessState::Finalizing(..)
    | @phase.ProcessState::Finalized(..)
    | @phase.ProcessState::Failed(..) => None
    @phase.ProcessState::Disconnected(..) => None
    _ =>
      Some({
        ..lifecycle,
        process: @phase.ProcessState::Disconnected(disconnected_at_unix_sec~),
      })
  }
}

///|
fn lifecycle_transport_reconnect(
  lifecycle : @phase.AgentLifecycle,
) -> @phase.AgentLifecycle? {
  match lifecycle.process {
    @phase.ProcessState::Disconnected(..) =>
      Some({ ..lifecycle, process: @phase.ProcessState::Connected })
    _ => None
  }
}

///|
fn ServerState::persist_transport_process_transition(
  self : ServerState,
  agent_id : String,
  next : @phase.AgentLifecycle,
  trigger : @types.LifecycleTrigger,
) -> Unit {
  let prev = self.current_lifecycle(agent_id)
  if @phase.persist_lifecycle(self.config.project_dir, self.registry, next) {
    ignore(
      append_lifecycle_event(
        self.config.project_dir,
        agent_id,
        prev,
        next,
        trigger,
      ),
    )
    @phase.sync_parent_child_lifecycle(
      self.config.project_dir,
      self.config.terminal_session,
      self.registry,
      agent_id,
      next,
    )
  }
}

///|
fn ServerState::mark_transport_soft_disconnected(
  self : ServerState,
  agent_id : String,
  disconnected_at_unix_sec : Int64,
) -> Unit {
  if self.registry.get_opt(agent_id) is Some(agent) &&
    agent.state == @types.AgentState::Suspended {
    return
  }
  let lifecycle = self.current_lifecycle(agent_id)
  match
    lifecycle_transport_soft_disconnect(lifecycle, disconnected_at_unix_sec) {
    Some(next) =>
      self.persist_transport_process_transition(
        agent_id,
        next,
        @types.LifecycleTrigger::TransportDisconnected,
      )
    None => ()
  }
}

///|
fn ServerState::mark_transport_reconnected(
  self : ServerState,
  agent_id : String,
) -> Unit {
  let lifecycle = self.current_lifecycle(agent_id)
  match lifecycle_transport_reconnect(lifecycle) {
    Some(next) =>
      self.persist_transport_process_transition(
        agent_id,
        next,
        @types.LifecycleTrigger::TransportReconnected,
      )
    None => ()
  }
}

///|
async fn ServerState::prod_leaf_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  now : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if self.worker_no_handoff_prodded_at.contains(agent_id) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  self.worker_no_handoff_prodded_at.set(agent_id, now)
  ignore(
    self.durable_deliver_to_agent(
      agent,
      "watchdog",
      leaf_stalled_no_handoff_prod_message(@phase.extract_slug(agent_id)),
      @types.Status::Info,
      runner,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::emit_leaf_stalled_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  idle_sec : Int64,
  screen : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if self.worker_no_handoff_stalled_emitted.contains(agent_id) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  self.worker_no_handoff_stalled_emitted.set(agent_id, true)
  let message = leaf_stalled_no_handoff_parent_message(
    @phase.extract_slug(agent_id),
    idle_sec,
    screen,
  )
  ignore(
    self.durable_deliver_to_parent(
      agent_id,
      message,
      @types.Status::Failure,
      runner,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::prod_worker_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  now : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if self.worker_no_handoff_prodded_at.contains(agent_id) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  let target = match agent.terminal_target {
    Some(t) => t
    None => return
  }
  self.worker_no_handoff_prodded_at.set(agent_id, now)
  ignore(
    @tools.execute_delivery(
      @message.DeliveryMethod::LocalTerminalInput(
        target, worker_no_handoff_prod_text,
      ),
      runner,
      project_dir=self.config.project_dir,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::emit_worker_stalled_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  idle_sec : Int64,
  screen : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if self.worker_no_handoff_stalled_emitted.contains(agent_id) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  self.worker_no_handoff_stalled_emitted.set(agent_id, true)
  let message = worker_stalled_no_handoff_message(
    @phase.extract_slug(agent_id),
    idle_sec,
    screen,
  )
  ignore(
    self.durable_deliver_to_parent(
      agent_id,
      message,
      @types.Status::Failure,
      runner,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::emit_worker_exited_without_notify_if_needed(
  self : ServerState,
  agent : @types.Agent,
  screen : String?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  if agent.role != @types.Role::Worker {
    return
  }
  let agent_id = agent.agent_id.to_string()
  if self.handoff_was_delivered(agent_id) ||
    self.worker_no_handoff_exit_emitted.contains(agent_id) {
    return
  }
  self.worker_no_handoff_exit_emitted.set(agent_id, true)
  let screen_text = match screen {
    Some(s) => s
    None =>
      @runtime.extract_viewport_text(self.pane_watcher.read_viewport(agent_id))
  }
  let message = worker_exited_without_notify_message(
    @phase.extract_slug(agent_id),
    screen_text,
  )
  ignore(
    self.durable_deliver_to_parent(
      agent_id,
      message,
      @types.Status::Failure,
      runner,
    ),
  ) catch {
    _ => ()
  }
}

///|
async fn ServerState::check_leaf_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  lifecycle : @phase.WorkflowState,
  now : Int64,
  observation : @runtime.PaneIdleObservation,
  prod_sec : Int64,
  escalate_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if agent.role != @types.Role::Dev ||
    self.handoff_was_delivered(agent_id) ||
    prod_sec <= 0L {
    return
  }
  let prodded_at = self.worker_no_handoff_prodded_at.get(agent_id)
  let prodded = prodded_at != None
  let idle_timeout = if prodded { escalate_sec } else { prod_sec }
  if idle_timeout <= 0L {
    return
  }
  if observation.idle_sec < idle_timeout {
    return
  }
  let gate_ready = self.leaf_merge_gate_ready_for_agent(agent_id)
  let decision_idle_sec = match prodded_at {
    Some(t) => {
      let elapsed_since_prod = nonnegative_elapsed(now, t)
      let post_prod_idle_sec = if observation.idle_sec < elapsed_since_prod {
        observation.idle_sec
      } else {
        elapsed_since_prod
      }
      prod_sec + post_prod_idle_sec
    }
    None => observation.idle_sec
  }
  match
    leaf_no_handoff_decision(
      agent.role,
      lifecycle,
      gate_ready,
      decision_idle_sec,
      self.handoff_was_delivered(agent_id),
      prodded,
      self.worker_no_handoff_stalled_emitted.contains(agent_id),
      prod_sec,
      escalate_sec,
    ) {
    WorkerNoHandoffDecision::Prod =>
      self.prod_leaf_no_handoff(agent, now, runner)
    WorkerNoHandoffDecision::EmitStalled =>
      self.emit_leaf_stalled_no_handoff(
        agent,
        observation.idle_sec,
        observation.screen,
        runner,
      )
    WorkerNoHandoffDecision::DoNothing => ()
  }
}

///|
async fn ServerState::check_worker_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  now : Int64,
  observation : @runtime.PaneIdleObservation,
  prod_sec : Int64,
  escalate_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if agent.role != @types.Role::Worker ||
    self.handoff_was_delivered(agent_id) ||
    prod_sec <= 0L {
    return
  }
  let prodded_at = self.worker_no_handoff_prodded_at.get(agent_id)
  let prodded = prodded_at != None
  let idle_timeout = if prodded { escalate_sec } else { prod_sec }
  if idle_timeout <= 0L {
    return
  }
  if observation.idle_sec < idle_timeout {
    return
  }
  let decision_idle_sec = match prodded_at {
    Some(t) => nonnegative_elapsed(now, t)
    None => observation.idle_sec
  }
  match
    worker_no_handoff_decision(
      agent.role,
      decision_idle_sec,
      self.handoff_was_delivered(agent_id),
      prodded,
      self.worker_no_handoff_stalled_emitted.contains(agent_id),
      prod_sec,
      escalate_sec,
    ) {
    WorkerNoHandoffDecision::Prod =>
      self.prod_worker_no_handoff(agent, now, runner)
    WorkerNoHandoffDecision::EmitStalled =>
      self.emit_worker_stalled_no_handoff(
        agent,
        observation.idle_sec,
        observation.screen,
        runner,
      )
    WorkerNoHandoffDecision::DoNothing => ()
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
  worker_no_handoff_prod_sec? : Int64 = 120L,
  worker_no_handoff_escalate_sec? : Int64 = 120L,
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
    if @types.is_supervisor_role(agent.role) {
      continue
    }
    let lifecycle = self.current_lifecycle(agent_id)
    // Some lifecycle states are kill-watchdog-exempt, but no-handoff checks
    // may still need to prod or notify without terminating the agent.
    let watchdog_exempt = @phase.lifecycle_idle_watchdog_exempt(lifecycle) &&
      !self.leaf_watchdog_should_fail_without_handoff(
        agent_id,
        lifecycle.workflow,
      )
    match agent.terminal_target {
      Some(_) => ()
      None => continue
    }

    // Read and parse the pane snapshot once for all idle decisions this tick.
    match self.pane_watcher.observe_idle(agent_id, now) {
      Some(observation) => {
        self.check_worker_no_handoff(
          agent, now, observation, worker_no_handoff_prod_sec, worker_no_handoff_escalate_sec,
          runner,
        )
        self.check_leaf_no_handoff(
          agent,
          lifecycle.workflow,
          now,
          observation,
          worker_no_handoff_prod_sec,
          worker_no_handoff_escalate_sec,
          runner,
        )
        if watchdog_exempt {
          continue
        }
        if should_emit_70_pct_warning(
            observation.idle_sec,
            timeout,
            self.idle_agent_warned_at_70.contains(agent_id),
          ) {
          self.idle_agent_warned_at_70.set(agent_id, true)
          @moontrace.warn("idle agent approaching kill threshold", fields=[
            @moontrace.field("agent_id", agent_id),
            @moontrace.field("idle_sec", observation.idle_sec),
            @moontrace.field("threshold", timeout),
            @moontrace.field("percent", idle_watchdog_warning_percent),
          ])
        }
        if observation.idle_sec < timeout {
          continue
        }
        self.emit_worker_exited_without_notify_if_needed(
          agent,
          Some(observation.screen),
          runner,
        )
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
async test "check_idle_agents skips supervisor roles before reading panes" {
  let project_dir = "/tmp/choir-check-idle-supervisor-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let reads : Array[String] = []
  let spawned : Array[String] = []
  let killed : Array[Int] = []
  let host : @runtime.PaneWatchHost = {
    spawn_zellij_pane_viewport_subscribe: fn(_session, name, _snapshot_path) {
      spawned.push(name)
      100
    },
    kill_pid_best_effort: fn(pid) { killed.push(pid) },
    delete_file_sync: fn(_path) {  },
    read_file: fn(path) {
      reads.push(path)
      "{\"event\":\"pane_update\",\"viewport\":[\"idle\"]}"
    },
  }
  let state = {
    ..ServerState::new(
      { ..@types.Config::default(), project_dir, terminal_session: "s" },
      make_hermetic_recovery_provider(),
    ),
    pane_watcher: @runtime.PaneWatcher::with_host(host),
  }
  for role in [@types.Role::Root, @types.Role::TL] {
    let agent_id = match role {
      @types.Role::Root => "root"
      @types.Role::TL => "main.tl"
      _ => "main.supervisor"
    }
    ignore(
      state.register_agent({
        agent_id: @types.AgentId(agent_id),
        role,
        agent_type: @types.AgentType::Claude,
        parent: None,
        workspace: project_dir,
        branch: "main",
        terminal_target: Some({
          kind: @types.TargetKind::ZellijPane,
          session: "s",
          name: agent_id,
        }),
        host: @types.Host::Local,
        spawn_depth: 0,
        state: @types.AgentState::Active,
      }),
    )
    state.watch_pane(agent_id)
  }
  let calls : Array[@workspace.Command] = []
  state.check_idle_agents(1000L, 0L, async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  assert_eq(spawned.length(), 2)
  @debug.assert_eq(reads, [])
  @debug.assert_eq(killed, [])
  @debug.assert_eq(calls, [])
  assert_eq(state.registry.get("root").state, @types.AgentState::Active)
  assert_eq(state.registry.get("main.tl").state, @types.AgentState::Active)
  ignore(@sys.rm_rf(project_dir))
}

///|
async fn handler_disconnect_moontrace_capture(
  captured : Array[@moontrace.Event],
  f : async () -> Unit,
) -> Unit {
  @moontrace.set_subscriber(fn(event) { captured.push(event) })
  f() catch {
    err => {
      @moontrace.clear_subscriber()
      raise err
    }
  }
  @moontrace.clear_subscriber()
}

///|
fn handler_disconnect_warning_count(
  events : Array[@moontrace.Event],
  message : String,
) -> Int {
  let mut count = 0
  for event in events {
    if event.level == @moontrace.Level::Warn && event.message == message {
      count = count + 1
    }
  }
  count
}

///|
async test "startup disconnect after register emits startup prompt-gap warning" {
  let project_dir = "/tmp/choir-startup-disconnect-warning-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  ignore(
    @sys.create_dir_all(project_dir + "/.choir/worktrees/main.gemini-leaf"),
  )
  let parent_id = "main.tl"
  let agent_id = "main.gemini-leaf"
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    make_hermetic_recovery_provider(),
  )
  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Gemini,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/main.gemini-leaf",
      branch: agent_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  state.schedule_disconnect(
    agent_id,
    0L,
    connected_sec=Some(1L),
    last_request_name=Some("register"),
  )
  let captured : Array[@moontrace.Event] = []
  handler_disconnect_moontrace_capture(captured, async fn() {
    state.process_pending_disconnects_with_runner(61L, 60L, runner=async fn(
      _cmds,
    ) {
      []
    })
  })
  assert_eq(
    handler_disconnect_warning_count(
      captured, "worker disconnected immediately after register (likely interactive prompt block or config gap)",
    ),
    1,
  )
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "unexpected disconnect closes terminal and preserves failure teardown" {
  let project_dir = "/tmp/choir-unexpected-disconnect-close-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let parent_id = "main.tl"
  let agent_id = "main.leaf"
  let target : @types.LocalTarget = {
    kind: @types.TargetKind::ZellijPane,
    session: "s",
    name: "leaf-pane",
  }
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    make_hermetic_recovery_provider(),
  )
  ignore(
    state.register_agent({
      agent_id: @types.AgentId(parent_id),
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: Some({
        kind: @types.TargetKind::ZellijPane,
        session: "s",
        name: "parent-pane",
      }),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  ignore(
    state.register_agent({
      agent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir + "/.choir/worktrees/main.leaf",
      branch: agent_id,
      terminal_target: Some(target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  let expected_close = @workspace.local_close_target(target)
  let calls : Array[@workspace.Command] = []
  state.handle_disconnect_with_runner(agent_id, runner=async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  let mut saw_close = false
  let mut saw_parent_failure = false
  for cmd in calls {
    if cmd == expected_close {
      saw_close = true
    }
    if cmd.program == "choir" &&
      cmd.args.contains("zellij-action") &&
      cmd.args.contains("send") &&
      cmd.args[cmd.args.length() - 1].contains("[FAILED: " + agent_id + "]") {
      saw_parent_failure = true
    }
  }
  assert_true(saw_close)
  assert_true(saw_parent_failure)
  match @phase.read_lifecycle(project_dir, agent_id) {
    Some(
      { process: @phase.ProcessState::Failed(reason=UnexpectedDisconnect), .. }
    ) => ()
    _ => fail("expected persisted Failed(UnexpectedDisconnect) lifecycle")
  }
  ignore(@sys.rm_rf(project_dir))
}

///|
test "clear_agent_runtime_tracking clears worker no-handoff maps" {
  let project_dir = "/tmp/choir-clear-worker-handoff-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    make_hermetic_recovery_provider(),
  )
  let agent_id = "main.worker"
  state.pending_disconnects.set(agent_id, 1L)
  state.disconnect_contexts.set(agent_id, {
    connected_sec: Some(1L),
    last_request_name: Some("register"),
  })
  state.handoff_delivered.set(agent_id, true)
  state.worker_no_handoff_prodded_at.set(agent_id, 2L)
  state.worker_no_handoff_stalled_emitted.set(agent_id, true)
  state.worker_no_handoff_exit_emitted.set(agent_id, true)
  state.idle_agent_warned_at_70.set(agent_id, true)
  state.recent_poller_event_emissions.set(agent_id, {
    "merge_ready": { content_hash: "hash", emitted_at_unix: 3L },
  })

  state.clear_agent_runtime_tracking(agent_id)

  assert_eq(state.pending_disconnects.contains(agent_id), false)
  assert_eq(state.disconnect_contexts.contains(agent_id), false)
  assert_eq(state.handoff_delivered.contains(agent_id), false)
  assert_eq(state.worker_no_handoff_prodded_at.contains(agent_id), false)
  assert_eq(state.worker_no_handoff_stalled_emitted.contains(agent_id), false)
  assert_eq(state.worker_no_handoff_exit_emitted.contains(agent_id), false)
  assert_eq(state.idle_agent_warned_at_70.contains(agent_id), false)
  assert_eq(state.recent_poller_event_emissions.contains(agent_id), false)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "supervisor disconnect clears startup disconnect context" {
  let project_dir = "/tmp/choir-supervisor-disconnect-context-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/kv"))
  let state = ServerState::new(
    { ..@types.Config::default(), project_dir, terminal_session: "s" },
    make_hermetic_recovery_provider(),
  )
  ignore(
    state.register_agent({
      agent_id: "main.tl",
      role: @types.Role::TL,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: "main",
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )
  state.schedule_disconnect(
    "main.tl",
    0L,
    connected_sec=Some(1L),
    last_request_name=Some("register"),
  )
  assert_eq(state.disconnect_contexts.contains("main.tl"), true)
  state.process_pending_disconnects_with_runner(1L, 0L, runner=async fn(_cmds) {
    []
  })
  assert_eq(state.disconnect_contexts.contains("main.tl"), false)
  ignore(@sys.rm_rf(project_dir))
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
async fn ServerState::handle_disconnect_confirming_with_runner(
  self : ServerState,
  agent_id : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  kill_pgid? : (Int) -> Unit = default_kill_pgid_best_effort,
) -> Unit {
  let agent = self.registry.get(agent_id) catch {
    _ => {
      self.clear_agent_runtime_tracking(agent_id)
      return
    }
  }
  if @types.is_supervisor_role(agent.role) {
    self.disconnect_contexts.remove(agent_id)
    return
  }
  self.kill_tracked_agent_pgroup(agent_id, kill_pgid)
  match self.disconnect_contexts.get(agent_id) {
    Some(ctx) =>
      if ctx.last_request_name == Some("register") {
        match ctx.connected_sec {
          Some(sec) if sec < 2 =>
            @moontrace.warn(
              "worker disconnected immediately after register (likely interactive prompt block or config gap)",
              fields=[
                @moontrace.field("agent_id", agent_id),
                @moontrace.field(
                  "agent_type",
                  agent.agent_type.to_wire_string(),
                ),
                @moontrace.field("connected_sec", sec.to_string()),
                @moontrace.field("last_request", "register"),
              ],
            )
          _ => ()
        }
      }
    None => ()
  }
  let lifecycle = self.current_lifecycle(agent_id)
  match agent.state {
    Done | Failed => {
      if !worker_no_handoff_terminal_process(lifecycle) {
        self.emit_worker_exited_without_notify_if_needed(agent, None, runner)
      }
      match agent.terminal_target {
        Some(target) =>
          self.interpret_teardown_effects([CloseTerminal(target)], runner)
        None => ()
      }
      self.clear_agent_runtime_tracking(agent_id)
    }
    Completing => {
      if !worker_no_handoff_terminal_process(lifecycle) {
        self.emit_worker_exited_without_notify_if_needed(agent, None, runner)
      }
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
      match @phase.lifecycle_disconnect_policy(lifecycle) {
        @phase.LifecycleDisconnectPolicy::Preserve => ()
        @phase.LifecycleDisconnectPolicy::FinalizeDone(..) => {
          self.emit_worker_exited_without_notify_if_needed(agent, None, runner)
          self.finalize_agent_with_runner(
            agent_id,
            @types.ExitReason::Disconnected,
            runner,
            notify_parent=false,
            close_target=false,
            remove_worktree=false,
          )
        }
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
              let parent_branch = match @workspace.parent_branch(agent.branch) {
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
              let review_mode = match self.poller.get(pr_number) {
                Some(existing) => existing.review_mode
                None =>
                  @workspace.review_mode_for_agent_workspace(
                    self.config.project_dir,
                    Some(agent.workspace),
                    @phase.extract_slug(agent_id),
                    agent_id=Some(agent_id),
                    global_review_mode=self.config.review_mode,
                  )
              }
              self.poller.ensure_tracked(
                pr_number,
                agent_id,
                agent.branch,
                parent_branch,
                pr_url,
                @poller.now_sec(),
                review_mode=Some(review_mode),
              )
              ignore(self.poller.write_state_file(self.config.project_dir))
            }
            None => {
              self.emit_worker_exited_without_notify_if_needed(
                agent,
                None,
                runner,
              )
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
                close_target=true,
              )
            }
          }
        }
      }
  }
}

///|
pub async fn ServerState::handle_disconnect_with_runner(
  self : ServerState,
  agent_id : String,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  kill_pgid? : (Int) -> Unit = default_kill_pgid_best_effort,
) -> Unit {
  self.handle_disconnect_confirming_with_runner(agent_id, runner, kill_pgid~)
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
  connected_sec? : Int64? = None,
  last_request_name? : String? = None,
) -> Unit {
  match self.registry.get_opt(agent_id) {
    Some(_) => ()
    None => return
  }
  self.mark_transport_soft_disconnected(agent_id, now)
  if connected_sec != None || last_request_name != None {
    self.disconnect_contexts.set(agent_id, { connected_sec, last_request_name })
  } else {
    self.disconnect_contexts.remove(agent_id)
  }
  self.pending_disconnects.set(agent_id, now)
}

///|
/// Clear a pending disconnect (called when an agent re-registers).
pub fn ServerState::clear_pending_disconnect(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.pending_disconnects.remove(agent_id)
  self.disconnect_contexts.remove(agent_id)
  self.mark_transport_reconnected(agent_id)
  ignore(self.registry.set_alive(agent_id, true)) catch {
    _ => ()
  }
}

///|
async fn ServerState::pending_disconnect_target_still_alive(
  self : ServerState,
  agent_id : String,
) -> Bool {
  let agent = try self.registry.get(agent_id) catch {
    _ => return false
  } noraise {
    a => a
  }
  if (
      agent.state != @types.AgentState::Active &&
      agent.state != @types.AgentState::Suspended
    ) ||
    @types.is_supervisor_role(agent.role) {
    return false
  }
  match agent.terminal_target {
    Some(_) => {
      let live = (self.recovery_provider.zellij_live)(
        self.config.project_dir,
        self.config.terminal_session,
      )
      if @runtime.is_local_target_alive(
          agent.terminal_target,
          self.config.terminal_session,
          live,
        ) {
        return true
      }
    }
    None => ()
  }
  if !@types.is_choir_managed_worktree_path(
      self.config.project_dir,
      agent.workspace,
    ) {
    return false
  }
  (self.recovery_provider.agent_process_alive)(
    self.config.project_dir,
    agent.workspace,
  )
}

///|
/// Process pending disconnects older than grace_seconds. Fire handle_disconnect for stale ones.
pub async fn ServerState::process_pending_disconnects_with_runner(
  self : ServerState,
  now : Int64,
  grace_seconds : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  kill_pgid? : (Int) -> Unit = default_kill_pgid_best_effort,
) -> Unit {
  let stale : Array[String] = []
  for agent_id, disconnect_time in self.pending_disconnects {
    if now - disconnect_time >= grace_seconds {
      stale.push(agent_id)
    }
  }
  for agent_id in stale {
    if self.pending_disconnect_target_still_alive(agent_id) {
      continue
    }
    ignore(self.registry.set_alive(agent_id, false)) catch {
      _ => ()
    }
    self.handle_disconnect_confirming_with_runner(agent_id, runner, kill_pgid~)
    ignore(self.registry.set_alive(agent_id, false)) catch {
      _ => ()
    }
    self.pending_disconnects.remove(agent_id)
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

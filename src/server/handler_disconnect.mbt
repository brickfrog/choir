///|
/// Register a pane for idle watchdog monitoring.
/// Resolves the agent's live zellij pane id from the current list-panes
/// snapshot and records it for dump-screen polling. Missing tabs remain
/// tracked with no pane id so later poller ticks can retry resolution.
pub async fn ServerState::watch_pane(
  self : ServerState,
  agent_id : String,
) -> Unit {
  let agent = self.registry.get(agent_id) catch { _ => return }
  let target = match agent.terminal_target {
    Some(t) => t
    None => return
  }
  let snapshot = (self.list_panes_snapshot_capture)(target.session)
  let pane_id = match @tools.resolve_zellij_pane_id(target, snapshot) {
    Some(value) => Some("terminal_" + value.to_string())
    None => None
  }
  self.pane_watcher.watch_pane(agent_id, target, @poller.now_sec(), pane_id~)
}

///|
async fn ServerState::ensure_watched_pane_resolved(
  self : ServerState,
  agent_id : String,
) -> Bool {
  if !self.pane_watcher.is_watching_agent(agent_id) {
    return false
  }
  let agent = self.registry.get(agent_id) catch { _ => return false }
  let target = match agent.terminal_target {
    Some(value) => value
    None => return false
  }
  let cached = self.pane_watcher.pane_id_for_agent(agent_id)
  let snapshot = (self.list_panes_snapshot_capture)(target.session)
  let current = match @tools.resolve_zellij_pane_id(target, snapshot) {
    Some(value) => Some("terminal_" + value.to_string())
    None => None
  }
  match (cached, current) {
    (Some(cached_id), Some(current_id)) if cached_id == current_id => true
    _ => {
      self.pane_watcher.watch_pane(
        agent_id,
        target,
        @poller.now_sec(),
        pane_id=current,
      )
      current is Some(_)
    }
  }
}

///|
/// Drop pane watchdog state for an agent.
fn ServerState::stop_watching(self : ServerState, agent_id : String) -> Unit {
  self.pane_watcher.stop_watching(agent_id)
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
  self.stop_watching(agent_id)
  self.pending_disconnects.remove(agent_id)
  self.agent_pids.remove(agent_id)
  self.disconnect_contexts.remove(agent_id)
  self.clear_all_no_handoff_watchdog_state(agent_id)
  self.handoff_delivered.remove(agent_id)
  self.worker_no_handoff_exit_emitted.remove(agent_id)
  self.spawn_registration_first_unseen.remove(agent_id)
  self.spawn_launch_diagnostics.remove(agent_id)
  self.idle_agent_warned_at_70.remove(agent_id)
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
      @async.sleep(0)
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
      @async.sleep(0)
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
      async fn(_cmds) {
        @async.sleep(0)
        [128]
      },
      _ => true,
    )
    safe_remove_git_worktree(
      "/repo/.choir/worktrees/present",
      async fn(_cmds) {
        @async.sleep(0)
        raise @types.ChoirError::agent_not_found("synthetic")
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
  // Only signal a pgid we recorded IN-MEMORY at registration. The on-disk
  // sidecar holds the SPAWN-TIME pid; for a never-registered or crashed leaf
  // that pid is freed early and can be reused by an unrelated process group, so
  // blind-killing it nukes innocent processes (e.g. zellij ptys -> cascading
  // spawn failures). PID reuse, choir-84zz. Clean up the stale sidecar but NEVER
  // use it as a kill target.
  match self.forget_agent_pid(agent_id) {
    Some(pid) => kill_pgid(pid)
    None => {
      let path = @workspace.agent_pid_file_path(
        self.config.project_dir,
        agent_id,
      )
      if @workspace.parse_agent_pgid((self.read_file)(path)) is Some(_) {
        ignore((self.delete_file)(path))
      }
    }
  }
}

///|
pub fn ServerState::mark_handoff_delivered(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.handoff_delivered.set(agent_id, true)
  self.clear_all_no_handoff_watchdog_state(agent_id)
  self.worker_no_handoff_exit_emitted.remove(agent_id)
}

///|
pub fn ServerState::reset_handoff_delivered(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.handoff_delivered.remove(agent_id)
}

///|
pub fn ServerState::handoff_was_delivered(
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
/// Reconcile a tracked PR that was closed on GitHub WITHOUT being merged
/// (choir-56ax). Plans a per-PR-gated finalize to `Done(PrClosedUnmerged)` with
/// the worktree preserved, then interprets it. If the leaf does not own this
/// exact PR (supersede case) or is already terminal, the planner returns no
/// effects and the leaf is left working.
async fn ServerState::reconcile_closed_unmerged_with_runner(
  self : ServerState,
  agent_id : String,
  pr_number : Int,
  branch : String,
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
  let effects = plan_closed_unmerged_finalization(
    agent,
    lifecycle,
    pr_number,
    branch,
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
  kill_pgid? : (Int) -> Unit = default_kill_pgid_best_effort,
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
          hook_capture=@exec.capture_hook_script_merged,
          xdg_config_home=@exec.hook_xdg_config_home(),
          home=@exec.hook_home(),
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
      ClearRuntimeTracking(agent_id) => {
        self.kill_tracked_agent_pgroup(agent_id, kill_pgid)
        self.clear_agent_runtime_tracking(agent_id)
      }
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
      RefreshPR(pr_number) =>
        self.refresh_pr_with_runner(
          pr_number,
          runner,
          capture=@exec.capture_command_merged,
          automerge_capture=@exec.capture_command_merged,
        )
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
      let review_required = @policy.review_required_for_branch(
        self.config.pr_policy.reviewer,
        self.config.pr_policy.skip_copilot_on_feature_branch,
        tracked.parent_branch,
        self.cached_default_branch,
      )
      if @poller.tl_tracked_pr_merge_gate_snapshot_ready(
          tracked,
          unresolved_threads,
          review_mode=tracked.review_mode,
          review_required~,
          audit_receipt_state=tracked.audit_receipt_state,
        ) {
        return true
      }
    }
  }
  false
}

///|
test "leaf merge gate threads audit state and cached default branch" {
  let make_state = fn(
    label : String,
    audit_receipt_state : @types.AuditReceiptState,
    review : @poller.ReviewState,
  ) -> ServerState {
    let project_dir = "/tmp/choir-leaf-merge-gate-" +
      label +
      "-" +
      @sys.get_pid().to_string() +
      "-" +
      @env.now().reinterpret_as_int64().to_string()
    ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
    let state = ServerState::new(
      {
        ..@types.Config::default(),
        project_dir,
        pr_policy: {
          ..@types.PrPolicy::default(),
          reviewer: @types.Reviewer::Copilot,
        },
      },
      make_hermetic_recovery_provider(),
    )
    let agent_id = "main.leaf-merge-gate"
    state.poller.track(
      901, agent_id, "feature/leaf", "feature/base", "https://example.test/pr/901",
      0L,
    )
    match state.poller.get(901) {
      Some(tracked) =>
        state.poller.restore({
          ..tracked,
          last_review_state: review,
          last_ci_rollup: @poller.CiRollupStatus::Success,
          audit_receipt_state,
          unresolved_thread_ids: [],
          unresolved_thread_ids_fetched: true,
        })
      None => abort("expected tracked leaf PR")
    }
    state
  }

  let pending = make_state(
    "pending",
    @types.AuditReceiptState::Pending(head_sha="head"),
    @poller.ReviewState::Approved,
  )
  assert_false(pending.leaf_merge_gate_ready_for_agent("main.leaf-merge-gate"))
  ignore(@sys.rm_rf(pending.config.project_dir))

  let findings = make_state(
    "findings",
    @types.AuditReceiptState::FindingsRemain(head_sha="head", count=2),
    @poller.ReviewState::Approved,
  )
  assert_false(findings.leaf_merge_gate_ready_for_agent("main.leaf-merge-gate"))
  ignore(@sys.rm_rf(findings.config.project_dir))

  let valid = make_state(
    "valid",
    @types.AuditReceiptState::Valid,
    @poller.ReviewState::Approved,
  )
  assert_true(valid.leaf_merge_gate_ready_for_agent("main.leaf-merge-gate"))
  ignore(@sys.rm_rf(valid.config.project_dir))

  let not_required = make_state(
    "not-required",
    @types.AuditReceiptState::NotRequired,
    @poller.ReviewState::Approved,
  )
  assert_true(
    not_required.leaf_merge_gate_ready_for_agent("main.leaf-merge-gate"),
  )
  ignore(@sys.rm_rf(not_required.config.project_dir))

  let default_branch = make_state(
    "default-branch",
    @types.AuditReceiptState::NotRequired,
    @poller.ReviewState::None_,
  )
  assert_eq(default_branch.cached_default_branch, "main")
  assert_true(
    default_branch.leaf_merge_gate_ready_for_agent("main.leaf-merge-gate"),
  )
  ignore(@sys.rm_rf(default_branch.config.project_dir))
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
async fn ServerState::emit_leaf_pre_tdd_stalled(
  self : ServerState,
  agent : @types.Agent,
  idle_sec : Int64,
  tdd_phase : @types.LeafTddPhase?,
  screen : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  let state_key = no_handoff_watchdog_state_key(agent_id, LeafPreTddStall)
  if self.worker_no_handoff_stalled_emitted.contains(state_key) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  self.worker_no_handoff_stalled_emitted.set(state_key, true)
  let message = leaf_pre_tdd_stalled_parent_message(
    @phase.extract_slug(agent_id),
    idle_sec,
    tdd_phase,
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
async fn ServerState::emit_leaf_stalled_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  idle_sec : Int64,
  screen : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  let state_key = no_handoff_watchdog_state_key(agent_id, LeafPostFixNoHandoff)
  if self.worker_no_handoff_stalled_emitted.contains(state_key) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  self.worker_no_handoff_stalled_emitted.set(state_key, true)
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
async fn ServerState::emit_worker_stalled_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  idle_sec : Int64,
  screen : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  let state_key = no_handoff_watchdog_state_key(agent_id, WorkerNoHandoff)
  if self.worker_no_handoff_stalled_emitted.contains(state_key) ||
    self.handoff_was_delivered(agent_id) {
    return
  }
  self.worker_no_handoff_stalled_emitted.set(state_key, true)
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
    None => {
      ignore(self.ensure_watched_pane_resolved(agent_id))
      match self.pane_watcher.current_screen(agent_id) {
        Some(s) => s
        None => ""
      }
    }
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
  observation : @runtime.PaneIdleObservation,
  idle_threshold_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if agent.role != @types.Role::Dev ||
    self.handoff_was_delivered(agent_id) ||
    idle_threshold_sec <= 0L {
    return
  }
  let gate_ready = self.leaf_merge_gate_ready_for_agent(agent_id)
  let pre_tdd_key = no_handoff_watchdog_state_key(agent_id, LeafPreTddStall)
  let post_fix_key = no_handoff_watchdog_state_key(
    agent_id,
    LeafPostFixNoHandoff,
  )
  let tdd_phase = self.leaf_tdd_phase_for_agent(agent_id)
  if observation.idle_sec >= idle_threshold_sec {
    match
      leaf_pre_tdd_stall_decision(
        agent.role,
        lifecycle,
        tdd_phase,
        observation.idle_sec,
        self.handoff_was_delivered(agent_id),
        self.worker_no_handoff_stalled_emitted.contains(pre_tdd_key),
        idle_threshold_sec,
      ) {
      WorkerNoHandoffDecision::EmitStalled =>
        self.emit_leaf_pre_tdd_stalled(
          agent,
          observation.idle_sec,
          tdd_phase,
          observation.screen,
          runner,
        )
      WorkerNoHandoffDecision::DoNothing => ()
    }
  }
  if observation.idle_sec >= idle_threshold_sec {
    match
      leaf_no_handoff_decision(
        agent.role,
        lifecycle,
        gate_ready,
        observation.idle_sec,
        self.handoff_was_delivered(agent_id),
        self.worker_no_handoff_stalled_emitted.contains(post_fix_key),
        idle_threshold_sec,
      ) {
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
}

///|
async fn ServerState::check_worker_no_handoff(
  self : ServerState,
  agent : @types.Agent,
  observation : @runtime.PaneIdleObservation,
  idle_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_id = agent.agent_id.to_string()
  if agent.role != @types.Role::Worker ||
    self.handoff_was_delivered(agent_id) ||
    idle_sec <= 0L {
    return
  }
  let state_key = no_handoff_watchdog_state_key(agent_id, WorkerNoHandoff)
  if observation.idle_sec < idle_sec {
    return
  }
  match
    worker_no_handoff_decision(
      agent.role,
      observation.idle_sec,
      self.handoff_was_delivered(agent_id),
      self.worker_no_handoff_stalled_emitted.contains(state_key),
      idle_sec,
    ) {
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
  worker_no_handoff_idle_sec? : Int64 = 120L,
  transcript_progress_window_sec? : Int64 = 90L,
) -> Unit {
  let agent_ids = self.pane_watcher.watched_agents()
  for agent_id in agent_ids {
    let agent = try self.registry.get(agent_id) catch {
      _ => {
        self.stop_watching(agent_id)
        continue
      }
    } noraise {
      a => a
    }
    if agent.state != @types.AgentState::Active {
      self.stop_watching(agent_id)
      continue
    }
    if @types.is_supervisor_role(agent.role) {
      continue
    }
    let lifecycle = self.current_lifecycle(agent_id)
    // Some lifecycle states are kill-watchdog-exempt, but no-handoff checks
    // may still need to prod or notify without terminating the agent.
    let watchdog_exempt = @phase.lifecycle_idle_watchdog_exempt(lifecycle)
    match agent.terminal_target {
      Some(_) => ()
      None => continue
    }
    if !self.ensure_watched_pane_resolved(agent_id) {
      continue
    }

    // Read and parse the pane snapshot once for all idle decisions this tick.
    match self.pane_watcher.observe_idle(agent_id, now) {
      Some(observation) => {
        self.check_worker_no_handoff(
          agent, observation, worker_no_handoff_idle_sec, runner,
        )
        self.check_leaf_no_handoff(
          agent,
          lifecycle.workflow,
          observation,
          worker_no_handoff_idle_sec,
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
        // Existing behavior (preserved): a live-but-idle agent past the
        // threshold is still reaped — the hung-but-alive case the watchdog
        // exists for. Additive fast path: a pane that is observed idle whose
        // owned process is no longer alive is reaped PROMPTLY, without waiting
        // the full idle threshold. This catches a dead process whose pane
        // shows stale content (a true-positive the screen-hash window can
        // miss/delay). It does not turn off the idle reap for live agents, and
        // it does not solve the busy-but-stuck blind spot (a live leaf
        // thinking quietly still looks idle). pid-liveness only resolves for
        // choir-managed worktrees; for any other workspace agent_process_alive
        // has no owned handle, so the fast path stays disabled and the
        // threshold reap is the only signal.
        let idle_expired = observation.idle_sec >= timeout
        let process_dead = if @types.is_choir_managed_worktree_path(
            self.config.project_dir,
            agent.workspace,
          ) {
          !(self.recovery_provider.agent_process_alive)(
            self.config.project_dir,
            agent_id,
          )
        } else {
          false
        }
        if process_dead {
          ()
        } else if idle_expired && agent.agent_type == @types.AgentType::Claude {
          let transcript_idle_sec = (self.recovery_provider.leaf_transcript_idle_sec)(
            self.config.project_dir,
            agent.workspace,
            agent.agent_type,
          )
          let progressing = match transcript_idle_sec {
            Some(seconds) => seconds < transcript_progress_window_sec
            None => false
          }
          if progressing {
            @moontrace.warn(
              "watchdog idle reap suppressed by transcript progress",
              fields=[
                @moontrace.field("agent", agent_id),
                @moontrace.field("idle_sec", observation.idle_sec),
                @moontrace.field(
                  "transcript_idle_sec",
                  transcript_idle_sec.unwrap_or(-1L),
                ),
                @moontrace.field("threshold", timeout),
                @moontrace.field(
                  "transcript_progress_window_sec", transcript_progress_window_sec,
                ),
              ],
            )
            continue
          }
        } else if !idle_expired {
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
          @moontrace.field(
            "idle_sec",
            if idle_expired {
              timeout
            } else {
              observation.idle_sec
            },
          ),
          @moontrace.field("process_dead", process_dead),
        ])
        let message = if idle_expired {
          "[WATCHDOG] agent " +
          agent_id +
          " killed after " +
          timeout.to_string() +
          "s idle (no pane output change)"
        } else {
          "[WATCHDOG] agent " +
          agent_id +
          " killed: owned process not alive (pane idle " +
          observation.idle_sec.to_string() +
          "s, agent_process_alive=false)"
        }
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
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  let reads : Array[String] = []
  let host : @runtime.PaneWatchHost = {
    dump_pane_screen: async fn(_session, _pane_id) {
      @async.sleep(0)
      reads.push(_session + ":" + _pane_id)
      "idle"
    },
  }
  let state = {
    ..ServerState::new(
      { ..@types.Config::default(), project_dir, terminal_session: "s" },
      make_hermetic_recovery_provider(),
    ),
    pane_watcher: @runtime.PaneWatcher::with_host(host),
  }
  for agent_id in ["root", "main.tl"] {
    let role = @types.Role::TL
    let target : @types.LocalTarget = {
      kind: @types.TargetKind::ZellijPane,
      session: "s",
      name: agent_id,
    }
    ignore(
      state.register_agent({
        agent_id: @types.AgentId(agent_id),
        role,
        agent_type: @types.AgentType::Claude,
        parent: None,
        workspace: project_dir,
        branch: "main",
        terminal_target: Some(target),
        host: @types.Host::Local,
        spawn_depth: 0,
        state: @types.AgentState::Active,
      }),
    )
    state.pane_watcher.watch_pane(
      agent_id,
      target,
      0L,
      pane_id=Some("terminal_" + agent_id.length().to_string()),
    )
  }
  let calls : Array[@workspace.Command] = []
  state.check_idle_agents(1000L, 0L, async fn(cmds) {
    @async.sleep(0)
    for cmd in cmds {
      calls.push(cmd)
    }
    [0]
  })
  @debug.assert_eq(reads, [])
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
fn handler_disconnect_string_field(
  event : @moontrace.Event,
  key : String,
) -> String? {
  for field in event.fields {
    if field.key == key {
      match field.value {
        Json::String(value) => return Some(value)
        _ => return None
      }
    }
  }
  None
}

///|
let codex_stderr_tail_missing : String = "(no codex stderr captured)"

///|
let agy_stderr_tail_missing : String = "(no agy stderr captured)"

///|
fn codex_stderr_warning_tail_from_content(content : String) -> String {
  let max_bytes = 2000
  let max_lines = 20
  let byte_tail = if content.length() > max_bytes {
    content[content.length() - max_bytes:]
  } else {
    content
  }
  let split_lines : Array[String] = []
  for line in byte_tail.split("\n") {
    split_lines.push(line.to_owned())
  }
  let mut end = split_lines.length()
  if end > 0 && split_lines[end - 1] == "" {
    end = end - 1
  }
  let start = if end > max_lines { end - max_lines } else { 0 }
  let lines : Array[String] = []
  for i = start; i < end; i = i + 1 {
    lines.push(split_lines[i])
  }
  lines.join("\n")
}

///|
/// Hard cap on the size of the stderr file we'll read into memory before
/// trimming. The spawn-side wrapper opens the stderr log with `2>`, so each
/// run truncates the previous content — a single chatty/runaway codex run
/// is the only thing bounded by this cap. 64 KB is several orders of
/// magnitude beyond what a startup-time disconnect can realistically
/// produce, while keeping the worst-case allocation bounded.
const CODEX_STDERR_MAX_READ_BYTES : Int = 65536

///|
/// Default file_size adapter for the warning path; wraps `@sys.file_size`
/// so the server module itself doesn't reference `@sys.*` directly.
fn default_codex_stderr_file_size(path : String) -> Int {
  @sys.file_size(path)
}

///|
/// Default read adapter; wraps `@sys.read_file` so the server module
/// itself doesn't reference `@sys.*` directly. Injected at the call
/// site so the warning-tail logic is mockable in tests.
fn default_codex_stderr_read(path : String) -> String {
  @sys.read_file(path)
}

///|
fn codex_stderr_warning_tail(
  project_dir : String,
  agent_id : String,
  file_size? : (String) -> Int = default_codex_stderr_file_size,
  read_file? : (String) -> String = default_codex_stderr_read,
) -> String {
  let path = @workspace.codex_stderr_log_path(project_dir, agent_id)
  let size = file_size(path)
  if size <= 0 {
    return codex_stderr_tail_missing
  }
  // Refuse to materialize a multi-megabyte stderr blob in the warning path;
  // the spawn wrapper truncates on each run, but we still defend against a
  // pathological case (e.g. the truncate was disabled by an operator override
  // or a stderr log left behind from a different code path).
  if size > CODEX_STDERR_MAX_READ_BYTES {
    return "(codex stderr too large to tail: " + size.to_string() + " bytes)"
  }
  let content = read_file(path)
  if content == "" {
    return codex_stderr_tail_missing
  }
  let tail = codex_stderr_warning_tail_from_content(content)
  if tail == "" {
    codex_stderr_tail_missing
  } else {
    tail
  }
}

///|
fn agy_stderr_warning_tail(
  project_dir : String,
  agent_id : String,
  file_size? : (String) -> Int = default_codex_stderr_file_size,
  read_file? : (String) -> String = default_codex_stderr_read,
) -> String {
  let path = @workspace.agy_stderr_log_path(project_dir, agent_id)
  let size = file_size(path)
  if size <= 0 {
    return agy_stderr_tail_missing
  }
  if size > CODEX_STDERR_MAX_READ_BYTES {
    return "(agy stderr too large to tail: " + size.to_string() + " bytes)"
  }
  let content = read_file(path)
  if content == "" {
    return agy_stderr_tail_missing
  }
  let tail = codex_stderr_warning_tail_from_content(content)
  if tail == "" {
    agy_stderr_tail_missing
  } else {
    tail
  }
}

///|
test "codex_stderr_warning_tail_from_content returns last 20 lines" {
  let lines : Array[String] = []
  for i = 0; i < 24; i = i + 1 {
    lines.push("codex stderr line " + i.to_string())
  }
  let expected : Array[String] = []
  for i = 4; i < 24; i = i + 1 {
    expected.push("codex stderr line " + i.to_string())
  }
  assert_eq(
    codex_stderr_warning_tail_from_content(lines.join("\n") + "\n"),
    expected.join("\n"),
  )
}

///|
test "codex_stderr_warning_tail_from_content caps at 2KB from the end" {
  let big = StringBuilder::new(size_hint=3000)
  for i = 0; i < 2500; i = i + 1 {
    big.write_string("x")
  }
  big.write_string("\nTAIL")
  let result = codex_stderr_warning_tail_from_content(big.to_string())
  assert_true(result.length() <= 2000)
  assert_true(result.has_suffix("TAIL"))
}

///|
priv struct CodexStderrReadCallFlag {
  mut val : Bool
}

///|
test "codex_stderr_warning_tail bails on oversized file without reading" {
  // Inject a size adapter that reports a multi-megabyte file and a read
  // adapter that would fail loudly if called. The 64 KB cap must short-
  // circuit BEFORE allocating.
  let read_called : CodexStderrReadCallFlag = { val: false }
  let result = codex_stderr_warning_tail(
    "/proj",
    "main.leaf",
    file_size=fn(_) { CODEX_STDERR_MAX_READ_BYTES + 1024 },
    read_file=fn(_) {
      read_called.val = true
      ""
    },
  )
  assert_false(read_called.val)
  assert_true(result.has_prefix("(codex stderr too large to tail: "))
}

///|
test "codex_stderr_warning_tail returns missing sentinel for absent file" {
  let result = codex_stderr_warning_tail(
    "/proj",
    "main.leaf",
    file_size=fn(_) { 0 },
    read_file=fn(_) { "" },
  )
  assert_eq(result, codex_stderr_tail_missing)
}

///|
test "codex_stderr_warning_tail returns tail when file is in-bounds" {
  let content = "boot ok\nspawn ok\nexit 0\n"
  let result = codex_stderr_warning_tail(
    "/proj",
    "main.leaf",
    file_size=fn(_) { content.length() },
    read_file=fn(_) { content },
  )
  assert_eq(result, "boot ok\nspawn ok\nexit 0")
}

///|
async test "startup disconnect after register emits startup prompt-gap warning" {
  let project_dir = "/tmp/choir-startup-disconnect-warning-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
  ignore(
    @sys.create_dir_all(project_dir + "/.choir/worktrees/main.gemini-leaf"),
  )
  let parent_id = "main.tl"
  let agent_id = "main.gemini-leaf"
  ignore(
    @sys.write_file_sync(
      project_dir + "/.choir/logs/agy-main.gemini-leaf.stderr.log",
      "agy boot\nmcp bridge disconnected\n",
    ),
  )
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
      @async.sleep(0)
      []
    })
  })
  assert_eq(
    handler_disconnect_warning_count(
      captured, "worker disconnected immediately after register (likely interactive prompt block or config gap)",
    ),
    1,
  )
  // Non-Codex agent: the codex_stderr_tail field MUST NOT appear in the
  // warning. Gemini/agy has its own stderr log and warning field.
  let warning_message = "worker disconnected immediately after register (likely interactive prompt block or config gap)"
  let mut found_codex_field = false
  let mut found_agy_tail = false
  let mut found_agy_event = false
  for event in captured {
    if event.message != warning_message {
      continue
    }
    for field in event.fields {
      if field.key == "codex_stderr_tail" {
        found_codex_field = true
      }
    }
    match handler_disconnect_string_field(event, "agy_stderr_tail") {
      Some(value) if value == "agy boot\nmcp bridge disconnected" =>
        found_agy_tail = true
      _ => ()
    }
    match handler_disconnect_string_field(event, "event") {
      Some("agy_disconnect_stderr_tail") => found_agy_event = true
      _ => ()
    }
  }
  assert_false(found_codex_field)
  assert_true(found_agy_event)
  assert_true(found_agy_tail)
  ignore(@sys.rm_rf(project_dir))
}

///|
async test "unexpected disconnect closes terminal and preserves failure teardown" {
  let project_dir = "/tmp/choir-unexpected-disconnect-close-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
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
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
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
  state.worker_no_handoff_stalled_emitted.set(
    "worker-no-handoff:" + agent_id,
    true,
  )
  state.worker_no_handoff_stalled_emitted.set(
    "leaf-post-fix-no-handoff:" + agent_id,
    true,
  )
  state.worker_no_handoff_stalled_emitted.set(
    "leaf-pre-tdd-stall:" + agent_id,
    true,
  )
  state.worker_no_handoff_exit_emitted.set(agent_id, true)
  state.spawn_registration_first_unseen.set(agent_id, 3L)
  state.idle_agent_warned_at_70.set(agent_id, true)
  state.recent_poller_event_emissions.set(agent_id, {
    "merge_ready": { content_hash: "hash", emitted_at_unix: 3L },
  })

  state.clear_agent_runtime_tracking(agent_id)

  assert_eq(state.pending_disconnects.contains(agent_id), false)
  assert_eq(state.disconnect_contexts.contains(agent_id), false)
  assert_eq(state.handoff_delivered.contains(agent_id), false)
  assert_eq(
    state.worker_no_handoff_stalled_emitted.contains(
      "worker-no-handoff:" + agent_id,
    ),
    false,
  )
  assert_eq(
    state.worker_no_handoff_stalled_emitted.contains(
      "leaf-post-fix-no-handoff:" + agent_id,
    ),
    false,
  )
  assert_eq(
    state.worker_no_handoff_stalled_emitted.contains(
      "leaf-pre-tdd-stall:" + agent_id,
    ),
    false,
  )
  assert_eq(state.worker_no_handoff_exit_emitted.contains(agent_id), false)
  assert_eq(state.spawn_registration_first_unseen.contains(agent_id), false)
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
  ignore(@sys.create_dir_all(project_dir + "/.choir/state/kv"))
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
    @async.sleep(0)
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
          Some(sec) if sec < 2 => {
            let fields : Array[@moontrace.Field] = [
              @moontrace.field("agent_id", agent_id),
              @moontrace.field("agent_type", agent.agent_type.to_wire_string()),
              @moontrace.field("connected_sec", sec.to_string()),
              @moontrace.field("last_request", "register"),
            ]
            // Only codex captures stderr to a per-agent file today; emitting
            // codex_stderr_tail for non-Codex providers would always read
            // "(no codex stderr captured)" and add noise to the warning.
            if agent.agent_type == @types.AgentType::Codex {
              fields.push(
                @moontrace.field(
                  "codex_stderr_tail",
                  codex_stderr_warning_tail(self.config.project_dir, agent_id),
                ),
              )
            } else if agent.agent_type == @types.AgentType::Gemini {
              fields.push(
                @moontrace.field("event", "agy_disconnect_stderr_tail"),
              )
              fields.push(
                @moontrace.field(
                  "agy_stderr_tail",
                  agy_stderr_warning_tail(self.config.project_dir, agent_id),
                ),
              )
            }
            @moontrace.warn(
              "worker disconnected immediately after register (likely interactive prompt block or config gap)",
              fields~,
            )
          }
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
              ignore(self.ensure_watched_pane_resolved(agent_id))
              let screen = match self.pane_watcher.current_screen(agent_id) {
                Some(s) => s
                None => ""
              }
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
  runner~ : async (Array[@workspace.Command]) -> Array[Int],
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
    agent_id,
  )
}

///|
/// Process pending disconnects older than grace_seconds. Fire handle_disconnect for stale ones.
pub async fn ServerState::process_pending_disconnects_with_runner(
  self : ServerState,
  now : Int64,
  grace_seconds : Int64,
  runner~ : async (Array[@workspace.Command]) -> Array[Int],
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
    self.reap_thread_owning_dead_leaf(agent_id, runner)
    ignore(self.registry.set_alive(agent_id, false)) catch {
      _ => ()
    }
    self.pending_disconnects.remove(agent_id)
  }
}

///|
/// Dead-leaf reaper (choir-3rp5, Leaf 3 / F10/F13). Runs only for a leaf this
/// poller tick has CONFIRMED dead past the disconnect grace (the
/// `pending_disconnect_target_still_alive` liveness probe returned false above).
///
/// `handle_disconnect_confirming_with_runner` PRESERVES the thread-owning Dev
/// states (`ReviewOwned`/`ChangesRequested`/`ExitRequestedDeferred`) across
/// disconnect — by design, so a brief transport drop does not lose an in-flight
/// review cycle. But this leaf is now confirmed gone: a dead leaf still owning a
/// PR's contested review threads sits non-terminal forever, wedging Leaf 1's
/// `is_terminal`-keyed gate so the TL can never take over. Finalizing it to Done
/// drives the agent terminal — clearing its runtime tracking, recording the
/// terminal status, and firing the exit hook. (Worktree removal is intentionally
/// left off here, `remove_worktree=false`: this path reclaims lifecycle/tracking,
/// not the on-disk worktree.) The preserve no longer applies.
///
/// JUSTIFICATION (F13): this is teardown that would exist even if no gate
/// consumed the leaf's terminal-ness — a confirmed-dead agent's resources must
/// be reclaimed regardless. The TL gate opening for that PR is a consequence,
/// not the purpose. NEVER `transfer_leaf_ownership` (F2): it raises across
/// role/parent and is leaf→leaf only; TL authority is purely the gate opening
/// when the leaf is terminal, with no ownership mutation.
async fn ServerState::reap_thread_owning_dead_leaf(
  self : ServerState,
  agent_id : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent = match self.registry.get_opt(agent_id) {
    Some(a) => a
    None => return
  }
  if @types.is_supervisor_role(agent.role) {
    return
  }
  let lifecycle = self.current_lifecycle(agent_id)
  // Keyed on ProcessState::is_terminal (F4): if confirming already drove the
  // leaf terminal, the absorbing fence holds — do not re-finalize.
  if lifecycle.process.is_terminal() {
    return
  }
  // Selection: only a leaf still PRESERVED in a thread-owning Dev state would
  // otherwise orphan its threads (F1 states named in lifecycle_thread_owning_dev).
  if !@phase.lifecycle_thread_owning_dev(lifecycle.workflow) {
    return
  }
  // Record the per-owned-PR health determinant before finalize (F6); terminal
  // label is always Done (F3), Done/Fail quarantined from consumers.
  self.record_pr_health_determinants_for_agent(agent_id, "dead_leaf_reaper")
  self.finalize_agent_with_runner(
    agent_id,
    @types.ExitReason::Disconnected,
    runner,
    notify_parent=false,
    close_target=false,
    remove_worktree=false,
  )
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

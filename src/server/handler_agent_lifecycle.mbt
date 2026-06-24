///|
fn lifecycle_for_registered_agent(
  existing : @phase.AgentLifecycle,
) -> @phase.AgentLifecycle {
  match existing.process {
    @phase.ProcessState::Disconnected(..) =>
      { ..existing, process: @phase.ProcessState::Connected }
    // All terminal states are absorbing on fresh register (choir-3rp5, F5/RA-1):
    // `is_terminal` includes `Finalizing`, the handoff instant, so a fresh
    // register must not resurrect it to `Connected` or the single-writer gate
    // would see a "live" leaf the TL already inherited. Mirrors the absorbing
    // reconnect door in `lifecycle_transport_reconnect`.
    @phase.ProcessState::Finalizing(..) => existing
    @phase.ProcessState::Finalized(..) => existing
    @phase.ProcessState::Failed(..) => existing
    _ => { ..existing, process: @phase.ProcessState::Connected }
  }
}

///|
test "register door keeps a Finalizing agent terminal (no resurrection)" {
  let base = @phase.lifecycle_for_role("main.leaf", @types.Role::Dev)
  let finalizing = {
    ..base,
    process: @phase.ProcessState::Finalizing(
      reason=@phase.FinalizeReason::RecoveredDone,
    ),
  }
  let after = lifecycle_for_registered_agent(finalizing)
  assert_true(after.process.is_terminal())
  match after.process {
    @phase.ProcessState::Finalizing(..) => ()
    other => fail("expected Finalizing preserved, got " + other.to_string())
  }
}

///|
test "register door preserves Finalized and Failed but reconnects others" {
  let base = @phase.lifecycle_for_role("main.leaf", @types.Role::Dev)
  let finalized = {
    ..base,
    process: @phase.ProcessState::Finalized(
      reason=@phase.FinalizeReason::RecoveredDone,
    ),
  }
  assert_true(lifecycle_for_registered_agent(finalized).process.is_terminal())
  let failed = {
    ..base,
    process: @phase.ProcessState::Failed(
      reason=@phase.FailureReason::RecoveredFailed,
    ),
  }
  assert_true(lifecycle_for_registered_agent(failed).process.is_terminal())
  let disconnected = {
    ..base,
    process: @phase.ProcessState::Disconnected(disconnected_at_unix_sec=0L),
  }
  match lifecycle_for_registered_agent(disconnected).process {
    @phase.ProcessState::Connected => ()
    other =>
      fail("expected Disconnected to reconnect, got " + other.to_string())
  }
}

///|
pub fn ServerState::register_agent(
  self : ServerState,
  agent : @types.Agent,
) -> Unit {
  self.clear_pending_disconnect(agent.agent_id.to_string())
  let agent_id = agent.agent_id.to_string()
  self.spawn_launch_diagnostics.remove(agent_id)
  let lifecycle = match
    @phase.read_lifecycle(self.config.project_dir, agent_id) {
    Some(existing) => lifecycle_for_registered_agent(existing)
    None => @phase.lifecycle_for_agent(agent)
  }
  let existed = self.registry.get_opt(agent_id) is Some(_)
  if !existed {
    ignore(self.registry.upsert(agent))
  }
  ignore(
    @phase.persist_lifecycle(self.config.project_dir, self.registry, lifecycle),
  )
  if existed {
    let state = match self.registry.get_opt(agent_id) {
      Some(current) => current.state
      None => lifecycle.to_agent_state()
    }
    ignore(self.registry.upsert({ ..agent, state, }))
  }
  @phase.sync_parent_child_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    agent_id,
    lifecycle,
  )
}

///|
pub async fn ServerState::apply_recovered_agent(
  self : ServerState,
  agent : @types.Agent,
  alive : Bool,
) -> Unit {
  try {
    self.register_agent(agent)
    if alive && agent.terminal_target is Some(_) {
      self.watch_pane(agent.agent_id.to_string())
    }
    if !alive {
      ignore(self.registry.set_alive(agent.agent_id.to_string(), false))
    }
  } catch {
    _ => ()
  }
}

///|
pub fn ServerState::restore_recovered_pr_tracking(
  self : ServerState,
  tracked : @poller.TrackedPR,
) -> Unit {
  self.poller.restore(tracked)
}

///|
pub fn ServerState::track_recovered_pr(
  self : ServerState,
  pr_number : Int,
  agent_id : String,
  branch : String,
  parent_branch : String,
  pr_url : String,
  created_at : Int64,
  review : @poller.ReviewState,
  review_bodies : String,
  sha : String,
  ci_rollup : @poller.CiRollupStatus,
  copilot_issue_comment_seen : Bool,
) -> Unit {
  let review_mode = match self.poller.get(pr_number) {
    Some(existing) => existing.review_mode
    None => {
      let agent_workspace = Some(self.registry.get(agent_id).workspace) catch {
        _ => None
      }
      @workspace.review_mode_for_agent_workspace(
        self.config.project_dir,
        agent_workspace,
        @phase.extract_slug(agent_id),
        agent_id=Some(agent_id),
        global_review_mode=self.config.review_mode,
      )
    }
  }
  self.poller.track_recovered(
    pr_number,
    agent_id,
    branch,
    parent_branch,
    pr_url,
    created_at,
    review,
    review_bodies,
    sha,
    ci_rollup,
    copilot_issue_comment_seen,
    review_mode~,
  )
}

///|
pub fn ServerState::sync_recovered_pr_lifecycle(
  self : ServerState,
  agent_id : String,
  pr : @runtime.OpenPR,
  review : @poller.ReviewState,
) -> Unit {
  let agent_opt = try self.registry.get(agent_id) catch {
    _ => None
  } noraise {
    a => Some(a)
  }
  let lifecycle = self.current_lifecycle(agent_id)
  let workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(dev) =>
      @phase.WorkflowState::Dev(
        @runtime.recover_dev_lifecycle_for_pr(dev, pr.pr_number, pr.url, review),
      )
    other => other
  }
  let recovered = {
    ..lifecycle,
    workflow,
    process: match agent_opt {
      Some(agent) if agent.terminal_target is Some(_) =>
        @phase.ProcessState::Connected
      _ => lifecycle.process
    },
  }
  @phase.apply_recovered_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    agent_id,
    recovered,
  )
}

///|
pub fn ServerState::finalize_recovered_offline_agent(
  self : ServerState,
  agent_id : String,
) -> Unit {
  let lifecycle = self.current_lifecycle(agent_id)
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => ()
    _ => {
      let finalized = {
        ..lifecycle,
        process: @phase.ProcessState::Finalized(
          reason=@phase.FinalizeReason::RecoveredDone,
        ),
      }
      @phase.apply_recovered_lifecycle(
        self.config.project_dir,
        self.config.terminal_session,
        self.registry,
        agent_id,
        finalized,
      )
    }
  }
}

///|
pub fn ServerState::persist_recovered_poller_state(self : ServerState) -> Unit {
  ignore(self.poller.write_state_file(self.config.project_dir))
}

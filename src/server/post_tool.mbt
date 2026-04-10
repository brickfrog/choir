///|
pub(all) enum MergedDeliverySource {
  MergePrTool
  ExternalObservation
} derive(Debug, Eq)

///|
pub(all) enum TeardownEffect {
  PersistLifecycle(
    agent_id~ : String,
    lifecycle~ : @phase.AgentLifecycle,
    trigger~ : @types.LifecycleTrigger
  )
  SyncParentLifecycle(agent_id~ : String, lifecycle~ : @phase.AgentLifecycle)
  NotifyParent(
    parent_id~ : String,
    agent_id~ : String,
    message~ : String,
    status~ : @types.Status
  )
  RemoveTeamMember(parent_id~ : String, slug~ : String)
  FireHook(
    agent_id~ : String,
    role~ : @types.Role,
    exit_reason~ : @types.ExitReason
  )
  RemoveWorktree(String)
  CloseTerminal(@types.LocalTarget)
  InjectTerminalMessage(@types.LocalTarget, String)
  ClearRuntimeTracking(String)
  WatchPane(agent_id~ : String)
  UpdateDevLifecycle(agent_id~ : String, event~ : @phase.DevEvent)
  DeliverToParentMerged(
    leaf_id~ : String,
    pr_number~ : Int,
    branch~ : String,
    parent_branch~ : String,
    url~ : String,
    source~ : MergedDeliverySource,
    merge_execution_mode~ : @evidence.MergeExecutionMode?,
    parent_id~ : String?
  )
  /// If primary parent notification used a non-terminal channel, optionally echo failure text
  /// to the parent's terminal. Interpretation calls `plan_delivery` (not the planner).
  ParentFailureTerminalEchoIfNeeded(
    parent_id~ : String,
    agent_id~ : String,
    parent_message~ : String,
    reason~ : @phase.FailureReason
  )
  RefreshPR(Int)
} derive(Debug, Eq)

///|
fn finalize_reason_for_exit(
  exit_reason : @types.ExitReason,
) -> @phase.FinalizeReason {
  match exit_reason {
    @types.ExitReason::Merged => @phase.FinalizeReason::Merged
    @types.ExitReason::Disconnected =>
      @phase.FinalizeReason::DisconnectFinalized
    @types.ExitReason::Shutdown => @phase.FinalizeReason::Shutdown
  }
}

///|
/// Builds teardown steps from in-memory `agent` and `lifecycle` values only (no registry I/O).
/// Interpretation may re-resolve parents and persist using current server state.
pub fn plan_finalize(
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  exit_reason : @types.ExitReason,
  notify_parent? : Bool = false,
  close_target? : Bool = true,
  remove_worktree? : Bool = true,
) -> Array[TeardownEffect] {
  let agent_id = agent.agent_id.to_string()
  let effects : Array[TeardownEffect] = []
  let finalize_reason = finalize_reason_for_exit(exit_reason)
  let allow_merge_refinalize = exit_reason == @types.ExitReason::Merged

  match lifecycle.process {
    @phase.ProcessState::Failed(..) => {
      effects.push(ClearRuntimeTracking(agent_id))
      return effects
    }
    @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged) => {
      effects.push(ClearRuntimeTracking(agent_id))
      return effects
    }
    @phase.ProcessState::Finalized(..) =>
      if !allow_merge_refinalize {
        effects.push(ClearRuntimeTracking(agent_id))
        return effects
      }
    _ => ()
  }

  // State Transition to Finalizing
  let with_finalizing = {
    ..lifecycle,
    process: @phase.ProcessState::Finalizing(reason=finalize_reason),
  }
  effects.push(
    PersistLifecycle(
      agent_id~,
      lifecycle=with_finalizing,
      trigger=exit_reason.lifecycle_trigger(),
    ),
  )

  // Notify Parent
  if notify_parent {
    match agent.parent {
      Some(parent_id) => {
        effects.push(
          RemoveTeamMember(parent_id~, slug=@phase.extract_slug(agent_id)),
        )
        effects.push(
          NotifyParent(
            parent_id~,
            agent_id~,
            message="agent shutdown",
            status=@types.Status::Success,
          ),
        )
      }
      None => ()
    }
  }

  // Hook
  effects.push(FireHook(agent_id~, role=agent.role, exit_reason~))

  // Cleanup
  if remove_worktree && agent.workspace.contains(".choir/worktrees/") {
    effects.push(RemoveWorktree(agent.workspace))
  }
  if close_target {
    match agent.terminal_target {
      Some(target) => effects.push(CloseTerminal(target))
      None => ()
    }
  }

  // Final Transition to Finalized
  let finalized_workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(_) =>
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=finalize_reason),
      )
    @phase.WorkflowState::Worker(_) =>
      @phase.WorkflowState::Worker(
        @phase.WorkerLifecycle::Done(reason=finalize_reason),
      )
    @phase.WorkflowState::Supervisor(_) =>
      @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Done)
  }
  let finalized = {
    ..lifecycle,
    process: @phase.ProcessState::Finalized(reason=finalize_reason),
    workflow: finalized_workflow,
  }
  effects.push(
    PersistLifecycle(
      agent_id~,
      lifecycle=finalized,
      trigger=@types.LifecycleTrigger::FinalizeComplete,
    ),
  )
  effects.push(SyncParentLifecycle(agent_id~, lifecycle=finalized))
  effects.push(ClearRuntimeTracking(agent_id))

  effects
}

///|
fn lifecycle_accepts_merge_observed(
  lifecycle : @phase.AgentLifecycle,
  pr_number : Int,
) -> Bool {
  match
    @phase.plan_dev_event_checked(
      lifecycle,
      @phase.DevEvent::MergeObserved(pr_number~),
    ) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn merged_provenance_label(
  source : MergedDeliverySource,
  merge_execution_mode : @evidence.MergeExecutionMode?,
) -> String {
  match source {
    ExternalObservation => "external_observation"
    MergePrTool =>
      match merge_execution_mode {
        Some(@evidence.MergeExecutionMode::ServerAutomerge) =>
          "server_automerge"
        Some(@evidence.MergeExecutionMode::ForceOverride) => "force_override"
        _ => "merge_pr"
      }
  }
}

///|
fn merged_summary_line(
  source : MergedDeliverySource,
  merge_execution_mode : @evidence.MergeExecutionMode?,
) -> String {
  match source {
    ExternalObservation =>
      "Authoritative: external merge observed; automatic reconciliation finalized the leaf."
    MergePrTool =>
      match merge_execution_mode {
        Some(@evidence.MergeExecutionMode::ServerAutomerge) =>
          "Authoritative: server automerge succeeded; no TL merge action was required."
        Some(@evidence.MergeExecutionMode::ForceOverride) =>
          "Authoritative: merge_pr force=true succeeded; merge policy was overridden explicitly."
        _ =>
          "Authoritative: merge_pr succeeded; the leaf is finalized and cleaned up."
      }
  }
}

///|
fn merged_override_reason_line(
  source : MergedDeliverySource,
  merge_execution_mode : @evidence.MergeExecutionMode?,
) -> String? {
  match (source, merge_execution_mode) {
    (MergePrTool, Some(@evidence.MergeExecutionMode::ForceOverride)) =>
      Some("policy_override: merge_pr invoked with force=true")
    _ => None
  }
}

///|
pub fn plan_external_merge_finalization(
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  pr_number : Int,
  branch : String,
  parent_branch : String,
  url : String,
  notify_parent? : Bool = true,
) -> Array[TeardownEffect] {
  let agent_id = agent.agent_id.to_string()
  match lifecycle.process {
    @phase.ProcessState::Failed(..)
    | @phase.ProcessState::Finalized(reason=@phase.FinalizeReason::Merged) =>
      [ClearRuntimeTracking(agent_id)]
    _ => {
      let effects : Array[TeardownEffect] = []
      if lifecycle_accepts_merge_observed(lifecycle, pr_number) {
        effects.push(
          UpdateDevLifecycle(
            agent_id~,
            event=@phase.DevEvent::MergeObserved(pr_number~),
          ),
        )
      }
      if notify_parent {
        effects.push(
          DeliverToParentMerged(
            leaf_id=agent_id,
            pr_number~,
            branch~,
            parent_branch~,
            url~,
            source=MergedDeliverySource::ExternalObservation,
            merge_execution_mode=None,
            parent_id=agent.parent,
          ),
        )
      }
      for
        effect in plan_finalize(
          agent,
          lifecycle,
          @types.ExitReason::Merged,
          notify_parent=false,
        ) {
        effects.push(effect)
      }
      effects
    }
  }
}

///|
/// Side-effect free aside from constructing effects. Parent delivery edge cases that need
/// `plan_delivery` run in `interpret_teardown_effects` via `ParentFailureTerminalEchoIfNeeded`.
pub fn plan_fail(
  agent : @types.Agent,
  lifecycle : @phase.AgentLifecycle,
  reason : @phase.FailureReason,
  parent_message : String,
  exit_reason : @types.ExitReason,
  parent : @types.Agent?,
  close_target? : Bool = false,
) -> Array[TeardownEffect] {
  let agent_id = agent.agent_id.to_string()
  let effects : Array[TeardownEffect] = []

  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => {
      effects.push(ClearRuntimeTracking(agent_id))
      return effects
    }
    _ => ()
  }

  // Hook
  effects.push(FireHook(agent_id~, role=agent.role, exit_reason~))

  // Cleanup
  if close_target {
    match agent.terminal_target {
      Some(target) => effects.push(CloseTerminal(target))
      None => ()
    }
  }

  // Transition to Failed
  let failed_workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(_) =>
      @phase.WorkflowState::Dev(@phase.DevLifecycle::Failed(reason~))
    @phase.WorkflowState::Worker(_) =>
      @phase.WorkflowState::Worker(@phase.WorkerLifecycle::Failed(reason~))
    @phase.WorkflowState::Supervisor(_) =>
      @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Failed(reason~),
      )
  }
  let failed = {
    ..lifecycle,
    process: @phase.ProcessState::Failed(reason~),
    workflow: failed_workflow,
  }
  effects.push(
    PersistLifecycle(
      agent_id~,
      lifecycle=failed,
      trigger=exit_reason.lifecycle_trigger(),
    ),
  )
  effects.push(SyncParentLifecycle(agent_id~, lifecycle=failed))

  // Notify Parent (secondary terminal echo decided at interpret time; see
  // `ParentFailureTerminalEchoIfNeeded`.)
  match parent {
    Some(p) => {
      let parent_id = p.agent_id.to_string()
      effects.push(
        NotifyParent(
          parent_id~,
          agent_id~,
          message=parent_message,
          status=@types.Status::Failure,
        ),
      )
      effects.push(
        ParentFailureTerminalEchoIfNeeded(
          parent_id~,
          agent_id~,
          parent_message~,
          reason~,
        ),
      )
    }
    None => ()
  }

  effects.push(ClearRuntimeTracking(agent_id))

  effects
}

///|
fn resolve_parent_for_plan_fail(
  project_dir : String,
  terminal_session : String,
  registry : @registry.AgentRegistry,
  agent : @types.Agent,
) -> @types.Agent? {
  match agent.parent {
    Some(parent_id) =>
      try
        @phase.resolve_agent_with_fallback(
          project_dir, terminal_session, registry, parent_id,
        )
      catch {
        _ => None
      } noraise {
        p => Some(p)
      }
    None => None
  }
}

///|
/// Returns effects from a consistent snapshot taken immediately before interpretation in
/// `handle_with_runner` (same synchronous turn, no await between plan and interpret). Lifecycle
/// rows come from disk via `read_or_default_lifecycle`; registry rows come from `registry.get`.
/// The interpreter re-reads the registry where required (e.g. parent resolution) so delivery
/// targets match current registration, matching the prior `PostToolAction` behavior.
pub fn plan_post_tool_actions(
  req : @types.Request,
  resp : @types.Response,
  merged_agent_id~ : String?,
  poller : @poller.PollerState,
  registry : @registry.AgentRegistry,
  project_dir : String,
  terminal_session : String,
) -> Array[TeardownEffect] {
  let effects : Array[TeardownEffect] = []
  if !resp.is_ok() {
    return effects
  }

  // shutdown
  if req.name == "shutdown" {
    match request_agent_id(req) {
      Some(agent_id) =>
        match resp.ok_field("status") {
          Some("shutdown") =>
            try {
              let agent = registry.get(agent_id)
              let lifecycle = @phase.read_or_default_lifecycle(
                project_dir,
                agent_id,
                agent.role,
              )
              for
                e in plan_finalize(
                  agent,
                  lifecycle,
                  @types.ExitReason::Shutdown,
                  notify_parent=true,
                ) {
                effects.push(e)
              }
            } catch {
              _ => effects.push(ClearRuntimeTracking(agent_id))
            }
          _ => ()
        }
      None => ()
    }
  }

  // merge_pr
  if req.name == "merge_pr" {
    match (request_int_arg(req, "pr_number"), merged_agent_id) {
      (Some(pr_number), Some(agent_id)) => {
        effects.push(
          UpdateDevLifecycle(
            agent_id~,
            event=@phase.DevEvent::MergeObserved(pr_number~),
          ),
        )
        try {
          let leaf = registry.get(agent_id)
          let (branch, parent_branch, url) = match poller.get(pr_number) {
            Some(t) => (t.branch, t.parent_branch, t.pr_url)
            None => (leaf.branch, "", "")
          }
          effects.push(
            DeliverToParentMerged(
              leaf_id=agent_id,
              pr_number~,
              branch~,
              parent_branch~,
              url~,
              source=MergedDeliverySource::MergePrTool,
              merge_execution_mode=Some(
                if request_bool_arg(req, "force").unwrap_or(false) {
                  @evidence.MergeExecutionMode::ForceOverride
                } else if request_bool_arg(req, "automerge").unwrap_or(false) {
                  @evidence.MergeExecutionMode::ServerAutomerge
                } else {
                  @evidence.MergeExecutionMode::Manual
                },
              ),
              parent_id=leaf.parent,
            ),
          )
          let lifecycle = @phase.read_or_default_lifecycle(
            project_dir,
            agent_id,
            leaf.role,
          )
          for
            e in plan_finalize(
              leaf,
              lifecycle,
              @types.ExitReason::Merged,
              notify_parent=false,
            ) {
            effects.push(e)
          }
        } catch {
          _ => effects.push(ClearRuntimeTracking(agent_id))
        }
      }
      _ => ()
    }
  }

  // kill_agent
  if req.name == "kill_agent" {
    match req.args.get("agent_id") {
      Some(agent_id) =>
        try {
          let agent = registry.get(agent_id)
          let lifecycle = @phase.read_or_default_lifecycle(
            project_dir,
            agent_id,
            agent.role,
          )
          let parent = resolve_parent_for_plan_fail(
            project_dir, terminal_session, registry, agent,
          )
          for
            e in plan_fail(
              agent,
              lifecycle,
              @phase.FailureReason::ParentKilled,
              "agent killed by parent",
              @types.ExitReason::Shutdown,
              parent,
              close_target=false,
            ) {
            effects.push(e)
          }
        } catch {
          _ => effects.push(ClearRuntimeTracking(agent_id))
        }
      None => ()
    }
  }

  // spawn/rescue pane watchers
  if req.name == "fork_wave" ||
    req.name == "spawn_worker" ||
    req.name == "rescue_leaf" {
    let watch_ids : Array[String] = []
    match resp.ok_field("agent_ids") {
      Some(ids) =>
        for part in ids.split(",") {
          let agent_id = part.to_string().trim().to_string()
          if agent_id != "" {
            watch_ids.push(agent_id)
          }
        }
      None => ()
    }
    if req.name == "rescue_leaf" {
      match resp.ok_field("agent_id") {
        Some(agent_id) => {
          let aid = agent_id.trim().to_string()
          if aid != "" {
            watch_ids.push(aid)
          }
        }
        None => ()
      }
    }
    for agent_id in watch_ids {
      effects.push(WatchPane(agent_id~))
    }
  }

  // resolve_review_thread
  if req.name == "resolve_review_thread" {
    match request_agent_id(req) {
      Some(agent_id) =>
        for pr in poller.tracked.values() {
          if pr.agent_id == agent_id {
            effects.push(RefreshPR(pr.pr_number))
          }
        }
      None => ()
    }
  }
  effects
}

///|
/// Parent-facing text after `merge_pr` tool succeeds — distinct from poller pre-merge signals.
pub fn merged_pr_parent_message(
  pr_number : Int,
  leaf_agent_id : String,
  branch : String,
  parent_branch : String,
  pr_url : String,
  source : MergedDeliverySource,
  merge_execution_mode? : @evidence.MergeExecutionMode? = None,
) -> String {
  let branch_disp = if branch == "" { "<unknown>" } else { branch }
  let parent_disp = if parent_branch == "" {
    "<unknown>"
  } else {
    parent_branch
  }
  let lines : Array[String] = [
    "[PR MERGED] " +
    leaf_agent_id +
    " PR #" +
    pr_number.to_string() +
    " is merged on the remote.",
    "branch: " + branch_disp,
    "parent_branch: " + parent_disp,
    "merge_provenance: " + merged_provenance_label(source, merge_execution_mode),
    merged_summary_line(source, merge_execution_mode),
  ]
  match merged_override_reason_line(source, merge_execution_mode) {
    Some(line) => lines.push(line)
    None => ()
  }
  if pr_url != "" {
    lines.push("pr_url: " + pr_url)
  }
  lines.join("\n")
}

///|
pub async fn best_effort_release_chainlink_lock_for_agent(
  project_dir : String,
  agent : @types.Agent,
  read_chainlink_issue_id? : (String, String?, String) -> String? = @workspace.chainlink_issue_id_for_agent_workspace,
  release_lock? : async (String) -> Bool = @chainlink.release_lock,
) -> Unit {
  match
    read_chainlink_issue_id(
      project_dir,
      Some(agent.workspace),
      @phase.extract_slug(agent.agent_id.to_string()),
    ) {
    Some(issue_id) => {
      let released = release_lock(issue_id) catch { _ => false }
      if !released {
        @sys.write_stderr(
          "[chainlink] warn: lock release failed for issue " + issue_id + "\n",
        )
      }
    }
    None => ()
  }
}

///|
pub impl Show for TeardownEffect with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

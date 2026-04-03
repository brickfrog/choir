///|
fn supervisor_role_for_scope(_scope : String) -> @types.Role {
  // Default to TL; do not infer Root purely from scope == "root".
  @types.Role::TL
}

///|
fn child_summary_for_slug(
  children : Array[ChildLifecycle],
  slug : String,
) -> (String, ChildLifecycleSummary)? {
  for child in children {
    if child.slug == slug || child.branch == slug || child.child_id == slug {
      return Some((child.child_id, child.summary))
    }
  }
  None
}

///|
fn child_summary_terminal(summary : ChildLifecycleSummary) -> Bool {
  match summary {
    ChildLifecycleSummary::Done => true
    ChildLifecycleSummary::Failed(_) => true
    _ => false
  }
}

///|
fn all_children_terminal(children : Array[ChildLifecycle]) -> Bool {
  for child in children {
    if !child_summary_terminal(child.summary) {
      return false
    }
  }
  true
}

///|
fn promote_if_wave_complete(
  supervisor : SupervisorLifecycle,
) -> SupervisorLifecycle {
  match supervisor {
    SupervisorLifecycle::Supervising(children~, ..) =>
      if all_children_terminal(children) {
        match
          supervisor_transition(
            supervisor,
            SupervisorEvent::AllChildrenComplete,
          ) {
          Transitioned(next) => next
          InvalidTransition(_) => supervisor
        }
      } else {
        supervisor
      }
    _ => supervisor
  }
}

///|
fn legacy_dev_phase_from_lifecycle(lifecycle : DevLifecycle) -> DevPhase {
  match lifecycle {
    DevLifecycle::Working => DevPhase::Working
    DevLifecycle::ReviewOwned(
      pr_number~,
      state=ReviewOwnership::OpenUnreviewed(url~)
    ) => DevPhase::PROpenUnreviewed(pr_number~, url~)
    DevLifecycle::ReviewOwned(
      pr_number~,
      state=ReviewOwnership::FixesAwaitingReview(round~)
    ) => DevPhase::FixesPushedAwaitingReview(pr_number~, round~)
    DevLifecycle::ReviewOwned(
      pr_number~,
      state=ReviewOwnership::ApprovedAwaitingMerge
    ) => DevPhase::ApprovedAwaitingMerge(pr_number~)
    DevLifecycle::ChangesRequested(pr_number~, ..) =>
      DevPhase::ChangesRequested(pr_number~)
    DevLifecycle::ExitRequestedDeferred(
      pr_number~,
      state=ReviewOwnership::OpenUnreviewed(url~)
    ) =>
      DevPhase::ExitRequestedDeferred(
        pr_number~,
        stage=DevStage::PROpenUnreviewed,
        round=0,
        url~,
      )
    DevLifecycle::ExitRequestedDeferred(
      pr_number~,
      state=ReviewOwnership::FixesAwaitingReview(round~)
    ) =>
      DevPhase::ExitRequestedDeferred(
        pr_number~,
        stage=DevStage::FixesPushedAwaitingReview,
        round~,
        url="",
      )
    DevLifecycle::ExitRequestedDeferred(
      pr_number~,
      state=ReviewOwnership::ApprovedAwaitingMerge
    ) =>
      DevPhase::ExitRequestedDeferred(
        pr_number~,
        stage=DevStage::ApprovedAwaitingMerge,
        round=0,
        url="",
      )
    DevLifecycle::Exitable => DevPhase::Exitable
    DevLifecycle::Done(..) => DevPhase::Done
    DevLifecycle::Failed(reason~) =>
      DevPhase::Failed(reason=failure_reason_message(reason))
  }
}

///|
fn tl_event_trigger(event : TLEvent) -> @types.LifecycleTrigger {
  match event {
    TLEvent::ChildSpawned(_) => @types.LifecycleTrigger::ChildSpawned
    TLEvent::ChildCompleted(_) => @types.LifecycleTrigger::ChildCompleted
    TLEvent::ChildFailed(_, ..) => @types.LifecycleTrigger::ChildFailed
    TLEvent::PRMerged(..) => @types.LifecycleTrigger::PRMerged
    TLEvent::AllChildrenDone => @types.LifecycleTrigger::AllChildrenDone
    TLEvent::OwnPRFiled(..) => @types.LifecycleTrigger::OwnPRFiled
  }
}

///|
fn dev_event_trigger(event : DevEvent) -> @types.LifecycleTrigger {
  match event {
    DevEvent::PRCreated(..) => @types.LifecycleTrigger::PRCreated
    DevEvent::NotifyParentSuccess(..) =>
      @types.LifecycleTrigger::NotifyParentSuccess
    DevEvent::NotifyParentFailure(..) =>
      @types.LifecycleTrigger::NotifyParentFailure
    DevEvent::ExitRequested => @types.LifecycleTrigger::ExitRequested
    DevEvent::MergeObserved(_) => @types.LifecycleTrigger::MergeObserved
    DevEvent::ReviewReceivedEv(..) => @types.LifecycleTrigger::ReviewReceived
    DevEvent::ReviewApprovedEv(_) => @types.LifecycleTrigger::ReviewApproved
    DevEvent::FixesPushedEv(..) => @types.LifecycleTrigger::FixesPushed
  }
}

///|
/// Pure planning: current persisted lifecycle snapshot plus a TL event to
/// lifecycle effects (no file or registry I/O).
pub fn plan_tl_lifecycle_effects(
  lifecycle : AgentLifecycle,
  event : TLEvent,
) -> Array[LifecycleEffect] {
  let supervisor = match lifecycle.workflow {
    WorkflowState::Supervisor(supervisor) => supervisor
    _ => SupervisorLifecycle::Planning
  }
  let transitioned = match event {
    TLEvent::ChildSpawned(child_id~) =>
      supervisor_transition(
        supervisor,
        SupervisorEvent::ChildSpawned(child={
          child_id,
          slug: child_id,
          branch: child_id,
          agent_type: @types.AgentType::Unknown,
          summary: ChildLifecycleSummary::Working,
        }),
      )
    TLEvent::ChildCompleted(child_id~) =>
      match
        supervisor_transition(
          supervisor,
          SupervisorEvent::ChildUpdated(
            child_id~,
            summary=ChildLifecycleSummary::Done,
            agent_type=None,
          ),
        ) {
        Transitioned(next) => Transitioned(promote_if_wave_complete(next))
        invalid => invalid
      }
    TLEvent::ChildFailed(child_id~, reason~) =>
      match
        supervisor_transition(
          supervisor,
          SupervisorEvent::ChildFailed(
            child_id~,
            reason=classify_failure(reason),
          ),
        ) {
        Transitioned(next) => Transitioned(promote_if_wave_complete(next))
        invalid => invalid
      }
    TLEvent::PRMerged(url~, ..) =>
      match supervisor {
        SupervisorLifecycle::Supervising(children~, ..)
        | SupervisorLifecycle::WaveComplete(children~, ..) =>
          match child_summary_for_slug(children, url) {
            Some((child_id, _)) =>
              match
                supervisor_transition(
                  supervisor,
                  SupervisorEvent::ChildUpdated(
                    child_id~,
                    summary=ChildLifecycleSummary::Done,
                    agent_type=None,
                  ),
                ) {
                Transitioned(next) =>
                  Transitioned(promote_if_wave_complete(next))
                invalid => invalid
              }
            None => InvalidTransition("child not found")
          }
        _ => InvalidTransition("no supervising children")
      }
    TLEvent::OwnPRFiled(number~, url~, ..) =>
      supervisor_transition(
        supervisor,
        SupervisorEvent::OwnPRFiled(number~, url~),
      )
    _ => InvalidTransition("unsupported tl event")
  }
  match transitioned {
    Transitioned(new_supervisor) => {
      let next_lc = {
        ..lifecycle,
        workflow: WorkflowState::Supervisor(new_supervisor),
      }
      [
        PersistLifecycle(lifecycle=next_lc),
        AppendLifecycleEvent(
          agent_id=lifecycle.agent_id,
          from_lc=lifecycle,
          to_lc=next_lc,
          trigger=tl_event_trigger(event),
        ),
      ]
    }
    InvalidTransition(_) => []
  }
}

///|
/// Read the current lifecycle for `scope`, then plan TL effects (read I/O
/// only; no persistence). Callers run `interpret_lifecycle_effects` to execute
/// the returned plan.
pub fn plan_tl_event_for_scope(
  project_dir : String,
  scope : String,
  event : TLEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Array[LifecycleEffect] {
  let store = LifecycleStore::new(project_dir)
  let default_role = match registry {
    Some(reg) =>
      reg.get(scope).role catch {
        _ => supervisor_role_for_scope(scope)
      }
    None => supervisor_role_for_scope(scope)
  }
  let lifecycle = store.read_or_default(scope, default_role)
  plan_tl_lifecycle_effects(lifecycle, event)
}

///|
fn sync_registry_after_persist(
  registry : @registry.AgentRegistry,
  lifecycle : AgentLifecycle,
) -> Unit {
  try {
    let agent = registry.get(lifecycle.agent_id)
    ignore(registry.upsert({ ..agent, state: lifecycle.to_agent_state() }))
  } catch {
    _ => ()
  }
}

///|
/// Execute lifecycle effects: atomic lifecycle writes, optional JSONL history,
/// and optional in-memory registry coherence after a successful write.
///
/// **Append / persist pairing (fragile):** `AppendLifecycleEvent` runs only when
/// the *immediately preceding* effect was a successful `PersistLifecycle` for
/// the *same* `agent_id` as in the append. This mirrors the historical
/// `if write(...) { append(...) }` coupling. Plans should emit
/// `[PersistLifecycle(...), AppendLifecycleEvent(agent_id=that.agent, ...)]`
/// per logical transition. After each append effect is processed, the latch is
/// cleared so a later append cannot bind to an older persist without another
/// successful `PersistLifecycle` in between.
pub fn interpret_lifecycle_effects(
  project_dir : String,
  effects : Array[LifecycleEffect],
  registry? : @registry.AgentRegistry? = None,
) -> Unit {
  let mut last_persisted : AgentLifecycle? = None
  for effect in effects {
    match effect {
      PersistLifecycle(lifecycle~) =>
        if write_lifecycle(project_dir, lifecycle) {
          last_persisted = Some(lifecycle)
          match registry {
            Some(reg) => sync_registry_after_persist(reg, lifecycle)
            None => ()
          }
        } else {
          last_persisted = None
        }
      AppendLifecycleEvent(agent_id~, from_lc~, to_lc~, trigger~) => {
        match last_persisted {
          Some(lc) =>
            if lc.agent_id == agent_id {
              ignore(
                append_lifecycle_event(
                  project_dir, agent_id, from_lc, to_lc, trigger,
                ),
              )
            }
          None => ()
        }
        last_persisted = None
      }
    }
  }
}

///|
/// Pure planning for dev lifecycle updates (no persistence).
pub fn plan_dev_event_checked(
  lifecycle : AgentLifecycle,
  event : DevEvent,
) -> Result[(DevPhase, Array[LifecycleEffect]), String] {
  let dev = match lifecycle.workflow {
    WorkflowState::Dev(dev) => dev
    _ => DevLifecycle::Working
  }
  match event {
    DevEvent::NotifyParentSuccess(..) =>
      Ok((legacy_dev_phase_from_lifecycle(dev), []))
    DevEvent::NotifyParentFailure(message~) => {
      let failed = DevLifecycle::Failed(reason=classify_failure(message))
      let next_lc = { ..lifecycle, workflow: WorkflowState::Dev(failed) }
      Ok(
        (
          legacy_dev_phase_from_lifecycle(failed),
          [
            PersistLifecycle(lifecycle=next_lc),
            AppendLifecycleEvent(
              agent_id=lifecycle.agent_id,
              from_lc=lifecycle,
              to_lc=next_lc,
              trigger=dev_event_trigger(event),
            ),
          ],
        ),
      )
    }
    _ => {
      let lifecycle_event = match event {
        DevEvent::PRCreated(pr_number~, url~, ..) =>
          Some(DevLifecycleEvent::PRCreated(pr_number~, url~))
        DevEvent::ReviewReceivedEv(pr_number~, body~) =>
          Some(DevLifecycleEvent::ReviewReceived(pr_number~, body~))
        DevEvent::ReviewApprovedEv(pr_number~) =>
          Some(DevLifecycleEvent::ReviewApproved(pr_number~))
        DevEvent::FixesPushedEv(pr_number~, sha~) =>
          Some(DevLifecycleEvent::FixesPushed(pr_number~, sha~))
        DevEvent::ExitRequested => Some(DevLifecycleEvent::ExitRequested)
        DevEvent::MergeObserved(pr_number~) =>
          Some(DevLifecycleEvent::MergeObserved(pr_number~))
        _ => None
      }
      match lifecycle_event {
        Some(dev_event) =>
          match dev_lifecycle_transition(dev, dev_event) {
            Transitioned(new_dev) => {
              let next_lc = {
                ..lifecycle,
                workflow: WorkflowState::Dev(new_dev),
              }
              Ok(
                (
                  legacy_dev_phase_from_lifecycle(new_dev),
                  [
                    PersistLifecycle(lifecycle=next_lc),
                    AppendLifecycleEvent(
                      agent_id=lifecycle.agent_id,
                      from_lc=lifecycle,
                      to_lc=next_lc,
                      trigger=dev_event_trigger(event),
                    ),
                  ],
                ),
              )
            }
            InvalidTransition(message) => Err(message)
          }
        None => Err("unsupported dev event")
      }
    }
  }
}

///|
/// Read lifecycle for `scope`, then pure-plan (`plan_dev_event_checked`). Does
/// **not** write files, append JSONL, or touch the registry — callers must run
/// `interpret_lifecycle_effects` (or use `@tools.apply_dev_event` /
/// `@tools.apply_dev_event_checked`, which interpret after planning).
pub fn plan_dev_event_for_scope(
  project_dir : String,
  scope : String,
  event : DevEvent,
) -> Result[(DevPhase, Array[LifecycleEffect]), String] {
  let store = LifecycleStore::new(project_dir)
  let lifecycle = store.read_or_default(scope, @types.Role::Dev)
  plan_dev_event_checked(lifecycle, event)
}

///|
pub fn apply_dev_event(
  project_dir : String,
  scope : String,
  event : DevEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Unit {
  match plan_dev_event_for_scope(project_dir, scope, event) {
    Ok((_, effects)) =>
      interpret_lifecycle_effects(project_dir, effects, registry~)
    Err(_) => ()
  }
}

///|
pub fn current_dev_phase(project_dir : String, scope : String) -> DevPhase {
  let store = LifecycleStore::new(project_dir)
  let lifecycle = store.read_or_default(scope, @types.Role::Dev)
  match lifecycle.workflow {
    WorkflowState::Dev(dev) => legacy_dev_phase_from_lifecycle(dev)
    _ => DevPhase::Working
  }
}

///|
pub fn synthesized_parent_terminal_target(
  session : String,
  parent_id : String,
  role : @types.Role,
) -> @types.LocalTarget {
  let slug = match role {
    @types.Role::Root | @types.Role::TL => "TL"
    _ => extract_slug(parent_id)
  }
  @workspace.local_target_for(session, slug, @types.IsolationMode::Worktree)
}

///|
pub fn synthesized_parent_agent_type(_role : @types.Role) -> @types.AgentType {
  @types.AgentType::Claude
}

///|
pub fn resolve_agent_with_fallback(
  project_dir : String,
  session : String,
  reg : @registry.AgentRegistry,
  agent_id : String,
) -> @types.Agent raise @types.ChoirError {
  reg.get(agent_id) catch {
    _ =>
      match read_lifecycle(project_dir, agent_id) {
        Some(lifecycle) =>
          {
            agent_id: @types.AgentId(agent_id),
            role: lifecycle.role,
            agent_type: synthesized_parent_agent_type(lifecycle.role),
            parent: None,
            workspace: project_dir,
            branch: agent_id,
            terminal_target: Some(
              synthesized_parent_terminal_target(
                session,
                agent_id,
                lifecycle.role,
              ),
            ),
            host: @types.Host::Local,
            state: lifecycle.to_agent_state(),
            spawn_depth: 0,
          }
        None => raise @types.ChoirError::agent_not_found(agent_id)
      }
  }
}

///|
pub fn resolve_parent_with_fallback(
  project_dir : String,
  session : String,
  reg : @registry.AgentRegistry,
  caller_id : String,
) -> @types.Agent raise @types.ChoirError {
  let agent = reg.get(caller_id)
  match agent.parent {
    Some(parent_id) =>
      resolve_agent_with_fallback(project_dir, session, reg, parent_id)
    None =>
      raise @types.ChoirError::agent_not_found("no parent for " + caller_id)
  }
}

///|
pub fn persist_lifecycle(
  project_dir : String,
  registry : @registry.AgentRegistry,
  lifecycle : AgentLifecycle,
) -> Bool {
  let ok = write_lifecycle(project_dir, lifecycle)
  try {
    let agent = registry.get(lifecycle.agent_id)
    ignore(registry.upsert({ ..agent, state: lifecycle.to_agent_state() }))
  } catch {
    _ => ()
  }
  ok
}

///|
fn child_exists(children : Array[ChildLifecycle], child_id : String) -> Bool {
  for child in children {
    if child.child_id == child_id {
      return true
    }
  }
  false
}

///|
pub fn sync_parent_child_lifecycle(
  project_dir : String,
  session : String,
  registry : @registry.AgentRegistry,
  agent_id : String,
  lifecycle : AgentLifecycle,
) -> Unit {
  let agent = registry.get(agent_id) catch { _ => return }
  let parent_id = match agent.parent {
    Some(parent_id) => parent_id
    None => return
  }
  let parent = resolve_agent_with_fallback(
    project_dir, session, registry, parent_id,
  ) catch {
    _ => return
  }
  let child : ChildLifecycle = {
    child_id: agent_id,
    slug: extract_slug(agent_id),
    branch: agent.branch,
    agent_type: agent.agent_type,
    summary: child_summary_from_lifecycle(lifecycle),
  }
  let parent_lifecycle = read_or_default_lifecycle(
    project_dir,
    parent_id,
    parent.role,
  )
  let supervisor = match parent_lifecycle.workflow {
    WorkflowState::Supervisor(supervisor) => supervisor
    _ => SupervisorLifecycle::Planning
  }
  let (transitioned, supervisor_trigger) = match supervisor {
    SupervisorLifecycle::Supervising(children~, ..)
    | SupervisorLifecycle::WaveComplete(children~, ..) =>
      if child_exists(children, agent_id) {
        (
          supervisor_transition(
            supervisor,
            SupervisorEvent::ChildUpdated(
              child_id=agent_id,
              summary=child.summary,
              agent_type=Some(agent.agent_type),
            ),
          ),
          @types.LifecycleTrigger::ChildUpdated,
        )
      } else {
        (
          supervisor_transition(
            supervisor,
            SupervisorEvent::ChildSpawned(child~),
          ),
          @types.LifecycleTrigger::ChildSpawned,
        )
      }
    _ =>
      (
        supervisor_transition(supervisor, SupervisorEvent::ChildSpawned(child~)),
        @types.LifecycleTrigger::ChildSpawned,
      )
  }
  match transitioned {
    Transitioned(new_supervisor) => {
      let next_parent = {
        ..parent_lifecycle,
        workflow: WorkflowState::Supervisor(new_supervisor),
      }
      if persist_lifecycle(project_dir, registry, next_parent) {
        ignore(
          append_lifecycle_event(
            project_dir, parent_id, parent_lifecycle, next_parent, supervisor_trigger,
          ),
        )
      }
    }
    InvalidTransition(_) => ()
  }
}

///|
pub fn remove_parent_child_lifecycle(
  project_dir : String,
  registry : @registry.AgentRegistry,
  agent_id : String,
) -> Unit {
  let agent = registry.get(agent_id) catch { _ => return }
  let parent_id = match agent.parent {
    Some(parent_id) => parent_id
    None => return
  }
  let parent = registry.get(parent_id) catch { _ => return }
  let parent_lifecycle = read_or_default_lifecycle(
    project_dir,
    parent_id,
    parent.role,
  )
  let supervisor = match parent_lifecycle.workflow {
    WorkflowState::Supervisor(supervisor) => supervisor
    _ => SupervisorLifecycle::Planning
  }
  match
    supervisor_transition(
      supervisor,
      SupervisorEvent::ChildRemoved(child_id=agent_id),
    ) {
    Transitioned(new_supervisor) => {
      let next_parent = {
        ..parent_lifecycle,
        workflow: WorkflowState::Supervisor(new_supervisor),
      }
      if persist_lifecycle(project_dir, registry, next_parent) {
        ignore(
          append_lifecycle_event(
            project_dir,
            parent_id,
            parent_lifecycle,
            next_parent,
            @types.LifecycleTrigger::ChildRemoved,
          ),
        )
      }
    }
    InvalidTransition(_) => ()
  }
}

///|
pub fn apply_recovered_lifecycle(
  project_dir : String,
  session : String,
  registry : @registry.AgentRegistry,
  agent_id : String,
  lifecycle : AgentLifecycle,
) -> Unit {
  ignore(persist_lifecycle(project_dir, registry, lifecycle))
  sync_parent_child_lifecycle(
    project_dir, session, registry, agent_id, lifecycle,
  )
}

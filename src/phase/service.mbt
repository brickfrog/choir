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
fn tl_event_trigger(event : TLEvent) -> String {
  match event {
    TLEvent::ChildSpawned(_) => "ChildSpawned"
    TLEvent::ChildCompleted(_) => "ChildCompleted"
    TLEvent::ChildFailed(_, ..) => "ChildFailed"
    TLEvent::PRMerged(..) => "PRMerged"
    TLEvent::AllChildrenDone => "AllChildrenDone"
    TLEvent::OwnPRFiled(..) => "OwnPRFiled"
  }
}

///|
fn dev_event_trigger(event : DevEvent) -> String {
  match event {
    DevEvent::PRCreated(..) => "PRCreated"
    DevEvent::NotifyParentSuccess(..) => "NotifyParentSuccess"
    DevEvent::NotifyParentFailure(..) => "NotifyParentFailure"
    DevEvent::ExitRequested => "ExitRequested"
    DevEvent::MergeObserved(_) => "MergeObserved"
    DevEvent::ReviewReceivedEv(..) => "ReviewReceived"
    DevEvent::ReviewApprovedEv(_) => "ReviewApproved"
    DevEvent::FixesPushedEv(..) => "FixesPushed"
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
          agent_type: "",
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
/// Load lifecycle for `scope`, then plan TL effects (read I/O only).
pub fn apply_tl_event(
  project_dir : String,
  scope : String,
  event : TLEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Array[LifecycleEffect] {
  let store = LifecycleStore::new(project_dir)
  let default_role = match registry {
    Some(reg) =>
      match reg.get(scope) {
        Ok(agent) => agent.role
        Err(_) => supervisor_role_for_scope(scope)
      }
    None => supervisor_role_for_scope(scope)
  }
  let lifecycle = store.read_or_default(scope, default_role)
  plan_tl_lifecycle_effects(lifecycle, event)
}

///|
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
        } else {
          last_persisted = None
        }
      AppendLifecycleEvent(agent_id~, from_lc~, to_lc~, trigger~) =>
        match last_persisted {
          Some(lc) =>
            if lc.agent_id == agent_id {
              ignore(
                append_lifecycle_event(
                  project_dir,
                  agent_id,
                  lifecycle_to_json(from_lc),
                  lifecycle_to_json(to_lc),
                  trigger,
                ),
              )
            }
          None => ()
        }
      SyncRegistryState(agent_id~, lifecycle~) =>
        match registry {
          Some(reg) =>
            match reg.get(agent_id) {
              Ok(agent) =>
                ignore(
                  reg.upsert({ ..agent, state: lifecycle.to_agent_state() }),
                )
              Err(_) => ()
            }
          None => ()
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
pub fn apply_dev_event_checked(
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
  match apply_dev_event_checked(project_dir, scope, event) {
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
) -> Result[@types.Agent, @types.ChoirError] {
  match reg.get(agent_id) {
    Ok(agent) => Ok(agent)
    Err(_) =>
      match read_lifecycle(project_dir, agent_id) {
        Some(lifecycle) =>
          Ok({
            agent_id,
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
          })
        None => Err(@types.ChoirError::AgentNotFound(agent_id))
      }
  }
}

///|
pub fn resolve_parent_with_fallback(
  project_dir : String,
  session : String,
  reg : @registry.AgentRegistry,
  caller_id : String,
) -> Result[@types.Agent, @types.ChoirError] {
  match reg.get(caller_id) {
    Ok(agent) =>
      match agent.parent {
        Some(parent_id) =>
          resolve_agent_with_fallback(project_dir, session, reg, parent_id)
        None =>
          Err(@types.ChoirError::AgentNotFound("no parent for " + caller_id))
      }
    Err(e) => Err(e)
  }
}

///|
pub fn persist_lifecycle(
  project_dir : String,
  registry : @registry.AgentRegistry,
  lifecycle : AgentLifecycle,
) -> Bool {
  let ok = write_lifecycle(project_dir, lifecycle)
  match registry.get(lifecycle.agent_id) {
    Ok(agent) =>
      ignore(registry.upsert({ ..agent, state: lifecycle.to_agent_state() }))
    Err(_) => ()
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
  let agent = match registry.get(agent_id) {
    Ok(agent) => agent
    Err(_) => return
  }
  let parent_id = match agent.parent {
    Some(parent_id) => parent_id
    None => return
  }
  let parent = match
    resolve_agent_with_fallback(project_dir, session, registry, parent_id) {
    Ok(parent) => parent
    Err(_) => return
  }
  let child : ChildLifecycle = {
    child_id: agent_id,
    slug: extract_slug(agent_id),
    branch: agent.branch,
    agent_type: agent.agent_type.to_string(),
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
            ),
          ),
          "ChildUpdated",
        )
      } else {
        (
          supervisor_transition(
            supervisor,
            SupervisorEvent::ChildSpawned(child~),
          ),
          "ChildSpawned",
        )
      }
    _ =>
      (
        supervisor_transition(supervisor, SupervisorEvent::ChildSpawned(child~)),
        "ChildSpawned",
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
            project_dir,
            parent_id,
            lifecycle_to_json(parent_lifecycle),
            lifecycle_to_json(next_parent),
            supervisor_trigger,
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
  let agent = match registry.get(agent_id) {
    Ok(agent) => agent
    Err(_) => return
  }
  let parent_id = match agent.parent {
    Some(parent_id) => parent_id
    None => return
  }
  let parent = match registry.get(parent_id) {
    Ok(parent) => parent
    Err(_) => return
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
            lifecycle_to_json(parent_lifecycle),
            lifecycle_to_json(next_parent),
            "ChildRemoved",
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

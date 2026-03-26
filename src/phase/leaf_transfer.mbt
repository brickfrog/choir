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
fn persist_agent_lifecycle(
  project_dir : String,
  registry : @registry.AgentRegistry,
  lifecycle : AgentLifecycle,
) -> Unit {
  ignore(write_lifecycle(project_dir, lifecycle))
  match registry.get(lifecycle.agent_id) {
    Ok(agent) =>
      ignore(registry.upsert({ ..agent, state: lifecycle.to_agent_state() }))
    Err(_) => ()
  }
}

///|
fn current_lifecycle_for_transfer(
  project_dir : String,
  registry : @registry.AgentRegistry,
  agent_id : String,
) -> AgentLifecycle {
  match registry.get(agent_id) {
    Ok(agent) => read_or_default_lifecycle(project_dir, agent_id, agent.role)
    Err(_) =>
      match read_lifecycle(project_dir, agent_id) {
        Some(lifecycle) => lifecycle
        None => lifecycle_for_role(agent_id, @types.Role::Dev)
      }
  }
}

///|
fn resolve_parent_meta(
  project_dir : String,
  registry : @registry.AgentRegistry,
  parent_id : String,
) -> Result[(@types.Role, @types.AgentType), @types.ExoError] {
  match registry.get(parent_id) {
    Ok(parent) => Ok((parent.role, parent.agent_type))
    Err(_) =>
      match read_lifecycle(project_dir, parent_id) {
        Some(lifecycle) => Ok((lifecycle.role, @types.AgentType::Claude))
        None => Err(@types.ExoError::AgentNotFound(parent_id))
      }
  }
}

///|
fn sync_parent_child_lifecycle_transfer(
  project_dir : String,
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
  let (parent_role, _parent_type) = match
    resolve_parent_meta(project_dir, registry, parent_id) {
    Ok(v) => v
    Err(_) => return
  }
  let child : ChildLifecycle = {
    child_id: agent_id,
    slug: extract_slug(agent_id),
    branch: agent.branch,
    agent_type: @config.agent_type_to_string(agent.agent_type),
    summary: child_summary_from_lifecycle(lifecycle),
  }
  let parent_lifecycle = read_or_default_lifecycle(
    project_dir, parent_id, parent_role,
  )
  let supervisor = match parent_lifecycle.workflow {
    WorkflowState::Supervisor(supervisor) => supervisor
    _ => SupervisorLifecycle::Planning
  }
  let transitioned = match supervisor {
    SupervisorLifecycle::Supervising(children~) =>
      if child_exists(children, agent_id) {
        supervisor_transition(
          supervisor,
          SupervisorEvent::ChildUpdated(
            child_id=agent_id,
            summary=child.summary,
          ),
        )
      } else {
        supervisor_transition(supervisor, SupervisorEvent::ChildSpawned(child~))
      }
    _ =>
      supervisor_transition(supervisor, SupervisorEvent::ChildSpawned(child~))
  }
  match transitioned {
    Transitioned(new_supervisor) =>
      persist_agent_lifecycle(project_dir, registry, {
        ..parent_lifecycle,
        workflow: WorkflowState::Supervisor(new_supervisor),
      })
    InvalidTransition(_) => ()
  }
}

///|
fn remove_parent_child_lifecycle_transfer(
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
    Transitioned(new_supervisor) =>
      persist_agent_lifecycle(project_dir, registry, {
        ..parent_lifecycle,
        workflow: WorkflowState::Supervisor(new_supervisor),
      })
    InvalidTransition(_) => ()
  }
}

///|
/// Transfer poller PR ownership and dev/workflow state from a replaced leaf to
/// its replacement, finalize the old leaf as rescued (not generic failure), and
/// update the parent supervisor view to track the replacement child only.
pub fn execute_leaf_ownership_transfer(
  project_dir : String,
  registry : @registry.AgentRegistry,
  poller : @poller.PollerState,
  from_agent_id : String,
  to_agent_id : String,
) -> Result[Int, @types.ExoError] {
  if from_agent_id == to_agent_id {
    return Ok(0)
  }
  let from_agent = match registry.get(from_agent_id) {
    Ok(agent) => agent
    Err(e) => return Err(e)
  }
  let to_agent = match registry.get(to_agent_id) {
    Ok(agent) => agent
    Err(e) => return Err(e)
  }
  if from_agent.parent != to_agent.parent {
    return Err(
      @types.ExoError::ValidationError(
        "cannot transfer ownership across different parents",
      ),
    )
  }
  if from_agent.role != to_agent.role {
    return Err(
      @types.ExoError::ValidationError(
        "cannot transfer ownership across different roles",
      ),
    )
  }
  match from_agent.role {
    @types.Role::Dev | @types.Role::Worker => ()
    _ =>
      return Err(
        @types.ExoError::ValidationError(
          "ownership transfer only supports leaf roles",
        ),
      )
  }
  if poller.has_tracked_pr(from_agent_id) &&
    from_agent.branch != to_agent.branch {
    return Err(
      @types.ExoError::ValidationError(
        "replacement branch must match tracked PR branch (" +
        from_agent.branch +
        ") when reusing rescue semantics",
      ),
    )
  }
  let transferred = poller.transfer_owner(
    from_agent_id,
    to_agent_id,
    to_agent.branch,
    @workspace.parent_branch(to_agent.branch).unwrap_or(""),
  )
  let from_lifecycle = current_lifecycle_for_transfer(
    project_dir, registry, from_agent_id,
  )
  let to_lifecycle = current_lifecycle_for_transfer(
    project_dir, registry, to_agent_id,
  )
  let workflow = match (from_lifecycle.workflow, to_lifecycle.workflow) {
    (WorkflowState::Dev(from_dev), WorkflowState::Dev(_)) =>
      WorkflowState::Dev(from_dev)
    (WorkflowState::Worker(from_worker), WorkflowState::Worker(_)) =>
      WorkflowState::Worker(from_worker)
    _ => to_lifecycle.workflow
  }
  let carried_lifecycle = {
    ..to_lifecycle,
    agent_id: to_agent_id,
    role: to_agent.role,
    workflow,
  }
  persist_agent_lifecycle(project_dir, registry, carried_lifecycle)
  sync_parent_child_lifecycle_transfer(
    project_dir, registry, to_agent_id, carried_lifecycle,
  )
  remove_parent_child_lifecycle_transfer(project_dir, registry, from_agent_id)
  let finalized_workflow = match from_lifecycle.workflow {
    WorkflowState::Dev(_) =>
      WorkflowState::Dev(
        DevLifecycle::Done(reason=FinalizeReason::ReplacedByRescue),
      )
    WorkflowState::Worker(_) =>
      WorkflowState::Worker(
        WorkerLifecycle::Done(reason=FinalizeReason::ReplacedByRescue),
      )
    _ => from_lifecycle.workflow
  }
  let from_finalized : AgentLifecycle = {
    ..from_lifecycle,
    process: ProcessState::Finalized(reason=FinalizeReason::ReplacedByRescue),
    workflow: finalized_workflow,
  }
  ignore(write_lifecycle(project_dir, from_finalized))
  ignore(registry.upsert({ ..from_agent, state: @types.AgentState::Done }))
  Ok(transferred)
}

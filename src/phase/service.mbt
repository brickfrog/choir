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
pub fn apply_tl_event(
  project_dir : String,
  scope : String,
  event : TLEvent,
  registry? : @registry.AgentRegistry? = None,
) -> Unit {
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
      if store.write(next_lc) {
        ignore(
          store.append_event(scope, lifecycle, next_lc, tl_event_trigger(event)),
        )
      }
    }
    InvalidTransition(_) => ()
  }
}

///|
pub fn apply_dev_event_checked(
  project_dir : String,
  scope : String,
  event : DevEvent,
) -> Result[DevPhase, String] {
  let store = LifecycleStore::new(project_dir)
  let lifecycle = store.read_or_default(scope, @types.Role::Dev)
  let dev = match lifecycle.workflow {
    WorkflowState::Dev(dev) => dev
    _ => DevLifecycle::Working
  }
  match event {
    DevEvent::NotifyParentSuccess(..) =>
      Ok(legacy_dev_phase_from_lifecycle(dev))
    DevEvent::NotifyParentFailure(message~) => {
      let failed = DevLifecycle::Failed(reason=classify_failure(message))
      let next_lc = { ..lifecycle, workflow: WorkflowState::Dev(failed) }
      if store.write(next_lc) {
        ignore(
          store.append_event(
            scope,
            lifecycle,
            next_lc,
            dev_event_trigger(event),
          ),
        )
      }
      Ok(legacy_dev_phase_from_lifecycle(failed))
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
              if store.write(next_lc) {
                ignore(
                  store.append_event(
                    scope,
                    lifecycle,
                    next_lc,
                    dev_event_trigger(event),
                  ),
                )
              }
              Ok(legacy_dev_phase_from_lifecycle(new_dev))
            }
            InvalidTransition(message) => Err(message)
          }
        None => Err("unsupported dev event")
      }
    }
  }
}

///|
pub fn apply_dev_event(
  project_dir : String,
  scope : String,
  event : DevEvent,
) -> Unit {
  ignore(apply_dev_event_checked(project_dir, scope, event))
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

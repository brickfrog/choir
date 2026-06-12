///|
/// Compact label for a workflow state, used by the TUI event journal's
/// lifecycle-changed events. Self-contained (carries the PR/wave payload in
/// the label) so journal events stay replayable without re-reading state.
pub fn workflow_state_label(workflow : WorkflowState) -> String {
  match workflow {
    WorkflowState::Dev(dev) =>
      match dev {
        DevLifecycle::Working => "dev:working"
        DevLifecycle::WaitingForRedGate => "dev:waiting_for_red_gate"
        DevLifecycle::ReviewOwned(pr_number~, ..) =>
          "dev:review_owned#" + pr_number.to_string()
        DevLifecycle::ChangesRequested(pr_number~, ..) =>
          "dev:changes_requested#" + pr_number.to_string()
        DevLifecycle::ExitRequestedDeferred(pr_number~, ..) =>
          "dev:exit_requested_deferred#" + pr_number.to_string()
        DevLifecycle::Exitable => "dev:exitable"
        DevLifecycle::Done(..) => "dev:done"
        DevLifecycle::Failed(..) => "dev:failed"
      }
    WorkflowState::Worker(worker) =>
      match worker {
        WorkerLifecycle::Working => "worker:working"
        WorkerLifecycle::Exitable => "worker:exitable"
        WorkerLifecycle::Done(..) => "worker:done"
        WorkerLifecycle::Failed(..) => "worker:failed"
      }
    WorkflowState::Supervisor(supervisor) =>
      match supervisor {
        SupervisorLifecycle::Planning => "supervisor:planning"
        SupervisorLifecycle::Dispatching => "supervisor:dispatching"
        SupervisorLifecycle::Supervising(wave~, ..) =>
          "supervisor:supervising@" + wave.to_string()
        SupervisorLifecycle::WaveComplete(wave~, ..) =>
          "supervisor:wave_complete@" + wave.to_string()
        SupervisorLifecycle::OwnPRFiled(number~, ..) =>
          "supervisor:own_pr_filed#" + number.to_string()
        SupervisorLifecycle::Done => "supervisor:done"
        SupervisorLifecycle::Failed(..) => "supervisor:failed"
      }
  }
}

///|
pub fn AgentLifecycle::workflow_label(self : AgentLifecycle) -> String {
  workflow_state_label(self.workflow)
}

///|
priv struct LifecycleTransitionObserverSlot {
  mut observer : ((
    String,
    AgentLifecycle,
    AgentLifecycle,
    @types.LifecycleTrigger,
  ) -> Unit)?
}

///|
/// Process-wide observer for lifecycle transitions. `append_lifecycle_event`
/// is the single funnel every transition flows through (store, service,
/// server handlers), so installing here gives the TUI journal its
/// lifecycle choke point without sprinkling emission across call sites.
/// Installed once at daemon boot; tests leave it unset.
let lifecycle_transition_observer_slot : LifecycleTransitionObserverSlot = {
  observer: None,
}

///|
pub fn set_lifecycle_transition_observer(
  observer : (String, AgentLifecycle, AgentLifecycle, @types.LifecycleTrigger) -> Unit,
) -> Unit {
  lifecycle_transition_observer_slot.observer = Some(observer)
}

///|
pub fn clear_lifecycle_transition_observer() -> Unit {
  lifecycle_transition_observer_slot.observer = None
}

///|
fn notify_lifecycle_transition_observer(
  agent_id : String,
  from_lc : AgentLifecycle,
  to_lc : AgentLifecycle,
  trigger : @types.LifecycleTrigger,
) -> Unit {
  match lifecycle_transition_observer_slot.observer {
    Some(f) => f(agent_id, from_lc, to_lc, trigger)
    None => ()
  }
}

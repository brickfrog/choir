///|
/// Shared per-agent status derivation — the single assembly core behind the
/// status read models (status_bar_state panes, server status_dump rows, and
/// the canonical TUI snapshot). Read models project from this; they do not
/// re-derive PR selection, thread tri-state, CI rollup, or attention.
pub(all) struct AgentStatusDerived {
  workflow_pr_number : Int?
  pr_number : Int?
  unresolved_threads : StatusBarThreadCount
  ci_rollup : @poller.CiRollupStatus?
  fixes_pushed_at : Int64
  attention : PaneAttention
} derive(Debug, Eq)

///|
/// One tracked-PR-per-agent index (highest PR number wins), shared by all
/// status projections.
pub fn status_tracked_by_agent(
  poller_tracked : Map[Int, @poller.TrackedPR],
) -> Map[String, @poller.TrackedPR] {
  status_bar_tracked_by_agent(poller_tracked)
}

///|
pub fn derive_agent_status(
  agent_id : String,
  workflow : @phase.WorkflowState,
  poller_tracked : Map[Int, @poller.TrackedPR],
  tracked_by_agent : Map[String, @poller.TrackedPR],
) -> AgentStatusDerived {
  let workflow_pr_number = status_bar_workflow_pr_number(workflow)
  let tracked = status_bar_tracked_for_workflow(
    poller_tracked, agent_id, workflow_pr_number, tracked_by_agent,
  )
  let pr_number = match workflow_pr_number {
    Some(value) => Some(value)
    None =>
      match tracked {
        Some(value) => status_bar_positive_pr_number(value.pr_number)
        None => None
      }
  }
  let unresolved_threads = status_bar_thread_count(pr_number, tracked)
  let ci_rollup = match tracked {
    Some(value) => Some(value.last_ci_rollup)
    None => None
  }
  let fixes_pushed_at = match tracked {
    Some(value) => value.fixes_pushed_at
    None => 0L
  }
  {
    workflow_pr_number,
    pr_number,
    unresolved_threads,
    ci_rollup,
    fixes_pushed_at,
    attention: pane_needs_attention(
      workflow, fixes_pushed_at, unresolved_threads,
    ),
  }
}

///|
/// Wire conversion for the canonical snapshot's per-agent status fields.
pub fn AgentStatusDerived::to_tui_fields(
  self : AgentStatusDerived,
  lifecycle_wire : String,
  last_activity_unix : Int64,
) -> @types.TuiAgentStatusFields {
  {
    lifecycle_wire,
    pr_number: self.pr_number,
    unresolved_threads: match self.unresolved_threads {
      Count(n) => Some(n)
      _ => None
    },
    ci_rollup: match self.ci_rollup {
      Some(value) => Some(ci_rollup_to_wire_string(value))
      None => None
    },
    attention: pane_attention_to_bool_string(self.attention),
    fixes_pushed_at: self.fixes_pushed_at,
    last_activity_unix,
  }
}

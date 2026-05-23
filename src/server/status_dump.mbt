///|
pub(all) struct ServerStatusSnapshotRow {
  agent_id : String
  role : @types.Role
  agent_type : @types.AgentType
  lifecycle : @phase.WorkflowState
  terminal_target : String
  parent_agent_id : String?
  last_activity_unix : Int64
  last_request_age_sec : Int64?
  pr_number : Int?
  unresolved_threads : @tools.StatusBarThreadCount
  ci_rollup : @poller.CiRollupStatus?
  attention_needed : @tools.PaneAttention
} derive(Debug, Eq)

///|
pub fn server_status_path(project_dir : String) -> String {
  project_dir + "/.choir/server-status.txt"
}

///|
fn server_status_tracked_pr_by_agent(
  poller : @poller.PollerState,
) -> Map[String, @poller.TrackedPR] {
  let by_agent : Map[String, @poller.TrackedPR] = {}
  for tracked in poller.tracked.values() {
    match by_agent.get(tracked.agent_id) {
      Some(existing) if existing.pr_number >= tracked.pr_number => ()
      _ => by_agent.set(tracked.agent_id, tracked)
    }
  }
  by_agent
}

///|
fn server_status_last_request_age_sec(
  now_sec : Int64,
  lifecycle : @phase.AgentLifecycle,
) -> Int64? {
  if lifecycle.last_updated_unix_sec <= 0L {
    return None
  }
  Some(@types.non_negative_i64(now_sec - lifecycle.last_updated_unix_sec))
}

///|
fn server_status_positive_pr_number(number : Int) -> Int? {
  if number > 0 {
    Some(number)
  } else {
    None
  }
}

///|
fn server_status_workflow_pr_number(workflow : @phase.WorkflowState) -> Int? {
  match workflow {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ReviewOwned(pr_number~, ..)) =>
      server_status_positive_pr_number(pr_number)
    @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number~, ..)
    ) => server_status_positive_pr_number(pr_number)
    @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(pr_number~, ..)
    ) => server_status_positive_pr_number(pr_number)
    @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::OwnPRFiled(number~, ..)
    ) => server_status_positive_pr_number(number)
    _ => None
  }
}

///|
fn server_status_tracked_for_workflow(
  poller : @poller.PollerState,
  agent_id : String,
  workflow_pr_number : Int?,
  tracked_by_agent : Map[String, @poller.TrackedPR],
) -> @poller.TrackedPR? {
  match workflow_pr_number {
    Some(pr_number) =>
      match poller.tracked.get(pr_number) {
        Some(tracked) if tracked.agent_id == agent_id => Some(tracked)
        _ => None
      }
    None => tracked_by_agent.get(agent_id)
  }
}

///|
fn server_status_thread_count(
  pr_number : Int?,
  tracked : @poller.TrackedPR?,
) -> @tools.StatusBarThreadCount {
  match pr_number {
    None => @tools.StatusBarThreadCount::NoPR
    Some(_) =>
      match tracked {
        Some(value) =>
          if value.unresolved_thread_ids_fetched {
            @tools.StatusBarThreadCount::Count(
              value.unresolved_thread_ids.length(),
            )
          } else {
            @tools.StatusBarThreadCount::Unknown
          }
        None => @tools.StatusBarThreadCount::Unknown
      }
  }
}

///|
fn sort_server_status_rows(
  rows : Array[ServerStatusSnapshotRow],
) -> Array[ServerStatusSnapshotRow] {
  let sorted = rows.copy()
  sorted.sort_by(fn(a, b) {
    if a.agent_id < b.agent_id {
      -1
    } else if a.agent_id > b.agent_id {
      1
    } else {
      0
    }
  })
  sorted
}

///|
pub fn server_status_snapshot_rows(
  registry : @registry.AgentRegistry,
  poller : @poller.PollerState,
  lifecycle_reader : (String) -> @phase.AgentLifecycle?,
  now_sec : Int64,
) -> Array[ServerStatusSnapshotRow] {
  let tracked_by_agent = server_status_tracked_pr_by_agent(poller)
  let rows : Array[ServerStatusSnapshotRow] = []
  for agent in registry.list() {
    let agent_id = agent.agent_id.to_string()
    let lifecycle = lifecycle_reader(agent_id).unwrap_or(
      @phase.lifecycle_for_agent(agent),
    )
    let workflow = lifecycle.workflow
    let workflow_pr_number = server_status_workflow_pr_number(workflow)
    let tracked = server_status_tracked_for_workflow(
      poller, agent_id, workflow_pr_number, tracked_by_agent,
    )
    let pr_number = match workflow_pr_number {
      Some(value) => Some(value)
      None =>
        match tracked {
          Some(value) => server_status_positive_pr_number(value.pr_number)
          None => None
        }
    }
    let unresolved_threads = server_status_thread_count(pr_number, tracked)
    let ci_rollup = match tracked {
      Some(value) => Some(value.last_ci_rollup)
      None => None
    }
    let fixes_pushed_at = match tracked {
      Some(value) => value.fixes_pushed_at
      None => 0L
    }
    rows.push({
      agent_id,
      role: agent.role,
      agent_type: agent.agent_type,
      lifecycle: workflow,
      terminal_target: agent.terminal_target
      .map(@types.LocalTarget::to_string)
      .unwrap_or("none"),
      parent_agent_id: @tools.status_bar_parent_agent_id(agent.parent),
      last_activity_unix: @types.non_negative_i64(
        lifecycle.last_updated_unix_sec,
      ),
      last_request_age_sec: server_status_last_request_age_sec(
        now_sec, lifecycle,
      ),
      pr_number,
      unresolved_threads,
      ci_rollup,
      attention_needed: @tools.pane_needs_attention(
        workflow, fixes_pushed_at, unresolved_threads,
      ),
    })
  }
  sort_server_status_rows(rows)
}

///|
fn server_status_optional_age(value : Int64?) -> String {
  match value {
    Some(v) => v.to_string()
    None => "unknown"
  }
}

///|
fn server_status_optional_pr(value : Int?) -> String {
  match value {
    Some(v) => v.to_string()
    None => "none"
  }
}

///|
fn server_status_thread_count_to_string(
  value : @tools.StatusBarThreadCount,
) -> String {
  match value {
    NoPR => "none"
    Unknown => "unknown"
    Count(v) => v.to_string()
  }
}

///|
fn server_status_attention_to_string(value : @tools.PaneAttention) -> String {
  @tools.pane_attention_to_bool_string(value)
}

///|
fn server_status_optional_string(value : String?) -> String {
  match value {
    Some(v) => v
    None => "none"
  }
}

///|
fn server_status_optional_ci_rollup(value : @poller.CiRollupStatus?) -> String {
  match value {
    Some(v) => v.to_wire_string()
    None => "unknown"
  }
}

///|
fn server_status_agent_type_to_string(value : @types.AgentType) -> String {
  let wire = value.to_wire_string()
  if wire == "" {
    "unknown"
  } else {
    wire
  }
}

///|
pub fn format_server_status_snapshot(
  rows : Array[ServerStatusSnapshotRow],
  taken_at_sec : Int64,
) -> String {
  let out = StringBuilder::new()
  out.write_string("choir server status\n")
  out.write_string("taken_at_unix_sec=")
  out.write_string(taken_at_sec.to_string())
  out.write_string("\n")
  out.write_string("agents=")
  out.write_string(rows.length().to_string())
  out.write_string("\n")
  for row in rows {
    out.write_string("agent_id=")
    out.write_string(row.agent_id)
    out.write_string(" role=")
    out.write_string(row.role.to_wire_string())
    out.write_string(" agent_type=")
    out.write_string(server_status_agent_type_to_string(row.agent_type))
    out.write_string(" lifecycle=")
    out.write_string(@tools.lifecycle_to_wire_string(row.lifecycle))
    out.write_string(" terminal_target=")
    out.write_string(row.terminal_target)
    out.write_string(" parent_agent_id=")
    out.write_string(server_status_optional_string(row.parent_agent_id))
    out.write_string(" last_activity_unix=")
    out.write_string(row.last_activity_unix.to_string())
    out.write_string(" last_request_age_sec=")
    out.write_string(server_status_optional_age(row.last_request_age_sec))
    out.write_string(" pr_number=")
    out.write_string(server_status_optional_pr(row.pr_number))
    out.write_string(" unresolved_threads=")
    out.write_string(
      server_status_thread_count_to_string(row.unresolved_threads),
    )
    out.write_string(" ci_rollup=")
    out.write_string(server_status_optional_ci_rollup(row.ci_rollup))
    out.write_string(" attention_needed=")
    out.write_string(server_status_attention_to_string(row.attention_needed))
    out.write_string("\n")
  }
  out.to_string()
}

///|
pub fn build_server_status_snapshot_text(
  registry : @registry.AgentRegistry,
  poller : @poller.PollerState,
  lifecycle_reader : (String) -> @phase.AgentLifecycle?,
  now_sec : Int64,
) -> String {
  format_server_status_snapshot(
    server_status_snapshot_rows(registry, poller, lifecycle_reader, now_sec),
    now_sec,
  )
}

///|
pub fn write_server_status_snapshot_text(
  project_dir : String,
  content : String,
  write_file_atomic : (String, String) -> Bool,
) -> Bool {
  write_file_atomic(server_status_path(project_dir), content)
}

///|
pub fn ServerState::write_server_status_snapshot(
  self : ServerState,
  now_sec : Int64,
  lifecycle_reader : (String) -> @phase.AgentLifecycle?,
) -> Bool {
  let content = build_server_status_snapshot_text(
    self.registry,
    self.poller,
    lifecycle_reader,
    now_sec,
  )
  write_server_status_snapshot_text(
    self.config.project_dir,
    content,
    self.write_file_atomic,
  )
}

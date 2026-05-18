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
  unresolved_threads : Int?
  ci_rollup : @poller.CiRollupStatus?
  attention_needed : Bool?
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
  let age = now_sec - lifecycle.last_updated_unix_sec
  Some(if age < 0L { 0L } else { age })
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
    let tracked = tracked_by_agent.get(agent_id)
    let pr_number = match tracked {
      Some(value) => server_status_positive_pr_number(value.pr_number)
      None => server_status_workflow_pr_number(workflow)
    }
    let unresolved_threads = match tracked {
      Some(value) =>
        if value.unresolved_thread_ids_fetched {
          Some(value.unresolved_thread_ids.length())
        } else {
          None
        }
      None => None
    }
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
      parent_agent_id: agent.parent,
      last_activity_unix: if lifecycle.last_updated_unix_sec > 0L {
        lifecycle.last_updated_unix_sec
      } else {
        0L
      },
      last_request_age_sec: server_status_last_request_age_sec(
        now_sec, lifecycle,
      ),
      pr_number,
      unresolved_threads,
      ci_rollup,
      attention_needed: match unresolved_threads {
        Some(thread_count) =>
          Some(
            @tools.pane_needs_attention(workflow, fixes_pushed_at, thread_count),
          )
        None =>
          if pr_number is None {
            Some(@tools.pane_needs_attention(workflow, fixes_pushed_at, 0))
          } else {
            None
          }
      },
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
fn server_status_optional_thread_count(
  pr_number : Int?,
  value : Int?,
) -> String {
  match value {
    Some(v) => v.to_string()
    None => if pr_number is None { "none" } else { "unknown" }
  }
}

///|
fn server_status_optional_bool(value : Bool?) -> String {
  match value {
    Some(v) => if v { "true" } else { "false" }
    None => "unknown"
  }
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
    Some(v) => @tools.ci_rollup_to_wire_string(v)
    None => "unknown"
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
    out.write_string(@tools.role_to_wire_string(row.role))
    out.write_string(" agent_type=")
    out.write_string(
      @tools.agent_type_to_wire_string(row.agent_type).unwrap_or("unknown"),
    )
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
      server_status_optional_thread_count(row.pr_number, row.unresolved_threads),
    )
    out.write_string(" ci_rollup=")
    out.write_string(server_status_optional_ci_rollup(row.ci_rollup))
    out.write_string(" attention_needed=")
    out.write_string(server_status_optional_bool(row.attention_needed))
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

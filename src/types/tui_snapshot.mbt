///|
/// Canonical full-state read model served by `tui_snapshot`. This is THE
/// snapshot shape going forward: new UI surfaces project from this type
/// instead of hand-assembling another bespoke read model. Assembly performs
/// zero network I/O — PR fields are as fresh as the last poller tick
/// (`prs_as_of_ms` carries that timestamp).
pub(all) struct TuiSnapshot {
  schema_version : Int
  taken_at_ms : Int64
  wave : TuiSnapshotWave
  agents : Array[TuiSnapshotAgent]
  prs : Array[TuiSnapshotPr]
  prs_as_of_ms : Int64
  beads : Array[TuiBeadSummary]
  beads_as_of_ms : Int64?
  poller : PollerVitals
  journal_seq : Int64
  recent_events : Array[TuiEventEnvelope]
} derive(Debug, Eq)

///|
pub let tui_snapshot_schema_version : Int = 1

///|
pub(all) struct TuiSnapshotWave {
  run_id : String
  wave : Int?
  integration_branch : String
  started_at_unix : Int64?
  supervisor_id : String?
} derive(Debug, Eq)

///|
pub(all) struct TuiSnapshotAgent {
  agent_id : String
  role : Role
  agent_type : AgentType
  parent : String?
  workspace : String
  branch : String
  terminal_target : String?
  state : AgentState
  spawn_depth : Int
  alive : Bool
  lifecycle : String
  lifecycle_updated_unix : Int64?
  tdd_phase : LeafTddPhase?
  last_tool_call : ToolCallRecord?
  beads_issue_id : String?
} derive(Debug, Eq)

///|
pub(all) struct TuiSnapshotPr {
  pr_number : Int
  agent_id : String
  branch : String
  parent_branch : String
  pr_url : String
  review_state : String
  ci_rollup : String
  mergeable : String
  merge_state_status : String
  unresolved_threads : Int?
  merged_at_unix : Int64?
  copilot_issue_comment_seen : Bool
  copilot_skipped_reason : String?
  merge_gate_ready : Bool
  consecutive_failures : Int
  backoff_until : Int64
  fixes_pushed_at : Int64
} derive(Debug, Eq)

///|
pub(all) struct TuiBeadSummary {
  issue_id : String
  status : String
  title : String
  assignee : String
  blocks : Array[String]
} derive(Debug, Eq)

///|
fn tui_string_array_json(values : Array[String]) -> Json {
  let out : Array[Json] = []
  for value in values {
    out.push(value.to_json())
  }
  out.to_json()
}

///|
pub impl ToJson for TuiSnapshotWave with fn to_json(self) -> Json {
  {
    "run_id": self.run_id.to_json(),
    "wave": match self.wave {
      Some(v) => v.to_json()
      None => null
    },
    "integration_branch": self.integration_branch.to_json(),
    "started_at_unix": tui_optional_int64_json(self.started_at_unix),
    "supervisor_id": tui_optional_string_json(self.supervisor_id),
  }.to_json()
}

///|
pub impl ToJson for TuiSnapshotAgent with fn to_json(self) -> Json {
  {
    "agent_id": self.agent_id.to_json(),
    "role": self.role.to_wire_string().to_json(),
    "agent_type": self.agent_type.to_wire_string().to_json(),
    "parent": tui_optional_string_json(self.parent),
    "workspace": self.workspace.to_json(),
    "branch": self.branch.to_json(),
    "terminal_target": tui_optional_string_json(self.terminal_target),
    "state": self.state.to_wire_string().to_json(),
    "spawn_depth": self.spawn_depth.to_json(),
    "alive": self.alive.to_json(),
    "lifecycle": self.lifecycle.to_json(),
    "lifecycle_updated_unix": tui_optional_int64_json(
      self.lifecycle_updated_unix,
    ),
    "tdd_phase": match self.tdd_phase {
      Some(phase) => phase.to_wire_string().to_json()
      None => null
    },
    "last_tool_call": match self.last_tool_call {
      Some(record) => record.to_json()
      None => null
    },
    "beads_issue_id": tui_optional_string_json(self.beads_issue_id),
  }.to_json()
}

///|
pub impl ToJson for TuiSnapshotPr with fn to_json(self) -> Json {
  {
    "pr_number": self.pr_number.to_json(),
    "agent_id": self.agent_id.to_json(),
    "branch": self.branch.to_json(),
    "parent_branch": self.parent_branch.to_json(),
    "pr_url": self.pr_url.to_json(),
    "review_state": self.review_state.to_json(),
    "ci_rollup": self.ci_rollup.to_json(),
    "mergeable": self.mergeable.to_json(),
    "merge_state_status": self.merge_state_status.to_json(),
    "unresolved_threads": match self.unresolved_threads {
      Some(v) => v.to_json()
      None => null
    },
    "merged_at_unix": tui_optional_int64_json(self.merged_at_unix),
    "copilot_issue_comment_seen": self.copilot_issue_comment_seen.to_json(),
    "copilot_skipped_reason": tui_optional_string_json(
      self.copilot_skipped_reason,
    ),
    "merge_gate_ready": self.merge_gate_ready.to_json(),
    "consecutive_failures": self.consecutive_failures.to_json(),
    "backoff_until": self.backoff_until.to_json(),
    "fixes_pushed_at": self.fixes_pushed_at.to_json(),
  }.to_json()
}

///|
pub impl ToJson for TuiBeadSummary with fn to_json(self) -> Json {
  {
    "issue_id": self.issue_id.to_json(),
    "status": self.status.to_json(),
    "title": self.title.to_json(),
    "assignee": self.assignee.to_json(),
    "blocks": tui_string_array_json(self.blocks),
  }.to_json()
}

///|
pub impl ToJson for TuiSnapshot with fn to_json(self) -> Json {
  let agents : Array[Json] = []
  for agent in self.agents {
    agents.push(agent.to_json())
  }
  let prs : Array[Json] = []
  for pr in self.prs {
    prs.push(pr.to_json())
  }
  let beads : Array[Json] = []
  for bead in self.beads {
    beads.push(bead.to_json())
  }
  let recent_events : Array[Json] = []
  for envelope in self.recent_events {
    recent_events.push(envelope.to_json())
  }
  {
    "schema_version": self.schema_version.to_json(),
    "taken_at_ms": self.taken_at_ms.to_json(),
    "wave": self.wave.to_json(),
    "agents": agents.to_json(),
    "prs": prs.to_json(),
    "prs_as_of_ms": self.prs_as_of_ms.to_json(),
    "beads": beads.to_json(),
    "beads_as_of_ms": tui_optional_int64_json(self.beads_as_of_ms),
    "poller": self.poller.to_json(),
    "journal_seq": self.journal_seq.to_json(),
    "recent_events": recent_events.to_json(),
  }.to_json()
}

///|
fn tui_snapshot_parse_error(message : String) -> ChoirError {
  ChoirError::validation_error("tui snapshot parse error: " + message)
}

///|
pub fn parse_tui_snapshot_wave_json(
  json : Json,
) -> Result[TuiSnapshotWave, ChoirError] {
  guard json is Object(obj) else {
    return Err(tui_snapshot_parse_error("wave: expected object"))
  }
  Ok({
    run_id: json_field_string(obj, "run_id").unwrap_or(""),
    wave: json_field_int(obj, "wave"),
    integration_branch: json_field_string(obj, "integration_branch").unwrap_or(
      "",
    ),
    started_at_unix: json_field_int64(obj, "started_at_unix"),
    supervisor_id: json_field_string(obj, "supervisor_id"),
  })
}

///|
pub fn parse_tui_snapshot_agent_json(
  json : Json,
) -> Result[TuiSnapshotAgent, ChoirError] {
  guard json is Object(obj) else {
    return Err(tui_snapshot_parse_error("agent: expected object"))
  }
  let agent_id = match json_field_string(obj, "agent_id") {
    Some(v) => v
    None => return Err(tui_snapshot_parse_error("agent: agent_id"))
  }
  let role = match json_field_string(obj, "role") {
    Some(raw) =>
      match Role::try_parse_wire(raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None => return Err(tui_snapshot_parse_error("agent: role"))
  }
  let agent_type = match json_field_string(obj, "agent_type") {
    Some(raw) =>
      match AgentType::try_parse_wire(raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None => AgentType::Unknown
  }
  let state = match json_field_string(obj, "state") {
    Some(raw) =>
      match AgentState::try_parse_wire(raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None => return Err(tui_snapshot_parse_error("agent: state"))
  }
  let tdd_phase = match json_field_string(obj, "tdd_phase") {
    Some(raw) =>
      match LeafTddPhase::try_parse_wire(raw) {
        Ok(v) => Some(v)
        Err(e) => return Err(e)
      }
    None => None
  }
  let last_tool_call = match obj.get("last_tool_call") {
    Some(Object(_) as value) =>
      match parse_tool_call_record_json(value) {
        Ok(v) => Some(v)
        Err(e) => return Err(e)
      }
    _ => None
  }
  Ok({
    agent_id,
    role,
    agent_type,
    parent: json_field_string(obj, "parent"),
    workspace: json_field_string(obj, "workspace").unwrap_or(""),
    branch: json_field_string(obj, "branch").unwrap_or(""),
    terminal_target: json_field_string(obj, "terminal_target"),
    state,
    spawn_depth: json_field_int(obj, "spawn_depth").unwrap_or(0),
    alive: json_field_bool(obj, "alive").unwrap_or(false),
    lifecycle: json_field_string(obj, "lifecycle").unwrap_or(""),
    lifecycle_updated_unix: json_field_int64(obj, "lifecycle_updated_unix"),
    tdd_phase,
    last_tool_call,
    beads_issue_id: json_field_string(obj, "beads_issue_id"),
  })
}

///|
pub fn parse_tui_snapshot_pr_json(
  json : Json,
) -> Result[TuiSnapshotPr, ChoirError] {
  guard json is Object(obj) else {
    return Err(tui_snapshot_parse_error("pr: expected object"))
  }
  let pr_number = match json_field_int(obj, "pr_number") {
    Some(v) => v
    None => return Err(tui_snapshot_parse_error("pr: pr_number"))
  }
  Ok({
    pr_number,
    agent_id: json_field_string(obj, "agent_id").unwrap_or(""),
    branch: json_field_string(obj, "branch").unwrap_or(""),
    parent_branch: json_field_string(obj, "parent_branch").unwrap_or(""),
    pr_url: json_field_string(obj, "pr_url").unwrap_or(""),
    review_state: json_field_string(obj, "review_state").unwrap_or(""),
    ci_rollup: json_field_string(obj, "ci_rollup").unwrap_or(""),
    mergeable: json_field_string(obj, "mergeable").unwrap_or(""),
    merge_state_status: json_field_string(obj, "merge_state_status").unwrap_or(
      "",
    ),
    unresolved_threads: json_field_int(obj, "unresolved_threads"),
    merged_at_unix: json_field_int64(obj, "merged_at_unix"),
    copilot_issue_comment_seen: json_field_bool(
      obj, "copilot_issue_comment_seen",
    ).unwrap_or(false),
    copilot_skipped_reason: json_field_string(obj, "copilot_skipped_reason"),
    merge_gate_ready: json_field_bool(obj, "merge_gate_ready").unwrap_or(false),
    consecutive_failures: json_field_int(obj, "consecutive_failures").unwrap_or(
      0,
    ),
    backoff_until: json_field_int64(obj, "backoff_until").unwrap_or(0L),
    fixes_pushed_at: json_field_int64(obj, "fixes_pushed_at").unwrap_or(0L),
  })
}

///|
pub fn parse_tui_bead_summary_json(
  json : Json,
) -> Result[TuiBeadSummary, ChoirError] {
  guard json is Object(obj) else {
    return Err(tui_snapshot_parse_error("bead: expected object"))
  }
  let issue_id = match json_field_string(obj, "issue_id") {
    Some(v) => v
    None => return Err(tui_snapshot_parse_error("bead: issue_id"))
  }
  let blocks : Array[String] = []
  match obj.get("blocks") {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(s) => blocks.push(s)
          _ => ()
        }
      }
    _ => ()
  }
  Ok({
    issue_id,
    status: json_field_string(obj, "status").unwrap_or(""),
    title: json_field_string(obj, "title").unwrap_or(""),
    assignee: json_field_string(obj, "assignee").unwrap_or(""),
    blocks,
  })
}

///|
pub fn parse_tui_snapshot_json(json : Json) -> Result[TuiSnapshot, ChoirError] {
  guard json is Object(obj) else {
    return Err(tui_snapshot_parse_error("expected object"))
  }
  let wave = match obj.get("wave") {
    Some(value) =>
      match parse_tui_snapshot_wave_json(value) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None => return Err(tui_snapshot_parse_error("missing wave"))
  }
  let agents : Array[TuiSnapshotAgent] = []
  match obj.get("agents") {
    Some(Array(items)) =>
      for item in items {
        match parse_tui_snapshot_agent_json(item) {
          Ok(v) => agents.push(v)
          Err(e) => return Err(e)
        }
      }
    _ => return Err(tui_snapshot_parse_error("missing agents"))
  }
  let prs : Array[TuiSnapshotPr] = []
  match obj.get("prs") {
    Some(Array(items)) =>
      for item in items {
        match parse_tui_snapshot_pr_json(item) {
          Ok(v) => prs.push(v)
          Err(e) => return Err(e)
        }
      }
    _ => return Err(tui_snapshot_parse_error("missing prs"))
  }
  let beads : Array[TuiBeadSummary] = []
  match obj.get("beads") {
    Some(Array(items)) =>
      for item in items {
        match parse_tui_bead_summary_json(item) {
          Ok(v) => beads.push(v)
          Err(e) => return Err(e)
        }
      }
    _ => ()
  }
  let poller = match obj.get("poller") {
    Some(value) =>
      match parse_poller_vitals_json(value) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None => return Err(tui_snapshot_parse_error("missing poller"))
  }
  let recent_events : Array[TuiEventEnvelope] = []
  match obj.get("recent_events") {
    Some(Array(items)) =>
      for item in items {
        match parse_tui_event_envelope_json(item) {
          Ok(v) => recent_events.push(v)
          Err(e) => return Err(e)
        }
      }
    _ => ()
  }
  let journal_seq = match json_field_int64(obj, "journal_seq") {
    Some(v) => v
    None => return Err(tui_snapshot_parse_error("missing journal_seq"))
  }
  Ok({
    schema_version: json_field_int(obj, "schema_version").unwrap_or(0),
    taken_at_ms: json_field_int64(obj, "taken_at_ms").unwrap_or(0L),
    wave,
    agents,
    prs,
    prs_as_of_ms: json_field_int64(obj, "prs_as_of_ms").unwrap_or(0L),
    beads,
    beads_as_of_ms: json_field_int64(obj, "beads_as_of_ms"),
    poller,
    journal_seq,
    recent_events,
  })
}

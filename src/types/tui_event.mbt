///|
/// Last tool call recorded per agent at the dispatch layer. Lives in the
/// agent registry (not on the connection) so it survives reconnects and is
/// snapshot-able.
pub(all) struct ToolCallRecord {
  tool : String
  ok : Bool
  duration_ms : Int64
  ts_ms : Int64
} derive(Debug, Eq)

///|
pub impl ToJson for ToolCallRecord with fn to_json(self) -> Json {
  {
    "tool": self.tool.to_json(),
    "ok": self.ok.to_json(),
    "duration_ms": self.duration_ms.to_json(),
    "ts_ms": self.ts_ms.to_json(),
  }.to_json()
}

///|
pub fn parse_tool_call_record_json(
  json : Json,
) -> Result[ToolCallRecord, ChoirError] {
  guard json is Object(obj) else {
    return Err(
      ChoirError::validation_error("tool call record: expected object"),
    )
  }
  let tool = match json_field_string(obj, "tool") {
    Some(v) => v
    None => return Err(ChoirError::validation_error("tool call record: tool"))
  }
  let ok = match json_field_bool(obj, "ok") {
    Some(v) => v
    None => return Err(ChoirError::validation_error("tool call record: ok"))
  }
  let duration_ms = match json_field_int64(obj, "duration_ms") {
    Some(v) => v
    None =>
      return Err(ChoirError::validation_error("tool call record: duration_ms"))
  }
  let ts_ms = match json_field_int64(obj, "ts_ms") {
    Some(v) => v
    None => return Err(ChoirError::validation_error("tool call record: ts_ms"))
  }
  Ok({ tool, ok, duration_ms, ts_ms })
}

///|
/// Poller health, updated once per poller tick and included in the canonical
/// snapshot. `last_evt_age_sec` is computed from the journal's latest event
/// timestamp; `None` means unknown (renders as a red warning, never silently).
pub(all) struct PollerVitals {
  last_tick_duration_ms : Int64
  consecutive_errors : Int
  tracked_prs : Int
  last_tick_at_ms : Int64
  last_evt_age_sec : Int64?
} derive(Debug, Eq)

///|
pub fn PollerVitals::initial() -> PollerVitals {
  {
    last_tick_duration_ms: 0L,
    consecutive_errors: 0,
    tracked_prs: 0,
    last_tick_at_ms: 0L,
    last_evt_age_sec: None,
  }
}

///|
pub impl ToJson for PollerVitals with fn to_json(self) -> Json {
  {
    "last_tick_duration_ms": self.last_tick_duration_ms.to_json(),
    "consecutive_errors": self.consecutive_errors.to_json(),
    "tracked_prs": self.tracked_prs.to_json(),
    "last_tick_at_ms": self.last_tick_at_ms.to_json(),
    "last_evt_age_sec": match self.last_evt_age_sec {
      Some(v) => v.to_json()
      None => null
    },
  }.to_json()
}

///|
pub fn parse_poller_vitals_json(
  json : Json,
) -> Result[PollerVitals, ChoirError] {
  guard json is Object(obj) else {
    return Err(ChoirError::validation_error("poller vitals: expected object"))
  }
  let last_tick_duration_ms = json_field_int64(obj, "last_tick_duration_ms").unwrap_or(
    0L,
  )
  let consecutive_errors = json_field_int(obj, "consecutive_errors").unwrap_or(
    0,
  )
  let tracked_prs = json_field_int(obj, "tracked_prs").unwrap_or(0)
  let last_tick_at_ms = json_field_int64(obj, "last_tick_at_ms").unwrap_or(0L)
  let last_evt_age_sec = json_field_int64(obj, "last_evt_age_sec")
  Ok({
    last_tick_duration_ms,
    consecutive_errors,
    tracked_prs,
    last_tick_at_ms,
    last_evt_age_sec,
  })
}

///|
/// Kind of PR status change observed by the poller. Mirrors the typed poll
/// events in `src/poller/detect.mbt` one-to-one (PRMerged is a separate
/// `TuiEvent` variant because it carries merge metadata).
pub(all) enum PrEventKind {
  ReviewReceived
  ReviewCommented
  PrReady
  FixesPushed
  ReviewTimeout
  CiFailed
  CiFailureCleared
  CiSucceeded
  CopilotIssueCommentSeen
  MergeReady
  ReviewThreadsResolved
} derive(Debug, Eq)

///|
pub fn PrEventKind::to_wire_string(self : PrEventKind) -> String {
  match self {
    ReviewReceived => "review_received"
    ReviewCommented => "review_commented"
    PrReady => "pr_ready"
    FixesPushed => "fixes_pushed"
    ReviewTimeout => "review_timeout"
    CiFailed => "ci_failed"
    CiFailureCleared => "ci_failure_cleared"
    CiSucceeded => "ci_succeeded"
    CopilotIssueCommentSeen => "copilot_issue_comment_seen"
    MergeReady => "merge_ready"
    ReviewThreadsResolved => "review_threads_resolved"
  }
}

///|
pub fn PrEventKind::try_parse_wire(
  s : String,
) -> Result[PrEventKind, ChoirError] {
  match s {
    "review_received" => Ok(ReviewReceived)
    "review_commented" => Ok(ReviewCommented)
    "pr_ready" => Ok(PrReady)
    "fixes_pushed" => Ok(FixesPushed)
    "review_timeout" => Ok(ReviewTimeout)
    "ci_failed" => Ok(CiFailed)
    "ci_failure_cleared" => Ok(CiFailureCleared)
    "ci_succeeded" => Ok(CiSucceeded)
    "copilot_issue_comment_seen" => Ok(CopilotIssueCommentSeen)
    "merge_ready" => Ok(MergeReady)
    "review_threads_resolved" => Ok(ReviewThreadsResolved)
    _ => Err(ChoirError::validation_error("unknown pr event kind: " + s))
  }
}

///|
pub(all) enum TuiLifecycleKind {
  SupervisorPlanning
  SupervisorDispatching
  SupervisorSupervising
  SupervisorWaveComplete
  SupervisorOwnPrFiled
  SupervisorDone
  SupervisorFailed
  DevWorking
  DevWaitingForRedGate
  DevReviewOwned
  DevChangesRequested
  DevExitRequestedDeferred
  DevExitable
  DevDone
  DevFailed
  WorkerWorking
  WorkerExitable
  WorkerDone
  WorkerFailed
} derive(Debug, Eq)

///|
pub fn TuiLifecycleKind::to_wire_string(self : TuiLifecycleKind) -> String {
  match self {
    SupervisorPlanning => "supervisor_planning"
    SupervisorDispatching => "supervisor_dispatching"
    SupervisorSupervising => "supervisor_supervising"
    SupervisorWaveComplete => "supervisor_wave_complete"
    SupervisorOwnPrFiled => "supervisor_own_pr_filed"
    SupervisorDone => "supervisor_done"
    SupervisorFailed => "supervisor_failed"
    DevWorking => "dev_working"
    DevWaitingForRedGate => "dev_waiting_for_red_gate"
    DevReviewOwned => "dev_review_owned"
    DevChangesRequested => "dev_changes_requested"
    DevExitRequestedDeferred => "dev_exit_requested_deferred"
    DevExitable => "dev_exitable"
    DevDone => "dev_done"
    DevFailed => "dev_failed"
    WorkerWorking => "worker_working"
    WorkerExitable => "worker_exitable"
    WorkerDone => "worker_done"
    WorkerFailed => "worker_failed"
  }
}

///|
pub fn TuiLifecycleKind::try_parse_wire(
  s : String,
) -> Result[TuiLifecycleKind, ChoirError] {
  match s {
    "supervisor_planning" => Ok(SupervisorPlanning)
    "supervisor_dispatching" => Ok(SupervisorDispatching)
    "supervisor_supervising" => Ok(SupervisorSupervising)
    "supervisor_wave_complete" => Ok(SupervisorWaveComplete)
    "supervisor_own_pr_filed" => Ok(SupervisorOwnPrFiled)
    "supervisor_done" => Ok(SupervisorDone)
    "supervisor_failed" => Ok(SupervisorFailed)
    "dev_working" => Ok(DevWorking)
    "dev_waiting_for_red_gate" => Ok(DevWaitingForRedGate)
    "dev_review_owned" => Ok(DevReviewOwned)
    "dev_changes_requested" => Ok(DevChangesRequested)
    "dev_exit_requested_deferred" => Ok(DevExitRequestedDeferred)
    "dev_exitable" => Ok(DevExitable)
    "dev_done" => Ok(DevDone)
    "dev_failed" => Ok(DevFailed)
    "worker_working" => Ok(WorkerWorking)
    "worker_exitable" => Ok(WorkerExitable)
    "worker_done" => Ok(WorkerDone)
    "worker_failed" => Ok(WorkerFailed)
    _ => Err(ChoirError::validation_error("unknown tui lifecycle kind: " + s))
  }
}

///|
pub fn TuiLifecycleKind::is_failed(self : TuiLifecycleKind) -> Bool {
  match self {
    SupervisorFailed | DevFailed | WorkerFailed => true
    _ => false
  }
}

///|
pub fn LifecycleTrigger::try_parse_wire(
  s : String,
) -> Result[LifecycleTrigger, ChoirError] {
  match s {
    "ChildSpawned" => Ok(ChildSpawned)
    "ChildCompleted" => Ok(ChildCompleted)
    "ChildFailed" => Ok(ChildFailed)
    "PRMerged" => Ok(PRMerged)
    "AllChildrenDone" => Ok(AllChildrenDone)
    "OwnPRFiled" => Ok(OwnPRFiled)
    "PRCreated" => Ok(PRCreated)
    "NotifyParentSuccess" => Ok(NotifyParentSuccess)
    "NotifyParentFailure" => Ok(NotifyParentFailure)
    "ExitRequested" => Ok(ExitRequested)
    "MergeObserved" => Ok(MergeObserved)
    "ReviewReceived" => Ok(ReviewReceived)
    "ReviewApproved" => Ok(ReviewApproved)
    "FixesPushed" => Ok(FixesPushed)
    "ChildUpdated" => Ok(ChildUpdated)
    "ChildRemoved" => Ok(ChildRemoved)
    "TransportDisconnected" => Ok(TransportDisconnected)
    "TransportReconnected" => Ok(TransportReconnected)
    "ExitMerged" => Ok(ExitMerged)
    "ExitDisconnected" => Ok(ExitDisconnected)
    "ExitShutdown" => Ok(ExitShutdown)
    "FinalizeComplete" => Ok(FinalizeComplete)
    _ => Err(ChoirError::validation_error("unknown lifecycle trigger: " + s))
  }
}

///|
/// Daemon-observed orchestration event for the TUI journal. Every variant is
/// self-contained and replayable: no payload depends on mutable state at read
/// time. Emission is restricted to four choke points (tool dispatch
/// completion, lifecycle store transitions, registry mutations, the poller);
/// if a piece of state is only visible in a log line, that is a missing
/// event — add a variant here, never parse logs.
pub(all) enum TuiEvent {
  AgentRegistered(
    agent_id~ : String,
    role~ : Role,
    agent_type~ : AgentType,
    parent~ : String?,
    workspace~ : String,
    branch~ : String,
    terminal_target~ : String?,
    state~ : AgentState,
    spawn_depth~ : Int
  )
  AgentStateChanged(agent_id~ : String, state~ : AgentState)
  AgentRemoved(agent_id~ : String)
  LifecycleChanged(
    agent_id~ : String,
    from~ : TuiLifecycleKind,
    to~ : TuiLifecycleKind,
    from_label~ : String,
    to_label~ : String,
    trigger~ : LifecycleTrigger
  )
  TddPhaseChanged(agent_id~ : String, phase~ : LeafTddPhase)
  TddGateViolation(agent_id~ : String, tool~ : String, detail~ : String)
  ToolCallCompleted(
    agent_id~ : String,
    tool~ : String,
    ok~ : Bool,
    duration_ms~ : Int64
  )
  PrTracked(pr_number~ : Int, agent_id~ : String, branch~ : String)
  PrStatusChanged(
    pr_number~ : Int,
    agent_id~ : String,
    kind~ : PrEventKind,
    detail~ : String
  )
  PrMerged(
    pr_number~ : Int,
    agent_id~ : String,
    branch~ : String,
    merged_at_unix~ : Int64?
  )
  PollerTick(duration_ms~ : Int64, errors~ : Int, tracked_prs~ : Int)
  MessageQueued(
    recipient_id~ : String,
    sender_id~ : String,
    message_id~ : String
  )
  MessageDelivered(recipient_id~ : String, message_id~ : String)
  BeadSummaryChanged(issue_id~ : String, status~ : String, title~ : String)
  BeadRemoved(issue_id~ : String)
  DaemonShutdown(reason~ : String)
} derive(Debug, Eq)

///|
fn tui_optional_string_json(value : String?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => null
  }
}

///|
fn tui_optional_int64_json(value : Int64?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => null
  }
}

///|
pub fn TuiEvent::type_tag(self : TuiEvent) -> String {
  match self {
    AgentRegistered(..) => "agent_registered"
    AgentStateChanged(..) => "agent_state_changed"
    AgentRemoved(..) => "agent_removed"
    LifecycleChanged(..) => "lifecycle_changed"
    TddPhaseChanged(..) => "tdd_phase_changed"
    TddGateViolation(..) => "tdd_gate_violation"
    ToolCallCompleted(..) => "tool_call_completed"
    PrTracked(..) => "pr_tracked"
    PrStatusChanged(..) => "pr_status_changed"
    PrMerged(..) => "pr_merged"
    PollerTick(..) => "poller_tick"
    MessageQueued(..) => "message_queued"
    MessageDelivered(..) => "message_delivered"
    BeadSummaryChanged(..) => "bead_summary_changed"
    BeadRemoved(..) => "bead_removed"
    DaemonShutdown(..) => "daemon_shutdown"
  }
}

///|
fn TuiEvent::data_json(self : TuiEvent) -> Json {
  match self {
    AgentRegistered(
      agent_id~,
      role~,
      agent_type~,
      parent~,
      workspace~,
      branch~,
      terminal_target~,
      state~,
      spawn_depth~
    ) =>
      {
        "agent_id": agent_id.to_json(),
        "role": role.to_wire_string().to_json(),
        "agent_type": agent_type.to_wire_string().to_json(),
        "parent": tui_optional_string_json(parent),
        "workspace": workspace.to_json(),
        "branch": branch.to_json(),
        "terminal_target": tui_optional_string_json(terminal_target),
        "state": state.to_wire_string().to_json(),
        "spawn_depth": spawn_depth.to_json(),
      }.to_json()
    AgentStateChanged(agent_id~, state~) =>
      {
        "agent_id": agent_id.to_json(),
        "state": state.to_wire_string().to_json(),
      }.to_json()
    AgentRemoved(agent_id~) => { "agent_id": agent_id.to_json() }.to_json()
    LifecycleChanged(agent_id~, from~, to~, from_label~, to_label~, trigger~) =>
      {
        "agent_id": agent_id.to_json(),
        "from": from.to_wire_string().to_json(),
        "to": to.to_wire_string().to_json(),
        "from_label": from_label.to_json(),
        "to_label": to_label.to_json(),
        "trigger": trigger.to_wire_string().to_json(),
      }.to_json()
    TddPhaseChanged(agent_id~, phase~) =>
      {
        "agent_id": agent_id.to_json(),
        "phase": phase.to_wire_string().to_json(),
      }.to_json()
    TddGateViolation(agent_id~, tool~, detail~) =>
      {
        "agent_id": agent_id.to_json(),
        "tool": tool.to_json(),
        "detail": detail.to_json(),
      }.to_json()
    ToolCallCompleted(agent_id~, tool~, ok~, duration_ms~) =>
      {
        "agent_id": agent_id.to_json(),
        "tool": tool.to_json(),
        "ok": ok.to_json(),
        "duration_ms": duration_ms.to_json(),
      }.to_json()
    PrTracked(pr_number~, agent_id~, branch~) =>
      {
        "pr_number": pr_number.to_json(),
        "agent_id": agent_id.to_json(),
        "branch": branch.to_json(),
      }.to_json()
    PrStatusChanged(pr_number~, agent_id~, kind~, detail~) =>
      {
        "pr_number": pr_number.to_json(),
        "agent_id": agent_id.to_json(),
        "kind": kind.to_wire_string().to_json(),
        "detail": detail.to_json(),
      }.to_json()
    PrMerged(pr_number~, agent_id~, branch~, merged_at_unix~) =>
      {
        "pr_number": pr_number.to_json(),
        "agent_id": agent_id.to_json(),
        "branch": branch.to_json(),
        "merged_at_unix": tui_optional_int64_json(merged_at_unix),
      }.to_json()
    PollerTick(duration_ms~, errors~, tracked_prs~) =>
      {
        "duration_ms": duration_ms.to_json(),
        "errors": errors.to_json(),
        "tracked_prs": tracked_prs.to_json(),
      }.to_json()
    MessageQueued(recipient_id~, sender_id~, message_id~) =>
      {
        "recipient_id": recipient_id.to_json(),
        "sender_id": sender_id.to_json(),
        "message_id": message_id.to_json(),
      }.to_json()
    MessageDelivered(recipient_id~, message_id~) =>
      {
        "recipient_id": recipient_id.to_json(),
        "message_id": message_id.to_json(),
      }.to_json()
    BeadSummaryChanged(issue_id~, status~, title~) =>
      {
        "issue_id": issue_id.to_json(),
        "status": status.to_json(),
        "title": title.to_json(),
      }.to_json()
    BeadRemoved(issue_id~) => { "issue_id": issue_id.to_json() }.to_json()
    DaemonShutdown(reason~) => { "reason": reason.to_json() }.to_json()
  }
}

///|
pub impl ToJson for TuiEvent with fn to_json(self) -> Json {
  { "type": self.type_tag().to_json(), "data": self.data_json() }.to_json()
}

///|
fn tui_event_parse_error(message : String) -> ChoirError {
  ChoirError::validation_error("tui event parse error: " + message)
}

///|
fn tui_required_string(
  obj : Map[String, Json],
  key : String,
) -> Result[String, ChoirError] {
  match json_field_string(obj, key) {
    Some(v) => Ok(v)
    None => Err(tui_event_parse_error("missing string field: " + key))
  }
}

///|
fn tui_required_int(
  obj : Map[String, Json],
  key : String,
) -> Result[Int, ChoirError] {
  match json_field_int(obj, key) {
    Some(v) => Ok(v)
    None => Err(tui_event_parse_error("missing int field: " + key))
  }
}

///|
fn tui_required_int64(
  obj : Map[String, Json],
  key : String,
) -> Result[Int64, ChoirError] {
  match json_field_int64(obj, key) {
    Some(v) => Ok(v)
    None => Err(tui_event_parse_error("missing int64 field: " + key))
  }
}

///|
fn tui_required_bool(
  obj : Map[String, Json],
  key : String,
) -> Result[Bool, ChoirError] {
  match json_field_bool(obj, key) {
    Some(v) => Ok(v)
    None => Err(tui_event_parse_error("missing bool field: " + key))
  }
}

///|
fn parse_tui_event_data(
  type_tag : String,
  obj : Map[String, Json],
) -> Result[TuiEvent, ChoirError] {
  match type_tag {
    "agent_registered" => {
      let agent_id = match tui_required_string(obj, "agent_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let role = match tui_required_string(obj, "role") {
        Ok(v) =>
          match Role::try_parse_wire(v) {
            Ok(parsed) => parsed
            Err(e) => return Err(e)
          }
        Err(e) => return Err(e)
      }
      let agent_type = match tui_required_string(obj, "agent_type") {
        Ok(v) =>
          match AgentType::try_parse_wire(v) {
            Ok(parsed) => parsed
            Err(e) => return Err(e)
          }
        Err(e) => return Err(e)
      }
      let parent = json_field_string(obj, "parent")
      let workspace = match tui_required_string(obj, "workspace") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let branch = match tui_required_string(obj, "branch") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let terminal_target = json_field_string(obj, "terminal_target")
      let state = match tui_required_string(obj, "state") {
        Ok(v) =>
          match AgentState::try_parse_wire(v) {
            Ok(parsed) => parsed
            Err(e) => return Err(e)
          }
        Err(e) => return Err(e)
      }
      let spawn_depth = match tui_required_int(obj, "spawn_depth") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(
        TuiEvent::AgentRegistered(
          agent_id~,
          role~,
          agent_type~,
          parent~,
          workspace~,
          branch~,
          terminal_target~,
          state~,
          spawn_depth~,
        ),
      )
    }
    "agent_state_changed" => {
      let agent_id = match tui_required_string(obj, "agent_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let state = match tui_required_string(obj, "state") {
        Ok(v) =>
          match AgentState::try_parse_wire(v) {
            Ok(parsed) => parsed
            Err(e) => return Err(e)
          }
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::AgentStateChanged(agent_id~, state~))
    }
    "agent_removed" =>
      match tui_required_string(obj, "agent_id") {
        Ok(agent_id) => Ok(TuiEvent::AgentRemoved(agent_id~))
        Err(e) => Err(e)
      }
    "lifecycle_changed" => {
      let agent_id = match tui_required_string(obj, "agent_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let from_raw = match tui_required_string(obj, "from") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let from = match TuiLifecycleKind::try_parse_wire(from_raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let to_raw = match tui_required_string(obj, "to") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let to = match TuiLifecycleKind::try_parse_wire(to_raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let from_label = match tui_required_string(obj, "from_label") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let to_label = match tui_required_string(obj, "to_label") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let trigger = match tui_required_string(obj, "trigger") {
        Ok(v) =>
          match LifecycleTrigger::try_parse_wire(v) {
            Ok(parsed) => parsed
            Err(e) => return Err(e)
          }
        Err(e) => return Err(e)
      }
      Ok(
        TuiEvent::LifecycleChanged(
          agent_id~,
          from~,
          to~,
          from_label~,
          to_label~,
          trigger~,
        ),
      )
    }
    "tdd_phase_changed" => {
      let agent_id = match tui_required_string(obj, "agent_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let phase = match tui_required_string(obj, "phase") {
        Ok(v) =>
          match LeafTddPhase::try_parse_wire(v) {
            Ok(parsed) => parsed
            Err(e) => return Err(e)
          }
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::TddPhaseChanged(agent_id~, phase~))
    }
    "tdd_gate_violation" => {
      let agent_id = match tui_required_string(obj, "agent_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let tool = match tui_required_string(obj, "tool") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let detail = match tui_required_string(obj, "detail") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::TddGateViolation(agent_id~, tool~, detail~))
    }
    "tool_call_completed" => {
      let agent_id = match tui_required_string(obj, "agent_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let tool = match tui_required_string(obj, "tool") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let ok = match tui_required_bool(obj, "ok") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let duration_ms = match tui_required_int64(obj, "duration_ms") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::ToolCallCompleted(agent_id~, tool~, ok~, duration_ms~))
    }
    "pr_tracked" => {
      let pr_number = match tui_required_int(obj, "pr_number") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let agent_id = match tui_required_string(obj, "agent_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let branch = match tui_required_string(obj, "branch") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::PrTracked(pr_number~, agent_id~, branch~))
    }
    "pr_status_changed" => {
      let pr_number = match tui_required_int(obj, "pr_number") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let agent_id = match tui_required_string(obj, "agent_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let kind = match tui_required_string(obj, "kind") {
        Ok(v) =>
          match PrEventKind::try_parse_wire(v) {
            Ok(parsed) => parsed
            Err(e) => return Err(e)
          }
        Err(e) => return Err(e)
      }
      let detail = match tui_required_string(obj, "detail") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::PrStatusChanged(pr_number~, agent_id~, kind~, detail~))
    }
    "pr_merged" => {
      let pr_number = match tui_required_int(obj, "pr_number") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let agent_id = match tui_required_string(obj, "agent_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let branch = match tui_required_string(obj, "branch") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let merged_at_unix = json_field_int64(obj, "merged_at_unix")
      Ok(TuiEvent::PrMerged(pr_number~, agent_id~, branch~, merged_at_unix~))
    }
    "poller_tick" => {
      let duration_ms = match tui_required_int64(obj, "duration_ms") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let errors = match tui_required_int(obj, "errors") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let tracked_prs = match tui_required_int(obj, "tracked_prs") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::PollerTick(duration_ms~, errors~, tracked_prs~))
    }
    "message_queued" => {
      let recipient_id = match tui_required_string(obj, "recipient_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let sender_id = match tui_required_string(obj, "sender_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let message_id = match tui_required_string(obj, "message_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::MessageQueued(recipient_id~, sender_id~, message_id~))
    }
    "message_delivered" => {
      let recipient_id = match tui_required_string(obj, "recipient_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let message_id = match tui_required_string(obj, "message_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::MessageDelivered(recipient_id~, message_id~))
    }
    "bead_summary_changed" => {
      let issue_id = match tui_required_string(obj, "issue_id") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let status = match tui_required_string(obj, "status") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let title = match tui_required_string(obj, "title") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(TuiEvent::BeadSummaryChanged(issue_id~, status~, title~))
    }
    "bead_removed" =>
      match tui_required_string(obj, "issue_id") {
        Ok(issue_id) => Ok(TuiEvent::BeadRemoved(issue_id~))
        Err(e) => Err(e)
      }
    "daemon_shutdown" =>
      match tui_required_string(obj, "reason") {
        Ok(reason) => Ok(TuiEvent::DaemonShutdown(reason~))
        Err(e) => Err(e)
      }
    _ => Err(tui_event_parse_error("unknown event type: " + type_tag))
  }
}

///|
pub fn parse_tui_event_json(json : Json) -> Result[TuiEvent, ChoirError] {
  guard json is Object(obj) else {
    return Err(tui_event_parse_error("expected object"))
  }
  let type_tag = match json_field_string(obj, "type") {
    Some(v) => v
    None => return Err(tui_event_parse_error("missing type"))
  }
  match obj.get("data") {
    Some(Object(data)) => parse_tui_event_data(type_tag, data)
    _ => Err(tui_event_parse_error("missing data object"))
  }
}

///|
/// Journal envelope: every event carries a monotonically increasing sequence
/// number and a timestamp. Serialized one-per-line in
/// `.choir/events.journal.jsonl`.
pub(all) struct TuiEventEnvelope {
  seq : Int64
  ts_ms : Int64
  event : TuiEvent
} derive(Debug, Eq)

///|
pub impl ToJson for TuiEventEnvelope with fn to_json(self) -> Json {
  {
    "seq": self.seq.to_json(),
    "ts_ms": self.ts_ms.to_json(),
    "type": self.event.type_tag().to_json(),
    "data": self.event.data_json(),
  }.to_json()
}

///|
pub fn TuiEventEnvelope::to_jsonl_line(self : TuiEventEnvelope) -> String {
  self.to_json().stringify() + "\n"
}

///|
pub fn parse_tui_event_envelope_json(
  json : Json,
) -> Result[TuiEventEnvelope, ChoirError] {
  guard json is Object(obj) else {
    return Err(tui_event_parse_error("expected envelope object"))
  }
  let seq = match json_field_int64(obj, "seq") {
    Some(v) => v
    None => return Err(tui_event_parse_error("missing seq"))
  }
  let ts_ms = match json_field_int64(obj, "ts_ms") {
    Some(v) => v
    None => return Err(tui_event_parse_error("missing ts_ms"))
  }
  let type_tag = match json_field_string(obj, "type") {
    Some(v) => v
    None => return Err(tui_event_parse_error("missing type"))
  }
  let event = match obj.get("data") {
    Some(Object(data)) =>
      match parse_tui_event_data(type_tag, data) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    _ => return Err(tui_event_parse_error("missing data object"))
  }
  Ok({ seq, ts_ms, event })
}

///|
pub fn parse_tui_event_envelope_line(
  line : String,
) -> Result[TuiEventEnvelope, ChoirError] {
  let trimmed = line.trim().to_owned()
  if trimmed == "" {
    return Err(tui_event_parse_error("empty line"))
  }
  let json = @json.parse(trimmed) catch {
    _ => return Err(tui_event_parse_error("invalid JSON line"))
  }
  parse_tui_event_envelope_json(json)
}

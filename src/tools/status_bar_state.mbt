///|
pub(all) enum StatusBarThreadCount {
  NoPR
  Unknown
  Count(Int)
} derive(Debug, Eq)

///|
pub(all) enum PaneAttention {
  Clear
  Needed
  Unknown
} derive(Debug, Eq)

///|
pub(all) struct StatusBarPane {
  zellij_pane_id : Int
  agent_id : String
  role : String
  agent_type : String
  lifecycle : String
  pr_number : Int?
  unresolved_threads : StatusBarThreadCount
  ci_rollup : String
  attention_needed : PaneAttention
  parent_agent_id : String?
  last_activity_unix : Int64
} derive(Debug, Eq)

///|
pub(all) struct StatusBarSnapshot {
  schema_version : Int
  taken_at_ms : Int64
  panes : Array[StatusBarPane]
} derive(Debug, Eq)

///|
pub(all) struct StatusBarRegistryEntry {
  agent : @types.Agent
  lifecycle : @phase.AgentLifecycle
} derive(Debug)

///|
pub(all) struct ZellijListPanesEntry {
  pane_id : Int
  tab_name : String
  pane_name : String
} derive(Debug, Eq)

///|
pub(all) struct ZellijListPanesSnapshot {
  entries : Array[ZellijListPanesEntry]
} derive(Debug, Eq)

///|
pub(all) struct CachedListPanesSnapshot {
  snapshot : ZellijListPanesSnapshot
  expires_at_unix_ms : Int64
} derive(Debug, Eq)

///|
pub const LIST_PANES_TTL_MS : Int64 = 3000L

///|
pub fn empty_zellij_list_panes_snapshot() -> ZellijListPanesSnapshot {
  { entries: [] }
}

///|
pub fn list_panes_cache_lookup(
  map : Map[String, CachedListPanesSnapshot],
  session : String,
  now_ms : Int64,
) -> ZellijListPanesSnapshot? {
  match map.get(session) {
    Some(entry) if entry.expires_at_unix_ms > now_ms => Some(entry.snapshot)
    _ => None
  }
}

///|
fn status_bar_null_json() -> Json {
  @json.parse("null") catch {
    _ => "".to_json()
  }
}

///|
fn status_bar_thread_count_json(value : StatusBarThreadCount) -> Json {
  match value {
    NoPR => "none".to_json()
    Unknown => "unknown".to_json()
    Count(v) => v.to_json()
  }
}

///|
fn status_bar_thread_count_from_json(
  value : Json,
  path : @json.JsonPath,
) -> StatusBarThreadCount raise @json.JsonDecodeError {
  match value {
    Number(_, ..) => {
      let count : Int = @json.from_json(value, path~)
      StatusBarThreadCount::Count(count)
    }
    String("none") => StatusBarThreadCount::NoPR
    String("unknown") => StatusBarThreadCount::Unknown
    String(_) =>
      raise @json.JsonDecodeError(
        (
          path, "status_bar_state: expected unresolved_threads count/none/unknown",
        ),
      )
    _ =>
      raise @json.JsonDecodeError(
        (
          path, "status_bar_state: expected unresolved_threads count/none/unknown",
        ),
      )
  }
}

///|
fn pane_attention_json(value : PaneAttention) -> Json {
  match value {
    Clear => "clear".to_json()
    Needed => "needed".to_json()
    Unknown => "unknown".to_json()
  }
}

///|
fn pane_attention_from_json(
  value : Json,
  path : @json.JsonPath,
) -> PaneAttention raise @json.JsonDecodeError {
  match value {
    String("clear") => PaneAttention::Clear
    String("needed") => PaneAttention::Needed
    String("unknown") => PaneAttention::Unknown
    _ =>
      raise @json.JsonDecodeError(
        (
          path, "status_bar_state: expected attention_needed clear/needed/unknown",
        ),
      )
  }
}

///|
fn status_bar_optional_int_json(value : Int?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => status_bar_null_json()
  }
}

///|
fn status_bar_optional_string_json(value : String?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => status_bar_null_json()
  }
}

///|
fn status_bar_int64_json(v : Int64) -> Json {
  Json::number(v.to_double(), repr=v.to_string())
}

///|
fn status_bar_int64_from_json(
  value : Json,
  path : @json.JsonPath,
) -> Int64 raise @json.JsonDecodeError {
  match value {
    Number(n, ..) => {
      let v = n.to_int64()
      if v.to_double() == n {
        v
      } else {
        raise @json.JsonDecodeError(
          (path, "status_bar_state: expected integer"),
        )
      }
    }
    String(_) => @json.from_json(value, path~)
    _ =>
      raise @json.JsonDecodeError((path, "status_bar_state: expected integer"))
  }
}

///|
pub impl ToJson for StatusBarPane with fn to_json(self) -> Json {
  {
    "zellij_pane_id": self.zellij_pane_id.to_json(),
    "agent_id": self.agent_id.to_json(),
    "role": self.role.to_json(),
    "agent_type": self.agent_type.to_json(),
    "lifecycle": self.lifecycle.to_json(),
    "pr_number": status_bar_optional_int_json(self.pr_number),
    "unresolved_threads": status_bar_thread_count_json(self.unresolved_threads),
    "ci_rollup": self.ci_rollup.to_json(),
    "attention_needed": pane_attention_json(self.attention_needed),
    "parent_agent_id": status_bar_optional_string_json(self.parent_agent_id),
    "last_activity_unix": status_bar_int64_json(self.last_activity_unix),
  }.to_json()
}

///|
pub impl FromJson for StatusBarPane with fn from_json(json, path) {
  match json {
    Object(fields) => {
      let zellij_pane_id : Int = match fields.get("zellij_pane_id") {
        Some(value) =>
          @json.from_json(value, path=path.add_key("zellij_pane_id"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("zellij_pane_id"),
              "StatusBarPane::from_json: missing field zellij_pane_id",
            ),
          )
      }
      let agent_id : String = match fields.get("agent_id") {
        Some(value) => @json.from_json(value, path=path.add_key("agent_id"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("agent_id"),
              "StatusBarPane::from_json: missing field agent_id",
            ),
          )
      }
      let role : String = match fields.get("role") {
        Some(value) => @json.from_json(value, path=path.add_key("role"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("role"),
              "StatusBarPane::from_json: missing field role",
            ),
          )
      }
      let agent_type : String = match fields.get("agent_type") {
        Some(value) => @json.from_json(value, path=path.add_key("agent_type"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("agent_type"),
              "StatusBarPane::from_json: missing field agent_type",
            ),
          )
      }
      let lifecycle : String = match fields.get("lifecycle") {
        Some(value) => @json.from_json(value, path=path.add_key("lifecycle"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("lifecycle"),
              "StatusBarPane::from_json: missing field lifecycle",
            ),
          )
      }
      let pr_number : Int? = match fields.get("pr_number") {
        Some(Null) => None
        Some(value) =>
          Some(@json.from_json(value, path=path.add_key("pr_number")))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("pr_number"),
              "StatusBarPane::from_json: missing field pr_number",
            ),
          )
      }
      let unresolved_threads : StatusBarThreadCount = match
        fields.get("unresolved_threads") {
        Some(value) =>
          status_bar_thread_count_from_json(
            value,
            path.add_key("unresolved_threads"),
          )
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("unresolved_threads"),
              "StatusBarPane::from_json: missing field unresolved_threads",
            ),
          )
      }
      let ci_rollup : String = match fields.get("ci_rollup") {
        Some(value) => @json.from_json(value, path=path.add_key("ci_rollup"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("ci_rollup"),
              "StatusBarPane::from_json: missing field ci_rollup",
            ),
          )
      }
      let attention_needed : PaneAttention = match
        fields.get("attention_needed") {
        Some(value) =>
          pane_attention_from_json(value, path.add_key("attention_needed"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("attention_needed"),
              "StatusBarPane::from_json: missing field attention_needed",
            ),
          )
      }
      let parent_agent_id : String? = match fields.get("parent_agent_id") {
        Some(Null) => None
        Some(value) =>
          Some(@json.from_json(value, path=path.add_key("parent_agent_id")))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("parent_agent_id"),
              "StatusBarPane::from_json: missing field parent_agent_id",
            ),
          )
      }
      let last_activity_unix : Int64 = match fields.get("last_activity_unix") {
        Some(value) =>
          status_bar_int64_from_json(value, path.add_key("last_activity_unix"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("last_activity_unix"),
              "StatusBarPane::from_json: missing field last_activity_unix",
            ),
          )
      }
      {
        zellij_pane_id,
        agent_id,
        role,
        agent_type,
        lifecycle,
        pr_number,
        unresolved_threads,
        ci_rollup,
        attention_needed,
        parent_agent_id,
        last_activity_unix,
      }
    }
    _ =>
      raise @json.JsonDecodeError(
        (path, "StatusBarPane::from_json: expected object"),
      )
  }
}

///|
pub fn StatusBarSnapshot::to_json_map(
  self : StatusBarSnapshot,
) -> Map[String, Json] {
  let panes : Array[Json] = []
  for pane in self.panes {
    panes.push(pane.to_json())
  }
  {
    "schema_version": self.schema_version.to_json(),
    "taken_at_ms": status_bar_int64_json(self.taken_at_ms),
    "panes": panes.to_json(),
  }
}

///|
pub impl ToJson for StatusBarSnapshot with fn to_json(self) -> Json {
  self.to_json_map().to_json()
}

///|
pub impl FromJson for StatusBarSnapshot with fn from_json(json, path) {
  match json {
    Object(fields) => {
      let schema_version : Int = match fields.get("schema_version") {
        Some(value) =>
          @json.from_json(value, path=path.add_key("schema_version"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("schema_version"),
              "StatusBarSnapshot::from_json: missing field schema_version",
            ),
          )
      }
      if schema_version != 2 {
        raise @json.JsonDecodeError(
          (
            path.add_key("schema_version"),
            "StatusBarSnapshot::from_json: expected schema_version 2",
          ),
        )
      }
      let taken_at_ms : Int64 = match fields.get("taken_at_ms") {
        Some(value) =>
          status_bar_int64_from_json(value, path.add_key("taken_at_ms"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("taken_at_ms"),
              "StatusBarSnapshot::from_json: missing field taken_at_ms",
            ),
          )
      }
      let panes : Array[StatusBarPane] = match fields.get("panes") {
        Some(value) => @json.from_json(value, path=path.add_key("panes"))
        None =>
          raise @json.JsonDecodeError(
            (
              path.add_key("panes"),
              "StatusBarSnapshot::from_json: missing field panes",
            ),
          )
      }
      { schema_version, taken_at_ms, panes }
    }
    _ =>
      raise @json.JsonDecodeError(
        (path, "StatusBarSnapshot::from_json: expected object"),
      )
  }
}

///|
fn status_bar_positive_pr_number(n : Int) -> Int? {
  if n > 0 {
    Some(n)
  } else {
    None
  }
}

///|
pub fn status_bar_parent_agent_id(parent : String?) -> String? {
  match parent {
    Some(value) => {
      let trimmed = value.trim()
      if trimmed == "" {
        None
      } else if trimmed == value {
        Some(value)
      } else {
        Some(trimmed.to_owned())
      }
    }
    None => None
  }
}

///|
fn status_bar_is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn status_bar_parse_digits(raw : String) -> Int? {
  if raw == "" {
    return None
  }
  for c in raw {
    if !status_bar_is_digit(c) {
      return None
    }
  }
  Some(@string.parse_int(raw)) catch {
    _ => None
  }
}

///|
fn status_bar_json_bool(value : Json?) -> Bool {
  match value {
    Some(True) => true
    _ => false
  }
}

///|
fn status_bar_json_int(value : Json?) -> Int? {
  match value {
    Some(Number(n, ..)) => Some(n.to_int())
    Some(String(s)) => status_bar_parse_digits(s)
    _ => None
  }
}

///|
fn status_bar_json_string(value : Json?) -> String? {
  match value {
    Some(String(s)) => Some(s)
    Some(Number(n, ..)) => Some(n.to_int().to_string())
    _ => None
  }
}

///|
fn status_bar_first_nonempty_string(a : String?, b : String?) -> String? {
  match a {
    Some(value) if value != "" => Some(value)
    _ =>
      match b {
        Some(value) if value != "" => Some(value)
        _ => None
      }
  }
}

///|
fn status_bar_list_panes_entry_from_object(
  obj : Map[String, Json],
  fallback_tab_name : String?,
  fallback_pane_name : String?,
) -> ZellijListPanesEntry? {
  if status_bar_json_bool(obj.get("is_plugin")) ||
    status_bar_json_bool(obj.get("exited")) {
    return None
  }
  let pane_id = match status_bar_json_int(obj.get("pane_id")) {
    Some(value) => value
    None =>
      match status_bar_json_int(obj.get("id")) {
        Some(value) => value
        None => return None
      }
  }
  let tab_name = match
    status_bar_first_nonempty_string(
      status_bar_json_string(obj.get("tab_name")),
      fallback_tab_name,
    ) {
    Some(value) => value
    None => return None
  }
  let pane_name = status_bar_first_nonempty_string(
    status_bar_first_nonempty_string(
      status_bar_json_string(obj.get("pane_name")),
      status_bar_json_string(obj.get("title")),
    ),
    fallback_pane_name,
  ).unwrap_or("")
  Some({ pane_id, tab_name, pane_name })
}

///|
fn status_bar_push_list_panes_entry(
  entries : Array[ZellijListPanesEntry],
  entry : ZellijListPanesEntry?,
) -> Unit {
  match entry {
    Some(value) => entries.push(value)
    None => ()
  }
}

///|
fn status_bar_parse_list_panes_array(
  panes : Array[Json],
  fallback_tab_name? : String? = None,
) -> Array[ZellijListPanesEntry] {
  let entries : Array[ZellijListPanesEntry] = []
  for pane in panes {
    match pane {
      Object(obj) =>
        status_bar_push_list_panes_entry(
          entries,
          status_bar_list_panes_entry_from_object(obj, fallback_tab_name, None),
        )
      _ => ()
    }
  }
  entries
}

///|
fn status_bar_parse_list_panes_object(
  fields : Map[String, Json],
) -> Array[ZellijListPanesEntry] {
  let entries : Array[ZellijListPanesEntry] = []
  match status_bar_list_panes_entry_from_object(fields, None, None) {
    Some(entry) => {
      entries.push(entry)
      return entries
    }
    None => ()
  }
  match fields.get("panes") {
    Some(Array(panes)) => return status_bar_parse_list_panes_array(panes)
    _ => ()
  }
  fields.each(fn(tab_name, value) {
    match value {
      Object(tab_obj) =>
        match
          status_bar_list_panes_entry_from_object(tab_obj, Some(tab_name), None) {
          Some(entry) => entries.push(entry)
          None =>
            tab_obj.each(fn(pane_name, pane_value) {
              match pane_value {
                Object(pane_obj) =>
                  status_bar_push_list_panes_entry(
                    entries,
                    status_bar_list_panes_entry_from_object(
                      pane_obj,
                      Some(tab_name),
                      Some(pane_name),
                    ),
                  )
                _ => ()
              }
            })
        }
      Array(panes) => {
        let parsed = status_bar_parse_list_panes_array(
          panes,
          fallback_tab_name=Some(tab_name),
        )
        for entry in parsed {
          entries.push(entry)
        }
      }
      _ => ()
    }
  })
  entries
}

///|
pub fn parse_zellij_list_panes_json(raw : String) -> ZellijListPanesSnapshot {
  if raw.trim().to_owned() == "" {
    return empty_zellij_list_panes_snapshot()
  }
  let json = @json.parse(raw) catch {
    _ => return empty_zellij_list_panes_snapshot()
  }
  let entries = match json {
    Array(panes) => status_bar_parse_list_panes_array(panes)
    Object(fields) => status_bar_parse_list_panes_object(fields)
    _ => []
  }
  { entries, }
}

///|
fn status_bar_terminal_pane_id(name : String) -> Int? {
  let prefix = "terminal_"
  if !name.has_prefix(prefix) {
    return None
  }
  status_bar_parse_digits(name[prefix.length():].to_owned())
}

///|
pub fn resolve_zellij_pane_id(
  target : @types.LocalTarget,
  list_panes : ZellijListPanesSnapshot,
) -> Int? {
  match target.kind {
    @types.TargetKind::ZellijPane =>
      match status_bar_terminal_pane_id(target.name) {
        Some(value) => Some(value)
        None => {
          for entry in list_panes.entries {
            if entry.pane_name == target.name {
              return Some(entry.pane_id)
            }
          }
          None
        }
      }
    @types.TargetKind::ZellijTab => {
      for entry in list_panes.entries {
        if entry.tab_name == target.name {
          return Some(entry.pane_id)
        }
      }
      None
    }
  }
}

///|
pub fn role_to_wire_string(agent_id : String, role : @types.Role) -> String {
  if agent_id == "root" {
    return "root"
  }
  match role {
    @types.Role::TL => "tl"
    @types.Role::Dev => "dev"
    @types.Role::Worker => "worker"
  }
}

///|
pub fn agent_type_to_wire_string(agent_type : @types.AgentType) -> String? {
  match agent_type {
    @types.AgentType::Codex => Some("codex")
    @types.AgentType::Claude => Some("claude")
    @types.AgentType::MoonPilot => Some("moon_pilot")
    @types.AgentType::Gemini => Some("gemini")
    @types.AgentType::CursorAgent => Some("cursor_agent")
    @types.AgentType::Unknown => None
  }
}

///|
pub fn ci_rollup_to_wire_string(rollup : @poller.CiRollupStatus) -> String {
  match rollup {
    @poller.CiRollupStatus::Success => "success"
    @poller.CiRollupStatus::InProgress => "in_progress"
    @poller.CiRollupStatus::Failure => "failure"
    @poller.CiRollupStatus::Unknown => "unknown"
    @poller.CiRollupStatus::NoChecks => "no_checks"
  }
}

///|
pub fn lifecycle_to_wire_string(workflow : @phase.WorkflowState) -> String {
  match workflow {
    @phase.WorkflowState::Dev(dev) =>
      match dev {
        @phase.DevLifecycle::Working => "working"
        @phase.DevLifecycle::ReviewOwned(..) => "review_owned"
        @phase.DevLifecycle::ChangesRequested(..) => "changes_requested"
        @phase.DevLifecycle::ExitRequestedDeferred(..) => "review_owned"
        @phase.DevLifecycle::Done(..) => "done"
        @phase.DevLifecycle::Failed(..) => "failed"
        @phase.DevLifecycle::Exitable => "exitable"
        @phase.DevLifecycle::WaitingForRedGate => "waiting_for_red_gate"
      }
    @phase.WorkflowState::Worker(worker) =>
      match worker {
        @phase.WorkerLifecycle::Working => "working"
        @phase.WorkerLifecycle::Exitable => "exitable"
        @phase.WorkerLifecycle::Done(..) => "done"
        @phase.WorkerLifecycle::Failed(..) => "failed"
      }
    @phase.WorkflowState::Supervisor(supervisor) =>
      match supervisor {
        @phase.SupervisorLifecycle::Planning => "working"
        @phase.SupervisorLifecycle::Dispatching => "working"
        @phase.SupervisorLifecycle::Supervising(..) => "working"
        @phase.SupervisorLifecycle::WaveComplete(..) => "done"
        @phase.SupervisorLifecycle::OwnPRFiled(..) => "review_owned"
        @phase.SupervisorLifecycle::Done => "done"
        @phase.SupervisorLifecycle::Failed(..) => "failed"
      }
  }
}

///|
pub fn pane_needs_attention(
  workflow : @phase.WorkflowState,
  fixes_pushed_at : Int64,
  unresolved_threads : StatusBarThreadCount,
) -> PaneAttention {
  match workflow {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ChangesRequested(..)) =>
      if fixes_pushed_at <= 0L {
        PaneAttention::Clear
      } else {
        match unresolved_threads {
          Count(thread_count) if thread_count > 0 => PaneAttention::Needed
          Count(_) => PaneAttention::Clear
          Unknown => PaneAttention::Unknown
          NoPR => PaneAttention::Clear
        }
      }
    _ => PaneAttention::Clear
  }
}

///|
pub fn pane_attention_to_bool_string(value : PaneAttention) -> String {
  match value {
    Clear => "false"
    Needed => "true"
    Unknown => "unknown"
  }
}

///|
fn status_bar_workflow_pr_number(workflow : @phase.WorkflowState) -> Int? {
  match workflow {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ReviewOwned(pr_number~, ..))
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ChangesRequested(pr_number~, ..)
    )
    | @phase.WorkflowState::Dev(
      @phase.DevLifecycle::ExitRequestedDeferred(pr_number~, ..)
    ) => status_bar_positive_pr_number(pr_number)
    @phase.WorkflowState::Supervisor(
      @phase.SupervisorLifecycle::OwnPRFiled(number~, ..)
    ) => status_bar_positive_pr_number(number)
    _ => None
  }
}

///|
fn status_bar_tracked_by_agent(
  poller_tracked : Map[Int, @poller.TrackedPR],
) -> Map[String, @poller.TrackedPR] {
  let by_agent : Map[String, @poller.TrackedPR] = {}
  for tracked in poller_tracked.values() {
    match by_agent.get(tracked.agent_id) {
      Some(existing) if existing.pr_number >= tracked.pr_number => ()
      _ => by_agent.set(tracked.agent_id, tracked)
    }
  }
  by_agent
}

///|
fn status_bar_tracked_for_workflow(
  poller_tracked : Map[Int, @poller.TrackedPR],
  agent_id : String,
  workflow_pr_number : Int?,
  tracked_by_agent : Map[String, @poller.TrackedPR],
) -> @poller.TrackedPR? {
  match workflow_pr_number {
    Some(pr_number) =>
      match poller_tracked.get(pr_number) {
        Some(tracked) if tracked.agent_id == agent_id => Some(tracked)
        _ => None
      }
    None => tracked_by_agent.get(agent_id)
  }
}

///|
fn status_bar_thread_count(
  pr_number : Int?,
  tracked : @poller.TrackedPR?,
) -> StatusBarThreadCount {
  match pr_number {
    None => StatusBarThreadCount::NoPR
    Some(_) =>
      match tracked {
        Some(value) =>
          if value.unresolved_thread_ids_fetched {
            StatusBarThreadCount::Count(value.unresolved_thread_ids.length())
          } else {
            StatusBarThreadCount::Unknown
          }
        None => StatusBarThreadCount::Unknown
      }
  }
}

///|
fn status_bar_pane_from_entry(
  entry : StatusBarRegistryEntry,
  poller_tracked : Map[Int, @poller.TrackedPR],
  tracked_by_agent : Map[String, @poller.TrackedPR],
  list_panes : ZellijListPanesSnapshot,
) -> StatusBarPane? {
  let target = match entry.agent.terminal_target {
    Some(value) => value
    None => return None
  }
  let zellij_pane_id = match resolve_zellij_pane_id(target, list_panes) {
    Some(value) => value
    None => return None
  }
  let agent_type = match agent_type_to_wire_string(entry.agent.agent_type) {
    Some(value) => value
    None => return None
  }
  let agent_id = entry.agent.agent_id.to_string()
  if agent_id == "" {
    return None
  }
  let workflow = entry.lifecycle.workflow
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
    Some(value) => ci_rollup_to_wire_string(value.last_ci_rollup)
    None => "unknown"
  }
  let fixes_pushed_at = match tracked {
    Some(value) => value.fixes_pushed_at
    None => 0L
  }
  Some({
    zellij_pane_id,
    agent_id,
    role: role_to_wire_string(agent_id, entry.agent.role),
    agent_type,
    lifecycle: lifecycle_to_wire_string(workflow),
    pr_number,
    unresolved_threads,
    ci_rollup,
    attention_needed: pane_needs_attention(
      workflow, fixes_pushed_at, unresolved_threads,
    ),
    parent_agent_id: status_bar_parent_agent_id(entry.agent.parent),
    last_activity_unix: @types.non_negative_i64(
      entry.lifecycle.last_updated_unix_sec,
    ),
  })
}

///|
fn sort_status_bar_panes(panes : Array[StatusBarPane]) -> Array[StatusBarPane] {
  let sorted = panes.copy()
  sorted.sort_by(fn(a, b) {
    if a.zellij_pane_id < b.zellij_pane_id {
      -1
    } else if a.zellij_pane_id > b.zellij_pane_id {
      1
    } else if a.agent_id < b.agent_id {
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
pub fn build_status_bar_snapshot(
  registry_entries : Array[StatusBarRegistryEntry],
  poller_tracked : Map[Int, @poller.TrackedPR],
  list_panes : ZellijListPanesSnapshot,
  now_ms : Int64,
) -> StatusBarSnapshot {
  let tracked_by_agent = status_bar_tracked_by_agent(poller_tracked)
  let panes : Array[StatusBarPane] = []
  for entry in registry_entries {
    match
      status_bar_pane_from_entry(
        entry, poller_tracked, tracked_by_agent, list_panes,
      ) {
      Some(pane) => panes.push(pane)
      None => ()
    }
  }
  {
    schema_version: 2,
    taken_at_ms: @types.non_negative_i64(now_ms),
    panes: sort_status_bar_panes(panes),
  }
}

///|
pub fn status_bar_registry_entries(
  registry : @registry.AgentRegistry,
  lifecycle_reader : (String) -> @phase.AgentLifecycle?,
) -> Array[StatusBarRegistryEntry] {
  let entries : Array[StatusBarRegistryEntry] = []
  for agent in registry.list() {
    let agent_id = agent.agent_id.to_string()
    entries.push({
      agent,
      lifecycle: lifecycle_reader(agent_id).unwrap_or(
        @phase.lifecycle_for_agent(agent),
      ),
    })
  }
  entries
}

///|
fn status_bar_registry_entry_sessions(
  registry_entries : Array[StatusBarRegistryEntry],
) -> Array[String] {
  let seen : Map[String, Bool] = {}
  let sessions : Array[String] = []
  for entry in registry_entries {
    match entry.agent.terminal_target {
      Some(target) =>
        if !seen.contains(target.session) {
          seen.set(target.session, true)
          sessions.push(target.session)
        }
      None => ()
    }
  }
  sessions
}

///|
fn status_bar_pane_from_entry_by_session(
  entry : StatusBarRegistryEntry,
  poller_tracked : Map[Int, @poller.TrackedPR],
  tracked_by_agent : Map[String, @poller.TrackedPR],
  list_panes_by_session : Map[String, ZellijListPanesSnapshot],
) -> StatusBarPane? {
  let target = match entry.agent.terminal_target {
    Some(value) => value
    None => return None
  }
  let list_panes = match list_panes_by_session.get(target.session) {
    Some(value) => value
    None => return None
  }
  status_bar_pane_from_entry(
    entry, poller_tracked, tracked_by_agent, list_panes,
  )
}

///|
fn build_status_bar_snapshot_by_session(
  registry_entries : Array[StatusBarRegistryEntry],
  poller_tracked : Map[Int, @poller.TrackedPR],
  list_panes_by_session : Map[String, ZellijListPanesSnapshot],
  now_ms : Int64,
) -> StatusBarSnapshot {
  let tracked_by_agent = status_bar_tracked_by_agent(poller_tracked)
  let panes : Array[StatusBarPane] = []
  for entry in registry_entries {
    match
      status_bar_pane_from_entry_by_session(
        entry, poller_tracked, tracked_by_agent, list_panes_by_session,
      ) {
      Some(pane) => panes.push(pane)
      None => ()
    }
  }
  {
    schema_version: 2,
    taken_at_ms: @types.non_negative_i64(now_ms),
    panes: sort_status_bar_panes(panes),
  }
}

///|
async fn status_bar_default_list_panes_capture(
  _session : String,
) -> Result[ZellijListPanesSnapshot, @types.ChoirError] {
  @async.sleep(0)
  Ok(empty_zellij_list_panes_snapshot())
}

///|
async fn capture_zellij_list_panes_snapshot_result(
  session : String,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> Result[ZellijListPanesSnapshot, @types.ChoirError] {
  let (exit_code, output) = capture(
    @workspace.zellij_list_panes_json_command(session),
  )
  if exit_code != 0 {
    Err(
      @types.ChoirError::workspace_error(
        "zellij list-panes failed for session " + session,
      ),
    )
  } else {
    Ok(parse_zellij_list_panes_json(output))
  }
}

///|
pub async fn capture_zellij_list_panes_snapshot(
  session : String,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_stdout,
) -> ZellijListPanesSnapshot {
  match capture_zellij_list_panes_snapshot_result(session, capture~) {
    Ok(snapshot) => snapshot
    Err(_) => empty_zellij_list_panes_snapshot()
  }
}

///|
async fn status_bar_list_panes_for_session(
  session : String,
  now_ms : Int64,
  list_panes_cache : Map[String, CachedListPanesSnapshot]?,
  list_panes_capture : async (String) -> Result[
    ZellijListPanesSnapshot,
    @types.ChoirError,
  ],
) -> ZellijListPanesSnapshot {
  match list_panes_cache {
    Some(cache) =>
      match list_panes_cache_lookup(cache, session, now_ms) {
        Some(snapshot) => return snapshot
        None => ()
      }
    None => ()
  }
  match list_panes_capture(session) {
    Ok(snapshot) => {
      match list_panes_cache {
        Some(cache) =>
          cache.set(session, {
            snapshot,
            expires_at_unix_ms: now_ms + LIST_PANES_TTL_MS,
          })
        None => ()
      }
      snapshot
    }
    Err(_) => empty_zellij_list_panes_snapshot()
  }
}

///|
async fn status_bar_list_panes_by_session(
  registry_entries : Array[StatusBarRegistryEntry],
  now_ms : Int64,
  list_panes_cache : Map[String, CachedListPanesSnapshot]?,
  list_panes_capture : async (String) -> Result[
    ZellijListPanesSnapshot,
    @types.ChoirError,
  ],
) -> Map[String, ZellijListPanesSnapshot] {
  let snapshots : Map[String, ZellijListPanesSnapshot] = {}
  for session in status_bar_registry_entry_sessions(registry_entries) {
    snapshots.set(
      session,
      status_bar_list_panes_for_session(
        session, now_ms, list_panes_cache, list_panes_capture,
      ),
    )
  }
  snapshots
}

///|
pub async fn interpret_status_bar_state(
  args : StatusBarStateArgs,
  project_dir : String,
  registry : @registry.AgentRegistry?,
  poller_state : @poller.PollerState?,
  lifecycle_reader? : ((String) -> @phase.AgentLifecycle?)? = None,
  list_panes_cache? : Map[String, CachedListPanesSnapshot]? = None,
  list_panes_capture? : async (String) -> Result[
    ZellijListPanesSnapshot,
    @types.ChoirError,
  ] = status_bar_default_list_panes_capture,
  now_ms? : Int64 = @env.now().reinterpret_as_int64(),
) -> @types.Response {
  ignore(args)
  let reg = match registry {
    Some(value) => value
    None =>
      return @types.Response::Err("status_bar_state requires an agent registry")
  }
  let reader = match lifecycle_reader {
    Some(value) => value
    None => fn(agent_id) { @phase.read_lifecycle(project_dir, agent_id) }
  }
  let tracked : Map[Int, @poller.TrackedPR] = match poller_state {
    Some(value) => value.tracked
    None => {}
  }
  let registry_entries = status_bar_registry_entries(reg, reader)
  let list_panes_by_session = status_bar_list_panes_by_session(
    registry_entries, now_ms, list_panes_cache, list_panes_capture,
  )
  let snapshot = build_status_bar_snapshot_by_session(
    registry_entries, tracked, list_panes_by_session, now_ms,
  )
  @types.Response::ok_values(snapshot.to_json_map())
}

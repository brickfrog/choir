///|
pub(all) struct StatusBarPane {
  zellij_pane_id : Int
  agent_id : String
  role : String
  agent_type : String
  lifecycle : String
  pr_number : Int?
  unresolved_threads : Int
  ci_rollup : String
  attention_needed : Bool
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
fn status_bar_null_json() -> Json {
  @json.parse("null") catch {
    _ => "".to_json()
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
pub impl ToJson for StatusBarPane with to_json(self) -> Json {
  {
    "zellij_pane_id": self.zellij_pane_id.to_json(),
    "agent_id": self.agent_id.to_json(),
    "role": self.role.to_json(),
    "agent_type": self.agent_type.to_json(),
    "lifecycle": self.lifecycle.to_json(),
    "pr_number": status_bar_optional_int_json(self.pr_number),
    "unresolved_threads": self.unresolved_threads.to_json(),
    "ci_rollup": self.ci_rollup.to_json(),
    "attention_needed": self.attention_needed.to_json(),
    "parent_agent_id": status_bar_optional_string_json(self.parent_agent_id),
    "last_activity_unix": self.last_activity_unix.to_json(),
  }.to_json()
}

///|
pub impl FromJson for StatusBarPane with from_json(json, path) {
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
      let unresolved_threads : Int = match fields.get("unresolved_threads") {
        Some(value) =>
          @json.from_json(value, path=path.add_key("unresolved_threads"))
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
      let attention_needed : Bool = match fields.get("attention_needed") {
        Some(value) =>
          @json.from_json(value, path=path.add_key("attention_needed"))
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
          @json.from_json(value, path=path.add_key("last_activity_unix"))
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
    "taken_at_ms": self.taken_at_ms.to_json(),
    "panes": panes.to_json(),
  }
}

///|
pub impl ToJson for StatusBarSnapshot with to_json(self) -> Json {
  self.to_json_map().to_json()
}

///|
pub impl FromJson for StatusBarSnapshot with from_json(json, path) {
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
      let taken_at_ms : Int64 = match fields.get("taken_at_ms") {
        Some(value) => @json.from_json(value, path=path.add_key("taken_at_ms"))
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
fn status_bar_nonnegative_i64(n : Int64) -> Int64 {
  if n < 0L {
    0L
  } else {
    n
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
fn status_bar_parent_agent_id(parent : String?) -> String? {
  match parent {
    Some(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed == "" {
        None
      } else {
        Some(trimmed)
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
pub fn parse_zellij_pane_id(target : String) -> Int? {
  if !target.has_prefix("zellij-pane:") {
    return None
  }
  let mut parts_count = 0
  let mut last_part = ""
  for part in target.split(":") {
    parts_count = parts_count + 1
    last_part = part.to_owned()
  }
  if parts_count < 3 {
    return None
  }
  let prefix = "terminal_"
  if !last_part.has_prefix(prefix) {
    return None
  }
  status_bar_parse_digits(last_part[prefix.length():].to_owned())
}

///|
pub fn role_to_wire_string(role : @types.Role) -> String {
  match role {
    @types.Role::Root => "root"
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
  unresolved_threads : Int,
) -> Bool {
  match workflow {
    @phase.WorkflowState::Dev(@phase.DevLifecycle::Failed(..))
    | @phase.WorkflowState::Worker(@phase.WorkerLifecycle::Failed(..))
    | @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Failed(..)) =>
      true
    @phase.WorkflowState::Dev(@phase.DevLifecycle::ChangesRequested(..)) =>
      fixes_pushed_at > 0L && unresolved_threads > 0
    _ => false
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
    by_agent.set(tracked.agent_id, tracked)
  }
  by_agent
}

///|
fn status_bar_pane_from_entry(
  entry : StatusBarRegistryEntry,
  tracked_by_agent : Map[String, @poller.TrackedPR],
) -> StatusBarPane? {
  let target = match entry.agent.terminal_target {
    Some(value) => value.to_string()
    None => return None
  }
  let zellij_pane_id = match parse_zellij_pane_id(target) {
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
  let tracked = tracked_by_agent.get(agent_id)
  let pr_number = match tracked {
    Some(value) => status_bar_positive_pr_number(value.pr_number)
    None => status_bar_workflow_pr_number(workflow)
  }
  let unresolved_threads = match tracked {
    Some(value) => value.unresolved_thread_ids.length()
    None => 0
  }
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
    role: role_to_wire_string(entry.agent.role),
    agent_type,
    lifecycle: lifecycle_to_wire_string(workflow),
    pr_number,
    unresolved_threads,
    ci_rollup,
    attention_needed: pane_needs_attention(
      workflow, fixes_pushed_at, unresolved_threads,
    ),
    parent_agent_id: status_bar_parent_agent_id(entry.agent.parent),
    last_activity_unix: status_bar_nonnegative_i64(
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
  now_ms : Int64,
) -> StatusBarSnapshot {
  let tracked_by_agent = status_bar_tracked_by_agent(poller_tracked)
  let panes : Array[StatusBarPane] = []
  for entry in registry_entries {
    match status_bar_pane_from_entry(entry, tracked_by_agent) {
      Some(pane) => panes.push(pane)
      None => ()
    }
  }
  {
    schema_version: 1,
    taken_at_ms: status_bar_nonnegative_i64(now_ms),
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
pub fn interpret_status_bar_state(
  args : StatusBarStateArgs,
  project_dir : String,
  registry : @registry.AgentRegistry?,
  poller_state : @poller.PollerState?,
  lifecycle_reader? : ((String) -> @phase.AgentLifecycle?)? = None,
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
  let snapshot = build_status_bar_snapshot(
    status_bar_registry_entries(reg, reader),
    tracked,
    now_ms,
  )
  @types.Response::ok_values(snapshot.to_json_map())
}

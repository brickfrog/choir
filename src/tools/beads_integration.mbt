///|
pub(all) struct BeadsIssue {
  id : String
  title : String
  status : String
  assignee : String
  notes : String
  labels : Array[String]
  metadata : Map[String, String]
} derive(Debug, Eq)

///|
pub(all) struct BeadsRoute {
  agent_type : @types.AgentType?
  child_role : @types.Role?
  worker_type : String?
  automerge : Bool?
  review_mode : @types.ReviewMode?
  warnings : Array[String]
} derive(Debug, Eq)

///|
pub(all) struct BeadsWaveFromIssuesPlan {
  fork_wave_args : Map[String, Json]
  issue_ids : Array[String]
  warnings : Array[String]
} derive(Debug, Eq)

///|
fn json_field_string_or_empty(
  fields : Map[String, Json],
  name : String,
) -> String {
  @types.json_field_string(fields, name).unwrap_or("")
}

///|
fn json_string_array(value : Json?) -> Array[String] {
  let out : Array[String] = []
  match value {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(s) => out.push(s)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn json_scalar_to_string(value : Json) -> String? {
  match value {
    String(s) => Some(s)
    Number(n, ..) => Some(n.to_string())
    True => Some("true")
    False => Some("false")
    _ => None
  }
}

///|
fn json_string_map(value : Json?) -> Map[String, String] {
  let out : Map[String, String] = {}
  match value {
    Some(Object(fields)) =>
      for entry in fields {
        match json_scalar_to_string(entry.1) {
          Some(v) => out.set(entry.0, v)
          None => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn parse_beads_issue_fields(
  fields : Map[String, Json],
) -> Result[BeadsIssue, @types.ChoirError] {
  let id = json_field_string_or_empty(fields, "id")
  if id == "" {
    return Err(@types.ChoirError::validation_error("beads issue missing id"))
  }
  let title = json_field_string_or_empty(fields, "title")
  if title == "" {
    return Err(@types.ChoirError::validation_error("beads issue missing title"))
  }
  Ok({
    id,
    title,
    status: json_field_string_or_empty(fields, "status"),
    assignee: json_field_string_or_empty(fields, "assignee"),
    notes: json_field_string_or_empty(fields, "notes"),
    labels: json_string_array(fields.get("labels")),
    metadata: json_string_map(fields.get("metadata")),
  })
}

///|
pub fn parse_beads_issues_json(
  content : String,
) -> Result[Array[BeadsIssue], @types.ChoirError] {
  let json = @json.parse(content) catch {
    _ => return Err(@types.ChoirError::validation_error("invalid beads json"))
  }
  match json {
    Array(items) => {
      let out : Array[BeadsIssue] = []
      for item in items {
        match item {
          Object(fields) =>
            match parse_beads_issue_fields(fields) {
              Ok(issue) => out.push(issue)
              Err(e) => return Err(e)
            }
          _ =>
            return Err(
              @types.ChoirError::validation_error("invalid beads issue"),
            )
        }
      }
      Ok(out)
    }
    Object(fields) =>
      match parse_beads_issue_fields(fields) {
        Ok(issue) => Ok([issue])
        Err(e) => Err(e)
      }
    _ => Err(@types.ChoirError::validation_error("invalid beads json"))
  }
}

///|
fn parse_agent_type_label(value : String) -> @types.AgentType? {
  match value {
    "claude" => Some(@types.AgentType::Claude)
    "gemini" => Some(@types.AgentType::Gemini)
    "moon_pilot" | "moonpilot" => Some(@types.AgentType::MoonPilot)
    "codex" => Some(@types.AgentType::Codex)
    "agent" | "cursor_agent" | "cursoragent" =>
      Some(@types.AgentType::CursorAgent)
    _ => None
  }
}

///|
fn parse_bool_label(value : String) -> Bool? {
  match value {
    "true" | "on" | "yes" | "1" => Some(true)
    "false" | "off" | "no" | "0" => Some(false)
    _ => None
  }
}

///|
fn parse_review_mode_label(value : String) -> @types.ReviewMode? {
  match value {
    "single_pass" | "singlepass" => Some(@types.ReviewMode::SinglePass)
    "iterative" => Some(@types.ReviewMode::Iterative)
    _ => None
  }
}

///|
fn route_value_from_issue(issue : BeadsIssue, key : String) -> String? {
  for label in issue.labels {
    let prefix = key + ":"
    if label.has_prefix(prefix) {
      return Some(label[prefix.length():].trim().to_lower().to_owned())
    }
  }
  match issue.metadata.get(key) {
    Some(v) => Some(v.trim().to_lower().to_owned())
    None =>
      match issue.metadata.get("choir_" + key) {
        Some(v) => Some(v.trim().to_lower().to_owned())
        None => None
      }
  }
}

///|
pub fn beads_route_for_issue(issue : BeadsIssue) -> BeadsRoute {
  let warnings : Array[String] = []
  let agent_type = match route_value_from_issue(issue, "agent") {
    Some(value) =>
      match parse_agent_type_label(value) {
        Some(t) => Some(t)
        None => {
          warnings.push(
            issue.id + ": unknown agent route `" + value + "` ignored",
          )
          None
        }
      }
    None => None
  }
  let child_role = match route_value_from_issue(issue, "role") {
    Some("tl") => Some(@types.Role::TL)
    Some("dev") => Some(@types.Role::Dev)
    Some(other) => {
      warnings.push(issue.id + ": unknown role route `" + other + "` ignored")
      None
    }
    None => None
  }
  let worker_type = match route_value_from_issue(issue, "kind") {
    Some("research") => Some("research")
    Some("review") => Some("review")
    Some("worker") => Some("research")
    Some(_) | None => None
  }
  let automerge = match route_value_from_issue(issue, "automerge") {
    Some(value) =>
      match parse_bool_label(value) {
        Some(v) => Some(v)
        None => {
          warnings.push(
            issue.id + ": unknown automerge route `" + value + "` ignored",
          )
          None
        }
      }
    None => None
  }
  let review_mode = match route_value_from_issue(issue, "review") {
    Some(value) =>
      match parse_review_mode_label(value) {
        Some(v) => Some(v)
        None => {
          warnings.push(
            issue.id + ": unknown review route `" + value + "` ignored",
          )
          None
        }
      }
    None => None
  }
  { agent_type, child_role, worker_type, automerge, review_mode, warnings }
}

///|
fn issue_task_text(issue : BeadsIssue) -> String {
  let base = issue.title.trim().to_owned()
  let notes = issue.notes.trim().to_owned()
  if notes == "" {
    base
  } else {
    base + "\n\nBeads notes:\n" + notes
  }
}

///|
fn maybe_set_uniform_agent_type(
  args : Map[String, Json],
  routes : Array[BeadsRoute],
  issue_ids : Array[String],
  warnings : Array[String],
) -> Unit {
  let mut seen : @types.AgentType? = None
  let routed : Array[String] = []
  for i = 0; i < routes.length(); i = i + 1 {
    match routes[i].agent_type {
      Some(t) => {
        routed.push(issue_ids[i])
        match seen {
          Some(prior) =>
            if prior != t {
              warnings.push(
                "mixed agent labels in one fork_wave; split by label or omit wave execution",
              )
              return
            }
          None => seen = Some(t)
        }
      }
      None => ()
    }
  }
  match seen {
    Some(t) =>
      if routed.length() == routes.length() {
        args.set("agent_type", t.to_wire_string().to_json())
      } else if routed.length() > 0 {
        warnings.push(
          "some but not all issues have agent labels; default agent_type left unchanged",
        )
      }
    None => ()
  }
}

///|
fn maybe_set_uniform_role(
  args : Map[String, Json],
  routes : Array[BeadsRoute],
  issue_ids : Array[String],
  warnings : Array[String],
) -> Unit {
  ignore(issue_ids)
  let mut seen : @types.Role? = None
  let mut routed = 0
  for r in routes {
    match r.child_role {
      Some(role) => {
        routed = routed + 1
        match seen {
          Some(prior) =>
            if prior != role {
              warnings.push("mixed role labels in one fork_wave; role omitted")
              return
            }
          None => seen = Some(role)
        }
      }
      None => ()
    }
  }
  match seen {
    Some(role) =>
      if routed == routes.length() {
        args.set("role", role.to_wire_string().to_json())
      } else if routed > 0 {
        warnings.push("some but not all issues have role labels; role omitted")
      }
    None => ()
  }
}

///|
fn maybe_set_uniform_automerge(
  args : Map[String, Json],
  routes : Array[BeadsRoute],
  warnings : Array[String],
) -> Unit {
  let mut seen : Bool? = None
  let mut routed = 0
  for r in routes {
    match r.automerge {
      Some(value) => {
        routed = routed + 1
        match seen {
          Some(prior) =>
            if prior != value {
              warnings.push(
                "mixed automerge labels in one fork_wave; automerge omitted",
              )
              return
            }
          None => seen = Some(value)
        }
      }
      None => ()
    }
  }
  match seen {
    Some(value) =>
      if routed == routes.length() {
        args.set("automerge", value.to_json())
      } else if routed > 0 {
        warnings.push(
          "some but not all issues have automerge labels; automerge omitted",
        )
      }
    None => ()
  }
}

///|
fn maybe_set_uniform_review_mode(
  args : Map[String, Json],
  routes : Array[BeadsRoute],
  warnings : Array[String],
) -> Unit {
  let mut seen : @types.ReviewMode? = None
  let mut routed = 0
  for r in routes {
    match r.review_mode {
      Some(value) => {
        routed = routed + 1
        match seen {
          Some(prior) =>
            if prior != value {
              warnings.push(
                "mixed review labels in one fork_wave; review_mode omitted",
              )
              return
            }
          None => seen = Some(value)
        }
      }
      None => ()
    }
  }
  match seen {
    Some(value) =>
      if routed == routes.length() {
        args.set("review_mode", value.to_wire_string().to_json())
      } else if routed > 0 {
        warnings.push(
          "some but not all issues have review labels; review_mode omitted",
        )
      }
    None => ()
  }
}

///|
pub fn build_beads_wave_from_issues_plan(
  parent_id : String,
  caller_id : String,
  parent_branch : String,
  slug_prefix : String,
  issues : Array[BeadsIssue],
) -> Result[BeadsWaveFromIssuesPlan, @types.ChoirError] {
  if issues.length() == 0 {
    return Err(
      @types.ChoirError::validation_error(
        "no ready Beads issues under " + parent_id,
      ),
    )
  }
  let tasks : Array[Json] = []
  let task_contracts : Array[Json] = []
  let issue_ids : Array[String] = []
  let routes : Array[BeadsRoute] = []
  let warnings : Array[String] = []
  for issue in issues {
    issue_ids.push(issue.id)
    tasks.push(issue_task_text(issue).to_json())
    task_contracts.push({ "beads_issue_id": issue.id.to_json() }.to_json())
    let route = beads_route_for_issue(issue)
    for warning in route.warnings {
      warnings.push(warning)
    }
    match route.worker_type {
      Some(kind) =>
        warnings.push(
          issue.id +
          ": kind:" +
          kind +
          " is worker-routed; fork_wave plan keeps it as a leaf",
        )
      None => ()
    }
    routes.push(route)
  }
  let args : Map[String, Json] = {
    "caller_id": caller_id.to_json(),
    "parent_branch": parent_branch.to_json(),
    "slug_prefix": slug_prefix.to_json(),
    "count": issues.length().to_json(),
    "tasks": tasks.to_json(),
    "task_contracts": task_contracts.to_json(),
  }
  maybe_set_uniform_agent_type(args, routes, issue_ids, warnings)
  maybe_set_uniform_role(args, routes, issue_ids, warnings)
  maybe_set_uniform_automerge(args, routes, warnings)
  maybe_set_uniform_review_mode(args, routes, warnings)
  Ok({ fork_wave_args: args, issue_ids, warnings })
}

///|
pub fn beads_ready_children_command(
  parent_id : String,
  project_dir : String,
) -> @workspace.Command {
  {
    program: "bd",
    args: ["ready", "--json", "--parent", parent_id, "--limit", "0"],
    workdir: Some(project_dir),
  }
}

///|
pub fn beads_children_command(
  parent_id : String,
  project_dir : String,
) -> @workspace.Command {
  {
    program: "bd",
    args: ["children", parent_id, "--json"],
    workdir: Some(project_dir),
  }
}

///|
pub fn beads_update_spawn_command(
  project_dir : String,
  issue_id : String,
  agent_id : String,
  role : @types.Role,
  agent_type : @types.AgentType,
  branch : String,
  workspace : String,
  wave_id : String?,
) -> @workspace.Command {
  let args : Array[String] = [
    "update",
    issue_id,
    "--status",
    "in_progress",
    "--assignee",
    agent_id,
    "--set-metadata",
    "choir_agent_id=" + agent_id,
    "--set-metadata",
    "choir_role=" + role.to_wire_string(),
    "--set-metadata",
    "choir_agent_type=" + agent_type.to_wire_string(),
    "--set-metadata",
    "choir_branch=" + branch,
    "--set-metadata",
    "choir_workspace=" + workspace,
  ]
  match wave_id {
    Some(id) => {
      args.push("--set-metadata")
      args.push("choir_wave_id=" + id)
    }
    None => ()
  }
  { program: "bd", args, workdir: Some(project_dir) }
}

///|
pub fn beads_note_command(
  project_dir : String,
  issue_id : String,
  text : String,
) -> @workspace.Command {
  { program: "bd", args: ["note", issue_id, text], workdir: Some(project_dir) }
}

///|
pub fn beads_pr_note_command(
  project_dir : String,
  issue_id : String,
  pr_number : Int,
) -> @workspace.Command {
  beads_note_command(
    project_dir,
    issue_id,
    "Choir filed PR #" + pr_number.to_string(),
  )
}

///|
pub fn beads_close_merged_command(
  project_dir : String,
  issue_id : String,
  pr_number : Int,
) -> @workspace.Command {
  {
    program: "bd",
    args: [
      "close",
      issue_id,
      "--reason",
      "Merged in PR #" + pr_number.to_string(),
    ],
    workdir: Some(project_dir),
  }
}

///|
pub fn beads_set_state_command(
  project_dir : String,
  issue_id : String,
  dimension : String,
  value : String,
  reason : String,
) -> @workspace.Command {
  {
    program: "bd",
    args: ["set-state", issue_id, dimension + "=" + value, "--reason", reason],
    workdir: Some(project_dir),
  }
}

///|
pub fn beads_gate_create_command(
  project_dir : String,
  blocked_issue_id : String,
  gate_type : String,
  reason : String,
  await_id : String?,
) -> @workspace.Command {
  let args : Array[String] = [
    "gate", "create", "--type", gate_type, "--blocks", blocked_issue_id, "--reason",
    reason,
  ]
  match await_id {
    Some(id) if id != "" => {
      args.push("--await-id")
      args.push(id)
    }
    _ => ()
  }
  { program: "bd", args, workdir: Some(project_dir) }
}

///|
pub fn beads_audit_record_command(
  project_dir : String,
  issue_id : String?,
  kind : String,
  tool_name : String,
  response : String,
) -> @workspace.Command {
  let args : Array[String] = [
    "audit", "record", "--kind", kind, "--tool-name", tool_name, "--response", response,
  ]
  match issue_id {
    Some(id) => {
      args.push("--issue-id")
      args.push(id)
    }
    None => ()
  }
  { program: "bd", args, workdir: Some(project_dir) }
}

///|
pub fn beads_merge_slot_command(
  project_dir : String,
  action : String,
) -> @workspace.Command {
  { program: "bd", args: ["merge-slot", action], workdir: Some(project_dir) }
}

///|
pub fn beads_readonly_show_command(
  project_dir : String,
  issue_id : String,
) -> @workspace.Command {
  {
    program: "bd",
    args: ["--readonly", "show", issue_id, "--json"],
    workdir: Some(project_dir),
  }
}

///|
pub fn beads_usage_note(
  agent_id : String,
  tokens_in : Int,
  tokens_out : Int,
  elapsed_s : Int,
  cost_usd : Double?,
) -> String {
  let base = "Choir usage for " +
    agent_id +
    ": tokens_in=" +
    tokens_in.to_string() +
    " tokens_out=" +
    tokens_out.to_string() +
    " elapsed_s=" +
    elapsed_s.to_string()
  match cost_usd {
    Some(cost) => base + " cost_usd=" + cost.to_string()
    None => base
  }
}

///|
pub async fn run_beads_best_effort(
  cmd : @workspace.Command,
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  let (exit_code, _) = capture(cmd)
  exit_code == 0
}

///|
fn spawn_spec_workspace(
  project_dir : String,
  spec : @types.SpawnSpec,
) -> String {
  match spec.isolation {
    @types.IsolationMode::Inline => project_dir
    @types.IsolationMode::Worktree =>
      @workspace.worktree_path(
        project_dir,
        @workspace.spawn_workspace_dir_slug(spec),
      )
    @types.IsolationMode::Standalone =>
      project_dir + "/.choir/agents/" + spec.slug
  }
}

///|
pub async fn mirror_beads_spawn_for_spec(
  project_dir : String,
  spec : @types.SpawnSpec,
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  let issue_id = match spec.task_contract {
    Some(contract) =>
      match contract.beads_issue_id {
        Some(id) => id
        None => return true
      }
    None => return true
  }
  run_beads_best_effort(
    beads_update_spawn_command(
      project_dir,
      issue_id,
      @workspace.canonical_agent_id(spec),
      spec.role,
      spec.agent_type,
      @workspace.spawn_git_branch(spec),
      spawn_spec_workspace(project_dir, spec),
      spec.wave_id,
    ),
    capture,
  )
}

///|
pub fn beads_issue_id_for_agent(
  project_dir : String,
  registry : @registry.AgentRegistry?,
  agent_id : String,
) -> String? {
  match registry {
    Some(reg) =>
      match (Some(reg.get(agent_id)) catch { _ => None }) {
        Some(agent) => @workspace.beads_issue_id_for_agent(project_dir, agent)
        None => None
      }
    None => None
  }
}

///|
pub async fn mirror_beads_note_for_agent(
  project_dir : String,
  registry : @registry.AgentRegistry?,
  agent_id : String,
  note : String,
  tool_name : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  let issue_id = match
    beads_issue_id_for_agent(project_dir, registry, agent_id) {
    Some(id) => id
    None => return true
  }
  let note_ok = run_beads_best_effort(
    beads_note_command(project_dir, issue_id, note),
    capture,
  )
  ignore(
    run_beads_best_effort(
      beads_audit_record_command(
        project_dir,
        Some(issue_id),
        "tool_call",
        tool_name,
        note,
      ),
      capture,
    ),
  )
  note_ok
}

///|
pub async fn mirror_beads_state_for_agent(
  project_dir : String,
  registry : @registry.AgentRegistry?,
  agent_id : String,
  dimension : String,
  value : String,
  reason : String,
  tool_name : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Bool {
  let issue_id = match
    beads_issue_id_for_agent(project_dir, registry, agent_id) {
    Some(id) => id
    None => return true
  }
  let state_ok = run_beads_best_effort(
    beads_set_state_command(project_dir, issue_id, dimension, value, reason),
    capture,
  )
  ignore(
    run_beads_best_effort(
      beads_audit_record_command(
        project_dir,
        Some(issue_id),
        "tool_call",
        tool_name,
        reason,
      ),
      capture,
    ),
  )
  state_ok
}

///|
priv struct NativeConductorTask {
  id : String
  title : String
  description : String
  acceptance_criteria : String
  status : @types.TaskStatus
  assignee : String
  notes : String
  dependency_count : Int
  blocking_dependency_ids : Array[String]
  dependencies_loaded : Bool
}

///|
fn native_conductor_error(detail : String) -> @types.Response {
  @types.Response::Err("Conductor request: " + detail)
}

///|
fn native_conductor_goal_action_ok_json(value : Json) -> @types.Response {
  match value {
    Object(fields) => @types.Response::ok_values(fields)
    _ => native_conductor_error("internal response was not an object")
  }
}

///|
fn native_conductor_required_string(
  request : @types.Request,
  name : String,
) -> Result[String, @types.ChoirError] {
  match request.args.get(name) {
    Some(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed == "" {
        Err(@types.ChoirError::validation_error("missing " + name))
      } else {
        Ok(trimmed)
      }
    }
    None => Err(@types.ChoirError::validation_error("missing " + name))
  }
}

///|
fn native_conductor_optional_string(
  request : @types.Request,
  name : String,
) -> String? {
  match request.args.get(name) {
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
fn native_conductor_task_status(
  raw : String,
) -> Result[@types.TaskStatus, @types.ChoirError] {
  match @types.TaskStatus::try_parse_wire(raw) {
    Ok(value) => Ok(value)
    Err(_) =>
      Err(
        @types.ChoirError::validation_error(
          "task status must be todo, in_progress, or done",
        ),
      )
  }
}

///|
fn native_conductor_task_status_for_beads(status : @types.TaskStatus) -> String {
  match status {
    Todo => "open"
    InProgress => "in_progress"
    Done => "closed"
  }
}

///|
fn native_conductor_task_from_json(
  value : Json,
  require_dependency_details : Bool,
) -> Result[NativeConductorTask, @types.ChoirError] {
  guard value is Object(fields) else {
    return Err(@types.ChoirError::validation_error("invalid Beads task JSON"))
  }
  let id = @types.json_field_string(fields, "id").unwrap_or("")
  let title = @types.json_field_string(fields, "title").unwrap_or("")
  let status = @types.json_field_string(fields, "status").unwrap_or("")
  if id == "" || title == "" || status == "" {
    return Err(
      @types.ChoirError::validation_error(
        "Beads task requires id, title, and status",
      ),
    )
  }
  let parsed_status = match native_conductor_task_status(status) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let dependency_count = match fields.get("dependency_count") {
    Some(Number(value, ..)) if value.to_int() >= 0 => value.to_int()
    Some(_) =>
      return Err(
        @types.ChoirError::validation_error(
          "Beads task has an invalid dependency count",
        ),
      )
    None => 0
  }
  let blocking_dependency_ids : Array[String] = []
  let dependencies_loaded = match fields.get("dependencies") {
    Some(Array(dependencies)) => {
      if dependency_count != dependencies.length() {
        return Err(
          @types.ChoirError::validation_error(
            "Beads task dependency count does not match its details",
          ),
        )
      }
      for dependency in dependencies {
        guard dependency is Object(dependency_fields) else {
          return Err(
            @types.ChoirError::validation_error(
              "Beads task contains an invalid dependency",
            ),
          )
        }
        let dependency_id = @types.json_field_string(dependency_fields, "id")
          .unwrap_or("")
          .trim()
          .to_owned()
        let dependency_type = @types.json_field_string(
            dependency_fields, "dependency_type",
          )
          .unwrap_or("")
          .trim()
          .to_owned()
        if dependency_id == "" || dependency_type == "" {
          return Err(
            @types.ChoirError::validation_error(
              "Beads task dependency requires id and dependency_type",
            ),
          )
        }
        if dependency_type == "blocks" {
          blocking_dependency_ids.push(dependency_id)
        }
      }
      blocking_dependency_ids.sort()
      true
    }
    Some(_) =>
      return Err(
        @types.ChoirError::validation_error(
          "Beads task dependencies have the wrong shape",
        ),
      )
    None => {
      if require_dependency_details && dependency_count > 0 {
        return Err(
          @types.ChoirError::validation_error(
            "Beads task omitted required dependency details",
          ),
        )
      }
      dependency_count == 0
    }
  }
  Ok({
    id,
    title,
    description: @types.json_field_string(fields, "description").unwrap_or(""),
    acceptance_criteria: @types.json_field_string(fields, "acceptance_criteria").unwrap_or(
      "",
    ),
    status: parsed_status,
    assignee: @types.json_field_string(fields, "assignee").unwrap_or(""),
    notes: @types.json_field_string(fields, "notes").unwrap_or(""),
    dependency_count,
    blocking_dependency_ids,
    dependencies_loaded,
  })
}

///|
fn native_conductor_tasks_from_output(
  output : String,
  require_dependency_details? : Bool = false,
) -> Result[Array[NativeConductorTask], @types.ChoirError] {
  let value = @json.parse(output) catch {
    _ => return Err(@types.ChoirError::validation_error("invalid Beads JSON"))
  }
  let items = match value {
    Array(values) => values
    Object(_) => [value]
    _ => return Err(@types.ChoirError::validation_error("invalid Beads JSON"))
  }
  let tasks : Array[NativeConductorTask] = []
  for item in items {
    match native_conductor_task_from_json(item, require_dependency_details) {
      Ok(task) => tasks.push(task)
      Err(error) => return Err(error)
    }
  }
  Ok(tasks)
}

///|
fn NativeConductorTask::to_json(self : NativeConductorTask) -> Json {
  {
    "id": self.id.to_json(),
    "title": self.title.to_json(),
    "description": self.description.to_json(),
    "acceptance_criteria": self.acceptance_criteria.to_json(),
    "status": self.status.to_wire_string().to_json(),
    "assignee": self.assignee.to_json(),
    "notes": self.notes.to_json(),
    "dependency_count": self.dependency_count.to_json(),
    "blocking_dependency_ids": self.blocking_dependency_ids.to_json(),
    "dependencies_loaded": self.dependencies_loaded.to_json(),
  }.to_json()
}

///|
pub async fn validate_native_beads_cli(
  capture? : async (Command) -> (Int, String) = capture_command_merged,
) -> Result[Unit, @types.ChoirError] {
  let (exit_code, output) = capture({
    program: "bd",
    args: ["--version"],
    workdir: None,
  })
  if exit_code != 0 {
    return Err(
      @types.ChoirError::transport_error(
        "Beads 1.1.0 is required but bd --version failed",
      ),
    )
  }
  if output.trim() != "bd version 1.1.0 (v1.1.0)" {
    return Err(
      @types.ChoirError::validation_error(
        "Beads 1.1.0 is required; observed " + output.trim().to_owned(),
      ),
    )
  }
  Ok(())
}

///|
async fn native_conductor_capture_beads(
  project_dir : String,
  operation : String,
  arguments : Array[String],
  capture : async (Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (exit_code, output) = capture({
    program: "bd",
    args: arguments,
    workdir: Some(project_dir),
  })
  if exit_code == 0 {
    Ok(output)
  } else {
    let detail = output.trim().to_owned()
    let suffix = if detail == "" { "" } else { ": " + detail }
    Err(
      @types.ChoirError::transport_error(
        "bd " +
        operation +
        " failed with status " +
        exit_code.to_string() +
        suffix,
      ),
    )
  }
}

///|
async fn dispatch_native_task_list(
  project_dir : String,
  capture : async (Command) -> (Int, String),
) -> @types.Response {
  let output = match
    native_conductor_capture_beads(
      project_dir,
      "list",
      ["list", "--json", "--all", "--readonly"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  let tasks = match native_conductor_tasks_from_output(output) {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  @types.Response::ok_values({
    "status": "ok".to_json(),
    "tasks": tasks.map(fn(task) { task.to_json() }).to_json(),
  })
}

///|
async fn dispatch_native_task_get(
  project_dir : String,
  request : @types.Request,
  capture : async (Command) -> (Int, String),
) -> @types.Response {
  let id = match native_conductor_required_string(request, "id") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  let output = match
    native_conductor_capture_beads(
      project_dir,
      "show",
      ["show", id, "--json", "--readonly"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  match
    native_conductor_tasks_from_output(output, require_dependency_details=true) {
    Ok([task]) =>
      @types.Response::ok_values({
        "status": "ok".to_json(),
        "task": task.to_json(),
      })
    Ok(_) => native_conductor_error("Beads show returned an invalid task set")
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
fn native_conductor_task_create_arguments(
  request : @types.Request,
) -> Result[(String, @types.TaskStatus, Array[String]), @types.ChoirError] {
  let id = match native_conductor_required_string(request, "id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let title = match native_conductor_required_string(request, "title") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let status = match native_conductor_optional_string(request, "status") {
    Some(value) =>
      match native_conductor_task_status(value) {
        Ok(parsed) => parsed
        Err(error) => return Err(error)
      }
    None => @types.TaskStatus::Todo
  }
  let arguments : Array[String] = [
    "create", title, "--id", id, "--force", "--type", "task", "--priority", "2",
    "--json",
  ]
  match native_conductor_optional_string(request, "assignee") {
    Some(value) => {
      arguments.push("--assignee")
      arguments.push(value)
    }
    None => ()
  }
  match native_conductor_optional_string(request, "notes") {
    Some(value) => {
      arguments.push("--notes")
      arguments.push(value)
    }
    None => ()
  }
  Ok((id, status, arguments))
}

///|
async fn dispatch_native_task_create(
  project_dir : String,
  request : @types.Request,
  capture : async (Command) -> (Int, String),
) -> @types.Response {
  let (id, status, arguments) = match
    native_conductor_task_create_arguments(request) {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  let existing = capture({
    program: "bd",
    args: ["show", id, "--json"],
    workdir: Some(project_dir),
  })
  if existing.0 == 0 {
    return match native_conductor_tasks_from_output(existing.1) {
      Ok([task]) =>
        @types.Response::ok_values({
          "status": "ok".to_json(),
          "created": false.to_json(),
          "task": task.to_json(),
        })
      Ok(_) => native_conductor_error("existing Bead result was ambiguous")
      Err(error) => @types.Response::Err(error.message())
    }
  }
  let created = match
    native_conductor_capture_beads(project_dir, "create", arguments, capture) {
    Ok(output) => output
    Err(error) => return @types.Response::Err(error.message())
  }
  let task = match native_conductor_tasks_from_output(created) {
    Ok([value]) => value
    Ok(_) => return native_conductor_error("Beads create returned no task")
    Err(error) => return @types.Response::Err(error.message())
  }
  let final_task = if status == @types.TaskStatus::Todo {
    task
  } else {
    let updated = match
      native_conductor_capture_beads(
        project_dir,
        "update",
        [
          "update",
          id,
          "--status",
          native_conductor_task_status_for_beads(status),
          "--json",
        ],
        capture,
      ) {
      Ok(output) => output
      Err(error) => return @types.Response::Err(error.message())
    }
    match native_conductor_tasks_from_output(updated) {
      Ok([value]) => value
      Ok(_) => return native_conductor_error("Beads update returned no task")
      Err(error) => return @types.Response::Err(error.message())
    }
  }
  @types.Response::ok_values({
    "status": "ok".to_json(),
    "created": true.to_json(),
    "task": final_task.to_json(),
  })
}

///|
pub(all) struct NativeMigrationBeadMaterialization {
  bead_ids : Array[String]
  created_ids : Array[String]
  adopted_ids : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativeMigrationBeadContent {
  id : String
  title : String
  description : String
  acceptance_criteria : String
  notes : String
  blocking_dependency_ids : Array[String]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn native_migration_bead_description(
  proposal : @migration.MigrationBeadProposal,
) -> String {
  let paths = proposal.source_paths.map(@control.repo_path_text)
  paths.sort()
  "Migration inventory unit: " +
  proposal.stable_key.0 +
  "\nContract: " +
  proposal.migration_contract_ref.contract_artifact_digest.0 +
  "\nOwnership: " +
  proposal.ownership_claim.0 +
  "\nPaths: " +
  paths.join(",")
}

///|
fn native_migration_bead_acceptance(
  proposal : @migration.MigrationBeadProposal,
) -> String {
  let specs = proposal.verification_specs.map(fn(spec) {
    spec.id.0 +
    "@" +
    spec.version.to_string() +
    ":" +
    spec.digest.0 +
    ":" +
    spec.process_spec_digest.0
  })
  specs.sort()
  "Declared verification: " + specs.join(",")
}

///|
fn native_migration_bead_notes(
  proposal : @migration.MigrationBeadProposal,
) -> String {
  "migration-idempotency:" +
  proposal.idempotency_key.0 +
  "\nproposal-digest:" +
  @storage.artifact_digest(
    @migration.canonical_migration_bead_proposal_bytes(proposal),
  ).0
}

///|
pub fn native_migration_bead_content(
  proposal : @migration.MigrationBeadProposal,
) -> NativeMigrationBeadContent {
  let dependencies = proposal.blocking_dependency_ids.map(fn(id) { id.0 })
  dependencies.sort()
  {
    id: proposal.id.0,
    title: proposal.title,
    description: native_migration_bead_description(proposal),
    acceptance_criteria: native_migration_bead_acceptance(proposal),
    notes: native_migration_bead_notes(proposal),
    blocking_dependency_ids: dependencies,
  }
}

///|
fn native_migration_bead_is_exact(
  task : NativeConductorTask,
  proposal : @migration.MigrationBeadProposal,
) -> Bool {
  let content = native_migration_bead_content(proposal)
  task.id == content.id &&
  task.title == content.title &&
  task.description == content.description &&
  task.acceptance_criteria == content.acceptance_criteria &&
  task.notes == content.notes &&
  task.status == @types.TaskStatus::Todo &&
  task.dependencies_loaded &&
  task.blocking_dependency_ids == content.blocking_dependency_ids
}

///|
pub async fn materialize_native_migration_beads(
  project_dir : String,
  proposals : Array[@migration.MigrationBeadProposal],
  capture? : async (Command) -> (Int, String) = capture_command_merged,
) -> Result[NativeMigrationBeadMaterialization, @types.ChoirError] {
  let ordered = proposals.copy()
  ordered.sort_by(fn(left, right) { left.id.compare(right.id) })
  for index, proposal in ordered {
    if @migration.validate_migration_bead_proposal(proposal, fn(_) { true })
      is Err(_) ||
      ordered[index + 1:].any(fn(candidate) { candidate.id == proposal.id }) {
      return Err(
        @types.ChoirError::validation_error(
          "migration Bead proposal identity is invalid",
        ),
      )
    }
    if proposal.blocking_dependency_ids.any(fn(dependency) {
        !ordered.any(fn(candidate) { candidate.id == dependency })
      }) {
      return Err(
        @types.ChoirError::validation_error(
          "migration Bead dependency proposal is absent",
        ),
      )
    }
  }
  let missing : Array[@migration.MigrationBeadProposal] = []
  let adopted_ids : Array[String] = []
  for proposal in ordered {
    let observed = capture({
      program: "bd",
      args: ["show", proposal.id.0, "--json", "--readonly"],
      workdir: Some(project_dir),
    })
    if observed.0 != 0 {
      missing.push(proposal)
      continue
    }
    let task = match
      native_conductor_tasks_from_output(
        observed.1,
        require_dependency_details=true,
      ) {
      Ok([value]) => value
      Ok(_) =>
        return Err(
          @types.ChoirError::validation_error(
            "existing migration Bead is ambiguous",
          ),
        )
      Err(error) => return Err(error)
    }
    if !native_migration_bead_is_exact(task, proposal) {
      return Err(
        @types.ChoirError::validation_error(
          "existing migration Bead conflicts with its proposal",
        ),
      )
    }
    adopted_ids.push(proposal.id.0)
  }
  let created_ids : Array[String] = []
  let pending = missing.copy()
  while pending.length() > 0 {
    let mut progressed = false
    for index = pending.length() - 1; index >= 0; index = index - 1 {
      let proposal = pending[index]
      if proposal.blocking_dependency_ids.any(fn(dependency) {
          pending.any(fn(candidate) { candidate.id == dependency })
        }) {
        continue
      }
      let dependencies = proposal.blocking_dependency_ids.map(fn(id) { id.0 })
      dependencies.sort()
      let arguments = [
        "create",
        proposal.title,
        "--id",
        proposal.id.0,
        "--force",
        "--type",
        "task",
        "--priority",
        "2",
        "--json",
        "--description",
        native_migration_bead_description(proposal),
        "--acceptance",
        native_migration_bead_acceptance(proposal),
        "--notes",
        native_migration_bead_notes(proposal),
      ]
      if dependencies.length() > 0 {
        arguments.push("--deps")
        arguments.push(dependencies.join(","))
      }
      match
        native_conductor_capture_beads(
          project_dir, "create migration Bead", arguments, capture,
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      let verified = match
        native_conductor_capture_beads(
          project_dir,
          "show migration Bead",
          ["show", proposal.id.0, "--json", "--readonly"],
          capture,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let task = match
        native_conductor_tasks_from_output(
          verified,
          require_dependency_details=true,
        ) {
        Ok([value]) => value
        Ok(_) =>
          return Err(
            @types.ChoirError::validation_error(
              "created migration Bead is ambiguous",
            ),
          )
        Err(error) => return Err(error)
      }
      if !native_migration_bead_is_exact(task, proposal) {
        return Err(
          @types.ChoirError::validation_error(
            "created migration Bead does not match its proposal",
          ),
        )
      }
      created_ids.push(proposal.id.0)
      ignore(pending.remove(index))
      progressed = true
    }
    if !progressed {
      return Err(
        @types.ChoirError::validation_error(
          "migration Bead dependency graph is cyclic",
        ),
      )
    }
  }
  created_ids.sort()
  adopted_ids.sort()
  Ok({
    bead_ids: ordered.map(fn(proposal) { proposal.id.0 }),
    created_ids,
    adopted_ids,
  })
}

///|
async fn dispatch_native_task_update(
  project_dir : String,
  request : @types.Request,
  capture : async (Command) -> (Int, String),
) -> @types.Response {
  let id = match native_conductor_required_string(request, "id") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  let arguments : Array[String] = ["update", id]
  match native_conductor_optional_string(request, "status") {
    Some(raw) =>
      match native_conductor_task_status(raw) {
        Ok(status) => {
          arguments.push("--status")
          arguments.push(native_conductor_task_status_for_beads(status))
        }
        Err(error) => return @types.Response::Err(error.message())
      }
    None => ()
  }
  match native_conductor_optional_string(request, "assignee") {
    Some(value) => {
      arguments.push("--assignee")
      arguments.push(value)
    }
    None => ()
  }
  match native_conductor_optional_string(request, "notes") {
    Some(value) => {
      arguments.push("--notes")
      arguments.push(value)
    }
    None => ()
  }
  if arguments.length() == 2 {
    return dispatch_native_task_get(project_dir, request, capture)
  }
  arguments.push("--json")
  let output = match
    native_conductor_capture_beads(project_dir, "update", arguments, capture) {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  match native_conductor_tasks_from_output(output) {
    Ok([task]) =>
      @types.Response::ok_values({
        "status": "ok".to_json(),
        "task": task.to_json(),
      })
    Ok(_) => native_conductor_error("Beads update returned no task")
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
fn native_conductor_goal_draft_json(
  request : @types.Request,
  goal_id : @control.GoalId,
) -> String {
  let fields : Map[String, Json] = Map([])
  request.args.each_json(fn(key, value) { fields.set(key, value) })
  fields.set("goal_id", goal_id.0.to_json())
  fields.to_json().stringify(indent=0)
}

///|
test "native Conductor mints Goal identity around structured submission arguments" {
  let part : Json = {
    "part_id": "bead-1".to_json(),
    "instruction": "implement the contract".to_json(),
    "provider": "codex".to_json(),
    "exact_paths": ["README.md"].to_json(),
    "path_trees": ([] : Array[String]).to_json(),
    "repository_wide": false.to_json(),
    "moon_args": ["test", "--target", "native"].to_json(),
  }.to_json()
  let request : @types.Request = {
    req_method: "tools/call",
    name: "goal_submit",
    args: @types.RequestArgs::from_values({
      "proposal_id": "proposal-1".to_json(),
      "goal_id": "bead-1-must-not-control-goal-identity".to_json(),
      "pull_request": {
        "title": "docs: update the README".to_json(),
        "body": "Updates the README and verifies the native suite.".to_json(),
      }.to_json(),
      "maximum_parallel_parts": (1).to_json(),
      "parts": [part].to_json(),
    }),
  }
  let draft = match
    @workflow.decode_conductor_goal_draft(
      native_conductor_goal_draft_json(
        request,
        @control.GoalId("goal-minted-by-choir"),
      ),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(draft.goal_id, @control.GoalId("goal-minted-by-choir"))
  assert_eq(draft.parts[0].part_id, @control.PartId("bead-1"))
  assert_eq(draft.parts[0].verification.arguments, [
    "test", "--target", "native",
  ])
}

///|
async fn dispatch_native_goal_submit(
  project_dir : String,
  request : @types.Request,
  capture : async (Command) -> (Int, String),
) -> @types.Response {
  let token = match @sys.mint_local_token() {
    Some(value) => value
    None =>
      return native_conductor_error("failed to mint a durable Goal identity")
  }
  let draft = native_conductor_goal_draft_json(
    request,
    @control.GoalId("goal-" + token),
  )
  match submit_native_conductor_goal_draft(project_dir, draft, capture) {
    Ok(report) => native_conductor_goal_action_ok_json(report.to_json())
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
fn dispatch_native_goal_status(
  project_dir : String,
  request : @types.Request,
) -> @types.Response {
  let report = match
    (
      native_conductor_optional_string(request, "goal_id"),
      native_conductor_optional_string(request, "part_id"),
    ) {
    (Some(goal_id), None) =>
      inspect_native_goal(project_dir, @control.GoalId(goal_id))
    (None, Some(part_id)) =>
      inspect_native_goal_for_part(project_dir, @control.PartId(part_id))
    _ =>
      return @types.Response::Err(
        "goal_status requires exactly one of goal_id or part_id",
      )
  }
  match report {
    Ok(report) => {
      guard report.to_json() is Object(fields) else {
        return native_conductor_error("status response was not an object")
      }
      match
        native_goal_publication_probe_diagnostic(project_dir, report.goal_id) {
        Some(diagnostic) => {
          fields.set("publication_observation_diagnostic", diagnostic)
          fields.set("diagnostic_is_observational", true.to_json())
        }
        None => ()
      }
      native_conductor_goal_action_ok_json(fields.to_json())
    }
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
fn dispatch_native_goal_cancel(
  project_dir : String,
  request : @types.Request,
  now : Int64,
) -> @types.Response {
  let goal_id = match native_conductor_required_string(request, "goal_id") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  match cancel_native_goal(project_dir, @control.GoalId(goal_id), now) {
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationPersisted(
        record
      )
    ) =>
      native_conductor_goal_action_ok_json(
        {
          "goal_id": record.goal.id.to_json(),
          "state": record.state.to_json(),
          "lifecycle": record.goal.lifecycle.to_json(),
          "durable_version": record.durable_version.to_json(),
          "replayed": false.to_json(),
        }.to_json(),
      )
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationReplayed(
        record
      )
    ) =>
      native_conductor_goal_action_ok_json(
        {
          "goal_id": record.goal.id.to_json(),
          "state": record.state.to_json(),
          "lifecycle": record.goal.lifecycle.to_json(),
          "durable_version": record.durable_version.to_json(),
          "replayed": true.to_json(),
        }.to_json(),
      )
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationTerminal(
        state
      )
    ) =>
      native_conductor_goal_action_ok_json(
        {
          "goal_id": goal_id.to_json(),
          "state": state.to_json(),
          "already_terminal": true.to_json(),
        }.to_json(),
      )
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
fn native_conductor_policy_change(
  request : @types.Request,
) -> Result[@workflow.GoalPolicyChange, @types.ChoirError] {
  let action = match native_conductor_required_string(request, "action") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match action {
    "pause" => Ok(@workflow.GoalPolicyChange::GoalPolicyPause)
    "resume" => Ok(@workflow.GoalPolicyChange::GoalPolicyResume)
    "set_concurrency" => {
      let maximum = match request.args.get_int("maximum_parallel_parts") {
        Some(value) => value
        None =>
          match request.args.get("maximum_parallel_parts") {
            Some(raw) => @string.parse_int(raw) catch { _ => 0 }
            None => 0
          }
      }
      if maximum <= 0 {
        Err(
          @types.ChoirError::validation_error(
            "maximum_parallel_parts must be positive",
          ),
        )
      } else {
        Ok(
          @workflow.GoalPolicyChange::GoalPolicySetMaximumParallelParts(maximum),
        )
      }
    }
    _ =>
      Err(
        @types.ChoirError::validation_error(
          "action must be pause, resume, or set_concurrency",
        ),
      )
  }
}

///|
fn dispatch_native_goal_steer(
  project_dir : String,
  request : @types.Request,
) -> @types.Response {
  let goal_id = match native_conductor_required_string(request, "goal_id") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  if request.args.get("action") == Some("retry_part") {
    let part_id = request.args
      .get("part_id")
      .map(fn(value) { @control.PartId(value) })
    return match
      retry_native_goal_part(project_dir, @control.GoalId(goal_id), part_id) {
      Ok(record) =>
        native_conductor_goal_action_ok_json(
          {
            "goal_id": record.goal.id.to_json(),
            "state": record.state.to_json(),
            "lifecycle": record.goal.lifecycle.to_json(),
            "durable_version": record.durable_version.to_json(),
            "retried": true.to_json(),
          }.to_json(),
        )
      Err(error) => @types.Response::Err(error.message())
    }
  }
  let change = match native_conductor_policy_change(request) {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  match steer_native_goal(project_dir, @control.GoalId(goal_id), change) {
    Ok(
      @workflow.GoalSteeringPersistenceResult::GoalSteeringPersisted(
        record,
        revision
      )
    ) =>
      native_conductor_goal_action_ok_json(
        {
          "goal_id": record.goal.id.to_json(),
          "state": record.state.to_json(),
          "lifecycle": record.goal.lifecycle.to_json(),
          "durable_version": record.durable_version.to_json(),
          "maximum_parallel_parts": record.maximum_parallel_parts.to_json(),
          "policy_revision": revision.to_json(),
          "pause": record.pause.to_json(),
          "replayed": false.to_json(),
        }.to_json(),
      )
    Ok(@workflow.GoalSteeringPersistenceResult::GoalSteeringReplayed(record))
    | Ok(@workflow.GoalSteeringPersistenceResult::GoalSteeringNoChange(record)) =>
      native_conductor_goal_action_ok_json(
        {
          "goal_id": record.goal.id.to_json(),
          "state": record.state.to_json(),
          "lifecycle": record.goal.lifecycle.to_json(),
          "durable_version": record.durable_version.to_json(),
          "maximum_parallel_parts": record.maximum_parallel_parts.to_json(),
          "pause": record.pause.to_json(),
          "replayed": true.to_json(),
        }.to_json(),
      )
    Ok(@workflow.GoalSteeringPersistenceResult::GoalSteeringTerminal(state)) =>
      native_conductor_goal_action_ok_json(
        {
          "goal_id": goal_id.to_json(),
          "state": state.to_json(),
          "already_terminal": true.to_json(),
        }.to_json(),
      )
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
fn dispatch_native_goal_attach(
  project_dir : String,
  request : @types.Request,
) -> @types.Response {
  let take_id = match native_conductor_required_string(request, "take_id") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  match attach_native_goal(project_dir, @control.TakeId(take_id)) {
    Ok(report) => {
      guard report is Object(fields) else {
        return native_conductor_error("attach response was not an object")
      }
      fields.set("observational", true.to_json())
      native_conductor_goal_action_ok_json(fields.to_json())
    }
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
fn dispatch_native_goal_answer(
  project_dir : String,
  request : @types.Request,
  now : Int64,
) -> @types.Response {
  let request_id = match
    native_conductor_required_string(request, "request_id") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  let answer = match native_conductor_required_string(request, "answer") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  match
    answer_native_goal_input(
      project_dir,
      @workflow.GoalInputRequestId(request_id),
      answer,
      now,
    ) {
    Ok(
      @workflow.GoalInputAnswerPersistenceResult::GoalInputAnswerPersisted(
        record,
        receipt
      )
    ) =>
      native_conductor_goal_action_ok_json(
        {
          "goal_id": record.goal.id.to_json(),
          "state": record.state.to_json(),
          "lifecycle": record.goal.lifecycle.to_json(),
          "durable_version": record.durable_version.to_json(),
          "answer": receipt.to_json(),
          "replayed": false.to_json(),
        }.to_json(),
      )
    Ok(
      @workflow.GoalInputAnswerPersistenceResult::GoalInputAnswerPersistenceReplayed(
        record,
        receipt
      )
    ) =>
      native_conductor_goal_action_ok_json(
        {
          "goal_id": record.goal.id.to_json(),
          "state": record.state.to_json(),
          "lifecycle": record.goal.lifecycle.to_json(),
          "durable_version": record.durable_version.to_json(),
          "answer": receipt.to_json(),
          "replayed": true.to_json(),
        }.to_json(),
      )
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
pub async fn dispatch_native_conductor_request(
  project_dir : String,
  request : @types.Request,
  now? : Int64 = @env.now().reinterpret_as_int64() / 1000L,
  capture? : async (Command) -> (Int, String) = capture_command_merged,
) -> @types.Response {
  if request.req_method != "tools/call" {
    return native_conductor_error("authenticated Conductor required")
  }
  match request.name {
    "goal_submit" => dispatch_native_goal_submit(project_dir, request, capture)
    "goal_status" => dispatch_native_goal_status(project_dir, request)
    "goal_cancel" => dispatch_native_goal_cancel(project_dir, request, now)
    "goal_steer" => dispatch_native_goal_steer(project_dir, request)
    "goal_attach" => dispatch_native_goal_attach(project_dir, request)
    "goal_answer" => dispatch_native_goal_answer(project_dir, request, now)
    "task_list" => dispatch_native_task_list(project_dir, capture)
    "task_get" => dispatch_native_task_get(project_dir, request, capture)
    "task_create" => dispatch_native_task_create(project_dir, request, capture)
    "task_update" => dispatch_native_task_update(project_dir, request, capture)
    _ => native_conductor_error("unknown tool " + request.name)
  }
}

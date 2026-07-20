///|
priv struct NativeConductorTask {
  id : String
  title : String
  status : @types.TaskStatus
  assignee : String
  notes : String
}

///|
fn native_conductor_error(detail : String) -> @types.Response {
  @types.Response::Err("Conductor request: " + detail)
}

///|
fn native_conductor_ok_json(value : Json) -> @types.Response {
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
  Ok({
    id,
    title,
    status: parsed_status,
    assignee: @types.json_field_string(fields, "assignee").unwrap_or(""),
    notes: @types.json_field_string(fields, "notes").unwrap_or(""),
  })
}

///|
fn native_conductor_tasks_from_output(
  output : String,
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
    match native_conductor_task_from_json(item) {
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
    "status": self.status.to_wire_string().to_json(),
    "assignee": self.assignee.to_json(),
    "notes": self.notes.to_json(),
  }.to_json()
}

///|
async fn native_conductor_capture_beads(
  project_dir : String,
  operation : String,
  arguments : Array[String],
  capture : async (@workspace.Command) -> (Int, String),
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
  capture : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  let output = match
    native_conductor_capture_beads(
      project_dir,
      "list",
      ["list", "--json", "--all"],
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
  capture : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  let id = match native_conductor_required_string(request, "id") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  let output = match
    native_conductor_capture_beads(
      project_dir,
      "show",
      ["show", id, "--json"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  match native_conductor_tasks_from_output(output) {
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
  capture : async (@workspace.Command) -> (Int, String),
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
async fn dispatch_native_task_update(
  project_dir : String,
  request : @types.Request,
  capture : async (@workspace.Command) -> (Int, String),
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
async fn dispatch_native_goal_submit(
  project_dir : String,
  request : @types.Request,
  capture : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  let draft = match native_conductor_required_string(request, "draft_json") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  match submit_native_conductor_goal_draft(project_dir, draft, capture) {
    Ok(report) => native_conductor_ok_json(report.to_json())
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
fn dispatch_native_goal_status(
  project_dir : String,
  request : @types.Request,
) -> @types.Response {
  let goal_id = match native_conductor_required_string(request, "goal_id") {
    Ok(value) => value
    Err(error) => return @types.Response::Err(error.message())
  }
  match inspect_native_goal(project_dir, @control.GoalId(goal_id)) {
    Ok(report) => native_conductor_ok_json(report.to_json())
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
      @types.Response::ok_values({
        "goal_id": record.goal.id.to_json(),
        "state": record.state.to_json(),
        "lifecycle": record.goal.lifecycle.to_json(),
        "durable_version": record.durable_version.to_json(),
        "replayed": false.to_json(),
      })
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationReplayed(
        record
      )
    ) =>
      @types.Response::ok_values({
        "goal_id": record.goal.id.to_json(),
        "state": record.state.to_json(),
        "lifecycle": record.goal.lifecycle.to_json(),
        "durable_version": record.durable_version.to_json(),
        "replayed": true.to_json(),
      })
    Ok(
      @workflow.GoalCancellationPersistenceResult::GoalCancellationTerminal(
        state
      )
    ) =>
      @types.Response::ok_values({
        "goal_id": goal_id.to_json(),
        "state": state.to_json(),
        "already_terminal": true.to_json(),
      })
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
      @types.Response::ok_values({
        "goal_id": record.goal.id.to_json(),
        "state": record.state.to_json(),
        "lifecycle": record.goal.lifecycle.to_json(),
        "durable_version": record.durable_version.to_json(),
        "maximum_parallel_parts": record.maximum_parallel_parts.to_json(),
        "policy_revision": revision.to_json(),
        "pause": record.pause.to_json(),
        "replayed": false.to_json(),
      })
    Ok(@workflow.GoalSteeringPersistenceResult::GoalSteeringReplayed(record))
    | Ok(@workflow.GoalSteeringPersistenceResult::GoalSteeringNoChange(record)) =>
      @types.Response::ok_values({
        "goal_id": record.goal.id.to_json(),
        "state": record.state.to_json(),
        "lifecycle": record.goal.lifecycle.to_json(),
        "durable_version": record.durable_version.to_json(),
        "maximum_parallel_parts": record.maximum_parallel_parts.to_json(),
        "pause": record.pause.to_json(),
        "replayed": true.to_json(),
      })
    Ok(@workflow.GoalSteeringPersistenceResult::GoalSteeringTerminal(state)) =>
      @types.Response::ok_values({
        "goal_id": goal_id.to_json(),
        "state": state.to_json(),
        "already_terminal": true.to_json(),
      })
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
      guard report.to_json() is Object(fields) else {
        return native_conductor_error("attach response was not an object")
      }
      fields.set("observational", true.to_json())
      @types.Response::ok_values(fields)
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
      @types.Response::ok_values({
        "goal_id": record.goal.id.to_json(),
        "state": record.state.to_json(),
        "lifecycle": record.goal.lifecycle.to_json(),
        "durable_version": record.durable_version.to_json(),
        "answer": receipt.to_json(),
        "replayed": false.to_json(),
      })
    Ok(
      @workflow.GoalInputAnswerPersistenceResult::GoalInputAnswerPersistenceReplayed(
        record,
        receipt
      )
    ) =>
      @types.Response::ok_values({
        "goal_id": record.goal.id.to_json(),
        "state": record.state.to_json(),
        "lifecycle": record.goal.lifecycle.to_json(),
        "durable_version": record.durable_version.to_json(),
        "answer": receipt.to_json(),
        "replayed": true.to_json(),
      })
    Err(error) => @types.Response::Err(error.message())
  }
}

///|
pub async fn dispatch_native_conductor_request(
  project_dir : String,
  request : @types.Request,
  now? : Int64 = @env.now().reinterpret_as_int64() / 1000L,
  capture? : async (@workspace.Command) -> (Int, String) = capture_command_merged,
) -> @types.Response {
  if request.req_method != "tools/call" || request.role != @types.Role::TL {
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

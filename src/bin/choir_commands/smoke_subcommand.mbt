///|
pub(all) struct SmokeBeadsArgs {
  issue_id : String
  slug : String
  caller_id : String
  timeout_sec : Int
  poll_interval_ms : Int
  help : Bool
} derive(Debug, Eq)

///|
pub(all) struct SmokeBeadsReport {
  issue_id : String
  worker_id : String
  role : String
  agent_type : String
  beads_issue_id : String
  worker_status : String
  final_status : String
} derive(Debug, Eq)

///|
fn parse_positive_int_flag(
  flag : String,
  raw : String,
) -> Result[Int, @types.ChoirError] {
  let value = @string.parse_int(raw.trim().to_owned()) catch {
    _ =>
      return Err(
        @types.ChoirError::validation_error(flag + " must be a positive number"),
      )
  }
  if value <= 0 {
    return Err(
      @types.ChoirError::validation_error(flag + " must be a positive number"),
    )
  }
  Ok(value)
}

///|
fn default_smoke_suffix() -> String {
  @env.now().reinterpret_as_int64().to_string()
}

///|
pub fn parse_smoke_beads_args(
  args : Array[String],
) -> Result[SmokeBeadsArgs, @types.ChoirError] {
  let suffix = default_smoke_suffix()
  let mut issue_id = "choir-beads-handoff-smoke-" + suffix
  let mut slug = "beads-handoff-smoke-" + suffix
  let mut caller_id = "main"
  let mut timeout_sec = 300
  let mut poll_interval_ms = 1000
  let mut help = false
  let mut i = 3
  while i < args.length() {
    match args[i] {
      "--help" | "-h" => {
        help = true
        i = i + 1
      }
      "--id" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--id requires a value"),
          )
        }
        issue_id = args[i + 1]
        i = i + 2
      }
      "--slug" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--slug requires a value"),
          )
        }
        slug = args[i + 1]
        i = i + 2
      }
      "--caller-id" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--caller-id requires a value"),
          )
        }
        caller_id = args[i + 1]
        i = i + 2
      }
      "--timeout-sec" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error(
              "--timeout-sec requires a value",
            ),
          )
        }
        timeout_sec = match
          parse_positive_int_flag("--timeout-sec", args[i + 1]) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        i = i + 2
      }
      "--poll-interval-ms" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error(
              "--poll-interval-ms requires a value",
            ),
          )
        }
        poll_interval_ms = match
          parse_positive_int_flag("--poll-interval-ms", args[i + 1]) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        i = i + 2
      }
      other =>
        return Err(
          @types.ChoirError::validation_error(
            "unknown smoke beads-handoff flag: " + other,
          ),
        )
    }
  }
  if issue_id.trim() == "" {
    return Err(@types.ChoirError::validation_error("--id cannot be empty"))
  }
  if slug.trim() == "" {
    return Err(@types.ChoirError::validation_error("--slug cannot be empty"))
  }
  if caller_id.trim() == "" {
    return Err(
      @types.ChoirError::validation_error("--caller-id cannot be empty"),
    )
  }
  Ok({ issue_id, slug, caller_id, timeout_sec, poll_interval_ms, help })
}

///|
fn smoke_beads_help() -> String {
  (
    #|usage: choir smoke beads-handoff [--id <issue_id>] [--slug <worker_slug>] [--caller-id <agent_id>] [--timeout-sec N]
    #|
    #|Runs a live Beads handoff canary through the Choir server:
    #|  create a Beads task, spawn one read-only worker with beads_issue_id,
    #|  observe task_get + notify_parent events, close the task,
    #|  export .beads/issues.jsonl, and reject unrelated git mutations.
    #|  Worker shutdown is observability-only after notify_parent.
    #|
  )
}

///|
fn smoke_help() -> String {
  (
    #|usage: choir smoke <beads-handoff>
    #|
    #|Commands:
    #|  beads-handoff     Run a live Beads handoff canary
    #|
  )
}

///|
fn json_obj(fields : Map[String, Json]) -> Json {
  fields.to_json()
}

///|
pub fn smoke_beads_worker_task(issue_id : String) -> String {
  "Read the assigned Beads issue via `task_get " +
  issue_id +
  "` or `bd show " +
  issue_id +
  " --json`, then `notify_parent` with only the issue id, title, and status. Do not edit files, commit, create branches, file PRs, or close the issue."
}

///|
pub fn smoke_beads_task_create_args(args : SmokeBeadsArgs) -> Map[String, Json] {
  {
    "id": args.issue_id.to_json(),
    "title": "Live Choir Beads handoff smoke".to_json(),
    "status": "in_progress".to_json(),
    "notes": "Created by `choir smoke beads-handoff`.".to_json(),
  }
}

///|
pub fn smoke_beads_spawn_args(args : SmokeBeadsArgs) -> Map[String, Json] {
  {
    "caller_id": args.caller_id.to_json(),
    "slug": args.slug.to_json(),
    "worker_type": "research".to_json(),
    "task": smoke_beads_worker_task(args.issue_id).to_json(),
    "beads_issue_id": args.issue_id.to_json(),
    "contract": json_obj({ "beads_issue_id": args.issue_id.to_json() }),
  }
}

///|
fn command_string(cmd : @workspace.Command) -> String {
  cmd.to_string()
}

///|
fn make_choir_tool_command(
  choir_exe : String,
  tool : String,
  args_json : Map[String, Json],
  project_dir : String,
) -> @workspace.Command {
  {
    program: choir_exe,
    args: [
      "tool",
      tool,
      "--caller-role",
      "tl",
      "--json",
      args_json.to_json().stringify(),
    ],
    workdir: Some(project_dir),
  }
}

///|
fn make_bd_close_command(
  issue_id : String,
  project_dir : String,
) -> @workspace.Command {
  {
    program: "bd",
    args: [
      "close", issue_id, "--reason", "Live Choir Beads handoff smoke passed",
    ],
    workdir: Some(project_dir),
  }
}

///|
fn make_bd_export_command(project_dir : String) -> @workspace.Command {
  {
    program: "bd",
    args: ["export", "--output", ".beads/issues.jsonl"],
    workdir: Some(project_dir),
  }
}

///|
fn make_git_status_command(project_dir : String) -> @workspace.Command {
  { program: "git", args: ["status", "--short"], workdir: Some(project_dir) }
}

///|
fn parse_tool_response_output(
  output : String,
) -> Result[@types.Response, @types.ChoirError] {
  let mut found : @types.Response? = None
  for raw in output.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    match @transport.parse_response(line) {
      Ok(resp) => found = Some(resp)
      Err(_) => ()
    }
  }
  match found {
    Some(resp) => Ok(resp)
    None =>
      Err(
        @types.ChoirError::transport_error(
          "tool command did not emit a Choir response",
        ),
      )
  }
}

///|
fn response_ok_fields(
  resp : @types.Response,
) -> Result[@types.ResponseFields, @types.ChoirError] {
  match resp {
    @types.Response::Ok(fields) => Ok(fields)
    @types.Response::Err(msg) => Err(@types.ChoirError::transport_error(msg))
  }
}

///|
async fn run_choir_tool(
  choir_exe : String,
  tool : String,
  args_json : Map[String, Json],
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[@types.ResponseFields, @types.ChoirError] {
  let cmd = make_choir_tool_command(choir_exe, tool, args_json, project_dir)
  let (code, output) = capture(cmd)
  if code != 0 {
    return Err(
      @types.ChoirError::transport_error(
        command_string(cmd) +
        " failed with exit " +
        code.to_string() +
        ": " +
        output,
      ),
    )
  }
  let resp = match parse_tool_response_output(output) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  response_ok_fields(resp)
}

///|
async fn run_command_ok(
  cmd : @workspace.Command,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (code, output) = capture(cmd)
  if code != 0 {
    return Err(
      @types.ChoirError::transport_error(
        command_string(cmd) +
        " failed with exit " +
        code.to_string() +
        ": " +
        output,
      ),
    )
  }
  Ok(output)
}

///|
fn spawn_worker_id(
  fields : @types.ResponseFields,
) -> Result[String, @types.ChoirError] {
  match fields.get("agent_id") {
    Some(id) if id != "" => Ok(id)
    _ =>
      Err(
        @types.ChoirError::transport_error(
          "spawn_worker response missing agent_id",
        ),
      )
  }
}

///|
fn field_or_unknown(fields : @types.ResponseFields, key : String) -> String {
  fields.get(key).unwrap_or("<unknown>")
}

///|
fn git_status_path(line : String) -> String {
  if line.length() <= 3 {
    return line.trim().to_owned()
  }
  let path = line[3:line.length()].trim().to_owned()
  match path.find(" -> ") {
    Some(idx) => path[idx + 4:path.length()].to_owned()
    None => path
  }
}

///|
fn git_status_paths(status : String) -> Array[String] {
  let paths : Array[String] = []
  for raw in status.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    paths.push(git_status_path(line))
  }
  paths
}

///|
pub fn git_status_only_beads_issue_export(status : String) -> Bool {
  for path in git_status_paths(status) {
    if path != ".beads/issues.jsonl" {
      return false
    }
  }
  true
}

///|
fn event_tool_ok(event : Event, tool : String) -> Bool {
  if event.type_ != "tools.call" {
    return false
  }
  guard event.data is Object(data) else { return false }
  @types.json_field_string(data, "tool") == Some(tool) &&
  @types.json_field_string(data, "status") == Some("ok")
}

///|
pub fn smoke_beads_events_pass(events : Array[Event]) -> Bool {
  let mut saw_task_get = false
  let mut saw_notify_parent = false
  for event in events {
    if event_tool_ok(event, "task_get") {
      saw_task_get = true
    }
    if event_tool_ok(event, "notify_parent") {
      saw_notify_parent = true
    }
  }
  saw_task_get && saw_notify_parent
}

///|
async fn wait_for_smoke_events(
  project_dir : String,
  worker_id : String,
  timeout_sec : Int,
  poll_interval_ms : Int,
  sleep_fn : async (Int) -> Unit,
) -> Result[Array[Event], @types.ChoirError] {
  let max_wait_ms = timeout_sec * 1000
  let mut waited = 0
  while waited <= max_wait_ms {
    let events = read_agent_events(project_dir, worker_id)
    if smoke_beads_events_pass(events) {
      return Ok(events)
    }
    sleep_fn(poll_interval_ms)
    waited = waited + poll_interval_ms
  }
  Err(
    @types.ChoirError::transport_error(
      "timed out waiting for worker task_get and notify_parent events",
    ),
  )
}

///|
fn validate_smoke_git_status(
  label : String,
  status : String,
) -> Result[Unit, @types.ChoirError] {
  if git_status_only_beads_issue_export(status) {
    Ok(())
  } else {
    Err(
      @types.ChoirError::validation_error(
        label +
        " has unrelated git changes; expected only .beads/issues.jsonl:\n" +
        status,
      ),
    )
  }
}

///|
pub async fn run_smoke_beads_handoff(
  args : SmokeBeadsArgs,
  choir_exe : String,
  project_dir : String,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> Result[SmokeBeadsReport, @types.ChoirError] {
  let before_status = match
    run_command_ok(make_git_status_command(project_dir), capture) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  match validate_smoke_git_status("pre-smoke git status", before_status) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }

  match
    run_choir_tool(
      choir_exe,
      "task_create",
      smoke_beads_task_create_args(args),
      project_dir,
      capture,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let spawn_fields = match
    run_choir_tool(
      choir_exe,
      "spawn_worker",
      smoke_beads_spawn_args(args),
      project_dir,
      capture,
    ) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let worker_id = match spawn_worker_id(spawn_fields) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let role = field_or_unknown(spawn_fields, "role")
  let agent_type = field_or_unknown(spawn_fields, "agent_type")
  let beads_issue_id = field_or_unknown(spawn_fields, "beads_issue_id")
  if beads_issue_id != args.issue_id {
    return Err(
      @types.ChoirError::validation_error(
        "spawn_worker returned beads_issue_id " +
        beads_issue_id +
        ", expected " +
        args.issue_id,
      ),
    )
  }

  match
    wait_for_smoke_events(
      project_dir,
      worker_id,
      args.timeout_sec,
      args.poll_interval_ms,
      sleep_fn,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }

  let worker_status = match
    run_command_ok(make_git_status_command(project_dir), capture) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  match validate_smoke_git_status("post-worker git status", worker_status) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }

  match
    run_command_ok(make_bd_close_command(args.issue_id, project_dir), capture) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match run_command_ok(make_bd_export_command(project_dir), capture) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let final_status = match
    run_command_ok(make_git_status_command(project_dir), capture) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  match validate_smoke_git_status("final git status", final_status) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }

  Ok({
    issue_id: args.issue_id,
    worker_id,
    role,
    agent_type,
    beads_issue_id,
    worker_status,
    final_status,
  })
}

///|
fn render_status_block(status : String) -> String {
  let trimmed = status.trim().to_owned()
  if trimmed == "" {
    "<clean>"
  } else {
    trimmed
  }
}

///|
pub fn render_smoke_beads_report(report : SmokeBeadsReport) -> String {
  "PASS choir smoke beads-handoff\n" +
  "issue_id: " +
  report.issue_id +
  "\nworker_id: " +
  report.worker_id +
  "\nrole: " +
  report.role +
  "\nagent_type: " +
  report.agent_type +
  "\nbeads_issue_id: " +
  report.beads_issue_id +
  "\nobserved: task_get ok, notify_parent ok; shutdown observability-only after notify_parent\npost_worker_git_status:\n" +
  render_status_block(report.worker_status) +
  "\nfinal_git_status:\n" +
  render_status_block(report.final_status) +
  "\n"
}

///|
fn smoke_beads_handoff_run(args : Array[String]) -> Unit {
  let parsed = match parse_smoke_beads_args(args) {
    Ok(value) => value
    Err(e) => {
      @sys.write_stderr("choir smoke beads-handoff: " + e.message() + "\n")
      @sys.write_stderr(smoke_beads_help())
      @sys.exit(1)
      return
    }
  }
  if parsed.help {
    @sys.write_stdout(smoke_beads_help())
    return
  }
  let choir_exe = if args.length() > 0 { args[0] } else { "choir" }
  let project_dir = "."
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      match run_smoke_beads_handoff(parsed, choir_exe, project_dir) {
        Ok(report) => @sys.write_stdout(render_smoke_beads_report(report))
        Err(e) => {
          @sys.write_stderr(
            "FAIL choir smoke beads-handoff: " + e.message() + "\n",
          )
          @sys.exit(1)
        }
      }
    })
  })
}

///|
pub fn smoke_subcommand_run() -> Unit {
  let args = @env.args()
  let subcmd = if args.length() >= 3 { args[2] } else { "" }
  match subcmd {
    "beads-handoff" => smoke_beads_handoff_run(args)
    "--help" | "-h" | "" => @sys.write_stdout(smoke_help())
    _ => {
      @sys.write_stderr("choir smoke: unknown command '" + subcmd + "'\n")
      @sys.write_stderr(smoke_help())
      @sys.exit(1)
    }
  }
}

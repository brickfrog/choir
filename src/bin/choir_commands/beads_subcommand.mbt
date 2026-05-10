///|
pub(all) struct BeadsWaveFromCliArgs {
  parent_id : String
  caller_id : String
  parent_branch : String
  slug_prefix : String
  execute : Bool
} derive(Debug, Eq)

///|
pub(all) struct BeadsGateCliArgs {
  issue_id : String
  gate_type : String
  reason : String
  await_id : String?
} derive(Debug, Eq)

///|
pub(all) struct BeadsSpecLinkCliArgs {
  issue_id : String
  feature_slug : String
  force : Bool
} derive(Debug, Eq)

///|
pub(all) enum BeadsCliRequest {
  WaveFrom(BeadsWaveFromCliArgs)
  Gate(BeadsGateCliArgs)
  MergeSlot(String)
  SpecLink(BeadsSpecLinkCliArgs)
  Doctor
  Help
} derive(Debug, Eq)

///|
fn beads_help() -> String {
  (
    #|usage: choir beads <command>
    #|
    #|Commands:
    #|  wave-from <parent-id> [--caller-id ID] [--parent-branch BR] [--slug-prefix PFX] [--execute]
    #|      Read ready child beads and print a fork_wave JSON plan, or execute it.
    #|  gate <issue-id> <type> <reason> [--await-id ID]
    #|      Create a Beads gate blocking an issue. Use type=bead and await-id=<rig>:<bead-id> for cross-repo blockers.
    #|  merge-slot <check|create|acquire|release>
    #|      Proxy Beads merge-slot coordination.
    #|  spec-link <issue-id> <feature-slug> [--force]
    #|      Link a bead to .choir/context/<feature-slug>-spec.md. Refuses missing or empty spec files unless forced.
    #|  doctor
    #|      Print Beads/Choir consistency counts and dirty export status.
    #|
  )
}

///|
fn parse_beads_wave_from_args(
  args : Array[String],
) -> Result[BeadsWaveFromCliArgs, @types.ChoirError] {
  if args.length() < 4 {
    return Err(
      @types.ChoirError::validation_error("wave-from requires <parent-id>"),
    )
  }
  let parent_id = args[3]
  let mut caller_id = "main"
  let mut parent_branch = "main"
  let mut slug_prefix = parent_id
  let mut execute = false
  let mut i = 4
  while i < args.length() {
    match args[i] {
      "--caller-id" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--caller-id requires a value"),
          )
        }
        caller_id = args[i + 1]
        i = i + 2
      }
      "--parent-branch" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error(
              "--parent-branch requires a value",
            ),
          )
        }
        parent_branch = args[i + 1]
        i = i + 2
      }
      "--slug-prefix" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error(
              "--slug-prefix requires a value",
            ),
          )
        }
        slug_prefix = args[i + 1]
        i = i + 2
      }
      "--execute" => {
        execute = true
        i = i + 1
      }
      other =>
        return Err(
          @types.ChoirError::validation_error(
            "unknown beads wave-from flag: " + other,
          ),
        )
    }
  }
  Ok({ parent_id, caller_id, parent_branch, slug_prefix, execute })
}

///|
fn parse_beads_gate_args(
  args : Array[String],
) -> Result[BeadsGateCliArgs, @types.ChoirError] {
  if args.length() < 6 {
    return Err(
      @types.ChoirError::validation_error(
        "gate requires <issue-id> <type> <reason>",
      ),
    )
  }
  let issue_id = args[3]
  let gate_type = args[4]
  let reason = args[5]
  let mut await_id : String? = None
  let mut i = 6
  while i < args.length() {
    match args[i] {
      "--await-id" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--await-id requires a value"),
          )
        }
        await_id = Some(args[i + 1])
        i = i + 2
      }
      other =>
        return Err(
          @types.ChoirError::validation_error(
            "unknown beads gate flag: " + other,
          ),
        )
    }
  }
  Ok({ issue_id, gate_type, reason, await_id })
}

///|
fn parse_beads_spec_link_args(
  args : Array[String],
) -> Result[BeadsSpecLinkCliArgs, @types.ChoirError] {
  if args.length() < 5 {
    return Err(
      @types.ChoirError::validation_error(
        "spec-link requires <issue-id> <feature-slug>",
      ),
    )
  }
  let issue_id = args[3]
  let feature_slug = args[4]
  let mut force = false
  let mut i = 5
  while i < args.length() {
    match args[i] {
      "--force" => {
        force = true
        i = i + 1
      }
      other =>
        return Err(
          @types.ChoirError::validation_error(
            "unknown beads spec-link flag: " + other,
          ),
        )
    }
  }
  Ok({ issue_id, feature_slug, force })
}

///|
pub fn parse_beads_cli_args(
  args : Array[String],
) -> Result[BeadsCliRequest, @types.ChoirError] {
  if args.length() < 3 {
    return Ok(BeadsCliRequest::Help)
  }
  match args[2] {
    "--help" | "-h" | "help" => Ok(BeadsCliRequest::Help)
    "wave-from" => parse_beads_wave_from_args(args).map(fn(a) { WaveFrom(a) })
    "gate" => parse_beads_gate_args(args).map(fn(a) { Gate(a) })
    "merge-slot" =>
      if args.length() == 4 {
        match args[3] {
          "check" | "create" | "acquire" | "release" =>
            Ok(BeadsCliRequest::MergeSlot(args[3]))
          other =>
            Err(
              @types.ChoirError::validation_error(
                "unknown merge-slot action: " + other,
              ),
            )
        }
      } else {
        Err(
          @types.ChoirError::validation_error(
            "merge-slot requires <check|create|acquire|release>",
          ),
        )
      }
    "spec-link" => parse_beads_spec_link_args(args).map(fn(a) { SpecLink(a) })
    "doctor" => Ok(BeadsCliRequest::Doctor)
    other =>
      Err(
        @types.ChoirError::validation_error("unknown beads command: " + other),
      )
  }
}

///|
fn string_array_json(values : Array[String]) -> Json {
  let items : Array[Json] = []
  for value in values {
    items.push(value.to_json())
  }
  items.to_json()
}

///|
pub fn render_beads_wave_from_plan(
  plan : @tools.BeadsWaveFromIssuesPlan,
) -> String {
  {
    "fork_wave": plan.fork_wave_args.to_json(),
    "issue_ids": string_array_json(plan.issue_ids),
    "warnings": string_array_json(plan.warnings),
  }
  .to_json()
  .stringify() +
  "\n"
}

///|
fn choir_tool_fork_wave_command(
  choir_exe : String,
  project_dir : String,
  fork_wave_args : Map[String, Json],
) -> @workspace.Command {
  {
    program: choir_exe,
    args: [
      "tool",
      "fork_wave",
      "--caller-role",
      "tl",
      "--json",
      fork_wave_args.to_json().stringify(),
    ],
    workdir: Some(project_dir),
  }
}

///|
pub async fn run_beads_wave_from(
  args : BeadsWaveFromCliArgs,
  project_dir : String,
  choir_exe : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (ready_code, ready_json) = capture(
    @tools.beads_ready_children_command(args.parent_id, project_dir),
  )
  if ready_code != 0 {
    return Err(
      @types.ChoirError::transport_error(
        "bd ready failed: " + ready_json.trim().to_owned(),
      ),
    )
  }
  let issues = match @tools.parse_beads_issues_json(ready_json) {
    Ok(items) => items
    Err(e) => return Err(e)
  }
  let plan = match
    @tools.build_beads_wave_from_issues_plan(
      args.parent_id,
      args.caller_id,
      args.parent_branch,
      args.slug_prefix,
      issues,
    ) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  if !args.execute {
    return Ok(render_beads_wave_from_plan(plan))
  }
  let (code, output) = capture(
    choir_tool_fork_wave_command(choir_exe, project_dir, plan.fork_wave_args),
  )
  if code != 0 {
    Err(
      @types.ChoirError::transport_error(
        "choir tool fork_wave failed: " + output.trim().to_owned(),
      ),
    )
  } else {
    Ok(output)
  }
}

///|
fn spec_link_command(
  project_dir : String,
  args : BeadsSpecLinkCliArgs,
) -> @workspace.Command {
  let path = spec_link_spec_path(args)
  {
    program: "bd",
    args: [
      "update",
      args.issue_id,
      "--spec-id",
      path,
      "--append-notes",
      "Choir spec: " + path,
    ],
    workdir: Some(project_dir),
  }
}

///|
fn spec_link_spec_path(args : BeadsSpecLinkCliArgs) -> String {
  ".choir/context/" + args.feature_slug + "-spec.md"
}

///|
fn project_relative_path(project_dir : String, rel_path : String) -> String {
  if project_dir == "" || project_dir == "." {
    rel_path
  } else if project_dir.has_suffix("/") {
    project_dir + rel_path
  } else {
    project_dir + "/" + rel_path
  }
}

///|
pub async fn run_beads_spec_link(
  project_dir : String,
  args : BeadsSpecLinkCliArgs,
  capture : async (@workspace.Command) -> (Int, String),
  path_entry_exists? : (String) -> Bool = fn(path) {
    @sys.path_entry_exists(path)
  },
  path_readable? : (String) -> Bool = fn(path) { @sys.path_exists(path) },
  read_file? : (String) -> String = fn(path) { @sys.read_file(path) },
) -> Result[String, @types.ChoirError] {
  let path = spec_link_spec_path(args)
  if !args.force {
    let full_path = project_relative_path(project_dir, path)
    if !path_entry_exists(full_path) {
      return Err(
        @types.ChoirError::validation_error(
          "spec file " +
          path +
          " does not exist; refuse to link without --force",
        ),
      )
    }
    if !path_readable(full_path) {
      return Err(
        @types.ChoirError::validation_error(
          "spec file " + path + " exists but is unreadable; check permissions",
        ),
      )
    }
    if read_file(full_path) == "" {
      return Err(
        @types.ChoirError::validation_error(
          "spec file " +
          path +
          " exists but is empty; refuse to link without --force (typically means the spec was scaffolded but not yet written)",
        ),
      )
    }
  }
  run_passthrough(spec_link_command(project_dir, args), capture)
}

///|
async fn run_passthrough(
  cmd : @workspace.Command,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (code, output) = capture(cmd)
  if code == 0 {
    Ok(output)
  } else {
    Err(
      @types.ChoirError::transport_error(
        cmd.to_string() + " failed: " + output.trim().to_owned(),
      ),
    )
  }
}

///|
fn beads_git_status_path(line : String) -> String {
  if line.length() <= 3 {
    ""
  } else {
    let path = line[3:].trim().to_owned()
    match path.split_once(" -> ") {
      Some((_from, to)) => to.to_owned()
      None => path
    }
  }
}

///|
pub(all) struct BeadsDoctorReport {
  ready_count : Int
  in_progress_count : Int
  beads_export_dirty : Bool
  unrelated_dirty_paths : Array[String]
  stalled_beads : Array[StalledBead]
} derive(Debug, Eq)

///|
pub(all) struct BeadsDoctorIssueSnapshot {
  id : String
  status : String
  assignee : String
  started_at : String
} derive(Debug, Eq)

///|
pub(all) struct StalledBead {
  id : String
  assignee : String
  age_hours : Int64
} derive(Debug, Eq)

///|
let stalled_bead_threshold_hours : Int = 4

///|
let seconds_per_hour : Int64 = 3600L

///|
pub fn build_beads_doctor_report(
  ready_json : String,
  in_progress_json : String,
  git_status : String,
  active_agent_ids? : Array[String]? = None,
  now_sec? : Int64 = @env.now().reinterpret_as_int64() / 1000L,
  stalled_threshold_hours? : Int = stalled_bead_threshold_hours,
) -> Result[BeadsDoctorReport, @types.ChoirError] {
  let ready = match parse_beads_doctor_issues("bd ready --json", ready_json) {
    Ok(items) => items
    Err(e) => return Err(e)
  }
  let in_progress = match
    parse_beads_doctor_issues(
      "bd list --json --status in_progress", in_progress_json,
    ) {
    Ok(items) => items
    Err(e) => return Err(e)
  }
  let in_progress_snapshots = match
    parse_beads_doctor_issue_snapshots(
      "bd list --json --status in_progress", in_progress_json,
    ) {
    Ok(items) => items
    Err(e) => return Err(e)
  }
  let unrelated : Array[String] = []
  let mut export_dirty = false
  for line in git_status.split("\n") {
    let path = beads_git_status_path(line.to_owned())
    if path == "" {
      continue
    }
    if path == ".beads/issues.jsonl" {
      export_dirty = true
    } else {
      unrelated.push(path)
    }
  }
  let stalled_beads = detect_stalled_beads(
    in_progress_snapshots, active_agent_ids, now_sec, stalled_threshold_hours,
  )
  Ok({
    ready_count: ready.length(),
    in_progress_count: in_progress.length(),
    beads_export_dirty: export_dirty,
    unrelated_dirty_paths: unrelated,
    stalled_beads,
  })
}

///|
fn beads_json_payload_from_output(output : String) -> String {
  let direct = output.trim().to_owned()
  if beads_json_payload_parses(direct) {
    return direct
  }
  let mut offset = 0
  for raw in output.split("\n") {
    let line = raw.to_owned()
    match beads_json_line_payload_offset(line) {
      Some(line_offset) => {
        let start = offset + line_offset
        match beads_json_payload_end(output, start) {
          Some(end) => {
            let payload = output[start:end].trim().to_owned()
            if beads_json_payload_parses(payload) {
              return payload
            }
          }
          None => ()
        }
      }
      None => ()
    }
    offset = offset + line.length() + 1
  }
  direct
}

///|
fn beads_json_payload_parses(payload : String) -> Bool {
  ignore(@json.parse(payload) catch { _ => return false })
  true
}

///|
fn beads_json_line_payload_offset(line : String) -> Int? {
  let mut i = 0
  while i < line.length() &&
        (line[i] == ' ' || line[i] == '\t' || line[i] == '\r') {
    i = i + 1
  }
  if i < line.length() && (line[i] == '[' || line[i] == '{') {
    Some(i)
  } else {
    None
  }
}

///|
fn beads_json_payload_end(output : String, start : Int) -> Int? {
  let mut i = start
  let mut depth = 0
  let mut in_string = false
  let mut escaped = false
  while i < output.length() {
    let c = output[i]
    if in_string {
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        in_string = false
      }
    } else {
      match c {
        '"' => in_string = true
        '[' | '{' => depth = depth + 1
        ']' | '}' => {
          depth = depth - 1
          if depth == 0 {
            return Some(i + 1)
          }
          if depth < 0 {
            return None
          }
        }
        _ => ()
      }
    }
    i = i + 1
  }
  None
}

///|
fn parse_beads_doctor_issues(
  source : String,
  output : String,
) -> Result[Array[@tools.BeadsIssue], @types.ChoirError] {
  let payload = beads_json_payload_from_output(output)
  match @tools.parse_beads_issues_json(payload) {
    Ok(items) => Ok(items)
    Err(_) =>
      Err(
        @types.ChoirError::validation_error(
          "invalid beads json from " +
          source +
          "; raw output: " +
          output.trim().to_owned(),
        ),
      )
  }
}

///|
fn parse_beads_doctor_issue_snapshot(
  fields : Map[String, Json],
) -> Result[BeadsDoctorIssueSnapshot, @types.ChoirError] {
  let id = @types.json_field_string(fields, "id").unwrap_or("")
  if id == "" {
    return Err(@types.ChoirError::validation_error("beads issue missing id"))
  }
  Ok({
    id,
    status: @types.json_field_string(fields, "status").unwrap_or(""),
    assignee: @types.json_field_string(fields, "assignee").unwrap_or(""),
    started_at: @types.json_field_string(fields, "started_at").unwrap_or(""),
  })
}

///|
fn parse_beads_doctor_issue_snapshots(
  source : String,
  output : String,
) -> Result[Array[BeadsDoctorIssueSnapshot], @types.ChoirError] {
  let payload = beads_json_payload_from_output(output)
  let json = @json.parse(payload) catch {
    _ =>
      return Err(
        @types.ChoirError::validation_error(
          "invalid beads json from " +
          source +
          "; raw output: " +
          output.trim().to_owned(),
        ),
      )
  }
  match json {
    Array(items) => {
      let out : Array[BeadsDoctorIssueSnapshot] = []
      for item in items {
        match item {
          Object(fields) =>
            match parse_beads_doctor_issue_snapshot(fields) {
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
      match parse_beads_doctor_issue_snapshot(fields) {
        Ok(issue) => Ok([issue])
        Err(e) => Err(e)
      }
    _ => Err(@types.ChoirError::validation_error("invalid beads json"))
  }
}

///|
fn parse_beads_started_at_utc_sec(value : String) -> Int64? {
  Some(@tempo.DateTime::parse(value).to_unix_seconds()) catch {
    _ => None
  }
}

///|
fn detect_stalled_beads(
  issues : Array[BeadsDoctorIssueSnapshot],
  active_agent_ids : Array[String]?,
  now_sec : Int64,
  threshold_hours : Int,
) -> Array[StalledBead] {
  let stalled : Array[StalledBead] = []
  let active_ids = match active_agent_ids {
    Some(ids) => ids
    None => return stalled
  }
  let threshold_sec = threshold_hours.to_int64() * seconds_per_hour
  for issue in issues {
    let assignee = issue.assignee.trim().to_owned()
    if issue.status != "in_progress" || assignee == "" {
      continue
    }
    if active_ids.contains(assignee) {
      continue
    }
    let started_sec = match parse_beads_started_at_utc_sec(issue.started_at) {
      Some(sec) => sec
      None => continue
    }
    let age_sec = now_sec - started_sec
    if age_sec > threshold_sec {
      stalled.push({
        id: issue.id,
        assignee,
        age_hours: age_sec / seconds_per_hour,
      })
    }
  }
  stalled
}

///|
fn active_agent_ids_from_lifecycle(
  project_dir : String,
  in_progress_json : String,
  kv_exists? : (String) -> Bool = fn(path) { @sys.path_entry_exists(path) },
  read_lifecycle? : (String, String) -> @phase.AgentLifecycle? = fn(dir, id) {
    @phase.read_lifecycle(dir, id)
  },
) -> Array[String]? {
  if !kv_exists(project_relative_path(project_dir, ".choir/kv")) {
    return None
  }
  let issues = match
    parse_beads_doctor_issue_snapshots(
      "bd list --json --status in_progress", in_progress_json,
    ) {
    Ok(items) => items
    Err(_) => return None
  }
  let ids : Array[String] = []
  for issue in issues {
    let assignee = issue.assignee.trim().to_owned()
    if assignee == "" || ids.contains(assignee) {
      continue
    }
    match read_lifecycle(project_dir, assignee) {
      Some(lifecycle) =>
        if lifecycle.to_agent_state() == @types.AgentState::Active {
          ids.push(assignee)
        }
      None => ()
    }
  }
  Some(ids)
}

///|
fn default_active_agent_ids_from_lifecycle(
  project_dir : String,
  in_progress_json : String,
) -> Array[String]? {
  active_agent_ids_from_lifecycle(project_dir, in_progress_json)
}

///|
fn render_recovery_hint(out : StringBuilder, hint : String) -> Unit {
  out.write_string("  ↳ " + hint + "\n")
}

///|
pub fn render_beads_doctor_report(report : BeadsDoctorReport) -> String {
  let out = StringBuilder::new()
  out.write_string("ready_count: " + report.ready_count.to_string() + "\n")
  if report.ready_count > 0 {
    render_recovery_hint(out, "run `bd ready` to inspect dispatchable beads")
  }
  out.write_string(
    "in_progress_count: " + report.in_progress_count.to_string() + "\n",
  )
  if report.in_progress_count > 0 {
    render_recovery_hint(
      out, "check assigned leaves are still active in the registry",
    )
  }
  out.write_string(
    "beads_export_dirty: " +
    (if report.beads_export_dirty { "true" } else { "false" }) +
    "\n",
  )
  if report.beads_export_dirty {
    render_recovery_hint(
      out, "run `bd dolt commit -am \"sync issues\"` to commit bd state",
    )
  }
  if report.unrelated_dirty_paths.length() == 0 {
    out.write_string("unrelated_dirty_paths: <none>\n")
  } else {
    out.write_string("unrelated_dirty_paths:\n")
    for path in report.unrelated_dirty_paths {
      out.write_string("- " + path + "\n")
    }
    render_recovery_hint(
      out, "commit or stash these before continuing wave work",
    )
  }
  for bead in report.stalled_beads {
    out.write_string(
      "STALLED: " +
      bead.id +
      " (started " +
      bead.age_hours.to_string() +
      "h ago, assignee " +
      bead.assignee +
      " not in registry)\n",
    )
    out.write_string(
      "  → bd update " + bead.id + " --status open --assignee \"\"\n",
    )
  }
  out.to_string()
}

///|
pub async fn run_beads_doctor(
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
  now_sec? : Int64 = @env.now().reinterpret_as_int64() / 1000L,
  active_agent_ids? : (String, String) -> Array[String]? = default_active_agent_ids_from_lifecycle,
) -> Result[String, @types.ChoirError] {
  let (ready_code, ready_json) = capture({
    program: "bd",
    args: ["ready", "--json", "--limit", "0"],
    workdir: Some(project_dir),
  })
  if ready_code != 0 {
    return Err(@types.ChoirError::transport_error("bd ready failed"))
  }
  let (progress_code, progress_json) = capture({
    program: "bd",
    args: ["list", "--json", "--status", "in_progress", "--limit", "0"],
    workdir: Some(project_dir),
  })
  if progress_code != 0 {
    return Err(@types.ChoirError::transport_error("bd list failed"))
  }
  let (status_code, status) = capture({
    program: "git",
    args: ["status", "--short"],
    workdir: Some(project_dir),
  })
  if status_code != 0 {
    return Err(@types.ChoirError::git_error("git status failed"))
  }
  let active_agent_ids = active_agent_ids(project_dir, progress_json)
  match
    build_beads_doctor_report(
      ready_json,
      progress_json,
      status,
      active_agent_ids~,
      now_sec~,
    ) {
    Ok(report) => Ok(render_beads_doctor_report(report))
    Err(e) => Err(e)
  }
}

///|
pub async fn run_beads_cli_request(
  request : BeadsCliRequest,
  project_dir : String,
  choir_exe : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  match request {
    BeadsCliRequest::Help => Ok(beads_help())
    BeadsCliRequest::WaveFrom(args) =>
      run_beads_wave_from(args, project_dir, choir_exe, capture)
    BeadsCliRequest::Gate(args) =>
      run_passthrough(
        @tools.beads_gate_create_command(
          project_dir,
          args.issue_id,
          args.gate_type,
          args.reason,
          args.await_id,
        ),
        capture,
      )
    BeadsCliRequest::MergeSlot(action) =>
      run_passthrough(
        @tools.beads_merge_slot_command(project_dir, action),
        capture,
      )
    BeadsCliRequest::SpecLink(args) =>
      run_beads_spec_link(project_dir, args, capture)
    BeadsCliRequest::Doctor => run_beads_doctor(project_dir, capture)
  }
}

///|
pub fn beads_subcommand_run() -> Unit {
  let parsed = match parse_beads_cli_args(@env.args()) {
    Ok(req) => req
    Err(e) => {
      @sys.write_stderr("choir beads: " + e.message() + "\n")
      @sys.write_stderr(beads_help())
      @sys.exit(1)
      return
    }
  }
  let argv = @env.args()
  let choir_exe = if argv.length() > 0 { argv[0] } else { "choir" }
  @async.run_async_main(async fn() {
    @async.with_task_group(async fn(_root) {
      // All bd dispatches use stdout-only capture on success so JSON parsers see
      // clean payloads, while failing commands still include stderr context.
      // Doctor used this first; choir-dxh consolidated bd commands because each
      // emits success JSON and benefits from stderr-on-failure diagnostics.
      let result = run_beads_cli_request(
        parsed, ".", choir_exe, @exec.capture_command_stdout_with_stderr_on_error,
      )
      match result {
        Ok(output) => @sys.write_stdout(output)
        Err(e) => {
          @sys.write_stderr("choir beads: " + e.message() + "\n")
          @sys.exit(1)
        }
      }
    })
  })
}

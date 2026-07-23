///|
priv enum ConductorStatusPhase {
  Queued
  Implement
  Verify
  Audit
  Integrate
  Assure
  Publish
  PullRequest
}

///|
fn ConductorStatusPhase::label(self : ConductorStatusPhase) -> String {
  match self {
    Queued => "queued"
    Implement => "impl"
    Verify => "verify"
    Audit => "audit"
    Integrate => "integrate"
    Assure => "assure"
    Publish => "publish"
    PullRequest => "file PR"
  }
}

///|
priv enum ConductorStatusAttention {
  NeedsInput
  RecoveryUncertain
  Blocked
  Paused
  Canceling
}

///|
fn ConductorStatusAttention::label(self : ConductorStatusAttention) -> String {
  match self {
    NeedsInput => "NEEDS INPUT"
    RecoveryUncertain => "RECOVERY UNCERTAIN"
    Blocked => "BLOCKED"
    Paused => "PAUSED"
    Canceling => "CANCELING"
  }
}

///|
priv struct ConductorGoalDisplay {
  maximum_parallel_parts : Int
  total_parts : Int
  integrated_parts : Int
  implementation_parts : Int
  verification_parts : Int
  audit_parts : Int
  integration_parts : Int
  single_part_id : String?
  phase : ConductorStatusPhase
  attention : ConductorStatusAttention?
  attention_target : String?
  additional_attention : Int
}

///|
fn conductor_statusline_json_tag(value : Json?) -> String {
  match value {
    Some(String(tag)) => tag
    Some(Array(values)) if values.length() > 0 =>
      match values[0] {
        String(tag) => tag
        _ => ""
      }
    _ => ""
  }
}

///|
fn conductor_statusline_identity(value : Json?) -> String? {
  match value {
    Some(String(identity)) if identity != "" => Some(identity)
    Some(Array(values)) if values.length() >= 2 =>
      match values[1] {
        String(identity) if identity != "" => Some(identity)
        _ => None
      }
    _ => None
  }
}

///|
fn conductor_statusline_input_request(
  fields : Map[String, Json],
) -> (Bool, String?) {
  guard fields.get("active_input_request") is Some(Object(request)) else {
    return (false, None)
  }
  let target = match conductor_statusline_json_tag(request.get("reason")) {
    "GoalInputPublicationRemoteUnavailable" => Some("publish")
    "GoalInputFinalizationNeedsUserInput"
    | "GoalInputFinalizationDrifted"
    | "GoalInputFinalizationAmbiguous" => Some("file PR")
    _ => None
  }
  (true, target)
}

///|
fn conductor_statusline_recovery_target(
  fields : Map[String, Json],
  part_target : String?,
) -> String? {
  match part_target {
    Some(_) => part_target
    None =>
      match conductor_statusline_json_tag(fields.get("publication_state")) {
        "BranchPublicationPreflightUncertain"
        | "BranchPublicationMutationUncertain" => Some("publish")
        _ =>
          match conductor_statusline_json_tag(fields.get("assurance_stage")) {
            "GoalAssuranceRecoveryUncertain" => Some("assure")
            _ =>
              match
                conductor_statusline_json_tag(fields.get("pull_request_state")) {
                "PullRequestRemoteCreateUncertain" => Some("file PR")
                _ => None
              }
          }
      }
  }
}

///|
fn conductor_statusline_goal_display(report : Json) -> ConductorGoalDisplay? {
  guard report is Object(fields) else { return None }
  let state = conductor_statusline_json_tag(fields.get("state"))
  if state == "GoalExecutionSucceeded" || state == "GoalExecutionCanceled" {
    return None
  }
  let maximum_parallel_parts = match fields.get("maximum_parallel_parts") {
    Some(Number(value, ..)) if value.to_int() > 0 => value.to_int()
    _ => 1
  }
  let parts = match fields.get("parts") {
    Some(Array(values)) => values
    _ => []
  }
  let mut integrated = 0
  let mut implementation = 0
  let mut verification = 0
  let mut audit = 0
  let mut integration = 0
  let mut single_part_id : String? = None
  let mut recovery_target : String? = None
  let mut blocked_target : String? = None
  let mut recovery_count = 0
  let mut blocked_count = 0
  for part in parts {
    guard part is Object(part_fields) else { continue }
    let part_id = conductor_statusline_identity(part_fields.get("part_id"))
    if parts.length() == 1 {
      single_part_id = part_id
    }
    match conductor_statusline_json_tag(part_fields.get("stage")) {
      "PartImplementationSandboxPrepared"
      | "PartImplementationCommandPrepared"
      | "PartImplementationHarnessStarted"
      | "PartImplementationCompleted" => implementation = implementation + 1
      "PartCandidateRecorded" | "PartVerificationSandboxPrepared" =>
        verification = verification + 1
      "PartVerified"
      | "PartAuditSandboxPrepared"
      | "PartAuditCommandPrepared"
      | "PartAuditHarnessStarted"
      | "PartAuditResultRecorded" => audit = audit + 1
      "PartAudited"
      | "PartIntegrationPlanned"
      | "PartPromotionPrepared"
      | "PartIntegrationAuthorized" => integration = integration + 1
      "PartIntegrated" => integrated = integrated + 1
      "PartRecoveryUncertain" => {
        recovery_count = recovery_count + 1
        if recovery_target is None {
          recovery_target = part_id
        }
      }
      "PartBlocked" => {
        blocked_count = blocked_count + 1
        if blocked_target is None {
          blocked_target = part_id
        }
      }
      _ => ()
    }
  }
  let (has_input, input_target) = conductor_statusline_input_request(fields)
  let part_attention_count = recovery_count + blocked_count
  let (attention, attention_target, additional_attention) = if has_input {
    (Some(NeedsInput), input_target, part_attention_count)
  } else if recovery_count > 0 {
    (
      Some(RecoveryUncertain),
      conductor_statusline_recovery_target(fields, recovery_target),
      part_attention_count - 1,
    )
  } else if state == "GoalExecutionPaused" &&
    conductor_statusline_json_tag(fields.get("pause_reason")) ==
    "GoalPauseRecoveryUncertain" {
    (
      Some(RecoveryUncertain),
      conductor_statusline_recovery_target(fields, None),
      blocked_count,
    )
  } else if blocked_count > 0 || state == "GoalExecutionBlocked" {
    (
      Some(Blocked),
      blocked_target,
      if blocked_count > 0 {
        blocked_count - 1
      } else {
        0
      },
    )
  } else if state == "GoalExecutionPaused" {
    (Some(Paused), None, 0)
  } else if state == "GoalExecutionCanceling" {
    (Some(Canceling), None, 0)
  } else {
    (None, None, 0)
  }
  let phase = match state {
    "GoalExecutionAssuring" => Assure
    "GoalExecutionAssured" =>
      if conductor_statusline_json_tag(fields.get("publication_state")) ==
        "BranchPublicationReceipted" {
        PullRequest
      } else {
        Publish
      }
    "GoalExecutionRunning" if parts.length() > 0 && integrated == parts.length() =>
      Assure
    _ => Queued
  }
  Some({
    maximum_parallel_parts,
    total_parts: parts.length(),
    integrated_parts: integrated,
    implementation_parts: implementation,
    verification_parts: verification,
    audit_parts: audit,
    integration_parts: integration,
    single_part_id,
    phase,
    attention,
    attention_target,
    additional_attention,
  })
}

///|
fn conductor_statusline_active_phase(display : ConductorGoalDisplay) -> String {
  if display.integration_parts > 0 {
    Integrate.label()
  } else if display.audit_parts > 0 {
    Audit.label()
  } else if display.verification_parts > 0 {
    Verify.label()
  } else if display.implementation_parts > 0 {
    Implement.label()
  } else {
    display.phase.label()
  }
}

///|
fn conductor_statusline_goal_segment(report : Json) -> String {
  let display = match conductor_statusline_goal_display(report) {
    Some(value) => value
    None => return ""
  }
  match display.attention {
    Some(attention) => {
      let label = attention.label()
      let additional = if display.additional_attention > 0 {
        " (+" + display.additional_attention.to_string() + ")"
      } else {
        ""
      }
      match
        (display.total_parts, display.single_part_id, display.attention_target) {
        (1, Some(part_id), Some(target)) if part_id == target =>
          part_id + ": " + label + additional
        (1, Some(part_id), None) => part_id + ": " + label + additional
        _ => {
          let target = match display.attention_target {
            Some(value) => ": " + value
            None => ""
          }
          let progress = if display.total_parts > 1 {
            " · " +
            display.integrated_parts.to_string() +
            "/" +
            display.total_parts.to_string() +
            " done"
          } else {
            ""
          }
          "Choir " + label + target + additional + progress
        }
      }
    }
    None =>
      match (display.total_parts, display.single_part_id) {
        (1, Some(part_id)) =>
          part_id + ": " + conductor_statusline_active_phase(display)
        _ => {
          let segments : Array[String] = [
            display.integrated_parts.to_string() +
            "/" +
            display.total_parts.to_string() +
            " done",
          ]
          for
            pair in [
              (display.implementation_parts, Implement),
              (display.verification_parts, Verify),
              (display.audit_parts, Audit),
              (display.integration_parts, Integrate),
            ] {
            let (count, phase) = pair
            if count > 0 {
              segments.push(count.to_string() + " " + phase.label())
            }
          }
          if segments.length() == 1 {
            segments.push(display.phase.label())
          }
          if display.maximum_parallel_parts > 1 &&
            display.integrated_parts < display.total_parts {
            segments.push("cap " + display.maximum_parallel_parts.to_string())
          }
          "Choir " + segments.join(" · ")
        }
      }
  }
}

///|
fn conductor_statusline_cache_key_valid(key : String) -> Bool {
  if key.length() == 0 || key.length() > 96 {
    return false
  }
  for index = 0; index < key.length(); index = index + 1 {
    let unit = key.code_unit_at(index)
    if !((unit >= 'a' && unit <= 'z') ||
      (unit >= 'A' && unit <= 'Z') ||
      (unit >= '0' && unit <= '9') ||
      unit == '-' ||
      unit == '_') {
      return false
    }
  }
  true
}

///|
fn conductor_statusline_cache_root(project_dir : String) -> String {
  project_dir + "/.choir/state/conductor-statusline"
}

///|
fn conductor_statusline_active_cache_path(project_dir : String) -> String {
  conductor_statusline_cache_root(project_dir) + "/active"
}

///|
fn conductor_statusline_cache_path(
  project_dir : String,
  key : String,
) -> String? {
  if conductor_statusline_cache_key_valid(key) {
    Some(conductor_statusline_cache_root(project_dir) + "/" + key + ".json")
  } else {
    None
  }
}

///|
fn conductor_statusline_cache_content(report : Json?) -> String {
  match report {
    Some(value) if conductor_statusline_goal_display(value) is Some(_) =>
      conductor_goal_update_fingerprint(value) + "\n"
    _ => ""
  }
}

///|
fn conductor_statusline_activate_cache(
  project_dir : String,
  key : String,
  report : Json?,
) -> Unit {
  let cache_path = match conductor_statusline_cache_path(project_dir, key) {
    Some(value) => value
    None => return
  }
  let root = conductor_statusline_cache_root(project_dir)
  if !@sys.create_dir_all(root) {
    return
  }
  let active_path = conductor_statusline_active_cache_path(project_dir)
  let prior_key = @sys.read_file(active_path).trim().to_owned()
  if prior_key != key && conductor_statusline_cache_key_valid(prior_key) {
    match conductor_statusline_cache_path(project_dir, prior_key) {
      Some(path) => ignore(@sys.delete_file_sync(path))
      None => ()
    }
  }
  if !@sys.write_file_atomic(
      cache_path,
      conductor_statusline_cache_content(report),
    ) {
    return
  }
  ignore(@sys.write_file_atomic(active_path, key + "\n"))
}

///|
fn conductor_statusline_deactivate_cache(project_dir : String) -> Unit {
  let root = conductor_statusline_cache_root(project_dir)
  if !@sys.create_dir_all(root) {
    return
  }
  let active_path = conductor_statusline_active_cache_path(project_dir)
  let prior_key = @sys.read_file(active_path).trim().to_owned()
  if conductor_statusline_cache_key_valid(prior_key) {
    match conductor_statusline_cache_path(project_dir, prior_key) {
      Some(path) => ignore(@sys.delete_file_sync(path))
      None => ()
    }
  }
  ignore(@sys.write_file_atomic(active_path, ""))
}

///|
fn conductor_statusline_update_cache(
  project_dir : String,
  key : String,
  report : Json,
) -> Unit {
  match conductor_statusline_cache_path(project_dir, key) {
    Some(path) =>
      ignore(
        @sys.write_file_atomic(
          path,
          conductor_statusline_cache_content(Some(report)),
        ),
      )
    None => ()
  }
}

///|
fn conductor_statusline_cached_report(
  project_dir : String,
  key : String,
  read_file : (String) -> String,
) -> Json? {
  let path = match conductor_statusline_cache_path(project_dir, key) {
    Some(value) => value
    None => return None
  }
  if read_file(conductor_statusline_active_cache_path(project_dir)).trim() !=
    key {
    return None
  }
  let raw = read_file(path).trim().to_owned()
  if raw == "" {
    return None
  }
  Some(@json.parse(raw)) catch {
    _ => None
  }
}

///|
fn conductor_statusline_json_object(
  fields : Map[String, Json],
  name : String,
) -> Map[String, Json] {
  match fields.get(name) {
    Some(Object(value)) => value
    _ => Map([])
  }
}

///|
fn conductor_statusline_json_string(
  fields : Map[String, Json],
  name : String,
) -> String {
  match fields.get(name) {
    Some(String(value)) => value.trim().to_owned()
    _ => ""
  }
}

///|
fn conductor_statusline_percentage(
  fields : Map[String, Json],
  name : String,
) -> Int? {
  match fields.get(name) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
fn conductor_statusline_git_branch(
  project_dir : String,
  read_file : (String) -> String,
) -> String {
  let git_path = project_dir + "/.git"
  let pointer = read_file(git_path)
  let head_path = if pointer.has_prefix("gitdir: ") {
    let git_dir = pointer.trim().to_owned()[8:].to_owned()
    if git_dir.has_prefix("/") {
      git_dir + "/HEAD"
    } else {
      project_dir + "/" + git_dir + "/HEAD"
    }
  } else {
    git_path + "/HEAD"
  }
  let head = read_file(head_path).trim().to_owned()
  if head.has_prefix("ref: refs/heads/") {
    head[16:].to_owned()
  } else if head.length() >= 7 {
    head[0:7].to_owned()
  } else {
    head
  }
}

///|
fn conductor_statusline_render(
  input : String,
  branch : String,
  report : Json?,
) -> String {
  let parsed = @json.parse(input) catch { _ => return "" }
  guard parsed is Object(root) else { return "" }
  let session : Array[String] = []
  let model = conductor_statusline_json_string(
    conductor_statusline_json_object(root, "model"),
    "display_name",
  )
  if model != "" {
    session.push(model)
  }
  for
    pair in [
      (
        "ctx ",
        conductor_statusline_percentage(
          conductor_statusline_json_object(root, "context_window"),
          "used_percentage",
        ),
      ),
      (
        "5h ",
        conductor_statusline_percentage(
          conductor_statusline_json_object(
            conductor_statusline_json_object(root, "rate_limits"),
            "five_hour",
          ),
          "used_percentage",
        ),
      ),
      (
        "7d ",
        conductor_statusline_percentage(
          conductor_statusline_json_object(
            conductor_statusline_json_object(root, "rate_limits"),
            "seven_day",
          ),
          "used_percentage",
        ),
      ),
    ] {
    let (prefix, percentage) = pair
    match percentage {
      Some(value) => session.push(prefix + value.to_string() + "%")
      None => ()
    }
  }
  let groups : Array[String] = []
  if session.length() > 0 {
    groups.push(session.join(" · "))
  }
  if branch != "" {
    groups.push(branch)
  }
  match report {
    Some(value) => {
      let goal = conductor_statusline_goal_segment(value)
      if goal != "" {
        groups.push(goal)
      }
    }
    None => ()
  }
  groups.join(" │ ")
}

///|
fn conductor_statusline_read_all_stdin() -> String {
  let input = StringBuilder::new()
  for ;; {
    match @sys.read_stdin_line(262144) {
      Some(line) => {
        input.write_string(line)
        input.write_string("\n")
      }
      None => break
    }
  }
  input.to_string()
}

///|
fn conductor_statusline_run() -> Unit {
  let input = conductor_statusline_read_all_stdin()
  let project_dir = match @sys.getenv("CHOIR_WORKSPACE") {
    Some(value) if value.trim() != "" => value.trim().to_owned()
    _ => "."
  }
  let report = match @sys.getenv("CHOIR_STATUSLINE_CACHE_KEY") {
    Some(key) =>
      conductor_statusline_cached_report(
        project_dir,
        key.trim().to_owned(),
        @sys.read_file,
      )
    None => None
  }
  let rendered = conductor_statusline_render(
    input,
    conductor_statusline_git_branch(project_dir, @sys.read_file),
    report,
  )
  if rendered != "" {
    @sys.write_stdout(rendered)
  }
}

///|
fn conductor_statusline_test_part(id : String, stage : String) -> Json {
  { "part_id": ["PartId", id].to_json(), "stage": stage.to_json() }.to_json()
}

///|
fn conductor_statusline_test_report(
  state : String,
  maximum_parallel_parts : Int,
  parts : Array[Json],
) -> Json {
  {
    "state": state.to_json(),
    "maximum_parallel_parts": maximum_parallel_parts.to_json(),
    "parts": parts.to_json(),
  }.to_json()
}

///|
test "Conductor statusline renders single and parallel Part progress" {
  let single = conductor_statusline_test_report("GoalExecutionRunning", 1, [
    conductor_statusline_test_part(
      "choir-hdg", "PartVerificationSandboxPrepared",
    ),
  ])
  assert_eq(conductor_statusline_goal_segment(single), "choir-hdg: verify")
  let parallel = conductor_statusline_test_report("GoalExecutionRunning", 4, [
    conductor_statusline_test_part(
      "choir-a", "PartImplementationHarnessStarted",
    ),
    conductor_statusline_test_part("choir-b", "PartVerificationSandboxPrepared"),
    conductor_statusline_test_part("choir-c", "PartAuditHarnessStarted"),
    conductor_statusline_test_part("choir-d", "PartIntegrated"),
    conductor_statusline_test_part("choir-e", "PartAccepted"),
  ])
  assert_eq(
    conductor_statusline_goal_segment(parallel),
    "Choir 1/5 done · 1 impl · 1 verify · 1 audit · cap 4",
  )
}

///|
test "Conductor statusline prioritizes exceptional parallel Parts" {
  let report = conductor_statusline_test_report("GoalExecutionBlocked", 4, [
    conductor_statusline_test_part("choir-a", "PartRecoveryUncertain"),
    conductor_statusline_test_part("choir-b", "PartBlocked"),
    conductor_statusline_test_part("choir-c", "PartIntegrated"),
    conductor_statusline_test_part("choir-d", "PartAccepted"),
  ])
  assert_eq(
    conductor_statusline_goal_segment(report),
    "Choir RECOVERY UNCERTAIN: choir-a (+1) · 1/4 done",
  )
}

///|
test "Conductor statusline names Goal-level input and assurance phases" {
  let awaiting_input = conductor_statusline_test_report(
    "GoalExecutionPaused",
    1,
    [conductor_statusline_test_part("choir-a", "PartIntegrated")],
  )
  guard awaiting_input is Object(input_fields) else {
    fail("expected report object")
  }
  input_fields.set(
    "active_input_request",
    { "reason": "GoalInputPublicationRemoteUnavailable".to_json() }.to_json(),
  )
  assert_eq(
    conductor_statusline_goal_segment(awaiting_input),
    "Choir NEEDS INPUT: publish",
  )
  let assuring = conductor_statusline_test_report("GoalExecutionAssuring", 2, [
    conductor_statusline_test_part("choir-a", "PartIntegrated"),
    conductor_statusline_test_part("choir-b", "PartIntegrated"),
  ])
  assert_eq(
    conductor_statusline_goal_segment(assuring),
    "Choir 2/2 done · assure",
  )
}

///|
test "Conductor statusline clears terminal Goals" {
  let succeeded = conductor_statusline_test_report(
    "GoalExecutionSucceeded",
    1,
    [conductor_statusline_test_part("choir-a", "PartIntegrated")],
  )
  assert_eq(conductor_statusline_goal_segment(succeeded), "")
  assert_eq(conductor_statusline_cache_content(Some(succeeded)), "")
}

///|
test "Conductor statusline isolates launch-specific caches" {
  let report = conductor_statusline_test_report("GoalExecutionRunning", 1, [
    conductor_statusline_test_part(
      "choir-a", "PartImplementationHarnessStarted",
    ),
  ])
  let project_dir = "/repo"
  let active_path = conductor_statusline_active_cache_path(project_dir)
  let cache_path = conductor_statusline_cache_path(project_dir, "conductor-2").unwrap()
  let read_file = fn(path) {
    if path == active_path {
      "conductor-2\n"
    } else if path == cache_path {
      conductor_statusline_cache_content(Some(report))
    } else {
      ""
    }
  }
  assert_true(
    conductor_statusline_cached_report(project_dir, "conductor-1", read_file)
    is None,
  )
  let cached = conductor_statusline_cached_report(
    project_dir, "conductor-2", read_file,
  )
  assert_true(cached is Some(_))
  assert_eq(
    cached.unwrap().stringify(indent=0),
    @json.parse(conductor_statusline_cache_content(Some(report))).stringify(
      indent=0,
    ),
  )
}

///|
test "Conductor statusline renders Claude context and branch compactly" {
  let input =
    #|{"model":{"display_name":"Opus 4.8"},"context_window":{"used_percentage":18},"rate_limits":{"five_hour":{"used_percentage":23},"seven_day":{"used_percentage":41}}}
  assert_eq(
    conductor_statusline_render(input, "main", None),
    "Opus 4.8 · ctx 18% · 5h 23% · 7d 41% │ main",
  )
  assert_eq(
    conductor_statusline_git_branch("/repo", fn(path) {
      if path == "/repo/.git" {
        "gitdir: /git/worktrees/feature\n"
      } else if path == "/git/worktrees/feature/HEAD" {
        "ref: refs/heads/feature/statusline\n"
      } else {
        ""
      }
    }),
    "feature/statusline",
  )
}

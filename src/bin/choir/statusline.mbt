///|
fn conductor_phase_label(phase : @workflow.ConductorGoalPhase) -> String {
  match phase {
    @workflow.ConductorGoalPhase::ConductorPhaseQueued => "queued"
    @workflow.ConductorGoalPhase::ConductorPhaseImplement => "impl"
    @workflow.ConductorGoalPhase::ConductorPhaseVerify => "verify"
    @workflow.ConductorGoalPhase::ConductorPhaseAudit => "audit"
    @workflow.ConductorGoalPhase::ConductorPhaseIntegrate => "integrate"
    @workflow.ConductorGoalPhase::ConductorPhaseAssure => "assure"
    @workflow.ConductorGoalPhase::ConductorPhasePublish => "publish"
    @workflow.ConductorGoalPhase::ConductorPhasePullRequest => "file PR"
    @workflow.ConductorGoalPhase::ConductorPhaseAwaitMerge => "await merge"
  }
}

///|
fn conductor_attention_label(
  attention : @workflow.ConductorGoalAttention,
) -> String {
  match attention {
    @workflow.ConductorGoalAttention::ConductorAttentionNeedsInput =>
      "NEEDS INPUT"
    @workflow.ConductorGoalAttention::ConductorAttentionRecoveryUncertain =>
      "RECOVERY UNCERTAIN"
    @workflow.ConductorGoalAttention::ConductorAttentionBlocked => "BLOCKED"
    @workflow.ConductorGoalAttention::ConductorAttentionPaused => "PAUSED"
    @workflow.ConductorGoalAttention::ConductorAttentionCanceling =>
      "CANCELING"
  }
}

///|
fn conductor_statusline_goal_display(
  report : Json,
) -> @workflow.ConductorGoalDisplay? {
  let typed : @workflow.GoalStatusReport = @json.from_json(report) catch {
    _ => return None
  }
  @workflow.conductor_goal_display(typed)
}

///|
fn conductor_statusline_active_phase(
  display : @workflow.ConductorGoalDisplay,
) -> String {
  if display.integration_parts > 0 {
    conductor_phase_label(@workflow.ConductorGoalPhase::ConductorPhaseIntegrate)
  } else if display.audit_parts > 0 {
    conductor_phase_label(@workflow.ConductorGoalPhase::ConductorPhaseAudit)
  } else if display.verification_parts > 0 {
    conductor_phase_label(@workflow.ConductorGoalPhase::ConductorPhaseVerify)
  } else if display.implementation_parts > 0 {
    conductor_phase_label(@workflow.ConductorGoalPhase::ConductorPhaseImplement)
  } else {
    conductor_phase_label(display.phase)
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
      let label = conductor_attention_label(attention)
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
              (
                display.implementation_parts,
                @workflow.ConductorGoalPhase::ConductorPhaseImplement,
              ),
              (
                display.verification_parts,
                @workflow.ConductorGoalPhase::ConductorPhaseVerify,
              ),
              (
                display.audit_parts,
                @workflow.ConductorGoalPhase::ConductorPhaseAudit,
              ),
              (
                display.integration_parts,
                @workflow.ConductorGoalPhase::ConductorPhaseIntegrate,
              ),
            ] {
            let (count, phase) = pair
            if count > 0 {
              segments.push(count.to_string() + " " + conductor_phase_label(phase))
            }
          }
          if segments.length() == 1 {
            segments.push(conductor_phase_label(display.phase))
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
  // The cache stores the full report, not a projection: the statusline
  // decodes it as a typed GoalStatusReport, and any projection subset would
  // silently drop fields the typed decoder requires.
  match report {
    Some(value) if conductor_statusline_goal_display(value) is Some(_) =>
      value.stringify(indent=0) + "\n"
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
fn conductor_statusline_test_part(
  id : String,
  stage : String,
) -> @workflow.GoalPartStatus {
  let parsed_stage : @workflow.PartWorkflowStage = @json.from_json(
    Json::string(stage),
  ) catch {
    _ => abort("unknown Part stage tag: " + stage)
  }
  {
    workflow_id: "wf-" + id,
    part_id: @control.PartId(id),
    provider_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    implementation_take_id: @control.TakeId("take-" + id + "-impl"),
    implementation_take_lifecycle: @control.TakeLifecycle::TakeRunning,
    implementation_session_lifecycle: None,
    verification_take_id: @control.TakeId("take-" + id + "-verify"),
    verification_take_lifecycle: @control.TakeLifecycle::TakePlanned,
    verification_session_lifecycle: None,
    audit_take_id: @control.TakeId("take-" + id + "-audit"),
    audit_take_lifecycle: @control.TakeLifecycle::TakePlanned,
    audit_session_lifecycle: None,
    lifecycle: @control.PartLifecycle::PartReady,
    stage: parsed_stage,
    durable_version: 1,
    harness_session_count: 0,
    effect_receipt_count: 0,
    verification_receipt_count: 0,
    audit_receipt_present: false,
    integration_receipt_present: false,
  }
}

///|
fn conductor_statusline_test_report(
  state : String,
  maximum_parallel_parts : Int,
  parts : Array[@workflow.GoalPartStatus],
  input_reason? : @workflow.GoalInputReason,
) -> Json {
  let parsed_state : @workflow.GoalExecutionState = @json.from_json(
    Json::string(state),
  ) catch {
    _ => abort("unknown Goal state tag: " + state)
  }
  let goal_id = @control.GoalId("goal-a")
  let report : @workflow.GoalStatusReport = {
    goal_id,
    state: parsed_state,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
    goal_ref: @workflow.GitRefName("refs/heads/choir/goals/goal-a"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    durable_version: 2,
    maximum_parallel_parts,
    active_policy_revision: {
      id: @control.RevisionId("revision-1"),
      goal_id,
      parent_revision_id: None,
      ordinal: 1,
      change: @workflow.GoalPolicyChange::GoalPolicyInitial,
      maximum_parallel_parts,
      digest: @control.Digest(
        "0000000000000000000000000000000000000000000000000000000000000000",
      ),
    },
    policy_revision_count: 1,
    pause_reason: None,
    resume_state: None,
    active_input_request: match input_reason {
      Some(reason) =>
        Some({
          id: @workflow.GoalInputRequestId("input-1"),
          goal_id,
          reason,
          created_at_version: 2,
        })
      None => None
    },
    input_answer_count: 0,
    assurance_stage: None,
    goal_verification_take_id: None,
    goal_audit_take_id: None,
    goal_branch_seal: None,
    assurance_sandbox_count: 0,
    assurance_harness_session_count: 0,
    assurance_effect_receipt_count: 0,
    goal_verification_receipt_count: 0,
    goal_audit_receipt_present: false,
    publication_state: None,
    publication_remote_repository_id: None,
    publication_remote_head_ref: None,
    publication_receipt_present: false,
    published_oid: None,
    pull_request_state: None,
    pull_request_receipt_present: false,
    pull_request_number: None,
    pull_request_url: None,
    finalization_id: None,
    readiness_decision: None,
    readiness_observation_sequence: None,
    semantic_run_projection: None,
    parts,
  }
  report.to_json()
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
    input_reason=@workflow.GoalInputReason::GoalInputPublicationRemoteUnavailable,
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

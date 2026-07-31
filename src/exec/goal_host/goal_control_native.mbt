///|
fn native_conductor_error(detail : String) -> @types.Response {
  @types.Response::err_text("Conductor request: " + detail)
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
    "commit_title": "docs: update the README".to_json(),
    "instruction": "implement the contract".to_json(),
    "provider": "codex".to_json(),
    "exact_paths": ["README.md"].to_json(),
    "path_trees": ([] : Array[String]).to_json(),
    "repository_wide": false.to_json(),
    "moon_args": ["test", "--target", "native"].to_json(),
  }.to_json()
  let request : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
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
  capture : async (@process_host.Command) -> (Int, String),
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
  match
    submit_native_conductor_goal_draft(
      project_dir,
      draft,
      capture,
      nfc_available=@process_host.native_path_nfc_available,
      is_nfc=@process_host.native_path_is_nfc,
    ) {
    Ok(report) => native_conductor_goal_action_ok_json(report.to_json())
    Err(error) => @types.Response::err(error)
  }
}

///|
/// Resolve the Goal selector shared by cancel and steer: an explicit goal_id,
/// or a user-facing part_id whose Goal the daemon looks up. Recovery from the
/// CLI relies on the part_id path because internal Goal ids are never shown.
fn native_conductor_resolve_goal_id(
  project_dir : String,
  request : @types.Request,
) -> Result[@control.GoalId, @types.ChoirError] {
  match
    (
      native_conductor_optional_string(request, "goal_id"),
      native_conductor_optional_string(request, "part_id"),
    ) {
    (Some(goal_id), None) => Ok(@control.GoalId(goal_id))
    (None, Some(part_id)) =>
      match
        inspect_native_goal_for_part(project_dir, @control.PartId(part_id)) {
        Ok(report) => Ok(report.goal_id)
        Err(error) => Err(error)
      }
    _ =>
      Err(
        @types.ChoirError::validation_error(
          "exactly one of goal_id or part_id is required",
        ),
      )
  }
}

///|
/// Project enumeration for recovery without a live Conductor: every durable
/// Goal with its state, lifecycle, and the Bead part ids it claimed, so a
/// user who lost the session can find a Goal by its work rather than by an
/// internal id they were never shown.
fn dispatch_native_goal_list(project_dir : String) -> @types.Response {
  let repository = native_goal_repository(project_dir)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return @types.Response::err(error)
  }
  let records = match
    @workflow.list_goal_execution_records(repository, adapters) {
    Ok(value) => value
    Err(error) => return @types.Response::err(error)
  }
  let goals = records.map(fn(stored) {
    let record = stored.record
    (
      {
        "goal_id": record.goal.id.to_json(),
        "state": record.state.to_json(),
        "lifecycle": record.goal.lifecycle.to_json(),
        "durable_version": record.durable_version.to_json(),
        "part_ids": record.source_claims
        .map(fn(claim) { claim.part_id.0 })
        .to_json(),
      } : Map[String, Json]).to_json()
  })
  native_conductor_goal_action_ok_json(
    ({ "goals": goals.to_json() } : Map[String, Json]).to_json(),
  )
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
      return @types.Response::err_text(
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
    Err(error) => @types.Response::err(error)
  }
}

///|
fn dispatch_native_goal_cancel(
  project_dir : String,
  request : @types.Request,
  now : Int64,
) -> @types.Response {
  let goal = match native_conductor_resolve_goal_id(project_dir, request) {
    Ok(value) => value
    Err(error) => return @types.Response::err(error)
  }
  match cancel_native_goal(project_dir, goal, now) {
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
          "goal_id": goal.to_json(),
          "state": state.to_json(),
          "already_terminal": true.to_json(),
        }.to_json(),
      )
    Err(error) => @types.Response::err(error)
  }
}

///|
/// Reclaim one terminal Goal's working storage, or report exactly what that
/// would reclaim.
///
/// Operator-facing only: it is deliberately absent from the Conductor tool
/// list, because what an installation keeps on disk is the user's call rather
/// than a steering decision. A non-terminal Goal is refused with the typed
/// reason rendered by the control plane, never partially archived.
///
/// The Git surface is injected so a test can drive this whole path — the
/// request's `dry_run` included — against a durable store without a repository
/// on disk. `dry_run` is the feature's only safety affordance, and it is read
/// here, so it is only pinned by a test that starts from a request.
pub async fn dispatch_native_goal_archive(
  project_dir : String,
  request : @types.Request,
  now : Int64,
  list_refs? : async (String) -> Result[
    Array[@workflow.GitRefName],
    @types.ChoirError,
  ] = list_native_goal_owned_git_refs,
  delete_refs? : async (String, Array[@workflow.GitRefName]) -> Result[
    Int,
    @types.ChoirError,
  ] = delete_native_goal_archived_git_refs,
) -> @types.Response {
  let goal = match native_conductor_resolve_goal_id(project_dir, request) {
    Ok(value) => value
    Err(error) => return @types.Response::err(error)
  }
  let dry_run = request.args.get_bool("dry_run").unwrap_or(false)
  let report = match
    archive_native_goal(
      project_dir,
      goal,
      dry_run~,
      now~,
      list_refs~,
      delete_refs~,
    ) {
    Ok(value) => value
    Err(error) => return @types.Response::err(error)
  }
  match report.decision {
    @workflow.GoalArchiveDecision::GoalArchiveRefused(refusal) =>
      @types.Response::err(
        @types.ChoirError::validation_error(
          @workflow.goal_archive_refusal_message(goal, refusal),
        ),
      )
    @workflow.GoalArchiveDecision::GoalArchivePlanned(plan) =>
      @types.Response::ok_values(
        native_goal_archive_response_fields(plan, report, dry_run~),
      )
  }
}

///|
/// The archive response.
///
/// `goal_id` and `state` are top-level because the daemon resolves a
/// Conductor's park from exactly those two fields of any `goal_` response. A
/// response that buried them would read as an unknown state, and an unknown
/// state parks — leaving a Conductor waiting on a Goal that has already
/// finished and just had its storage reclaimed.
pub fn native_goal_archive_response_fields(
  plan : @workflow.GoalArchivePlan,
  report : NativeGoalArchiveReport,
  dry_run~ : Bool,
) -> Map[String, Json] {
  {
    "goal_id": plan.goal_id.to_json(),
    "state": plan.state.to_json(),
    "dry_run": dry_run.to_json(),
    "archived": report.applied.to_json(),
    "release_refs": plan.release_refs.to_json(),
    "release_artifacts": plan.release_artifacts.to_json(),
    "retain_refs": plan.retain_refs.to_json(),
    "retain_artifacts": plan.retain_artifacts.to_json(),
    "refs_removed": report.refs_removed.to_json(),
    "artifacts_released": report.artifacts_released.to_json(),
    "outbox_events_released": report.outbox_events_released.to_json(),
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
      // No string fallback: a concurrency that arrived as text was already a
      // malformed request, and re-parsing it let a bad argument through as a
      // number instead of failing validation.
      let maximum = request.args.get_int("maximum_parallel_parts").unwrap_or(0)
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
  let goal = match native_conductor_resolve_goal_id(project_dir, request) {
    Ok(value) => value
    Err(error) => return @types.Response::err(error)
  }
  if request.args.get("action") == Some("retry_part") {
    // When the Goal was selected by part_id, that same Bead names the
    // blocked Part to retry; a bare goal_id retries the sole blocked Part
    // unless a part_id explicitly names one.
    let part_id = request.args
      .get("part_id")
      .map(fn(value) { @control.PartId(value) })
    return match retry_native_goal_part(project_dir, goal, part_id) {
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
      Err(error) => @types.Response::err(error)
    }
  }
  let goal_id = goal.0
  let change = match native_conductor_policy_change(request) {
    Ok(value) => value
    Err(error) => return @types.Response::err(error)
  }
  match steer_native_goal(project_dir, goal, change) {
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
    Err(error) => @types.Response::err(error)
  }
}

///|
fn dispatch_native_goal_attach(
  project_dir : String,
  request : @types.Request,
) -> @types.Response {
  let take_id = match native_conductor_required_string(request, "take_id") {
    Ok(value) => value
    Err(error) => return @types.Response::err(error)
  }
  match attach_native_goal(project_dir, @control.TakeId(take_id)) {
    Ok(report) => {
      guard report is Object(fields) else {
        return native_conductor_error("attach response was not an object")
      }
      fields.set("observational", true.to_json())
      native_conductor_goal_action_ok_json(fields.to_json())
    }
    Err(error) => @types.Response::err(error)
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
    Err(error) => return @types.Response::err(error)
  }
  let answer = match native_conductor_required_string(request, "answer") {
    Ok(value) => value
    Err(error) => return @types.Response::err(error)
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
    Err(error) => @types.Response::err(error)
  }
}

///|
pub async fn dispatch_native_goal_request(
  project_dir : String,
  request : @types.Request,
  now : Int64,
  capture~ : async (@process_host.Command) -> (Int, String),
) -> @types.Response {
  match request.name {
    "goal_submit" => dispatch_native_goal_submit(project_dir, request, capture)
    "goal_list" => dispatch_native_goal_list(project_dir)
    "goal_status" => dispatch_native_goal_status(project_dir, request)
    "goal_cancel" => dispatch_native_goal_cancel(project_dir, request, now)
    "goal_archive" => dispatch_native_goal_archive(project_dir, request, now)
    "goal_steer" => dispatch_native_goal_steer(project_dir, request)
    "goal_attach" => dispatch_native_goal_attach(project_dir, request)
    "goal_answer" => dispatch_native_goal_answer(project_dir, request, now)
    _ => native_conductor_error("unknown Goal tool " + request.name)
  }
}

///|
fn goal_cli_usage() -> String {
  "usage: choir goal list [--json] | choir goal status [--json] <goal-id|--part bead-id> | choir goal status <goal-id|--part bead-id> --json | choir goal steer <goal-id|--part bead-id> <pause|resume|concurrency N|retry [bead-id]> | choir goal cancel <goal-id|--part bead-id> | choir goal archive <goal-id|--part bead-id> [--dry-run] | choir goal attach <take-id> | choir goal answer <request-id> <answer>"
}

///|
/// Resolve a Goal selector shared across status/steer/cancel: a bare token is
/// the internal goal_id, `--part <bead-id>` names the user-facing Bead whose
/// Goal the daemon resolves. Recovery without a live Conductor needs the
/// latter because internal Goal ids are never shown to the user.
fn goal_cli_selector(
  args : Array[String],
  start : Int,
) -> Result[(Map[String, Json], Int), String] {
  if start >= args.length() {
    return Err(goal_cli_usage())
  }
  if args[start] == "--part" {
    if start + 1 >= args.length() || args[start + 1].trim() == "" {
      return Err(goal_cli_usage())
    }
    Ok(({ "part_id": args[start + 1].trim().to_owned().to_json() }, start + 2))
  } else {
    let value = args[start].trim().to_owned()
    if value == "" {
      return Err(goal_cli_usage())
    }
    Ok(({ "goal_id": value.to_json() }, start + 1))
  }
}

///|
test "goal selector accepts a goal id or a Bead part selector" {
  assert_eq(goal_cli_selector(["goal-a"], 0).unwrap().0, {
    "goal_id": "goal-a".to_json(),
  })
  assert_eq(goal_cli_selector(["--part", "choir-x"], 0).unwrap().0, {
    "part_id": "choir-x".to_json(),
  })
  assert_eq(goal_cli_selector(["--part", "choir-x"], 0).unwrap().1, 2)
  assert_true(goal_cli_selector(["--part"], 0) is Err(_))
  assert_true(goal_cli_selector([], 0) is Err(_))
}

///|
fn goal_cli_no_serve_response() -> @types.Response {
  @types.Response::err_text(
    @types.ChoirError::transport_error(
      "no `choir serve` is running — start it, then run `choir goal`.",
    ).message(),
  )
}

///|
fn goal_cli_call(tool : String, values : Map[String, Json]) -> @types.Response {
  let config = match goal_client_load_config() {
    Ok(loaded) => loaded
    Err(err) => return @types.Response::err_text(err)
  }
  let capability = @sys.getenv("CHOIR_CONDUCTOR_TOKEN")
  let req : @types.Request = {
    req_method: @types.WireMethod::WireToolsCall,
    name: tool,
    args: @types.RequestArgs::from_values(values),
  }
  match client_call_uds(config, req, capability) {
    Ok(resp) => resp
    // Only an unreachable socket means "no daemon". A rejected registration,
    // a mid-stream close, or an unparseable response are different faults and
    // reporting them as "start the daemon" sends the operator the wrong way.
    Err(error) =>
      if client_error_is_unreachable(error, config.listen_uds) {
        goal_cli_no_serve_response()
      } else {
        @types.Response::err_text(
          @types.ChoirError::transport_error(error).message(),
        )
      }
  }
}

///|
fn goal_cli_terminal_text(value : String, limit? : Int = 160) -> String {
  let output = StringBuilder::new()
  let mut seen = 0
  for char in value {
    if seen >= limit {
      output.write_string("…")
      break
    }
    seen = seen + 1
    match char {
      '\n' => output.write_string("\\n")
      '\r' => output.write_string("\\r")
      '\t' => output.write_string("\\t")
      '\u{001b}' => output.write_string("\\x1b")
      value if value < ' ' ||
        value == '\u{007f}' ||
        (value >= '\u{0080}' && value <= '\u{009f}') =>
        output.write_string("\\control")
      value => output.write_char(value)
    }
  }
  output.to_string()
}

///|
fn goal_cli_surface_text(surface : @control.ProviderSurfaceId) -> String {
  match surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli => "Claude"
    @control.ProviderSurfaceId::CodexSubscriptionCli => "Codex"
  }
}

///|
fn goal_cli_state_text(state : @workflow.GoalExecutionState) -> String {
  match state {
    GoalExecutionQueued => "queued"
    GoalExecutionRunning => "running"
    GoalExecutionAssuring => "assuring"
    GoalExecutionAssured => "assured"
    GoalExecutionPaused => "paused"
    GoalExecutionBlocked => "blocked"
    GoalExecutionCanceling => "canceling"
    GoalExecutionSucceeded => "succeeded"
    GoalExecutionCanceled => "canceled"
  }
}

///|
fn goal_cli_lifecycle_text(lifecycle : @control.GoalLifecycle) -> String {
  match lifecycle {
    GoalActive(GoalRunning) => "active/running"
    GoalActive(GoalNeedsInput) => "active/needs-input"
    GoalActive(GoalDrift) => "active/drift"
    GoalActive(GoalAmbiguous) => "active/ambiguous"
    GoalActive(GoalIntegrityBlocked) => "active/integrity-blocked"
    GoalActive(GoalRecoveryUncertain) => "active/recovery-uncertain"
    GoalCanceling(_) => "canceling"
    GoalSucceeded(_) => "succeeded"
    GoalCanceled(_) => "canceled"
  }
}

///|
fn goal_cli_part_stage_text(stage : @workflow.PartWorkflowStage) -> String {
  match stage {
    PartAccepted => "accepted"
    PartImplementationSandboxPrepared => "implementation-sandbox"
    PartImplementationCommandPrepared => "implementation-command"
    PartImplementationHarnessStarted => "implementing"
    PartImplementationCompleted => "implementation-complete"
    PartCandidateRecorded => "candidate"
    PartVerificationSandboxPrepared => "verification-sandbox"
    PartVerified => "verified"
    PartAuditSandboxPrepared => "audit-sandbox"
    PartAuditCommandPrepared => "audit-command"
    PartAuditHarnessStarted => "auditing"
    PartAuditResultRecorded => "audit-result"
    PartAudited => "audited"
    PartIntegrationPlanned => "integration-planned"
    PartPromotionPrepared => "promotion-prepared"
    PartIntegrationAuthorized => "integration-authorized"
    PartIntegrated => "integrated"
    PartCanceled => "canceled"
    PartBlocked => "blocked"
    PartRecoveryUncertain => "recovery-uncertain"
  }
}

///|
fn goal_cli_part_lifecycle_text(lifecycle : @control.PartLifecycle) -> String {
  match lifecycle {
    PartPending => "pending"
    PartReady => "ready"
    PartExecuting(_) => "executing"
    PartCandidate(_) => "candidate"
    PartVerified(_, _) => "verified"
    PartAudited(_, _, _) => "audited"
    PartPromoting(_, _, _) => "promoting"
    PartIntegrated(_) => "integrated"
    PartBlocked(_) => "blocked"
    PartCanceledNotRun => "canceled-not-run"
  }
}

///|
fn goal_cli_take_lifecycle_text(lifecycle : @control.TakeLifecycle) -> String {
  match lifecycle {
    TakePlanned => "planned"
    TakeLeased => "leased"
    TakeRunning => "running"
    TakeResultRecorded(_) => "result-recorded"
    TakeTerminal(_) => "terminal"
  }
}

///|
fn goal_cli_cancellation_text(
  cause : @workflow.GoalCancellationCause,
) -> String {
  match cause {
    GoalCancellationUserRequested => "user requested"
    GoalCancellationEvidenceOnlyCompleted(_, _) =>
      "evidence-only work completed"
    GoalCancellationSupersededByContractRevision(_) =>
      "superseded by a contract revision"
    GoalCancellationAuditRepairFailed(_) => "audit repair failed"
    GoalCancellationVerificationRepairFailed(_) => "verification repair failed"
    GoalCancellationAutoMergeFailed(_) => "automatic merge failed"
    GoalCancellationWorkOrderStopped(_) => "WorkOrder stopped"
    GoalCancellationPartBlocked(part, _) =>
      "Part " + goal_cli_terminal_text(part.0) + " blocked"
    GoalCancellationAssuranceBlocked => "Goal assurance blocked"
    GoalCancellationBranchInitializationBlocked(_) =>
      "branch initialization blocked"
    GoalCancellationSourceClaimBlocked(part, _) =>
      "source claim for " + goal_cli_terminal_text(part.0) + " blocked"
    GoalCancellationFinalizationRecoveryUncertain =>
      "finalization recovery uncertain"
    GoalCancellationUnattendedInputRequired(_) =>
      "unattended execution requires input"
  }
}

///|
fn goal_cli_input_reason_text(reason : @workflow.GoalInputReason) -> String {
  match reason {
    GoalInputPublicationRemoteUnavailable => "publication remote unavailable"
    GoalInputFinalizationNeedsUserInput => "finalization needs user input"
    GoalInputFinalizationDrifted => "finalization drifted"
    GoalInputFinalizationAmbiguous => "finalization is ambiguous"
  }
}

///|
fn goal_cli_usage_text(usage : @control.TakeUsage) -> String {
  "input " +
  usage.input_tokens.to_string() +
  ", output " +
  usage.output_tokens.to_string() +
  ", cache-read " +
  usage.cache_read_tokens.to_string() +
  ", cache-create " +
  usage.cache_creation_tokens.to_string() +
  ", wall " +
  usage.wall_time_ms.to_string() +
  " ms"
}

///|
fn goal_cli_attention_text(report : @workflow.GoalStatusReport) -> String {
  match report.cancellation_cause {
    Some(cause) => goal_cli_cancellation_text(cause)
    None =>
      match report.active_input_request {
        Some(request) => goal_cli_input_reason_text(request.reason)
        None =>
          match report.pause_reason {
            Some(GoalPauseRecoveryUncertain) => "recovery is uncertain"
            Some(GoalPauseRequested) => "paused by request"
            Some(GoalPauseAwaitingAnswer(request)) =>
              "awaiting answer " + goal_cli_terminal_text(request.0)
            None =>
              match report.assurance_block_reason {
                Some(GoalAssuranceVerificationBlocked(_)) =>
                  "Goal verification gate blocked"
                Some(GoalAssuranceAuditBlocked(_)) => "Goal audit gate blocked"
                None => {
                  for part in report.parts {
                    match part.dispatch_diagnostic {
                      Some(diagnostic) =>
                        return goal_cli_terminal_text(diagnostic.detail)
                      None => ()
                    }
                  }
                  "none"
                }
              }
          }
      }
  }
}

///|
fn goal_cli_pr_state_text(report : @workflow.GoalStatusReport) -> String {
  match (report.pull_request_number, report.pull_request_url) {
    (Some(number), Some(url)) => {
      let remote = match report.pull_request_draft {
        Some(true) => "draft"
        _ =>
          match
            (report.pull_request_delivery_policy, report.readiness_decision) {
            (Some({ mode: PullRequestAutoMerge, .. }), Some(PullRequestReady)) =>
              "merged"
            _ if report.pull_request_receipt_present => "open"
            _ => "remote state unobserved"
          }
      }
      let delivery = match report.readiness_decision {
        Some(PullRequestReady) => "ready"
        Some(PullRequestAwaitingReview) => "awaiting review"
        Some(PullRequestAwaitingMerge) => "awaiting merge"
        Some(PullRequestDeliveryFailed(_)) => "delivery failed"
        Some(PullRequestReadinessNeedsInput(_)) => "needs input"
        Some(PullRequestReadinessDrift(_)) => "drifted"
        Some(PullRequestReadinessAmbiguous) => "ambiguous"
        None => "readiness unobserved"
      }
      let merge = match report.pull_request_merge_state {
        Some(PullRequestMergeNotRequested) => "merge not requested"
        Some(PullRequestMergePlanned) => "merge planned"
        Some(PullRequestMergeAuthorized) => "merge authorized"
        Some(PullRequestMergeMayHaveBeenIssued) => "merge may have been issued"
        Some(PullRequestMergeEnabled) => "merge enabled"
        Some(PullRequestMergeRejected(_)) => "merge rejected"
        None => "merge state unobserved"
      }
      "#" +
      number.0.to_string() +
      " " +
      goal_cli_terminal_text(url.0) +
      " (" +
      remote +
      ", " +
      delivery +
      ", " +
      merge +
      ")"
    }
    _ => "not created"
  }
}

///|
fn goal_cli_render_list(
  fields : @types.ResponseFields,
) -> Result[String, String] {
  let report : @workflow.GoalListReport = @json.from_json(
    fields.to_json_map().to_json(),
  ) catch {
    _ => return Err("daemon returned a malformed Goal list")
  }
  if report.goals.length() == 0 {
    return Ok("No Goals found.\n")
  }
  let goals = report.goals.copy()
  goals.sort_by(fn(left, right) { left.goal_id.compare(right.goal_id) })
  let output = StringBuilder::new()
  output.write_string(
    "GOAL  STATE  LIFECYCLE  PARTS  BRANCH  WORKORDER  CAUSE\n",
  )
  for goal in goals {
    let parts = goal.part_ids.map(fn(part) { goal_cli_terminal_text(part.0) })
    let work_order = match goal.work_order_id {
      Some(value) => goal_cli_terminal_text(value.0)
      None => "—"
    }
    let cause = match goal.cancellation_cause {
      Some(value) => goal_cli_cancellation_text(value)
      None => "—"
    }
    output.write_string(
      goal_cli_terminal_text(goal.goal_id.0) +
      "  " +
      goal_cli_state_text(goal.state) +
      "  " +
      goal_cli_lifecycle_text(goal.lifecycle) +
      "  " +
      parts.join(",") +
      " (" +
      parts.length().to_string() +
      ")  " +
      goal_cli_terminal_text(goal.goal_ref.0) +
      "  " +
      work_order +
      "  " +
      cause +
      "\n",
    )
  }
  Ok(output.to_string())
}

///|
fn goal_cli_render_status(
  fields : @types.ResponseFields,
) -> Result[String, String] {
  let report : @workflow.GoalStatusReport = @json.from_json(
    fields.to_json_map().to_json(),
  ) catch {
    _ => return Err("daemon returned a malformed Goal status")
  }
  let output = StringBuilder::new()
  output.write_string(
    "Goal: " + goal_cli_terminal_text(report.goal_id.0) + "\n",
  )
  output.write_string(
    "State: " +
    goal_cli_state_text(report.state) +
    " (" +
    goal_cli_lifecycle_text(report.lifecycle) +
    ")\n",
  )
  output.write_string("Attention: " + goal_cli_attention_text(report) + "\n")
  output.write_string(
    "Branch: " +
    goal_cli_terminal_text(report.goal_ref.0) +
    " -> " +
    goal_cli_terminal_text(report.integration_target_ref.0) +
    "\n",
  )
  output.write_string("Pull request: " + goal_cli_pr_state_text(report) + "\n")
  match report.work_order_id {
    Some(value) =>
      output.write_string(
        "WorkOrder: " + goal_cli_terminal_text(value.0) + "\n",
      )
    None => output.write_string("WorkOrder: none\n")
  }
  output.write_string(
    "Observed usage: " + goal_cli_usage_text(report.usage) + "\n",
  )
  if report.provider_usage.length() == 0 {
    output.write_string("Provider usage: no provider sessions\n")
  } else {
    output.write_string("Provider usage:\n")
    for status in report.provider_usage {
      output.write_string("  " + goal_cli_surface_text(status.surface) + ": ")
      match status.usage {
        Some(usage) => output.write_string(goal_cli_usage_text(usage) + "\n")
        None => output.write_string("unknown\n")
      }
    }
  }
  if report.provider_capacity.length() == 0 {
    output.write_string("Provider pressure: unobserved\n")
  } else {
    let pressured = report.provider_capacity.filter(fn(status) {
      status.held >= status.capacity || status.deferred_until is Some(_)
    })
    if pressured.length() == 0 {
      output.write_string("Provider pressure: observed; none\n")
    } else {
      output.write_string("Provider pressure:\n")
      for status in pressured {
        let deferred = match status.deferred_until {
          Some(value) => ", deferred until " + value.to_string()
          None => ""
        }
        output.write_string(
          "  " +
          goal_cli_surface_text(status.surface) +
          ": " +
          status.held.to_string() +
          "/" +
          status.capacity.to_string() +
          " held" +
          deferred +
          "\n",
        )
      }
    }
  }
  output.write_string("Parts (" + report.parts.length().to_string() + "):\n")
  for part in report.parts {
    output.write_string(
      "  " +
      goal_cli_terminal_text(part.part_id.0) +
      ": " +
      goal_cli_surface_text(part.provider_surface) +
      ", " +
      goal_cli_part_stage_text(part.stage) +
      "/" +
      goal_cli_part_lifecycle_text(part.lifecycle) +
      ", verification receipts " +
      part.verification_receipt_count.to_string() +
      ", audit receipts " +
      (if part.audit_receipt_present { "1" } else { "0" }) +
      ", findings " +
      part.audit_total_findings_count.to_string() +
      " (blocking " +
      part.audit_blocking_findings_count.to_string() +
      "), integration " +
      (if part.integration_receipt_present { "yes" } else { "no" }) +
      ", failovers " +
      part.provider_failovers.length().to_string() +
      "\n",
    )
    for
      take in [
        (
          "implementation",
          part.implementation_take_id,
          part.implementation_take_lifecycle,
        ),
        (
          "verification",
          part.verification_take_id,
          part.verification_take_lifecycle,
        ),
        ("audit", part.audit_take_id, part.audit_take_lifecycle),
      ] {
      output.write_string(
        "    " +
        take.0 +
        ": " +
        goal_cli_terminal_text(take.1.0) +
        " (" +
        goal_cli_take_lifecycle_text(take.2) +
        ") — choir goal attach " +
        goal_cli_terminal_text(take.1.0) +
        "\n",
      )
    }
  }
  if report.goal_verification_take_id is Some(_) ||
    report.goal_audit_take_id is Some(_) {
    output.write_string(
      "Goal assurance: verification receipts " +
      report.goal_verification_receipt_count.to_string() +
      ", audit receipt " +
      (if report.goal_audit_receipt_present { "yes" } else { "no" }) +
      "\n",
    )
    match report.goal_verification_take_id {
      Some(take) =>
        output.write_string(
          "  verification: " +
          goal_cli_terminal_text(take.0) +
          " — choir goal attach " +
          goal_cli_terminal_text(take.0) +
          "\n",
        )
      None => ()
    }
    match report.goal_audit_take_id {
      Some(take) =>
        output.write_string(
          "  audit: " +
          goal_cli_terminal_text(take.0) +
          " — choir goal attach " +
          goal_cli_terminal_text(take.0) +
          "\n",
        )
      None => ()
    }
  }
  Ok(output.to_string())
}

///|
fn goal_cli_emit_human(
  response : @types.Response,
  render : (@types.ResponseFields) -> Result[String, String],
) -> Unit {
  match response.ok_payload() {
    Some(fields) =>
      match render(fields) {
        Ok(value) => {
          @sys.write_stdout(value)
          @sys.exit(0)
        }
        Err(error) => {
          @sys.write_stderr(
            "choir goal: " + goal_cli_terminal_text(error) + "\n",
          )
          @sys.exit(1)
        }
      }
    None => {
      @sys.write_stderr(
        "choir goal: " +
        goal_cli_terminal_text(
          response.error_message().unwrap_or("request failed"),
        ) +
        "\n",
      )
      @sys.exit(1)
    }
  }
}

///|
fn goal_cli_list_json(
  args : Array[String],
  start : Int,
) -> Result[Bool, String] {
  if start == args.length() {
    return Ok(false)
  }
  if start + 1 == args.length() && args[start] == "--json" {
    Ok(true)
  } else {
    Err(goal_cli_usage())
  }
}

///|
fn goal_cli_status_presentation(
  args : Array[String],
  start : Int,
) -> Result[(Map[String, Json], Bool), String] {
  let selector : Array[String] = []
  let mut json = false
  for index = start; index < args.length(); index = index + 1 {
    if args[index] == "--json" {
      if json {
        return Err(goal_cli_usage())
      }
      json = true
    } else {
      selector.push(args[index])
    }
  }
  match goal_cli_status_values(selector, 0) {
    Ok(values) => Ok((values, json))
    Err(error) => Err(error)
  }
}

///|
fn goal_cli_requested_json(args : Array[String], start : Int) -> Bool {
  for index = start; index < args.length(); index = index + 1 {
    if args[index] == "--json" {
      return true
    }
  }
  false
}

///|
fn goal_cli_test_fields(value : Json) -> @types.ResponseFields {
  match value {
    Object(fields) => @types.ResponseFields::from_values(fields)
    _ => abort("test response is not an object")
  }
}

///|
fn goal_cli_test_report(
  state? : String = "GoalExecutionRunning",
  parts? : Array[@workflow.GoalPartStatus] = [],
) -> @workflow.GoalStatusReport {
  @json.from_json(conductor_statusline_test_report(state, 1, parts)) catch {
    _ => abort("statusline fixture did not decode")
  }
}

///|
test "goal list and status parse JSON only in the admitted positions" {
  assert_eq(goal_cli_list_json(["--json"], 0), Ok(true))
  assert_eq(goal_cli_list_json([], 0), Ok(false))
  assert_true(goal_cli_list_json(["--json", "--json"], 0) is Err(_))
  assert_eq(
    goal_cli_status_presentation(["--json", "goal-a"], 0).unwrap(),
    ({ "goal_id": "goal-a".to_json() }, true),
  )
  assert_eq(
    goal_cli_status_presentation(["--part", "choir-a", "--json"], 0).unwrap(),
    ({ "part_id": "choir-a".to_json() }, true),
  )
  assert_true(
    goal_cli_status_presentation(["goal-a", "--json", "--json"], 0) is Err(_),
  )
  assert_true(
    goal_cli_status_presentation(["goal-a", "extra", "--json"], 0) is Err(_),
  )
}

///|
test "JSON presentation preserves the exact existing wire encoding" {
  let response = @types.Response::ok_values({
    "goal_id": "goal-a".to_json(),
    "state": "GoalExecutionRunning".to_json(),
  })
  assert_eq(
    client_response_json(response),
    @transport.format_response(response) + "\n",
  )
}

///|
test "human Goal list is empty-safe, sorted, and terminal-safe" {
  assert_eq(
    goal_cli_render_list(
      goal_cli_test_fields(@workflow.GoalListReport::{ goals: [] }.to_json()),
    ),
    Ok("No Goals found.\n"),
  )
  let running : @workflow.GoalListStatus = {
    goal_id: @control.GoalId("goal-b\nsecond-line"),
    state: @workflow.GoalExecutionState::GoalExecutionRunning,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
    durable_version: 2,
    part_ids: [@control.PartId("choir-b")],
    goal_ref: @workflow.GitRefName("refs/heads/goal-b"),
    work_order_id: None,
    cancellation_cause: None,
  }
  let canceled : @workflow.GoalListStatus = {
    ..running,
    goal_id: @control.GoalId("goal-a"),
    state: @workflow.GoalExecutionState::GoalExecutionCanceled,
    lifecycle: @control.GoalLifecycle::GoalCanceled(
      @control.CancellationSummaryId("cancel-1"),
    ),
    part_ids: [@control.PartId("choir-a"), @control.PartId("choir-c")],
    work_order_id: Some(@workflow.WorkOrderId("work-1")),
    cancellation_cause: Some(
      @workflow.GoalCancellationCause::GoalCancellationUserRequested,
    ),
  }
  let rendered = goal_cli_render_list(
    goal_cli_test_fields(
      @workflow.GoalListReport::{ goals: [running, canceled] }.to_json(),
    ),
  ).unwrap()
  let lines = rendered.split("\n").collect()
  assert_true(lines[1].has_prefix("goal-a"))
  assert_true(lines[2].has_prefix("goal-b"))
  assert_true(rendered.contains("choir-a,choir-c (2)"))
  assert_true(rendered.contains("work-1"))
  assert_true(rendered.contains("user requested"))
  assert_true(rendered.contains("goal-b\\nsecond-line"))
  assert_false(rendered.contains("goal-b\nsecond-line"))
}

///|
test "human Goal status includes usage pressure evidence and every attach command" {
  let part = {
    ..conductor_statusline_test_part("choir-a", "PartVerified"),
    verification_receipt_count: 2,
    audit_receipt_present: true,
    audit_total_findings_count: 3,
    audit_blocking_findings_count: 1,
    integration_receipt_present: true,
    provider_failovers: [
      {
        from_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        to_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
        cause: @control.ProviderAvailability::ProviderUnavailable,
        retry_ordinal: 1,
        decided_at: 10L,
      },
    ],
  }
  let base = goal_cli_test_report(parts=[part])
  let report = {
    ..base,
    work_order_id: Some(@workflow.WorkOrderId("work-a")),
    usage: {
      input_tokens: 10,
      output_tokens: 5,
      cache_read_tokens: 2,
      cache_creation_tokens: 1,
      wall_time_ms: 30,
    },
    provider_usage: [
      {
        surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        usage: None,
      },
      {
        surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
        usage: Some({
          input_tokens: 10,
          output_tokens: 5,
          cache_read_tokens: 2,
          cache_creation_tokens: 1,
          wall_time_ms: 30,
        }),
      },
    ],
    provider_capacity: [
      {
        surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        held: 2,
        capacity: 2,
        deferred_until: Some(99L),
      },
      {
        surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
        held: 0,
        capacity: 2,
        deferred_until: None,
      },
    ],
    goal_verification_take_id: Some(@control.TakeId("goal-verify")),
    goal_audit_take_id: Some(@control.TakeId("goal-audit")),
    goal_verification_receipt_count: 1,
    goal_audit_receipt_present: true,
  }
  let rendered = goal_cli_render_status(goal_cli_test_fields(report.to_json())).unwrap()
  assert_true(rendered.contains("WorkOrder: work-a"))
  assert_true(rendered.contains("Claude: unknown"))
  assert_true(rendered.contains("Codex: input 10"))
  assert_true(rendered.contains("Claude: 2/2 held, deferred until 99"))
  assert_true(rendered.contains("verification receipts 2"))
  assert_true(rendered.contains("findings 3 (blocking 1)"))
  assert_true(rendered.contains("integration yes, failovers 1"))
  for
    take in [
      part.implementation_take_id,
      part.verification_take_id,
      part.audit_take_id,
      @control.TakeId("goal-verify"),
      @control.TakeId("goal-audit"),
    ] {
    assert_true(rendered.contains("choir goal attach " + take.0))
  }
}

///|
test "human Goal status distinguishes pressure observation and PR states" {
  let unobserved = goal_cli_render_status(
    goal_cli_test_fields(goal_cli_test_report().to_json()),
  ).unwrap()
  assert_true(unobserved.contains("Pull request: not created"))
  assert_true(unobserved.contains("Provider pressure: unobserved"))
  let base = goal_cli_test_report()
  let observed = {
    ..base,
    provider_capacity: [
      {
        surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
        held: 0,
        capacity: 2,
        deferred_until: None,
      },
    ],
    pull_request_number: Some(@workflow.PullRequestNumber(42)),
    pull_request_url: Some(
      @workflow.PullRequestUrl("https://example.invalid/pull/42"),
    ),
    pull_request_draft: Some(true),
    readiness_decision: Some(
      @workflow.PullRequestReadinessDecision::PullRequestAwaitingReview,
    ),
  }
  let rendered = goal_cli_render_status(
    goal_cli_test_fields(observed.to_json()),
  ).unwrap()
  assert_true(rendered.contains("Provider pressure: observed; none"))
  assert_true(rendered.contains("#42 https://example.invalid/pull/42"))
  assert_true(rendered.contains("draft, awaiting review"))
  let merged = {
    ..observed,
    pull_request_receipt_present: true,
    pull_request_draft: Some(false),
    pull_request_delivery_policy: Some({
      mode: @types.PullRequestDeliveryMode::PullRequestAutoMerge,
      merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
    }),
    pull_request_merge_state: Some(
      @workflow.PullRequestMergeState::PullRequestMergeEnabled,
    ),
    readiness_decision: Some(
      @workflow.PullRequestReadinessDecision::PullRequestReady,
    ),
  }
  let merged_text = goal_cli_render_status(
    goal_cli_test_fields(merged.to_json()),
  ).unwrap()
  assert_true(merged_text.contains("merged, ready, merge enabled"))
}

///|
test "human Goal status renders typed attention and bounds hostile text" {
  for
    entry in [
      ("GoalExecutionRunning", "State: running"),
      ("GoalExecutionBlocked", "State: blocked"),
      ("GoalExecutionSucceeded", "State: succeeded"),
    ] {
    let (state, expected) = entry
    assert_true(
      goal_cli_render_status(
        goal_cli_test_fields(goal_cli_test_report(state~).to_json()),
      )
      .unwrap()
      .contains(expected),
    )
  }
  let base = goal_cli_test_report(state="GoalExecutionPaused")
  let paused = {
    ..base,
    pause_reason: Some(@workflow.GoalPauseReason::GoalPauseRequested),
  }
  assert_true(
    goal_cli_render_status(goal_cli_test_fields(paused.to_json()))
    .unwrap()
    .contains("Attention: paused by request"),
  )
  let canceled = {
    ..goal_cli_test_report(state="GoalExecutionCanceled"),
    cancellation_cause: Some(
      @workflow.GoalCancellationCause::GoalCancellationAuditRepairFailed(
        @control.Digest("a".repeat(64)),
      ),
    ),
  }
  assert_true(
    goal_cli_render_status(goal_cli_test_fields(canceled.to_json()))
    .unwrap()
    .contains("Attention: audit repair failed"),
  )
  let hostile = "line\n\t\u{001b}" + "x".repeat(300)
  let safe = goal_cli_terminal_text(hostile)
  assert_true(safe.contains("\\n\\t\\x1b"))
  assert_true(safe.length() < 190)
  assert_false(safe.contains("\u{001b}"))
}

///|
test "malformed daemon payload fails before rendering partial status" {
  assert_eq(
    goal_cli_render_status(
      @types.ResponseFields::from_values({ "goal_id": "goal-a".to_json() }),
    ),
    Err("daemon returned a malformed Goal status"),
  )
}

///|
fn goal_cli_status_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  let (values, next) = match goal_cli_selector(args, start) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if next != args.length() {
    return Err(goal_cli_usage())
  }
  Ok(values)
}

///|
test "goal status accepts a Goal ID or a Bead part selector" {
  assert_eq(goal_cli_status_values(["goal-a"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
  })
  assert_eq(goal_cli_status_values(["--part", "choir-x"], 0).unwrap(), {
    "part_id": "choir-x".to_json(),
  })
  assert_true(goal_cli_status_values([], 0) is Err(_))
  assert_true(goal_cli_status_values(["goal-a", "goal-b"], 0) is Err(_))
}

///|
test "goal CLI reports missing serve instead of local fallback" {
  match goal_cli_no_serve_response().error_message() {
    Some(msg) => {
      assert_true(msg.contains("no `choir serve` is running"))
      assert_true(msg.contains("start it, then run `choir goal`"))
    }
    None => fail("expected missing-serve error")
  }
}

///|
fn goal_cli_steer_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  let (selector, action_index) = match goal_cli_selector(args, start) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if action_index >= args.length() {
    return Err(goal_cli_usage())
  }
  let action = args[action_index].trim().to_lower()
  let values = selector
  match action {
    "pause" | "resume" => {
      if action_index + 1 != args.length() {
        return Err(goal_cli_usage())
      }
      values["action"] = action.to_json()
      Ok(values)
    }
    "retry" => {
      // Optional trailing Bead id names the blocked Part; omitted when
      // exactly one Part is blocked.
      if action_index + 1 < args.length() {
        if action_index + 2 != args.length() ||
          args[action_index + 1].trim() == "" {
          return Err(goal_cli_usage())
        }
        values["part_id"] = args[action_index + 1].trim().to_owned().to_json()
      } else if action_index + 1 != args.length() {
        return Err(goal_cli_usage())
      }
      values["action"] = "retry_part".to_json()
      Ok(values)
    }
    "concurrency" => {
      if action_index + 2 != args.length() {
        return Err(goal_cli_usage())
      }
      let value = @string.parse_int(args[action_index + 1]) catch { _ => 0 }
      if value <= 0 {
        return Err("concurrency requires a positive integer")
      }
      values["action"] = "set_concurrency".to_json()
      values["maximum_parallel_parts"] = value.to_json()
      Ok(values)
    }
    _ => Err(goal_cli_usage())
  }
}

///|
test "goal CLI parses typed steering operations" {
  assert_eq(goal_cli_steer_values(["goal-a", "pause"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "pause".to_json(),
  })
  assert_eq(
    goal_cli_steer_values(["--part", "choir-x", "resume"], 0).unwrap(),
    { "part_id": "choir-x".to_json(), "action": "resume".to_json() },
  )
  assert_eq(goal_cli_steer_values(["goal-a", "concurrency", "3"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "set_concurrency".to_json(),
    "maximum_parallel_parts": (3).to_json(),
  })
  assert_eq(goal_cli_steer_values(["goal-a", "retry"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "retry_part".to_json(),
  })
  assert_eq(goal_cli_steer_values(["goal-a", "retry", "choir-b"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "action": "retry_part".to_json(),
    "part_id": "choir-b".to_json(),
  })
  assert_true(
    goal_cli_steer_values(["goal-a", "concurrency", "0"], 0) is Err(_),
  )
  assert_true(goal_cli_steer_values(["goal-a", "pause", "extra"], 0) is Err(_))
}

///|
/// Archive selects a Goal exactly like status and cancel; `--dry-run` may sit
/// on either side of the selector, because an operator reaching for a preview
/// should not have to remember which.
fn goal_cli_archive_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  let selector : Array[String] = []
  let mut dry_run = false
  for index = start; index < args.length(); index = index + 1 {
    if args[index] == "--dry-run" {
      dry_run = true
    } else {
      selector.push(args[index])
    }
  }
  let (values, next) = match goal_cli_selector(selector, 0) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if next != selector.length() {
    return Err(goal_cli_usage())
  }
  values["dry_run"] = dry_run.to_json()
  Ok(values)
}

///|
test "goal archive parses a selector and an optional dry run" {
  assert_eq(goal_cli_archive_values(["goal-a"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "dry_run": false.to_json(),
  })
  assert_eq(goal_cli_archive_values(["goal-a", "--dry-run"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "dry_run": true.to_json(),
  })
  assert_eq(goal_cli_archive_values(["--dry-run", "goal-a"], 0).unwrap(), {
    "goal_id": "goal-a".to_json(),
    "dry_run": true.to_json(),
  })
  assert_eq(
    goal_cli_archive_values(["--part", "choir-x", "--dry-run"], 0).unwrap(),
    { "part_id": "choir-x".to_json(), "dry_run": true.to_json() },
  )
  assert_true(goal_cli_archive_values([], 0) is Err(_))
  assert_true(goal_cli_archive_values(["--dry-run"], 0) is Err(_))
  assert_true(goal_cli_archive_values(["goal-a", "goal-b"], 0) is Err(_))
}

///|
fn goal_cli_attach_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  if start + 1 != args.length() || args[start].trim() == "" {
    Err(goal_cli_usage())
  } else {
    Ok({ "take_id": args[start].trim().to_owned().to_json() })
  }
}

///|
test "goal CLI parses observational Take attachment" {
  assert_eq(goal_cli_attach_values(["take-a"], 0).unwrap(), {
    "take_id": "take-a".to_json(),
  })
  assert_true(goal_cli_attach_values([], 0) is Err(_))
  assert_true(goal_cli_attach_values(["take-a", "extra"], 0) is Err(_))
}

///|
fn goal_cli_answer_values(
  args : Array[String],
  start : Int,
) -> Result[Map[String, Json], String] {
  if start + 1 >= args.length() || args[start].trim() == "" {
    return Err(goal_cli_usage())
  }
  let answer = args[start + 1:].join(" ").trim().to_owned()
  if answer == "" {
    return Err(goal_cli_usage())
  }
  Ok({
    "request_id": args[start].trim().to_owned().to_json(),
    "answer": answer.to_json(),
  })
}

///|
test "goal CLI binds an answer to one durable request" {
  assert_eq(
    goal_cli_answer_values(["request-a", "I", "reopened", "it"], 0).unwrap(),
    { "request_id": "request-a".to_json(), "answer": "I reopened it".to_json() },
  )
  assert_true(goal_cli_answer_values(["request-a"], 0) is Err(_))
}

///|
fn goal_run() -> Unit {
  let args = @env.args()
  if args.length() == 3 && (args[2] == "--help" || args[2] == "-h") {
    @sys.write_stdout(goal_cli_usage() + "\n")
    return
  }
  if args.length() >= 3 && args[2] == "list" {
    let json = match goal_cli_list_json(args, 3) {
      Ok(value) => value
      Err(error) => {
        if goal_cli_requested_json(args, 3) {
          client_emit(@types.Response::err_text(error))
        } else {
          @sys.write_stderr(error + "\n")
          @sys.exit(1)
        }
        return
      }
    }
    let response = goal_cli_call("goal_list", Map([]))
    if json {
      client_emit(response)
    } else {
      goal_cli_emit_human(response, goal_cli_render_list)
    }
    return
  }
  if args.length() >= 3 && args[2] == "status" {
    let presentation = match goal_cli_status_presentation(args, 3) {
      Ok(value) => value
      Err(err) => {
        if goal_cli_requested_json(args, 3) {
          client_emit(@types.Response::err_text(err))
        } else {
          @sys.write_stderr(err + "\n")
          @sys.exit(1)
        }
        return
      }
    }
    let response = goal_cli_call("goal_status", presentation.0)
    if presentation.1 {
      client_emit(response)
    } else {
      goal_cli_emit_human(response, goal_cli_render_status)
    }
    return
  }
  if args.length() >= 3 && args[2] == "cancel" {
    let values = match goal_cli_status_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::err_text(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_cancel", values))
    return
  }
  if args.length() >= 3 && args[2] == "archive" {
    let values = match goal_cli_archive_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::err_text(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_archive", values))
    return
  }
  if args.length() >= 3 && args[2] == "steer" {
    let values = match goal_cli_steer_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::err_text(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_steer", values))
    return
  }
  if args.length() >= 3 && args[2] == "attach" {
    let values = match goal_cli_attach_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::err_text(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_attach", values))
    return
  }
  if args.length() >= 3 && args[2] == "answer" {
    let values = match goal_cli_answer_values(args, 3) {
      Ok(value) => value
      Err(err) => {
        client_emit(@types.Response::err_text(err))
        return
      }
    }
    client_emit(goal_cli_call("goal_answer", values))
    return
  }
  client_emit(@types.Response::err_text(goal_cli_usage()))
}

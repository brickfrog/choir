///| Pure Conductor-facing projections of the durable Goal status report.
/// The choird binary previously re-derived park decisions, material-change
/// fingerprints, and statusline displays from stringified JSON with
/// hand-maintained field-name lists; every decision here consumes the typed
/// `GoalStatusReport` instead, so report-shape drift is a compile error
/// rather than a silently wrong projection.

///|
pub fn goal_execution_state_is_terminal(state : GoalExecutionState) -> Bool {
  match state {
    GoalExecutionState::GoalExecutionSucceeded
    | GoalExecutionState::GoalExecutionCanceled => true
    _ => false
  }
}

///|
/// Whether the Conductor's Stop hook should park awaiting a further durable
/// Goal event. A durable cancellation cutoff also releases the park: choird
/// continues reconciliation independently, but the user's cancellation request
/// has been accepted and must not trap the Conductor in repeated Stop-hook
/// turns. An unknown state parks, matching the pre-observation default.
pub fn conductor_park_for_goal_state(state : GoalExecutionState?) -> Bool {
  match state {
    Some(
      GoalExecutionState::GoalExecutionSucceeded
      | GoalExecutionState::GoalExecutionCanceling
      | GoalExecutionState::GoalExecutionCanceled
    ) => false
    Some(_) => true
    None => true
  }
}

///|
/// Decode the wire tag of a Goal execution state ("GoalExecutionRunning",
/// ...). Returns `None` for anything that is not a current state tag.
pub fn parse_goal_execution_state(tag : String) -> GoalExecutionState? {
  let decoded : GoalExecutionState = @json.from_json(Json::string(tag)) catch {
    _ => return None
  }
  Some(decoded)
}

///|
/// Projection of the report fields whose change is material to the
/// Conductor: state transitions, lifecycle movement, pauses, input requests,
/// and per-Part stage movement. Counter-only churn (receipt counts, durable
/// versions) deliberately does not change the fingerprint, so it never wakes
/// the Conductor or rewrites the statusline cache.
pub fn goal_report_material_fingerprint(report : GoalStatusReport) -> String {
  let parts = report.parts.map(fn(part) {
    (
      {
        "part_id": part.part_id.to_json(),
        "implementation_take_lifecycle": part.implementation_take_lifecycle.to_json(),
        "implementation_session_lifecycle": part.implementation_session_lifecycle.to_json(),
        "verification_take_lifecycle": part.verification_take_lifecycle.to_json(),
        "verification_session_lifecycle": part.verification_session_lifecycle.to_json(),
        "audit_take_lifecycle": part.audit_take_lifecycle.to_json(),
        "audit_session_lifecycle": part.audit_session_lifecycle.to_json(),
        "lifecycle": part.lifecycle.to_json(),
        "stage": part.stage.to_json(),
        "dispatch_diagnostic": part.dispatch_diagnostic.to_json(),
        // A Part that started spending a different provider's allowance is a
        // material change: the Conductor has to be able to explain it.
        "provider_failovers": part.provider_failovers.to_json(),
      } : Map[String, Json]).to_json()
  })
  (
    {
      "goal_id": report.goal_id.to_json(),
      "state": report.state.to_json(),
      "lifecycle": report.lifecycle.to_json(),
      "pause_reason": report.pause_reason.to_json(),
      "resume_state": report.resume_state.to_json(),
      "active_input_request": report.active_input_request.to_json(),
      "maximum_parallel_parts": report.maximum_parallel_parts.to_json(),
      "assurance_stage": report.assurance_stage.to_json(),
      "assurance_block_reason": report.assurance_block_reason.to_json(),
      "publication_state": report.publication_state.to_json(),
      "pull_request_state": report.pull_request_state.to_json(),
      "pull_request_delivery_policy": report.pull_request_delivery_policy.to_json(),
      // A cancellation is always material: it is the reason the Goal stopped,
      // and a Conductor that never saw it cannot explain the outcome.
      "cancellation_cause": report.cancellation_cause.to_json(),
      "pull_request_merge_state": report.pull_request_merge_state.to_json(),
      "finalization_id": report.finalization_id.to_json(),
      "readiness_decision": report.readiness_decision.to_json(),
      "parts": parts.to_json(),
    } : Map[String, Json])
  .to_json()
  .stringify(indent=0)
}

///|
fn part_attention_summary(part : GoalPartStatus) -> String? {
  let reason = match part.lifecycle {
    @control.PartLifecycle::PartBlocked(reason) =>
      reason.to_json().stringify(indent=0)
    @control.PartLifecycle::PartCanceledNotRun => "\"PartCanceledNotRun\""
    _ => return None
  }
  let detail = match part.dispatch_diagnostic {
    Some(diagnostic) => ": " + diagnostic.detail
    None => ""
  }
  Some("Part " + part.part_id.0 + " " + reason + detail)
}

///|
/// One line naming why a Goal currently needs attention, or `None` while it is
/// simply running.
///
/// The daemon log used to record only that a Goal reached
/// `GoalExecutionBlocked`, which left an operator reading `serve.log` with no
/// way to separate a failing verification from a provider outage. Every cause
/// this returns is read from typed durable state, never inferred.
pub fn goal_report_attention_summary(report : GoalStatusReport) -> String? {
  let causes : Array[String] = []
  for part in report.parts {
    match part_attention_summary(part) {
      Some(value) => causes.push(value)
      None => ()
    }
  }
  match report.assurance_block_reason {
    Some(reason) =>
      causes.push("Goal assurance " + reason.to_json().stringify(indent=0))
    None => ()
  }
  match report.active_input_request {
    Some(request) =>
      causes.push(
        "input requested " + request.reason.to_json().stringify(indent=0),
      )
    None => ()
  }
  match report.pause_reason {
    Some(reason) =>
      causes.push("paused " + reason.to_json().stringify(indent=0))
    None => ()
  }
  if causes.length() == 0 {
    None
  } else {
    Some(causes.join("; "))
  }
}

///|
pub(all) enum ConductorGoalPhase {
  ConductorPhaseQueued
  ConductorPhaseImplement
  ConductorPhaseVerify
  ConductorPhaseAudit
  ConductorPhaseIntegrate
  ConductorPhaseAssure
  ConductorPhasePublish
  ConductorPhasePullRequest
  ConductorPhaseMerge
} derive(Debug, Eq)

///|
pub(all) enum ConductorGoalAttention {
  ConductorAttentionNeedsInput
  ConductorAttentionRecoveryUncertain
  ConductorAttentionBlocked
  ConductorAttentionPaused
  ConductorAttentionCanceling
} derive(Debug, Eq)

///|
pub(all) struct ConductorGoalDisplay {
  maximum_parallel_parts : Int
  total_parts : Int
  integrated_parts : Int
  implementation_parts : Int
  verification_parts : Int
  audit_parts : Int
  integration_parts : Int
  single_part_id : String?
  phase : ConductorGoalPhase
  attention : ConductorGoalAttention?
  attention_target : String?
  additional_attention : Int
  /// Total tokens this Goal's Takes reported spending against the user's paid
  /// subscription allowance. Zero when no surface reported any.
  spent_tokens : Int
  /// Only the surfaces that cannot serve another Take right now. A surface
  /// with room and nothing refused on it is left out entirely, for the reason
  /// a zero spend figure is: it is noise, and a reader who sees a capacity
  /// figure at all should be seeing pressure.
  capacity_pressure : Array[ProviderSurfaceCapacityStatus]
  /// How many of this Goal's Parts are waiting on a provider rather than
  /// working, from `goal_parts_awaiting_provider`. Zero when none are.
  provider_waiting : Int
} derive(Debug, Eq)

///|
/// A token count short enough to sit in a status line: exact below a thousand,
/// then thousands, then millions. Rounding here is presentation only; the
/// durable figure keeps its full precision.
pub fn compact_token_count(tokens : Int) -> String {
  if tokens < 1000 {
    tokens.to_string()
  } else if tokens < 1000000 {
    (tokens / 1000).to_string() + "k"
  } else {
    (tokens / 1000000).to_string() +
    "." +
    (tokens % 1000000 / 100000).to_string() +
    "M"
  }
}

///|
fn conductor_input_request_target(report : GoalStatusReport) -> (Bool, String?) {
  match report.active_input_request {
    Some(request) =>
      match request.reason {
        GoalInputReason::GoalInputPublicationRemoteUnavailable =>
          (true, Some("publish"))
        GoalInputReason::GoalInputFinalizationNeedsUserInput
        | GoalInputReason::GoalInputFinalizationDrifted
        | GoalInputReason::GoalInputFinalizationAmbiguous =>
          (true, Some("file PR"))
      }
    None => (false, None)
  }
}

///|
fn conductor_recovery_target(
  report : GoalStatusReport,
  part_target : String?,
) -> String? {
  match part_target {
    Some(_) => part_target
    None =>
      match report.publication_state {
        Some(BranchPublicationState::BranchPublicationPreflightUncertain)
        | Some(BranchPublicationState::BranchPublicationMutationUncertain) =>
          Some("publish")
        _ =>
          match report.assurance_stage {
            Some(GoalAssuranceStage::GoalAssuranceRecoveryUncertain) =>
              Some("assure")
            _ =>
              match report.pull_request_state {
                Some(PullRequestIntentState::PullRequestRemoteCreateUncertain) =>
                  Some("file PR")
                _ => None
              }
          }
      }
  }
}

///|
/// Statusline display decision for an active Goal. Terminal Goals produce no
/// display. This is the typed replacement for the binary's raw-JSON stage
/// and state tag matching.
///
/// `now` is a parameter because two of the things a reader is entitled to see
/// age: a surface deferral names an instant, and a provider observation stops
/// deferring a Part once its re-check schedule says so.
pub fn conductor_goal_display(
  report : GoalStatusReport,
  now : Int64,
) -> ConductorGoalDisplay? {
  if goal_execution_state_is_terminal(report.state) {
    return None
  }
  let maximum_parallel_parts = if report.maximum_parallel_parts > 0 {
    report.maximum_parallel_parts
  } else {
    1
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
  for part in report.parts {
    let part_id = if part.part_id.0 == "" { None } else { Some(part.part_id.0) }
    if report.parts.length() == 1 {
      single_part_id = part_id
    }
    match part.stage {
      PartWorkflowStage::PartImplementationSandboxPrepared
      | PartWorkflowStage::PartImplementationCommandPrepared
      | PartWorkflowStage::PartImplementationHarnessStarted
      | PartWorkflowStage::PartImplementationCompleted =>
        implementation = implementation + 1
      PartWorkflowStage::PartCandidateRecorded
      | PartWorkflowStage::PartVerificationSandboxPrepared =>
        verification = verification + 1
      PartWorkflowStage::PartVerified
      | PartWorkflowStage::PartAuditSandboxPrepared
      | PartWorkflowStage::PartAuditCommandPrepared
      | PartWorkflowStage::PartAuditHarnessStarted
      | PartWorkflowStage::PartAuditResultRecorded => audit = audit + 1
      PartWorkflowStage::PartAudited
      | PartWorkflowStage::PartIntegrationPlanned
      | PartWorkflowStage::PartPromotionPrepared
      | PartWorkflowStage::PartIntegrationAuthorized =>
        integration = integration + 1
      PartWorkflowStage::PartIntegrated => integrated = integrated + 1
      PartWorkflowStage::PartRecoveryUncertain => {
        recovery_count = recovery_count + 1
        if recovery_target is None {
          recovery_target = part_id
        }
      }
      PartWorkflowStage::PartBlocked => {
        blocked_count = blocked_count + 1
        if blocked_target is None {
          blocked_target = part_id
        }
      }
      _ => ()
    }
  }
  let (has_input, input_target) = conductor_input_request_target(report)
  let part_attention_count = recovery_count + blocked_count
  let (attention, attention_target, additional_attention) = if has_input {
    (
      Some(ConductorGoalAttention::ConductorAttentionNeedsInput),
      input_target,
      part_attention_count,
    )
  } else if recovery_count > 0 {
    (
      Some(ConductorGoalAttention::ConductorAttentionRecoveryUncertain),
      conductor_recovery_target(report, recovery_target),
      part_attention_count - 1,
    )
  } else if report.state == GoalExecutionState::GoalExecutionPaused &&
    report.pause_reason == Some(GoalPauseReason::GoalPauseRecoveryUncertain) {
    (
      Some(ConductorGoalAttention::ConductorAttentionRecoveryUncertain),
      conductor_recovery_target(report, None),
      blocked_count,
    )
  } else if blocked_count > 0 ||
    report.state == GoalExecutionState::GoalExecutionBlocked {
    (
      Some(ConductorGoalAttention::ConductorAttentionBlocked),
      blocked_target,
      if blocked_count > 0 {
        blocked_count - 1
      } else {
        0
      },
    )
  } else if report.state == GoalExecutionState::GoalExecutionPaused {
    (Some(ConductorGoalAttention::ConductorAttentionPaused), None, 0)
  } else if report.state == GoalExecutionState::GoalExecutionCanceling {
    (Some(ConductorGoalAttention::ConductorAttentionCanceling), None, 0)
  } else {
    (None, None, 0)
  }
  let phase = match report.state {
    GoalExecutionState::GoalExecutionAssuring =>
      ConductorGoalPhase::ConductorPhaseAssure
    GoalExecutionState::GoalExecutionAssured =>
      if report.publication_state ==
        Some(BranchPublicationState::BranchPublicationReceipted) {
        if report.pull_request_state ==
          Some(PullRequestIntentState::PullRequestReceipted) &&
          report.pull_request_delivery_policy
          .map(fn(policy) {
            policy.mode == @types.PullRequestDeliveryMode::PullRequestAutoMerge
          })
          .unwrap_or(false) {
          ConductorGoalPhase::ConductorPhaseMerge
        } else {
          ConductorGoalPhase::ConductorPhasePullRequest
        }
      } else {
        ConductorGoalPhase::ConductorPhasePublish
      }
    // A running Goal reports the furthest stage its Parts have reached. It
    // used to render as "queued" for the entire length of a Take, which reads
    // as "nothing has started" while a provider session is doing the work.
    GoalExecutionState::GoalExecutionRunning if report.parts.length() > 0 =>
      if integrated == report.parts.length() {
        ConductorGoalPhase::ConductorPhaseAssure
      } else if integration > 0 {
        ConductorGoalPhase::ConductorPhaseIntegrate
      } else if audit > 0 {
        ConductorGoalPhase::ConductorPhaseAudit
      } else if verification > 0 {
        ConductorGoalPhase::ConductorPhaseVerify
      } else if implementation > 0 {
        ConductorGoalPhase::ConductorPhaseImplement
      } else {
        ConductorGoalPhase::ConductorPhaseQueued
      }
    _ => ConductorGoalPhase::ConductorPhaseQueued
  }
  Some({
    maximum_parallel_parts,
    total_parts: report.parts.length(),
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
    spent_tokens: @control.take_usage_total_tokens(report.usage),
    capacity_pressure: report.provider_capacity.filter(
      provider_surface_is_pressured,
    ),
    provider_waiting: goal_parts_awaiting_provider(report, now),
  })
}

///|
/// What a WorkOrder has actually produced, counted from the durable Goal
/// report rather than from a running tally.
///
/// Every count is derived on read for the same reason the safety ceiling is:
/// an incremented counter and the durable state it claims to describe drift
/// apart the moment a crash lands between them, and the report is the thing a
/// reader is entitled to trust.
pub(all) struct WorkOrderPortfolio {
  /// The delivered-Bead quota this WorkOrder is working toward, when its stop
  /// policy names one.
  target : Int?
  /// The absolute instant work stops being admitted, when the policy names one.
  deadline : Int64?
  /// Reached the integration target. A Part that is integrated into the Goal
  /// branch but whose pull request has not merged is not delivered yet; it is
  /// counted as awaiting merge, because delivery is the merge.
  delivered : Int
  awaiting_merge : Int
  /// Started and not yet finished.
  active : Int
  /// Accepted and not yet started.
  eligible : Int
  /// Blocked on something the Part cannot resolve itself.
  failed : Int
  /// Recovery-uncertain: an effect may have occurred and cannot be observed.
  quarantined : Int
  skipped : Int
  /// Waiting on a provider surface that cannot serve yet, whether because the
  /// surface said so or because it is at its portfolio bound — see
  /// `goal_parts_awaiting_provider`, which is the one place either is decided.
  /// Counted separately from failed because the Part is fine and the surface
  /// is not.
  provider_deferred : Int
  /// Why the WorkOrder stopped, once it has.
  terminal_reason : WorkOrderStopReason?
} derive(Debug, Eq, ToJson, FromJson)

///|
fn work_order_stop_target(policy : WorkOrderStopPolicy) -> Int? {
  match policy {
    WorkOrderStopAtDeliveredQuota(_, count) => Some(count)
    WorkOrderStopAtFirstOf(policies) => {
      for policy in policies {
        match work_order_stop_target(policy) {
          Some(count) => return Some(count)
          None => ()
        }
      }
      None
    }
    _ => None
  }
}

///|
fn work_order_stop_deadline(policy : WorkOrderStopPolicy) -> Int64? {
  match policy {
    WorkOrderStopAtDeadline(instant) => Some(instant)
    WorkOrderStopAtFirstOf(policies) => {
      for policy in policies {
        match work_order_stop_deadline(policy) {
          Some(instant) => return Some(instant)
          None => ()
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Whether this Goal's delivery has actually landed.
///
/// `PullRequestReady` is the repository's own answer to that question, and it
/// is already delivery-mode aware: an auto-merge Goal is ready only once the
/// exact pull request is observed merged, while a review-only Goal is ready
/// once a non-draft pull request is open, because offering it for review is
/// the delivery. Re-deriving this from the merge state would get review-only
/// Goals wrong, and a merge that is only planned or authorized has not landed.
fn goal_delivery_has_landed(report : GoalStatusReport) -> Bool {
  match report.pull_request_state {
    // A Goal that never intended a pull request delivers by integration alone.
    None => true
    Some(_) =>
      report.readiness_decision
      is Some(PullRequestReadinessDecision::PullRequestReady)
  }
}

///|
/// Whether this Part's own surface has stopped admitting it, and no admitted
/// surface would take it instead.
///
/// The report is read against the same schedule the recovery decision uses, so
/// it stops counting a Part at the instant that Part becomes eligible again. A
/// schedule that could not be built is not itself a reason to report a Part as
/// waiting.
///
/// The failover branch is read rather than assumed: `plan_part_recovery_retry`
/// moves a Part whose surface reported a spent allowance onto another admitted
/// surface, and a Part with somewhere to go is not waiting. This asks
/// `select_admitted_provider_surface` the same question with the same
/// observations, so the two agree instead of this one over-counting.
fn part_awaits_provider_availability(
  part : GoalPartStatus,
  now : Int64,
) -> Bool {
  match (part.dispatch_diagnostic, part_provider_recheck_policy()) {
    (Some(diagnostic), Ok(policy)) =>
      if @control.provider_availability_admits_dispatch(
          diagnostic.availability,
          observed_at=diagnostic.observed_at,
          prior_deferrals=part_surface_prior_deferrals(
            part.provider_failovers,
            part.provider_surface,
          ),
          policy~,
          now~,
        ) {
        false
      } else {
        @control.select_admitted_provider_surface(
          part.provider_surface,
          part.admitted_provider_surfaces,
          part_surface_observations(part.provider_failovers),
          policy,
          now,
        )
        is None
      }
    _ => false
  }
}

///|
/// Whether this Part still has provider or planner work the admission gate
/// would have to authorize.
///
/// Exhaustive so a new stage has to decide: a stage left out would either
/// count a finished Part as waiting for a slot forever or hide one that is.
fn part_stage_awaits_provider(stage : PartWorkflowStage) -> Bool {
  match stage {
    PartWorkflowStage::PartIntegrated
    | PartWorkflowStage::PartCanceled
    | PartWorkflowStage::PartBlocked => false
    PartWorkflowStage::PartAccepted
    | PartWorkflowStage::PartImplementationSandboxPrepared
    | PartWorkflowStage::PartImplementationCommandPrepared
    | PartWorkflowStage::PartImplementationHarnessStarted
    | PartWorkflowStage::PartImplementationCompleted
    | PartWorkflowStage::PartCandidateRecorded
    | PartWorkflowStage::PartVerificationSandboxPrepared
    | PartWorkflowStage::PartVerified
    | PartWorkflowStage::PartAuditSandboxPrepared
    | PartWorkflowStage::PartAuditCommandPrepared
    | PartWorkflowStage::PartAuditHarnessStarted
    | PartWorkflowStage::PartAuditResultRecorded
    | PartWorkflowStage::PartAudited
    | PartWorkflowStage::PartIntegrationPlanned
    | PartWorkflowStage::PartPromotionPrepared
    | PartWorkflowStage::PartIntegrationAuthorized
    | PartWorkflowStage::PartRecoveryUncertain => true
  }
}

///|
/// Whether this Part would be dispatching if its surface had room.
///
/// Decided from the durable lease state the gate itself commits against: the
/// Part holds no slot, and the surface it runs on cannot serve another Take.
/// A Part that holds a slot is running on that surface, which is why a full
/// surface serving this Goal reads differently from one starving it.
fn part_awaits_provider_capacity(
  part : GoalPartStatus,
  capacity : Array[ProviderSurfaceCapacityStatus],
) -> Bool {
  if part.leased_provider_surface is Some(_) ||
    !part_stage_awaits_provider(part.stage) {
    return false
  }
  for status in capacity {
    if status.surface == part.provider_surface {
      return provider_surface_is_pressured(status)
    }
  }
  false
}

///|
/// How many of this Goal's Parts are waiting on a provider rather than working.
///
/// One count, two ways to be waiting, and neither is inferred: a surface that
/// reported it cannot serve (`dispatch_diagnostic`), and a surface at its
/// portfolio bound (the durable lease records the report carries). A Part
/// waiting for both reasons is counted once.
///
/// Capacity waiting is bounded by the Goal's own ceiling, which is what
/// decides how many of its Parts may dispatch at once. Parts queued behind
/// that ceiling are waiting on the Goal rather than on the surface, and
/// reporting them as provider-deferred would blame a full surface for a local
/// bound.
fn goal_parts_awaiting_provider(report : GoalStatusReport, now : Int64) -> Int {
  let mut waiting = 0
  let mut capacity_candidates = 0
  let mut leased = 0
  for part in report.parts {
    if part.leased_provider_surface is Some(_) {
      leased = leased + 1
    }
    if part_awaits_provider_availability(part, now) {
      waiting = waiting + 1
    } else if part_awaits_provider_capacity(part, report.provider_capacity) {
      capacity_candidates = capacity_candidates + 1
    }
  }
  let local_slots = report.maximum_parallel_parts - leased
  let admissible = if local_slots < 0 {
    0
  } else if capacity_candidates < local_slots {
    capacity_candidates
  } else {
    local_slots
  }
  waiting + admissible
}

///|
/// Project what a Goal's WorkOrder has produced, as of `now`.
pub fn work_order_portfolio(
  report : GoalStatusReport,
  now : Int64,
) -> WorkOrderPortfolio {
  let landed = goal_delivery_has_landed(report)
  let mut delivered = 0
  let mut awaiting_merge = 0
  let mut active = 0
  let mut eligible = 0
  let mut failed = 0
  let mut quarantined = 0
  let mut skipped = 0
  for part in report.parts {
    match part.stage {
      PartWorkflowStage::PartIntegrated =>
        if landed {
          delivered = delivered + 1
        } else {
          awaiting_merge = awaiting_merge + 1
        }
      PartWorkflowStage::PartAccepted => eligible = eligible + 1
      PartWorkflowStage::PartCanceled => skipped = skipped + 1
      PartWorkflowStage::PartBlocked => failed = failed + 1
      PartWorkflowStage::PartRecoveryUncertain => quarantined = quarantined + 1
      _ => active = active + 1
    }
  }
  {
    target: report.work_order.bind(fn(budget) {
      work_order_stop_target(budget.stop_policy)
    }),
    deadline: report.work_order.bind(fn(budget) {
      work_order_stop_deadline(budget.stop_policy)
    }),
    delivered,
    awaiting_merge,
    active,
    eligible,
    failed,
    quarantined,
    skipped,
    provider_deferred: goal_parts_awaiting_provider(report, now),
    terminal_reason: report.work_order.bind(fn(budget) { budget.stopped }),
  }
}

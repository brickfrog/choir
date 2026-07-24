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
/// Goal event. Terminal states must release the park: after success or
/// cancellation no further event will ever arrive. An unknown state parks,
/// matching the pre-observation default.
pub fn conductor_park_for_goal_state(state : GoalExecutionState?) -> Bool {
  match state {
    // Awaiting a human merge is not a durable event the Conductor should
    // sleep for: the park must release or the Stop hook would hold the
    // session hostage until someone merges the pull request.
    Some(GoalExecutionState::GoalExecutionAwaitingMerge) => false
    Some(value) => !goal_execution_state_is_terminal(value)
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
    ({
      "part_id": part.part_id.to_json(),
      "implementation_take_lifecycle": part.implementation_take_lifecycle.to_json(),
      "implementation_session_lifecycle": part.implementation_session_lifecycle.to_json(),
      "verification_take_lifecycle": part.verification_take_lifecycle.to_json(),
      "verification_session_lifecycle": part.verification_session_lifecycle.to_json(),
      "audit_take_lifecycle": part.audit_take_lifecycle.to_json(),
      "audit_session_lifecycle": part.audit_session_lifecycle.to_json(),
      "lifecycle": part.lifecycle.to_json(),
      "stage": part.stage.to_json(),
    } : Map[String, Json]).to_json()
  })
  ({
    "goal_id": report.goal_id.to_json(),
    "state": report.state.to_json(),
    "lifecycle": report.lifecycle.to_json(),
    "pause_reason": report.pause_reason.to_json(),
    "resume_state": report.resume_state.to_json(),
    "active_input_request": report.active_input_request.to_json(),
    "maximum_parallel_parts": report.maximum_parallel_parts.to_json(),
    "assurance_stage": report.assurance_stage.to_json(),
    "publication_state": report.publication_state.to_json(),
    "pull_request_state": report.pull_request_state.to_json(),
    "finalization_id": report.finalization_id.to_json(),
    "readiness_decision": report.readiness_decision.to_json(),
    "parts": parts.to_json(),
  } : Map[String, Json])
  .to_json()
  .stringify(indent=0)
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
  ConductorPhaseAwaitMerge
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
} derive(Debug, Eq)

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
                Some(
                  PullRequestIntentState::PullRequestRemoteCreateUncertain
                ) => Some("file PR")
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
pub fn conductor_goal_display(
  report : GoalStatusReport,
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
    let part_id = if part.part_id.0 == "" {
      None
    } else {
      Some(part.part_id.0)
    }
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
    GoalExecutionState::GoalExecutionAwaitingMerge =>
      ConductorGoalPhase::ConductorPhaseAwaitMerge
    GoalExecutionState::GoalExecutionAssured =>
      if report.publication_state ==
        Some(BranchPublicationState::BranchPublicationReceipted) {
        ConductorGoalPhase::ConductorPhasePullRequest
      } else {
        ConductorGoalPhase::ConductorPhasePublish
      }
    GoalExecutionState::GoalExecutionRunning if report.parts.length() > 0 &&
      integrated == report.parts.length() =>
      ConductorGoalPhase::ConductorPhaseAssure
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
  })
}

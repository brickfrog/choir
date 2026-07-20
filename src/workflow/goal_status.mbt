///|
pub(all) struct GoalPartStatus {
  workflow_id : String
  part_id : @control.PartId
  provider_surface : @control.ProviderSurfaceId
  implementation_take_id : @control.TakeId
  verification_take_id : @control.TakeId
  audit_take_id : @control.TakeId
  lifecycle : @control.PartLifecycle
  stage : PartWorkflowStage
  durable_version : Int
  harness_session_count : Int
  effect_receipt_count : Int
  verification_receipt_count : Int
  audit_receipt_present : Bool
  integration_receipt_present : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalStatusReport {
  goal_id : @control.GoalId
  state : GoalExecutionState
  lifecycle : @control.GoalLifecycle
  goal_ref : GitRefName
  integration_target_ref : GitRefName
  durable_version : Int
  maximum_parallel_parts : Int
  active_policy_revision : GoalPolicyRevision
  policy_revision_count : Int
  pause_reason : GoalPauseReason?
  resume_state : GoalExecutionState?
  active_input_request : GoalInputRequest?
  input_answer_count : Int
  assurance_stage : GoalAssuranceStage?
  goal_verification_take_id : @control.TakeId?
  goal_audit_take_id : @control.TakeId?
  goal_branch_seal : @control.GoalBranchSeal?
  assurance_sandbox_count : Int
  assurance_harness_session_count : Int
  assurance_effect_receipt_count : Int
  goal_verification_receipt_count : Int
  goal_audit_receipt_present : Bool
  publication_state : BranchPublicationState?
  publication_remote_repository_id : RemoteRepositoryId?
  publication_remote_head_ref : GitRefName?
  publication_receipt_present : Bool
  published_oid : @control.GitOid?
  pull_request_state : PullRequestIntentState?
  pull_request_receipt_present : Bool
  pull_request_number : PullRequestNumber?
  pull_request_url : PullRequestUrl?
  finalization_id : @control.FinalizationId?
  readiness_decision : PullRequestReadinessDecision?
  readiness_observation_sequence : Int64?
  parts : Array[GoalPartStatus]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum GoalTakeOrigin {
  GoalTakeFromPart(@control.PartId)
  GoalTakeFromAssurance
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAttachSession {
  session : @control.HarnessSession
  events : Array[@control.HarnessEventEnvelope]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalAttachReport {
  goal_id : @control.GoalId
  take : @control.Take
  origin : GoalTakeOrigin
  sessions : Array[GoalAttachSession]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn goal_attach_projection(
  goal_id : @control.GoalId,
  take : @control.Take,
  origin : GoalTakeOrigin,
  available_sessions : Array[@control.HarnessSession],
  available_events : Array[@control.HarnessEventEnvelope],
) -> Result[GoalAttachReport, @types.ChoirError] {
  if take.goal_id != goal_id {
    return Err(goal_execution_error("attach Take belongs to another Goal"))
  }
  let sessions : Array[GoalAttachSession] = []
  for session in available_sessions {
    if session.take_id == take.id {
      let events : Array[@control.HarnessEventEnvelope] = []
      for event in available_events {
        if event.take_id == take.id && event.session_id == session.id {
          events.push(event)
        }
      }
      events.sort_by(fn(left, right) {
        left.choir_sequence.0.compare(right.choir_sequence.0)
      })
      let mut expected_sequence = 1L
      for event in events {
        if event.choir_sequence.0 != expected_sequence {
          return Err(goal_execution_error("attach event journal has a gap"))
        }
        expected_sequence = expected_sequence + 1L
      }
      if session.last_choir_sequence.0 != expected_sequence - 1L {
        return Err(
          goal_execution_error("attach session cursor disagrees with events"),
        )
      }
      sessions.push({ session, events })
    }
  }
  sessions.sort_by(fn(left, right) { left.session.id.compare(right.session.id) })
  if sessions.length() == 0 {
    Err(goal_execution_error("attach Take has no registered harness session"))
  } else {
    Ok({ goal_id, take, origin, sessions })
  }
}

///|
pub fn goal_attach_report(
  record : GoalExecutionRecord,
  snapshots : Array[PartWorkflowSnapshot],
  assurance : GoalAssuranceRecord?,
  take_id : @control.TakeId,
) -> Result[GoalAttachReport?, @types.ChoirError] {
  let mut report : GoalAttachReport? = None
  for snapshot in snapshots {
    if snapshot.goal.id != record.goal.id ||
      snapshot.part.goal_id != record.goal.id {
      return Err(goal_execution_error("attach Part belongs to another Goal"))
    }
    for
      take in [
        snapshot.implementation_take,
        snapshot.verification_take,
        snapshot.audit_take,
      ] {
      if take.id == take_id {
        if report is Some(_) {
          return Err(goal_execution_error("attach Take identity is duplicated"))
        }
        let projection = match
          goal_attach_projection(
            record.goal.id,
            take,
            GoalTakeOrigin::GoalTakeFromPart(snapshot.part.id),
            snapshot.harness_sessions,
            snapshot.harness_events,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        report = Some(projection)
      }
    }
  }
  match assurance {
    Some(value) => {
      if value.goal_id != record.goal.id {
        return Err(
          goal_execution_error("attach assurance belongs to another Goal"),
        )
      }
      for take in [value.verification_take, value.audit_take] {
        if take.id == take_id {
          if report is Some(_) {
            return Err(
              goal_execution_error("attach Take identity is duplicated"),
            )
          }
          let projection = match
            goal_attach_projection(
              record.goal.id,
              take,
              GoalTakeOrigin::GoalTakeFromAssurance,
              value.harness_sessions,
              value.harness_events,
            ) {
            Ok(projection) => projection
            Err(error) => return Err(error)
          }
          report = Some(projection)
        }
      }
    }
    None => ()
  }
  Ok(report)
}

///|
pub fn goal_status_report(
  record : GoalExecutionRecord,
  snapshots : Array[PartWorkflowSnapshot],
  assurance : GoalAssuranceRecord?,
  publication : GoalPublicationRecord?,
  pull_request : GoalPullRequestRecord?,
  finalization : GoalFinalizationRecord?,
) -> Result[GoalStatusReport, @types.ChoirError] {
  if snapshots.length() != record.part_workflow_ids.length() {
    return Err(goal_execution_error("status Part cardinality is inconsistent"))
  }
  let parts : Array[GoalPartStatus] = []
  for workflow_id in record.part_workflow_ids {
    let mut matching : PartWorkflowSnapshot? = None
    for snapshot in snapshots {
      if snapshot.workflow_id == workflow_id {
        if matching is Some(_) {
          return Err(goal_execution_error("status contains a duplicate Part"))
        }
        matching = Some(snapshot)
      }
    }
    let snapshot = match matching {
      Some(value) => value
      None => return Err(goal_execution_error("status Part is absent"))
    }
    if snapshot.goal.id != record.goal.id ||
      snapshot.part.goal_id != record.goal.id {
      return Err(goal_execution_error("status Part belongs to another Goal"))
    }
    parts.push({
      workflow_id,
      part_id: snapshot.part.id,
      provider_surface: snapshot.identities.implementation_session.surface,
      implementation_take_id: snapshot.implementation_take.id,
      verification_take_id: snapshot.verification_take.id,
      audit_take_id: snapshot.audit_take.id,
      lifecycle: snapshot.part.lifecycle,
      stage: snapshot.stage,
      durable_version: snapshot.durable_version,
      harness_session_count: snapshot.harness_sessions.length(),
      effect_receipt_count: snapshot.effect_receipts.length(),
      verification_receipt_count: snapshot.verification_receipts.length(),
      audit_receipt_present: snapshot.audit_receipt is Some(_),
      integration_receipt_present: snapshot.integration_receipt is Some(_),
    })
  }
  match assurance {
    Some(value) if value.goal_id != record.goal.id =>
      return Err(goal_execution_error("assurance belongs to another Goal"))
    _ => ()
  }
  let assurance_status = match assurance {
    Some(value) =>
      (
        Some(value.stage),
        Some(value.verification_take.id),
        Some(value.audit_take.id),
        value.seal,
        value.sandbox_leases.length(),
        value.harness_sessions.length(),
        value.effect_receipts.length(),
        value.verification_receipts.length(),
        value.audit_receipt is Some(_),
      )
    None => (None, None, None, None, 0, 0, 0, 0, false)
  }
  match publication {
    Some(value) if value.goal_id != record.goal.id =>
      return Err(goal_execution_error("publication belongs to another Goal"))
    _ => ()
  }
  let publication_status = match publication {
    Some(value) =>
      (
        Some(value.intent.state),
        Some(value.intent.canonical_repository_id),
        Some(value.intent.remote_head_ref),
        value.receipt is Some(_),
        value.receipt.map(fn(receipt) { receipt.published_oid }),
      )
    None => (None, None, None, false, None)
  }
  match pull_request {
    Some(value) if value.goal_id != record.goal.id =>
      return Err(goal_execution_error("pull request belongs to another Goal"))
    _ => ()
  }
  let pull_request_status = match pull_request {
    Some(value) =>
      (
        Some(value.intent.state),
        value.receipt is Some(_),
        value.receipt.map(fn(receipt) { receipt.number }),
        value.receipt.map(fn(receipt) { receipt.url }),
      )
    None => (None, false, None, None)
  }
  match finalization {
    Some(value) if value.goal_id != record.goal.id =>
      return Err(goal_execution_error("finalization belongs to another Goal"))
    _ => ()
  }
  let finalization_status = match finalization {
    Some(value) =>
      (
        Some(value.readiness.finalization_id),
        Some(value.readiness.decision),
        Some(value.readiness.observation_sequence),
      )
    None => (None, None, None)
  }
  Ok({
    goal_id: record.goal.id,
    state: record.state,
    lifecycle: record.goal.lifecycle,
    goal_ref: record.goal_ref,
    integration_target_ref: record.integration_target_ref,
    durable_version: record.durable_version,
    maximum_parallel_parts: record.maximum_parallel_parts,
    active_policy_revision: record.policy_revisions[record.policy_revisions.length() -
    1],
    policy_revision_count: record.policy_revisions.length(),
    pause_reason: record.pause.map(fn(value) { value.reason }),
    resume_state: record.pause.map(fn(value) { value.resume_state }),
    active_input_request: record.active_input_request,
    input_answer_count: record.input_answers.length(),
    assurance_stage: assurance_status.0,
    goal_verification_take_id: assurance_status.1,
    goal_audit_take_id: assurance_status.2,
    goal_branch_seal: assurance_status.3,
    assurance_sandbox_count: assurance_status.4,
    assurance_harness_session_count: assurance_status.5,
    assurance_effect_receipt_count: assurance_status.6,
    goal_verification_receipt_count: assurance_status.7,
    goal_audit_receipt_present: assurance_status.8,
    publication_state: publication_status.0,
    publication_remote_repository_id: publication_status.1,
    publication_remote_head_ref: publication_status.2,
    publication_receipt_present: publication_status.3,
    published_oid: publication_status.4,
    pull_request_state: pull_request_status.0,
    pull_request_receipt_present: pull_request_status.1,
    pull_request_number: pull_request_status.2,
    pull_request_url: pull_request_status.3,
    finalization_id: finalization_status.0,
    readiness_decision: finalization_status.1,
    readiness_observation_sequence: finalization_status.2,
    parts,
  })
}

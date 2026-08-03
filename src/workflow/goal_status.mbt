///|
pub(all) struct GoalPartStatus {
  workflow_id : @control.WorkflowId
  part_id : @control.PartId
  provider_surface : @control.ProviderSurfaceId
  implementation_take_id : @control.TakeId
  implementation_take_lifecycle : @control.TakeLifecycle
  implementation_session_lifecycle : @control.HarnessSessionLifecycle?
  verification_take_id : @control.TakeId
  verification_take_lifecycle : @control.TakeLifecycle
  verification_session_lifecycle : @control.HarnessSessionLifecycle?
  audit_take_id : @control.TakeId
  audit_take_lifecycle : @control.TakeLifecycle
  audit_session_lifecycle : @control.HarnessSessionLifecycle?
  lifecycle : @control.PartLifecycle
  stage : PartWorkflowStage
  durable_version : Int
  harness_session_count : Int
  effect_receipt_count : Int
  verification_receipt_count : Int
  audit_receipt_present : Bool
  audit_total_findings_count : Int
  audit_blocking_findings_count : Int
  integration_receipt_present : Bool
  dispatch_diagnostic : PartDispatchDiagnostic?
  /// Every surface this Part moved to, and why. `provider_surface` reports
  /// where it runs now; this reports how it got there, so a changed provider
  /// is read rather than inferred.
  provider_failovers : Array[PartProviderFailover]
  /// Every surface this Part's captured contract allows it to run on. Carried
  /// because a Part refused by its current surface is not waiting when another
  /// admitted surface would take it — the recovery decision moves it instead,
  /// and a report without this set cannot tell those apart.
  admitted_provider_surfaces : Array[@control.ProviderSurfaceId]
  /// The provider surface this Part holds a portfolio slot on right now, read
  /// from the durable lease record. `Some` means this Part is dispatching, so
  /// a full surface is one it is being served by rather than blocked on.
  leased_provider_surface : @control.ProviderSurfaceId?
  /// What this Part's provider sessions reported consuming. Background Takes
  /// spend the user's paid subscription allowance, so the cost of a Goal is
  /// reportable rather than invisible.
  usage : @control.TakeUsage
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Sum what every provider session on this Part reported. Sessions that
/// reported nothing contribute nothing rather than being estimated.
pub fn part_reported_usage(
  snapshot : PartWorkflowSnapshot,
) -> @control.TakeUsage {
  let mut total = @control.empty_take_usage()
  for session in snapshot.harness_sessions {
    match session.usage {
      Some(usage) if @control.validate_take_usage(usage) =>
        total = @control.add_take_usage(total, usage)
      _ => ()
    }
  }
  total
}

///|
fn goal_part_session_lifecycle(
  snapshot : PartWorkflowSnapshot,
  session_id : @control.HarnessSessionId,
) -> @control.HarnessSessionLifecycle? {
  for session in snapshot.harness_sessions {
    if session.id == session_id {
      return Some(session.lifecycle)
    }
  }
  None
}

///|
pub(all) struct SemanticDependencyEdge {
  part_id : @control.PartId
  dependency_id : @control.PartId
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SemanticVerificationResult {
  verification_spec_id : @control.VerificationSpecId
  verification_spec_digest : @control.Digest
  outcome : @control.VerificationOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SemanticPartResult {
  part_id : @control.PartId
  task_contract_digest : @control.Digest
  candidate_change_digest : @control.Digest
  verification_results : Array[SemanticVerificationResult]
  audit_policy_digest : @control.Digest
  audit_outcome : @control.AuditOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SemanticPromotionResult {
  part_id : @control.PartId
  rank : Int
  resulting_tree_oid : @control.GitOid
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SemanticReceiptCardinalities {
  part_verification : Int
  part_audit : Int
  integration : Int
  goal_verification : Int
  goal_audit : Int
  publication : Int
  pull_request : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SemanticRunProjection {
  accepted_part_ids : Array[@control.PartId]
  dependency_edges : Array[SemanticDependencyEdge]
  ordered_parts : Array[SemanticPartResult]
  promotions : Array[SemanticPromotionResult]
  final_tree_oid : @control.GitOid
  goal_verification_results : Array[SemanticVerificationResult]
  combined_audit_policy_digest : @control.Digest
  combined_audit_outcome : @control.AuditOutcome
  receipt_cardinalities : SemanticReceiptCardinalities
  terminal_goal_outcome : GoalExecutionState
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ProviderSurfaceUsageStatus {
  surface : @control.ProviderSurfaceId
  usage : @control.TakeUsage?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalListStatus {
  goal_id : @control.GoalId
  state : GoalExecutionState
  lifecycle : @control.GoalLifecycle
  durable_version : Int
  part_ids : Array[@control.PartId]
  goal_ref : GitRefName
  work_order_id : WorkOrderId?
  cancellation_cause : GoalCancellationCause?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct GoalListReport {
  goals : Array[GoalListStatus]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn goal_list_report(records : Array[GoalExecutionRecord]) -> GoalListReport {
  let goals = records.map(fn(record) {
    {
      goal_id: record.goal.id,
      state: record.state,
      lifecycle: record.goal.lifecycle,
      durable_version: record.durable_version,
      part_ids: record.source_claims.map(fn(claim) { claim.part_id }),
      goal_ref: record.goal_ref,
      work_order_id: record.work_order_id,
      cancellation_cause: record.cancellation_request.map(fn(request) {
        request.cause
      }),
    }
  })
  { goals, }
}

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
  assurance_block_reason : GoalAssuranceBlockReason?
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
  pull_request_delivery_policy : @types.PullRequestDeliveryPolicy?
  pull_request_merge_state : PullRequestMergeState?
  pull_request_receipt_present : Bool
  pull_request_number : PullRequestNumber?
  pull_request_url : PullRequestUrl?
  /// Requested presentation state from the Goal's pull request document.
  pull_request_draft : Bool?
  finalization_id : @control.FinalizationId?
  readiness_decision : PullRequestReadinessDecision?
  /// Draft state of the exact remote pull request at the last observation, so
  /// awaiting-review never has to be inferred from pull request text.
  readiness_observed_draft : Bool?
  readiness_observation_sequence : Int64?
  /// The WorkOrder budget this Goal runs under, when it has one, so a reader
  /// sees the target and deadline the counts are measured against.
  work_order_id : WorkOrderId?
  work_order : WorkOrderBudget?
  /// Why this Goal was canceled, carried as the durable typed cause rather
  /// than prose. Every variant but a user request names the evidence digest
  /// the decision was made from, so a reader never has to reconstruct why a
  /// Goal stopped from surrounding state.
  cancellation_cause : GoalCancellationCause?
  /// When the cancellation cutoff was installed, so a report can be ordered
  /// against the event stream it cut.
  cancellation_cutoff_sequence : @control.EventSequence?
  /// What every provider-backed Part and Goal-assurance session reported
  /// consuming. Missing observations contribute nothing to this aggregate so
  /// existing readers keep their historical best-known-total behavior.
  usage : @control.TakeUsage
  /// Usage attributed to the surface recorded on each harness session. A
  /// surface is present only when it owns a session, and its observation is
  /// unknown when any one of those sessions omitted usage.
  provider_usage : Array[ProviderSurfaceUsageStatus]
  /// What each provider surface is holding against its configured bound, on
  /// the same reporting path as `usage`: the cost of this Goal and the
  /// pressure it is competing for are read from one report rather than two.
  /// Empty in a projection built without a capacity observation, which claims
  /// nothing rather than reporting a bound it did not read.
  provider_capacity : Array[ProviderSurfaceCapacityStatus]
  semantic_run_projection : SemanticRunProjection?
  parts : Array[GoalPartStatus]
} derive(Debug, Eq, ToJson, FromJson)

///|
fn goal_usage_can_add(
  left : @control.TakeUsage,
  right : @control.TakeUsage,
) -> Bool {
  let maximum = 2147483647
  right.input_tokens <= maximum - left.input_tokens &&
  right.output_tokens <= maximum - left.output_tokens &&
  right.cache_read_tokens <= maximum - left.cache_read_tokens &&
  right.cache_creation_tokens <= maximum - left.cache_creation_tokens &&
  right.wall_time_ms <= maximum - left.wall_time_ms
}

///|
fn goal_reported_usage(
  snapshots : Array[PartWorkflowSnapshot],
  assurance : GoalAssuranceRecord?,
) -> Result[
  (@control.TakeUsage, Array[ProviderSurfaceUsageStatus]),
  @types.ChoirError,
] {
  let sessions : Array[@control.HarnessSession] = []
  for snapshot in snapshots {
    for session in snapshot.harness_sessions {
      sessions.push(session)
    }
  }
  match assurance {
    Some(value) =>
      for session in value.harness_sessions {
        sessions.push(session)
      }
    None => ()
  }
  let seen : Array[@control.HarnessSessionId] = []
  let mut aggregate = @control.empty_take_usage()
  let mut claude = @control.empty_take_usage()
  let mut codex = @control.empty_take_usage()
  let mut claude_sessions = 0
  let mut codex_sessions = 0
  let mut claude_complete = true
  let mut codex_complete = true
  for session in sessions {
    if seen.contains(session.id) {
      return Err(
        goal_execution_error("status contains a duplicate harness session"),
      )
    }
    seen.push(session.id)
    match session.surface {
      @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
        claude_sessions = claude_sessions + 1
      @control.ProviderSurfaceId::CodexSubscriptionCli =>
        codex_sessions = codex_sessions + 1
    }
    match session.usage {
      Some(usage) => {
        if !@control.validate_take_usage(usage) {
          return Err(goal_execution_error("status contains invalid usage"))
        }
        if !goal_usage_can_add(aggregate, usage) {
          return Err(goal_execution_error("status usage sum is invalid"))
        }
        aggregate = @control.add_take_usage(aggregate, usage)
        match session.surface {
          @control.ProviderSurfaceId::ClaudeSubscriptionCli => {
            if !goal_usage_can_add(claude, usage) {
              return Err(goal_execution_error("status usage sum is invalid"))
            }
            claude = @control.add_take_usage(claude, usage)
          }
          @control.ProviderSurfaceId::CodexSubscriptionCli => {
            if !goal_usage_can_add(codex, usage) {
              return Err(goal_execution_error("status usage sum is invalid"))
            }
            codex = @control.add_take_usage(codex, usage)
          }
        }
      }
      None =>
        match session.surface {
          @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
            claude_complete = false
          @control.ProviderSurfaceId::CodexSubscriptionCli =>
            codex_complete = false
        }
    }
  }
  let provider_usage : Array[ProviderSurfaceUsageStatus] = []
  if claude_sessions > 0 {
    provider_usage.push({
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
      usage: if claude_complete {
        Some(claude)
      } else {
        None
      },
    })
  }
  if codex_sessions > 0 {
    provider_usage.push({
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      usage: if codex_complete {
        Some(codex)
      } else {
        None
      },
    })
  }
  Ok((aggregate, provider_usage))
}

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
  if sessions.length() == 0 &&
    !(take.purpose is @control.TakePurpose::PartVerification(_, _, _) ||
    take.purpose is @control.TakePurpose::GoalVerification(_, _, _)) {
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
fn semantic_part_verification_results(
  snapshot : PartWorkflowSnapshot,
) -> Result[Array[SemanticVerificationResult], @types.ChoirError] {
  let results : Array[SemanticVerificationResult] = []
  for slot in snapshot.verification_slots {
    let receipt_id = match slot.authorizing_receipt_id {
      Some(value) => value
      None =>
        return Err(
          goal_execution_error(
            "semantic projection has an unauthorized Part verification slot",
          ),
        )
    }
    let matches = snapshot.verification_receipts.filter(fn(receipt) {
      receipt.receipt_id == receipt_id &&
      receipt.verification_spec == slot.verification_spec
    })
    if matches.length() != 1 ||
      matches[0].outcome != @control.VerificationOutcome::VerificationPassed {
      return Err(
        goal_execution_error(
          "semantic projection has an invalid Part verification result",
        ),
      )
    }
    results.push({
      verification_spec_id: slot.verification_spec.id,
      verification_spec_digest: slot.verification_spec.digest,
      outcome: matches[0].outcome,
    })
  }
  results.sort_by(fn(left, right) {
    left.verification_spec_id.compare(right.verification_spec_id)
  })
  if results.length() == 0 {
    Err(goal_execution_error("semantic projection has no Part verification"))
  } else {
    Ok(results)
  }
}

///|
fn semantic_goal_verification_results(
  assurance : GoalAssuranceRecord,
) -> Result[Array[SemanticVerificationResult], @types.ChoirError] {
  let results : Array[SemanticVerificationResult] = []
  for slot in assurance.verification_slots {
    let receipt_id = match slot.authorizing_receipt_id {
      Some(value) => value
      None =>
        return Err(
          goal_execution_error(
            "semantic projection has an unauthorized Goal verification slot",
          ),
        )
    }
    let matches = assurance.verification_receipts.filter(fn(receipt) {
      receipt.receipt_id == receipt_id &&
      receipt.verification_spec == slot.verification_spec
    })
    if matches.length() != 1 ||
      matches[0].outcome != @control.VerificationOutcome::VerificationPassed {
      return Err(
        goal_execution_error(
          "semantic projection has an invalid Goal verification result",
        ),
      )
    }
    results.push({
      verification_spec_id: slot.verification_spec.id,
      verification_spec_digest: slot.verification_spec.digest,
      outcome: matches[0].outcome,
    })
  }
  results.sort_by(fn(left, right) {
    left.verification_spec_id.compare(right.verification_spec_id)
  })
  if results.length() == 0 {
    Err(goal_execution_error("semantic projection has no Goal verification"))
  } else {
    Ok(results)
  }
}

///|
fn semantic_snapshot_for_part(
  snapshots : Array[PartWorkflowSnapshot],
  part_id : @control.PartId,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  let matches = snapshots.filter(fn(snapshot) { snapshot.part.id == part_id })
  if matches.length() == 1 {
    Ok(matches[0])
  } else {
    Err(
      goal_execution_error(
        "semantic projection Part identity is absent or duplicated",
      ),
    )
  }
}

///|
pub fn semantic_run_projection(
  record : GoalExecutionRecord,
  snapshots : Array[PartWorkflowSnapshot],
  assurance : GoalAssuranceRecord?,
  publication : GoalPublicationRecord?,
  pull_request : GoalPullRequestRecord?,
  finalization : GoalFinalizationRecord?,
) -> Result[SemanticRunProjection?, @types.ChoirError] {
  if record.state != GoalExecutionState::GoalExecutionSucceeded {
    return Ok(None)
  }
  guard record.goal.lifecycle is @control.GoalLifecycle::GoalSucceeded(_) &&
    assurance is Some(assurance) &&
    publication is Some(publication) &&
    pull_request is Some(pull_request) &&
    finalization is Some(finalization) &&
    assurance.stage == GoalAssuranceStage::GoalAudited &&
    assurance.seal is Some(seal) &&
    assurance.audit_receipt is Some(goal_audit) &&
    publication.intent.state ==
    BranchPublicationState::BranchPublicationReceipted &&
    publication.receipt is Some(publication_receipt) &&
    pull_request.intent.state == PullRequestIntentState::PullRequestReceipted &&
    pull_request.receipt is Some(pull_request_receipt) &&
    finalization.readiness.decision ==
    PullRequestReadinessDecision::PullRequestReady else {
    return Err(
      goal_execution_error(
        "successful Goal lacks complete semantic projection evidence",
      ),
    )
  }
  if snapshots.length() == 0 ||
    snapshots.length() != record.part_workflow_ids.length() ||
    assurance.goal_id != record.goal.id ||
    publication.goal_id != record.goal.id ||
    pull_request.goal_id != record.goal.id ||
    finalization.goal_id != record.goal.id ||
    assurance.repository_id != record.repository_id ||
    publication.repository_id != record.repository_id ||
    pull_request.repository_id != record.repository_id ||
    finalization.repository_id != record.repository_id ||
    assurance.goal_contract_digest != record.goal.contract_digest ||
    publication.goal_contract_digest != record.goal.contract_digest ||
    pull_request.goal_contract_digest != record.goal.contract_digest ||
    finalization.goal_contract_digest != record.goal.contract_digest ||
    assurance.integration_receipts.length() < snapshots.length() ||
    snapshots.any(fn(snapshot) {
      !assurance.integration_receipts.any(fn(receipt) {
        receipt.part_id == snapshot.part.id
      })
    }) ||
    seal.head_oid != publication_receipt.published_oid ||
    seal.head_oid != pull_request_receipt.expected_head_oid ||
    publication.intent.goal_branch_seal_id != seal.id ||
    publication.intent.goal_branch_seal_digest != seal.seal_digest ||
    pull_request.intent.goal_branch_seal_id != seal.id ||
    pull_request.intent.goal_branch_seal_digest != seal.seal_digest ||
    pull_request.intent.combined_audit_receipt_id != goal_audit.receipt_id ||
    finalization.readiness.pull_request_receipt_id !=
    pull_request_receipt.receipt_id ||
    finalization.readiness.goal_branch_seal_id != seal.id ||
    finalization.readiness.goal_branch_seal_digest != seal.seal_digest ||
    @control.audit_findings_admission(
      goal_audit.outcome,
      goal_audit.blocking_findings_count,
    )
    is Some(_) {
    return Err(
      goal_execution_error("successful Goal semantic evidence is inconsistent"),
    )
  }
  let accepted_part_ids = snapshots.map(fn(snapshot) { snapshot.part.id })
  accepted_part_ids.sort()
  for index = 0; index < accepted_part_ids.length(); index = index + 1 {
    if index > 0 && accepted_part_ids[index - 1] == accepted_part_ids[index] {
      return Err(
        goal_execution_error("semantic projection contains a duplicate Part"),
      )
    }
  }
  let dependency_edges : Array[SemanticDependencyEdge] = []
  for workflow_id in record.part_workflow_ids {
    if snapshots
      .filter(fn(snapshot) { snapshot.workflow_id == workflow_id })
      .length() !=
      1 {
      return Err(
        goal_execution_error(
          "semantic projection workflow identity is absent or duplicated",
        ),
      )
    }
  }
  for snapshot in snapshots {
    if snapshot.goal.id != record.goal.id ||
      snapshot.part.goal_id != record.goal.id ||
      !(snapshot.part.lifecycle is @control.PartLifecycle::PartIntegrated(_)) {
      return Err(
        goal_execution_error(
          "semantic projection contains a nonintegrated Part",
        ),
      )
    }
    for dependency_id in snapshot.part.dependency_ids {
      if !accepted_part_ids.contains(dependency_id) {
        return Err(
          goal_execution_error(
            "semantic projection contains an unknown dependency",
          ),
        )
      }
      dependency_edges.push({ part_id: snapshot.part.id, dependency_id })
    }
  }
  dependency_edges.sort_by(fn(left, right) {
    let by_part = left.part_id.compare(right.part_id)
    if by_part == 0 {
      left.dependency_id.compare(right.dependency_id)
    } else {
      by_part
    }
  })
  let ordered_parts : Array[SemanticPartResult] = []
  let promotions : Array[SemanticPromotionResult] = []
  let mut part_verification_count = 0
  let mut expected_head = record.base_commit_oid
  for rank, integration in assurance.integration_receipts {
    let snapshot = match
      semantic_snapshot_for_part(snapshots, integration.part_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    guard snapshot.candidate is Some(candidate) &&
      snapshot.audit_receipt is Some(audit) &&
      snapshot.integration_receipt == Some(integration) &&
      integration.from_head_oid == expected_head &&
      candidate.id == integration.candidate_id &&
      candidate.commit_oid == integration.candidate_commit_oid &&
      candidate.tree_oid == integration.candidate_tree_oid &&
      @control.audit_findings_admission(
        audit.outcome,
        audit.blocking_findings_count,
      )
      is None else {
      return Err(
        goal_execution_error(
          "semantic projection Part evidence is inconsistent",
        ),
      )
    }
    let verification = match semantic_part_verification_results(snapshot) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    part_verification_count = part_verification_count + verification.length()
    ordered_parts.push({
      part_id: snapshot.part.id,
      task_contract_digest: snapshot.task_contract.digest,
      candidate_change_digest: candidate.canonical_change_digest,
      verification_results: verification,
      audit_policy_digest: audit.audit_policy_digest,
      audit_outcome: audit.outcome,
    })
    promotions.push({
      part_id: snapshot.part.id,
      rank: rank + 1,
      resulting_tree_oid: integration.promotion_tree_oid,
    })
    expected_head = integration.promotion_commit_oid
  }
  if expected_head != seal.head_oid ||
    promotions[promotions.length() - 1].resulting_tree_oid != seal.tree_oid {
    return Err(
      goal_execution_error("semantic projection final tree is inconsistent"),
    )
  }
  let goal_verification = match semantic_goal_verification_results(assurance) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(
    Some({
      accepted_part_ids,
      dependency_edges,
      ordered_parts,
      promotions,
      final_tree_oid: seal.tree_oid,
      goal_verification_results: goal_verification,
      combined_audit_policy_digest: goal_audit.audit_policy_digest,
      combined_audit_outcome: goal_audit.outcome,
      receipt_cardinalities: {
        part_verification: part_verification_count,
        part_audit: snapshots.length(),
        integration: assurance.integration_receipts.length(),
        goal_verification: assurance.verification_slots.length(),
        goal_audit: 1,
        publication: 1,
        pull_request: 1,
      },
      terminal_goal_outcome: record.state,
    }),
  )
}

///|
/// `provider_capacity` is the portfolio's lease state as this reader observed
/// it, and `None` is a legitimate answer: a process that holds no capacity
/// policy — a one-shot CLI, a conformance harness — reports no bound rather
/// than a default one it never read.
pub fn goal_status_report(
  record : GoalExecutionRecord,
  snapshots : Array[PartWorkflowSnapshot],
  assurance : GoalAssuranceRecord?,
  publication : GoalPublicationRecord?,
  pull_request : GoalPullRequestRecord?,
  finalization : GoalFinalizationRecord?,
  work_order? : WorkOrderBudget? = None,
  provider_capacity~ : ProviderCapacityObservation?,
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
      implementation_take_lifecycle: snapshot.implementation_take.lifecycle,
      implementation_session_lifecycle: goal_part_session_lifecycle(
        snapshot,
        snapshot.identities.implementation_session.id,
      ),
      verification_take_id: snapshot.verification_take.id,
      verification_take_lifecycle: snapshot.verification_take.lifecycle,
      verification_session_lifecycle: None,
      audit_take_id: snapshot.audit_take.id,
      audit_take_lifecycle: snapshot.audit_take.lifecycle,
      audit_session_lifecycle: goal_part_session_lifecycle(
        snapshot,
        snapshot.identities.audit_session.id,
      ),
      lifecycle: snapshot.part.lifecycle,
      stage: snapshot.stage,
      durable_version: snapshot.durable_version,
      harness_session_count: snapshot.harness_sessions.length(),
      effect_receipt_count: snapshot.effect_receipts.length(),
      verification_receipt_count: snapshot.verification_receipts.length(),
      audit_receipt_present: snapshot.audit_receipt is Some(_),
      audit_total_findings_count: match snapshot.audit_receipt {
        Some(receipt) => receipt.total_findings_count
        None => 0
      },
      audit_blocking_findings_count: match snapshot.audit_receipt {
        Some(receipt) => receipt.blocking_findings_count
        None => 0
      },
      integration_receipt_present: snapshot.integration_receipt is Some(_),
      dispatch_diagnostic: snapshot.dispatch_diagnostic,
      provider_failovers: snapshot.provider_failovers,
      admitted_provider_surfaces: snapshot.admitted_provider_surfaces,
      leased_provider_surface: match provider_capacity {
        Some(observation) =>
          part_leased_provider_surface(
            observation,
            record.goal.id,
            snapshot.part.id,
          )
        None => None
      },
      usage: part_reported_usage(snapshot),
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
  let assurance_block_reason = match assurance {
    Some(value) => value.blocked_reason
    None => None
  }
  let usage_status = match goal_reported_usage(snapshots, assurance) {
    Ok(value) => value
    Err(error) => return Err(error)
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
        Some(value.intent.delivery_policy),
        Some(value.intent.merge_state),
        value.receipt is Some(_),
        value.receipt.map(fn(receipt) { receipt.number }),
        value.receipt.map(fn(receipt) { receipt.url }),
        Some(value.intent.document.draft),
      )
    None => (None, None, None, false, None, None, None)
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
        value.readiness.observed_draft,
        Some(value.readiness.observation_sequence),
      )
    None => (None, None, None, None)
  }
  let semantic_run_projection = match
    semantic_run_projection(
      record, snapshots, assurance, publication, pull_request, finalization,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
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
    assurance_block_reason,
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
    pull_request_delivery_policy: pull_request_status.1,
    pull_request_merge_state: pull_request_status.2,
    pull_request_receipt_present: pull_request_status.3,
    pull_request_number: pull_request_status.4,
    pull_request_url: pull_request_status.5,
    pull_request_draft: pull_request_status.6,
    finalization_id: finalization_status.0,
    readiness_decision: finalization_status.1,
    readiness_observed_draft: finalization_status.2,
    readiness_observation_sequence: finalization_status.3,
    work_order_id: record.work_order_id,
    work_order,
    cancellation_cause: record.cancellation_request.map(fn(request) {
      request.cause
    }),
    cancellation_cutoff_sequence: record.cancellation_request.map(fn(request) {
      request.cutoff_sequence
    }),
    usage: usage_status.0,
    provider_usage: usage_status.1,
    provider_capacity: match provider_capacity {
      Some(observation) => provider_surface_capacity_statuses(observation)
      None => []
    },
    semantic_run_projection,
    parts,
  })
}

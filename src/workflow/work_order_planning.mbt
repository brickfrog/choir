///|
pub(all) struct WorkOrderPlanningRoundId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct WorkOrderPlanningEffectId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum WorkOrderPlanningPhase {
  WorkOrderPlanningIntentRecorded
  WorkOrderPlanningDispatched
  WorkOrderPlanningProposalReceived
  WorkOrderPlanningBeadsDelivering
  WorkOrderPlanningBeadsDelivered
  WorkOrderPlanningGoalReady
  WorkOrderPlanningRoundTerminal
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum WorkOrderPlanningFailure {
  WorkOrderPlannerProviderFailed(@control.Digest)
  WorkOrderPlannerArtifactMismatch
  WorkOrderPlannerRepositorySnapshotDrift
  WorkOrderPlannerBeadSnapshotDrift
  WorkOrderPlannerScopeEscape(String)
  WorkOrderPlannerDuplicateIdentity(String)
  WorkOrderPlannerMissingDependency(String, String)
  WorkOrderPlannerDependencyCycle(Array[String])
  WorkOrderPlannerOwnershipDrift(String)
  WorkOrderPlannerContradictoryContract(String, String)
  WorkOrderPlannerRepeatedEmptyProposal
  WorkOrderPlannerCyclicRediscovery(@control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum WorkOrderPlanningOutcome {
  WorkOrderPlanningPending
  WorkOrderPlanningProposalAccepted
  WorkOrderPlanningNoEligibleWork
  WorkOrderPlanningNoFurtherFindings
  WorkOrderPlanningFailed(WorkOrderPlanningFailure)
  WorkOrderPlanningQuarantined(WorkOrderPlanningFailure)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WorkOrderPlanningFinding {
  summary : String
  evidence : String
  related_bead_ids : Array[@control.PartId]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WorkOrderPlanningProposal {
  findings : Array[WorkOrderPlanningFinding]
  eligible_work_observed : Bool
  bead_mutations : @command.BeadBatchProposal
  primary_target_ids : Array[@control.PartId]
  prerequisite_closure_ids : Array[@control.PartId]
  finite_goal : ConductorGoalDraft?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WorkOrderPlanningRound {
  id : WorkOrderPlanningRoundId
  work_order_id : WorkOrderId
  sequence : Int
  repository_snapshot_digest : @control.Digest
  bead_snapshot_digest : @control.Digest
  effect_id : WorkOrderPlanningEffectId
  planner_surface : @control.ProviderSurfaceId
  phase : WorkOrderPlanningPhase
  proposal_artifact : @control.ArtifactReference?
  proposal_digest : @control.Digest?
  bead_batch_digest : @control.Digest?
  delivered_bead_snapshot_digest : @control.Digest?
  empty_response_count : Int
  provider_failure_count : Int
  outcome : WorkOrderPlanningOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
fn work_order_planning_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("WorkOrder planning: " + detail)
}

///|
pub fn validate_work_order_planning_round(
  round : WorkOrderPlanningRound,
) -> Result[Unit, @types.ChoirError] {
  if round.sequence <= 0 ||
    round.id !=
    work_order_planning_round_id(round.work_order_id, round.sequence) ||
    round.effect_id != work_order_planning_effect_id(round.id) {
    return Err(work_order_planning_error("round identity is invalid"))
  }
  if @storage.validate_digest(round.repository_snapshot_digest) is Err(_) ||
    @storage.validate_digest(round.bead_snapshot_digest) is Err(_) ||
    round.empty_response_count < 0 ||
    round.provider_failure_count < 0 {
    return Err(work_order_planning_error("round evidence is invalid"))
  }
  match (round.proposal_artifact, round.proposal_digest) {
    (None, None) => ()
    (Some(artifact), Some(digest)) if artifact.digest == digest => ()
    _ => return Err(work_order_planning_error("proposal receipt is invalid"))
  }
  match round.bead_batch_digest {
    Some(digest) =>
      if @storage.validate_digest(digest) is Err(_) {
        return Err(work_order_planning_error("Bead batch digest is invalid"))
      }
    None => ()
  }
  match round.delivered_bead_snapshot_digest {
    Some(digest) =>
      if @storage.validate_digest(digest) is Err(_) {
        return Err(work_order_planning_error("delivered snapshot is invalid"))
      }
    None => ()
  }
  match (round.phase, round.outcome) {
    (WorkOrderPlanningRoundTerminal, WorkOrderPlanningPending)
    | (WorkOrderPlanningRoundTerminal, WorkOrderPlanningProposalAccepted) =>
      Err(work_order_planning_error("terminal round has nonterminal outcome"))
    (_, WorkOrderPlanningFailed(_) | WorkOrderPlanningQuarantined(_)) if round.phase !=
      WorkOrderPlanningRoundTerminal =>
      Err(work_order_planning_error("terminal outcome has nonterminal phase"))
    _ => Ok(())
  }
}

///|
let work_order_planner_failure_limit : Int = 3

///|
let work_order_planner_empty_limit : Int = 3

///|
fn replace_current_work_order_round(
  record : WorkOrderRecord,
  round : WorkOrderPlanningRound,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  guard record.planning_rounds.last() is Some(current) &&
    current.id == round.id &&
    current.sequence == round.sequence else {
    return Err(work_order_planning_error("round is not current"))
  }
  let rounds = record.planning_rounds.copy()
  rounds[rounds.length() - 1] = round
  Ok({
    ..record,
    planning_rounds: rounds,
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn work_order_planning_round_id(
  work_order_id : WorkOrderId,
  sequence : Int,
) -> WorkOrderPlanningRoundId {
  WorkOrderPlanningRoundId(
    "work-order-round-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode(
          "choir.work-order-planning-round.v1\u{00}" +
          work_order_id.0 +
          "\u{00}" +
          sequence.to_string(),
        ),
      ),
    ),
  )
}

///|
pub fn work_order_planning_effect_id(
  round_id : WorkOrderPlanningRoundId,
) -> WorkOrderPlanningEffectId {
  WorkOrderPlanningEffectId(
    "work-order-planner-effect-" +
    @storage.digest_text(@storage.artifact_digest(@utf8.encode(round_id.0))),
  )
}

///|
pub fn plan_work_order_round(
  record : WorkOrderRecord,
  repository_snapshot_digest : @control.Digest,
  bead_snapshot_digest : @control.Digest,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  if record.lifecycle != WorkOrderLifecycle::WorkOrderActive {
    return Err(work_order_planning_error("WorkOrder is not active"))
  }
  if record.child_goals.any(fn(binding) {
      binding.outcome == WorkOrderChildOutcome::WorkOrderChildActive
    }) {
    return Err(
      work_order_planning_error("an active child Goal still owns work"),
    )
  }
  if @storage.validate_digest(repository_snapshot_digest) is Err(_) ||
    @storage.validate_digest(bead_snapshot_digest) is Err(_) {
    return Err(work_order_planning_error("snapshot digest is invalid"))
  }
  let sequence = record.planning_rounds.length() + 1
  let id = work_order_planning_round_id(record.id, sequence)
  let round : WorkOrderPlanningRound = {
    id,
    work_order_id: record.id,
    sequence,
    repository_snapshot_digest,
    bead_snapshot_digest,
    effect_id: work_order_planning_effect_id(id),
    planner_surface: record.planner.primary_surface,
    phase: WorkOrderPlanningPhase::WorkOrderPlanningIntentRecorded,
    proposal_artifact: None,
    proposal_digest: None,
    bead_batch_digest: None,
    delivered_bead_snapshot_digest: None,
    empty_response_count: 0,
    provider_failure_count: 0,
    outcome: WorkOrderPlanningOutcome::WorkOrderPlanningPending,
  }
  Ok({
    ..record,
    planning_rounds: record.planning_rounds + [round],
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn dispatch_work_order_planning_round(
  record : WorkOrderRecord,
  now : Int64,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  guard record.planning_rounds.last() is Some(round) &&
    round.phase == WorkOrderPlanningPhase::WorkOrderPlanningIntentRecorded &&
    round.outcome == WorkOrderPlanningOutcome::WorkOrderPlanningPending else {
    return Err(work_order_planning_error("round is not dispatchable"))
  }
  let budget = record_work_order_agentic_take(record.budget)
  match work_order_admits_new_work(budget, now) {
    WorkOrderAdmission::WorkOrderExhausted(reason) =>
      Ok({
        ..record,
        budget: { ..budget, stopped: Some(reason) },
        lifecycle: WorkOrderLifecycle::WorkOrderStopped(reason),
        durable_version: record.durable_version + 1,
      })
    WorkOrderAdmission::WorkOrderAdmitsNewWork =>
      replace_current_work_order_round({ ..record, budget, }, {
        ..round,
        phase: WorkOrderPlanningPhase::WorkOrderPlanningDispatched,
      })
  }
}

///|
pub fn record_work_order_planner_failure(
  record : WorkOrderRecord,
  failure_digest : @control.Digest,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  if @storage.validate_digest(failure_digest) is Err(_) {
    return Err(work_order_planning_error("provider failure digest is invalid"))
  }
  guard record.planning_rounds.last() is Some(round) &&
    round.phase == WorkOrderPlanningPhase::WorkOrderPlanningDispatched else {
    return Err(work_order_planning_error("round is not dispatched"))
  }
  let failures = round.provider_failure_count + 1
  if failures >= work_order_planner_failure_limit {
    return replace_current_work_order_round(record, {
      ..round,
      provider_failure_count: failures,
      phase: WorkOrderPlanningPhase::WorkOrderPlanningRoundTerminal,
      outcome: WorkOrderPlanningOutcome::WorkOrderPlanningQuarantined(
        WorkOrderPlanningFailure::WorkOrderPlannerProviderFailed(failure_digest),
      ),
    })
  }
  let surfaces = [record.planner.primary_surface] +
    record.planner.failover_surfaces
  let surface = surfaces[failures % surfaces.length()]
  replace_current_work_order_round(record, {
    ..round,
    provider_failure_count: failures,
    planner_surface: surface,
    phase: WorkOrderPlanningPhase::WorkOrderPlanningIntentRecorded,
    outcome: WorkOrderPlanningOutcome::WorkOrderPlanningPending,
  })
}

///|
pub fn record_empty_work_order_planner_response(
  record : WorkOrderRecord,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  guard record.planning_rounds.last() is Some(round) &&
    round.phase == WorkOrderPlanningPhase::WorkOrderPlanningDispatched else {
    return Err(work_order_planning_error("round is not dispatched"))
  }
  let empties = round.empty_response_count + 1
  if empties >= work_order_planner_empty_limit {
    replace_current_work_order_round(record, {
      ..round,
      empty_response_count: empties,
      phase: WorkOrderPlanningPhase::WorkOrderPlanningRoundTerminal,
      outcome: WorkOrderPlanningOutcome::WorkOrderPlanningQuarantined(
        WorkOrderPlanningFailure::WorkOrderPlannerRepeatedEmptyProposal,
      ),
    })
  } else {
    replace_current_work_order_round(record, {
      ..round,
      empty_response_count: empties,
      phase: WorkOrderPlanningPhase::WorkOrderPlanningIntentRecorded,
    })
  }
}

///|
pub fn work_order_planning_proposal_bytes(
  proposal : WorkOrderPlanningProposal,
) -> Bytes {
  @utf8.encode(proposal.to_json().stringify(indent=0))
}

///|
pub fn decode_work_order_planning_proposal(
  content : Bytes,
) -> Result[WorkOrderPlanningProposal, @types.ChoirError] {
  let json = @json.parse(@utf8.decode(content)) catch {
    _ => return Err(work_order_planning_error("proposal is not valid JSON"))
  }
  let proposal : WorkOrderPlanningProposal = @json.from_json(json) catch {
    _ => return Err(work_order_planning_error("proposal shape is invalid"))
  }
  if proposal.findings.any(fn(finding) {
      finding.summary.trim().to_owned() == "" ||
      finding.evidence.trim().to_owned() == ""
    }) {
    return Err(work_order_planning_error("finding is incomplete"))
  }
  match (proposal.eligible_work_observed, proposal.finite_goal) {
    (true, None) =>
      Err(work_order_planning_error("eligible work has no finite Goal"))
    (false, Some(_)) =>
      Err(work_order_planning_error("ineligible work carries a Goal"))
    (true, Some(goal)) =>
      if goal.work_order is Some(_) || goal.parts.length() == 0 {
        Err(work_order_planning_error("finite Goal is invalid"))
      } else {
        Ok(proposal)
      }
    (false, None) => Ok(proposal)
  }
}

///|
fn planning_failure_from_bead_verdict(
  verdict : @command.BeadItemVerdict,
) -> WorkOrderPlanningFailure? {
  match verdict.outcome {
    @command.BeadItemOutcome::BeadItemAdmitted
    | @command.BeadItemOutcome::BeadItemAlreadyApplied
    | @command.BeadItemOutcome::BeadItemPartiallyApplied(_) => None
    @command.BeadItemOutcome::BeadItemDuplicateIdentity =>
      Some(WorkOrderPlannerDuplicateIdentity(verdict.id))
    @command.BeadItemOutcome::BeadItemRepeatedInBatch =>
      Some(WorkOrderPlannerDuplicateIdentity(verdict.id))
    @command.BeadItemOutcome::BeadItemUnknownTarget =>
      Some(WorkOrderPlannerOwnershipDrift(verdict.id))
    @command.BeadItemOutcome::BeadItemMissingDependency(dependency) =>
      Some(WorkOrderPlannerMissingDependency(verdict.id, dependency))
    @command.BeadItemOutcome::BeadItemSelfDependency =>
      Some(WorkOrderPlannerDependencyCycle([verdict.id, verdict.id]))
    @command.BeadItemOutcome::BeadItemDependencyCycle(cycle) =>
      Some(WorkOrderPlannerDependencyCycle(cycle))
    @command.BeadItemOutcome::BeadItemOwnershipDrift(_, _) =>
      Some(WorkOrderPlannerOwnershipDrift(verdict.id))
    @command.BeadItemOutcome::BeadItemContradictoryContract(detail) =>
      Some(WorkOrderPlannerContradictoryContract(verdict.id, detail))
  }
}

///|
test "every rejected Bead verdict has a typed planning failure" {
  let rejected : Array[@command.BeadItemOutcome] = [
    BeadItemDuplicateIdentity,
    BeadItemRepeatedInBatch,
    BeadItemUnknownTarget,
    BeadItemMissingDependency("missing"),
    BeadItemSelfDependency,
    BeadItemDependencyCycle(["a", "b", "a"]),
    BeadItemOwnershipDrift("before", "after"),
    BeadItemContradictoryContract("contradiction"),
  ]
  for outcome in rejected {
    assert_true(
      planning_failure_from_bead_verdict({ id: "bead", outcome }) is Some(_),
    )
  }
  for
    outcome in [
      @command.BeadItemOutcome::BeadItemAdmitted,
      @command.BeadItemOutcome::BeadItemAlreadyApplied,
      @command.BeadItemOutcome::BeadItemPartiallyApplied(["edge"]),
    ] {
    assert_true(
      planning_failure_from_bead_verdict({ id: "bead", outcome }) is None,
    )
  }
}

///|
pub fn validate_work_order_planning_proposal(
  record : WorkOrderRecord,
  round : WorkOrderPlanningRound,
  proposal : WorkOrderPlanningProposal,
  observed_repository_snapshot_digest : @control.Digest,
  observed_bead_snapshot_digest : @control.Digest,
  existing_beads : Array[@command.BeadRecord],
) -> WorkOrderPlanningFailure? {
  if observed_repository_snapshot_digest != round.repository_snapshot_digest {
    return Some(WorkOrderPlannerRepositorySnapshotDrift)
  }
  if observed_bead_snapshot_digest != round.bead_snapshot_digest {
    return Some(WorkOrderPlannerBeadSnapshotDrift)
  }
  match proposal.finite_goal {
    Some(goal) =>
      if goal.goal_id.0 == "" ||
        goal.parts.any(fn(part) {
          !(proposal.primary_target_ids.contains(part.part_id) ||
          proposal.prerequisite_closure_ids.contains(part.part_id))
        }) {
        return Some(WorkOrderPlannerScopeEscape("finite Goal selection"))
      }
    None => ()
  }
  let verdicts = @command.reconcile_bead_batch(
    proposal.bead_mutations,
    existing_beads,
  )
  for verdict in verdicts {
    match planning_failure_from_bead_verdict(verdict) {
      Some(failure) => return Some(failure)
      None => ()
    }
  }
  let digest = @storage.artifact_digest(
    work_order_planning_proposal_bytes(proposal),
  )
  if record.planning_rounds.any(fn(previous) {
      previous.sequence != round.sequence &&
      previous.proposal_digest == Some(digest)
    }) {
    return Some(WorkOrderPlannerCyclicRediscovery(digest))
  }
  None
}

///|
pub fn record_work_order_planning_proposal(
  record : WorkOrderRecord,
  artifact : @control.ArtifactReference,
  content : Bytes,
  observed_repository_snapshot_digest : @control.Digest,
  observed_bead_snapshot_digest : @control.Digest,
  existing_beads : Array[@command.BeadRecord],
  now : Int64,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  if content.length() == 0 {
    return record_empty_work_order_planner_response(record)
  }
  guard record.planning_rounds.last() is Some(round) &&
    round.phase == WorkOrderPlanningPhase::WorkOrderPlanningDispatched else {
    return Err(work_order_planning_error("round is not dispatched"))
  }
  let digest = @storage.artifact_digest(content)
  if digest != artifact.digest {
    return replace_current_work_order_round(record, {
      ..round,
      phase: WorkOrderPlanningPhase::WorkOrderPlanningRoundTerminal,
      outcome: WorkOrderPlanningOutcome::WorkOrderPlanningFailed(
        WorkOrderPlanningFailure::WorkOrderPlannerArtifactMismatch,
      ),
    })
  }
  let proposal = match decode_work_order_planning_proposal(content) {
    Ok(value) => value
    Err(error) =>
      return replace_current_work_order_round(record, {
        ..round,
        proposal_artifact: Some(artifact),
        proposal_digest: Some(digest),
        phase: WorkOrderPlanningPhase::WorkOrderPlanningRoundTerminal,
        outcome: WorkOrderPlanningOutcome::WorkOrderPlanningFailed(
          WorkOrderPlanningFailure::WorkOrderPlannerContradictoryContract(
            "proposal",
            error.message(),
          ),
        ),
      })
  }
  match
    validate_work_order_planning_proposal(
      record, round, proposal, observed_repository_snapshot_digest, observed_bead_snapshot_digest,
      existing_beads,
    ) {
    Some(failure) =>
      return replace_current_work_order_round(record, {
        ..round,
        proposal_artifact: Some(artifact),
        proposal_digest: Some(digest),
        phase: WorkOrderPlanningPhase::WorkOrderPlanningRoundTerminal,
        outcome: WorkOrderPlanningOutcome::WorkOrderPlanningFailed(failure),
      })
    None => ()
  }
  let counted_record = {
    ..record,
    budget: record_work_order_round(
      record.budget,
      proposal.eligible_work_observed,
      proposal.findings.length() > 0,
    ),
  }
  if !proposal.eligible_work_observed {
    let stopped_budget = record_work_order_stop(counted_record.budget, now)
    let terminal_record = match stopped_budget.stopped {
      Some(reason) =>
        {
          ..counted_record,
          budget: stopped_budget,
          lifecycle: WorkOrderLifecycle::WorkOrderStopped(reason),
        }
      None => { ..counted_record, budget: stopped_budget }
    }
    let outcome = if proposal.findings.length() == 0 {
      WorkOrderPlanningOutcome::WorkOrderPlanningNoFurtherFindings
    } else {
      WorkOrderPlanningOutcome::WorkOrderPlanningNoEligibleWork
    }
    return replace_current_work_order_round(terminal_record, {
      ..round,
      proposal_artifact: Some(artifact),
      proposal_digest: Some(digest),
      bead_batch_digest: Some(
        @command.bead_batch_digest(proposal.bead_mutations),
      ),
      phase: WorkOrderPlanningPhase::WorkOrderPlanningRoundTerminal,
      outcome,
    })
  }
  replace_current_work_order_round(counted_record, {
    ..round,
    proposal_artifact: Some(artifact),
    proposal_digest: Some(digest),
    bead_batch_digest: Some(@command.bead_batch_digest(proposal.bead_mutations)),
    phase: WorkOrderPlanningPhase::WorkOrderPlanningProposalReceived,
    outcome: WorkOrderPlanningOutcome::WorkOrderPlanningProposalAccepted,
  })
}

///|
pub fn begin_work_order_bead_delivery(
  record : WorkOrderRecord,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  guard record.planning_rounds.last() is Some(round) &&
    round.phase == WorkOrderPlanningPhase::WorkOrderPlanningProposalReceived &&
    round.bead_batch_digest is Some(_) else {
    return Err(work_order_planning_error("proposal is not deliverable"))
  }
  replace_current_work_order_round(record, {
    ..round,
    phase: WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivering,
  })
}

///|
pub fn complete_work_order_bead_delivery(
  record : WorkOrderRecord,
  delivered_digest : @control.Digest,
  delivered_bead_snapshot_digest : @control.Digest,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  guard record.planning_rounds.last() is Some(round) &&
    round.phase == WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivering &&
    round.bead_batch_digest == Some(delivered_digest) else {
    return Err(work_order_planning_error("Bead delivery receipt disagrees"))
  }
  if @storage.validate_digest(delivered_bead_snapshot_digest) is Err(_) {
    return Err(work_order_planning_error("delivered snapshot is invalid"))
  }
  replace_current_work_order_round(record, {
    ..round,
    delivered_bead_snapshot_digest: Some(delivered_bead_snapshot_digest),
    phase: WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivered,
  })
}

///|
/// Decide what a terminal planning round means for the campaign.
///
/// Stable no-work policies require more than one exact observation, so a
/// non-stopping no-work round authorizes another round against a fresh caller
/// snapshot. Provider and validation exhaustion instead latches a typed
/// terminal reason; an active WorkOrder must never remain parked forever on a
/// terminal round.
pub fn continue_work_order_after_terminal_round(
  record : WorkOrderRecord,
  repository_snapshot_digest : @control.Digest,
  bead_snapshot_digest : @control.Digest,
) -> Result[WorkOrderRecord, @types.ChoirError] {
  guard record.lifecycle == WorkOrderLifecycle::WorkOrderActive &&
    !record.child_goals.any(fn(binding) {
      binding.outcome == WorkOrderChildOutcome::WorkOrderChildActive
    }) &&
    record.planning_rounds.last() is Some(round) &&
    round.phase == WorkOrderPlanningPhase::WorkOrderPlanningRoundTerminal else {
    return Err(work_order_planning_error("terminal round is not continuable"))
  }
  match round.outcome {
    WorkOrderPlanningOutcome::WorkOrderPlanningNoEligibleWork
    | WorkOrderPlanningOutcome::WorkOrderPlanningNoFurtherFindings =>
      match record.budget.stopped {
        Some(reason) =>
          Ok({
            ..record,
            lifecycle: WorkOrderLifecycle::WorkOrderStopped(reason),
            durable_version: record.durable_version + 1,
          })
        None =>
          plan_work_order_round(
            record, repository_snapshot_digest, bead_snapshot_digest,
          )
      }
    WorkOrderPlanningOutcome::WorkOrderPlanningFailed(failure)
    | WorkOrderPlanningOutcome::WorkOrderPlanningQuarantined(failure) => {
      let budget = record_work_order_planner_stop(record.budget, failure)
      guard budget.stopped is Some(reason) else {
        return Err(work_order_planning_error("planner stop did not latch"))
      }
      Ok({
        ..record,
        budget,
        lifecycle: WorkOrderLifecycle::WorkOrderStopped(reason),
        durable_version: record.durable_version + 1,
      })
    }
    WorkOrderPlanningOutcome::WorkOrderPlanningPending
    | WorkOrderPlanningOutcome::WorkOrderPlanningProposalAccepted =>
      Err(work_order_planning_error("terminal round outcome is invalid"))
  }
}

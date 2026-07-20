///|
pub(all) struct MultiPartConformanceReport {
  passed : Bool
  initial_admission_count : Int
  running_conflict_deferred : Bool
  promotion_count : Int
  promotion_head_chain_valid : Bool
  failure : String?
} derive(Debug, Eq, ToJson)

///|
let scheduling_fixture_digest : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
fn scheduling_fixture_record(
  id : String,
  dependencies : Array[@control.PartId],
  lifecycle : @control.PartLifecycle,
  mutation : @control.MutationDeclaration,
) -> @workflow.GoalPartSchedulingRecord {
  let goal_id = @control.GoalId("goal-scheduling-conformance")
  let part_id = @control.PartId(id)
  let revision_id = @control.RevisionId("revision-" + id)
  {
    part: {
      id: part_id,
      goal_id,
      dependency_ids: dependencies,
      task_contract_revision_id: revision_id,
      lifecycle,
    },
    task_contract: {
      id: revision_id,
      goal_id,
      part_id,
      revision: 1,
      digest: scheduling_fixture_digest,
      base_commit_oid: @control.GitOid("goal-head"),
      base_tree_oid: @control.GitOid("goal-tree"),
      path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
      mutation_declaration: mutation,
      verification_specs: [],
      audit_policy_digest: scheduling_fixture_digest,
      implementation_capability_profile_digest: scheduling_fixture_digest,
      verification_capability_profile_digest: scheduling_fixture_digest,
      audit_capability_profile_digest: scheduling_fixture_digest,
    },
  }
}

///|
fn failed_multi_part_report(message : String) -> MultiPartConformanceReport {
  {
    passed: false,
    initial_admission_count: 0,
    running_conflict_deferred: false,
    promotion_count: 0,
    promotion_head_chain_valid: false,
    failure: Some(message),
  }
}

///|
pub fn run_multi_part_conformance_fixture() -> MultiPartConformanceReport {
  let shared = @control.MutationDeclaration::CompleteMutationDeclaration([
    @control.MutationClaim::ExactPath(@control.RepoPath("src/shared.mbt")),
  ])
  let isolated = @control.MutationDeclaration::CompleteMutationDeclaration([
    @control.MutationClaim::ExactPath(@control.RepoPath("src/isolated.mbt")),
  ])
  let part_a = scheduling_fixture_record(
    "a",
    [],
    @control.PartLifecycle::PartPending,
    isolated,
  )
  let part_b = scheduling_fixture_record(
    "b",
    [],
    @control.PartLifecycle::PartPending,
    shared,
  )
  let part_c = scheduling_fixture_record(
    "c",
    [part_a.part.id],
    @control.PartLifecycle::PartPending,
    shared,
  )
  let initial = match
    @workflow.schedule_goal_parts([part_c, part_b, part_a], 2) {
    Ok(value) => value
    Err(error) => return failed_multi_part_report(error.message())
  }
  let permuted = match
    @workflow.schedule_goal_parts([part_a, part_c, part_b], 2) {
    Ok(value) => value
    Err(error) => return failed_multi_part_report(error.message())
  }
  if initial.admitted_part_ids != [part_a.part.id, part_b.part.id] ||
    permuted.admitted_part_ids != initial.admitted_part_ids {
    return failed_multi_part_report("initial admission was not deterministic")
  }
  let integrated_a = {
    ..part_a,
    part: {
      ..part_a.part,
      lifecycle: @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId("integration-a"),
      ),
    },
  }
  let executing_b = {
    ..part_b,
    part: {
      ..part_b.part,
      lifecycle: @control.PartLifecycle::PartExecuting(
        @control.TakeId("take-b"),
      ),
    },
  }
  let conflict_schedule = match
    @workflow.schedule_goal_parts([part_c, executing_b, integrated_a], 2) {
    Ok(value) => value
    Err(error) => return failed_multi_part_report(error.message())
  }
  let conflict_deferred = conflict_schedule.decisions.any(fn(decision) {
    decision.part_id == part_c.part.id &&
    decision.admission ==
    @workflow.GoalPartAdmission::GoalPartDeferredByMutationConflict([
      part_b.part.id,
    ])
  })
  if !conflict_deferred {
    return failed_multi_part_report(
      "running mutation reservation did not defer the dependent Part",
    )
  }
  let audited = fn(
    record : @workflow.GoalPartSchedulingRecord,
  ) -> @workflow.GoalPartSchedulingRecord {
    {
      ..record,
      part: {
        ..record.part,
        lifecycle: @control.PartLifecycle::PartAudited(
          @control.CandidateId("candidate-" + part_id_text(record.part.id)),
          scheduling_fixture_digest,
          @control.ReceiptId("audit-" + part_id_text(record.part.id)),
        ),
      },
    }
  }
  let audited_a = audited(part_a)
  let audited_b = audited(part_b)
  let audited_c = audited(part_c)
  let first = match
    @workflow.select_next_deterministic_promotion(
      [audited_c, audited_b, audited_a],
      @control.GitOid("goal-head"),
    ) {
    Ok(Some(value)) => value
    _ => return failed_multi_part_report("first promotion rank was absent")
  }
  let promoted_a = {
    ..audited_a,
    part: {
      ..audited_a.part,
      lifecycle: @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId("integration-a"),
      ),
    },
  }
  let second = match
    @workflow.select_next_deterministic_promotion(
      [audited_c, audited_b, promoted_a],
      @control.GitOid("promotion-a"),
    ) {
    Ok(Some(value)) => value
    _ => return failed_multi_part_report("second promotion rank was absent")
  }
  let promoted_b = {
    ..audited_b,
    part: {
      ..audited_b.part,
      lifecycle: @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId("integration-b"),
      ),
    },
  }
  let third = match
    @workflow.select_next_deterministic_promotion(
      [audited_c, promoted_b, promoted_a],
      @control.GitOid("promotion-b"),
    ) {
    Ok(Some(value)) => value
    _ => return failed_multi_part_report("third promotion rank was absent")
  }
  let valid_chain = first.part_id == part_a.part.id &&
    first.expected_goal_head_oid == @control.GitOid("goal-head") &&
    second.part_id == part_b.part.id &&
    second.expected_goal_head_oid == @control.GitOid("promotion-a") &&
    third.part_id == part_c.part.id &&
    third.expected_goal_head_oid == @control.GitOid("promotion-b")
  if !valid_chain {
    return failed_multi_part_report("promotion head chain was not stable")
  }
  {
    passed: true,
    initial_admission_count: initial.admitted_part_ids.length(),
    running_conflict_deferred: conflict_deferred,
    promotion_count: 3,
    promotion_head_chain_valid: valid_chain,
    failure: None,
  }
}

///|
fn part_id_text(id : @control.PartId) -> String {
  guard id is @control.PartId(value) else { return "" }
  value
}

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
pub(all) struct GeneratedDagConformanceReport {
  graph_count : Int
  schedule_run_count : Int
  promotion_run_count : Int
  part_evaluation_count : Int
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
      instruction_artifact: {
        artifact_id: "instruction-" + id,
        digest: scheduling_fixture_digest,
      },
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

///|
fn generated_fixture_part_id(index : Int) -> @control.PartId {
  @control.PartId("generated-part-" + index.to_string())
}

///|
fn generated_fixture_mutation(
  seed : Int,
  index : Int,
) -> @control.MutationDeclaration {
  let group = (seed + index * 7) % 6
  let path_group = (seed + index) % 4
  match group {
    0 =>
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(
          @control.RepoPath(
            "src/group-" +
            path_group.to_string() +
            "/part-" +
            index.to_string() +
            ".mbt",
          ),
        ),
      ])
    1 =>
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::PathTree(
          @control.RepoPath("src/group-" + path_group.to_string()),
        ),
      ])
    2 =>
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(
          @control.RepoPath("shared/generated.lock"),
        ),
      ])
    3 => @control.MutationDeclaration::CompleteMutationDeclaration([])
    4 =>
      @control.MutationDeclaration::UnknownMutationDeclaration(
        @control.UnknownMutationReason::GeneratedOutputsUnknown,
      )
    _ => @control.MutationDeclaration::MissingMutationDeclaration
  }
}

///|
fn generated_fixture_records(
  seed : Int,
  count : Int,
) -> Array[@workflow.GoalPartSchedulingRecord] {
  let records : Array[@workflow.GoalPartSchedulingRecord] = []
  for index = 0; index < count; index = index + 1 {
    let dependencies : Array[@control.PartId] = []
    if index > 0 && (seed + index) % 3 != 0 {
      dependencies.push(generated_fixture_part_id(index - 1))
    }
    if index > 3 && (seed + index * 3) % 5 == 0 {
      let earlier = generated_fixture_part_id(index - 3)
      if !dependencies.contains(earlier) {
        dependencies.push(earlier)
      }
    }
    records.push(
      scheduling_fixture_record(
        generated_fixture_part_id(index).0,
        dependencies,
        @control.PartLifecycle::PartPending,
        generated_fixture_mutation(seed, index),
      ),
    )
  }
  records
}

///|
fn fixture_record_by_id(
  records : Array[@workflow.GoalPartSchedulingRecord],
  part_id : @control.PartId,
) -> @workflow.GoalPartSchedulingRecord? {
  for record in records {
    if record.part.id == part_id {
      return Some(record)
    }
  }
  None
}

///|
fn replace_fixture_lifecycle(
  records : Array[@workflow.GoalPartSchedulingRecord],
  part_id : @control.PartId,
  lifecycle : @control.PartLifecycle,
) -> Array[@workflow.GoalPartSchedulingRecord] {
  records.map(fn(record) {
    if record.part.id == part_id {
      { ..record, part: { ..record.part, lifecycle, } }
    } else {
      record
    }
  })
}

///|
fn generated_admission_failure(
  records : Array[@workflow.GoalPartSchedulingRecord],
  admitted_part_ids : Array[@control.PartId],
  maximum_parallel_parts : Int,
) -> String? {
  if admitted_part_ids.length() > maximum_parallel_parts {
    return Some("generated schedule exceeded its concurrency limit")
  }
  for index, part_id in admitted_part_ids {
    let record = match fixture_record_by_id(records, part_id) {
      Some(value) => value
      None => return Some("generated schedule admitted an unknown Part")
    }
    for dependency_id in record.part.dependency_ids {
      match fixture_record_by_id(records, dependency_id) {
        Some(
          {
            part: { lifecycle: @control.PartLifecycle::PartIntegrated(_), .. },
            ..,
          }
        ) => ()
        Some(_) =>
          return Some(
            "generated schedule admitted before dependency integration",
          )
        None => return Some("generated schedule lost a dependency")
      }
    }
    for other_index = index + 1
        other_index < admitted_part_ids.length()
        other_index = other_index + 1 {
      let other = match
        fixture_record_by_id(records, admitted_part_ids[other_index]) {
        Some(value) => value
        None => return Some("generated schedule admitted an unknown Part")
      }
      if @control.mutation_declarations_conflict(
          record.task_contract.mutation_declaration,
          other.task_contract.mutation_declaration,
        ) {
        return Some("generated schedule admitted conflicting Parts")
      }
    }
  }
  None
}

///|
fn generated_dag_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "generated DAG conformance failed: " + detail,
  )
}

///|
fn complete_generated_fixture(
  source : Array[@workflow.GoalPartSchedulingRecord],
  maximum_parallel_parts : Int,
) -> Result[Array[@control.PartId], @types.ChoirError] {
  let mut records = source
  let admission_order : Array[@control.PartId] = []
  let mut remaining = records.length()
  while remaining > 0 {
    let schedule = match
      @workflow.schedule_goal_parts(records, maximum_parallel_parts) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if schedule.admitted_part_ids.length() == 0 {
      return Err(generated_dag_error("acyclic schedule made no progress"))
    }
    match
      generated_admission_failure(
        records,
        schedule.admitted_part_ids,
        maximum_parallel_parts,
      ) {
      Some(message) => return Err(generated_dag_error(message))
      None => ()
    }
    for part_id in schedule.admitted_part_ids {
      admission_order.push(part_id)
      records = replace_fixture_lifecycle(
        records,
        part_id,
        @control.PartLifecycle::PartIntegrated(
          @control.ReceiptId("generated-integration-" + part_id.0),
        ),
      )
      remaining = remaining - 1
    }
  }
  Ok(admission_order)
}

///|
fn generated_fixture_promotion_order(
  source : Array[@workflow.GoalPartSchedulingRecord],
) -> Result[Array[@control.PartId], @types.ChoirError] {
  let mut records = source.map(fn(record) {
    {
      ..record,
      part: {
        ..record.part,
        lifecycle: @control.PartLifecycle::PartAudited(
          @control.CandidateId("generated-candidate-" + record.part.id.0),
          scheduling_fixture_digest,
          @control.ReceiptId("generated-audit-" + record.part.id.0),
        ),
      },
    }
  })
  let order : Array[@control.PartId] = []
  while order.length() < records.length() {
    let selection = match
      @workflow.select_next_deterministic_promotion(
        records,
        @control.GitOid("generated-head-" + order.length().to_string()),
      ) {
      Ok(Some(value)) => value
      Ok(None) =>
        return Err(generated_dag_error("promotion order made no progress"))
      Err(error) => return Err(error)
    }
    order.push(selection.part_id)
    records = replace_fixture_lifecycle(
      records,
      selection.part_id,
      @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId("generated-integration-" + selection.part_id.0),
      ),
    )
  }
  Ok(order)
}

///|
pub fn run_generated_dag_conformance_fixture() -> Result[
  GeneratedDagConformanceReport,
  @types.ChoirError,
] {
  let mut graph_count = 0
  let mut schedule_run_count = 0
  let mut promotion_run_count = 0
  let mut part_evaluation_count = 0
  for seed in [3, 7, 19, 31] {
    let records = generated_fixture_records(seed, 17)
    let reversed = records.copy()
    reversed.sort_by(fn(left, right) { right.part.id.compare(left.part.id) })
    graph_count = graph_count + 1
    let forward_promotion = match generated_fixture_promotion_order(records) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let reversed_promotion = match generated_fixture_promotion_order(reversed) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    promotion_run_count = promotion_run_count + 2
    part_evaluation_count = part_evaluation_count + records.length() * 2
    if forward_promotion != reversed_promotion {
      return Err(
        generated_dag_error("promotion order changed with input permutation"),
      )
    }
    for maximum_parallel_parts in [1, 2, 4, 7] {
      let forward = match
        complete_generated_fixture(records, maximum_parallel_parts) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let backward = match
        complete_generated_fixture(reversed, maximum_parallel_parts) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      schedule_run_count = schedule_run_count + 2
      part_evaluation_count = part_evaluation_count + records.length() * 2
      if forward != backward || forward.length() != records.length() {
        return Err(
          generated_dag_error("admission order changed with input permutation"),
        )
      }
    }
  }
  Ok({
    graph_count,
    schedule_run_count,
    promotion_run_count,
    part_evaluation_count,
  })
}

///|
pub fn scheduler_generated_dags_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("scheduler.generated_dags"),
    run: fn(_) {
      let report = match run_generated_dag_conformance_fixture() {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok({
        evidence: [
          ObservedGeneratedDagSuite(
            report.graph_count,
            report.schedule_run_count,
            report.promotion_run_count,
            report.part_evaluation_count,
          ),
        ],
      })
    },
  }
}

///|
let selection_fixture_digest : @control.Digest = @control.Digest(
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
)

///|
fn selection_fixture_source(
  id : String,
  dependencies : Array[@control.PartId],
  state : @workflow.SelectionSourceState,
) -> @workflow.GoalSelectionSourcePart {
  {
    part_id: @control.PartId(id),
    source_revision_digest: selection_fixture_digest,
    dependency_ids: dependencies,
    state,
  }
}

///|
fn selection_fixture_part(
  goal_id : @control.GoalId,
  id : String,
  dependencies : Array[@control.PartId],
) -> @workflow.ConductorPartProposal {
  let part_id = @control.PartId(id)
  {
    part_id,
    source_revision_digest: selection_fixture_digest,
    dependency_ids: dependencies,
    task_contract: {
      id: @control.RevisionId("revision-" + id),
      goal_id,
      part_id,
      revision: 1,
      digest: selection_fixture_digest,
      instruction_artifact: {
        artifact_id: "instruction-" + id,
        digest: selection_fixture_digest,
      },
      base_commit_oid: @control.GitOid("selection-base-commit"),
      base_tree_oid: @control.GitOid("selection-base-tree"),
      path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
      mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
          @control.MutationClaim::ExactPath(
            @control.RepoPath("src/" + id + ".mbt"),
          ),
        ],
      ),
      verification_specs: [
        {
          id: @control.VerificationSpecId("verify-" + id),
          version: 1,
          digest: selection_fixture_digest,
          process_spec_digest: selection_fixture_digest,
        },
      ],
      audit_policy_digest: selection_fixture_digest,
      implementation_capability_profile_digest: selection_fixture_digest,
      verification_capability_profile_digest: selection_fixture_digest,
      audit_capability_profile_digest: selection_fixture_digest,
    },
    provider_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
  }
}

///|
fn selection_fixture_snapshot(
  parts : Array[@workflow.GoalSelectionSourcePart],
) -> @workflow.GoalSelectionSnapshot {
  {
    repository_id: @workflow.RepositoryId("selection-repository"),
    base_commit_oid: @control.GitOid("selection-base-commit"),
    base_tree_oid: @control.GitOid("selection-base-tree"),
    parts,
  }
}

///|
fn selection_fixture_proposal(
  goal_id : @control.GoalId,
  parts : Array[@workflow.ConductorPartProposal],
) -> @workflow.GoalProposal {
  {
    id: @workflow.GoalProposalId("selection-proposal"),
    goal_id,
    repository_id: @workflow.RepositoryId("selection-repository"),
    base_ref: @workflow.GitRefName("refs/heads/main"),
    expected_base_commit_oid: @control.GitOid("selection-base-commit"),
    expected_base_tree_oid: @control.GitOid("selection-base-tree"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    selection_policy: @workflow.GoalSelectionPolicy::ExactClosure,
    maximum_parallel_parts: 2,
    parts,
  }
}

///|
fn selection_fixture_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("selection conformance failed: " + detail)
}

///|
pub fn selection_exact_snapshot_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("selection.exact_snapshot"),
    run: fn(_) {
      let goal_id = @control.GoalId("selection-goal")
      let needed_id = @control.PartId("needed")
      let sources = [
        selection_fixture_source(
          "valid",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
        selection_fixture_source(
          "needed",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
        selection_fixture_source(
          "dependency-missing",
          [needed_id],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
        selection_fixture_source(
          "closed",
          [],
          @workflow.SelectionSourceState::SelectionSourceClosed,
        ),
        selection_fixture_source(
          "ambiguous",
          [],
          @workflow.SelectionSourceState::SelectionSourceAmbiguous,
        ),
        selection_fixture_source(
          "duplicate",
          [],
          @workflow.SelectionSourceState::SelectionSourceOpen,
        ),
      ]
      let valid = selection_fixture_part(goal_id, "valid", [])
      let dependency_missing = selection_fixture_part(
        goal_id,
        "dependency-missing",
        [needed_id],
      )
      let closed = selection_fixture_part(goal_id, "closed", [])
      let ambiguous = selection_fixture_part(goal_id, "ambiguous", [])
      let missing = selection_fixture_part(goal_id, "missing", [])
      let duplicate = selection_fixture_part(goal_id, "duplicate", [])
      let proposed = [
        valid, dependency_missing, closed, ambiguous, missing, duplicate, duplicate,
      ]
      let decision = match
        @workflow.evaluate_goal_proposal(
          selection_fixture_proposal(goal_id, proposed),
          selection_fixture_snapshot(sources),
          fn(_) { true },
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let expected_rejections : Array[@workflow.PartSelectionRejection] = [
        {
          part_id: @control.PartId("ambiguous"),
          reasons: [@workflow.SelectionRejectionReason::SelectionAmbiguous],
        },
        {
          part_id: @control.PartId("closed"),
          reasons: [@workflow.SelectionRejectionReason::SelectionNotOpen],
        },
        {
          part_id: @control.PartId("dependency-missing"),
          reasons: [
            @workflow.SelectionRejectionReason::SelectionMissingOpenDependency,
          ],
        },
        {
          part_id: @control.PartId("duplicate"),
          reasons: [@workflow.SelectionRejectionReason::SelectionDuplicate],
        },
        {
          part_id: @control.PartId("missing"),
          reasons: [@workflow.SelectionRejectionReason::SelectionNotFound],
        },
      ]
      expected_rejections.sort_by(fn(left, right) {
        left.part_id.compare(right.part_id)
      })
      if decision.outcome !=
        @workflow.GoalSelectionOutcome::GoalSelectionRejected ||
        decision.goal is Some(_) ||
        decision.accepted_parts.length() != 0 ||
        decision.rejections != expected_rejections {
        return Err(
          selection_fixture_error(
            "mixed rejection set changed: " +
            decision.rejections.to_json().stringify(indent=0),
          ),
        )
      }
      let reverse_sources : Array[@workflow.GoalSelectionSourcePart] = []
      for source in sources.rev_iter() {
        reverse_sources.push(source)
      }
      let reverse_proposed : Array[@workflow.ConductorPartProposal] = []
      for part in proposed.rev_iter() {
        reverse_proposed.push(part)
      }
      let permuted = match
        @workflow.evaluate_goal_proposal(
          selection_fixture_proposal(goal_id, reverse_proposed),
          selection_fixture_snapshot(reverse_sources),
          fn(_) { true },
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if permuted.id != decision.id ||
        permuted.proposal_digest != decision.proposal_digest ||
        permuted.source_snapshot_digest != decision.source_snapshot_digest ||
        permuted.proposed_part_ids != decision.proposed_part_ids ||
        permuted.rejections != decision.rejections {
        return Err(
          selection_fixture_error("input permutation changed identity"),
        )
      }
      let accepted = match
        @workflow.evaluate_goal_proposal(
          selection_fixture_proposal(goal_id, [valid]),
          selection_fixture_snapshot(sources),
          fn(_) { true },
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if accepted.outcome !=
        @workflow.GoalSelectionOutcome::GoalSelectionAccepted ||
        accepted.accepted_parts.map(fn(part) { part.part.id }) !=
        [@control.PartId("valid")] ||
        accepted.rejections.length() != 0 {
        return Err(selection_fixture_error("valid selection was not accepted"))
      }
      Ok({
        evidence: [
          ObservedSelectionCase(
            SelectionConformanceKind::SelectionExactSnapshot,
            accepted.accepted_parts.length(),
            decision.rejections.length(),
            0,
          ),
        ],
      })
    },
  }
}

///|
let audit_fixture_digest_a : @control.Digest = @control.Digest(
  "1111111111111111111111111111111111111111111111111111111111111111",
)

///|
let audit_fixture_digest_b : @control.Digest = @control.Digest(
  "2222222222222222222222222222222222222222222222222222222222222222",
)

///|
fn audit_fixture_subject() -> @control.PartAuditSubject {
  {
    part_id: @control.PartId("audit-part"),
    candidate_take_id: @control.TakeId("implementation-take"),
    candidate_commit_oid: @control.GitOid("candidate-commit"),
    candidate_tree_oid: @control.GitOid("candidate-tree"),
    task_contract_revision_id: @control.RevisionId("contract-revision"),
    task_contract_digest: audit_fixture_digest_a,
    verification_receipt_set_digest: audit_fixture_digest_a,
    verification_evidence_manifest_digest: audit_fixture_digest_b,
    subject_digest: audit_fixture_digest_a,
  }
}

///|
fn audit_fixture_result() -> @control.AuditResult {
  {
    id: @control.AuditResultId("audit-result"),
    audit_take_id: @control.TakeId("audit-take"),
    take_fencing_epoch: @control.FencingEpoch(7L),
    audit_harness_session_id: @control.HarnessSessionId("audit-session"),
    subject: audit_fixture_subject(),
    auditor_capability_profile_digest: audit_fixture_digest_a,
    effective_surface_manifest_digest: audit_fixture_digest_b,
    provider_conformance_report_digest: audit_fixture_digest_a,
    audit_policy_digest: audit_fixture_digest_b,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 10L,
    finished_at: 11L,
    outcome: @control.AuditOutcome::AuditPassed,
    result_digest: audit_fixture_digest_a,
  }
}

///|
fn audit_fixture_receipt() -> @control.AuditReceipt {
  {
    receipt_id: @control.ReceiptId("audit-receipt"),
    audit_result_id: @control.AuditResultId("audit-result"),
    audit_result_digest: audit_fixture_digest_a,
    subject: audit_fixture_subject(),
    audit_take_id: @control.TakeId("audit-take"),
    audit_harness_session_id: @control.HarnessSessionId("audit-session"),
    audit_sandbox_generation_id: @control.SandboxGenerationId(
      "audit-generation",
    ),
    auditor_capability_profile_digest: audit_fixture_digest_a,
    provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
    provider_identity: "codex-subscription",
    model_identity: @control.ModelIdentity::UnreportedModelIdentity,
    provider_conformance_report_digest: audit_fixture_digest_a,
    audit_policy_digest: audit_fixture_digest_b,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 10L,
    finished_at: 11L,
    outcome: @control.AuditOutcome::AuditPassed,
  }
}

///|
fn audit_fixture_session() -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("audit-session"),
    take_id: @control.TakeId("audit-take"),
    sandbox_generation_id: @control.SandboxGenerationId("audit-generation"),
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    effective_surface_manifest_digest: audit_fixture_digest_b,
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
    provider_cursor: Some("audit-thread:audit-turn"),
    last_choir_sequence: @control.EventSequence(2L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  }
}

///|
fn audit_fixture_observation(
  subject : @control.PartAuditSubject,
  receipt : @control.AuditReceipt?,
  result : @control.AuditResult?,
  artifact_exists : (@control.Digest) -> Bool,
) -> @control.AuditGateObservation {
  @control.evaluate_part_audit_gate(
    subject,
    receipt,
    result,
    @control.TakeId("implementation-take"),
    @control.SandboxGenerationId("implementation-generation"),
    [@control.HarnessSessionId("implementation-session")],
    Some(audit_fixture_session()),
    audit_fixture_digest_a,
    audit_fixture_digest_b,
    audit_fixture_digest_a,
    audit_fixture_digest_b,
    artifact_exists,
  )
}

///|
fn audit_fixture_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("audit conformance failed: " + detail)
}

///|
pub fn audit_gate_missing_is_passive_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("audit.gate_missing_is_passive"),
    run: fn(_) {
      let reads = @ref.new(0)
      let observation = audit_fixture_observation(
        audit_fixture_subject(),
        None,
        Some(audit_fixture_result()),
        fn(_) {
          reads.val = reads.val + 1
          true
        },
      )
      if observation != @control.AuditGateObservation::AuditGateMissing ||
        reads.val != 0 {
        return Err(audit_fixture_error("missing gate performed work"))
      }
      Ok({ evidence: [ObservedAuditCase(AuditMissingGatePassive, 1, 0)] })
    },
  }
}

///|
pub fn audit_independence_rejects_author_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("audit.independence_rejects_author"),
    run: fn(_) {
      let candidate_take = @control.TakeId("implementation-take")
      let candidate_session = @control.HarnessSessionId(
        "implementation-session",
      )
      let take_receipt = {
        ..audit_fixture_receipt(),
        audit_take_id: candidate_take,
      }
      let take_result = {
        ..audit_fixture_result(),
        audit_take_id: candidate_take,
      }
      let sandbox_receipt = {
        ..audit_fixture_receipt(),
        audit_sandbox_generation_id: @control.SandboxGenerationId(
          "implementation-generation",
        ),
      }
      let session_receipt = {
        ..audit_fixture_receipt(),
        audit_harness_session_id: candidate_session,
      }
      let session_result = {
        ..audit_fixture_result(),
        audit_harness_session_id: candidate_session,
      }
      let observations = [
        audit_fixture_observation(
          audit_fixture_subject(),
          Some(take_receipt),
          Some(take_result),
          fn(_) { true },
        ),
        audit_fixture_observation(
          audit_fixture_subject(),
          Some(sandbox_receipt),
          Some(audit_fixture_result()),
          fn(_) { true },
        ),
        audit_fixture_observation(
          audit_fixture_subject(),
          Some(session_receipt),
          Some(session_result),
          fn(_) { true },
        ),
      ]
      let expected = @control.AuditGateObservation::AuditGateRejected(
        @control.AuditGateRejectionReason::AuditNotIndependent,
      )
      if observations.any(fn(observation) { observation != expected }) {
        return Err(audit_fixture_error("author identity was not rejected"))
      }
      Ok({
        evidence: [
          ObservedAuditCase(AuditIndependenceFence, observations.length(), 0),
        ],
      })
    },
  }
}

///|
fn goal_audit_fixture_subject() -> @control.GoalAuditSubject {
  {
    goal_id: @control.GoalId("audit-goal"),
    goal_branch_seal_id: @control.GoalBranchSealId("audit-seal"),
    goal_branch_seal_digest: audit_fixture_digest_a,
    goal_head_oid: @control.GitOid("goal-head"),
    goal_tree_oid: @control.GitOid("goal-tree"),
    goal_contract_digest: audit_fixture_digest_a,
    assurance_policy_revision: @control.RevisionId("assurance-revision"),
    integration_receipt_set_digest: audit_fixture_digest_a,
    goal_verification_receipt_set_digest: audit_fixture_digest_a,
    goal_verification_evidence_manifest_digest: audit_fixture_digest_b,
    subject_digest: audit_fixture_digest_a,
  }
}

///|
fn goal_audit_fixture_result() -> @control.GoalAuditResult {
  {
    id: @control.AuditResultId("goal-audit-result"),
    audit_take_id: @control.TakeId("goal-audit-take"),
    take_fencing_epoch: @control.FencingEpoch(8L),
    audit_harness_session_id: @control.HarnessSessionId("goal-audit-session"),
    subject: goal_audit_fixture_subject(),
    auditor_capability_profile_digest: audit_fixture_digest_a,
    effective_surface_manifest_digest: audit_fixture_digest_b,
    provider_conformance_report_digest: audit_fixture_digest_a,
    audit_policy_digest: audit_fixture_digest_b,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 12L,
    finished_at: 13L,
    outcome: @control.AuditOutcome::AuditPassed,
    result_digest: audit_fixture_digest_a,
  }
}

///|
fn goal_audit_fixture_receipt() -> @control.GoalAuditReceipt {
  {
    receipt_id: @control.ReceiptId("goal-audit-receipt"),
    audit_result_id: @control.AuditResultId("goal-audit-result"),
    audit_result_digest: audit_fixture_digest_a,
    subject: goal_audit_fixture_subject(),
    audit_take_id: @control.TakeId("goal-audit-take"),
    audit_harness_session_id: @control.HarnessSessionId("goal-audit-session"),
    audit_sandbox_generation_id: @control.SandboxGenerationId(
      "goal-audit-generation",
    ),
    auditor_capability_profile_digest: audit_fixture_digest_a,
    provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
    provider_identity: "codex-subscription",
    model_identity: @control.ModelIdentity::UnreportedModelIdentity,
    provider_conformance_report_digest: audit_fixture_digest_a,
    audit_policy_digest: audit_fixture_digest_b,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 12L,
    finished_at: 13L,
    outcome: @control.AuditOutcome::AuditPassed,
  }
}

///|
fn goal_audit_fixture_session() -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("goal-audit-session"),
    take_id: @control.TakeId("goal-audit-take"),
    sandbox_generation_id: @control.SandboxGenerationId("goal-audit-generation"),
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    effective_surface_manifest_digest: audit_fixture_digest_b,
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
    provider_cursor: Some("goal-audit-thread:goal-audit-turn"),
    last_choir_sequence: @control.EventSequence(2L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  }
}

///|
pub fn audit_subject_staleness_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("audit.subject_staleness"),
    run: fn(_) {
      let original = audit_fixture_subject()
      let changed_subjects = [
        { ..original, candidate_commit_oid: @control.GitOid("changed-commit") },
        { ..original, candidate_tree_oid: @control.GitOid("changed-tree") },
        {
          ..original,
          task_contract_revision_id: @control.RevisionId("changed-contract"),
          task_contract_digest: audit_fixture_digest_b,
        },
        { ..original, verification_receipt_set_digest: audit_fixture_digest_b },
        {
          ..original,
          verification_evidence_manifest_digest: audit_fixture_digest_a,
        },
      ]
      let expected_subject = @control.AuditGateObservation::AuditGateStale(
        @control.AuditGateStaleReason::AuditStaleSubject,
      )
      for subject in changed_subjects {
        let observation = audit_fixture_observation(
          subject,
          Some(audit_fixture_receipt()),
          Some(audit_fixture_result()),
          fn(_) { true },
        )
        if observation != expected_subject {
          return Err(audit_fixture_error("subject change was not stale"))
        }
      }
      let policy_observation = @control.evaluate_part_audit_gate(
        original,
        Some(audit_fixture_receipt()),
        Some(audit_fixture_result()),
        @control.TakeId("implementation-take"),
        @control.SandboxGenerationId("implementation-generation"),
        [@control.HarnessSessionId("implementation-session")],
        Some(audit_fixture_session()),
        audit_fixture_digest_a,
        audit_fixture_digest_b,
        audit_fixture_digest_a,
        audit_fixture_digest_a,
        fn(_) { true },
      )
      if policy_observation !=
        @control.AuditGateObservation::AuditGateStale(
          @control.AuditGateStaleReason::AuditStalePolicy,
        ) {
        return Err(audit_fixture_error("policy change was not stale"))
      }
      let goal_subject = {
        ..goal_audit_fixture_subject(),
        integration_receipt_set_digest: audit_fixture_digest_b,
      }
      let integration_observation = @control.evaluate_goal_audit_gate(
        goal_subject,
        Some(goal_audit_fixture_receipt()),
        Some(goal_audit_fixture_result()),
        [],
        [],
        [],
        Some(goal_audit_fixture_session()),
        audit_fixture_digest_a,
        audit_fixture_digest_b,
        audit_fixture_digest_a,
        audit_fixture_digest_b,
        fn(_) { true },
      )
      if integration_observation != expected_subject {
        return Err(
          audit_fixture_error("integration receipt set change was not stale"),
        )
      }
      Ok({
        evidence: [
          ObservedAuditCase(
            AuditSubjectStaleness,
            changed_subjects.length() + 2,
            0,
          ),
        ],
      })
    },
  }
}

///|
pub fn selection_revision_invalidation_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("selection.revision_invalidation"),
    run: fn(_) {
      let subject = audit_fixture_subject()
      let valid = audit_fixture_observation(
        subject,
        Some(audit_fixture_receipt()),
        Some(audit_fixture_result()),
        fn(_) { true },
      )
      if valid !=
        @control.AuditGateObservation::AuditGateValid(
          @control.ReceiptId("audit-receipt"),
        ) {
        return Err(audit_fixture_error("baseline receipt was not valid"))
      }
      let goal_id = @control.GoalId("revision-invalidation-goal")
      let source = selection_fixture_source(
        "revision-part",
        [],
        @workflow.SelectionSourceState::SelectionSourceOpen,
      )
      let proposed = selection_fixture_part(goal_id, "revision-part", [])
      let selection = match
        @workflow.evaluate_goal_proposal(
          selection_fixture_proposal(goal_id, [proposed]),
          selection_fixture_snapshot([source]),
          fn(_) { true },
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let queued = match
        @workflow.goal_execution_record_from_selection(
          selection,
          @workflow.goal_selection_decision_digest(selection),
          ["revision-part-workflow"],
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let running = match
        @workflow.advance_goal_execution_state(
          queued,
          @workflow.GoalExecutionState::GoalExecutionRunning,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (steered, scheduling_revision) = match
        @workflow.steer_goal_execution(
          running,
          @workflow.GoalPolicyChange::GoalPolicySetMaximumParallelParts(8),
        ) {
        Ok(
          @workflow.GoalSteeringDecision::GoalSteeringApplied(record, revision)
        ) => (record, revision)
        Ok(_) =>
          return Err(audit_fixture_error("scheduling change was not applied"))
        Err(error) => return Err(error)
      }
      let after_scheduling_change = audit_fixture_observation(
        subject,
        Some(audit_fixture_receipt()),
        Some(audit_fixture_result()),
        fn(_) { true },
      )
      if steered.maximum_parallel_parts != 8 ||
        steered.policy_revisions.length() != 2 ||
        scheduling_revision.maximum_parallel_parts != 8 ||
        after_scheduling_change != valid {
        return Err(
          audit_fixture_error("scheduling-only policy invalidated evidence"),
        )
      }
      let after_assurance_change = @control.evaluate_part_audit_gate(
        subject,
        Some(audit_fixture_receipt()),
        Some(audit_fixture_result()),
        @control.TakeId("implementation-take"),
        @control.SandboxGenerationId("implementation-generation"),
        [@control.HarnessSessionId("implementation-session")],
        Some(audit_fixture_session()),
        audit_fixture_digest_a,
        audit_fixture_digest_b,
        audit_fixture_digest_a,
        audit_fixture_digest_a,
        fn(_) { true },
      )
      if after_assurance_change !=
        @control.AuditGateObservation::AuditGateStale(
          @control.AuditGateStaleReason::AuditStalePolicy,
        ) {
        return Err(
          audit_fixture_error("assurance policy did not invalidate evidence"),
        )
      }
      let changed_contract = {
        ..subject,
        task_contract_revision_id: @control.RevisionId("changed-contract"),
        task_contract_digest: audit_fixture_digest_b,
      }
      let after_contract_change = audit_fixture_observation(
        changed_contract,
        Some(audit_fixture_receipt()),
        Some(audit_fixture_result()),
        fn(_) { true },
      )
      if after_contract_change !=
        @control.AuditGateObservation::AuditGateStale(
          @control.AuditGateStaleReason::AuditStaleSubject,
        ) {
        return Err(
          audit_fixture_error("task contract did not invalidate evidence"),
        )
      }
      Ok({
        evidence: [
          ObservedSelectionCase(
            SelectionRevisionInvalidation,
            1,
            2,
            scheduling_revision.maximum_parallel_parts,
          ),
        ],
      })
    },
  }
}

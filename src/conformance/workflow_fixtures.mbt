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
      repair_conflict_id: None,
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
      migration_contract_ref: None,
      implementation_capability_profile_digest: scheduling_fixture_digest,
      verification_capability_profile_digest: scheduling_fixture_digest,
      audit_capability_profile_digest: scheduling_fixture_digest,
    },
  }
}

///|
pub fn sandbox_transfer_validation_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("sandbox.transfer_security"),
    run: fn(_) {
      let limits : @sandbox.TransferLimits = {
        max_entries: 4,
        max_total_bytes: 32L,
        max_file_bytes: 16L,
        max_depth: 3,
        link_policy: @sandbox.TransferLinkPolicy::TransferRejectLinks,
      }
      let accepted = @sandbox.evaluate_transfer_manifest(
        [
          {
            path: "artifacts",
            kind: @sandbox.TransferEntryKind::TransferDirectory,
            size_bytes: 0L,
          },
          {
            path: "artifacts/result.json",
            kind: @sandbox.TransferEntryKind::TransferFile,
            size_bytes: 12L,
          },
        ],
        limits,
      )
      let rejected = [
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "../outside",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 1L,
            },
          ],
          limits,
        ),
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "artifacts/hardlink",
              kind: @sandbox.TransferEntryKind::TransferHardlink,
              size_bytes: 0L,
            },
          ],
          limits,
        ),
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "artifacts/link",
              kind: @sandbox.TransferEntryKind::TransferSymlink,
              size_bytes: 0L,
            },
          ],
          limits,
        ),
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "artifacts/fifo",
              kind: @sandbox.TransferEntryKind::TransferFifo,
              size_bytes: 0L,
            },
          ],
          limits,
        ),
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "artifacts/socket",
              kind: @sandbox.TransferEntryKind::TransferSocket,
              size_bytes: 0L,
            },
          ],
          limits,
        ),
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "artifacts/device",
              kind: @sandbox.TransferEntryKind::TransferDevice,
              size_bytes: 0L,
            },
          ],
          limits,
        ),
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "a",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 16L,
            },
            {
              path: "b",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 16L,
            },
            {
              path: "c",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 1L,
            },
          ],
          limits,
        ),
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "a",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 0L,
            },
            {
              path: "b",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 0L,
            },
            {
              path: "c",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 0L,
            },
            {
              path: "d",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 0L,
            },
            {
              path: "e",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 0L,
            },
          ],
          limits,
        ),
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "a/b/c/d",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 1L,
            },
          ],
          limits,
        ),
        @sandbox.evaluate_transfer_manifest(
          [
            {
              path: "artifacts/large.bin",
              kind: @sandbox.TransferEntryKind::TransferFile,
              size_bytes: 17L,
            },
          ],
          limits,
        ),
      ]
      let mut rejected_count = 0
      for decision in rejected {
        match decision {
          @sandbox.TransferManifestDecision::TransferManifestRejected(_) =>
            rejected_count = rejected_count + 1
          @sandbox.TransferManifestDecision::TransferManifestAccepted(_) =>
            return Err(
              @types.ChoirError::validation_error(
                "sandbox transfer fixture unexpectedly accepted",
              ),
            )
        }
      }
      let accepted_count = match accepted {
        @sandbox.TransferManifestDecision::TransferManifestAccepted(manifest) =>
          manifest.entries().length()
        @sandbox.TransferManifestDecision::TransferManifestRejected(_) =>
          return Err(
            @types.ChoirError::validation_error(
              "bounded sandbox transfer fixture was rejected",
            ),
          )
      }
      let destination_accepted = @sandbox.validate_transfer_adoption_destination([
            {
              path: "artifacts",
              kind: @sandbox.TransferDestinationKind::TransferDestinationDirectory,
            },
            {
              path: "artifacts/result",
              kind: @sandbox.TransferDestinationKind::TransferDestinationMissing,
            },
          ],
        )
        is Ok(_)
      let destination_rejected = @sandbox.validate_transfer_adoption_destination([
            {
              path: "artifacts",
              kind: @sandbox.TransferDestinationKind::TransferDestinationDirectory,
            },
            {
              path: "artifacts/result",
              kind: @sandbox.TransferDestinationKind::TransferDestinationSymlink,
            },
          ],
        )
        is Err(_)
      if accepted_count != 2 ||
        rejected_count != 10 ||
        !destination_accepted ||
        !destination_rejected {
        return Err(
          @types.ChoirError::validation_error(
            "sandbox transfer validation invariant failed",
          ),
        )
      }
      Ok({
        evidence: [
          ObservedTransferCase(
            TransferValidationBoundary,
            accepted_count,
            rejected_count,
            destination_accepted,
            destination_rejected,
          ),
        ],
      })
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
fn promotion_timing_fixture(
  completion_order : Array[@control.PartId],
) -> Result[Array[@control.PartId], @types.ChoirError] {
  let part_a = scheduling_fixture_record(
    "a",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let part_b = scheduling_fixture_record(
    "b",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let part_c = scheduling_fixture_record(
    "c",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let mut records = [part_c, part_a, part_b]
  let promoted : Array[@control.PartId] = []
  for completed_id in completion_order {
    records = replace_fixture_lifecycle(
      records,
      completed_id,
      @control.PartLifecycle::PartAudited(
        @control.CandidateId("timing-candidate-" + completed_id.0),
        scheduling_fixture_digest,
        @control.ReceiptId("timing-audit-" + completed_id.0),
      ),
    )
    let mut selecting = true
    while selecting {
      let head = if promoted.length() == 0 {
        @control.GitOid("timing-head")
      } else {
        @control.GitOid("timing-promotion-" + promoted.last().unwrap().0)
      }
      match @workflow.select_next_deterministic_promotion(records, head) {
        Ok(Some(selection)) => {
          promoted.push(selection.part_id)
          records = replace_fixture_lifecycle(
            records,
            selection.part_id,
            @control.PartLifecycle::PartIntegrated(
              @control.ReceiptId("timing-integration-" + selection.part_id.0),
            ),
          )
        }
        Ok(None) => selecting = false
        Err(error) => return Err(error)
      }
    }
  }
  if promoted.length() != records.length() {
    return Err(generated_dag_error("promotion timing fixture made no progress"))
  }
  Ok(promoted)
}

///|
pub fn integration_promotion_order_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("integration.promotion_order"),
    run: fn(_) {
      let expected = [
        @control.PartId("a"),
        @control.PartId("b"),
        @control.PartId("c"),
      ]
      let timings = [
        [@control.PartId("a"), @control.PartId("b"), @control.PartId("c")],
        [@control.PartId("a"), @control.PartId("c"), @control.PartId("b")],
        [@control.PartId("b"), @control.PartId("a"), @control.PartId("c")],
        [@control.PartId("b"), @control.PartId("c"), @control.PartId("a")],
        [@control.PartId("c"), @control.PartId("a"), @control.PartId("b")],
        [@control.PartId("c"), @control.PartId("b"), @control.PartId("a")],
      ]
      for timing in timings {
        let actual = match promotion_timing_fixture(timing) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if actual != expected {
          return Err(
            generated_dag_error(
              "promotion order changed with completion timing",
            ),
          )
        }
      }
      Ok({
        evidence: [
          ObservedIntegrationCase(
            IntegrationPromotionOrder,
            timings.length(),
            true,
            true,
          ),
        ],
      })
    },
  }
}

///|
fn divergent_candidate(
  part_id : @control.PartId,
  suffix : String,
) -> @control.CandidateCommit {
  {
    id: @control.CandidateId("divergent-candidate-" + suffix),
    goal_id: @control.GoalId("goal-scheduling-conformance"),
    part_id,
    take_id: @control.TakeId("divergent-take-" + suffix),
    base_commit_oid: @control.GitOid("divergent-head"),
    commit_oid: @control.GitOid("divergent-commit-" + suffix),
    tree_oid: @control.GitOid("divergent-tree-" + suffix),
    canonical_change_digest: scheduling_fixture_digest,
    changed_paths: [],
  }
}

///|
fn divergent_receipt(
  part : @control.GoalPart,
  candidate : @control.CandidateCommit,
  from_head : @control.GitOid,
  suffix : String,
  observed_at : Int64,
) -> Result[
  (@control.PromotionCommit, @control.IntegrationReceipt),
  @types.ChoirError,
] {
  let intent : @control.IntegrationIntent = {
    id: @control.IntegrationIntentId("divergent-intent-" + suffix),
    goal_id: candidate.goal_id,
    part_id: candidate.part_id,
    candidate_id: candidate.id,
    candidate_commit_oid: candidate.commit_oid,
    candidate_tree_oid: candidate.tree_oid,
    expected_goal_head_oid: from_head,
    strategy: @control.PromotionStrategy::NoFastForwardThreeWayV1,
    promotion_metadata_digest: scheduling_fixture_digest,
    integration_lease_epoch: @control.FencingEpoch(1L),
    lifecycle: @control.IntegrationIntentLifecycle::IntegrationPlanned,
    promotion_commit_oid: None,
    promotion_tree_oid: None,
    git_witness_ref: "refs/choir/witness/divergent-" + suffix,
  }
  let promotion : @control.PromotionCommit = {
    intent_id: intent.id,
    commit_oid: @control.GitOid("divergent-promotion-" + suffix),
    tree_oid: @control.GitOid("divergent-promotion-tree-" + suffix),
    first_parent_oid: from_head,
    second_parent_oid: candidate.commit_oid,
  }
  let prepared = match @control.prepare_integration_intent(intent, promotion) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let authorized = match
    @control.authorize_part_integration(
      part,
      candidate,
      @control.VerificationGateObservation::VerificationGateValid([
        @control.ReceiptId("divergent-verification-" + suffix),
      ]),
      @control.AuditGateObservation::AuditGateValid(
        @control.ReceiptId("divergent-audit-" + suffix),
      ),
      {
        id: @control.IntegrationLeaseId("divergent-lease-" + suffix),
        goal_id: candidate.goal_id,
        fencing_epoch: @control.FencingEpoch(1L),
        holder: "choird",
      },
      prepared,
    ) {
    Ok(value) => value
    Err(_) =>
      return Err(generated_dag_error("divergent candidate was not authorized"))
  }
  match
    @control.reconcile_integration_witness(
      authorized,
      promotion,
      @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
        promotion.commit_oid,
        promotion.commit_oid,
      ),
      @control.IntegrationReceiptId("divergent-integration-" + suffix),
      observed_at,
    ) {
    @control.IntegrationReconciliationOutcome::IntegrationApplied(receipt) =>
      Ok((promotion, receipt))
    _ => Err(generated_dag_error("divergent candidate was not receipted"))
  }
}

///|
pub fn integration_divergent_candidates_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("integration.divergent_candidates"),
    run: fn(_) {
      let audited_part = fn(suffix : String) {
        let record = scheduling_fixture_record(
          suffix,
          [],
          @control.PartLifecycle::PartPending,
          @control.MutationDeclaration::CompleteMutationDeclaration([]),
        )
        let candidate = divergent_candidate(record.part.id, suffix)
        let part = {
          ..record.part,
          lifecycle: @control.PartLifecycle::PartAudited(
            candidate.id,
            scheduling_fixture_digest,
            @control.ReceiptId("divergent-audit-" + suffix),
          ),
        }
        (part, candidate)
      }
      let (part_a, candidate_a) = audited_part("a")
      let (part_b, candidate_b) = audited_part("b")
      let base = @control.GitOid("divergent-head")
      let (promotion_a, receipt_a) = match
        divergent_receipt(part_a, candidate_a, base, "a", 1L) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (promotion_b, receipt_b) = match
        divergent_receipt(part_b, candidate_b, promotion_a.commit_oid, "b", 2L) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let parent_chain = promotion_a.first_parent_oid == base &&
        promotion_a.second_parent_oid == candidate_a.commit_oid &&
        promotion_b.first_parent_oid == promotion_a.commit_oid &&
        promotion_b.second_parent_oid == candidate_b.commit_oid
      let receipt_chain = receipt_a.from_head_oid == base &&
        receipt_a.promotion_commit_oid == promotion_a.commit_oid &&
        receipt_b.from_head_oid == receipt_a.promotion_commit_oid &&
        receipt_b.promotion_commit_oid == promotion_b.commit_oid
      if !parent_chain || !receipt_chain {
        return Err(generated_dag_error("divergent promotion chain was broken"))
      }
      Ok({
        evidence: [
          ObservedIntegrationCase(
            IntegrationDivergentCandidateComposition,
            2,
            parent_chain,
            receipt_chain,
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
    source_content_digest: selection_fixture_digest,
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
    source_content_digest: selection_fixture_digest,
    dependency_ids: dependencies,
    task_contract: {
      id: @control.RevisionId("revision-" + id),
      goal_id,
      part_id,
      revision: 1,
      digest: selection_fixture_digest,
      repair_conflict_id: None,
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
      migration_contract_ref: None,
      implementation_capability_profile_digest: selection_fixture_digest,
      verification_capability_profile_digest: selection_fixture_digest,
      audit_capability_profile_digest: selection_fixture_digest,
    },
    provider_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    part_context_manifest: None,
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
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
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
fn branch_initialization_fixture_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "branch initialization conformance failed: " + detail,
  )
}

///|
fn branch_initialization_fixture_record() -> Result[
  @workflow.GoalExecutionRecord,
  @types.ChoirError,
] {
  let goal_id = @control.GoalId("branch-initialization-goal")
  let source = selection_fixture_source(
    "branch-initialization-part",
    [],
    @workflow.SelectionSourceState::SelectionSourceOpen,
  )
  let part = selection_fixture_part(goal_id, "branch-initialization-part", [])
  let decision = match
    @workflow.evaluate_goal_proposal(
      selection_fixture_proposal(goal_id, [part]),
      selection_fixture_snapshot([source]),
      fn(_) { true },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  @workflow.goal_execution_record_from_selection(
    decision,
    @workflow.goal_selection_decision_digest(decision),
    ["workflow-branch-initialization-part"],
  )
}

///|
fn branch_initialization_fixture_round_trip(
  record : @workflow.GoalExecutionRecord,
) -> Result[@workflow.GoalExecutionRecord, @types.ChoirError] {
  @workflow.decode_goal_execution_record(
    @workflow.goal_execution_record_bytes(record),
  )
}

///|
pub fn branch_initialization_faults_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("branch.initialization_faults"),
    run: fn(context) {
      let fault_points = [
        FaultPoint::BranchInitAfterIntentBeforeAuthorized,
        FaultPoint::BranchInitAfterAuthorizedBeforeRefTransaction,
        FaultPoint::BranchInitDuringRefTransaction,
        FaultPoint::BranchInitAfterRefTransactionBeforeReceipt,
      ]
      for point in fault_points {
        if !context.fault_enabled(point) {
          return Err(
            branch_initialization_fixture_error(
              "required fault point was not injected",
            ),
          )
        }
      }
      let queued = match branch_initialization_fixture_record() {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let queued = match branch_initialization_fixture_round_trip(queued) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let canceled_before_authorization = match
        @workflow.request_goal_execution_cancellation(queued, context.now()) {
        Ok(@workflow.GoalCancellationDecision::GoalCancellationRequested(value)) =>
          value
        Ok(_) =>
          return Err(
            branch_initialization_fixture_error(
              "preauthorization cancellation was not installed",
            ),
          )
        Err(error) => return Err(error)
      }
      let canceled_before_authorization = match
        @workflow.authorize_goal_source_release(
          canceled_before_authorization,
          canceled_before_authorization.source_claims[0].part_id,
        ) {
        Ok(value) =>
          match
            @workflow.reconcile_goal_source_release(
              value,
              value.source_claims[0].part_id,
              @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
              context.now(),
            ) {
            Ok(released) => released
            Err(error) => return Err(error)
          }
        Err(error) => return Err(error)
      }
      if canceled_before_authorization.branch_initialization.lifecycle !=
        @workflow.GoalBranchInitLifecycle::GoalBranchInitAbandonedByCancellation ||
        @workflow.commit_goal_execution_cancellation(
          canceled_before_authorization,
        )
        is Err(_) {
        return Err(
          branch_initialization_fixture_error(
            "preauthorization cancellation did not abandon initialization",
          ),
        )
      }
      let running = match
        @workflow.advance_goal_execution_state(
          queued,
          @workflow.GoalExecutionState::GoalExecutionRunning,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let running = match
        @workflow.authorize_goal_source_claim(
          running,
          running.source_claims[0].part_id,
        ) {
        Ok(value) =>
          match
            @workflow.reconcile_goal_source_claim(
              value,
              value.source_claims[0].part_id,
              @workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor,
              context.now(),
            ) {
            Ok(claimed) => claimed
            Err(error) => return Err(error)
          }
        Err(error) => return Err(error)
      }
      let authorized = match
        @workflow.authorize_goal_branch_initialization(running) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let authorized = match
        branch_initialization_fixture_round_trip(authorized) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match
        @workflow.reconcile_goal_branch_initialization(
          authorized,
          @workflow.GoalBranchInitObservation::GoalBranchInitRefsAbsent,
          context.now(),
        ) {
        Ok(
          @workflow.GoalBranchInitReconciliation::GoalBranchInitExactRetryAuthorized(
            replay
          )
        ) if replay == authorized => ()
        Ok(_) =>
          return Err(
            branch_initialization_fixture_error(
              "absent refs did not preserve exact authorization",
            ),
          )
        Err(error) => return Err(error)
      }
      let receipted = match
        @workflow.reconcile_goal_branch_initialization(
          authorized,
          @workflow.GoalBranchInitObservation::GoalBranchInitRefsAtBase,
          context.now(),
        ) {
        Ok(
          @workflow.GoalBranchInitReconciliation::GoalBranchInitObservationRecorded(
            value
          )
        ) => value
        Ok(_) =>
          return Err(
            branch_initialization_fixture_error(
              "exact refs did not produce a receipt",
            ),
          )
        Err(error) => return Err(error)
      }
      let receipted = match
        branch_initialization_fixture_round_trip(receipted) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let partial_blocked = match
        @workflow.reconcile_goal_branch_initialization(
          authorized,
          @workflow.GoalBranchInitObservation::GoalBranchInitBranchOnly,
          context.now(),
        ) {
        Ok(
          @workflow.GoalBranchInitReconciliation::GoalBranchInitObservationRecorded(
            value
          )
        ) => value.state == @workflow.GoalExecutionState::GoalExecutionBlocked
        _ => false
      }
      let divergence_uncertain = match
        @workflow.reconcile_goal_branch_initialization(
          authorized,
          @workflow.GoalBranchInitObservation::GoalBranchInitRefsDiverged,
          context.now(),
        ) {
        Ok(
          @workflow.GoalBranchInitReconciliation::GoalBranchInitObservationRecorded(
            value
          )
        ) =>
          value.branch_initialization.lifecycle ==
          @workflow.GoalBranchInitLifecycle::GoalBranchInitUncertain
        _ => false
      }
      let canceling = match
        @workflow.request_goal_execution_cancellation(authorized, context.now()) {
        Ok(@workflow.GoalCancellationDecision::GoalCancellationRequested(value)) =>
          value
        _ =>
          return Err(
            branch_initialization_fixture_error(
              "postauthorization cancellation was not installed",
            ),
          )
      }
      let cancellation_waited = @workflow.commit_goal_execution_cancellation(
          canceling,
        )
        is Err(_)
      let canceling_receipted = match
        @workflow.reconcile_goal_branch_initialization(
          canceling,
          @workflow.GoalBranchInitObservation::GoalBranchInitRefsAtBase,
          context.now(),
        ) {
        Ok(
          @workflow.GoalBranchInitReconciliation::GoalBranchInitObservationRecorded(
            value
          )
        ) => value
        _ =>
          return Err(
            branch_initialization_fixture_error(
              "postauthorization cancellation did not reconcile",
            ),
          )
      }
      let canceling_released = match
        @workflow.authorize_goal_source_release(
          canceling_receipted,
          canceling_receipted.source_claims[0].part_id,
        ) {
        Ok(value) =>
          match
            @workflow.reconcile_goal_source_release(
              value,
              value.source_claims[0].part_id,
              @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
              context.now(),
            ) {
            Ok(released) => released
            Err(error) => return Err(error)
          }
        Err(error) => return Err(error)
      }
      if receipted.branch_initialization.receipt is None ||
        !partial_blocked ||
        !divergence_uncertain ||
        !cancellation_waited ||
        @workflow.commit_goal_execution_cancellation(canceling_released)
        is Err(_) {
        return Err(
          branch_initialization_fixture_error(
            "recovery matrix did not converge fail closed",
          ),
        )
      }
      Ok({
        evidence: [
          ObservedBranchInitializationCase(
            BranchInitializationRecoveryMatrix,
            1,
            partial_blocked,
            divergence_uncertain,
            cancellation_waited,
          ),
        ],
      })
    },
  }
}

///|
pub fn integration_conflict_repair_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("integration.conflict_repair"),
    run: fn(_) {
      let (source, _) = event_authorized_provider_dispatch_fixture()
      let verification_spec : @control.VerificationSpec = {
        id: @control.VerificationSpecId("conflict-repair-verification"),
        version: 1,
        digest: scheduling_fixture_digest,
        process_spec_digest: selection_fixture_digest,
      }
      let current_contract = {
        ..source.task_contract,
        verification_specs: [verification_spec],
      }
      let conflict : @control.IntegrationConflict = {
        id: @control.IntegrationConflictId("conflict-repair-1"),
        intent_id: @control.IntegrationIntentId("conflict-repair-intent-1"),
        candidate_id: @control.CandidateId("conflict-repair-candidate-1"),
        candidate_commit_oid: @control.GitOid(
          "conflict-repair-candidate-commit",
        ),
        expected_goal_head_oid: @control.GitOid("conflict-repair-goal-head"),
        expected_goal_head_tree_oid: @control.GitOid(
          "conflict-repair-goal-tree",
        ),
        merge_base_oid: current_contract.base_commit_oid,
        conflicting_paths: [@control.RepoPath("src/conflict.mbt")],
        evidence_digest: selection_fixture_digest,
      }
      let blocked = {
        ..source,
        stage: @workflow.PartWorkflowStage::PartBlocked,
        part: {
          ..source.part,
          lifecycle: @control.PartLifecycle::PartBlocked(
            @control.PartBlockReason::PartIntegrationConflict,
          ),
        },
        task_contract: current_contract,
        task_contract_history: [current_contract],
        pending_effect: None,
        integration_conflicts: [conflict],
      }
      let repair_contract : @control.TaskContractRevision = {
        ..current_contract,
        id: @control.RevisionId("conflict-repair-revision-2"),
        revision: 2,
        digest: ownership_digest_b,
        repair_conflict_id: Some(conflict.id),
        base_commit_oid: conflict.expected_goal_head_oid,
        base_tree_oid: conflict.expected_goal_head_tree_oid,
      }
      let implementation : @control.Take = {
        id: @control.TakeId("conflict-repair-implementation-2"),
        goal_id: blocked.goal.id,
        purpose: @control.TakePurpose::Implementation(
          blocked.part.id,
          repair_contract.id,
        ),
        ordinal: 2,
        fencing_epoch: None,
        lifecycle: @control.TakeLifecycle::TakePlanned,
      }
      let verification : @control.Take = {
        id: @control.TakeId("conflict-repair-verification-2"),
        goal_id: blocked.goal.id,
        purpose: @control.TakePurpose::PartVerification(
          blocked.part.id,
          implementation.id,
          verification_spec.digest,
        ),
        ordinal: 2,
        fencing_epoch: None,
        lifecycle: @control.TakeLifecycle::TakePlanned,
      }
      let audit : @control.Take = {
        id: @control.TakeId("conflict-repair-audit-2"),
        goal_id: blocked.goal.id,
        purpose: @control.TakePurpose::PartAudit(
          blocked.part.id,
          implementation.id,
          repair_contract.audit_policy_digest,
        ),
        ordinal: 2,
        fencing_epoch: None,
        lifecycle: @control.TakeLifecycle::TakePlanned,
      }
      let sandbox = fn(
        id : String,
        take : @control.Take,
        previous : @control.SandboxLease,
      ) -> @control.SandboxLease {
        {
          id: @control.SandboxLeaseId(id),
          take_id: take.id,
          generation_id: @control.SandboxGenerationId(id + "-generation"),
          capability_profile_digest: previous.capability_profile_digest,
          runtime_policy_digest: previous.runtime_policy_digest,
          lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
        }
      }
      let implementation_sandbox = sandbox(
        "conflict-repair-implementation-sandbox-2",
        implementation,
        blocked.identities.implementation_sandbox,
      )
      let verification_sandbox = sandbox(
        "conflict-repair-verification-sandbox-2",
        verification,
        blocked.identities.verification_sandbox,
      )
      let audit_sandbox = sandbox(
        "conflict-repair-audit-sandbox-2",
        audit,
        blocked.identities.audit_sandbox,
      )
      let session = fn(
        id : String,
        take : @control.Take,
        sandbox : @control.SandboxLease,
        previous : @control.HarnessSession,
      ) -> @control.HarnessSession {
        {
          id: @control.HarnessSessionId(id),
          take_id: take.id,
          sandbox_generation_id: sandbox.generation_id,
          surface: previous.surface,
          effective_surface_manifest_digest: previous.effective_surface_manifest_digest,
          cursor_class: previous.cursor_class,
          provider_cursor: None,
          last_choir_sequence: @control.EventSequence(0L),
          open_tool_execution_ids: [],
          lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
        }
      }
      let decision = match
        @workflow.plan_part_conflict_repair(
          blocked,
          repair_contract,
          {
            implementation_take: implementation,
            implementation_sandbox,
            implementation_session: session(
              "conflict-repair-implementation-session-2",
              implementation,
              implementation_sandbox,
              blocked.identities.implementation_session,
            ),
            verification_take: verification,
            verification_sandbox,
            verification_session: session(
              "conflict-repair-verification-session-2",
              verification,
              verification_sandbox,
              blocked.identities.verification_session,
            ),
            audit_take: audit,
            audit_sandbox,
            audit_session: session(
              "conflict-repair-audit-session-2",
              audit,
              audit_sandbox,
              blocked.identities.audit_session,
            ),
          },
          fn(_) { true },
        ) {
        Ok(
          @workflow.PartConflictRepairDecision::PartConflictRepairPlanned(value)
        ) => value
        Ok(_) =>
          return Err(
            branch_initialization_fixture_error(
              "first conflict repair reached its limit",
            ),
          )
        Err(error) => return Err(error)
      }
      let evidence_cleared = decision.candidate is None &&
        decision.verification_receipts.length() == 0 &&
        decision.audit_receipt is None &&
        decision.integration_intent is None &&
        decision.integration_receipt is None
      let fresh_assurance = decision.verification_take.id == verification.id &&
        decision.audit_take.id == audit.id &&
        decision.verification_take.purpose ==
        @control.TakePurpose::PartVerification(
          blocked.part.id,
          implementation.id,
          verification_spec.digest,
        ) &&
        decision.audit_take.purpose ==
        @control.TakePurpose::PartAudit(
          blocked.part.id,
          implementation.id,
          repair_contract.audit_policy_digest,
        )
      if decision.task_contract != repair_contract ||
        decision.task_contract_history.length() != 2 ||
        decision.prior_takes.length() != 3 ||
        decision.prior_take_evidence.length() != 1 ||
        decision.integration_conflicts != [conflict] ||
        !evidence_cleared ||
        !fresh_assurance {
        return Err(
          branch_initialization_fixture_error(
            "repair did not preserve history and reset assurance",
          ),
        )
      }
      Ok({
        evidence: [
          ObservedIntegrationConflictRepair(
            decision.task_contract.revision,
            decision.prior_takes.length(),
            evidence_cleared,
            fresh_assurance,
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
fn audit_workflow_result_fixture() -> @workflow.PartWorkflowSnapshot {
  let (base, _) = event_authorized_provider_dispatch_fixture()
  let candidate : @control.CandidateCommit = {
    id: @control.CandidateId("audit-workflow-candidate"),
    goal_id: base.goal.id,
    part_id: base.part.id,
    take_id: base.implementation_take.id,
    base_commit_oid: base.task_contract.base_commit_oid,
    commit_oid: @control.GitOid("audit-workflow-commit"),
    tree_oid: @control.GitOid("audit-workflow-tree"),
    canonical_change_digest: audit_fixture_digest_a,
    changed_paths: [],
  }
  let subject : @control.PartAuditSubject = {
    part_id: base.part.id,
    candidate_take_id: base.implementation_take.id,
    candidate_commit_oid: candidate.commit_oid,
    candidate_tree_oid: candidate.tree_oid,
    task_contract_revision_id: base.task_contract.id,
    task_contract_digest: base.task_contract.digest,
    verification_receipt_set_digest: audit_fixture_digest_a,
    verification_evidence_manifest_digest: audit_fixture_digest_b,
    subject_digest: audit_fixture_digest_a,
  }
  let audit_session = {
    ..base.identities.audit_session,
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
    provider_cursor: Some("audit-workflow-thread:audit-workflow-turn"),
    last_choir_sequence: @control.EventSequence(2L),
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(
      @control.HarnessTerminalObservation::HarnessCompleted,
    ),
  }
  let result : @control.AuditResult = {
    id: @control.AuditResultId("audit-workflow-result"),
    audit_take_id: base.audit_take.id,
    take_fencing_epoch: base.fencing_epoch,
    audit_harness_session_id: audit_session.id,
    subject,
    auditor_capability_profile_digest: base.task_contract.audit_capability_profile_digest,
    effective_surface_manifest_digest: audit_session.effective_surface_manifest_digest,
    provider_conformance_report_digest: audit_fixture_digest_a,
    audit_policy_digest: base.task_contract.audit_policy_digest,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 100L,
    finished_at: 101L,
    outcome: @control.AuditOutcome::AuditPassed,
    result_digest: audit_fixture_digest_b,
  }
  {
    ..base,
    stage: @workflow.PartWorkflowStage::PartAuditResultRecorded,
    part: {
      ..base.part,
      lifecycle: @control.PartLifecycle::PartVerified(
        candidate.id,
        subject.verification_receipt_set_digest,
      ),
    },
    identities: { ..base.identities, audit_session, },
    audit_take: {
      ..base.audit_take,
      lifecycle: @control.TakeLifecycle::TakeTerminal(
        @control.TakeTerminalDisposition::TakeSucceeded,
      ),
    },
    harness_sessions: base.harness_sessions.map(fn(session) {
      if session.id == audit_session.id {
        audit_session
      } else {
        session
      }
    }),
    candidate: Some(candidate),
    audit_subject: Some(subject),
    audit_result: Some(result),
    pending_effect: None,
  }
}

///|
fn audit_workflow_metadata() -> @workflow.AuditReceiptMetadata {
  {
    receipt_id: @control.ReceiptId("audit-workflow-receipt"),
    provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
    provider_identity: "codex-subscription-conformance",
    model_identity: @control.ModelIdentity::UnreportedModelIdentity,
  }
}

///|
fn audit_workflow_gate(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @control.AuditGateObservation {
  let subject = snapshot.audit_subject.unwrap()
  let result = snapshot.audit_result.unwrap()
  let session = snapshot.harness_sessions.filter(fn(candidate) {
      candidate.id == result.audit_harness_session_id
    })[0]
  let candidate_sessions : Array[@control.HarnessSessionId] = []
  for candidate in snapshot.harness_sessions {
    if candidate.take_id == snapshot.implementation_take.id {
      candidate_sessions.push(candidate.id)
    }
  }
  @control.evaluate_part_audit_gate(
    subject,
    snapshot.audit_receipt,
    Some(result),
    snapshot.implementation_take.id,
    snapshot.identities.implementation_sandbox.generation_id,
    candidate_sessions,
    Some(session),
    snapshot.task_contract.audit_capability_profile_digest,
    session.effective_surface_manifest_digest,
    result.provider_conformance_report_digest,
    snapshot.task_contract.audit_policy_digest,
    fn(_) { true },
  )
}

///|
fn cancellation_goal_assurance_identities(
  goal : @control.Goal,
  head : @control.GitOid,
) -> @workflow.GoalAssuranceIdentityPlan {
  let verification_take : @control.Take = {
    id: @control.TakeId("cancellation-goal-verification-take"),
    goal_id: goal.id,
    purpose: @control.TakePurpose::GoalVerification(
      goal.id,
      head,
      audit_fixture_digest_a,
    ),
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
  let audit_take : @control.Take = {
    id: @control.TakeId("cancellation-goal-audit-take"),
    goal_id: goal.id,
    purpose: @control.TakePurpose::GoalAudit(goal.id, audit_fixture_digest_b),
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
  let sandbox = fn(id : String, take : @control.Take) -> @control.SandboxLease {
    {
      id: @control.SandboxLeaseId(id),
      take_id: take.id,
      generation_id: @control.SandboxGenerationId(id + "-generation"),
      capability_profile_digest: audit_fixture_digest_a,
      runtime_policy_digest: audit_fixture_digest_b,
      lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
    }
  }
  let verification_sandbox = sandbox(
    "cancellation-goal-verification-sandbox", verification_take,
  )
  let audit_sandbox = sandbox("cancellation-goal-audit-sandbox", audit_take)
  let session = fn(
    id : String,
    take : @control.Take,
    lease : @control.SandboxLease,
  ) -> @control.HarnessSession {
    {
      id: @control.HarnessSessionId(id),
      take_id: take.id,
      sandbox_generation_id: lease.generation_id,
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      effective_surface_manifest_digest: audit_fixture_digest_a,
      cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
      provider_cursor: None,
      last_choir_sequence: @control.EventSequence(0L),
      open_tool_execution_ids: [],
      lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
    }
  }
  {
    verification_take,
    verification_sandbox,
    verification_session: session(
      "cancellation-goal-verification-session", verification_take, verification_sandbox,
    ),
    audit_take,
    audit_sandbox,
    audit_session: session(
      "cancellation-goal-audit-session", audit_take, audit_sandbox,
    ),
  }
}

///|
fn cancellation_goal_assurance_fixture() -> Result[
  (@workflow.GoalExecutionRecord, @workflow.GoalAssuranceRecord),
  @types.ChoirError,
] {
  let base = audit_workflow_result_fixture()
  let candidate = base.candidate.unwrap()
  let promotion_commit = @control.GitOid("cancellation-goal-promotion")
  let promotion_tree = @control.GitOid("cancellation-goal-promotion-tree")
  let verification_spec : @control.VerificationSpec = {
    id: @control.VerificationSpecId("cancellation-goal-check"),
    version: 1,
    digest: audit_fixture_digest_a,
    process_spec_digest: audit_fixture_digest_b,
  }
  let integration_receipt : @control.IntegrationReceipt = {
    id: @control.IntegrationReceiptId("cancellation-goal-integration"),
    intent_id: @control.IntegrationIntentId("cancellation-goal-intent"),
    goal_id: base.goal.id,
    part_id: base.part.id,
    candidate_id: candidate.id,
    candidate_commit_oid: candidate.commit_oid,
    candidate_tree_oid: candidate.tree_oid,
    from_head_oid: base.task_contract.base_commit_oid,
    promotion_commit_oid: promotion_commit,
    promotion_tree_oid: promotion_tree,
    witness_ref: "refs/choir/witness/cancellation-goal-intent",
    integrated_at: 110L,
  }
  let integrated : @workflow.PartWorkflowSnapshot = {
    ..base,
    task_contract: {
      ..base.task_contract,
      verification_specs: [verification_spec],
    },
    part: {
      ..base.part,
      lifecycle: @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId("cancellation-goal-integration"),
      ),
    },
    stage: @workflow.PartWorkflowStage::PartIntegrated,
    integration_receipt: Some(integration_receipt),
  }
  let repository_id = @workflow.RepositoryId("cancellation-repository")
  let goal_ref = @workflow.goal_execution_ref(base.goal.id)
  let branch_receipt : @workflow.GoalBranchInitReceipt = {
    intent_id: @workflow.GoalBranchInitIntentId("cancellation-branch-intent"),
    idempotency_key: audit_fixture_digest_a,
    repository_id,
    goal_ref,
    initialized_oid: base.task_contract.base_commit_oid,
    initialization_witness_ref: @workflow.GitRefName(
      "refs/choir/witness/cancellation-branch",
    ),
    observed_at: 100L,
  }
  let execution : @workflow.GoalExecutionRecord = {
    goal: base.goal,
    repository_id,
    selection_decision_digest: audit_fixture_digest_a,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: base.task_contract.base_commit_oid,
    base_tree_oid: base.task_contract.base_tree_oid,
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    goal_ref,
    branch_initialization: {
      intent_id: branch_receipt.intent_id,
      goal_id: base.goal.id,
      repository_id,
      goal_ref,
      captured_base_oid: base.task_contract.base_commit_oid,
      initialization_witness_ref: branch_receipt.initialization_witness_ref,
      idempotency_key: branch_receipt.idempotency_key,
      lifecycle: @workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted,
      receipt: Some(branch_receipt),
    },
    source_claims: [
      @workflow.receipted_goal_source_claim(
        base.goal.id,
        integrated.part.id,
        audit_fixture_digest_a,
        audit_fixture_digest_a,
        99L,
      ),
    ],
    maximum_parallel_parts: 1,
    policy_revisions: [@workflow.initial_goal_policy_revision(base.goal.id, 1)],
    part_workflow_ids: [integrated.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionAssuring,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 3,
    fencing_epoch: base.fencing_epoch,
  }
  let planned = match
    @workflow.initialize_goal_assurance(
      execution,
      [integrated],
      promotion_commit,
      promotion_tree,
      [verification_spec],
      cancellation_goal_assurance_identities(base.goal, promotion_commit),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((execution, planned))
}

///|
pub fn seal_atomicity_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("seal.atomicity"),
    run: fn(_) {
      let (execution, planned) = match cancellation_goal_assurance_fixture() {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let authorized = match
        @workflow.authorize_goal_assurance_seal(
          planned,
          execution.goal,
          planned.seal_intent.expected_head_oid,
          planned.seal_intent.expected_tree_oid,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let witnessed = match
        @workflow.record_goal_assurance_seal_witness(
          authorized,
          @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessApplied(
            planned.seal_intent.expected_head_oid,
            planned.seal_intent.expected_head_oid,
            planned.seal_intent.expected_tree_oid,
          ),
          120L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let seal_id = @control.GoalBranchSealId("atomic-goal-seal")
      let first = match
        @workflow.commit_goal_assurance_seal(witnessed, seal_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let replay = match
        @workflow.commit_goal_assurance_seal(witnessed, seal_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let immutable_replay = first == replay && first.seal is Some(_)
      let planned_effect = match
        @workflow.plan_next_goal_assurance_effect(first) {
        Ok(Some(value)) => value
        Ok(None) =>
          return Err(
            audit_fixture_error("sealed Goal scheduled no verification"),
          )
        Err(error) => return Err(error)
      }
      let persisted = match
        @workflow.persist_planned_goal_assurance_effect(first, planned_effect) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let replayed_effect = match
        @workflow.plan_next_goal_assurance_effect(persisted) {
        Ok(Some(value)) => value
        Ok(None) =>
          return Err(audit_fixture_error("pending verification was lost"))
        Err(error) => return Err(error)
      }
      let schedules_once = replayed_effect == planned_effect &&
        @workflow.persist_planned_goal_assurance_effect(
          persisted, replayed_effect,
        )
        is Err(_)
      let late_promotion_denied = @workflow.advance_goal_execution_state(
          execution,
          @workflow.GoalExecutionState::GoalExecutionRunning,
        )
        is Err(_) &&
        @workflow.commit_goal_assurance_seal(first, seal_id) is Err(_)
      if !immutable_replay || !schedules_once || !late_promotion_denied {
        return Err(audit_fixture_error("Goal seal atomicity invariant failed"))
      }
      Ok({
        evidence: [
          ObservedSealCase(
            SealAtomicity,
            immutable_replay,
            schedules_once,
            late_promotion_denied,
          ),
        ],
      })
    },
  }
}

///|
fn cancellation_audited_goal_fixture() -> Result[
  (@workflow.GoalExecutionRecord, @workflow.GoalAssuranceRecord),
  @types.ChoirError,
] {
  let (execution, planned) = match cancellation_goal_assurance_fixture() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let authorized = match
    @workflow.authorize_goal_assurance_seal(
      planned,
      execution.goal,
      planned.seal_intent.expected_head_oid,
      planned.seal_intent.expected_tree_oid,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let witnessed = match
    @workflow.record_goal_assurance_seal_witness(
      authorized,
      @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessApplied(
        planned.seal_intent.expected_head_oid,
        planned.seal_intent.expected_head_oid,
        planned.seal_intent.expected_tree_oid,
      ),
      120L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let completed_seal = match
    @workflow.commit_goal_assurance_seal(
      witnessed,
      @control.GoalBranchSealId("cancellation-goal-seal"),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let seal = completed_seal.seal.unwrap()
  let verification : @control.GoalVerificationAuthorizationSet = {
    subject_digest: audit_fixture_digest_a,
    receipt_ids: [@control.ReceiptId("cancellation-goal-verification")],
    receipt_set_digest: audit_fixture_digest_a,
    evidence_manifest_digest: audit_fixture_digest_b,
  }
  let subject : @control.GoalAuditSubject = {
    goal_id: execution.goal.id,
    goal_branch_seal_id: seal.id,
    goal_branch_seal_digest: seal.seal_digest,
    goal_head_oid: seal.head_oid,
    goal_tree_oid: seal.tree_oid,
    goal_contract_digest: seal.goal_contract_digest,
    assurance_policy_revision: seal.assurance_policy_revision,
    integration_receipt_set_digest: seal.integration_receipt_set_digest,
    goal_verification_receipt_set_digest: verification.receipt_set_digest,
    goal_verification_evidence_manifest_digest: verification.evidence_manifest_digest,
    subject_digest: audit_fixture_digest_a,
  }
  let result : @control.GoalAuditResult = {
    id: @control.AuditResultId("cancellation-goal-audit-result"),
    audit_take_id: completed_seal.audit_take.id,
    take_fencing_epoch: completed_seal.fencing_epoch,
    audit_harness_session_id: completed_seal.identities.audit_session.id,
    subject,
    auditor_capability_profile_digest: audit_fixture_digest_a,
    effective_surface_manifest_digest: audit_fixture_digest_b,
    provider_conformance_report_digest: audit_fixture_digest_a,
    audit_policy_digest: completed_seal.assurance_policy_digest,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 121L,
    finished_at: 122L,
    outcome: @control.AuditOutcome::AuditPassed,
    result_digest: audit_fixture_digest_b,
  }
  let receipt : @control.GoalAuditReceipt = {
    receipt_id: @control.ReceiptId("cancellation-goal-audit-receipt"),
    audit_result_id: result.id,
    audit_result_digest: result.result_digest,
    subject,
    audit_take_id: result.audit_take_id,
    audit_harness_session_id: result.audit_harness_session_id,
    audit_sandbox_generation_id: completed_seal.identities.audit_sandbox.generation_id,
    auditor_capability_profile_digest: result.auditor_capability_profile_digest,
    provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
    provider_identity: "codex-subscription-conformance",
    model_identity: @control.ModelIdentity::UnreportedModelIdentity,
    provider_conformance_report_digest: result.provider_conformance_report_digest,
    audit_policy_digest: result.audit_policy_digest,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: result.started_at,
    finished_at: result.finished_at,
    outcome: result.outcome,
  }
  let audited : @workflow.GoalAssuranceRecord = {
    ..completed_seal,
    verification_authorization: Some(verification),
    audit_subject: Some(subject),
    audit_result: Some(result),
    audit_receipt: Some(receipt),
    audit_take: {
      ..completed_seal.audit_take,
      lifecycle: @control.TakeLifecycle::TakeTerminal(
        @control.TakeTerminalDisposition::TakeSucceeded,
      ),
    },
    stage: @workflow.GoalAssuranceStage::GoalAudited,
    durable_version: completed_seal.durable_version + 1,
  }
  match
    @workflow.decode_goal_assurance_record(
      @workflow.goal_assurance_record_bytes(audited),
    ) {
    Ok(round_trip) if round_trip == audited =>
      Ok(
        (
          {
            ..execution,
            state: @workflow.GoalExecutionState::GoalExecutionAssured,
            durable_version: execution.durable_version + 1,
          },
          audited,
        ),
      )
    Ok(_) => Err(audit_fixture_error("audited Goal round trip changed"))
    Err(error) => Err(error)
  }
}

///|
fn cancellation_integration_intent(
  snapshot : @workflow.PartWorkflowSnapshot,
  authorized : Bool,
) -> @control.IntegrationIntent {
  let candidate = snapshot.candidate.unwrap()
  {
    id: @control.IntegrationIntentId(
      if authorized {
        "cancellation-integration-intent"
      } else {
        "cancellation-planned-integration"
      },
    ),
    goal_id: snapshot.goal.id,
    part_id: snapshot.part.id,
    candidate_id: candidate.id,
    candidate_commit_oid: candidate.commit_oid,
    candidate_tree_oid: candidate.tree_oid,
    expected_goal_head_oid: snapshot.task_contract.base_commit_oid,
    strategy: @control.PromotionStrategy::NoFastForwardThreeWayV1,
    promotion_metadata_digest: audit_fixture_digest_a,
    integration_lease_epoch: snapshot.fencing_epoch,
    lifecycle: if authorized {
      @control.IntegrationIntentLifecycle::IntegrationAuthorized
    } else {
      @control.IntegrationIntentLifecycle::IntegrationPlanned
    },
    promotion_commit_oid: if authorized {
      Some(@control.GitOid("cancellation-promotion"))
    } else {
      None
    },
    promotion_tree_oid: if authorized {
      Some(@control.GitOid("cancellation-promotion-tree"))
    } else {
      None
    },
    git_witness_ref: "refs/choir/witness/cancellation-integration-intent",
  }
}

///|
fn cancellation_integration_effect(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.PartEffectIntent {
  let intent = cancellation_integration_intent(snapshot, true)
  let promotion : @control.PromotionCommit = {
    intent_id: intent.id,
    commit_oid: intent.promotion_commit_oid.unwrap(),
    tree_oid: intent.promotion_tree_oid.unwrap(),
    first_parent_oid: intent.expected_goal_head_oid,
    second_parent_oid: intent.candidate_commit_oid,
  }
  {
    effect_id: "cancellation-integration-effect",
    kind: @workflow.PartEffectKind::ApplyIntegration(intent.id, promotion),
    request_digest: audit_fixture_digest_b,
    lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
  }
}

///|
fn cancellation_planned_integration_effect(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.PartEffectIntent {
  let intent = cancellation_integration_intent(snapshot, false)
  {
    effect_id: "cancellation-planned-integration-effect",
    kind: @workflow.PartEffectKind::GeneratePromotion(intent),
    request_digest: audit_fixture_digest_b,
    lifecycle: @workflow.PartEffectLifecycle::PartEffectPlanned,
  }
}

///|
fn cancellation_provider_effect(
  snapshot : @workflow.PartWorkflowSnapshot,
  lifecycle : @workflow.PartEffectLifecycle,
) -> @workflow.PartEffectIntent {
  {
    effect_id: "cancellation-provider-effect",
    kind: @workflow.PartEffectKind::DispatchAudit(
      snapshot.audit_take.id,
      {
        effect_id: "cancellation-audit-command",
        session_id: snapshot.identities.audit_session.id,
        command_id: @control.HarnessCommandId("cancellation-audit-command-1"),
        command_sequence: 1,
        required_provider_cursor: None,
        command_artifact_digest: audit_fixture_digest_a,
        provider_idempotency_token: Some("cancellation-audit-command"),
      },
      snapshot.audit_subject.unwrap(),
    ),
    request_digest: audit_fixture_digest_a,
    lifecycle,
  }
}

///|
fn cancellation_snapshot_round_trips(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> Bool {
  match
    @workflow.decode_part_snapshot(@workflow.part_snapshot_bytes(snapshot)) {
    Ok(decoded) => decoded == snapshot
    Err(_) => false
  }
}

///|
pub fn cancellation_part_effect_ordering_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("cancellation.part_effect_ordering"),
    run: fn(_) {
      let base = audit_workflow_result_fixture()
      let planned_provider = @workflow.record_part_goal_cancellation({
        ..base,
        pending_effect: Some(
          cancellation_provider_effect(
            base,
            @workflow.PartEffectLifecycle::PartEffectPlanned,
          ),
        ),
      })
      let authorized_provider = @workflow.record_part_goal_cancellation({
        ..base,
        pending_effect: Some(
          cancellation_provider_effect(
            base,
            @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
          ),
        ),
      })
      let planned_integration = @workflow.record_part_goal_cancellation({
        ..base,
        pending_effect: Some(cancellation_planned_integration_effect(base)),
      })
      let authorized_effect = cancellation_integration_effect(base)
      let authorized_integration = @workflow.record_part_goal_cancellation({
        ..base,
        pending_effect: Some(authorized_effect),
      })
      let results = [
        planned_provider, authorized_provider, planned_integration, authorized_integration,
      ]
      if results.any(fn(result) { result is Err(_) }) {
        return Err(audit_fixture_error("cancellation ordering was rejected"))
      }
      let planned_provider = planned_provider.unwrap()
      let authorized_provider = authorized_provider.unwrap()
      let planned_integration = planned_integration.unwrap()
      let authorized_integration = authorized_integration.unwrap()
      let authorized_replay_is_stable = match
        @workflow.record_part_goal_cancellation(authorized_integration) {
        Ok(replayed) => replayed == authorized_integration
        Err(_) => false
      }
      if planned_provider.pending_effect.unwrap().lifecycle !=
        @workflow.PartEffectLifecycle::PartEffectAbandonedByCancellation ||
        authorized_provider.pending_effect.unwrap().lifecycle !=
        @workflow.PartEffectLifecycle::PartEffectUncertain ||
        planned_integration.pending_effect.unwrap().lifecycle !=
        @workflow.PartEffectLifecycle::PartEffectAbandonedByCancellation ||
        !@workflow.part_cancellation_disposition_is_known(planned_provider) ||
        !@workflow.part_cancellation_disposition_is_known(authorized_provider) ||
        !@workflow.part_cancellation_disposition_is_known(planned_integration) ||
        authorized_integration.pending_effect != Some(authorized_effect) ||
        @workflow.part_cancellation_disposition_is_known(authorized_integration) ||
        !authorized_replay_is_stable ||
        results.any(fn(result) {
          cancellation_snapshot_round_trips(result.unwrap()) == false
        }) {
        return Err(
          audit_fixture_error("cancellation disposition violated its ordering"),
        )
      }
      Ok({
        evidence: [
          ObservedCancellationCase(CancellationPartEffectOrdering, 4, 3, true),
        ],
      })
    },
  }
}

///|
pub fn cancellation_ordering_matrix_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("cancellation.ordering_matrix"),
    run: fn(context) {
      match (branch_initialization_faults_case().run)(context) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      match (cancellation_part_effect_ordering_case().run)(context) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      let (assuring_execution, planned_assurance) = match
        cancellation_goal_assurance_fixture() {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let abandoned_assurance = match
        @workflow.record_goal_assurance_cancellation(planned_assurance) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let authorized_assurance = match
        @workflow.authorize_goal_assurance_seal(
          planned_assurance,
          assuring_execution.goal,
          planned_assurance.seal_intent.expected_head_oid,
          planned_assurance.seal_intent.expected_tree_oid,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let authorized_waits = match
        @workflow.record_goal_assurance_cancellation(authorized_assurance) {
        Ok(value) =>
          value == authorized_assurance &&
          !@workflow.goal_assurance_cancellation_disposition_is_known(value)
        Err(_) => false
      }
      let witnessed_assurance = match
        @workflow.record_goal_assurance_seal_witness(
          authorized_assurance,
          @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessApplied(
            authorized_assurance.seal_intent.expected_head_oid,
            authorized_assurance.seal_intent.expected_head_oid,
            authorized_assurance.seal_intent.expected_tree_oid,
          ),
          130L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let canceled_witness = match
        @workflow.record_goal_assurance_cancellation(witnessed_assurance) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let (execution, audited) = match cancellation_audited_goal_fixture() {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let sealed_for_effect = {
        ..audited,
        stage: @workflow.GoalAssuranceStage::GoalSealed,
      }
      let planned_effect = match
        @workflow.plan_next_goal_assurance_effect(sealed_for_effect) {
        Ok(Some(intent)) =>
          match
            @workflow.persist_planned_goal_assurance_effect(
              sealed_for_effect, intent,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
        Ok(None) =>
          return Err(audit_fixture_error("assurance effect was absent"))
        Err(error) => return Err(error)
      }
      let abandoned_effect = match
        @workflow.record_goal_assurance_cancellation(planned_effect) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let authorized_effect = match
        @workflow.authorize_pending_goal_assurance_effect(planned_effect) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let uncertain_effect = match
        @workflow.record_goal_assurance_cancellation(authorized_effect) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let canceled_audited = match
        @workflow.record_goal_assurance_cancellation(audited) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let assurance_rows_hold = @workflow.goal_assurance_cancellation_disposition_is_known(
          abandoned_assurance,
        ) &&
        abandoned_assurance.seal_intent.lifecycle ==
        @control.GoalBranchSealIntentLifecycle::GoalBranchSealAbandonedByCancellation &&
        authorized_waits &&
        @workflow.goal_assurance_cancellation_disposition_is_known(
          canceled_witness,
        ) &&
        canceled_witness.seal_intent.lifecycle ==
        @control.GoalBranchSealIntentLifecycle::GoalBranchSealWitnessed &&
        abandoned_effect.pending_effect
        is Some(
          {
            lifecycle: @workflow.GoalAssuranceEffectLifecycle::GoalAssuranceEffectAbandonedByCancellation,
            ..,
          }
        ) &&
        uncertain_effect.pending_effect
        is Some(
          {
            lifecycle: @workflow.GoalAssuranceEffectLifecycle::GoalAssuranceEffectUncertain,
            ..,
          }
        ) &&
        @workflow.goal_assurance_cancellation_disposition_is_known(
          canceled_audited,
        ) &&
        canceled_audited.seal == audited.seal
      if !assurance_rows_hold {
        return Err(audit_fixture_error("Goal assurance ordering failed"))
      }
      let publication = match
        @workflow.initialize_goal_publication(
          execution,
          audited,
          @workflow.RemoteRepositoryId("cancellation-remote"),
          @workflow.RemoteName("origin"),
          @workflow.GitRefName("refs/heads/choir-cancellation"),
          None,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let abandoned_publication = match
        @workflow.record_goal_publication_cancellation(
          publication,
          @workflow.RemoteBranchObservation::RemoteBranchAbsent,
          140L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let authorized_publication = match
        @workflow.authorize_goal_publication(
          publication,
          execution,
          audited,
          publication.intent.sealed_head_oid,
          @workflow.RemoteBranchObservation::RemoteBranchAbsent,
          false,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let abandoned_authorized_publication = match
        @workflow.record_goal_publication_cancellation(
          authorized_publication,
          @workflow.RemoteBranchObservation::RemoteBranchAbsent,
          141L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let uncertain_publication = match
        @workflow.record_goal_publication_observation(
          authorized_publication,
          @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
          @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
          None,
          142L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let canceled_uncertain_publication = match
        @workflow.record_goal_publication_cancellation(
          uncertain_publication,
          @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain,
          143L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let published = match
        @workflow.record_goal_publication_cancellation(
          authorized_publication,
          @workflow.RemoteBranchObservation::RemoteBranchAt(
            publication.intent.sealed_head_oid,
          ),
          144L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let publication_rows_hold = abandoned_publication.intent.state ==
        @workflow.BranchPublicationState::BranchPublicationAbandonedByCancellation &&
        abandoned_authorized_publication.intent.state ==
        @workflow.BranchPublicationState::BranchPublicationAbandonedByCancellation &&
        canceled_uncertain_publication.intent.state ==
        @workflow.BranchPublicationState::BranchPublicationMutationUncertain &&
        published.intent.state ==
        @workflow.BranchPublicationState::BranchPublicationReceipted &&
        [
          abandoned_publication, abandoned_authorized_publication, canceled_uncertain_publication,
          published,
        ].all(@workflow.goal_publication_cancellation_disposition_is_known)
      if !publication_rows_hold {
        return Err(audit_fixture_error("publication ordering failed"))
      }
      let marker = match
        @workflow.goal_pull_request_identity_marker(
          execution,
          published,
          @workflow.RemoteRepositoryId("cancellation-base-remote"),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let document : @workflow.PullRequestDocument = {
        title: "test: cancellation ordering",
        body: "Cancellation evidence\n\n" + marker.0,
      }
      let pull_request = match
        @workflow.initialize_goal_pull_request(
          execution,
          audited,
          published,
          @workflow.PullRequestProvider::GitHubPullRequestProvider,
          @workflow.RemoteRepositoryId("cancellation-base-remote"),
          document,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let remote : @workflow.RemotePullRequestSnapshot = {
        remote_id: @workflow.RemotePullRequestId("cancellation-pr"),
        number: @workflow.PullRequestNumber(42),
        url: @workflow.PullRequestUrl("https://example.invalid/cancellation/42"),
        provider_repository_id: pull_request.intent.canonical_repository_id,
        head_repository_id: pull_request.intent.head_repository_id,
        head_ref: pull_request.intent.head_ref,
        base_repository_id: pull_request.intent.base_repository_id,
        base_ref: pull_request.intent.base_ref,
        observed_head_oid: pull_request.intent.expected_head_oid,
        state: @workflow.RemotePullRequestState::RemotePullRequestOpen,
        marker_state: @workflow.PullRequestMarkerState::PullRequestMarkerExact,
        title_digest: audit_fixture_digest_a,
        body_digest: audit_fixture_digest_b,
        goal_contract_link_present: true,
        evidence_manifest_link_present: true,
      }
      let abandoned_pull_request = match
        @workflow.record_goal_pull_request_cancellation(
          pull_request,
          @workflow.PullRequestLookupObservation::PullRequestNoMatch,
          150L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let authorized_pull_request = match
        @workflow.authorize_goal_pull_request(
          pull_request,
          execution,
          audited,
          published,
          pull_request.intent.expected_head_oid,
          @workflow.PullRequestLookupObservation::PullRequestNoMatch,
          151L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let abandoned_authorized_pull_request = match
        @workflow.record_goal_pull_request_cancellation(
          authorized_pull_request,
          @workflow.PullRequestLookupObservation::PullRequestNoMatch,
          152L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let issued = match
        @workflow.mark_goal_pull_request_create_may_have_been_issued(
          authorized_pull_request, execution, audited, published,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let uncertain_pull_request = match
        @workflow.record_goal_pull_request_cancellation(
          issued,
          @workflow.PullRequestLookupObservation::PullRequestNoMatch,
          153L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let receipted_pull_request = match
        @workflow.record_goal_pull_request_cancellation(
          issued,
          @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
            remote,
          ),
          154L,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let pr_rows_hold = abandoned_pull_request.intent.state ==
        @workflow.PullRequestIntentState::PullRequestAbandonedByCancellation &&
        abandoned_authorized_pull_request.intent.state ==
        @workflow.PullRequestIntentState::PullRequestAbandonedByCancellation &&
        uncertain_pull_request.intent.state ==
        @workflow.PullRequestIntentState::PullRequestRemoteCreateUncertain &&
        receipted_pull_request.intent.state ==
        @workflow.PullRequestIntentState::PullRequestReceipted &&
        [
          abandoned_pull_request, abandoned_authorized_pull_request, uncertain_pull_request,
          receipted_pull_request,
        ].all(@workflow.goal_pull_request_cancellation_disposition_is_known)
      if !pr_rows_hold {
        return Err(audit_fixture_error("pull-request ordering failed"))
      }
      let cutoff = @control.EventSequence(200L)
      let canceling_goal = match
        @control.transition_goal(
          execution.goal,
          @control.GoalTransition::RequestGoalCancellation(cutoff),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let cancellation_wins = @control.transition_goal(
        canceling_goal,
        @control.GoalTransition::CommitGoalCancellation(
          @control.CancellationSummaryId("cancellation-matrix"),
        ),
      )
      let success_after_cutoff = @control.transition_goal(
        canceling_goal,
        @control.GoalTransition::CommitGoalSuccess(
          @control.FinalizationId("late-success"),
        ),
      )
      let succeeded_goal = match
        @control.transition_goal(
          execution.goal,
          @control.GoalTransition::CommitGoalSuccess(
            @control.FinalizationId("success-first"),
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let cancellation_after_success = @control.transition_goal(
        succeeded_goal,
        @control.GoalTransition::RequestGoalCancellation(cutoff),
      )
      if !(cancellation_wins is Ok(_)) ||
        !(success_after_cutoff is Err(_)) ||
        !(cancellation_after_success is Err(_)) {
        return Err(audit_fixture_error("terminal ordering race failed"))
      }
      let assurance_replay = match
        @workflow.record_goal_assurance_cancellation(canceled_audited) {
        Ok(value) => value == canceled_audited
        Err(_) => false
      }
      let publication_replay = match
        @workflow.record_goal_publication_cancellation(
          published,
          @workflow.RemoteBranchObservation::RemoteBranchAt(
            published.intent.sealed_head_oid,
          ),
          160L,
        ) {
        Ok(value) => value == published
        Err(_) => false
      }
      let pull_request_replay = match
        @workflow.record_goal_pull_request_cancellation(
          receipted_pull_request,
          @workflow.PullRequestLookupObservation::PullRequestStoredIdMatch(
            remote,
          ),
          160L,
        ) {
        Ok(value) => value == receipted_pull_request
        Err(_) => false
      }
      let replay_stable = assurance_replay &&
        publication_replay &&
        pull_request_replay
      if !replay_stable {
        return Err(audit_fixture_error("cancellation replay changed state"))
      }
      Ok({
        evidence: [
          ObservedCancellationCase(
            CancellationGoalOrderingMatrix,
            23,
            22,
            replay_stable,
          ),
        ],
      })
    },
  }
}

///|
pub fn audit_result_reconcile_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("audit.result_reconcile"),
    run: fn(context) {
      let point = FaultPoint::AuditAfterResultTransactionBeforeReceiptTransaction
      if !context.fault_enabled(point) {
        return Err(
          audit_fixture_error("result transaction fault was not injected"),
        )
      }
      let durable_result = audit_workflow_result_fixture()
      let restarted = match
        @workflow.decode_part_snapshot(
          @workflow.part_snapshot_bytes(durable_result),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let receipted = match
        @workflow.mint_part_audit_receipt(
          restarted,
          audit_workflow_metadata(),
          fn(_) { true },
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if receipted.stage != @workflow.PartWorkflowStage::PartAudited ||
        receipted.audit_receipt is None ||
        !(audit_workflow_gate(receipted)
        is @control.AuditGateObservation::AuditGateValid(_)) {
        return Err(audit_fixture_error("durable result did not reconcile once"))
      }
      Ok({
        evidence: [
          ObservedFault(point),
          ObservedAuditCase(AuditResultReconciliation, 1, 0),
        ],
      })
    },
  }
}

///|
pub fn audit_receipt_replay_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("audit.receipt_replay"),
    run: fn(context) {
      let point = FaultPoint::AuditAfterReceiptTransactionBeforeGateEvaluation
      if !context.fault_enabled(point) {
        return Err(
          audit_fixture_error("receipt transaction fault was not injected"),
        )
      }
      let receipted = match
        @workflow.mint_part_audit_receipt(
          audit_workflow_result_fixture(),
          audit_workflow_metadata(),
          fn(_) { true },
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let restarted = match
        @workflow.decode_part_snapshot(@workflow.part_snapshot_bytes(receipted)) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let duplicate_mint = @workflow.mint_part_audit_receipt(
        restarted,
        audit_workflow_metadata(),
        fn(_) { true },
      )
      if restarted != receipted ||
        !(duplicate_mint is Err(_)) ||
        !(audit_workflow_gate(restarted)
        is @control.AuditGateObservation::AuditGateValid(_)) {
        return Err(audit_fixture_error("receipt replay repeated producer work"))
      }
      Ok({
        evidence: [
          ObservedFault(point),
          ObservedAuditCase(AuditReceiptReplay, 1, 0),
        ],
      })
    },
  }
}

///|
pub fn audit_protocol_conflict_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("audit.protocol_conflict"),
    run: fn(_) {
      let base = audit_workflow_result_fixture()
      let subject = base.audit_subject.unwrap()
      let session = {
        ..base.identities.audit_session,
        provider_cursor: None,
        last_choir_sequence: @control.EventSequence(0L),
        lifecycle: @control.HarnessSessionLifecycle::HarnessSessionAwaitingEvents,
      }
      let intent : @workflow.PartEffectIntent = {
        effect_id: "audit-conflicting-delivery",
        kind: @workflow.PartEffectKind::DispatchAudit(
          base.audit_take.id,
          {
            effect_id: "audit-conflicting-command",
            session_id: session.id,
            command_id: @control.HarnessCommandId("audit-conflicting-command-1"),
            command_sequence: 1,
            required_provider_cursor: None,
            command_artifact_digest: audit_fixture_digest_a,
            provider_idempotency_token: Some("audit-conflicting-command"),
          },
          subject,
        ),
        request_digest: audit_fixture_digest_a,
        lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
      }
      let authorized = {
        ..base,
        stage: @workflow.PartWorkflowStage::PartAuditHarnessStarted,
        identities: { ..base.identities, audit_session: session },
        audit_take: {
          ..base.audit_take,
          fencing_epoch: Some(base.fencing_epoch),
          lifecycle: @control.TakeLifecycle::TakeRunning,
        },
        harness_sessions: base.harness_sessions.map(fn(candidate) {
          if candidate.id == session.id {
            session
          } else {
            candidate
          }
        }),
        audit_result: None,
        audit_receipt: None,
        pending_effect: Some(intent),
      }
      let violated = match
        @workflow.record_part_provider_protocol_violation(authorized, intent) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let session_fenced = violated.harness_sessions.any(fn(candidate) {
        candidate.id == session.id &&
        candidate.lifecycle ==
        @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated
      })
      if violated.stage != @workflow.PartWorkflowStage::PartRecoveryUncertain ||
        violated.audit_receipt is Some(_) ||
        !session_fenced ||
        !(violated.audit_take.lifecycle
        is @control.TakeLifecycle::TakeTerminal(
          @control.TakeTerminalDisposition::TakeRecoveryUncertain(
            @control.TakeUncertaintyReason::TakeProtocolViolation
          )
        )) {
        return Err(audit_fixture_error("conflicting audit was not fenced"))
      }
      Ok({ evidence: [ObservedAuditCase(AuditProtocolConflictFence, 1, 0)] })
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

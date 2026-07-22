///|
let schedule_digest : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
fn scheduling_record(
  id : String,
  dependencies : Array[@control.PartId],
  lifecycle : @control.PartLifecycle,
  declaration : @control.MutationDeclaration,
) -> @workflow.GoalPartSchedulingRecord {
  let part_id = @control.PartId(id)
  let revision_id = @control.RevisionId("revision-" + id)
  {
    part: {
      id: part_id,
      goal_id: @control.GoalId("goal-schedule"),
      dependency_ids: dependencies,
      task_contract_revision_id: revision_id,
      lifecycle,
    },
    task_contract: {
      id: revision_id,
      goal_id: @control.GoalId("goal-schedule"),
      part_id,
      revision: 1,
      digest: schedule_digest,
      repair_conflict_id: None,
      instruction_artifact: {
        artifact_id: "instruction-" + id,
        digest: schedule_digest,
      },
      base_commit_oid: @control.GitOid("shared-base"),
      base_tree_oid: @control.GitOid("shared-tree"),
      path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
      mutation_declaration: declaration,
      verification_specs: [
        {
          id: @control.VerificationSpecId("verify-" + id),
          version: 1,
          digest: schedule_digest,
          process_spec_digest: schedule_digest,
        },
      ],
      audit_policy_digest: schedule_digest,
      migration_contract_ref: None,
      implementation_capability_profile_digest: schedule_digest,
      verification_capability_profile_digest: schedule_digest,
      audit_capability_profile_digest: schedule_digest,
    },
  }
}

///|
fn generated_part_id(index : Int) -> @control.PartId {
  @control.PartId("generated-part-" + index.to_string())
}

///|
fn generated_mutation_declaration(
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
fn generated_scheduling_records(
  seed : Int,
  count : Int,
) -> Array[@workflow.GoalPartSchedulingRecord] {
  let records : Array[@workflow.GoalPartSchedulingRecord] = []
  for index = 0; index < count; index = index + 1 {
    let dependencies : Array[@control.PartId] = []
    if index > 0 && (seed + index) % 3 != 0 {
      dependencies.push(generated_part_id(index - 1))
    }
    if index > 3 && (seed + index * 3) % 5 == 0 {
      let earlier = generated_part_id(index - 3)
      if !dependencies.contains(earlier) {
        dependencies.push(earlier)
      }
    }
    records.push(
      scheduling_record(
        generated_part_id(index).0,
        dependencies,
        @control.PartLifecycle::PartPending,
        generated_mutation_declaration(seed, index),
      ),
    )
  }
  records
}

///|
fn replace_generated_part_lifecycle(
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
fn generated_scheduling_record_by_id(
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
fn assert_generated_admission_is_safe(
  records : Array[@workflow.GoalPartSchedulingRecord],
  admitted_part_ids : Array[@control.PartId],
  maximum_parallel_parts : Int,
) -> Unit raise {
  assert_true(admitted_part_ids.length() <= maximum_parallel_parts)
  for index, part_id in admitted_part_ids {
    let record = match generated_scheduling_record_by_id(records, part_id) {
      Some(value) => value
      None => fail("scheduler admitted an unknown generated Part")
    }
    for dependency_id in record.part.dependency_ids {
      let dependency = match
        generated_scheduling_record_by_id(records, dependency_id) {
        Some(value) => value
        None => fail("generated dependency disappeared")
      }
      assert_true(
        dependency.part.lifecycle is @control.PartLifecycle::PartIntegrated(_),
      )
    }
    for other_index = index + 1
        other_index < admitted_part_ids.length()
        other_index = other_index + 1 {
      let other_id = admitted_part_ids[other_index]
      let other = match generated_scheduling_record_by_id(records, other_id) {
        Some(value) => value
        None => fail("scheduler admitted an unknown generated Part")
      }
      assert_false(
        @control.mutation_declarations_conflict(
          record.task_contract.mutation_declaration,
          other.task_contract.mutation_declaration,
        ),
      )
    }
  }
}

///|
fn complete_generated_schedule(
  source : Array[@workflow.GoalPartSchedulingRecord],
  maximum_parallel_parts : Int,
) -> Array[@control.PartId] raise {
  let mut records = source
  let admission_order : Array[@control.PartId] = []
  let mut remaining = records.length()
  while remaining > 0 {
    let schedule = match
      @workflow.schedule_goal_parts(records, maximum_parallel_parts) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
    if schedule.admitted_part_ids.length() == 0 {
      fail("generated acyclic schedule made no progress")
    }
    assert_generated_admission_is_safe(
      records,
      schedule.admitted_part_ids,
      maximum_parallel_parts,
    )
    for part_id in schedule.admitted_part_ids {
      admission_order.push(part_id)
      records = replace_generated_part_lifecycle(
        records,
        part_id,
        @control.PartLifecycle::PartIntegrated(
          @control.ReceiptId("generated-integration-" + part_id.0),
        ),
      )
      remaining = remaining - 1
    }
  }
  admission_order
}

///|
fn generated_promotion_order(
  source : Array[@workflow.GoalPartSchedulingRecord],
) -> Array[@control.PartId] raise {
  let mut records = source.map(fn(record) {
    {
      ..record,
      part: {
        ..record.part,
        lifecycle: @control.PartLifecycle::PartAudited(
          @control.CandidateId("generated-candidate-" + record.part.id.0),
          schedule_digest,
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
      Ok(None) => fail("generated promotion order made no progress")
      Err(error) => fail(error.message())
    }
    order.push(selection.part_id)
    records = replace_generated_part_lifecycle(
      records,
      selection.part_id,
      @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId("generated-integration-" + selection.part_id.0),
      ),
    )
  }
  order
}

///|
test "scheduler admits independent Parts in stable order" {
  let part_a = scheduling_record(
    "a",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::PathTree(@control.RepoPath("src/a")),
    ]),
  )
  let part_b = scheduling_record(
    "b",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::PathTree(@control.RepoPath("src/b")),
    ]),
  )
  let part_c = scheduling_record(
    "c",
    [part_a.part.id],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::PathTree(@control.RepoPath("src/c")),
    ]),
  )
  let schedule = match
    @workflow.schedule_goal_parts([part_c, part_b, part_a], 3) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(schedule.admitted_part_ids, [part_a.part.id, part_b.part.id])
  assert_eq(
    schedule.decisions[2].admission,
    @workflow.GoalPartAdmission::GoalPartWaitingOnDependencies([part_a.part.id]),
  )
}

///|
test "scheduler serializes overlapping and unknown mutation declarations" {
  let part_a = scheduling_record(
    "a",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::PathTree(@control.RepoPath("src/shared")),
    ]),
  )
  let part_b = scheduling_record(
    "b",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::ExactPath(
        @control.RepoPath("src/shared/file.mbt"),
      ),
    ]),
  )
  let part_c = scheduling_record(
    "c",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::MissingMutationDeclaration,
  )
  let schedule = match
    @workflow.schedule_goal_parts([part_c, part_b, part_a], 3) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(schedule.admitted_part_ids, [part_a.part.id])
  assert_eq(
    schedule.decisions[1].admission,
    @workflow.GoalPartAdmission::GoalPartDeferredByMutationConflict([
      part_a.part.id,
    ]),
  )
  assert_eq(
    schedule.decisions[2].admission,
    @workflow.GoalPartAdmission::GoalPartDeferredByMutationConflict([
      part_a.part.id,
    ]),
  )
}

///|
test "running Part keeps its mutation and capacity reservation" {
  let running = scheduling_record(
    "b",
    [],
    @control.PartLifecycle::PartExecuting(@control.TakeId("take-b")),
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::ExactPath(@control.RepoPath("src/shared.mbt")),
    ]),
  )
  let conflicting = scheduling_record(
    "c",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::ExactPath(@control.RepoPath("src/shared.mbt")),
    ]),
  )
  let conflict_schedule = match
    @workflow.schedule_goal_parts([conflicting, running], 2) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(conflict_schedule.admitted_part_ids.length(), 0)
  assert_eq(
    conflict_schedule.decisions[1].admission,
    @workflow.GoalPartAdmission::GoalPartDeferredByMutationConflict([
      running.part.id,
    ]),
  )
  let independent = scheduling_record(
    "a",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let capacity_schedule = match
    @workflow.schedule_goal_parts([independent, running], 1) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(capacity_schedule.admitted_part_ids.length(), 0)
  assert_eq(
    capacity_schedule.decisions[0].admission,
    @workflow.GoalPartAdmission::GoalPartDeferredByCapacity,
  )
}

///|
test "scheduler rejects cyclic dependencies" {
  let part_a_id = @control.PartId("a")
  let part_b_id = @control.PartId("b")
  let part_a = scheduling_record(
    "a",
    [part_b_id],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let part_b = scheduling_record(
    "b",
    [part_a_id],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  assert_true(@workflow.schedule_goal_parts([part_a, part_b], 2) is Err(_))
}

///|
test "promotion selection composes divergent candidates onto the current head" {
  let audit_digest = schedule_digest
  let part_a = scheduling_record(
    "a",
    [],
    @control.PartLifecycle::PartAudited(
      @control.CandidateId("candidate-a"),
      audit_digest,
      @control.ReceiptId("audit-a"),
    ),
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let part_b = scheduling_record(
    "b",
    [],
    @control.PartLifecycle::PartAudited(
      @control.CandidateId("candidate-b"),
      audit_digest,
      @control.ReceiptId("audit-b"),
    ),
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let first = match
    @workflow.select_next_deterministic_promotion(
      [part_b, part_a],
      @control.GitOid("goal-head"),
    ) {
    Ok(Some(value)) => value
    _ => fail("first promotion was not selected")
  }
  assert_eq(first.part_id, part_a.part.id)
  assert_eq(first.expected_goal_head_oid, @control.GitOid("goal-head"))
  let integrated_a = {
    ..part_a,
    part: {
      ..part_a.part,
      lifecycle: @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId("integration-a"),
      ),
    },
  }
  let second = match
    @workflow.select_next_deterministic_promotion(
      [part_b, integrated_a],
      @control.GitOid("promotion-a"),
    ) {
    Ok(Some(value)) => value
    _ => fail("second promotion was not selected")
  }
  assert_eq(second.part_id, part_b.part.id)
  assert_eq(second.expected_goal_head_oid, @control.GitOid("promotion-a"))
}

///|
test "promotion waits for the earliest stable topological rank" {
  let audit_digest = schedule_digest
  let part_a = scheduling_record(
    "a",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let part_b = scheduling_record(
    "b",
    [],
    @control.PartLifecycle::PartAudited(
      @control.CandidateId("candidate-b"),
      audit_digest,
      @control.ReceiptId("audit-b"),
    ),
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  assert_true(
    @workflow.select_next_deterministic_promotion(
      [part_b, part_a],
      @control.GitOid("goal-head"),
    )
    is Ok(None),
  )
  let integrated_a = {
    ..part_a,
    part: {
      ..part_a.part,
      lifecycle: @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId("integration-a"),
      ),
    },
  }
  let selected = match
    @workflow.select_next_deterministic_promotion(
      [part_b, integrated_a],
      @control.GitOid("promotion-a"),
    ) {
    Ok(Some(value)) => value
    _ => fail("next stable promotion rank was not selected")
  }
  assert_eq(selected.part_id, part_b.part.id)
  assert_eq(selected.expected_goal_head_oid, @control.GitOid("promotion-a"))
}

///|
test "fixed-seed generated DAGs schedule safely at several concurrency limits" {
  for seed in [3, 7, 19, 31] {
    let records = generated_scheduling_records(seed, 17)
    let reversed = records.copy()
    reversed.sort_by(fn(left, right) { right.part.id.compare(left.part.id) })
    for maximum_parallel_parts in [1, 2, 4, 7] {
      let forward_order = complete_generated_schedule(
        records, maximum_parallel_parts,
      )
      let reversed_order = complete_generated_schedule(
        reversed, maximum_parallel_parts,
      )
      assert_eq(forward_order, reversed_order)
      assert_eq(forward_order.length(), records.length())
    }
  }
}

///|
test "fixed-seed generated DAG promotion order ignores input permutation" {
  for seed in [5, 11, 23, 37] {
    let records = generated_scheduling_records(seed, 19)
    let reversed = records.copy()
    reversed.sort_by(fn(left, right) { right.part.id.compare(left.part.id) })
    let forward_order = generated_promotion_order(records)
    let reversed_order = generated_promotion_order(reversed)
    assert_eq(forward_order, reversed_order)
    assert_eq(forward_order.length(), records.length())
  }
}

///|
async test "independent Parts execute concurrently and promote deterministically" {
  let part_a = scheduling_record(
    "a",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::PathTree(@control.RepoPath("src/a")),
    ]),
  )
  let part_b = scheduling_record(
    "b",
    [],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::PathTree(@control.RepoPath("src/b")),
    ]),
  )
  let active = @ref.new(0)
  let maximum_active = @ref.new(0)
  let head = @ref.new(@control.GitOid("goal-head"))
  let observed_heads : Array[@control.GitOid] = []
  let result = match
    @workflow.run_goal_parts([part_b, part_a], 2, {
      advance_part: async fn(record) {
        active.val = active.val + 1
        if active.val > maximum_active.val {
          maximum_active.val = active.val
        }
        @async.sleep(0)
        active.val = active.val - 1
        Ok({
          ..record,
          part: {
            ..record.part,
            lifecycle: @control.PartLifecycle::PartAudited(
              @control.CandidateId("candidate-" + record.part.id.0),
              schedule_digest,
              @control.ReceiptId("audit-" + record.part.id.0),
            ),
          },
        })
      },
      read_goal_head: async fn() { Ok(head.val) },
      promote_part: async fn(record, selection) {
        observed_heads.push(selection.expected_goal_head_oid)
        let promotion = @control.GitOid("promotion-" + record.part.id.0)
        head.val = promotion
        Ok({
          ..record,
          part: {
            ..record.part,
            lifecycle: @control.PartLifecycle::PartIntegrated(
              @control.ReceiptId("integration-" + record.part.id.0),
            ),
          },
        })
      },
      resume_promotion: async fn(_) {
        Err(
          @types.ChoirError::validation_error("unexpected promotion recovery"),
        )
      },
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(result.outcome, @workflow.GoalRunOutcome::GoalRunSucceeded)
  assert_eq(maximum_active.val, 2)
  assert_eq(result.promotion_order, [part_a.part.id, part_b.part.id])
  assert_eq(observed_heads, [
    @control.GitOid("goal-head"),
    @control.GitOid("promotion-a"),
  ])
}

///|
async test "promotion recovery completes before new Part execution" {
  let promoting = scheduling_record(
    "a",
    [],
    @control.PartLifecycle::PartPromoting(
      @control.CandidateId("candidate-a"),
      schedule_digest,
      @control.ReceiptId("audit-a"),
    ),
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let pending = scheduling_record(
    "b",
    [promoting.part.id],
    @control.PartLifecycle::PartPending,
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  let events : Array[String] = []
  let head = @ref.new(@control.GitOid("goal-head"))
  let result = match
    @workflow.run_goal_parts([pending, promoting], 2, {
      advance_part: async fn(record) {
        events.push("execute-" + record.part.id.0)
        Ok({
          ..record,
          part: {
            ..record.part,
            lifecycle: @control.PartLifecycle::PartAudited(
              @control.CandidateId("candidate-" + record.part.id.0),
              schedule_digest,
              @control.ReceiptId("audit-" + record.part.id.0),
            ),
          },
        })
      },
      read_goal_head: async fn() { Ok(head.val) },
      promote_part: async fn(record, _) {
        events.push("promote-" + record.part.id.0)
        head.val = @control.GitOid("promotion-" + record.part.id.0)
        Ok({
          ..record,
          part: {
            ..record.part,
            lifecycle: @control.PartLifecycle::PartIntegrated(
              @control.ReceiptId("integration-" + record.part.id.0),
            ),
          },
        })
      },
      resume_promotion: async fn(record) {
        events.push("recover-" + record.part.id.0)
        head.val = @control.GitOid("promotion-" + record.part.id.0)
        Ok({
          ..record,
          part: {
            ..record.part,
            lifecycle: @control.PartLifecycle::PartIntegrated(
              @control.ReceiptId("integration-" + record.part.id.0),
            ),
          },
        })
      },
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(result.outcome, @workflow.GoalRunOutcome::GoalRunSucceeded)
  assert_eq(events, ["recover-a", "execute-b", "promote-b"])
  assert_eq(result.promotion_order, [promoting.part.id, pending.part.id])
}

///|
async test "promotion conflict may return a versioned repair Take" {
  let audited = scheduling_record(
    "repair",
    [],
    @control.PartLifecycle::PartAudited(
      @control.CandidateId("candidate-original"),
      schedule_digest,
      @control.ReceiptId("audit-original"),
    ),
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::ExactPath(@control.RepoPath("src/repair.mbt")),
    ]),
  )
  let promotion_calls = @ref.new(0)
  let result = match
    @workflow.run_goal_parts([audited], 1, {
      advance_part: async fn(record) { Ok(record) },
      read_goal_head: async fn() { Ok(@control.GitOid("goal-head")) },
      promote_part: async fn(record, _) {
        promotion_calls.val = promotion_calls.val + 1
        if promotion_calls.val == 1 {
          let contract = {
            ..record.task_contract,
            id: @control.RevisionId("revision-repair-2"),
            revision: 2,
            repair_conflict_id: Some(
              @control.IntegrationConflictId("integration-conflict-1"),
            ),
          }
          Ok({
            part: {
              ..record.part,
              task_contract_revision_id: contract.id,
              lifecycle: @control.PartLifecycle::PartAudited(
                @control.CandidateId("candidate-repaired"),
                schedule_digest,
                @control.ReceiptId("audit-repaired"),
              ),
            },
            task_contract: contract,
          })
        } else {
          Ok({
            ..record,
            part: {
              ..record.part,
              lifecycle: @control.PartLifecycle::PartIntegrated(
                @control.ReceiptId("integration-repaired"),
              ),
            },
          })
        }
      },
      resume_promotion: async fn(record) { Ok(record) },
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(result.outcome, @workflow.GoalRunOutcome::GoalRunSucceeded)
  assert_eq(promotion_calls.val, 2)
  assert_eq(result.promotion_order, [audited.part.id])
  assert_eq(result.records[0].task_contract.revision, 2)
}

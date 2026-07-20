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
      implementation_capability_profile_digest: schedule_digest,
      verification_capability_profile_digest: schedule_digest,
      audit_capability_profile_digest: schedule_digest,
    },
  }
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

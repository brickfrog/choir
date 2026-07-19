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

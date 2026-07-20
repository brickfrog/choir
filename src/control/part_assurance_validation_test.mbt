///|
let assurance_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let assurance_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn assurance_contract(
  declaration : @control.MutationDeclaration,
) -> @control.TaskContractRevision {
  {
    id: @control.RevisionId("revision-1"),
    goal_id: @control.GoalId("goal-1"),
    part_id: @control.PartId("part-1"),
    revision: 1,
    digest: assurance_digest_a,
    repair_conflict_id: None,
    instruction_artifact: {
      artifact_id: "instruction-1",
      digest: assurance_digest_a,
    },
    base_commit_oid: @control.GitOid("base-oid"),
    base_tree_oid: @control.GitOid("base-tree"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: declaration,
    verification_specs: [
      {
        id: @control.VerificationSpecId("moon-test"),
        version: 1,
        digest: assurance_digest_a,
        process_spec_digest: assurance_digest_b,
      },
    ],
    audit_policy_digest: assurance_digest_a,
    implementation_capability_profile_digest: assurance_digest_a,
    verification_capability_profile_digest: assurance_digest_a,
    audit_capability_profile_digest: assurance_digest_a,
  }
}

///|
fn assurance_take() -> @control.Take {
  {
    id: @control.TakeId("implementation-1"),
    goal_id: @control.GoalId("goal-1"),
    purpose: @control.TakePurpose::Implementation(
      @control.PartId("part-1"),
      @control.RevisionId("revision-1"),
    ),
    ordinal: 1,
    fencing_epoch: Some(@control.FencingEpoch(1L)),
    lifecycle: @control.TakeLifecycle::TakeRunning,
  }
}

///|
fn assurance_candidate(
  paths : Array[@control.RepoPath],
) -> @control.CandidateCommit {
  {
    id: @control.CandidateId("candidate-1"),
    goal_id: @control.GoalId("goal-1"),
    part_id: @control.PartId("part-1"),
    take_id: @control.TakeId("implementation-1"),
    base_commit_oid: @control.GitOid("base-oid"),
    commit_oid: @control.GitOid("candidate-oid"),
    tree_oid: @control.GitOid("candidate-tree"),
    canonical_change_digest: assurance_digest_b,
    changed_paths: paths,
  }
}

///|
test "RepoPath validation rejects aliases controls Git internals and non-NFC" {
  let valid = fn(_ : String) { true }
  for
    raw in [
      "", "/src/a.mbt", "src//a.mbt", "src/../a.mbt", "src/.git/config", "src\\a.mbt",
      "src/*.mbt",
    ] {
    assert_true(
      @control.validate_repo_path(@control.RepoPath(raw), valid) is Err(_),
    )
  }
  assert_true(
    @control.validate_repo_path(@control.RepoPath("src/a.mbt"), valid) is Ok(_),
  )
  assert_true(
    @control.validate_repo_path(@control.RepoPath("docs/café.md"), fn(_) {
      false
    })
    is Err(_),
  )
}

///|
test "mutation conflicts use path-component boundaries" {
  let src = @control.RepoPath("src")
  let src2 = @control.RepoPath("src2")
  let file = @control.RepoPath("src/a.mbt")
  assert_true(
    @control.mutation_declarations_conflict(
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::PathTree(src),
      ]),
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(file),
      ]),
    ),
  )
  assert_false(
    @control.mutation_declarations_conflict(
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::PathTree(src),
      ]),
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::PathTree(src2),
      ]),
    ),
  )
  assert_false(
    @control.mutation_declarations_conflict(
      @control.MutationDeclaration::CompleteMutationDeclaration([]),
      @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::RepositoryWide,
      ]),
    ),
  )
  assert_true(
    @control.mutation_declarations_conflict(
      @control.MutationDeclaration::MissingMutationDeclaration,
      @control.MutationDeclaration::CompleteMutationDeclaration([]),
    ),
  )
}

///|
test "candidate validation enforces immutable contract and declared diff" {
  let contract = assurance_contract(
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::PathTree(@control.RepoPath("src")),
    ]),
  )
  assert_true(
    @control.validate_task_contract_revision(contract, fn(_) { true }) is Ok(_),
  )
  let candidate = assurance_candidate([
    @control.RepoPath("src/a.mbt"),
    @control.RepoPath("moon.mod"),
  ])
  let evidence : @control.CandidatePathEvidence = {
    candidate_tree_paths: [
      @control.RepoPath("src/a.mbt"),
      @control.RepoPath("moon.mod"),
    ],
    symlink_prefix_paths: [],
    normalization_collision_paths: [],
  }
  match
    @control.validate_candidate_commit(
      contract,
      assurance_take(),
      candidate,
      evidence,
      fn(_) { true },
    ) {
    Err(@control.CandidateValidationFailure::CandidateOwnershipViolation(paths)) =>
      assert_eq(paths, [@control.RepoPath("moon.mod")])
    _ => fail("expected an exact ownership violation")
  }
  assert_true(
    @control.validate_candidate_commit(
      {
        ..contract,
        mutation_declaration: @control.MutationDeclaration::UnknownMutationDeclaration(
          @control.UnknownMutationReason::SemanticScopeUnknown,
        ),
      },
      assurance_take(),
      candidate,
      evidence,
      fn(_) { true },
    )
    is Ok(_),
  )
}

///|
test "task contract requires an immutable instruction artifact" {
  let contract = assurance_contract(
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
  assert_true(
    @control.validate_task_contract_revision(
      {
        ..contract,
        instruction_artifact: {
          ..contract.instruction_artifact,
          artifact_id: "",
        },
      },
      fn(_) { true },
    )
    is Err(_),
  )
  assert_true(
    @control.validate_task_contract_revision(
      {
        ..contract,
        instruction_artifact: {
          ..contract.instruction_artifact,
          digest: @control.Digest("not-a-digest"),
        },
      },
      fn(_) { true },
    )
    is Err(_),
  )
}

///|
test "candidate path evidence rejects symlink-prefix ambiguity" {
  let path = @control.RepoPath("src/generated/out.mbt")
  let contract = assurance_contract(
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::RepositoryWide,
    ]),
  )
  match
    @control.validate_candidate_commit(
      contract,
      assurance_take(),
      assurance_candidate([path]),
      {
        candidate_tree_paths: [path],
        symlink_prefix_paths: [path],
        normalization_collision_paths: [],
      },
      fn(_) { true },
    ) {
    Err(@control.CandidateValidationFailure::CandidateInvalidPath(actual)) =>
      assert_eq(actual, path)
    _ => fail("expected invalid candidate path")
  }
}

///|
test "unchanged symlinks do not invalidate an unrelated candidate" {
  let changed = @control.RepoPath("src/feature.mbt")
  let symlink = @control.RepoPath("README.md")
  let contract = assurance_contract(
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::ExactPath(changed),
    ]),
  )
  assert_true(
    @control.validate_candidate_commit(
      contract,
      assurance_take(),
      assurance_candidate([changed]),
      {
        candidate_tree_paths: [changed, symlink],
        symlink_prefix_paths: [symlink],
        normalization_collision_paths: [],
      },
      fn(_) { true },
    )
    is Ok(_),
  )
  let through_symlink = @control.RepoPath("vendor/current/file.mbt")
  match
    @control.validate_candidate_commit(
      {
        ..contract,
        mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
            @control.MutationClaim::RepositoryWide,
          ],
        ),
      },
      assurance_take(),
      assurance_candidate([through_symlink]),
      {
        candidate_tree_paths: [through_symlink],
        symlink_prefix_paths: [@control.RepoPath("vendor/current")],
        normalization_collision_paths: [],
      },
      fn(_) { true },
    ) {
    Err(@control.CandidateValidationFailure::CandidateInvalidPath(actual)) =>
      assert_eq(actual, through_symlink)
    _ => fail("expected a changed symlink descendant to be rejected")
  }
}

///|
pub(all) enum OwnershipConformanceKind {
  OwnershipNormalizationMatrix
  OwnershipConflictMatrix
  OwnershipUnderclaim
  OwnershipRenameDeleteGenerate
} derive(Debug, Eq, ToJson, FromJson)

///|
let ownership_digest_a : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let ownership_digest_b : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn ownership_contract(
  declaration : @control.MutationDeclaration,
) -> @control.TaskContractRevision {
  {
    id: @control.RevisionId("ownership-revision"),
    goal_id: @control.GoalId("ownership-goal"),
    part_id: @control.PartId("ownership-part"),
    revision: 1,
    digest: ownership_digest_a,
    repair_conflict_id: None,
    instruction_artifact: {
      artifact_id: "ownership-instruction",
      digest: ownership_digest_a,
    },
    base_commit_oid: @control.GitOid("ownership-base"),
    base_tree_oid: @control.GitOid("ownership-base-tree"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: declaration,
    verification_specs: [
      {
        id: @control.VerificationSpecId("ownership-verification"),
        version: 1,
        digest: ownership_digest_a,
        process_spec_digest: ownership_digest_b,
      },
    ],
    audit_policy_digest: ownership_digest_a,
    migration_contract_ref: None,
    implementation_capability_profile_digest: ownership_digest_a,
    verification_capability_profile_digest: ownership_digest_a,
    audit_capability_profile_digest: ownership_digest_a,
  }
}

///|
fn ownership_take() -> @control.Take {
  {
    id: @control.TakeId("ownership-take"),
    goal_id: @control.GoalId("ownership-goal"),
    purpose: @control.TakePurpose::Implementation(
      @control.PartId("ownership-part"),
      @control.RevisionId("ownership-revision"),
    ),
    ordinal: 1,
    fencing_epoch: Some(@control.FencingEpoch(1L)),
    lifecycle: @control.TakeLifecycle::TakeRunning,
  }
}

///|
fn ownership_candidate(
  changed_paths : Array[@control.RepoPath],
) -> @control.CandidateCommit {
  {
    id: @control.CandidateId("ownership-candidate"),
    goal_id: @control.GoalId("ownership-goal"),
    part_id: @control.PartId("ownership-part"),
    take_id: @control.TakeId("ownership-take"),
    base_commit_oid: @control.GitOid("ownership-base"),
    commit_oid: @control.GitOid("ownership-candidate-commit"),
    tree_oid: @control.GitOid("ownership-candidate-tree"),
    canonical_change_digest: ownership_digest_b,
    changed_paths,
  }
}

///|
fn ownership_path_evidence(
  paths : Array[@control.RepoPath],
) -> @control.CandidatePathEvidence {
  {
    candidate_tree_paths: paths,
    symlink_prefix_paths: [],
    normalization_collision_paths: [],
  }
}

///|
fn ownership_case_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("ownership conformance failed: " + detail)
}

///|
pub fn ownership_normalization_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("ownership.normalization"),
    run: fn(_) {
      let valid = [
        @control.RepoPath("src/a.mbt"),
        @control.RepoPath("docs/café.md"),
        @control.RepoPath("generated/output.lock"),
      ]
      let invalid = [
        @control.RepoPath(""),
        @control.RepoPath("/src/a.mbt"),
        @control.RepoPath("src//a.mbt"),
        @control.RepoPath("src/../a.mbt"),
        @control.RepoPath("src/.git/config"),
        @control.RepoPath("src\\a.mbt"),
        @control.RepoPath("src/*.mbt"),
      ]
      if valid.any(fn(path) {
          @control.validate_repo_path(path, fn(_) { true }) is Err(_)
        }) ||
        invalid.any(fn(path) {
          @control.validate_repo_path(path, fn(_) { true }) is Ok(_)
        }) ||
        @control.validate_repo_path(@control.RepoPath("docs/café.md"), fn(_) {
          false
        })
        is Ok(_) {
        return Err(ownership_case_error("path normalization matrix changed"))
      }
      Ok({
        evidence: [
          ObservedOwnershipCase(
            OwnershipNormalizationMatrix,
            valid.length() + invalid.length() + 1,
          ),
        ],
      })
    },
  }
}

///|
pub fn ownership_conflict_matrix_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("ownership.conflict_matrix"),
    run: fn(_) {
      let exact_a = @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(@control.RepoPath("src/a.mbt")),
      ])
      let exact_b = @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(@control.RepoPath("src/b.mbt")),
      ])
      let tree_src = @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::PathTree(@control.RepoPath("src")),
      ])
      let tree_src2 = @control.MutationDeclaration::CompleteMutationDeclaration([
          @control.MutationClaim::PathTree(@control.RepoPath("src2")),
        ],
      )
      let repository_wide = @control.MutationDeclaration::CompleteMutationDeclaration([
          @control.MutationClaim::RepositoryWide,
        ],
      )
      let empty = @control.MutationDeclaration::CompleteMutationDeclaration([])
      let rows = [
        (exact_a, exact_a, true),
        (exact_a, exact_b, false),
        (tree_src, exact_a, true),
        (tree_src, tree_src2, false),
        (repository_wide, exact_a, true),
        (repository_wide, empty, false),
        (@control.MutationDeclaration::MissingMutationDeclaration, empty, true),
        (
          @control.MutationDeclaration::UnknownMutationDeclaration(
            @control.UnknownMutationReason::SemanticScopeUnknown,
          ),
          exact_b,
          true,
        ),
      ]
      for row in rows {
        let (left, right, expected) = row
        if @control.mutation_declarations_conflict(left, right) != expected ||
          @control.mutation_declarations_conflict(right, left) != expected {
          return Err(ownership_case_error("mutation conflict matrix changed"))
        }
      }
      Ok({
        evidence: [
          ObservedOwnershipCase(OwnershipConflictMatrix, rows.length()),
        ],
      })
    },
  }
}

///|
pub fn ownership_underclaim_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("ownership.underclaim"),
    run: fn(_) {
      let covered = @control.RepoPath("src/a/file.mbt")
      let uncovered = @control.RepoPath("src/b/file.mbt")
      let paths = [covered, uncovered]
      let result = @control.validate_candidate_commit(
        ownership_contract(
          @control.MutationDeclaration::CompleteMutationDeclaration([
            @control.MutationClaim::PathTree(@control.RepoPath("src/a")),
          ]),
        ),
        ownership_take(),
        ownership_candidate(paths),
        ownership_path_evidence(paths),
        fn(_) { true },
      )
      if result !=
        Err(
          @control.CandidateValidationFailure::CandidateOwnershipViolation([
            uncovered,
          ]),
        ) {
        return Err(ownership_case_error("under-claim was not exact"))
      }
      Ok({ evidence: [ObservedOwnershipCase(OwnershipUnderclaim, 1)] })
    },
  }
}

///|
pub fn ownership_rename_delete_generate_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("ownership.rename_delete_generate"),
    run: fn(_) {
      let old_path = @control.RepoPath("src/old_name.mbt")
      let new_path = @control.RepoPath("src/new_name.mbt")
      let generated_path = @control.RepoPath("generated/schema.mbt")
      let lock_path = @control.RepoPath("moon.lock")
      let paths = [old_path, new_path, generated_path, lock_path]
      let result = @control.validate_candidate_commit(
        ownership_contract(
          @control.MutationDeclaration::CompleteMutationDeclaration([
            @control.MutationClaim::ExactPath(old_path),
            @control.MutationClaim::ExactPath(new_path),
            @control.MutationClaim::ExactPath(generated_path),
          ]),
        ),
        ownership_take(),
        ownership_candidate(paths),
        ownership_path_evidence(paths),
        fn(_) { true },
      )
      if result !=
        Err(
          @control.CandidateValidationFailure::CandidateOwnershipViolation([
            lock_path,
          ]),
        ) {
        return Err(
          ownership_case_error(
            "rename/delete/generated paths did not all require coverage",
          ),
        )
      }
      Ok({
        evidence: [
          ObservedOwnershipCase(OwnershipRenameDeleteGenerate, paths.length()),
        ],
      })
    },
  }
}

///|
fn fixture_kind() -> AuditContextKind {
  PartAuditContext(
    @control.GoalId("goal"),
    @control.PartId("part"),
    @control.CandidateId("candidate"),
    @control.TakeId("take"),
    @control.GitOid("b".repeat(40)),
    @control.RevisionId("revision"),
    @control.Digest("a".repeat(64)),
    @control.MutationDeclaration::CompleteMutationDeclaration([]),
  )
}

///|
test "canonical context sorts paths and stats stably" {
  let oid = @control.GitOid("b".repeat(40))
  let left = build_audit_context(
    fixture_kind(),
    oid,
    oid,
    [@control.RepoPath("z"), @control.RepoPath("a")],
    [
      {
        path: @control.RepoPath("a"),
        additions: AuditContextKnownLineCount(1L),
        deletions: AuditContextKnownLineCount(0L),
      },
      {
        path: @control.RepoPath("z"),
        additions: AuditContextUnknownLineCount,
        deletions: AuditContextUnknownLineCount,
      },
    ],
    @utf8.encode("diff"),
  ).unwrap()
  let right = build_audit_context(
    fixture_kind(),
    oid,
    oid,
    [@control.RepoPath("a"), @control.RepoPath("z")],
    left.context.file_stats,
    @utf8.encode("diff"),
  ).unwrap()
  assert_eq(left.reference.digest, right.reference.digest)
  assert_eq(left.context.changed_paths, [
    @control.RepoPath("a"),
    @control.RepoPath("z"),
  ])
}

///|
test "Goal context sorts Parts and mutation claims stably" {
  let oid = @control.GitOid("9".repeat(40))
  let digest = @control.Digest("8".repeat(64))
  let part_a : GoalAuditContextPart = {
    part_id: @control.PartId("a"),
    task_contract_revision_id: @control.RevisionId("revision-a"),
    task_contract_digest: digest,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::PathTree(@control.RepoPath("src/z")),
        @control.MutationClaim::ExactPath(@control.RepoPath("src/a.mbt")),
      ],
    ),
  }
  let part_a_shuffled = {
    ..part_a,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(@control.RepoPath("src/a.mbt")),
        @control.MutationClaim::PathTree(@control.RepoPath("src/z")),
      ],
    ),
  }
  let part_b : GoalAuditContextPart = {
    part_id: @control.PartId("b"),
    task_contract_revision_id: @control.RevisionId("revision-b"),
    task_contract_digest: digest,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::RepositoryWide,
      ],
    ),
  }
  let kind = fn(parts) {
    AuditContextKind::GoalAuditContext(
      @control.GoalId("goal"),
      @control.GoalBranchSealId("seal"),
      digest,
      oid,
      digest,
      parts,
    )
  }
  let left = build_audit_context(
    kind([part_b, part_a]),
    oid,
    oid,
    [],
    [],
    @utf8.encode(""),
  ).unwrap()
  let right = build_audit_context(
    kind([part_a_shuffled, part_b]),
    oid,
    oid,
    [],
    [],
    @utf8.encode(""),
  ).unwrap()
  assert_eq(left.reference.digest, right.reference.digest)
  match left.context.kind {
    AuditContextKind::GoalAuditContext(_, _, _, _, _, parts) =>
      assert_eq(parts.map(fn(part) { part.part_id }), [
        @control.PartId("a"),
        @control.PartId("b"),
      ])
    _ => fail("Goal context kind changed")
  }
}

///|
test "complete diff boundary is inclusive and over-limit omits every byte" {
  let oid = @control.GitOid("c".repeat(40))
  let exact = build_audit_context(
    fixture_kind(),
    oid,
    oid,
    [],
    [],
    Bytes::make(audit_context_byte_limit, 0x78),
  ).unwrap()
  assert_true(exact.context.unified_diff is CompleteUnifiedDiff(_))
  let over = build_audit_context(
    fixture_kind(),
    oid,
    oid,
    [],
    [],
    Bytes::make(audit_context_diff_sentinel_bytes, 0x78),
  ).unwrap()
  assert_eq(over.context.unified_diff, UnifiedDiffOmittedOverLimit)
  assert_true(over.content.length() < audit_context_byte_limit)
}

///|
test "malformed duplicate and mismatched stat inputs fail closed" {
  let oid = @control.GitOid("d".repeat(40))
  assert_true(
    build_audit_context(
      fixture_kind(),
      oid,
      oid,
      [@control.RepoPath("hostile\npath"), @control.RepoPath("hostile\npath")],
      [],
      @utf8.encode(""),
    )
    is Err(_),
  )
  assert_true(parse_numstat_record("999999999999999999999999\t0\tx") is Err(_))
  assert_eq(parse_numstat_record("-\t-\tbinary").unwrap(), {
    path: @control.RepoPath("binary"),
    additions: AuditContextUnknownLineCount,
    deletions: AuditContextUnknownLineCount,
  })
  assert_true(
    build_audit_context(
      fixture_kind(),
      @control.GitOid("not-an-oid"),
      oid,
      [],
      [],
      @utf8.encode(""),
    )
    is Err(_),
  )
  assert_true(
    build_audit_context(
      fixture_kind(),
      oid,
      oid,
      [@control.RepoPath("a")],
      [
        {
          path: @control.RepoPath("b"),
          additions: AuditContextKnownLineCount(1L),
          deletions: AuditContextKnownLineCount(2L),
        },
      ],
      @utf8.encode(""),
    )
    is Err(_),
  )
}

///|
test "empty diff and exact additions and deletions remain canonical" {
  let oid = @control.GitOid("7".repeat(40))
  let artifact = build_audit_context(
    fixture_kind(),
    oid,
    oid,
    [@control.RepoPath("src/a.mbt")],
    [
      {
        path: @control.RepoPath("src/a.mbt"),
        additions: AuditContextKnownLineCount(12L),
        deletions: AuditContextKnownLineCount(3L),
      },
    ],
    @utf8.encode(""),
  ).unwrap()
  assert_eq(
    artifact.context.file_stats[0].additions,
    AuditContextKnownLineCount(12L),
  )
  assert_eq(
    artifact.context.file_stats[0].deletions,
    AuditContextKnownLineCount(3L),
  )
  assert_eq(
    artifact.context.unified_diff,
    CompleteUnifiedDiff(@utf8.encode("")),
  )
}

///|
test "injected Git responses bind exact recorded paths" {
  let oid = @control.GitOid("e".repeat(40))
  let captured : AuditContextGitCapture = {
    changed_paths_z: @utf8.encode("b\u{0000}a\u{0000}"),
    numstat_z: @utf8.encode("-\t-\tb\u{0000}1\t2\ta\u{0000}"),
    unified_diff: @utf8.encode("patch"),
    unified_diff_exceeded_sentinel: false,
  }
  let artifact = build_audit_context_from_git_capture(
    fixture_kind(),
    oid,
    oid,
    [@control.RepoPath("a"), @control.RepoPath("b")],
    captured,
  ).unwrap()
  assert_eq(artifact.context.changed_paths, [
    @control.RepoPath("a"),
    @control.RepoPath("b"),
  ])
  assert_true(
    build_audit_context_from_git_capture(
      fixture_kind(),
      oid,
      oid,
      [@control.RepoPath("a")],
      captured,
    )
    is Err(_),
  )
}

///|
test "metadata over limit fails closed without reflecting a hostile path" {
  let oid = @control.GitOid("f".repeat(40))
  let hostile = "secret-marker-" + "x".repeat(audit_context_byte_limit)
  match
    build_audit_context(
      fixture_kind(),
      oid,
      oid,
      [@control.RepoPath(hostile)],
      [
        {
          path: @control.RepoPath(hostile),
          additions: AuditContextKnownLineCount(0L),
          deletions: AuditContextKnownLineCount(0L),
        },
      ],
      @utf8.encode(""),
    ) {
    Err(error) => {
      assert_true(error.message().contains("audit context is invalid"))
      assert_false(error.message().contains("secret-marker"))
    }
    Ok(_) => fail("oversized metadata was accepted")
  }
}

///|
test "canonical metadata accepts its exact ceiling and rejects one byte more" {
  let oid = @control.GitOid("6".repeat(40))
  let mut padding = 0
  let mut low = 1
  let mut high = audit_context_byte_limit
  let mut exact : CanonicalAuditContextArtifact? = None
  for attempt = 0; attempt < 32; attempt = attempt + 1 {
    let candidate_padding = low + (high - low) / 2
    let mutation = @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::ExactPath(
        @control.RepoPath("x".repeat(candidate_padding)),
      ),
    ])
    let candidate = build_audit_context(
      PartAuditContext(
        @control.GoalId("goal"),
        @control.PartId("part"),
        @control.CandidateId("candidate"),
        @control.TakeId("take"),
        oid,
        @control.RevisionId("revision"),
        @control.Digest("5".repeat(64)),
        mutation,
      ),
      oid,
      oid,
      [],
      [],
      @utf8.encode(""),
    )
    match candidate {
      Ok(value) => {
        if value.content.length() == audit_context_byte_limit {
          padding = candidate_padding
          exact = Some(value)
          break
        }
        low = candidate_padding + 1
      }
      Err(_) => high = candidate_padding - 1
    }
  }
  let accepted = match exact {
    Some(value) => value
    None => fail("could not construct exact metadata ceiling")
  }
  assert_eq(accepted.content.length(), audit_context_byte_limit)
  let oversized_mutation = @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::ExactPath(
        @control.RepoPath("x".repeat(padding + 1)),
      ),
    ],
  )
  assert_true(
    build_audit_context(
      PartAuditContext(
        @control.GoalId("goal"),
        @control.PartId("part"),
        @control.CandidateId("candidate"),
        @control.TakeId("take"),
        oid,
        @control.RevisionId("revision"),
        @control.Digest("5".repeat(64)),
        oversized_mutation,
      ),
      oid,
      oid,
      [],
      [],
      @utf8.encode(""),
    )
    is Err(_),
  )
}

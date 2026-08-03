///|
fn direct_take_command(
  scopes? : Array[@control.MutationClaim] = [
    @control.MutationClaim::PathTree(@control.RepoPath("src")),
  ],
) -> @command.DirectTakeCommand {
  {
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    instruction: "repair the parser",
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration(
      scopes,
    ),
    verification_arguments: ["test", "--target", "native"],
    verification_timeout_ms: 120000L,
    apply: false,
  }
}

///|
fn direct_take_candidate(
  changed? : Array[@control.RepoPath] = [@control.RepoPath("src/parser.mbt")],
  symlinks? : Array[@control.RepoPath] = [],
) -> @workflow.DirectTakeCandidate {
  let tree_paths = [
    @control.RepoPath("README.md"),
    @control.RepoPath("src/parser.mbt"),
    ..symlinks,
  ]
  tree_paths.sort()
  {
    base_commit_oid: @control.GitOid("base"),
    base_tree_oid: @control.GitOid("base-tree"),
    candidate_tree_oid: @control.GitOid("candidate-tree"),
    changed_paths: changed,
    candidate_tree_paths: tree_paths,
    symlink_prefix_paths: symlinks,
  }
}

///|
test "direct Take candidate admission enforces scope and path evidence" {
  assert_true(
    @workflow.validate_direct_take_candidate(
      direct_take_command(),
      direct_take_candidate(),
      fn(_) { true },
    )
    is Ok(_),
  )
  assert_true(
    @workflow.validate_direct_take_candidate(
      direct_take_command(),
      direct_take_candidate(changed=[@control.RepoPath("README.md")]),
      fn(_) { true },
    )
    is Err(_),
  )
  let base_symlink_candidate = {
    ..direct_take_candidate(changed=[
      @control.RepoPath("src/removed-link/child.mbt"),
    ]),
    symlink_prefix_paths: [@control.RepoPath("src/removed-link")],
  }
  assert_false(
    base_symlink_candidate.candidate_tree_paths.contains(
      @control.RepoPath("src/removed-link"),
    ),
  )
  assert_true(
    @workflow.validate_direct_take_candidate(
      direct_take_command(),
      base_symlink_candidate,
      fn(_) { true },
    )
    is Err(_),
  )
  assert_true(
    @workflow.validate_direct_take_candidate(
      direct_take_command(),
      direct_take_candidate(changed=[@control.RepoPath("src/link/child.mbt")], symlinks=[
        @control.RepoPath("src/link"),
      ]),
      fn(_) { true },
    )
    is Err(_),
  )
  assert_true(
    @workflow.validate_direct_take_candidate(
      direct_take_command(),
      direct_take_candidate(changed=[
        @control.RepoPath("src/z.mbt"),
        @control.RepoPath("src/a.mbt"),
      ]),
      fn(_) { true },
    )
    is Err(_),
  )
}

///|
test "direct Take repository-wide scope remains bounded by canonical paths" {
  let repository_wide = direct_take_command(scopes=[
    @control.MutationClaim::RepositoryWide,
  ])
  assert_true(
    @workflow.validate_direct_take_candidate(
      repository_wide,
      direct_take_candidate(changed=[@control.RepoPath("README.md")]),
      fn(_) { true },
    )
    is Ok(_),
  )
  assert_true(
    @workflow.validate_direct_take_candidate(
      repository_wide,
      direct_take_candidate(changed=[@control.RepoPath("bad/../path")]),
      fn(_) { true },
    )
    is Err(_),
  )
}

///|
test "direct Take renders a bounded provider instruction without host authority" {
  let instruction = @workflow.render_direct_take_instruction(
    direct_take_command(),
  ).unwrap()
  assert_true(instruction.contains("src and its descendants"))
  assert_true(instruction.contains("moon test --target native"))
  assert_true(instruction.contains("repair the parser"))
  assert_true(instruction.contains("Do not invoke Beads"))
}

///|
test "direct Take verification is one registered network-disabled Moon process" {
  let plan = @workflow.plan_direct_take_verification(
    direct_take_command(),
    "abcdef0123456789",
  ).unwrap()
  assert_eq(plan.capability.fencing_epoch, @control.FencingEpoch(1L))
  assert_eq(
    plan.capability.take_id,
    @control.TakeId("direct-take-abcdef0123456789-verification"),
  )
  assert_eq(plan.process.arguments, [
    "test", "--target", "native", "--target-dir", "/scratch/verification-abcdef0123456789",
  ])
  assert_eq(
    plan.process.executable,
    @sandbox.SandboxExecutable::SandboxRegisteredTool(
      @sandbox.SandboxRegisteredToolId("moon"),
      @sandbox.boxlite_take_tool_manifest_digest(),
    ),
  )
  assert_eq(
    plan.process.network.profile,
    @sandbox.SandboxNetworkProfile::NetworkDisabled,
  )
  assert_true(@control.Digest::is_valid(plan.process_spec_digest))
}

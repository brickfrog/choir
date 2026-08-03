///|
test "direct Take requires an explicit paid surface and bounded instruction" {
  assert_true(@command.parse_direct_take_command(["fix", "it"]) is Err(_))
  assert_true(
    @command.parse_direct_take_command(["--provider", "other", "fix"]) is Err(_),
  )
  assert_true(
    @command.parse_direct_take_command(["--provider", "codex"]) is Err(_),
  )
  assert_true(
    @command.parse_direct_take_command(["--provider", "codex", "x".repeat(8193)])
    is Err(_),
  )
}

///|
test "direct Take defaults to repository-wide native Moon tests" {
  let command = @command.parse_direct_take_command([
    "--provider", "codex", "repair", "the", "parser",
  ]).unwrap()
  assert_eq(command.surface, @control.ProviderSurfaceId::CodexSubscriptionCli)
  assert_eq(command.instruction, "repair the parser")
  assert_eq(command.verification_arguments, ["test", "--target", "native"])
  assert_eq(command.verification_timeout_ms, 120000L)
  assert_false(command.apply)
  assert_eq(
    command.mutation_declaration,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::RepositoryWide,
    ]),
  )
}

///|
test "direct Take retains explicit scope verification and apply authority" {
  let command = @command.parse_direct_take_command([
    "--provider", "claude", "--scope", "src/config", "--scope", "README.md", "--verify",
    "check --target native", "--verify-timeout-ms", "600000", "--apply", "--", "--repair",
    "config",
  ]).unwrap()
  assert_eq(command.surface, @control.ProviderSurfaceId::ClaudeSubscriptionCli)
  assert_eq(command.instruction, "--repair config")
  assert_eq(command.verification_arguments, ["check", "--target", "native"])
  assert_eq(command.verification_timeout_ms, 600000L)
  assert_true(command.apply)
  assert_eq(
    command.mutation_declaration,
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::PathTree(@control.RepoPath("src/config")),
      @control.MutationClaim::PathTree(@control.RepoPath("README.md")),
    ]),
  )
}

///|
test "direct Take rejects authority-expanding or ambiguous options" {
  let invalid = [
    ["--provider", "codex", "--scope", "../src", "fix"],
    ["--provider", "codex", "--scope", ".git/config", "fix"],
    ["--provider", "codex", "--scope", "src", "--scope", "src", "fix"],
    ["--provider", "codex", "--verify", "moon test", "fix"],
    ["--provider", "codex", "--verify", "test --target-dir out", "fix"],
    ["--provider", "codex", "--verify-timeout-ms", "600001", "fix"],
    ["--provider", "codex", "--apply", "--apply", "fix"],
    ["--provider", "codex", "--unknown", "fix"],
  ]
  for arguments in invalid {
    assert_true(@command.parse_direct_take_command(arguments) is Err(_))
  }
}

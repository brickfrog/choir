///|
fn take_usage() -> String {
  (
    #|Usage: choir take --provider <claude|codex> [options] <instruction>
    #|
    #|Run exactly one paid-subscription provider in a network-disabled BoxLite
    #|guest, then independently verify its result with Moon. The host worktree
    #|is unchanged unless --apply is present and every identity recheck passes.
    #|
    #|Options:
    #|  --provider <claude|codex>  required paid surface
    #|  --scope <path>             admitted path tree; repeat up to 64 times
    #|                             (omission admits the repository)
    #|  --verify "<moon args>"     default: test --target native
    #|  --verify-timeout-ms <ms>   1..600000; default: 120000
    #|  --apply                     apply the verified patch after rechecking HEAD
    #|  -h, --help                 show this help
    #|
    #|This command creates no Bead, Goal, branch, commit, PR, Part workflow,
    #|WorkOrder, or Goal-execution record.
  ) +
  "\n"
}

///|
fn direct_take_surface_text(surface : @control.ProviderSurfaceId) -> String {
  match surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli => "claude"
    @control.ProviderSurfaceId::CodexSubscriptionCli => "codex"
  }
}

///|
fn render_direct_take_verification(
  outcome : @direct_take_host.NativeDirectTakeVerificationOutcome,
) -> String {
  match outcome {
    @direct_take_host.NativeDirectTakeVerificationPassed(result) =>
      "passed (exit 0, output " + result.output_digest.0 + ")\n" + result.output
    @direct_take_host.NativeDirectTakeVerificationFailed(result) =>
      "failed (exit " +
      result.exit_code.to_string() +
      ", output " +
      result.output_digest.0 +
      ")\n" +
      result.output
    @direct_take_host.NativeDirectTakeVerificationInterrupted => "interrupted\n"
    @direct_take_host.NativeDirectTakeVerificationTimedOut => "timed out\n"
    @direct_take_host.NativeDirectTakeVerificationOutputExceeded =>
      "output limit exceeded\n"
  }
}

///|
fn render_direct_take_report(
  report : @direct_take_host.NativeDirectTakeReport,
) -> String {
  let isolated = report.isolated
  let usage = isolated.provider.usage
  let changed = if isolated.patch.candidate.changed_paths.length() == 0 {
    "  (none)\n"
  } else {
    isolated.patch.candidate.changed_paths
    .map(fn(path) { "  " + @control.repo_path_text(path) })
    .join("\n") +
    "\n"
  }
  let application = if report.applied {
    "applied"
  } else if isolated.patch.patch == "" {
    "no changes"
  } else if report.apply_requested {
    "not applied because verification did not pass"
  } else {
    "dry run; pass --apply to apply after fresh identity checks"
  }
  let patch_text = if isolated.patch.patch == "" {
    "(empty)\n"
  } else {
    isolated.patch.patch
  }
  "Direct Take evidence\n" +
  "  provider: " +
  direct_take_surface_text(isolated.provider.surface) +
  "\n  base commit: " +
  report.snapshot.commit_oid.0 +
  "\n  base tree: " +
  report.snapshot.tree_oid.0 +
  "\n  source digest: " +
  report.snapshot.source_digest.0 +
  "\n  candidate tree: " +
  isolated.patch.candidate.candidate_tree_oid.0 +
  "\n  patch digest: " +
  isolated.patch.patch_digest.0 +
  "\n  surface digest: " +
  isolated.provider.surface_manifest_digest.0 +
  "\n  provider response digest: " +
  isolated.provider.response_digest.0 +
  "\n  image digest: " +
  isolated.image_digest.0 +
  "\n  tool manifest digest: " +
  isolated.tool_manifest_digest.0 +
  "\n  runtime policy digest: " +
  isolated.runtime_policy_digest.0 +
  "\n  verification spec digest: " +
  isolated.verification_process_spec_digest.0 +
  "\n  usage: input=" +
  usage.input_tokens.to_string() +
  " output=" +
  usage.output_tokens.to_string() +
  " cache-read=" +
  usage.cache_read_tokens.to_string() +
  " cache-create=" +
  usage.cache_creation_tokens.to_string() +
  " wall-ms=" +
  usage.wall_time_ms.to_string() +
  "\n  application: " +
  application +
  "\nChanged paths:\n" +
  changed +
  "Verification: " +
  render_direct_take_verification(isolated.verification) +
  "\nPatch (bounded to 1048576 bytes):\n" +
  patch_text
}

///|
fn take_run() -> Unit {
  let arguments = @env.args()[2:].to_owned()
  if arguments.length() == 1 &&
    (arguments[0] == "-h" || arguments[0] == "--help") {
    @sys.write_stdout(take_usage())
    return
  }
  let command = match @command.parse_direct_take_command(arguments) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr(error.message() + "\n\n")
      @sys.write_stderr(take_usage())
      @sys.exit(1)
      return
    }
  }
  let project_dir = match @sys.realpath_native(".") {
    Some(value) => value
    None => {
      @sys.write_stderr("choir take: project directory is unavailable\n")
      @sys.exit(1)
      return
    }
  }
  @async.run_async_main(async fn() {
    match @direct_take_host.run_native_direct_take(project_dir, command) {
      Ok(report) => {
        @sys.write_stdout(render_direct_take_report(report))
        if !@direct_take_host.native_direct_take_report_succeeded(report) {
          @sys.exit(1)
        }
      }
      Err(error) => {
        @sys.write_stderr("choir take: " + error.message() + "\n")
        @sys.exit(1)
      }
    }
  })
}

///|
test "direct Take help states dry-run, isolation, and no durable workflow" {
  let usage = take_usage()
  assert_true(usage.contains("network-disabled BoxLite"))
  assert_true(usage.contains("unchanged unless --apply"))
  assert_true(usage.contains("creates no Bead, Goal"))
  assert_true(usage.contains("--provider <claude|codex>"))
}

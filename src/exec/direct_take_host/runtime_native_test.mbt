///|
fn direct_take_runtime_command(apply : Bool) -> @command.DirectTakeCommand {
  {
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    instruction: "change src/a.mbt",
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::PathTree(@control.RepoPath("src")),
      ],
    ),
    verification_arguments: ["test", "--target", "native"],
    verification_timeout_ms: 120000L,
    apply,
  }
}

///|
fn direct_take_runtime_snapshot() -> @direct_take_host.NativeDirectTakeSnapshot {
  {
    repository_root: "/repo",
    git_directory: "/repo/.git",
    object_directory: "/repo/.git/objects",
    commit_oid: @control.GitOid("a".repeat(40)),
    tree_oid: @control.GitOid("b".repeat(40)),
    source_digest: @storage.artifact_digest(@utf8.encode("source")),
  }
}

///|
fn direct_take_runtime_result(
  snapshot : @direct_take_host.NativeDirectTakeSnapshot,
  process_digest : @control.Digest,
  passed : Bool,
) -> @direct_take_host.NativeDirectTakeIsolatedResult {
  let patch = "diff --git a/src/a.mbt b/src/a.mbt\n"
  let process : @take_host.NativeSandboxProcessResult = {
    exit_code: if passed {
      0
    } else {
      1
    },
    output: if passed {
      "ok"
    } else {
      "failed"
    },
    output_digest: @storage.artifact_digest(
      @utf8.encode(if passed { "ok" } else { "failed" }),
    ),
    started_at: None,
    finished_at: None,
  }
  {
    patch: {
      candidate: {
        base_commit_oid: snapshot.commit_oid,
        base_tree_oid: snapshot.tree_oid,
        candidate_tree_oid: @control.GitOid("c".repeat(40)),
        changed_paths: [@control.RepoPath("src/a.mbt")],
        candidate_tree_paths: [@control.RepoPath("src/a.mbt")],
        symlink_prefix_paths: [],
      },
      patch,
      patch_digest: @storage.artifact_digest(@utf8.encode(patch)),
    },
    verification: if passed {
      @direct_take_host.NativeDirectTakeVerificationPassed(process)
    } else {
      @direct_take_host.NativeDirectTakeVerificationFailed(process)
    },
    provider: {
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
      surface_manifest_digest: @storage.artifact_digest(@utf8.encode("surface")),
      response_digest: @storage.artifact_digest(@utf8.encode("response")),
      usage: @control.empty_take_usage(),
      started_at: 1L,
      finished_at: 2L,
    },
    image_digest: @storage.artifact_digest(@utf8.encode("image")),
    tool_manifest_digest: @storage.artifact_digest(@utf8.encode("tool")),
    runtime_policy_digest: @storage.artifact_digest(@utf8.encode("runtime")),
    verification_process_spec_digest: process_digest,
  }
}

///|
async test "direct Take dispatches one isolated provider run and dry-runs by default" {
  let snapshot = direct_take_runtime_snapshot()
  let isolated_calls = @ref.new(0)
  let apply_calls = @ref.new(0)
  let report = @direct_take_host.run_native_direct_take_with(
    direct_take_runtime_command(false),
    {
      capture_snapshot: fn() { Ok(snapshot) },
      execute_isolated: (observed, instruction, plan) => {
        isolated_calls.val = isolated_calls.val + 1
        assert_eq(observed, snapshot)
        assert_true(instruction.contains("User instruction"))
        Ok(direct_take_runtime_result(snapshot, plan.process_spec_digest, true))
      },
      apply_patch: fn(_, _) {
        apply_calls.val = apply_calls.val + 1
        Ok(())
      },
      is_nfc: fn(_) { true },
    },
  ).unwrap()
  assert_eq(isolated_calls.val, 1)
  assert_eq(apply_calls.val, 0)
  assert_false(report.applied)
  assert_true(@direct_take_host.native_direct_take_report_succeeded(report))
}

///|
async test "direct Take applies only a verified exact candidate when requested" {
  let snapshot = direct_take_runtime_snapshot()
  let apply_calls = @ref.new(0)
  let report = @direct_take_host.run_native_direct_take_with(
    direct_take_runtime_command(true),
    {
      capture_snapshot: fn() { Ok(snapshot) },
      execute_isolated: fn(_, _, plan) {
        Ok(direct_take_runtime_result(snapshot, plan.process_spec_digest, true))
      },
      apply_patch: (observed, patch) => {
        assert_eq(observed, snapshot)
        assert_eq(patch.candidate.base_tree_oid, snapshot.tree_oid)
        apply_calls.val = apply_calls.val + 1
        Ok(())
      },
      is_nfc: fn(_) { true },
    },
  ).unwrap()
  assert_eq(apply_calls.val, 1)
  assert_true(report.applied)
  assert_true(@direct_take_host.native_direct_take_report_succeeded(report))
}

///|
async test "direct Take returns failed verification evidence without applying" {
  let snapshot = direct_take_runtime_snapshot()
  let apply_calls = @ref.new(0)
  let report = @direct_take_host.run_native_direct_take_with(
    direct_take_runtime_command(true),
    {
      capture_snapshot: fn() { Ok(snapshot) },
      execute_isolated: fn(_, _, plan) {
        Ok(
          direct_take_runtime_result(snapshot, plan.process_spec_digest, false),
        )
      },
      apply_patch: fn(_, _) {
        apply_calls.val = apply_calls.val + 1
        Ok(())
      },
      is_nfc: fn(_) { true },
    },
  ).unwrap()
  assert_eq(apply_calls.val, 0)
  assert_false(report.applied)
  assert_false(@direct_take_host.native_direct_take_report_succeeded(report))
}

///|
async test "direct Take rejects malformed evidence before apply" {
  let snapshot = direct_take_runtime_snapshot()
  let apply_calls = @ref.new(0)
  let result = @direct_take_host.run_native_direct_take_with(
    direct_take_runtime_command(true),
    {
      capture_snapshot: fn() { Ok(snapshot) },
      execute_isolated: fn(_, _, plan) {
        let isolated = direct_take_runtime_result(
          snapshot,
          plan.process_spec_digest,
          true,
        )
        Ok({
          ..isolated,
          provider: {
            ..isolated.provider,
            response_digest: @control.Digest("invalid"),
          },
        })
      },
      apply_patch: fn(_, _) {
        apply_calls.val = apply_calls.val + 1
        Ok(())
      },
      is_nfc: fn(_) { true },
    },
  )
  assert_true(result is Err(_))
  assert_eq(apply_calls.val, 0)
}

///|
async test "audit context Git capture injects exact deterministic bounded requests" {
  let config : NativeGitWorkspaceConfig = {
    repository_root: "/repo",
    object_directory: "/repo/.git/objects",
    staging_root: "/tmp/choir-take-audit/staging",
  }
  let base = @control.GitOid("a".repeat(40))
  let subject = @control.GitOid("b".repeat(40))
  let requests : Array[NativeGitStagingProcessRequest] = []
  let captured = capture_native_audit_context_with(config, base, subject, async fn(
    request,
  ) {
    @async.sleep(0)
    requests.push(request)
    Ok(
      @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
        0,
        match requests.length() {
          1 => @utf8.encode("src/a.mbt\u{0000}")
          2 => @utf8.encode("1\t2\tsrc/a.mbt\u{0000}")
          _ => @utf8.encode("diff --git a/src/a.mbt b/src/a.mbt\n")
        },
      ),
    )
  }).unwrap()
  assert_eq(requests.length(), 3)
  for request in requests {
    assert_eq(request.program, "/usr/bin/git")
    assert_eq(request.environment["LC_ALL"], "C")
    assert_eq(request.environment["GIT_EXTERNAL_DIFF"], "")
    assert_true(request.arguments.contains("--no-ext-diff"))
    assert_true(request.arguments.contains("--no-textconv"))
    assert_true(request.arguments.contains("--no-renames"))
    assert_true(request.arguments.contains("--src-prefix=a/"))
    assert_true(request.arguments.contains("--dst-prefix=b/"))
    assert_eq(request.arguments[request.arguments.length() - 3], base.0)
    assert_eq(request.arguments[request.arguments.length() - 2], subject.0)
    assert_eq(request.arguments[request.arguments.length() - 1], "--")
  }
  assert_eq(
    requests[2].output_limit_bytes,
    @audit.audit_context_diff_sentinel_bytes,
  )
  assert_eq(captured.changed_paths_z, @utf8.encode("src/a.mbt\u{0000}"))
}

///|
async test "audit context Git capture omits an over-limit diff without retaining a prefix" {
  let config : NativeGitWorkspaceConfig = {
    repository_root: "/repo",
    object_directory: "/repo/.git/objects",
    staging_root: "/tmp/choir-take-audit/staging",
  }
  let calls = @ref.new(0)
  let captured = capture_native_audit_context_with(
    config,
    @control.GitOid("c".repeat(40)),
    @control.GitOid("d".repeat(40)),
    fn(_) {
      calls.val = calls.val + 1
      if calls.val < 3 {
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0, b"",
          ),
        )
      } else {
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessOutputExceeded(
            "discarded-prefix",
          ),
        )
      }
    },
  ).unwrap()
  assert_eq(calls.val, 3)
  assert_true(captured.unified_diff_exceeded_sentinel)
  assert_eq(captured.unified_diff, b"")
}

///|
async test "malformed audit context OIDs are rejected before process capture" {
  let config : NativeGitWorkspaceConfig = {
    repository_root: "/repo",
    object_directory: "/repo/.git/objects",
    staging_root: "/tmp/choir-take-audit/staging",
  }
  let calls = @ref.new(0)
  let result = capture_native_audit_context_with(
    config,
    @control.GitOid("not-an-oid"),
    @control.GitOid("d".repeat(40)),
    fn(_) {
      calls.val = calls.val + 1
      Ok(
        @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
          0, b"",
        ),
      )
    },
  )
  assert_true(result is Err(_))
  assert_eq(calls.val, 0)
}

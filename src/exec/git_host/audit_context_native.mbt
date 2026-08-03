///|
fn native_audit_git_environment(
  config : NativeGitWorkspaceConfig,
) -> Map[String, String] {
  {
    "GIT_DIR": config.staging_root + "/git-control",
    "GIT_OBJECT_DIRECTORY": config.object_directory,
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_ATTR_NOSYSTEM": "1",
    "GIT_EXTERNAL_DIFF": "",
    "XDG_CONFIG_HOME": "/nonexistent",
    "LC_ALL": "C",
    "LANG": "C",
  }
}

///|
fn native_audit_diff_arguments(
  base_tree_oid : @control.GitOid,
  subject_tree_oid : @control.GitOid,
  mode : String,
) -> Array[String] {
  let arguments = [
    "-c", "core.quotePath=false", "-c", "diff.external=", "diff", "--no-ext-diff",
    "--no-textconv", "--no-renames", "--no-color", "--src-prefix=a/", "--dst-prefix=b/",
  ]
  match mode {
    "paths" => {
      arguments.push("--name-only")
      arguments.push("-z")
    }
    "stat" => {
      arguments.push("--numstat")
      arguments.push("-z")
    }
    "diff" => arguments.push("--binary")
    _ => ()
  }
  arguments.push(base_tree_oid.0)
  arguments.push(subject_tree_oid.0)
  arguments.push("--")
  arguments
}

///|
/// Capture exact deterministic Git outputs through an injected bounded process
/// adapter. This boundary performs no policy or audit work.
pub async fn capture_native_audit_context_with(
  config : NativeGitWorkspaceConfig,
  base_tree_oid : @control.GitOid,
  subject_tree_oid : @control.GitOid,
  capture : async (NativeGitStagingProcessRequest) -> Result[
    @process_host.NativeBoundedBytesProcessOutcome,
    @types.ChoirError,
  ],
) -> Result[@audit.AuditContextGitCapture, @types.ChoirError] {
  if !@git_integration.valid_hex_oid_text(base_tree_oid.0) ||
    !@git_integration.valid_hex_oid_text(subject_tree_oid.0) {
    return Err(
      @types.ChoirError::validation_error(
        "audit context Git request is invalid",
      ),
    )
  }
  let environment = native_audit_git_environment(config)
  async fn run(
    mode : String,
    limit : Int,
  ) -> Result[@process_host.NativeBoundedBytesProcessOutcome, @types.ChoirError] {
    capture({
      program: "/usr/bin/git",
      arguments: native_audit_diff_arguments(
        base_tree_oid, subject_tree_oid, mode,
      ),
      environment,
      cwd: config.staging_root,
      stdin: b"",
      timeout_ms: 120000,
      output_limit_bytes: limit,
    })
  }
  let paths = match run("paths", @audit.audit_context_byte_limit) {
    Ok(@process_host.NativeBytesProcessCompleted(0, value)) => value
    _ =>
      return Err(
        @types.ChoirError::validation_error("audit context Git capture failed"),
      )
  }
  let stats = match run("stat", @audit.audit_context_byte_limit) {
    Ok(@process_host.NativeBytesProcessCompleted(0, value)) => value
    _ =>
      return Err(
        @types.ChoirError::validation_error("audit context Git capture failed"),
      )
  }
  let (diff, exceeded) = match
    run("diff", @audit.audit_context_diff_sentinel_bytes) {
    Ok(@process_host.NativeBytesProcessCompleted(0, value)) => (value, false)
    Ok(@process_host.NativeBytesProcessOutputExceeded(_)) => (b"", true)
    _ =>
      return Err(
        @types.ChoirError::validation_error("audit context Git capture failed"),
      )
  }
  Ok({
    changed_paths_z: paths,
    numstat_z: stats,
    unified_diff: diff,
    unified_diff_exceeded_sentinel: exceeded,
  })
}

///|
pub async fn capture_native_audit_context(
  config : NativeGitWorkspaceConfig,
  base_tree_oid : @control.GitOid,
  subject_tree_oid : @control.GitOid,
) -> Result[@audit.AuditContextGitCapture, @types.ChoirError] {
  capture_native_audit_context_with(config, base_tree_oid, subject_tree_oid, async fn(
    request,
  ) {
    @process_host.capture_bounded_process_bytes(
      request.program,
      request.arguments,
      request.environment,
      request.stdin,
      request.cwd,
      request.timeout_ms,
      request.output_limit_bytes,
      fn() { false },
    )
  })
}

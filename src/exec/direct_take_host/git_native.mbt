///|
let native_direct_take_patch_limit_bytes : Int = 1048576

///|
pub(all) struct NativeDirectTakeGitCaptureRequest {
  program : String
  arguments : Array[String]
  environment : Map[String, String]
  cwd : String
  stdin : Bytes
  timeout_ms : Int
  output_limit_bytes : Int
} derive(Debug, Eq)

///|
pub(all) struct NativeDirectTakeSnapshot {
  repository_root : String
  git_directory : String
  object_directory : String
  commit_oid : @control.GitOid
  tree_oid : @control.GitOid
  source_digest : @control.Digest
} derive(Debug, Eq)

///|
pub(all) struct NativeDirectTakePatch {
  candidate : @workflow.DirectTakeCandidate
  patch : String
  patch_digest : @control.Digest
} derive(Debug, Eq)

///|
fn native_direct_take_git_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::git_error("direct Take: " + detail)
}

///|
fn native_direct_take_host_git_environment() -> Map[String, String] {
  {
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_ATTR_NOSYSTEM": "1",
    "HOME": "/nonexistent",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin",
    "XDG_CONFIG_HOME": "/nonexistent",
  }
}

///|
fn native_direct_take_control_git_environment(
  config : @git_host.NativeGitWorkspaceConfig,
) -> Map[String, String] {
  let environment = native_direct_take_host_git_environment()
  environment["GIT_DIR"] = config.staging_root + "/git-control"
  environment["GIT_OBJECT_DIRECTORY"] = config.object_directory
  environment
}

///|
async fn capture_native_direct_take_git(
  request : NativeDirectTakeGitCaptureRequest,
) -> Result[@process_host.NativeBoundedBytesProcessOutcome, @types.ChoirError] {
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
}

///|
fn native_direct_take_capture_text(
  outcome : @process_host.NativeBoundedBytesProcessOutcome,
  label : String,
) -> Result[String, @types.ChoirError] {
  match outcome {
    @process_host.NativeBytesProcessCompleted(0, bytes) => {
      let decoded = @utf8.decode(bytes) catch {
        _ => return Err(native_direct_take_git_error(label + " is not UTF-8"))
      }
      Ok(decoded)
    }
    @process_host.NativeBytesProcessOutputExceeded(_) =>
      Err(native_direct_take_git_error(label + " exceeds its byte limit"))
    _ => Err(native_direct_take_git_error(label + " failed"))
  }
}

///|
async fn native_direct_take_git_text(
  project_dir : String,
  arguments : Array[String],
  output_limit_bytes : Int,
  capture : async (NativeDirectTakeGitCaptureRequest) -> Result[
    @process_host.NativeBoundedBytesProcessOutcome,
    @types.ChoirError,
  ],
  environment? : Map[String, String] = native_direct_take_host_git_environment(),
  stdin? : Bytes = b"",
  label? : String = "Git observation",
) -> Result[String, @types.ChoirError] {
  let outcome = match
    capture({
      program: "/usr/bin/git",
      arguments,
      environment,
      cwd: project_dir,
      stdin,
      timeout_ms: 120000,
      output_limit_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  native_direct_take_capture_text(outcome, label)
}

///|
pub async fn capture_native_direct_take_snapshot_with(
  project_dir : String,
  capture : async (NativeDirectTakeGitCaptureRequest) -> Result[
    @process_host.NativeBoundedBytesProcessOutcome,
    @types.ChoirError,
  ],
  canonicalize : (String) -> String?,
) -> Result[NativeDirectTakeSnapshot, @types.ChoirError] {
  let root = match
    native_direct_take_git_text(
      project_dir,
      ["rev-parse", "--show-toplevel"],
      4096,
      capture,
      label="repository root",
    ) {
    Ok(value) => value.trim().to_owned()
    Err(error) => return Err(error)
  }
  let commit = match
    native_direct_take_git_text(
      root,
      ["rev-parse", "--verify", "HEAD^{commit}"],
      4096,
      capture,
      label="HEAD commit",
    ) {
    Ok(value) => value.trim().to_lower().to_owned()
    Err(error) => return Err(error)
  }
  let tree = match
    native_direct_take_git_text(
      root,
      ["show", "-s", "--format=%T", "--no-show-signature", commit],
      4096,
      capture,
      label="HEAD tree",
    ) {
    Ok(value) => value.trim().to_lower().to_owned()
    Err(error) => return Err(error)
  }
  let git_directory = match
    native_direct_take_git_text(
      root,
      ["rev-parse", "--path-format=absolute", "--absolute-git-dir"],
      4096,
      capture,
      label="Git directory",
    ) {
    Ok(value) => value.trim().to_owned()
    Err(error) => return Err(error)
  }
  let object_directory = match
    native_direct_take_git_text(
      root,
      ["rev-parse", "--path-format=absolute", "--git-path", "objects"],
      4096,
      capture,
      label="Git object directory",
    ) {
    Ok(value) => value.trim().to_owned()
    Err(error) => return Err(error)
  }
  let status = match
    native_direct_take_git_text(
      root,
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
      1048576,
      capture,
      label="worktree status",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if status != "" {
    return Err(native_direct_take_git_error("worktree must be clean"))
  }
  if canonicalize(root) != Some(root) ||
    canonicalize(git_directory) != Some(git_directory) ||
    canonicalize(object_directory) != Some(object_directory) ||
    !@git_integration.valid_hex_oid_text(commit) ||
    !@git_integration.valid_hex_oid_text(tree) {
    return Err(native_direct_take_git_error("repository identity is invalid"))
  }
  let source_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.direct-take-source.v1\u{00}" +
      root +
      "\u{00}" +
      commit +
      "\u{00}" +
      tree,
    ),
  )
  Ok({
    repository_root: root,
    git_directory,
    object_directory,
    commit_oid: @control.GitOid(commit),
    tree_oid: @control.GitOid(tree),
    source_digest,
  })
}

///|
pub async fn capture_native_direct_take_snapshot(
  project_dir : String,
) -> Result[NativeDirectTakeSnapshot, @types.ChoirError] {
  capture_native_direct_take_snapshot_with(
    project_dir, capture_native_direct_take_git, @sys.realpath_native,
  )
}

///|
fn native_direct_take_nul_paths(
  output : String,
) -> Result[Array[@control.RepoPath], @types.ChoirError] {
  let paths : Array[@control.RepoPath] = []
  for raw in output.split("\u{00}") {
    if raw != "" {
      paths.push(@control.RepoPath(raw.to_owned()))
    }
  }
  paths.sort()
  for index = 1; index < paths.length(); index = index + 1 {
    if paths[index - 1] == paths[index] {
      return Err(native_direct_take_git_error("path evidence is duplicated"))
    }
  }
  Ok(paths)
}

///|
fn native_direct_take_tree_paths(
  output : String,
) -> Result[
  (Array[@control.RepoPath], Array[@control.RepoPath]),
  @types.ChoirError,
] {
  let paths : Array[@control.RepoPath] = []
  let symlinks : Array[@control.RepoPath] = []
  for raw in output.split("\u{00}") {
    if raw == "" {
      continue
    }
    let mut separator = -1
    for index = 0; index < raw.length(); index = index + 1 {
      if raw[index] == '\t' {
        separator = index
        break
      }
    }
    if separator <= 0 || separator + 1 >= raw.length() {
      return Err(
        native_direct_take_git_error("candidate tree listing is invalid"),
      )
    }
    let metadata = raw[:separator].to_owned()
    let path = @control.RepoPath(raw[separator + 1:].to_owned())
    paths.push(path)
    if metadata.has_prefix("120000 ") {
      symlinks.push(path)
    }
  }
  paths.sort()
  symlinks.sort()
  for index = 1; index < paths.length(); index = index + 1 {
    if paths[index - 1] == paths[index] {
      return Err(
        native_direct_take_git_error("candidate tree path is duplicated"),
      )
    }
  }
  Ok((paths, symlinks))
}

///|
test "direct Take Git path parsers retain sorted NUL and symlink evidence" {
  assert_eq(
    native_direct_take_nul_paths("src/z.mbt\u{00}README.md\u{00}").unwrap(),
    [@control.RepoPath("README.md"), @control.RepoPath("src/z.mbt")],
  )
  let (paths, symlinks) = native_direct_take_tree_paths(
    "100644 blob a\tsrc/z.mbt\u{00}120000 blob b\tvendor/current\u{00}",
  ).unwrap()
  assert_eq(paths, [
    @control.RepoPath("src/z.mbt"),
    @control.RepoPath("vendor/current"),
  ])
  assert_eq(symlinks, [@control.RepoPath("vendor/current")])
  assert_true(native_direct_take_nul_paths("a\u{00}a\u{00}") is Err(_))
  assert_true(native_direct_take_tree_paths("missing-tab\u{00}") is Err(_))
}

///|
pub async fn observe_native_direct_take_patch_with(
  snapshot : NativeDirectTakeSnapshot,
  config : @git_host.NativeGitWorkspaceConfig,
  result_root : String,
  runtime_key : String,
  capture : async (NativeDirectTakeGitCaptureRequest) -> Result[
    @process_host.NativeBoundedBytesProcessOutcome,
    @types.ChoirError,
  ],
) -> Result[NativeDirectTakePatch, @types.ChoirError] {
  let candidate_tree = match
    @git_host.observe_native_git_result_tree(
      config,
      "result-" + runtime_key,
      snapshot.commit_oid,
      snapshot.source_digest,
      result_root,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let environment = native_direct_take_control_git_environment(config)
  let changed_text = match
    native_direct_take_git_text(
      config.staging_root,
      [
        "diff",
        "--name-only",
        "-z",
        "--no-renames",
        snapshot.tree_oid.0,
        candidate_tree.0,
        "--",
      ],
      1048576,
      capture,
      environment~,
      label="candidate changed paths",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let changed_paths = match native_direct_take_nul_paths(changed_text) {
    Ok(value) if value.length() <= 4096 => value
    Ok(_) =>
      return Err(
        native_direct_take_git_error("candidate changes too many paths"),
      )
    Err(error) => return Err(error)
  }
  let tree_text = match
    native_direct_take_git_text(
      config.staging_root,
      ["ls-tree", "-r", "-z", candidate_tree.0],
      16777216,
      capture,
      environment~,
      label="candidate tree paths",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (candidate_tree_paths, symlink_prefix_paths) = match
    native_direct_take_tree_paths(tree_text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let base_tree_text = match
    native_direct_take_git_text(
      config.staging_root,
      ["ls-tree", "-r", "-z", snapshot.tree_oid.0],
      16777216,
      capture,
      environment~,
      label="base tree paths",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (_, base_symlink_prefix_paths) = match
    native_direct_take_tree_paths(base_tree_text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for path in base_symlink_prefix_paths {
    if !symlink_prefix_paths.contains(path) {
      symlink_prefix_paths.push(path)
    }
  }
  symlink_prefix_paths.sort()
  let patch = match
    native_direct_take_git_text(
      config.staging_root,
      [
        "diff",
        "--binary",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        snapshot.tree_oid.0,
        candidate_tree.0,
        "--",
      ],
      native_direct_take_patch_limit_bytes + 1,
      capture,
      environment~,
      label="candidate patch",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let patch_bytes = @utf8.encode(patch)
  if patch_bytes.length() > native_direct_take_patch_limit_bytes {
    return Err(
      native_direct_take_git_error("candidate patch exceeds 1048576 bytes"),
    )
  }
  let candidate : @workflow.DirectTakeCandidate = {
    base_commit_oid: snapshot.commit_oid,
    base_tree_oid: snapshot.tree_oid,
    candidate_tree_oid: candidate_tree,
    changed_paths,
    candidate_tree_paths,
    symlink_prefix_paths,
  }
  Ok({ candidate, patch, patch_digest: @storage.artifact_digest(patch_bytes) })
}

///|
pub async fn observe_native_direct_take_patch(
  snapshot : NativeDirectTakeSnapshot,
  config : @git_host.NativeGitWorkspaceConfig,
  result_root : String,
  runtime_key : String,
) -> Result[NativeDirectTakePatch, @types.ChoirError] {
  observe_native_direct_take_patch_with(
    snapshot, config, result_root, runtime_key, capture_native_direct_take_git,
  )
}

///|
fn native_direct_take_apply_arguments(check : Bool) -> Array[String] {
  let arguments = [
    "-c", "core.hooksPath=/dev/null", "apply", "--binary", "--whitespace=nowarn",
  ]
  if check {
    arguments.push("--check")
  }
  arguments.push("-")
  arguments
}

///|
pub async fn apply_native_direct_take_patch_with(
  expected : NativeDirectTakeSnapshot,
  patch : NativeDirectTakePatch,
  observe : async () -> Result[NativeDirectTakeSnapshot, @types.ChoirError],
  capture : async (NativeDirectTakeGitCaptureRequest) -> Result[
    @process_host.NativeBoundedBytesProcessOutcome,
    @types.ChoirError,
  ],
) -> Result[Unit, @types.ChoirError] {
  let patch_bytes = @utf8.encode(patch.patch)
  if patch_bytes.length() > native_direct_take_patch_limit_bytes ||
    @storage.artifact_digest(patch_bytes) != patch.patch_digest ||
    patch.candidate.base_commit_oid != expected.commit_oid ||
    patch.candidate.base_tree_oid != expected.tree_oid {
    return Err(
      native_direct_take_git_error("patch identity changed before apply"),
    )
  }
  let before_check = match observe() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if before_check != expected {
    return Err(native_direct_take_git_error("HEAD changed before patch check"))
  }
  let checked = match
    capture({
      program: "/usr/bin/git",
      arguments: native_direct_take_apply_arguments(true),
      environment: native_direct_take_host_git_environment(),
      cwd: expected.repository_root,
      stdin: patch_bytes,
      timeout_ms: 120000,
      output_limit_bytes: 65536,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match native_direct_take_capture_text(checked, "patch check") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(@utf8.encode(patch.patch)) != patch.patch_digest {
    return Err(native_direct_take_git_error("patch digest changed after check"))
  }
  let before_apply = match observe() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if before_apply != expected {
    return Err(native_direct_take_git_error("HEAD changed before patch apply"))
  }
  let applied = match
    capture({
      program: "/usr/bin/git",
      arguments: native_direct_take_apply_arguments(false),
      environment: native_direct_take_host_git_environment(),
      cwd: expected.repository_root,
      stdin: patch_bytes,
      timeout_ms: 120000,
      output_limit_bytes: 65536,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match native_direct_take_capture_text(applied, "patch apply") {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
pub async fn apply_native_direct_take_patch(
  expected : NativeDirectTakeSnapshot,
  patch : NativeDirectTakePatch,
) -> Result[Unit, @types.ChoirError] {
  apply_native_direct_take_patch_with(
    expected,
    patch,
    async fn() { capture_native_direct_take_snapshot(expected.repository_root) },
    capture_native_direct_take_git,
  )
}

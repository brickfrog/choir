///|
pub(all) struct NativeGitWorkspaceConfig {
  repository_root : String
  staging_root : String
} derive(Debug, Eq)

///|
pub(all) struct NativeGitWorkspaceSource {
  root : String
  commit_oid : @control.GitOid
  tree_oid : @control.GitOid
  source_digest : @control.Digest
} derive(Debug, Eq)

///|
fn native_git_workspace_error(message : String) -> @types.ChoirError {
  @types.ChoirError::git_error("native Git workspace: " + message)
}

///|
fn valid_native_git_workspace_key(value : String) -> Bool {
  if value == "" || value.length() > 120 {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    let valid = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '_'.to_int() ||
      code == '-'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
fn valid_native_git_workspace_config(config : NativeGitWorkspaceConfig) -> Bool {
  config.repository_root.has_prefix("/") &&
  config.staging_root.has_prefix("/tmp/choir-v2-take-") &&
  config.staging_root.has_suffix("/staging") &&
  !config.repository_root.contains("\n") &&
  !config.staging_root.contains("/../")
}

///|
fn native_git_workspace_environment(
  index_file : String?,
  work_tree : String?,
  commit : Bool,
) -> Map[String, String] {
  let environment = native_git_environment(commit)
  match index_file {
    Some(value) => environment["GIT_INDEX_FILE"] = value
    None => ()
  }
  match work_tree {
    Some(value) => environment["GIT_WORK_TREE"] = value
    None => ()
  }
  environment
}

///|
async fn capture_native_git_workspace_process(
  config : NativeGitWorkspaceConfig,
  arguments : Array[String],
  index_file? : String? = None,
  work_tree? : String? = None,
  commit? : Bool = false,
  timeout_ms? : Int = 120000,
) -> Result[NativeGitCapture, @types.ChoirError] {
  let args : Array[String] = ["-C", config.repository_root]
  for item in arguments {
    args.push(item)
  }
  let collected = @async.with_timeout_opt(timeout_ms, () => {
    @process.collect_output_merged(
      "/usr/bin/git",
      args,
      extra_env=native_git_workspace_environment(index_file, work_tree, commit),
      inherit_env=false,
      cwd=config.repository_root,
    )
  }) catch {
    _ => return Err(native_git_workspace_error("Git process failed"))
  }
  let (exit_code, data) = match collected {
    Some(value) => value
    None => return Err(@types.ChoirError::timeout("native Git workspace"))
  }
  let output = data.text() catch {
    _ => return Err(native_git_workspace_error("Git output is not UTF-8"))
  }
  Ok({ exit_code, output })
}

///|
async fn native_git_workspace_oid(
  config : NativeGitWorkspaceConfig,
  arguments : Array[String],
  index_file? : String? = None,
  work_tree? : String? = None,
  commit? : Bool = false,
) -> Result[@control.GitOid, @types.ChoirError] {
  let capture = match
    capture_native_git_workspace_process(
      config,
      arguments,
      index_file~,
      work_tree~,
      commit~,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match parsed_git_oid(capture.output) {
    Some(value) if capture.exit_code == 0 => Ok(value)
    _ => Err(native_git_workspace_error("Git object identity is invalid"))
  }
}

///|
async fn remove_native_workspace_file(
  root : String,
  path : String,
) -> Result[Unit, @types.ChoirError] {
  let removed = @process.collect_output_merged(
    "/usr/bin/rm",
    ["--", path],
    extra_env={ "HOME": "/nonexistent", "PATH": "/usr/bin:/bin" },
    inherit_env=false,
    cwd=root,
  ) catch {
    _ => return Err(native_git_workspace_error("workspace cleanup failed"))
  }
  if removed.0 == 0 {
    Ok(())
  } else {
    Err(native_git_workspace_error("workspace cleanup failed"))
  }
}

///|
pub async fn stage_native_git_workspace(
  config : NativeGitWorkspaceConfig,
  key : String,
  commit_oid : @control.GitOid,
  expected_tree_oid : @control.GitOid,
  source_digest : @control.Digest,
) -> Result[NativeGitWorkspaceSource, @types.ChoirError] {
  if !valid_native_git_workspace_config(config) ||
    !valid_native_git_workspace_key(key) ||
    !valid_hex_oid_text(commit_oid.0) ||
    !valid_hex_oid_text(expected_tree_oid.0) ||
    !valid_hex_oid_text(source_digest.0) {
    return Err(
      @types.ChoirError::validation_error(
        "native Git workspace request is invalid",
      ),
    )
  }
  if @sys.realpath_native(config.repository_root) !=
    Some(config.repository_root) ||
    @sys.realpath_native(config.staging_root) != Some(config.staging_root) {
    return Err(native_git_workspace_error("workspace roots are not canonical"))
  }
  let observed_tree = match
    native_git_workspace_oid(config, [
      "show",
      "-s",
      "--format=%T",
      "--no-show-signature",
      commit_oid.0,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if observed_tree != expected_tree_oid {
    return Err(native_git_workspace_error("base tree does not match contract"))
  }
  let workspace = config.staging_root + "/" + key
  let archive = config.staging_root + "/" + key + ".tar"
  if @sys.path_exists(workspace) ||
    @sys.path_exists(archive) ||
    !@sys.create_dir_all(workspace) {
    return Err(native_git_workspace_error("staging identity is not fresh"))
  }
  let archived = match
    capture_native_git_workspace_process(config, [
      "archive",
      "--format=tar",
      "--output=" + archive,
      commit_oid.0,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if archived.exit_code != 0 {
    return Err(native_git_workspace_error("Git archive failed"))
  }
  let extracted = @process.collect_output_merged(
    "/usr/bin/tar",
    [
      "-xf", archive, "-C", workspace, "--no-same-owner", "--no-same-permissions",
    ],
    extra_env={ "HOME": "/nonexistent", "PATH": "/usr/bin:/bin", "LC_ALL": "C" },
    inherit_env=false,
    cwd=config.staging_root,
  ) catch {
    _ => return Err(native_git_workspace_error("archive extraction failed"))
  }
  if extracted.0 != 0 {
    return Err(native_git_workspace_error("archive extraction failed"))
  }
  match remove_native_workspace_file(config.staging_root, archive) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if @sys.path_exists(workspace + "/.git") ||
    !@sys.write_file_sync(
      workspace + "/.choir-source-root",
      source_digest.0 + "\n",
    ) {
    return Err(native_git_workspace_error("staged source is invalid"))
  }
  Ok({ root: workspace, commit_oid, tree_oid: expected_tree_oid, source_digest })
}

///|
fn native_git_nul_paths(output : String) -> Array[@control.RepoPath] {
  let paths : Array[@control.RepoPath] = []
  for raw in output.split("\u{00}") {
    if raw != "" {
      paths.push(@control.RepoPath(raw.to_owned()))
    }
  }
  paths
}

///|
fn native_git_symlink_paths(output : String) -> Array[@control.RepoPath] {
  let paths : Array[@control.RepoPath] = []
  for raw in output.split("\u{00}") {
    if raw.has_prefix("120000 ") {
      for index = 0; index < raw.length(); index = index + 1 {
        if raw[index] == '\t' {
          paths.push(@control.RepoPath(raw[index + 1:].to_owned()))
          break
        }
      }
    }
  }
  paths
}

///|
pub async fn normalize_native_git_candidate(
  config : NativeGitWorkspaceConfig,
  key : String,
  goal_id : @control.GoalId,
  part_id : @control.PartId,
  take_id : @control.TakeId,
  base_commit_oid : @control.GitOid,
  result_root : String,
) -> Result[
  (@control.CandidateCommit, @control.CandidatePathEvidence),
  @types.ChoirError,
] {
  if !valid_native_git_workspace_config(config) ||
    !valid_native_git_workspace_key(key) ||
    !valid_hex_oid_text(base_commit_oid.0) ||
    @sys.realpath_native(result_root) != Some(result_root) ||
    !result_root.has_prefix(
      config.staging_root[:config.staging_root.length() - "/staging".length()] +
      "/results/",
    ) ||
    @sys.path_exists(result_root + "/.git") {
    return Err(
      @types.ChoirError::validation_error(
        "native candidate workspace is invalid",
      ),
    )
  }
  let marker = result_root + "/.choir-source-root"
  if !@sys.path_exists(marker) {
    return Err(native_git_workspace_error("candidate source marker is missing"))
  }
  match remove_native_workspace_file(result_root, marker) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let index_root = config.staging_root + "/indexes"
  let index_file = index_root + "/" + key + ".index"
  if !@sys.create_dir_all(index_root) || @sys.path_exists(index_file) {
    return Err(
      native_git_workspace_error("candidate index identity is not fresh"),
    )
  }
  let read_tree = match
    capture_native_git_workspace_process(
      config,
      ["read-tree", base_commit_oid.0],
      index_file=Some(index_file),
      work_tree=Some(result_root),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if read_tree.exit_code != 0 {
    return Err(
      native_git_workspace_error("candidate index initialization failed"),
    )
  }
  let added = match
    capture_native_git_workspace_process(
      config,
      ["add", "-A", "--", "."],
      index_file=Some(index_file),
      work_tree=Some(result_root),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if added.exit_code != 0 {
    return Err(native_git_workspace_error("candidate indexing failed"))
  }
  let tree_oid = match
    native_git_workspace_oid(
      config,
      ["write-tree"],
      index_file=Some(index_file),
      work_tree=Some(result_root),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let commit_oid = match
    native_git_workspace_oid(
      config,
      [
        "commit-tree",
        tree_oid.0,
        "-p",
        base_commit_oid.0,
        "-m",
        "choir: candidate for Part " + part_id.0,
      ],
      index_file=Some(index_file),
      work_tree=Some(result_root),
      commit=true,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let changed = match
    capture_native_git_workspace_process(config, [
      "diff-tree",
      "--no-commit-id",
      "--name-only",
      "-r",
      "-z",
      base_commit_oid.0,
      commit_oid.0,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let tree = match
    capture_native_git_workspace_process(config, [
      "ls-tree",
      "-r",
      "-z",
      tree_oid.0,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if changed.exit_code != 0 || tree.exit_code != 0 {
    return Err(native_git_workspace_error("candidate evidence failed"))
  }
  let changed_paths = native_git_nul_paths(changed.output)
  let tree_paths : Array[@control.RepoPath] = []
  for raw in tree.output.split("\u{00}") {
    for index = 0; index < raw.length(); index = index + 1 {
      if raw[index] == '\t' {
        tree_paths.push(@control.RepoPath(raw[index + 1:].to_owned()))
        break
      }
    }
  }
  let canonical_change_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.canonical-change.v1\u{00}" +
      base_commit_oid.0 +
      "\u{00}" +
      commit_oid.0 +
      "\u{00}" +
      tree_oid.0 +
      "\u{00}" +
      changed_paths.to_json().stringify(indent=0),
    ),
  )
  let candidate : @control.CandidateCommit = {
    id: @control.CandidateId(key + "-candidate"),
    goal_id,
    part_id,
    take_id,
    base_commit_oid,
    commit_oid,
    tree_oid,
    canonical_change_digest,
    changed_paths,
  }
  Ok(
    (
      candidate,
      {
        candidate_tree_paths: tree_paths,
        symlink_prefix_paths: native_git_symlink_paths(tree.output),
        normalization_collision_paths: [],
      },
    ),
  )
}

///|
test "native Git workspace keys reject path syntax" {
  assert_true(valid_native_git_workspace_key("take-1"))
  assert_false(valid_native_git_workspace_key("../take"))
  assert_false(valid_native_git_workspace_key("take/one"))
  assert_false(valid_native_git_workspace_key(""))
}

///|
test "native Git evidence keeps NUL paths and symlink identity" {
  assert_eq(native_git_nul_paths("src/a.mbt\u{00}docs/b.md\u{00}"), [
    @control.RepoPath("src/a.mbt"),
    @control.RepoPath("docs/b.md"),
  ])
  assert_eq(
    native_git_symlink_paths(
      "120000 blob 0123456789012345678901234567890123456789\tAGENTS.md\u{00}" +
      "100644 blob 0123456789012345678901234567890123456789\tREADME.md\u{00}",
    ),
    [@control.RepoPath("AGENTS.md")],
  )
}

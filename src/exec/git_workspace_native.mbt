///|
pub(all) struct NativeGitWorkspaceConfig {
  repository_root : String
  object_directory : String
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
  config.object_directory.has_prefix("/") &&
  config.object_directory.has_suffix("/objects") &&
  config.staging_root.has_prefix("/tmp/choir-take-") &&
  config.staging_root.has_suffix("/staging") &&
  !config.repository_root.contains("\n") &&
  !config.object_directory.contains("\n") &&
  !config.object_directory.contains("/../") &&
  !config.staging_root.contains("/../")
}

///|
fn native_git_workspace_environment(
  config : NativeGitWorkspaceConfig,
  index_file : String?,
  work_tree : String?,
  commit : Bool,
) -> Map[String, String] {
  let environment = native_git_environment(commit)
  environment["GIT_DIR"] = config.staging_root + "/git-control"
  environment["GIT_OBJECT_DIRECTORY"] = config.object_directory
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  environment["GIT_ATTR_NOSYSTEM"] = "1"
  environment["XDG_CONFIG_HOME"] = "/nonexistent"
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
fn ensure_native_git_control(
  config : NativeGitWorkspaceConfig,
) -> Result[Unit, @types.ChoirError] {
  let root = config.staging_root + "/git-control"
  let config_path = root + "/config"
  let head_path = root + "/HEAD"
  let config_content = "[core]\n\trepositoryformatversion = 0\n\tbare = true\n"
  let head_content = "ref: refs/heads/choir-control\n"
  if !@sys.create_dir_all(root + "/refs/heads") ||
    !@sys.create_dir_all(root + "/objects/info") ||
    !@sys.create_dir_all(root + "/objects/pack") {
    return Err(native_git_workspace_error("Git control root creation failed"))
  }
  if @sys.realpath_native(root) != Some(root) {
    return Err(native_git_workspace_error("Git control root is not canonical"))
  }
  if @sys.path_exists(config_path) {
    if @sys.read_file(config_path) != config_content {
      return Err(native_git_workspace_error("Git control config is invalid"))
    }
  } else if !@sys.write_file_sync(config_path, config_content) {
    return Err(native_git_workspace_error("Git control config creation failed"))
  }
  if @sys.path_exists(head_path) {
    if @sys.read_file(head_path) != head_content {
      return Err(native_git_workspace_error("Git control HEAD is invalid"))
    }
  } else if !@sys.write_file_sync(head_path, head_content) {
    return Err(native_git_workspace_error("Git control HEAD creation failed"))
  }
  Ok(())
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
  match ensure_native_git_control(config) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let args : Array[String] = []
  for item in arguments {
    args.push(item)
  }
  let collected = @async.with_timeout_opt(timeout_ms, () => {
    @process.collect_output_merged(
      "/usr/bin/git",
      args,
      extra_env=native_git_workspace_environment(
        config, index_file, work_tree, commit,
      ),
      inherit_env=false,
      cwd=config.staging_root,
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
    @sys.realpath_native(config.object_directory) !=
    Some(config.object_directory) ||
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
async fn prepare_native_git_result_index(
  config : NativeGitWorkspaceConfig,
  key : String,
  base_commit_oid : @control.GitOid,
  expected_source_digest : @control.Digest,
  result_root : String,
) -> Result[String, @types.ChoirError] {
  if !valid_native_git_workspace_config(config) ||
    !valid_native_git_workspace_key(key) ||
    !valid_hex_oid_text(base_commit_oid.0) ||
    !valid_hex_oid_text(expected_source_digest.0) ||
    @sys.realpath_native(config.object_directory) !=
    Some(config.object_directory) ||
    @sys.realpath_native(result_root) != Some(result_root) ||
    !result_root.has_prefix(
      config.staging_root[:config.staging_root.length() - "/staging".length()] +
      "/results/",
    ) ||
    @sys.path_exists(result_root + "/.git") {
    return Err(
      @types.ChoirError::validation_error("native result workspace is invalid"),
    )
  }
  let marker = result_root + "/.choir-source-root"
  let index_root = config.staging_root + "/indexes"
  let index_file = index_root + "/" + key + ".index"
  let state_file = index_root + "/" + key + ".state"
  let state_content = base_commit_oid.0 +
    "\n" +
    expected_source_digest.0 +
    "\n" +
    result_root +
    "\n"
  if !@sys.create_dir_all(index_root) {
    return Err(native_git_workspace_error("result index root failed"))
  }
  if @sys.path_exists(state_file) {
    if @sys.read_file(state_file) != state_content {
      if !@sys.path_exists(marker) {
        return Err(native_git_workspace_error("result retry state is invalid"))
      }
      match remove_native_workspace_file(index_root, state_file) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      if !@sys.write_file_sync(state_file, state_content) {
        return Err(native_git_workspace_error("result retry state failed"))
      }
    }
  } else if !@sys.path_exists(marker) ||
    @sys.read_file(marker) != expected_source_digest.0 + "\n" ||
    !@sys.write_file_sync(state_file, state_content) {
    return Err(native_git_workspace_error("result source is invalid"))
  }
  if @sys.read_file(state_file) != state_content {
    return Err(native_git_workspace_error("result retry state is false"))
  }
  if @sys.path_exists(marker) {
    match remove_native_workspace_file(result_root, marker) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  if @sys.path_exists(index_file) {
    match remove_native_workspace_file(index_root, index_file) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
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
    return Err(native_git_workspace_error("result index initialization failed"))
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
    return Err(native_git_workspace_error("result indexing failed"))
  }
  Ok(index_file)
}

///|
pub async fn observe_native_git_result_tree(
  config : NativeGitWorkspaceConfig,
  key : String,
  base_commit_oid : @control.GitOid,
  expected_source_digest : @control.Digest,
  result_root : String,
) -> Result[@control.GitOid, @types.ChoirError] {
  let index_file = match
    prepare_native_git_result_index(
      config, key, base_commit_oid, expected_source_digest, result_root,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  native_git_workspace_oid(
    config,
    ["write-tree"],
    index_file=Some(index_file),
    work_tree=Some(result_root),
  )
}

///|
pub async fn normalize_native_git_candidate(
  config : NativeGitWorkspaceConfig,
  key : String,
  goal_id : @control.GoalId,
  part_id : @control.PartId,
  take_id : @control.TakeId,
  base_commit_oid : @control.GitOid,
  expected_source_digest : @control.Digest,
  result_root : String,
) -> Result[
  (@control.CandidateCommit, @control.CandidatePathEvidence),
  @types.ChoirError,
] {
  let index_file = match
    prepare_native_git_result_index(
      config, key, base_commit_oid, expected_source_digest, result_root,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
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
test "native Git workspace environment isolates repository configuration" {
  let config : NativeGitWorkspaceConfig = {
    repository_root: "/repo",
    object_directory: "/repo/.git/objects",
    staging_root: "/tmp/choir-take-test/staging",
  }
  let environment = native_git_workspace_environment(
    config,
    Some("/tmp/choir-take-test/staging/index"),
    Some("/tmp/choir-take-test/result"),
    false,
  )
  assert_eq(environment["GIT_DIR"], "/tmp/choir-take-test/staging/git-control")
  assert_eq(environment["GIT_OBJECT_DIRECTORY"], "/repo/.git/objects")
  assert_eq(environment["GIT_CONFIG_GLOBAL"], "/dev/null")
  assert_eq(environment["GIT_ATTR_NOSYSTEM"], "1")
  assert_eq(environment["HOME"], "/nonexistent")
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

///|
async fn native_git_evidence_test_command(
  cwd : String,
  arguments : Array[String],
) -> String {
  let (exit_code, data) = @process.collect_output_merged(
    "/usr/bin/git",
    arguments,
    extra_env={
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_NOSYSTEM": "1",
      "HOME": "/nonexistent",
      "LC_ALL": "C.UTF-8",
      "PATH": "/usr/bin:/bin",
    },
    inherit_env=false,
    cwd~,
  ) catch {
    _ => fail("native Git evidence fixture process failed")
  }
  let output = data.text() catch {
    _ => fail("native Git evidence fixture output was not UTF-8")
  }
  if exit_code != 0 {
    fail("native Git evidence fixture command failed: " + output)
  }
  output
}

///|
async test "native Git candidate evidence captures raw changed paths and symlinks" {
  let root = "/tmp/choir-take-path-evidence-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  defer ignore(@sys.rm_rf(root))
  let repository = root + "/repository"
  let staging = root + "/staging"
  let result = root + "/results/candidate"
  guard @sys.create_dir_all(repository + "/src") &&
    @sys.create_dir_all(repository + "/docs") &&
    @sys.create_dir_all(staging) else {
    fail("native Git evidence fixture root failed")
  }
  ignore(native_git_evidence_test_command(repository, ["init", "--quiet"]))
  guard @sys.write_file_sync(repository + "/src/old_name.mbt", "old\n") &&
    @sys.write_file_sync(repository + "/src/delete.mbt", "delete\n") &&
    @sys.write_file_sync(repository + "/docs/café.md", "composed\n") else {
    fail("native Git evidence fixture base files failed")
  }
  ignore(
    native_git_evidence_test_command(repository, ["add", "--all", "--", "."]),
  )
  ignore(
    native_git_evidence_test_command(repository, [
      "-c", "user.name=Choir Test", "-c", "user.email=choir-test@invalid", "commit",
      "--quiet", "-m", "base",
    ]),
  )
  let base_commit = @control.GitOid(
    native_git_evidence_test_command(repository, ["rev-parse", "HEAD"])
    .trim()
    .to_owned(),
  )
  let base_tree = @control.GitOid(
    native_git_evidence_test_command(repository, [
      "show", "-s", "--format=%T", "HEAD",
    ])
    .trim()
    .to_owned(),
  )
  let config : NativeGitWorkspaceConfig = {
    repository_root: repository,
    object_directory: repository + "/.git/objects",
    staging_root: staging,
  }
  let source_digest = @control.Digest(
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  let source = match
    stage_native_git_workspace(
      config, "path-evidence", base_commit, base_tree, source_digest,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard @sys.create_dir_all(result) else {
    fail("native Git evidence result root failed")
  }
  let copied = @process.collect_output_merged(
    "/usr/bin/cp",
    ["-a", source.root + "/.", result],
    extra_env={ "HOME": "/nonexistent", "PATH": "/usr/bin:/bin" },
    inherit_env=false,
    cwd=root,
  ) catch {
    _ => fail("native Git evidence source copy failed")
  }
  if copied.0 != 0 {
    fail("native Git evidence source copy failed")
  }
  ignore(@sys.rm_rf(result + "/src/old_name.mbt"))
  ignore(@sys.rm_rf(result + "/src/delete.mbt"))
  guard @sys.write_file_sync(result + "/src/new_name.mbt", "old\n") &&
    @sys.create_dir_all(result + "/generated") &&
    @sys.create_dir_all(result + "/case") &&
    @sys.write_file_sync(result + "/generated/schema.mbt", "generated\n") &&
    @sys.write_file_sync(result + "/case/A.mbt", "upper\n") &&
    @sys.write_file_sync(result + "/case/a.mbt", "lower\n") &&
    @sys.write_file_sync(result + "/docs/cafe\u{301}.md", "decomposed\n") &&
    @sys.symlink_force("new_name.mbt", result + "/src/link.mbt") else {
    fail("native Git evidence candidate mutation failed")
  }
  let normalized = match
    normalize_native_git_candidate(
      config,
      "path-evidence-candidate",
      @control.GoalId("path-evidence-goal"),
      @control.PartId("path-evidence-part"),
      @control.TakeId("path-evidence-take"),
      base_commit,
      source.source_digest,
      result,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let expected = [
    @control.RepoPath("case/A.mbt"),
    @control.RepoPath("case/a.mbt"),
    @control.RepoPath("docs/cafe\u{301}.md"),
    @control.RepoPath("generated/schema.mbt"),
    @control.RepoPath("src/delete.mbt"),
    @control.RepoPath("src/link.mbt"),
    @control.RepoPath("src/new_name.mbt"),
    @control.RepoPath("src/old_name.mbt"),
  ]
  assert_eq(normalized.0.changed_paths.length(), expected.length())
  for path in expected {
    assert_true(
      normalized.0.changed_paths.any(fn(observed) { observed == path }),
    )
  }
  assert_eq(normalized.1.symlink_prefix_paths, [
    @control.RepoPath("src/link.mbt"),
  ])
  assert_true(
    @control.validate_repo_path(
      @control.RepoPath("docs/cafe\u{301}.md"),
      native_path_is_nfc,
    )
    is Err(_),
  )
}

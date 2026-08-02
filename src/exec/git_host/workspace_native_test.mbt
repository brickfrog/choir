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
async test "real exec integration: native Git candidate evidence captures raw paths" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
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
  let source_digest = @control.Digest("a".repeat(64))
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
      @control.SemanticCommitTitle("test: capture path evidence"),
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
  assert_eq(
    native_git_evidence_test_command(repository, [
      "show",
      "-s",
      "--format=%s",
      normalized.0.commit_oid.0,
    ])
    .trim()
    .to_owned(),
    "test: capture path evidence",
  )
  assert_eq(normalized.0.changed_paths.length(), expected.length())
  for path in expected {
    assert_true(
      normalized.0.changed_paths.any(fn(observed) { observed == path }),
    )
  }
  assert_eq(normalized.1.symlink_prefix_paths, [
    @control.RepoPath("src/link.mbt"),
  ])
}

///|
fn native_git_captured_test_config(root : String) -> NativeGitWorkspaceConfig {
  {
    repository_root: root + "/repository",
    object_directory: root + "/repository/.git/objects",
    staging_root: root + "/staging",
  }
}

///|
fn native_git_captured_test_prepare(root : String) -> NativeGitWorkspaceConfig {
  ignore(@sys.rm_rf(root))
  let config = native_git_captured_test_config(root)
  guard @sys.create_dir_all(config.object_directory) &&
    @sys.create_dir_all(config.staging_root) else {
    abort("captured staging test root failed")
  }
  config
}

///|
fn native_git_captured_test_environment(
  config : NativeGitWorkspaceConfig,
) -> Map[String, String] {
  {
    "PATH": "/usr/bin:/bin",
    "HOME": "/nonexistent",
    "LC_ALL": "C",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_DIR": config.staging_root + "/git-control",
    "GIT_OBJECT_DIRECTORY": config.object_directory,
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_ATTR_NOSYSTEM": "1",
    "XDG_CONFIG_HOME": "/nonexistent",
  }
}

///|
fn native_git_captured_test_manifest(
  tree_oid : String,
  symlink_oid : String,
) -> Bytes {
  @utf8.encode(
    "040000 tree " +
    tree_oid +
    " -\t.choir\u{0000}" +
    "100644 blob " +
    "4".repeat(40) +
    " 7\tCLAUDE.md\u{0000}" +
    "120000 blob " +
    symlink_oid +
    " 9\tAGENTS.md\u{0000}",
  )
}

///|
fn native_git_captured_test_cat_response(symlink_oid : String) -> Bytes {
  @utf8.encode(symlink_oid + " blob 9\nCLAUDE.md\n")
}

///|
async test "captured Git staging issues exact bounded requests and retains only source" {
  let root = "/tmp/choir-take-captured-success-" + @sys.get_pid().to_string()
  let config = native_git_captured_test_prepare(root)
  defer ignore(@sys.rm_rf(root))
  let commit_oid = @control.GitOid("1".repeat(40))
  let tree_oid = @control.GitOid("2".repeat(40))
  let symlink_oid = "3".repeat(40)
  let source_digest = @control.Digest("a".repeat(64))
  let requests : Array[NativeGitStagingProcessRequest] = []
  let capture = async fn(request : NativeGitStagingProcessRequest) {
    @async.sleep(0)
    requests.push(request)
    match requests.length() {
      1 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            @utf8.encode(tree_oid.0 + "\n"),
          ),
        )
      2 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            native_git_captured_test_manifest(tree_oid.0, symlink_oid),
          ),
        )
      3 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            native_git_captured_test_cat_response(symlink_oid),
          ),
        )
      4 => {
        assert_true(
          @sys.write_file_sync(config.staging_root + "/captured.tar", "tar"),
        )
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0, b"",
          ),
        )
      }
      5 => {
        let workspace = config.staging_root + "/captured"
        assert_true(@sys.create_dir_all(workspace + "/.choir"))
        assert_true(@sys.write_file_sync(workspace + "/CLAUDE.md", "claude\n"))
        assert_true(@sys.symlink_force("CLAUDE.md", workspace + "/AGENTS.md"))
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0, b"",
          ),
        )
      }
      _ => abort("unexpected captured staging request")
    }
  }
  let staged = stage_native_git_workspace_with_capture(
    config, "captured", commit_oid, tree_oid, source_digest, capture,
  ).unwrap()
  assert_eq(requests.length(), 5)
  let git_environment = native_git_captured_test_environment(config)
  assert_eq(requests[0], NativeGitStagingProcessRequest::{
    program: "/usr/bin/git",
    arguments: [
      "show",
      "-s",
      "--format=%T",
      "--no-show-signature",
      commit_oid.0,
    ],
    environment: git_environment,
    cwd: config.staging_root,
    stdin: b"",
    timeout_ms: 120000,
    output_limit_bytes: 4096,
  })
  assert_eq(requests[1].program, "/usr/bin/git")
  assert_eq(requests[1].arguments, [
    "ls-tree",
    "--full-tree",
    "-r",
    "-t",
    "-l",
    "-z",
    tree_oid.0,
  ])
  assert_eq(requests[1].environment, git_environment)
  assert_eq(requests[1].cwd, config.staging_root)
  assert_eq(requests[1].stdin, b"")
  assert_eq(requests[1].timeout_ms, 120000)
  assert_eq(requests[1].output_limit_bytes, 64 * 1024 * 1024 + 128 * 100000)
  assert_eq(requests[2], NativeGitStagingProcessRequest::{
    program: "/usr/bin/git",
    arguments: ["cat-file", "--batch"],
    environment: git_environment,
    cwd: config.staging_root,
    stdin: @utf8.encode(symlink_oid + "\n"),
    timeout_ms: 120000,
    output_limit_bytes: 9 + 128,
  })
  assert_eq(requests[3], NativeGitStagingProcessRequest::{
    program: "/usr/bin/prlimit",
    arguments: [
      "--fsize=1060928",
      "--",
      "/usr/bin/git",
      "archive",
      "--format=tar",
      "--output=" + config.staging_root + "/captured.tar",
      tree_oid.0,
    ],
    environment: git_environment,
    cwd: config.staging_root,
    stdin: b"",
    timeout_ms: 120000,
    output_limit_bytes: 1024 * 1024,
  })
  assert_eq(requests[4], NativeGitStagingProcessRequest::{
    program: "/usr/bin/tar",
    arguments: [
      "--restrict",
      "--extract",
      "--file=" + config.staging_root + "/captured.tar",
      "--directory=" + config.staging_root + "/captured",
      "--no-same-owner",
      "--no-same-permissions",
      "--delay-directory-restore",
      "--no-overwrite-dir",
    ],
    environment: {
      "HOME": "/nonexistent",
      "PATH": "/usr/bin:/bin",
      "LC_ALL": "C",
    },
    cwd: config.staging_root,
    stdin: b"",
    timeout_ms: 120000,
    output_limit_bytes: 1024 * 1024,
  })
  assert_eq(staged.root, config.staging_root + "/captured")
  assert_eq(
    @sys.read_file(staged.root + "/.choir-source-root"),
    source_digest.0 + "\n",
  )
  assert_false(@sys.path_entry_exists(config.staging_root + "/captured.tar"))
  assert_true(@sys.path_entry_exists(staged.root + "/CLAUDE.md"))
}

///|
async test "captured Git staging rejects unsafe trees before archive creation" {
  let root = "/tmp/choir-take-captured-unsafe-" + @sys.get_pid().to_string()
  let config = native_git_captured_test_prepare(root)
  defer ignore(@sys.rm_rf(root))
  let commit_oid = @control.GitOid("1".repeat(40))
  let tree_oid = @control.GitOid("2".repeat(40))
  let source_digest = @control.Digest("a".repeat(64))
  let calls = @ref.new(0)
  let capture = async fn(_request : NativeGitStagingProcessRequest) {
    @async.sleep(0)
    calls.val = calls.val + 1
    match calls.val {
      1 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            @utf8.encode(tree_oid.0 + "\n"),
          ),
        )
      2 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            @utf8.encode(
              "160000 commit " + "3".repeat(40) + " -\tsubmodule\u{0000}",
            ),
          ),
        )
      _ => abort("unsafe manifest reached an archive request")
    }
  }
  assert_true(
    stage_native_git_workspace_with_capture(
      config, "unsafe", commit_oid, tree_oid, source_digest, capture,
    )
    is Err(_),
  )
  assert_eq(calls.val, 2)
  assert_false(@sys.path_entry_exists(config.staging_root + "/unsafe"))
  assert_false(@sys.path_entry_exists(config.staging_root + "/unsafe.tar"))
}

///|
async test "captured Git staging rejects unsafe links before archive creation" {
  let root = "/tmp/choir-take-captured-link-" + @sys.get_pid().to_string()
  let config = native_git_captured_test_prepare(root)
  defer ignore(@sys.rm_rf(root))
  let commit_oid = @control.GitOid("1".repeat(40))
  let tree_oid = @control.GitOid("2".repeat(40))
  let symlink_oid = "3".repeat(40)
  let source_digest = @control.Digest("a".repeat(64))
  let calls = @ref.new(0)
  let capture = async fn(_request : NativeGitStagingProcessRequest) {
    @async.sleep(0)
    calls.val = calls.val + 1
    match calls.val {
      1 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            @utf8.encode(tree_oid.0 + "\n"),
          ),
        )
      2 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            @utf8.encode("120000 blob " + symlink_oid + " 7\tAGENTS.md\u{0000}"),
          ),
        )
      3 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            @utf8.encode(symlink_oid + " blob 7\nmissing\n"),
          ),
        )
      _ => abort("unsafe symlink reached an archive request")
    }
  }
  assert_true(
    stage_native_git_workspace_with_capture(
      config, "unsafe-link", commit_oid, tree_oid, source_digest, capture,
    )
    is Err(_),
  )
  assert_eq(calls.val, 3)
  assert_false(@sys.path_entry_exists(config.staging_root + "/unsafe-link"))
  assert_false(@sys.path_entry_exists(config.staging_root + "/unsafe-link.tar"))
}

///|
async test "captured Git staging cleans partial extraction after timeout" {
  let root = "/tmp/choir-take-captured-timeout-" + @sys.get_pid().to_string()
  let config = native_git_captured_test_prepare(root)
  defer ignore(@sys.rm_rf(root))
  let commit_oid = @control.GitOid("1".repeat(40))
  let tree_oid = @control.GitOid("2".repeat(40))
  let source_digest = @control.Digest("a".repeat(64))
  let calls = @ref.new(0)
  let capture = async fn(_request : NativeGitStagingProcessRequest) {
    @async.sleep(0)
    calls.val = calls.val + 1
    match calls.val {
      1 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            @utf8.encode(tree_oid.0 + "\n"),
          ),
        )
      2 =>
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0,
            @utf8.encode("100644 blob " + "3".repeat(40) + " 1\tfile\u{0000}"),
          ),
        )
      3 => {
        assert_true(
          @sys.write_file_sync(config.staging_root + "/timeout.tar", "tar"),
        )
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessCompleted(
            0, b"",
          ),
        )
      }
      4 => {
        assert_true(
          @sys.write_file_sync(
            config.staging_root + "/timeout/partial",
            "partial",
          ),
        )
        Ok(
          @process_host.NativeBoundedBytesProcessOutcome::NativeBytesProcessTimedOut(
            "tar timed out",
          ),
        )
      }
      _ => abort("unexpected captured timeout request")
    }
  }
  assert_true(
    stage_native_git_workspace_with_capture(
      config, "timeout", commit_oid, tree_oid, source_digest, capture,
    )
    is Err(_),
  )
  assert_eq(calls.val, 4)
  assert_false(@sys.path_entry_exists(config.staging_root + "/timeout"))
  assert_false(@sys.path_entry_exists(config.staging_root + "/timeout.tar"))
}

///|
async test "real exec integration: bounded Git staging preserves the exact tree" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-take-exact-stage-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  defer ignore(@sys.rm_rf(root))
  let repository = root + "/repository"
  let staging = root + "/staging"
  let outside = root + "/outside"
  guard @sys.create_dir_all(repository + "/.choir") &&
    @sys.create_dir_all(repository + "/docs") &&
    @sys.create_dir_all(staging) &&
    @sys.create_dir_all(outside) else {
    fail("exact staging fixture root failed")
  }
  ignore(native_git_evidence_test_command(repository, ["init", "--quiet"]))
  guard @sys.write_file_sync(
      repository + "/.choir/config.toml",
      "mode = 'test'\n",
    ) &&
    @sys.write_file_sync(repository + "/CLAUDE.md", "instructions\n") &&
    @sys.write_file_sync(repository + "/ordinary.txt", "$Format:%H$\n") &&
    @sys.write_file_sync(repository + "/docs/café.md", "unicode\n") &&
    @sys.write_file_sync(
      repository + "/.gitattributes",
      "AGENTS.md export-ignore\nordinary.txt export-subst\n",
    ) &&
    @sys.symlink_force("CLAUDE.md", repository + "/AGENTS.md") else {
    fail("exact staging fixture files failed")
  }
  ignore(
    native_git_evidence_test_command(repository, ["add", "--all", "--", "."]),
  )
  ignore(
    native_git_evidence_test_command(repository, [
      "-c", "user.name=Choir Test", "-c", "user.email=choir-test@invalid", "commit",
      "--quiet", "-m", "safe tree",
    ]),
  )
  let safe_commit = @control.GitOid(
    native_git_evidence_test_command(repository, ["rev-parse", "HEAD"])
    .trim()
    .to_owned(),
  )
  let safe_tree = @control.GitOid(
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
  let digest = @control.Digest("d".repeat(64))
  let staged = match
    stage_native_git_workspace(config, "safe", safe_commit, safe_tree, digest) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let top = @sys.list_dir_all(staged.root)
  assert_eq(top.length(), 7)
  for
    entry in [
      ".choir", ".choir-source-root", ".gitattributes", "AGENTS.md", "CLAUDE.md",
      "docs", "ordinary.txt",
    ] {
    assert_true(top.contains(entry))
  }
  assert_eq(
    @sys.read_file(staged.root + "/.choir/config.toml"),
    "mode = 'test'\n",
  )
  assert_eq(@sys.read_file(staged.root + "/ordinary.txt"), "$Format:%H$\n")
  assert_eq(@sys.read_file(staged.root + "/docs/café.md"), "unicode\n")
  let (readlink_code, readlink_data) = @process.collect_output_merged(
    "/usr/bin/readlink",
    ["--", staged.root + "/AGENTS.md"],
    extra_env={ "HOME": "/nonexistent", "LC_ALL": "C", "PATH": "/usr/bin:/bin" },
    inherit_env=false,
    cwd=root,
  ) catch {
    _ => fail("staged symlink read failed")
  }
  assert_eq(readlink_code, 0)
  assert_eq(readlink_data.text(), "CLAUDE.md\n")

  assert_true(@sys.rm_rf(repository + "/.choir"))
  assert_true(@sys.symlink_force(outside, repository + "/.choir"))
  ignore(
    native_git_evidence_test_command(repository, ["add", "--all", "--", "."]),
  )
  ignore(
    native_git_evidence_test_command(repository, [
      "-c", "user.name=Choir Test", "-c", "user.email=choir-test@invalid", "commit",
      "--quiet", "-m", "unsafe tree",
    ]),
  )
  let unsafe_commit = @control.GitOid(
    native_git_evidence_test_command(repository, ["rev-parse", "HEAD"])
    .trim()
    .to_owned(),
  )
  let unsafe_tree = @control.GitOid(
    native_git_evidence_test_command(repository, [
      "show", "-s", "--format=%T", "HEAD",
    ])
    .trim()
    .to_owned(),
  )
  assert_true(
    stage_native_git_workspace(
      config, "unsafe", unsafe_commit, unsafe_tree, digest,
    )
    is Err(_),
  )
  assert_false(@sys.path_entry_exists(staging + "/unsafe"))
  assert_false(@sys.path_entry_exists(staging + "/unsafe.tar"))
}

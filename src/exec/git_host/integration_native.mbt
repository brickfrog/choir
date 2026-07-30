///|
priv struct NativeGitProcessSpec {
  arguments : Array[String]
  stdin : String
  environment : Map[String, String]
  working_directory : String
}

///|
fn native_git_commit_date(epoch : Int64) -> String {
  "@" + epoch.to_string() + " +0000"
}

///|
pub fn native_git_environment(
  commit : Bool,
  commit_epoch? : Int64 = 0L,
) -> Map[String, String] {
  let environment : Map[String, String] = {
    "PATH": "/usr/bin:/bin",
    "HOME": "/nonexistent",
    "LC_ALL": "C",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_TERMINAL_PROMPT": "0",
  }
  if commit {
    let date = native_git_commit_date(commit_epoch)
    environment["GIT_AUTHOR_NAME"] = "Choir"
    environment["GIT_AUTHOR_EMAIL"] = "choir@localhost"
    environment["GIT_AUTHOR_DATE"] = date
    environment["GIT_COMMITTER_NAME"] = "Choir"
    environment["GIT_COMMITTER_EMAIL"] = "choir@localhost"
    environment["GIT_COMMITTER_DATE"] = date
  }
  environment
}

///|
fn native_git_integration_environment(
  config : @git_integration.NativeGitIntegrationConfig,
  object_access : Bool,
  commit : Bool,
  commit_epoch? : Int64 = 0L,
) -> Map[String, String] {
  let environment = native_git_environment(commit, commit_epoch~)
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  environment["GIT_ATTR_NOSYSTEM"] = "1"
  environment["XDG_CONFIG_HOME"] = "/nonexistent"
  if object_access {
    environment["GIT_DIR"] = config.control_root
    environment["GIT_OBJECT_DIRECTORY"] = config.object_directory
  } else {
    environment["GIT_DIR"] = config.git_directory
  }
  environment
}

///|
fn ensure_native_git_integration_control(
  config : @git_integration.NativeGitIntegrationConfig,
) -> Result[Unit, @types.ChoirError] {
  let config_path = config.control_root + "/config"
  let head_path = config.control_root + "/HEAD"
  let config_content = "[core]\n\trepositoryformatversion = 0\n\tbare = true\n\thooksPath = /dev/null\n[commit]\n\tgpgSign = false\n"
  let head_content = "ref: refs/heads/choir-control\n"
  if !@sys.create_dir_all(config.control_root + "/refs/heads") ||
    !@sys.create_dir_all(config.control_root + "/objects/info") ||
    !@sys.create_dir_all(config.control_root + "/objects/pack") ||
    @sys.realpath_native(config.control_root) != Some(config.control_root) {
    return Err(
      @types.ChoirError::git_error("sterile Git control root creation failed"),
    )
  }
  if @sys.path_exists(config_path) {
    if @sys.read_file(config_path) != config_content {
      return Err(
        @types.ChoirError::git_error("sterile Git control config is invalid"),
      )
    }
  } else if !@sys.write_file_sync(config_path, config_content) {
    return Err(
      @types.ChoirError::git_error("sterile Git control config creation failed"),
    )
  }
  if @sys.path_exists(head_path) {
    if @sys.read_file(head_path) != head_content {
      return Err(
        @types.ChoirError::git_error("sterile Git control HEAD is invalid"),
      )
    }
  } else if !@sys.write_file_sync(head_path, head_content) {
    return Err(
      @types.ChoirError::git_error("sterile Git control HEAD creation failed"),
    )
  }
  Ok(())
}

///|
fn native_git_process_spec(
  config : @git_integration.NativeGitIntegrationConfig,
  command : @git_integration.NativeGitIntegrationCommand,
) -> NativeGitProcessSpec {
  match command {
    NativeGitReadCommitTree(oid) =>
      {
        arguments: ["show", "-s", "--format=%T", "--no-show-signature", oid.0],
        stdin: "",
        environment: native_git_integration_environment(config, true, false),
        working_directory: config.control_root,
      }
    NativeGitReadCommitEpoch(oid) =>
      {
        arguments: ["show", "-s", "--format=%ct", "--no-show-signature", oid.0],
        stdin: "",
        environment: native_git_integration_environment(config, true, false),
        working_directory: config.control_root,
      }
    NativeGitReadCommitParents(oid) =>
      {
        arguments: ["show", "-s", "--format=%P", "--no-show-signature", oid.0],
        stdin: "",
        environment: native_git_integration_environment(config, true, false),
        working_directory: config.control_root,
      }
    NativeGitReadMergeBase(left, right) =>
      {
        arguments: ["merge-base", left.0, right.0],
        stdin: "",
        environment: native_git_integration_environment(config, true, false),
        working_directory: config.control_root,
      }
    NativeGitMergeTree(head, candidate) =>
      {
        arguments: [
          "merge-tree",
          "--write-tree",
          "--no-messages",
          "--name-only",
          "-z",
          head.0,
          candidate.0,
        ],
        stdin: "",
        environment: native_git_integration_environment(config, true, false),
        working_directory: config.control_root,
      }
    NativeGitCreatePromotion(tree, head, candidate, message, commit_epoch) =>
      {
        arguments: [
          "commit-tree",
          tree.0,
          "-p",
          head.0,
          "-p",
          candidate.0,
          "-m",
          message,
        ],
        stdin: "",
        environment: native_git_integration_environment(
          config,
          true,
          true,
          commit_epoch~,
        ),
        working_directory: config.control_root,
      }
    NativeGitReadRef(reference) =>
      {
        arguments: ["rev-parse", "--verify", "--quiet", reference],
        stdin: "",
        environment: native_git_integration_environment(config, false, false),
        working_directory: config.repository_root,
      }
    NativeGitApplyRefs(goal_ref, witness_ref, expected, promotion) =>
      {
        arguments: ["update-ref", "--stdin"],
        stdin: "start\n" +
        "update " +
        goal_ref +
        " " +
        promotion.0 +
        " " +
        expected.0 +
        "\n" +
        "create " +
        witness_ref +
        " " +
        promotion.0 +
        "\n" +
        "prepare\ncommit\n",
        environment: native_git_integration_environment(config, false, false),
        working_directory: config.repository_root,
      }
  }
}

///|
async fn capture_native_git_process(
  config : @git_integration.NativeGitIntegrationConfig,
  command : @git_integration.NativeGitIntegrationCommand,
) -> Result[@git_integration.NativeGitCapture, @types.ChoirError] {
  let git = match @process_host.resolve_executable_in_path("git") {
    Some(path) => path
    None =>
      return Err(@types.ChoirError::git_error("git executable is unavailable"))
  }
  match ensure_native_git_integration_control(config) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if @sys.realpath_native(config.repository_root) !=
    Some(config.repository_root) ||
    @sys.realpath_native(config.git_directory) != Some(config.git_directory) ||
    @sys.realpath_native(config.object_directory) !=
    Some(config.object_directory) {
    return Err(
      @types.ChoirError::git_error(
        "native Git integration paths are not canonical",
      ),
    )
  }
  let spec = native_git_process_spec(config, command)
  @process_host.abort_if_hermetic_test_exec(
    @process_host.command_to_shell_string({
      program: git,
      args: spec.arguments,
      workdir: Some(spec.working_directory),
    }),
  )
  let (stdin_read, stdin_write) = @process.write_to_process() catch {
    _ => return Err(@types.ChoirError::transport_error("Git stdin pipe failed"))
  }
  let (stdout_read, stdout_write) = @process.read_from_process() catch {
    _ => {
      stdin_write.close()
      return Err(@types.ChoirError::transport_error("Git output pipe failed"))
    }
  }
  let pid = @process.spawn_orphan(
    git,
    spec.arguments,
    extra_env=spec.environment,
    inherit_env=false,
    stdin=stdin_read,
    stdout=stdout_write,
    stderr=stdout_write,
    cwd=spec.working_directory,
  ) catch {
    _ => {
      stdin_write.close()
      stdout_read.close()
      return Err(@types.ChoirError::transport_error("Git process failed"))
    }
  }
  if spec.stdin != "" {
    ignore(stdin_write.write(spec.stdin) catch { _ => () })
  }
  stdin_write.close()
  let (output, _) = @process_host.drain_process_stdout(
    stdout_read, @process_host.capture_max_bytes,
  )
  let exit_code = @process.wait_pid(pid) catch {
    _ => return Err(@types.ChoirError::transport_error("Git wait failed"))
  }
  Ok({ exit_code, output })
}

///|
pub fn native_git_integration_adapters() -> @git_integration.NativeGitIntegrationAdapters {
  {
    is_nfc: @process_host.native_path_is_nfc,
    capture: capture_native_git_process,
  }
}

///|
test "promotion synthesis ignores repository and ambient Git configuration" {
  let config : @git_integration.NativeGitIntegrationConfig = {
    repository_root: "/repo",
    git_directory: "/repo/.git",
    object_directory: "/repo/.git/objects",
    control_root: "/tmp/choir-integration-control",
    goal_ref: "refs/heads/choir/goal",
  }
  let object_spec = native_git_process_spec(
    config,
    @git_integration.NativeGitMergeTree(
      @control.GitOid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
      @control.GitOid("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
    ),
  )
  assert_eq(object_spec.environment["GIT_DIR"], config.control_root)
  assert_eq(
    object_spec.environment["GIT_OBJECT_DIRECTORY"],
    config.object_directory,
  )
  assert_eq(object_spec.environment["GIT_CONFIG_GLOBAL"], "/dev/null")
  assert_eq(object_spec.environment["GIT_CONFIG_NOSYSTEM"], "1")
  assert_eq(object_spec.environment["GIT_ATTR_NOSYSTEM"], "1")
  assert_eq(object_spec.environment["HOME"], "/nonexistent")
  let ref_spec = native_git_process_spec(
    config,
    @git_integration.NativeGitReadRef(config.goal_ref),
  )
  assert_eq(ref_spec.environment["GIT_DIR"], config.git_directory)
  assert_eq(native_git_commit_date(1700000000L), "@1700000000 +0000")
}

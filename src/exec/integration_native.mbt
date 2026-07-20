///|
pub(all) enum NativeGitIntegrationCommand {
  NativeGitReadCommitTree(@control.GitOid)
  NativeGitReadCommitParents(@control.GitOid)
  NativeGitReadMergeBase(@control.GitOid, @control.GitOid)
  NativeGitMergeTree(@control.GitOid, @control.GitOid)
  NativeGitCreatePromotion(
    @control.GitOid,
    @control.GitOid,
    @control.GitOid,
    String
  )
  NativeGitReadRef(String)
  NativeGitApplyRefs(String, String, @control.GitOid, @control.GitOid)
} derive(Debug, Eq)

///|
pub(all) struct NativeGitCapture {
  exit_code : Int
  output : String
} derive(Debug, Eq)

///|
pub(all) struct NativeGitIntegrationConfig {
  repository_root : String
  git_directory : String
  object_directory : String
  control_root : String
  goal_ref : String
} derive(Debug, Eq)

///|
pub(all) struct NativeGitIntegrationAdapters {
  capture : async (NativeGitIntegrationConfig, NativeGitIntegrationCommand) -> Result[
    NativeGitCapture,
    @types.ChoirError,
  ]
}

///|
priv struct NativeGitProcessSpec {
  arguments : Array[String]
  stdin : String
  environment : Map[String, String]
  working_directory : String
}

///|
fn git_error(message : String) -> @types.ChoirError {
  @types.ChoirError::git_error(message)
}

///|
fn valid_hex_oid_text(value : String) -> Bool {
  if value.length() != 40 && value.length() != 64 {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    if !((code >= '0'.to_int() && code <= '9'.to_int()) ||
      (code >= 'a'.to_int() && code <= 'f'.to_int())) {
      return false
    }
  }
  true
}

///|
fn parsed_git_oid(output : String) -> @control.GitOid? {
  let value = output.trim().to_owned()
  if valid_hex_oid_text(value) {
    Some(@control.GitOid(value))
  } else {
    None
  }
}

///|
fn parsed_merge_tree_oid(output : String) -> @control.GitOid? {
  let fields = output.split("\u{00}").to_array()
  if fields.length() == 0 {
    None
  } else {
    parsed_git_oid(fields[0].to_owned())
  }
}

///|
fn valid_git_identity(value : String) -> Bool {
  if value == "" || value.length() > 160 {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    let valid = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '-'.to_int() ||
      code == '_'.to_int() ||
      code == '.'.to_int() ||
      code == ':'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
fn valid_git_ref(value : String, required_prefix : String) -> Bool {
  if !value.has_prefix(required_prefix) ||
    value.length() <= required_prefix.length() ||
    value.has_suffix("/") ||
    value.contains("..") ||
    value.contains("@{") ||
    value.contains("//") ||
    value.has_suffix(".lock") {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    let valid = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '/'.to_int() ||
      code == '-'.to_int() ||
      code == '_'.to_int() ||
      code == '.'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
fn validate_native_git_paths(
  config : NativeGitIntegrationConfig,
) -> Result[Unit, @types.ChoirError] {
  if !config.repository_root.has_prefix("/") ||
    !config.git_directory.has_prefix("/") ||
    !config.object_directory.has_prefix("/") ||
    !config.object_directory.has_suffix("/objects") ||
    !config.control_root.has_prefix("/") ||
    config.repository_root.contains("\n") ||
    config.git_directory.contains("\n") ||
    config.object_directory.contains("\n") ||
    config.control_root.contains("\n") ||
    config.repository_root.contains("/../") ||
    config.git_directory.contains("/../") ||
    config.object_directory.contains("/../") ||
    config.control_root.contains("/../") ||
    !valid_git_ref(config.goal_ref, "refs/heads/") {
    return Err(
      @types.ChoirError::validation_error(
        "native Git integration path is invalid",
      ),
    )
  }
  Ok(())
}

///|
fn validate_native_git_config(
  config : NativeGitIntegrationConfig,
  intent : @control.IntegrationIntent,
) -> Result[Unit, @types.ChoirError] {
  match validate_native_git_paths(config) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !valid_git_ref(intent.git_witness_ref, "refs/choir/witness/") ||
    !valid_git_identity(intent.id.0) ||
    !valid_git_identity(intent.goal_id.0) ||
    !valid_git_identity(intent.part_id.0) ||
    !valid_hex_oid_text(intent.expected_goal_head_oid.0) ||
    !valid_hex_oid_text(intent.candidate_commit_oid.0) ||
    !valid_hex_oid_text(intent.candidate_tree_oid.0) ||
    !valid_hex_oid_text(intent.promotion_metadata_digest.0) {
    return Err(
      @types.ChoirError::validation_error(
        "native Git integration identity or path is invalid",
      ),
    )
  }
  Ok(())
}

///|
fn promotion_message(intent : @control.IntegrationIntent) -> String {
  "choir: promote Part " +
  intent.part_id.0 +
  "\n\nGoal: " +
  intent.goal_id.0 +
  "\nIntent: " +
  intent.id.0 +
  "\nMetadata: " +
  intent.promotion_metadata_digest.0
}

///|
fn native_git_environment(commit : Bool) -> Map[String, String] {
  let environment : Map[String, String] = {
    "PATH": "/usr/bin:/bin",
    "HOME": "/nonexistent",
    "LC_ALL": "C",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_TERMINAL_PROMPT": "0",
  }
  if commit {
    environment["GIT_AUTHOR_NAME"] = "Choir"
    environment["GIT_AUTHOR_EMAIL"] = "choir@localhost"
    environment["GIT_AUTHOR_DATE"] = "@0 +0000"
    environment["GIT_COMMITTER_NAME"] = "Choir"
    environment["GIT_COMMITTER_EMAIL"] = "choir@localhost"
    environment["GIT_COMMITTER_DATE"] = "@0 +0000"
  }
  environment
}

///|
fn native_git_integration_environment(
  config : NativeGitIntegrationConfig,
  object_access : Bool,
  commit : Bool,
) -> Map[String, String] {
  let environment = native_git_environment(commit)
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
  config : NativeGitIntegrationConfig,
) -> Result[Unit, @types.ChoirError] {
  let config_path = config.control_root + "/config"
  let head_path = config.control_root + "/HEAD"
  let config_content = "[core]\n\trepositoryformatversion = 0\n\tbare = true\n\thooksPath = /dev/null\n[commit]\n\tgpgSign = false\n"
  let head_content = "ref: refs/heads/choir-control\n"
  if !@sys.create_dir_all(config.control_root + "/refs/heads") ||
    !@sys.create_dir_all(config.control_root + "/objects/info") ||
    !@sys.create_dir_all(config.control_root + "/objects/pack") ||
    @sys.realpath_native(config.control_root) != Some(config.control_root) {
    return Err(git_error("sterile Git control root creation failed"))
  }
  if @sys.path_exists(config_path) {
    if @sys.read_file(config_path) != config_content {
      return Err(git_error("sterile Git control config is invalid"))
    }
  } else if !@sys.write_file_sync(config_path, config_content) {
    return Err(git_error("sterile Git control config creation failed"))
  }
  if @sys.path_exists(head_path) {
    if @sys.read_file(head_path) != head_content {
      return Err(git_error("sterile Git control HEAD is invalid"))
    }
  } else if !@sys.write_file_sync(head_path, head_content) {
    return Err(git_error("sterile Git control HEAD creation failed"))
  }
  Ok(())
}

///|
fn native_git_process_spec(
  config : NativeGitIntegrationConfig,
  command : NativeGitIntegrationCommand,
) -> NativeGitProcessSpec {
  match command {
    NativeGitReadCommitTree(oid) =>
      {
        arguments: ["show", "-s", "--format=%T", "--no-show-signature", oid.0],
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
    NativeGitCreatePromotion(tree, head, candidate, message) =>
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
        environment: native_git_integration_environment(config, true, true),
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
fn parsed_conflicting_paths(
  output : String,
) -> Result[Array[@control.RepoPath], @types.ChoirError] {
  let fields = output.split("\u{00}").to_array()
  if fields.length() < 2 || parsed_git_oid(fields[0].to_owned()) is None {
    return Err(git_error("merge-tree returned invalid conflict evidence"))
  }
  let paths : Array[@control.RepoPath] = []
  for index = 1; index < fields.length(); index = index + 1 {
    let value = fields[index].to_owned()
    if value == "" {
      continue
    }
    let path = @control.RepoPath(value)
    match @control.validate_repo_path(path, native_path_is_nfc) {
      Ok(_) => paths.push(path)
      Err(_) => return Err(git_error("merge-tree returned an invalid path"))
    }
  }
  if paths.length() == 0 {
    Err(git_error("merge-tree conflict has no paths"))
  } else {
    Ok(paths)
  }
}

///|
fn integration_conflict(
  intent : @control.IntegrationIntent,
  head_tree : @control.GitOid,
  merge_base : @control.GitOid,
  paths : Array[@control.RepoPath],
  raw_evidence : String,
) -> @control.IntegrationConflict {
  let evidence_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.integration-conflict-evidence.v1\u{00}" +
      [
        intent.id.to_json(),
        intent.candidate_id.to_json(),
        intent.candidate_commit_oid.to_json(),
        intent.expected_goal_head_oid.to_json(),
        head_tree.to_json(),
        merge_base.to_json(),
        paths.to_json(),
        raw_evidence.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
  {
    id: @control.IntegrationConflictId(
      "conflict-" + @storage.digest_text(evidence_digest),
    ),
    intent_id: intent.id,
    candidate_id: intent.candidate_id,
    candidate_commit_oid: intent.candidate_commit_oid,
    expected_goal_head_oid: intent.expected_goal_head_oid,
    expected_goal_head_tree_oid: head_tree,
    merge_base_oid: merge_base,
    conflicting_paths: paths,
    evidence_digest,
  }
}

///|
async fn capture_native_git_process(
  config : NativeGitIntegrationConfig,
  command : NativeGitIntegrationCommand,
) -> Result[NativeGitCapture, @types.ChoirError] {
  let git = match resolve_executable_in_path("git") {
    Some(path) => path
    None => return Err(git_error("git executable is unavailable"))
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
    return Err(git_error("native Git integration paths are not canonical"))
  }
  let spec = native_git_process_spec(config, command)
  abort_if_hermetic_test_exec(
    command_to_shell_string({
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
  let (output, _) = drain_process_stdout(stdout_read, capture_max_bytes)
  let exit_code = @process.wait_pid(pid) catch {
    _ => return Err(@types.ChoirError::transport_error("Git wait failed"))
  }
  Ok({ exit_code, output })
}

///|
pub fn native_git_integration_adapters() -> NativeGitIntegrationAdapters {
  { capture: capture_native_git_process }
}

///|
async fn read_commit_tree(
  config : NativeGitIntegrationConfig,
  oid : @control.GitOid,
  adapters : NativeGitIntegrationAdapters,
) -> Result[@control.GitOid, @types.ChoirError] {
  let capture = match (adapters.capture)(config, NativeGitReadCommitTree(oid)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if capture.exit_code != 0 {
    return Err(git_error("required commit is absent or unreadable"))
  }
  match parsed_git_oid(capture.output) {
    Some(value) => Ok(value)
    None => Err(git_error("Git returned an invalid tree identity"))
  }
}

///|
pub async fn generate_native_promotion(
  config : NativeGitIntegrationConfig,
  intent : @control.IntegrationIntent,
  adapters : NativeGitIntegrationAdapters,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  match validate_native_git_config(config, intent) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if intent.lifecycle != @control.IntegrationIntentLifecycle::IntegrationPlanned ||
    intent.strategy != @control.PromotionStrategy::NoFastForwardThreeWayV1 {
    return Err(git_error("promotion intent is not ready for generation"))
  }
  let head_tree = match
    read_commit_tree(config, intent.expected_goal_head_oid, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if head_tree.0 == "" {
    return Err(git_error("goal head tree is unavailable"))
  }
  let candidate_tree = match
    read_commit_tree(config, intent.candidate_commit_oid, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if candidate_tree != intent.candidate_tree_oid {
    return Err(
      git_error("candidate tree does not match the integration intent"),
    )
  }
  let merged = match
    (adapters.capture)(
      config,
      NativeGitMergeTree(
        intent.expected_goal_head_oid,
        intent.candidate_commit_oid,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if merged.exit_code != 0 {
    let paths = match parsed_conflicting_paths(merged.output) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let base = match
      (adapters.capture)(
        config,
        NativeGitReadMergeBase(
          intent.expected_goal_head_oid,
          intent.candidate_commit_oid,
        ),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let merge_base = match parsed_git_oid(base.output) {
      Some(value) if base.exit_code == 0 => value
      _ => return Err(git_error("Git merge base is unavailable"))
    }
    return Ok(
      @workflow.PartEffectObservation::PromotionConflictObserved(
        integration_conflict(
          intent, head_tree, merge_base, paths, merged.output,
        ),
      ),
    )
  }
  let promotion_tree = match parsed_merge_tree_oid(merged.output) {
    Some(value) => value
    None =>
      return Err(git_error("merge-tree returned an invalid tree identity"))
  }
  let committed = match
    (adapters.capture)(
      config,
      NativeGitCreatePromotion(
        promotion_tree,
        intent.expected_goal_head_oid,
        intent.candidate_commit_oid,
        promotion_message(intent),
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if committed.exit_code != 0 {
    return Err(git_error("promotion commit creation failed"))
  }
  let promotion_oid = match parsed_git_oid(committed.output) {
    Some(value) => value
    None =>
      return Err(git_error("commit-tree returned an invalid commit identity"))
  }
  let observed_tree = match read_commit_tree(config, promotion_oid, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if observed_tree != promotion_tree {
    return Err(git_error("promotion tree witness does not match"))
  }
  let parents = match
    (adapters.capture)(config, NativeGitReadCommitParents(promotion_oid)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let expected_parents = intent.expected_goal_head_oid.0 +
    " " +
    intent.candidate_commit_oid.0
  if parents.exit_code != 0 ||
    parents.output.trim().to_owned() != expected_parents {
    return Err(git_error("promotion parent witness does not match"))
  }
  Ok(
    @workflow.PartEffectObservation::PromotionGenerated({
      intent_id: intent.id,
      commit_oid: promotion_oid,
      tree_oid: promotion_tree,
      first_parent_oid: intent.expected_goal_head_oid,
      second_parent_oid: intent.candidate_commit_oid,
    }),
  )
}

///|
async fn read_ref(
  config : NativeGitIntegrationConfig,
  reference : String,
  adapters : NativeGitIntegrationAdapters,
) -> Result[@control.GitOid?, @types.ChoirError] {
  let capture = match (adapters.capture)(config, NativeGitReadRef(reference)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if capture.exit_code == 1 {
    return Ok(None)
  }
  if capture.exit_code != 0 {
    return Err(git_error("Git ref observation failed"))
  }
  match parsed_git_oid(capture.output) {
    Some(value) => Ok(Some(value))
    None => Err(git_error("Git ref has an invalid object identity"))
  }
}

///|
pub async fn read_native_goal_head(
  config : NativeGitIntegrationConfig,
  adapters : NativeGitIntegrationAdapters,
) -> Result[@control.GitOid, @types.ChoirError] {
  match validate_native_git_paths(config) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match read_ref(config, config.goal_ref, adapters) {
    Ok(Some(value)) => Ok(value)
    Ok(None) => Err(git_error("Goal ref is absent"))
    Err(error) => Err(error)
  }
}

///|
pub async fn observe_native_integration(
  config : NativeGitIntegrationConfig,
  intent : @control.IntegrationIntent,
  promotion : @control.PromotionCommit,
  adapters : NativeGitIntegrationAdapters,
) -> Result[@control.IntegrationWitnessObservation, @types.ChoirError] {
  match validate_native_git_config(config, intent) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if promotion.intent_id != intent.id ||
    promotion.first_parent_oid != intent.expected_goal_head_oid ||
    promotion.second_parent_oid != intent.candidate_commit_oid {
    return Ok(
      @control.IntegrationWitnessObservation::IntegrationWitnessIntegrityError,
    )
  }
  let goal = match read_ref(config, config.goal_ref, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let witness = match read_ref(config, intent.git_witness_ref, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match (goal, witness) {
    (Some(goal_oid), Some(witness_oid)) if goal_oid == promotion.commit_oid &&
      witness_oid == promotion.commit_oid =>
      Ok(
        @control.IntegrationWitnessObservation::IntegrationWitnessApplied(
          witness_oid, goal_oid,
        ),
      )
    (Some(goal_oid), None) if goal_oid == intent.expected_goal_head_oid =>
      Ok(
        @control.IntegrationWitnessObservation::IntegrationWitnessNotApplied(
          goal_oid,
        ),
      )
    (None, _) =>
      Ok(
        @control.IntegrationWitnessObservation::IntegrationWitnessIntegrityError,
      )
    _ => Ok(@control.IntegrationWitnessObservation::IntegrationWitnessDiverged)
  }
}

///|
pub async fn apply_native_integration(
  config : NativeGitIntegrationConfig,
  intent : @control.IntegrationIntent,
  promotion : @control.PromotionCommit,
  adapters : NativeGitIntegrationAdapters,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  match validate_native_git_config(config, intent) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if intent.lifecycle !=
    @control.IntegrationIntentLifecycle::IntegrationAuthorized ||
    promotion.intent_id != intent.id {
    return Err(git_error("integration intent is not authorized"))
  }
  let applied = match
    (adapters.capture)(
      config,
      NativeGitApplyRefs(
        config.goal_ref,
        intent.git_witness_ref,
        intent.expected_goal_head_oid,
        promotion.commit_oid,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let witness = match
    observe_native_integration(config, intent, promotion, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if applied.exit_code != 0 &&
    witness
    is @control.IntegrationWitnessObservation::IntegrationWitnessNotApplied(_) {
    return Err(git_error("atomic integration ref update was rejected"))
  }
  Ok(@workflow.PartEffectObservation::IntegrationWitnessObserved(witness))
}

///|
pub async fn execute_native_git_effect(
  config : NativeGitIntegrationConfig,
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
  adapters : NativeGitIntegrationAdapters,
) -> Result[@workflow.PartEffectObservation, @types.ChoirError] {
  match intent.kind {
    @workflow.PartEffectKind::GeneratePromotion(integration) =>
      generate_native_promotion(config, integration, adapters)
    @workflow.PartEffectKind::ApplyIntegration(intent_id, promotion) => {
      let integration = match snapshot.integration_intent {
        Some(value) if value.id == intent_id => value
        _ => return Err(git_error("integration effect has no matching intent"))
      }
      apply_native_integration(config, integration, promotion, adapters)
    }
    _ => Err(git_error("effect is not a native Git integration operation"))
  }
}

///|
pub async fn reconcile_native_git_effect(
  config : NativeGitIntegrationConfig,
  snapshot : @workflow.PartWorkflowSnapshot,
  intent : @workflow.PartEffectIntent,
  adapters : NativeGitIntegrationAdapters,
) -> Result[@workflow.PartEffectRecovery, @types.ChoirError] {
  match intent.kind {
    @workflow.PartEffectKind::GeneratePromotion(_) =>
      Ok(@workflow.PartEffectRecovery::ExactEffectRetryAuthorized)
    @workflow.PartEffectKind::ApplyIntegration(intent_id, promotion) => {
      let integration = match snapshot.integration_intent {
        Some(value) if value.id == intent_id => value
        _ => return Err(git_error("integration effect has no matching intent"))
      }
      let witness = match
        observe_native_integration(config, integration, promotion, adapters) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(
        @workflow.PartEffectRecovery::EffectObservationRecovered(
          @workflow.PartEffectObservation::IntegrationWitnessObserved(witness),
        ),
      )
    }
    _ => Err(git_error("effect is not a native Git integration operation"))
  }
}

///|
test "promotion synthesis ignores repository and ambient Git configuration" {
  let config : NativeGitIntegrationConfig = {
    repository_root: "/repo",
    git_directory: "/repo/.git",
    object_directory: "/repo/.git/objects",
    control_root: "/tmp/choir-integration-control",
    goal_ref: "refs/heads/choir/goal",
  }
  let object_spec = native_git_process_spec(
    config,
    NativeGitMergeTree(
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
    NativeGitReadRef(config.goal_ref),
  )
  assert_eq(ref_spec.environment["GIT_DIR"], config.git_directory)
}

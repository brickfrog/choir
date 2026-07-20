///|
pub(all) enum NativeGitIntegrationCommand {
  NativeGitReadCommitTree(@control.GitOid)
  NativeGitReadCommitParents(@control.GitOid)
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
  goal_ref : String
} derive(Debug, Eq)

///|
pub(all) struct NativeGitIntegrationAdapters {
  capture : async (String, NativeGitIntegrationCommand) -> Result[
    NativeGitCapture,
    @types.ChoirError,
  ]
}

///|
priv struct NativeGitProcessSpec {
  arguments : Array[String]
  stdin : String
  environment : Map[String, String]
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
fn validate_native_git_config(
  config : NativeGitIntegrationConfig,
  intent : @control.IntegrationIntent,
) -> Result[Unit, @types.ChoirError] {
  if !config.repository_root.has_prefix("/") ||
    config.repository_root.contains("\n") ||
    !valid_git_ref(config.goal_ref, "refs/heads/") ||
    !valid_git_ref(intent.git_witness_ref, "refs/choir/witness/") ||
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
fn native_git_process_spec(
  command : NativeGitIntegrationCommand,
) -> NativeGitProcessSpec {
  match command {
    NativeGitReadCommitTree(oid) =>
      {
        arguments: ["show", "-s", "--format=%T", "--no-show-signature", oid.0],
        stdin: "",
        environment: native_git_environment(false),
      }
    NativeGitReadCommitParents(oid) =>
      {
        arguments: ["show", "-s", "--format=%P", "--no-show-signature", oid.0],
        stdin: "",
        environment: native_git_environment(false),
      }
    NativeGitMergeTree(head, candidate) =>
      {
        arguments: [
          "merge-tree",
          "--write-tree",
          "--no-messages",
          head.0,
          candidate.0,
        ],
        stdin: "",
        environment: native_git_environment(false),
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
        environment: native_git_environment(true),
      }
    NativeGitReadRef(reference) =>
      {
        arguments: ["rev-parse", "--verify", "--quiet", reference],
        stdin: "",
        environment: native_git_environment(false),
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
        environment: native_git_environment(false),
      }
  }
}

///|
async fn capture_native_git_process(
  repository_root : String,
  command : NativeGitIntegrationCommand,
) -> Result[NativeGitCapture, @types.ChoirError] {
  let git = match resolve_executable_in_path("git") {
    Some(path) => path
    None => return Err(git_error("git executable is unavailable"))
  }
  let spec = native_git_process_spec(command)
  abort_if_hermetic_test_exec(
    command_to_shell_string({
      program: git,
      args: spec.arguments,
      workdir: Some(repository_root),
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
    cwd=repository_root,
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
  let capture = match
    (adapters.capture)(config.repository_root, NativeGitReadCommitTree(oid)) {
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
      config.repository_root,
      NativeGitMergeTree(
        intent.expected_goal_head_oid,
        intent.candidate_commit_oid,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if merged.exit_code != 0 {
    return Ok(@workflow.PartEffectObservation::PromotionConflictObserved)
  }
  let promotion_tree = match parsed_git_oid(merged.output) {
    Some(value) => value
    None =>
      return Err(git_error("merge-tree returned an invalid tree identity"))
  }
  let committed = match
    (adapters.capture)(
      config.repository_root,
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
    (adapters.capture)(
      config.repository_root,
      NativeGitReadCommitParents(promotion_oid),
    ) {
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
  let capture = match
    (adapters.capture)(config.repository_root, NativeGitReadRef(reference)) {
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
      config.repository_root,
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

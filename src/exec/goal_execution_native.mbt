///|
priv struct NativeGoalRepositoryIdentity {
  root : String
  git_directory : String
  object_directory : String
}

///|
pub(all) struct NativeGoalPurgeReport {
  runtime_roots_removed : Int
  git_refs_removed : Int
} derive(Debug, Eq)

///|
pub(all) struct NativeGoalControlStateResetReport {
  source_claims_released : Int
  runtime_roots_removed : Int
  git_refs_removed : Int
} derive(Debug, Eq)

///|
pub(all) enum NativeGoalControlStatePreparation {
  NativeGoalControlStateCurrent
  NativeGoalControlStateInitialized
  NativeGoalControlStateReset(NativeGoalControlStateResetReport)
} derive(Debug, Eq)

///|
priv struct NativeOrphanedGoalSourceClaim {
  part_id : @control.PartId
  claimant : String
  goal_id : @control.GoalId
}

///|
let native_goal_control_state_generation : String = "choir-control-state-v3"

///|
priv struct NativeGoalPartRuntime {
  snapshot : @workflow.PartWorkflowSnapshot
  runtime : NativePartEffectRuntime
  counts : NativePartDispatchCounts
  surface : @control.ProviderSurfaceId
}

///|
fn native_goal_execution_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::workspace_error("native Goal execution: " + detail)
}

///|
fn native_goal_cancellation_observed(
  loaded : Result[@workflow.StoredGoalExecutionRecord?, @types.ChoirError],
  is_cutoff : (@workflow.GoalExecutionRecord) -> Bool,
) -> Bool {
  match loaded {
    Ok(Some(current)) => is_cutoff(current.record)
    Ok(None) => true
    // The process collector polls again. A read failure is not affirmative
    // evidence that choird installed a cancellation cutoff.
    Err(_) => false
  }
}

///|
test "Goal cancellation requires an affirmative durable observation" {
  let failed : Result[@workflow.StoredGoalExecutionRecord?, @types.ChoirError] = Err(
    @types.ChoirError::workspace_error("transient read failure"),
  )
  assert_false(native_goal_cancellation_observed(failed, fn(_) { true }))
  let absent : Result[@workflow.StoredGoalExecutionRecord?, @types.ChoirError] = Ok(
    None,
  )
  assert_true(native_goal_cancellation_observed(absent, fn(_) { false }))
}

///|
pub fn native_goal_repository(
  project_dir : String,
) -> @workflow.PartWorkflowRepository {
  {
    state_store: { path: project_dir + "/.choir/state/control/workflow.db" },
    artifact_store: { root: project_dir + "/.choir/state/control/artifacts" },
    max_snapshot_bytes: 4 * 1024 * 1024,
  }
}

///|
/// Fencing epoch of this process generation. `choir serve` mints it under the
/// instance lock; `choir run-goals` observes the value serve minted. Records
/// created or adopted by this generation carry it, which is what lets the
/// state store's stale-fence gate reject writes from surviving processes of
/// an older generation.
let native_goal_fencing_epoch_state : Ref[Int64] = Ref(1L)

///|
pub fn current_native_goal_fencing_epoch() -> @control.FencingEpoch {
  @control.FencingEpoch(native_goal_fencing_epoch_state.val)
}

///|
/// Increment and adopt the durable generation epoch. Only the daemon may
/// mint, and only while holding the single-instance lock.
pub fn mint_native_goal_fencing_epoch(
  project_dir : String,
) -> Result[Int64, @types.ChoirError] {
  let store = native_goal_repository(project_dir).state_store
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let epoch = state_store_mint_epoch_ffi(path, path_len)
  if epoch <= 0L {
    return Err(
      native_goal_execution_error("fencing generation could not be minted"),
    )
  }
  native_goal_fencing_epoch_state.val = epoch
  Ok(epoch)
}

///|
/// Adopt the generation epoch the daemon minted without incrementing it.
/// The goal worker runs in a separate process of the same generation and
/// must share the daemon's epoch, or the two would fence each other off.
pub fn observe_native_goal_fencing_epoch(
  project_dir : String,
) -> Result[Int64, @types.ChoirError] {
  let store = native_goal_repository(project_dir).state_store
  let (path, path_len) = exec_string_to_null_terminated_bytes(store.path)
  let epoch = state_store_read_epoch_ffi(path, path_len)
  if epoch <= 0L {
    return Err(
      native_goal_execution_error(
        "fencing generation is absent; start the worker through choird",
      ),
    )
  }
  native_goal_fencing_epoch_state.val = epoch
  Ok(epoch)
}

///|
async fn native_goal_git_value(
  project_dir : String,
  arguments : Array[String],
) -> Result[String, @types.ChoirError] {
  let capture = match capture_native_goal_git(project_dir, arguments) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let value = capture.output.trim().to_owned()
  if capture.exit_code != 0 || value == "" {
    Err(native_goal_execution_error("Git observation failed"))
  } else {
    Ok(value)
  }
}

///|
async fn capture_native_goal_git(
  repository_root : String,
  arguments : Array[String],
) -> Result[NativeGitCapture, @types.ChoirError] {
  let environment = native_git_environment(false)
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  environment["GIT_ATTR_NOSYSTEM"] = "1"
  environment["XDG_CONFIG_HOME"] = "/nonexistent"
  environment["GIT_TERMINAL_PROMPT"] = "0"
  let captured = @process.collect_output_merged(
    "/usr/bin/git",
    arguments,
    extra_env=environment,
    inherit_env=false,
    cwd=repository_root,
  ) catch {
    error =>
      return Err(native_goal_execution_error("Git process failed: \{error}"))
  }
  let output = captured.1.text() catch {
    _ => return Err(native_goal_execution_error("Git output is not UTF-8"))
  }
  Ok({ exit_code: captured.0, output })
}

///|
async fn discover_native_goal_repository(
  project_dir : String,
  record : @workflow.GoalExecutionRecord,
) -> Result[NativeGoalRepositoryIdentity, @types.ChoirError] {
  let root = match
    native_goal_git_value(project_dir, ["rev-parse", "--show-toplevel"]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let canonical_root = match @sys.realpath_native(root) {
    Some(value) => value
    None =>
      return Err(native_goal_execution_error("repository is not canonical"))
  }
  let expected_repository_id = @workflow.RepositoryId(
    "sha256:" +
    @storage.artifact_digest(
      @utf8.encode("choir.repository.v1\u{00}" + canonical_root),
    ).0,
  )
  if expected_repository_id != record.repository_id {
    return Err(native_goal_execution_error("repository identity changed"))
  }
  let base_commit = match
    native_goal_git_value(canonical_root, [
      "rev-parse",
      "--verify",
      record.base_commit_oid.0 + "^{commit}",
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let base_tree = match
    native_goal_git_value(canonical_root, [
      "show",
      "-s",
      "--format=%T",
      "--no-show-signature",
      record.base_commit_oid.0,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if base_commit != record.base_commit_oid.0 ||
    base_tree != record.base_tree_oid.0 {
    return Err(native_goal_execution_error("base Git identity changed"))
  }
  let git_directory = match
    native_goal_git_value(canonical_root, [
      "rev-parse", "--path-format=absolute", "--absolute-git-dir",
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object_directory = match
    native_goal_git_value(canonical_root, [
      "rev-parse", "--path-format=absolute", "--git-path", "objects",
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @sys.realpath_native(git_directory) != Some(git_directory) ||
    @sys.realpath_native(object_directory) != Some(object_directory) {
    return Err(native_goal_execution_error("Git storage is not canonical"))
  }
  Ok({ root: canonical_root, git_directory, object_directory })
}

///|
fn native_goal_initialization_git_config(
  repository : NativeGoalRepositoryIdentity,
  record : @workflow.GoalExecutionRecord,
) -> NativeGitIntegrationConfig {
  {
    repository_root: repository.root,
    git_directory: repository.git_directory,
    object_directory: repository.object_directory,
    control_root: native_goal_runtime_root(record.repository_id, record.goal.id) +
    "/integration-control",
    goal_ref: record.goal_ref.0,
  }
}

///|
async fn read_native_goal_initialization_ref(
  config : NativeGitIntegrationConfig,
  reference : String,
) -> Result[@control.GitOid?, @types.ChoirError] {
  let adapters = native_git_integration_adapters()
  let captured = match (adapters.capture)(config, NativeGitReadRef(reference)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if captured.exit_code != 0 {
    Ok(None)
  } else {
    let value = captured.output.trim().to_owned()
    if value == "" {
      Err(native_goal_execution_error("Git ref observation was empty"))
    } else {
      Ok(Some(@control.GitOid(value)))
    }
  }
}

///|
async fn observe_native_goal_branch_initialization(
  config : NativeGitIntegrationConfig,
  initialization : @workflow.GoalBranchInitialization,
) -> Result[@workflow.GoalBranchInitObservation, @types.ChoirError] {
  let goal = match
    read_native_goal_initialization_ref(config, initialization.goal_ref.0) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let witness = match
    read_native_goal_initialization_ref(
      config,
      initialization.initialization_witness_ref.0,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match (goal, witness) {
    (None, None) =>
      Ok(@workflow.GoalBranchInitObservation::GoalBranchInitRefsAbsent)
    (Some(goal_oid), Some(witness_oid)) if goal_oid ==
      initialization.captured_base_oid &&
      witness_oid == initialization.captured_base_oid =>
      Ok(@workflow.GoalBranchInitObservation::GoalBranchInitRefsAtBase)
    (Some(goal_oid), None) if goal_oid == initialization.captured_base_oid =>
      Ok(@workflow.GoalBranchInitObservation::GoalBranchInitBranchOnly)
    (None, Some(witness_oid)) if witness_oid == initialization.captured_base_oid =>
      Ok(@workflow.GoalBranchInitObservation::GoalBranchInitWitnessOnly)
    _ => Ok(@workflow.GoalBranchInitObservation::GoalBranchInitRefsDiverged)
  }
}

///|
async fn apply_native_goal_branch_initialization(
  config : NativeGitIntegrationConfig,
  initialization : @workflow.GoalBranchInitialization,
) -> Result[Unit, @types.ChoirError] {
  let zero = if initialization.captured_base_oid.0.length() == 64 {
    @control.GitOid(
      "0000000000000000000000000000000000000000000000000000000000000000",
    )
  } else {
    @control.GitOid("0000000000000000000000000000000000000000")
  }
  let adapters = native_git_integration_adapters()
  let applied = match
    (adapters.capture)(
      config,
      NativeGitApplyRefs(
        initialization.goal_ref.0,
        initialization.initialization_witness_ref.0,
        zero,
        initialization.captured_base_oid,
      ),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if applied.exit_code == 0 {
    Ok(())
  } else {
    Err(native_goal_execution_error("atomic Goal ref initialization failed"))
  }
}

///|
fn native_goal_part_runtime(
  parts : Array[NativeGoalPartRuntime],
  part_id : @control.PartId,
) -> NativeGoalPartRuntime? {
  for part in parts {
    if part.snapshot.part.id == part_id {
      return Some(part)
    }
  }
  None
}

///|
fn native_goal_integration_input(
  snapshot : @workflow.PartWorkflowSnapshot,
  selection : @workflow.DeterministicPromotionSelection,
) -> Result[@workflow.IntegrationPlanInput, @types.ChoirError] {
  let key = @storage.artifact_digest(
      @utf8.encode(
        "choir.native-goal-promotion.v1\u{00}" +
        snapshot.goal.id.0 +
        "\u{00}" +
        snapshot.part.id.0 +
        "\u{00}" +
        selection.candidate_id.0 +
        "\u{00}" +
        selection.expected_goal_head_oid.0,
      ),
    ).0
  Ok({
    lease: {
      id: @control.IntegrationLeaseId("integration-lease-" + key),
      goal_id: snapshot.goal.id,
      fencing_epoch: snapshot.fencing_epoch,
      holder: "choird",
    },
    intent_id: @control.IntegrationIntentId("integration-intent-" + key),
    expected_goal_head_oid: selection.expected_goal_head_oid,
    promotion_metadata_digest: @storage.artifact_digest(
      @utf8.encode("choir.native-goal-promotion-metadata.v1\u{00}" + key),
    ),
    git_witness_ref: "refs/choir/witness/" + key,
  })
}

///|
fn native_goal_conflict_repair_take(
  id : String,
  previous : @control.Take,
  purpose : @control.TakePurpose,
) -> @control.Take {
  {
    id: @control.TakeId(id),
    goal_id: previous.goal_id,
    purpose,
    ordinal: previous.ordinal + 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
}

///|
fn native_goal_conflict_repair_sandbox(
  key : String,
  role : String,
  take : @control.Take,
  previous : @control.SandboxLease,
) -> @control.SandboxLease {
  {
    id: @control.SandboxLeaseId("sandbox-" + key + "-" + role),
    take_id: take.id,
    generation_id: @control.SandboxGenerationId(
      "generation-" + key + "-" + role,
    ),
    capability_profile_digest: previous.capability_profile_digest,
    runtime_policy_digest: previous.runtime_policy_digest,
    lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  }
}

///|
fn native_goal_conflict_repair_session(
  key : String,
  role : String,
  take : @control.Take,
  sandbox : @control.SandboxLease,
  previous : @control.HarnessSession,
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId("session-" + key + "-" + role),
    take_id: take.id,
    sandbox_generation_id: sandbox.generation_id,
    surface: previous.surface,
    effective_surface_manifest_digest: previous.effective_surface_manifest_digest,
    cursor_class: previous.cursor_class,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn plan_native_goal_conflict_repair(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> Result[@workflow.PartConflictRepairDecision, @types.ChoirError] {
  if snapshot.integration_conflicts.length() == 0 {
    return Err(native_goal_execution_error("integration conflict is absent"))
  }
  if snapshot.integration_conflicts.length() >
    @workflow.maximum_part_conflict_repairs() {
    return Ok(
      @workflow.PartConflictRepairDecision::PartConflictRepairLimitReached,
    )
  }
  let conflict = snapshot.integration_conflicts[snapshot.integration_conflicts.length() -
    1]
  let repair_number = snapshot.integration_conflicts.length()
  let identity_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.native-goal-conflict-repair.v1\u{00}" +
      [
        snapshot.task_contract.digest.to_json(),
        conflict.id.to_json(),
        conflict.expected_goal_head_oid.to_json(),
        conflict.expected_goal_head_tree_oid.to_json(),
        repair_number.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
  let key = @storage.digest_text(identity_digest)[:20].to_owned()
  let revision_id = @control.RevisionId("repair-" + key)
  let contract_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.task-contract-conflict-repair.v1\u{00}" +
      [
        revision_id.to_json(),
        snapshot.goal.id.to_json(),
        snapshot.part.id.to_json(),
        (snapshot.task_contract.revision + 1).to_json(),
        conflict.id.to_json(),
        snapshot.task_contract.instruction_artifact.to_json(),
        conflict.expected_goal_head_oid.to_json(),
        conflict.expected_goal_head_tree_oid.to_json(),
        snapshot.task_contract.mutation_declaration.to_json(),
        snapshot.task_contract.verification_specs.to_json(),
        snapshot.task_contract.audit_policy_digest.to_json(),
        snapshot.task_contract.implementation_capability_profile_digest.to_json(),
        snapshot.task_contract.verification_capability_profile_digest.to_json(),
        snapshot.task_contract.audit_capability_profile_digest.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
  let contract : @control.TaskContractRevision = {
    ..snapshot.task_contract,
    id: revision_id,
    revision: snapshot.task_contract.revision + 1,
    digest: contract_digest,
    repair_conflict_id: Some(conflict.id),
    base_commit_oid: conflict.expected_goal_head_oid,
    base_tree_oid: conflict.expected_goal_head_tree_oid,
  }
  let implementation = native_goal_conflict_repair_take(
    "take-" + key + "-implementation",
    snapshot.implementation_take,
    @control.TakePurpose::Implementation(snapshot.part.id, contract.id),
  )
  let verification = native_goal_conflict_repair_take(
    "take-" + key + "-verification",
    snapshot.verification_take,
    @control.TakePurpose::PartVerification(
      snapshot.part.id,
      implementation.id,
      contract.verification_specs[0].digest,
    ),
  )
  let audit = native_goal_conflict_repair_take(
    "take-" + key + "-audit",
    snapshot.audit_take,
    @control.TakePurpose::PartAudit(
      snapshot.part.id,
      implementation.id,
      contract.audit_policy_digest,
    ),
  )
  let implementation_sandbox = native_goal_conflict_repair_sandbox(
    key,
    "implementation",
    implementation,
    snapshot.identities.implementation_sandbox,
  )
  let verification_sandbox = native_goal_conflict_repair_sandbox(
    key,
    "verification",
    verification,
    snapshot.identities.verification_sandbox,
  )
  let audit_sandbox = native_goal_conflict_repair_sandbox(
    key,
    "audit",
    audit,
    snapshot.identities.audit_sandbox,
  )
  @workflow.plan_part_conflict_repair(
    snapshot,
    contract,
    {
      implementation_take: implementation,
      implementation_sandbox,
      implementation_session: native_goal_conflict_repair_session(
        key,
        "implementation",
        implementation,
        implementation_sandbox,
        snapshot.identities.implementation_session,
      ),
      verification_take: verification,
      verification_sandbox,
      audit_take: audit,
      audit_sandbox,
      audit_session: native_goal_conflict_repair_session(
        key,
        "audit",
        audit,
        audit_sandbox,
        snapshot.identities.audit_session,
      ),
    },
    native_path_is_nfc,
  )
}

///|
fn native_goal_runtime_key(
  repository_id : @workflow.RepositoryId,
  goal_id : @control.GoalId,
) -> String {
  @storage.artifact_digest(@utf8.encode(repository_id.0 + "\u{00}" + goal_id.0)).0[:20].to_owned()
}

///|
fn native_goal_runtime_root(
  repository_id : @workflow.RepositoryId,
  goal_id : @control.GoalId,
) -> String {
  "/tmp/choir-take-goal-" + native_goal_runtime_key(repository_id, goal_id)
}

///|
fn native_goal_repository_id(
  project_dir : String,
) -> Result[@workflow.RepositoryId, @types.ChoirError] {
  let root = match @sys.realpath_native(project_dir) {
    Some(value) => value
    None =>
      return Err(native_goal_execution_error("repository is not canonical"))
  }
  Ok(
    @workflow.RepositoryId(
      "sha256:" +
      @storage.artifact_digest(@utf8.encode("choir.repository.v1\u{00}" + root)).0,
    ),
  )
}

///|
fn native_existing_sandbox_generation(
  runtime_root : String,
  generations : Array[@control.SandboxGenerationId],
  path_exists : (String) -> Bool,
) -> @control.SandboxGenerationId? {
  for generation_id in generations {
    if valid_native_effect_token(generation_id.0) &&
      path_exists(
        runtime_root + "/state/sandboxes/" + generation_id.0 + ".json",
      ) {
      return Some(generation_id)
    }
  }
  None
}

///|
test "Goal runtime recovery selects an exact durable sandbox manifest" {
  let observed : Array[String] = []
  let existing = native_existing_sandbox_generation(
    "/tmp/choir-take-goal-test",
    [
      @control.SandboxGenerationId("generation-1"),
      @control.SandboxGenerationId("generation-2"),
    ],
    fn(path) {
      observed.push(path)
      path.has_suffix("/generation-2.json")
    },
  )
  assert_eq(existing, Some(@control.SandboxGenerationId("generation-2")))
  assert_eq(observed.length(), 2)
}

///|
fn native_goal_boxlite_server_config(
  record : @workflow.GoalExecutionRecord,
) -> Result[NativeBoxLiteServerConfig, @types.ChoirError] {
  let runtime_key = native_goal_runtime_key(
    record.repository_id,
    record.goal.id,
  )
  let binary = match native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_dir = match native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    binary,
    runtime_dir,
    root: native_goal_runtime_root(record.repository_id, record.goal.id),
    port: 40000 + @sys.get_pid() % 10000,
    api_key: "choir-goal-" + runtime_key,
  })
}

///|
async fn cleanup_native_goal_runtime(
  record : @workflow.GoalExecutionRecord,
) -> Result[Unit, @types.ChoirError] {
  cleanup_native_goal_runtime_identity(record.repository_id, record.goal.id)
}

///|
async fn cleanup_native_goal_runtime_identity(
  repository_id : @workflow.RepositoryId,
  goal_id : @control.GoalId,
) -> Result[Unit, @types.ChoirError] {
  let runtime_root = native_goal_runtime_root(repository_id, goal_id)
  if !@sys.path_exists(runtime_root) {
    return Ok(())
  }
  let binary = match native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_dir = match native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  cleanup_native_boxlite_runtime({
    binary,
    runtime_dir,
    root: runtime_root,
    port: 40000 + @sys.get_pid() % 10000,
    api_key: "choir-goal-" + native_goal_runtime_key(repository_id, goal_id),
  })
}

///|
async fn finish_native_goal_runtime(
  terminal_ready : Bool,
  cleanup : async () -> Result[Unit, @types.ChoirError],
) -> Result[Bool, @types.ChoirError] {
  if terminal_ready {
    match cleanup() {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(terminal_ready)
}

///|
async test "Goal runtime cleanup is required only at a terminal boundary" {
  let cleaned = @ref.new(0)
  let cleanup = async fn() {
    @async.sleep(0)
    cleaned.val = cleaned.val + 1
    Ok(())
  }
  assert_false(finish_native_goal_runtime(false, cleanup).unwrap())
  assert_eq(cleaned.val, 0)
  assert_true(finish_native_goal_runtime(true, cleanup).unwrap())
  assert_eq(cleaned.val, 1)
}

///|
async test "Goal cannot cross its terminal boundary when cleanup fails" {
  let result = finish_native_goal_runtime(true, async fn() {
    @async.sleep(0)
    Err(native_goal_execution_error("cleanup failed"))
  })
  assert_true(result is Err(_))
}

///|
async fn capture_native_goal_source_state(
  project_dir : String,
  record : @workflow.GoalExecutionRecord,
  claim : @workflow.GoalSourceClaim,
  capture : async (Command) -> (Int, String),
) -> Result[
  (@workflow.GoalSelectionSourcePart, NativeConductorTask)?,
  @types.ChoirError,
] {
  let output = match
    native_conductor_capture_beads(
      project_dir,
      "show",
      ["show", claim.part_id.0, "--json", "--readonly"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let snapshot = match
    @workflow.goal_selection_snapshot_from_beads_json(
      record.repository_id,
      record.base_commit_oid,
      record.base_tree_oid,
      output,
    ) {
    Ok(value) => value
    Err(_) => return Ok(None)
  }
  let tasks = match native_conductor_tasks_from_output(output) {
    Ok(value) => value
    Err(_) => return Ok(None)
  }
  if snapshot.parts.length() != 1 ||
    tasks.length() != 1 ||
    snapshot.parts[0].part_id != claim.part_id ||
    tasks[0].id != claim.part_id.0 {
    return Ok(None)
  }
  Ok(Some((snapshot.parts[0], tasks[0])))
}

///|
async fn observe_native_goal_source_claim(
  project_dir : String,
  record : @workflow.GoalExecutionRecord,
  claim : @workflow.GoalSourceClaim,
  capture : async (Command) -> (Int, String),
) -> Result[@workflow.GoalSourceClaimObservation, @types.ChoirError] {
  let (source, task) = match
    capture_native_goal_source_state(project_dir, record, claim, capture) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Ok(@workflow.GoalSourceClaimObservation::GoalSourceAmbiguous)
    Err(error) => return Err(error)
  }
  if source.source_content_digest != claim.source_content_digest {
    return Ok(@workflow.GoalSourceClaimObservation::GoalSourceContentDrifted)
  }
  match task.status {
    @types.TaskStatus::Done =>
      Ok(@workflow.GoalSourceClaimObservation::GoalSourceClosed)
    @types.TaskStatus::InProgress =>
      if task.assignee == claim.claimant {
        Ok(
          @workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor,
        )
      } else {
        Ok(
          @workflow.GoalSourceClaimObservation::GoalSourceClaimedByAnotherActor,
        )
      }
    @types.TaskStatus::Todo =>
      if task.assignee == "" {
        Ok(@workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact)
      } else if task.assignee == claim.claimant {
        Ok(@workflow.GoalSourceClaimObservation::GoalSourceAmbiguous)
      } else {
        Ok(
          @workflow.GoalSourceClaimObservation::GoalSourceClaimedByAnotherActor,
        )
      }
  }
}

///|
async fn observe_native_goal_source_release(
  project_dir : String,
  record : @workflow.GoalExecutionRecord,
  claim : @workflow.GoalSourceClaim,
  capture : async (Command) -> (Int, String),
) -> Result[@workflow.GoalSourceClaimObservation, @types.ChoirError] {
  let (source, task) = match
    capture_native_goal_source_state(project_dir, record, claim, capture) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Ok(@workflow.GoalSourceClaimObservation::GoalSourceAmbiguous)
    Err(error) => return Err(error)
  }
  match task.status {
    @types.TaskStatus::InProgress if task.assignee == claim.claimant =>
      Ok(@workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor)
    @types.TaskStatus::Todo if task.assignee == "" =>
      Ok(@workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact)
    _ if source.source_content_digest != claim.source_content_digest =>
      Ok(@workflow.GoalSourceClaimObservation::GoalSourceContentDrifted)
    @types.TaskStatus::Done =>
      Ok(@workflow.GoalSourceClaimObservation::GoalSourceClosed)
    @types.TaskStatus::InProgress | @types.TaskStatus::Todo =>
      Ok(@workflow.GoalSourceClaimObservation::GoalSourceClaimedByAnotherActor)
  }
}

///|
async fn apply_native_goal_source_claim(
  project_dir : String,
  record : @workflow.GoalExecutionRecord,
  claim : @workflow.GoalSourceClaim,
  capture : async (Command) -> (Int, String),
) -> Result[@workflow.GoalSourceClaimObservation, @types.ChoirError] {
  let initial = match
    observe_native_goal_source_claim(project_dir, record, claim, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if initial != @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact {
    return Ok(initial)
  }
  let claim_result = native_conductor_capture_beads(
    project_dir,
    "claim",
    ["update", claim.part_id.0, "--claim", "--actor", claim.claimant, "--json"],
    capture,
  )
  let observed = match
    observe_native_goal_source_claim(project_dir, record, claim, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if observed == @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact {
    return match claim_result {
      Err(error) => Err(error)
      Ok(_) => Err(native_goal_execution_error("Beads claim was not applied"))
    }
  }
  Ok(observed)
}

///|
async fn apply_native_goal_source_release(
  project_dir : String,
  record : @workflow.GoalExecutionRecord,
  claim : @workflow.GoalSourceClaim,
  capture : async (Command) -> (Int, String),
) -> Result[@workflow.GoalSourceClaimObservation, @types.ChoirError] {
  let initial = match
    observe_native_goal_source_release(project_dir, record, claim, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if initial !=
    @workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor {
    return Ok(initial)
  }
  let release_result = native_conductor_capture_beads(
    project_dir,
    "release",
    [
      "update",
      claim.part_id.0,
      "--status",
      "open",
      "--assignee",
      "",
      "--actor",
      claim.claimant,
      "--json",
    ],
    capture,
  )
  let observed = match
    observe_native_goal_source_release(project_dir, record, claim, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if observed ==
    @workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor {
    return match release_result {
      Err(error) => Err(error)
      Ok(_) => Err(native_goal_execution_error("Beads release was not applied"))
    }
  }
  Ok(observed)
}

///|
fn native_source_claim_test_record(
  content_digest : @control.Digest,
) -> @workflow.GoalExecutionRecord {
  let goal_id = @control.GoalId("goal-source-claim-test")
  let part_id = @control.PartId("choir-source-claim")
  let goal : @control.Goal = {
    id: goal_id,
    contract_digest: content_digest,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let repository_id = @workflow.RepositoryId("source-claim-repository")
  let goal_ref = @workflow.goal_execution_ref(goal_id)
  {
    goal,
    repository_id,
    selection_decision_digest: content_digest,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: @control.GitOid("source-claim-base"),
    base_tree_oid: @control.GitOid("source-claim-tree"),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    pull_request_document: Some({
      title: "test: exercise source claims",
      body: "Exercises native source-claim handling.",
    }),
    migration_production_admission: None,
    goal_ref,
    branch_initialization: @workflow.initial_goal_branch_initialization(
      goal_id,
      repository_id,
      goal_ref,
      @control.GitOid("source-claim-base"),
    ),
    source_claims: [
      {
        ..@workflow.initial_goal_source_claim(
          goal_id, part_id, content_digest, content_digest,
        ),
        lifecycle: @workflow.GoalSourceClaimLifecycle::GoalSourceClaimAuthorized,
      },
    ],
    maximum_parallel_parts: 1,
    policy_revisions: [@workflow.initial_goal_policy_revision(goal_id, 1)],
    part_workflow_ids: ["source-claim-workflow"],
    state: @workflow.GoalExecutionState::GoalExecutionRunning,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 2,
    fencing_epoch: @control.FencingEpoch(1L),
  }
}

///|
async test "Beads claim recovers when delivery succeeded but acknowledgement was lost" {
  let open =
    #|[{"id":"choir-source-claim","title":"Claim me","description":"","acceptance_criteria":"","notes":"","status":"open","priority":2,"issue_type":"task","assignee":"","updated_at":"2026-07-21T00:00:00Z","dependency_count":0}]
  let snapshot = @workflow.goal_selection_snapshot_from_beads_json(
    @workflow.RepositoryId("source-claim-repository"),
    @control.GitOid("source-claim-base"),
    @control.GitOid("source-claim-tree"),
    open,
  ).unwrap()
  let record = native_source_claim_test_record(
    snapshot.parts[0].source_content_digest,
  )
  let claim = record.source_claims[0]
  let calls = @ref.new(0)
  let observation = apply_native_goal_source_claim("/fixture", record, claim, command => {
    calls.val = calls.val + 1
    match calls.val {
      1 => (0, open)
      2 => {
        assert_eq(command.args, [
          "update", "choir-source-claim", "--claim", "--actor", "choir:goal-source-claim-test",
          "--json",
        ])
        (1, "connection closed after commit")
      }
      3 =>
        (
          0,
          (
            #|[{"id":"choir-source-claim","title":"Claim me","description":"","acceptance_criteria":"","notes":"","status":"in_progress","priority":2,"issue_type":"task","assignee":"choir:goal-source-claim-test","updated_at":"2026-07-21T00:01:00Z","dependency_count":0}]
          ),
        )
      _ => fail("unexpected Beads claim command")
    }
  }).unwrap()
  assert_eq(
    observation,
    @workflow.GoalSourceClaimObservation::GoalSourceClaimedByExpectedActor,
  )
  assert_eq(calls.val, 3)
}

///|
async test "Beads claim rejects content drift before mutation" {
  let changed =
    #|[{"id":"choir-source-claim","title":"Changed","description":"","acceptance_criteria":"","notes":"","status":"open","priority":2,"issue_type":"task","assignee":"","updated_at":"2026-07-21T00:01:00Z","dependency_count":0}]
  let record = native_source_claim_test_record(
    @storage.artifact_digest(@utf8.encode("captured-content")),
  )
  let calls = @ref.new(0)
  let observation = apply_native_goal_source_claim(
    "/fixture",
    record,
    record.source_claims[0],
    _ => {
      calls.val = calls.val + 1
      (0, changed)
    },
  ).unwrap()
  assert_eq(
    observation,
    @workflow.GoalSourceClaimObservation::GoalSourceContentDrifted,
  )
  assert_eq(calls.val, 1)
}

///|
async test "Beads release recovers when delivery succeeded but acknowledgement was lost" {
  let claimed =
    #|[{"id":"choir-source-claim","title":"Claim me","description":"","acceptance_criteria":"","notes":"","status":"in_progress","priority":2,"issue_type":"task","assignee":"choir:goal-source-claim-test","updated_at":"2026-07-21T00:01:00Z","dependency_count":0}]
  let snapshot = @workflow.goal_selection_snapshot_from_beads_json(
    @workflow.RepositoryId("source-claim-repository"),
    @control.GitOid("source-claim-base"),
    @control.GitOid("source-claim-tree"),
    claimed,
  ).unwrap()
  let record = native_source_claim_test_record(
    snapshot.parts[0].source_content_digest,
  )
  let claim = record.source_claims[0]
  let calls = @ref.new(0)
  let observation = apply_native_goal_source_release(
    "/fixture",
    record,
    claim,
    command => {
      calls.val = calls.val + 1
      match calls.val {
        1 => (0, claimed)
        2 => {
          assert_eq(command.args, [
            "update", "choir-source-claim", "--status", "open", "--assignee", "",
            "--actor", "choir:goal-source-claim-test", "--json",
          ])
          (1, "connection closed after commit")
        }
        3 =>
          (
            0,
            (
              #|[{"id":"choir-source-claim","title":"Claim me","description":"","acceptance_criteria":"","notes":"","status":"open","priority":2,"issue_type":"task","assignee":"","updated_at":"2026-07-21T00:02:00Z","dependency_count":0}]
            ),
          )
        _ => fail("unexpected Beads release command")
      }
    },
  ).unwrap()
  assert_eq(
    observation,
    @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
  )
  assert_eq(calls.val, 3)
}

///|
async fn advance_native_goal_source_claims(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
  capture? : async (Command) -> (Int, String) = capture_command_merged,
) -> Result[Bool, @types.ChoirError] {
  let stored = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_goal_execution_error("Goal execution disappeared"))
    Err(error) => return Err(error)
  }
  if @workflow.goal_source_claims_have_conflict(stored.record) {
    let blocked = match
      @workflow.advance_goal_execution_state(
        stored.record,
        @workflow.GoalExecutionState::GoalExecutionBlocked,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match
      @workflow.persist_goal_execution_transition(
        repository, adapters, stored, blocked,
      ) {
      Ok(_) => return Ok(false)
      Err(error) => return Err(error)
    }
  }
  if @workflow.goal_source_claims_are_receipted(stored.record) {
    return Ok(true)
  }
  let mut selected : @workflow.GoalSourceClaim? = None
  for claim in stored.record.source_claims {
    if claim.lifecycle !=
      @workflow.GoalSourceClaimLifecycle::GoalSourceClaimReceipted {
      selected = Some(claim)
      break
    }
  }
  let claim = match selected {
    Some(value) => value
    None => return Err(native_goal_execution_error("source claim disappeared"))
  }
  if claim.lifecycle ==
    @workflow.GoalSourceClaimLifecycle::GoalSourceClaimPlanned {
    let authorized = match
      @workflow.authorize_goal_source_claim(stored.record, claim.part_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    return match
      @workflow.persist_goal_execution_transition(
        repository, adapters, stored, authorized,
      ) {
      Ok(_) => Ok(false)
      Err(error) => Err(error)
    }
  }
  if claim.lifecycle !=
    @workflow.GoalSourceClaimLifecycle::GoalSourceClaimAuthorized {
    return Err(native_goal_execution_error("source claim is not actionable"))
  }
  let observation = match
    apply_native_goal_source_claim(project_dir, stored.record, claim, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let reconciled = match
    @workflow.reconcile_goal_source_claim(
      stored.record,
      claim.part_id,
      observation,
      @env.now().reinterpret_as_int64() / 1000L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if reconciled == stored.record {
    Ok(@workflow.goal_source_claims_are_receipted(reconciled))
  } else {
    match
      @workflow.persist_goal_execution_transition(
        repository, adapters, stored, reconciled,
      ) {
      Ok(_) => Ok(false)
      Err(error) => Err(error)
    }
  }
}

///|
async fn advance_native_goal_source_releases(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
  capture? : async (Command) -> (Int, String) = capture_command_merged,
) -> Result[Bool, @types.ChoirError] {
  let stored = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_goal_execution_error("Goal execution disappeared"))
    Err(error) => return Err(error)
  }
  if @workflow.goal_source_release_dispositions_are_known(stored.record) {
    return Ok(true)
  }
  let mut selected : @workflow.GoalSourceClaim? = None
  for claim in stored.record.source_claims {
    if !(claim.lifecycle
      is @workflow.GoalSourceClaimLifecycle::GoalSourceReleased) &&
      !(claim.lifecycle
      is @workflow.GoalSourceClaimLifecycle::GoalSourceReleaseConflict(_)) &&
      !(claim.lifecycle
      is @workflow.GoalSourceClaimLifecycle::GoalSourceClaimConflict(_)) {
      selected = Some(claim)
      break
    }
  }
  let claim = match selected {
    Some(value) => value
    None =>
      return Err(native_goal_execution_error("source release disappeared"))
  }
  match claim.lifecycle {
    @workflow.GoalSourceClaimLifecycle::GoalSourceClaimPlanned
    | @workflow.GoalSourceClaimLifecycle::GoalSourceClaimAuthorized
    | @workflow.GoalSourceClaimLifecycle::GoalSourceClaimReceipted => {
      let authorized = match
        @workflow.authorize_goal_source_release(stored.record, claim.part_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      return match
        @workflow.persist_goal_execution_transition(
          repository, adapters, stored, authorized,
        ) {
        Ok(_) => Ok(false)
        Err(error) => Err(error)
      }
    }
    @workflow.GoalSourceClaimLifecycle::GoalSourceReleaseAuthorized => ()
    _ =>
      return Err(
        native_goal_execution_error("source release is not actionable"),
      )
  }
  let observation = match
    apply_native_goal_source_release(project_dir, stored.record, claim, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let reconciled = match
    @workflow.reconcile_goal_source_release(
      stored.record,
      claim.part_id,
      observation,
      @env.now().reinterpret_as_int64() / 1000L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if reconciled == stored.record {
    Ok(false)
  } else {
    match
      @workflow.persist_goal_execution_transition(
        repository, adapters, stored, reconciled,
      ) {
      Ok(_) => Ok(false)
      Err(error) => Err(error)
    }
  }
}

///|
fn native_goal_mcp_script() -> String? {
  resolve_native_runtime_asset(ChoirRuntimeAsset::ChoirSandboxMcp)
}

///|
async fn advance_native_goal_branch_initialization(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  goal_id : @control.GoalId,
) -> Result[@workflow.GoalBranchInitLifecycle, @types.ChoirError] {
  let stored = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_goal_execution_error("Goal execution disappeared"))
    Err(error) => return Err(error)
  }
  match stored.record.branch_initialization.lifecycle {
    @workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted
    | @workflow.GoalBranchInitLifecycle::GoalBranchInitIntegrityBlocked
    | @workflow.GoalBranchInitLifecycle::GoalBranchInitUncertain
    | @workflow.GoalBranchInitLifecycle::GoalBranchInitAbandonedByCancellation =>
      return Ok(stored.record.branch_initialization.lifecycle)
    @workflow.GoalBranchInitLifecycle::GoalBranchInitPlanned => {
      let authorized = match
        @workflow.authorize_goal_branch_initialization(stored.record) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let persisted = match
        @workflow.persist_goal_execution_transition(
          repository, adapters, stored, authorized,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      return Ok(persisted.record.branch_initialization.lifecycle)
    }
    @workflow.GoalBranchInitLifecycle::GoalBranchInitAuthorized => ()
  }
  let git = match discover_native_goal_repository(project_dir, stored.record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let config = native_goal_initialization_git_config(git, stored.record)
  let mut observation = match
    observe_native_goal_branch_initialization(
      config,
      stored.record.branch_initialization,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if observation ==
    @workflow.GoalBranchInitObservation::GoalBranchInitRefsAbsent {
    match
      apply_native_goal_branch_initialization(
        config,
        stored.record.branch_initialization,
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    observation = match
      observe_native_goal_branch_initialization(
        config,
        stored.record.branch_initialization,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  let reconciled = match
    @workflow.reconcile_goal_branch_initialization(
      stored.record,
      observation,
      @env.now().reinterpret_as_int64() / 1000L,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let next = match reconciled {
    @workflow.GoalBranchInitReconciliation::GoalBranchInitObservationRecorded(
      value
    ) => value
    @workflow.GoalBranchInitReconciliation::GoalBranchInitExactRetryAuthorized(
      _
    ) =>
      return Err(
        native_goal_execution_error(
          "Goal branch initialization remained unapplied",
        ),
      )
  }
  if next == stored.record {
    Ok(next.branch_initialization.lifecycle)
  } else {
    match
      @workflow.persist_goal_execution_transition(
        repository, adapters, stored, next,
      ) {
      Ok(value) => Ok(value.record.branch_initialization.lifecycle)
      Err(error) => Err(error)
    }
  }
}

///|
async fn execute_native_goal_record(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.GoalExecutionRecord,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
) -> Result[Unit, @types.ChoirError] {
  let git = match discover_native_goal_repository(project_dir, record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_key = native_goal_runtime_key(
    record.repository_id,
    record.goal.id,
  )
  let runtime_root = native_goal_runtime_root(
    record.repository_id,
    record.goal.id,
  )
  let runtime_preexisted = @sys.path_exists(runtime_root)
  let generations : Array[@control.SandboxGenerationId] = []
  for snapshot in snapshots {
    for lease in snapshot.sandbox_leases {
      if !generations.contains(lease.generation_id) {
        generations.push(lease.generation_id)
      }
    }
  }
  let existing_generation = native_existing_sandbox_generation(
    runtime_root, generations, @sys.path_exists,
  )
  let server_config = match native_goal_boxlite_server_config(record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if runtime_preexisted && existing_generation is None {
    match cleanup_native_boxlite_runtime(server_config) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  if !@sys.create_dir_all(runtime_root) ||
    @sys.realpath_native(runtime_root) != Some(runtime_root) {
    return Err(native_goal_execution_error("runtime root is unavailable"))
  }
  let moon_home = match @sys.getenv("CHOIR_MOON_HOME") {
    Some(value) => value
    None =>
      match @sys.getenv("HOME") {
        Some(value) => value + "/.moon"
        None => return Err(native_goal_execution_error("Moon home is absent"))
      }
  }
  let node = match resolve_executable_in_path("node") {
    Some(value) => value
    None => return Err(native_goal_execution_error("Node is absent"))
  }
  let mcp_script = match native_goal_mcp_script() {
    Some(value) => value
    None => return Err(native_goal_execution_error("sandbox MCP is absent"))
  }
  let server = match start_native_boxlite_server(server_config) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (active_server, initial_prepared) = match existing_generation {
    Some(_) => (server, None)
    None =>
      match
        prepare_native_boxlite_environment(
          server,
          moon_home,
          "choir-base-goal-" + runtime_key,
        ) {
        Ok(value) => (value.server, Some(value))
        Err(error) => {
          ignore(cleanup_native_boxlite_server(server))
          return Err(error)
        }
      }
  }
  let clock = @ref.new(100000L)
  let now = fn() {
    clock.val = clock.val + 1L
    clock.val
  }
  let goal_cancellation_requested = fn() {
    native_goal_cancellation_observed(
      @workflow.load_goal_execution_record(
        repository,
        local_part_workflow_repository_adapters(),
        record.goal.id,
      ),
      fn(current) {
        current.state == @workflow.GoalExecutionState::GoalExecutionCanceling ||
        current.state == @workflow.GoalExecutionState::GoalExecutionCanceled
      },
    )
  }
  let parts : Array[NativeGoalPartRuntime] = []
  for snapshot in snapshots {
    let surface = snapshot.identities.implementation_session.surface
    if snapshot.identities.audit_session.surface != surface {
      match existing_generation {
        Some(_) => stop_native_boxlite_server(active_server)
        None => ignore(cleanup_native_boxlite_server(active_server))
      }
      return Err(
        native_goal_execution_error("Part provider assignment drifted"),
      )
    }
    let runtime = match
      create_native_part_effect_runtime(
        native_part_runtime_config_for_paths(
          repository,
          active_server,
          git.root,
          git.git_directory,
          git.object_directory,
          record.goal_ref.0,
          moon_home,
          node,
          mcp_script,
          now,
          goal_cancellation_requested~,
        ),
      ) {
      Ok(value) => value
      Err(error) => {
        match existing_generation {
          Some(_) => stop_native_boxlite_server(active_server)
          None => ignore(cleanup_native_boxlite_server(active_server))
        }
        return Err(error)
      }
    }
    parts.push({
      snapshot,
      runtime,
      counts: {
        implementation: @ref.new(0),
        verification: @ref.new(0),
        audit: @ref.new(0),
      },
      surface,
    })
  }
  if parts.length() == 0 {
    match existing_generation {
      Some(_) => stop_native_boxlite_server(active_server)
      None => ignore(cleanup_native_boxlite_server(active_server))
    }
    return Err(native_goal_execution_error("Goal has no Part runtimes"))
  }
  let prepared = match initial_prepared {
    Some(value) => value
    None =>
      match existing_generation {
        Some(generation_id) =>
          match native_runtime_sandbox(parts[0].runtime, generation_id) {
            Ok(value) => value.prepared
            Err(error) => {
              stop_native_boxlite_server(active_server)
              return Err(error)
            }
          }
        None => {
          stop_native_boxlite_server(active_server)
          return Err(
            native_goal_execution_error("Goal runtime preparation is absent"),
          )
        }
      }
  }
  for part in parts {
    part.runtime.prepared.val = Some(prepared)
  }
  let integration : NativeGitIntegrationConfig = {
    repository_root: git.root,
    git_directory: git.git_directory,
    object_directory: git.object_directory,
    control_root: runtime_root + "/integration-control",
    goal_ref: record.goal_ref.0,
  }
  let boxlite_effect_lock = @ref.new(false)
  let config : GoalPartWorkflowAdapterConfig = {
    bindings: parts.map(fn(part) {
      {
        scheduling_record: {
          part: part.snapshot.part,
          task_contract: part.snapshot.task_contract,
        },
        initial_snapshot: part.snapshot,
        repository,
      }
    }),
    repository_adapters: local_part_workflow_repository_adapters(),
    dependencies: fn(part_id, admission) {
      let part = match native_goal_part_runtime(parts, part_id) {
        Some(value) => value
        None =>
          return Err(native_goal_execution_error("Part runtime is absent"))
      }
      let dependencies = native_part_dependencies_with_admission(
        repository,
        part.runtime,
        clock,
        part.counts,
        part.surface,
        None,
        Some(boxlite_effect_lock),
        fn(_) { None },
        explicit_admission=Some(admission),
      )
      Ok({
        ..dependencies,
        goal_authorizes_new_effects: fn() {
          match
            @workflow.load_goal_execution_record(
              repository,
              local_part_workflow_repository_adapters(),
              record.goal.id,
            ) {
            Ok(Some(current)) =>
              if current.record.state ==
                @workflow.GoalExecutionState::GoalExecutionRunning &&
                current.record.goal.lifecycle ==
                @control.GoalLifecycle::GoalActive(
                  @control.GoalActiveCondition::GoalRunning,
                ) {
                Ok(
                  @workflow.PartGoalAuthorization::PartGoalAuthorized(
                    Some({ record: current.state_record }),
                  ),
                )
              } else {
                Ok(@workflow.PartGoalAuthorization::PartGoalNotAuthorized)
              }
            Ok(None) =>
              Err(native_goal_execution_error("Goal record disappeared"))
            Err(error) => Err(error)
          }
        },
      })
    },
    integration_input: native_goal_integration_input,
    plan_conflict_repair: plan_native_goal_conflict_repair,
    read_goal_head: async fn() {
      read_native_goal_head(integration, native_git_integration_adapters())
    },
  }
  let result = @workflow.run_goal_parts(
    config.bindings.map(fn(binding) { binding.scheduling_record }),
    record.maximum_parallel_parts,
    goal_part_workflow_adapters(config),
  )
  match result {
    // Source Beads deliberately stay claimed here: Part integration onto the
    // private Goal branch is not delivery. Closure happens at the Goal
    // delivery boundary, inside finalization once the PR is observed ready.
    Ok(_) => {
      ignore(cleanup_native_boxlite_server(prepared.server))
      Ok(())
    }
    Err(error) => {
      // The authorized effect may still be retriable on the next tick. Keep
      // its persisted sandbox generation while releasing live processes.
      stop_native_boxlite_server(prepared.server)
      Err(error)
    }
  }
}

///|
async fn reconcile_native_completed_bead(
  project_dir : String,
  repository_id : @workflow.RepositoryId,
  base_commit_oid : @control.GitOid,
  base_tree_oid : @control.GitOid,
  part_id : @control.PartId,
  source_content_digest : @control.Digest,
  claimant : String,
  capture? : async (Command) -> (Int, String) = capture_command_merged,
) -> Result[Unit, @types.ChoirError] {
  let current_output = match
    native_conductor_capture_beads(
      project_dir,
      "show",
      ["show", part_id.0, "--json", "--readonly"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let current_snapshot = match
    @workflow.goal_selection_snapshot_from_beads_json(
      repository_id, base_commit_oid, base_tree_oid, current_output,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut current : @workflow.GoalSelectionSourcePart? = None
  for source in current_snapshot.parts {
    if source.part_id == part_id {
      if current is Some(_) {
        return Err(
          native_goal_execution_error(
            "Beads returned duplicate source Part identity",
          ),
        )
      }
      current = Some(source)
    }
  }
  let source = match current {
    Some(value) => value
    None =>
      return Err(
        native_goal_execution_error("Beads omitted the integrated source Part"),
      )
  }
  let task = match native_conductor_tasks_from_output(current_output) {
    Ok([value]) if value.id == part_id.0 => value
    Ok(_) =>
      return Err(
        native_goal_execution_error("Beads returned an ambiguous source Part"),
      )
    Err(error) => return Err(error)
  }
  if source.source_content_digest != source_content_digest {
    return Err(
      native_goal_execution_error(
        "integrated source Part changed after Goal acceptance: " + part_id.0,
      ),
    )
  }
  if task.status == @types.TaskStatus::Done {
    return Ok(())
  }
  if task.status != @types.TaskStatus::InProgress || task.assignee != claimant {
    return Err(
      native_goal_execution_error(
        "integrated source Part is not claimed by this Goal: " + part_id.0,
      ),
    )
  }
  let updated_output = match
    native_conductor_capture_beads(
      project_dir,
      "update",
      ["update", part_id.0, "--status", "closed", "--json"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let updated = match native_conductor_tasks_from_output(updated_output) {
    Ok([value]) => value
    Ok(_) =>
      return Err(
        native_goal_execution_error("Beads update returned an ambiguous Part"),
      )
    Err(error) => return Err(error)
  }
  if updated.id != part_id.0 || updated.status != @types.TaskStatus::Done {
    Err(
      native_goal_execution_error(
        "Beads did not confirm the integrated Part as closed",
      ),
    )
  } else {
    Ok(())
  }
}

///|
/// Close the source Beads of every integrated Part. This is the Goal
/// delivery boundary effect: it must run only once the finalization gate has
/// observed a ready pull request, never at Part integration, so a Bead's
/// closed status keeps meaning "Choir delivered this work".
pub async fn reconcile_native_integrated_part_sources(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.GoalExecutionRecord,
  capture? : async (Command) -> (Int, String) = capture_command_merged,
) -> Result[Unit, @types.ChoirError] {
  let adapters = local_part_workflow_repository_adapters()
  let selection = match
    @workflow.load_goal_selection_decision(repository, adapters, record.goal.id) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_goal_execution_error("Goal selection disappeared"))
    Err(error) => return Err(error)
  }
  if selection.state_record.value_digest != record.selection_decision_digest ||
    @workflow.goal_selection_decision_digest(selection.decision) !=
    record.selection_decision_digest {
    return Err(native_goal_execution_error("Goal selection digest drifted"))
  }
  for workflow_id in record.part_workflow_ids {
    let stored = match
      @workflow.load_part_snapshot(repository, adapters, workflow_id) {
      Ok(Some(value)) => value
      Ok(None) =>
        return Err(native_goal_execution_error("Part workflow is absent"))
      Err(error) => return Err(error)
    }
    let current = stored.snapshot
    if !(current.part.lifecycle is @control.PartLifecycle::PartIntegrated(_)) {
      continue
    }
    let mut accepted : @workflow.AcceptedGoalPart? = None
    for candidate in selection.decision.accepted_parts {
      if candidate.part.id == current.part.id {
        accepted = Some(candidate)
      }
    }
    let source = match accepted {
      Some(value) => value
      None =>
        return Err(
          native_goal_execution_error(
            "integrated Part is absent from the Goal selection",
          ),
        )
    }
    let mut source_claim : @workflow.GoalSourceClaim? = None
    for claim in record.source_claims {
      if claim.part_id == source.part.id {
        source_claim = Some(claim)
      }
    }
    let claim = match source_claim {
      Some(value) =>
        if value.lifecycle ==
          @workflow.GoalSourceClaimLifecycle::GoalSourceClaimReceipted &&
          value.source_content_digest == source.source_content_digest {
          value
        } else {
          return Err(
            native_goal_execution_error(
              "integrated Part has no exact source claim receipt",
            ),
          )
        }
      None =>
        return Err(
          native_goal_execution_error(
            "integrated Part has no exact source claim receipt",
          ),
        )
    }
    match
      reconcile_native_completed_bead(
        project_dir,
        record.repository_id,
        record.base_commit_oid,
        record.base_tree_oid,
        source.part.id,
        source.source_content_digest,
        claim.claimant,
        capture~,
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(())
}

///|
async test "integrated Part source reconciliation is idempotent and drift safe" {
  let repository_id = @workflow.RepositoryId("repository-source-sync")
  let base_commit_oid = @control.GitOid("base-commit-source-sync")
  let base_tree_oid = @control.GitOid("base-tree-source-sync")
  let part_id = @control.PartId("choir-source-sync")
  let claimed_source =
    #|[{"id":"choir-source-sync","title":"Original","description":"","acceptance_criteria":"","notes":"","status":"in_progress","priority":2,"issue_type":"task","assignee":"choir:goal-source-sync","updated_at":"2026-07-21T00:00:00Z","dependency_count":0}]
  let expected_content = match
    @workflow.goal_selection_snapshot_from_beads_json(
      repository_id, base_commit_oid, base_tree_oid, claimed_source,
    ) {
    Ok({ parts: [source], .. }) => source.source_content_digest
    Ok(_) => fail("source fixture was ambiguous")
    Err(error) => fail(error.message())
  }
  let close_commands : Array[Command] = []
  let closed = reconcile_native_completed_bead(
    "/repo",
    repository_id,
    base_commit_oid,
    base_tree_oid,
    part_id,
    expected_content,
    "choir:goal-source-sync",
    capture=command => {
      close_commands.push(command)
      if command.args[0] == "show" {
        (0, claimed_source)
      } else {
        (
          0,
          (
            #|{"id":"choir-source-sync","title":"Original","status":"closed"}
          ),
        )
      }
    },
  )
  match closed {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  @debug.assert_eq(close_commands.map(fn(command) { command.args }), [
    ["show", "choir-source-sync", "--json", "--readonly"],
    ["update", "choir-source-sync", "--status", "closed", "--json"],
  ])

  let replay_commands : Array[Command] = []
  let replayed = reconcile_native_completed_bead(
    "/repo",
    repository_id,
    base_commit_oid,
    base_tree_oid,
    part_id,
    expected_content,
    "choir:goal-source-sync",
    capture=command => {
      replay_commands.push(command)
      (
        0,
        (
          #|[{"id":"choir-source-sync","title":"Original","description":"","acceptance_criteria":"","notes":"","status":"closed","priority":2,"issue_type":"task","assignee":"","updated_at":"2026-07-21T00:01:00Z","dependency_count":0}]
        ),
      )
    },
  )
  assert_true(replayed is Ok(_))
  assert_eq(replay_commands.length(), 1)

  let drift_commands : Array[Command] = []
  let drifted = reconcile_native_completed_bead(
    "/repo",
    repository_id,
    base_commit_oid,
    base_tree_oid,
    part_id,
    expected_content,
    "choir:goal-source-sync",
    capture=command => {
      drift_commands.push(command)
      (
        0,
        (
          #|[{"id":"choir-source-sync","title":"Changed","description":"","acceptance_criteria":"","notes":"","status":"in_progress","priority":2,"issue_type":"task","assignee":"choir:goal-source-sync","updated_at":"2026-07-21T00:01:00Z","dependency_count":0}]
        ),
      )
    },
  )
  assert_true(drifted is Err(_))
  assert_eq(drift_commands.length(), 1)
}

///|
fn native_goal_cancellation_can_finish(
  snapshots : Array[@workflow.PartWorkflowSnapshot],
) -> Bool {
  snapshots.all(@workflow.part_cancellation_disposition_is_known)
}

///|
async fn persist_native_cancellation_observation(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  stored : @workflow.PartStoredSnapshot,
  integration : NativeGitIntegrationConfig,
  observed_at : Int64,
) -> Result[@workflow.PartStoredSnapshot, @types.ChoirError] {
  let intent = match stored.snapshot.pending_effect {
    Some(
      {
        lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
        kind: @workflow.PartEffectKind::ApplyIntegration(_, _),
        ..,
      } as value
    ) => value
    _ => return Ok(stored)
  }
  let recovery = match
    reconcile_native_git_effect(
      integration,
      stored.snapshot,
      intent,
      native_git_integration_adapters(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let observation = match recovery {
    @workflow.PartEffectRecovery::EffectObservationRecovered(value) => value
    _ =>
      return Err(
        native_goal_execution_error(
          "authorized integration did not produce an exact witness",
        ),
      )
  }
  @workflow.persist_recovered_part_effect_observation(
    repository,
    adapters,
    stored,
    intent,
    observation,
    observed_at,
    fn(reference) { native_part_artifact_exists(repository, reference) },
    fn(_) { true },
  )
}

///|
async fn reconcile_native_goal_part_cancellation(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  record : @workflow.GoalExecutionRecord,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
  forge : NativePullRequestForgeAdapters,
) -> Result[(Array[@workflow.PartWorkflowSnapshot], Bool), @types.ChoirError] {
  let needs_integration = snapshots.any(fn(snapshot) {
    snapshot.pending_effect
    is Some(
      {
        lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
        kind: @workflow.PartEffectKind::ApplyIntegration(_, _),
        ..,
      }
    )
  })
  let integration = if needs_integration {
    let git = match discover_native_goal_repository(project_dir, record) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    Some({
      repository_root: git.root,
      git_directory: git.git_directory,
      object_directory: git.object_directory,
      control_root: native_goal_runtime_root(
        record.repository_id,
        record.goal.id,
      ) +
      "/integration-control",
      goal_ref: record.goal_ref.0,
    })
  } else {
    None
  }
  let observed_at = match record.cancellation_request {
    Some(request) => request.requested_at
    None =>
      return Err(
        native_goal_execution_error(
          "canceling Goal has no cancellation request",
        ),
      )
  }
  let reconciled : Array[@workflow.PartWorkflowSnapshot] = []
  for snapshot in snapshots {
    let stored = match
      @workflow.load_part_snapshot(repository, adapters, snapshot.workflow_id) {
      Ok(Some(value)) => value
      Ok(None) =>
        return Err(
          native_goal_execution_error("Part disappeared during cancellation"),
        )
      Err(error) => return Err(error)
    }
    let witnessed = match integration {
      Some(config) =>
        match
          persist_native_cancellation_observation(
            repository, adapters, stored, config, observed_at,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      None => stored
    }
    let canceled = match
      @workflow.persist_part_goal_cancellation(repository, adapters, witnessed) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    reconciled.push(canceled.snapshot)
  }
  let assurance_known = match
    reconcile_native_goal_assurance_cancellation(
      project_dir, repository, adapters, record, observed_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let finalization_known = match
    reconcile_native_goal_finalization_cancellation(
      project_dir, repository, adapters, record, forge, observed_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((reconciled, assurance_known && finalization_known))
}

///|
async fn reconcile_native_goal_assurance_cancellation(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  observed_at : Int64,
) -> Result[Bool, @types.ChoirError] {
  let stored = match
    @workflow.load_goal_assurance_record(
      repository,
      adapters,
      execution.goal.id,
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(true)
    Err(error) => return Err(error)
  }
  if @workflow.goal_assurance_cancellation_disposition_is_known(stored.record) {
    return Ok(true)
  }
  let reconciled = if stored.record.seal_intent.lifecycle ==
    @control.GoalBranchSealIntentLifecycle::GoalBranchSealAuthorized {
    let git = match discover_native_goal_repository(project_dir, execution) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let observation = match
      native_goal_seal_witness(
        git,
        execution.goal_ref,
        stored.record.seal_intent,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let witnessed = match
      @workflow.record_goal_assurance_seal_witness(
        stored.record,
        observation,
        observed_at,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match
      persist_native_goal_assurance_record(
        repository,
        adapters,
        execution,
        witnessed,
        Some(stored.state_record.version),
      ) {
      Ok(Some(value)) => value
      Ok(None) => return Ok(false)
      Err(error) => return Err(error)
    }
  } else {
    stored
  }
  let canceled = match
    @workflow.record_goal_assurance_cancellation(reconciled.record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if canceled == reconciled.record {
    return Ok(
      @workflow.goal_assurance_cancellation_disposition_is_known(canceled),
    )
  }
  let persisted = match
    persist_native_goal_assurance_record(
      repository,
      adapters,
      execution,
      canceled,
      Some(reconciled.state_record.version),
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(false)
    Err(error) => return Err(error)
  }
  Ok(
    @workflow.goal_assurance_cancellation_disposition_is_known(persisted.record),
  )
}

///|
async fn reconcile_native_goal_publication_cancellation(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  observed_at : Int64,
) -> Result[Bool, @types.ChoirError] {
  let stored = match
    @workflow.load_goal_publication_record(
      repository,
      adapters,
      execution.goal.id,
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(true)
    Err(error) => return Err(error)
  }
  match stored.record.intent.state {
    @workflow.BranchPublicationState::BranchPublicationReceipted
    | @workflow.BranchPublicationState::BranchPublicationDrift
    | @workflow.BranchPublicationState::BranchPublicationAbandonedByCancellation =>
      return Ok(true)
    _ => ()
  }
  let observation = match stored.record.intent.state {
    @workflow.BranchPublicationState::BranchPublicationPlanned
    | @workflow.BranchPublicationState::BranchPublicationPreflightUncertain =>
      @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain
    _ => {
      let git = match discover_native_goal_repository(project_dir, execution) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      native_remote_branch_observation(git, stored.record.intent)
    }
  }
  let next = match
    @workflow.record_goal_publication_cancellation(
      stored.record,
      observation,
      observed_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if next != stored.record {
    match
      persist_native_goal_publication_record(
        repository,
        adapters,
        execution,
        next,
        Some(stored.state_record.version),
      ) {
      Ok(Some(_)) => ()
      Ok(None) => return Ok(false)
      Err(error) => return Err(error)
    }
  }
  Ok(@workflow.goal_publication_cancellation_disposition_is_known(next))
}

///|
async fn reconcile_native_goal_pull_request_cancellation(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  forge : NativePullRequestForgeAdapters,
  observed_at : Int64,
) -> Result[Bool, @types.ChoirError] {
  let stored = match
    @workflow.load_goal_pull_request_record(
      repository,
      adapters,
      execution.goal.id,
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(true)
    Err(error) => return Err(error)
  }
  match stored.record.intent.state {
    @workflow.PullRequestIntentState::PullRequestReceipted
    | @workflow.PullRequestIntentState::PullRequestNeedsInput(_)
    | @workflow.PullRequestIntentState::PullRequestAbandonedByCancellation =>
      return Ok(true)
    _ => ()
  }
  let lookup = match stored.record.intent.state {
    @workflow.PullRequestIntentState::PullRequestPlanned
    | @workflow.PullRequestIntentState::PullRequestAuthorized =>
      @workflow.PullRequestLookupObservation::PullRequestLookupUncertain
    _ => {
      let git = match discover_native_goal_repository(project_dir, execution) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let repository_name = match (forge.resolve_repository)(git.root) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      (forge.lookup)(git.root, repository_name, stored.record.intent)
    }
  }
  let next = match
    @workflow.record_goal_pull_request_cancellation(
      stored.record,
      lookup,
      observed_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if next != stored.record {
    match
      persist_native_goal_pull_request_record(
        repository,
        adapters,
        execution,
        next,
        Some(stored.state_record.version),
      ) {
      Ok((Some(_), _)) => ()
      Ok((None, _)) => return Ok(false)
      Err(error) => return Err(error)
    }
  }
  Ok(@workflow.goal_pull_request_cancellation_disposition_is_known(next))
}

///|
async fn reconcile_native_goal_finalization_cancellation(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  forge : NativePullRequestForgeAdapters,
  observed_at : Int64,
) -> Result[Bool, @types.ChoirError] {
  let publication_known = match
    reconcile_native_goal_publication_cancellation(
      project_dir, repository, adapters, execution, observed_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let pull_request_known = match
    reconcile_native_goal_pull_request_cancellation(
      project_dir, repository, adapters, execution, forge, observed_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(publication_known && pull_request_known)
}

///|
fn native_goal_assurance_transaction_completed(
  outcome : @storage.StateTransactionOutcome,
) -> Bool {
  match outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost => true
    _ => false
  }
}

///|
fn persist_native_goal_assurance_record(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  record : @workflow.GoalAssuranceRecord,
  expected_store_version : Int?,
) -> Result[@workflow.StoredGoalAssuranceRecord?, @types.ChoirError] {
  let receipt = match
    @workflow.persist_goal_assurance_record(repository, adapters, {
      record,
      expected_store_version,
      goal_precondition: @workflow.goal_execution_state_precondition(execution),
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.outcome {
    @workflow.GoalAssurancePersistenceOutcome::GoalAssuranceGoalPreconditionConflict =>
      Ok(None)
    @workflow.GoalAssurancePersistenceOutcome::GoalAssurancePersistenceCompleted(
      outcome
    ) => {
      let observed = match
        @workflow.load_goal_assurance_record(
          repository,
          adapters,
          execution.goal.id,
        ) {
        Ok(Some(value)) => value
        Ok(None) =>
          return Err(
            native_goal_execution_error("Goal assurance record disappeared"),
          )
        Err(error) => return Err(error)
      }
      if observed.record == record &&
        (
          native_goal_assurance_transaction_completed(outcome) ||
          outcome ==
          @storage.StateTransactionOutcome::StateTransactionVersionConflict
        ) {
        Ok(Some(observed))
      } else {
        Err(
          native_goal_execution_error("Goal assurance persistence conflicted"),
        )
      }
    }
  }
}

///|
async fn native_goal_ref_identity(
  repository : NativeGoalRepositoryIdentity,
  goal_ref : @workflow.GitRefName,
) -> Result[(@control.GitOid, @control.GitOid), @types.ChoirError] {
  let head = match
    native_goal_git_value(repository.root, [
      "rev-parse",
      "--verify",
      goal_ref.0 + "^{commit}",
    ]) {
    Ok(value) => @control.GitOid(value)
    Err(error) => return Err(error)
  }
  let tree = match
    native_goal_git_value(repository.root, [
      "show",
      "-s",
      "--format=%T",
      "--no-show-signature",
      head.0,
    ]) {
    Ok(value) => @control.GitOid(value)
    Err(error) => return Err(error)
  }
  Ok((head, tree))
}

///|
async fn native_goal_seal_witness(
  repository : NativeGoalRepositoryIdentity,
  goal_ref : @workflow.GitRefName,
  intent : @control.GoalBranchSealIntent,
) -> Result[@control.GoalBranchSealWitnessObservation, @types.ChoirError] {
  let goal_identity = match native_goal_ref_identity(repository, goal_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let observed_witness = match
    capture_native_goal_git(repository.root, [
      "rev-parse",
      "--verify",
      intent.seal_witness_ref + "^{commit}",
    ]) {
    Ok({ exit_code: 0, output }) =>
      Some(@control.GitOid(output.trim().to_owned()))
    Ok(_) => None
    Err(error) => return Err(error)
  }
  match observed_witness {
    Some(witness_oid) =>
      if witness_oid != intent.expected_head_oid {
        return Ok(
          @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessIntegrityError,
        )
      }
    None => {
      if goal_identity.0 != intent.expected_head_oid ||
        goal_identity.1 != intent.expected_tree_oid {
        return Ok(
          @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessDiverged,
        )
      }
      let zero = if intent.expected_head_oid.0.length() == 64 {
        "0000000000000000000000000000000000000000000000000000000000000000"
      } else {
        "0000000000000000000000000000000000000000"
      }
      let created = match
        capture_native_goal_git(repository.root, [
          "update-ref",
          intent.seal_witness_ref,
          intent.expected_head_oid.0,
          zero,
        ]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if created.exit_code != 0 {
        return Ok(
          @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessIntegrityError,
        )
      }
    }
  }
  let final_goal_identity = match
    native_goal_ref_identity(repository, goal_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let final_witness = match
    native_goal_git_value(repository.root, [
      "rev-parse",
      "--verify",
      intent.seal_witness_ref + "^{commit}",
    ]) {
    Ok(value) => @control.GitOid(value)
    Err(error) => return Err(error)
  }
  if final_witness == intent.expected_head_oid &&
    final_goal_identity.0 == intent.expected_head_oid &&
    final_goal_identity.1 == intent.expected_tree_oid {
    Ok(
      @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessApplied(
        final_witness,
        final_goal_identity.0,
        final_goal_identity.1,
      ),
    )
  } else {
    Ok(@control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessDiverged)
  }
}

///|
async test "native Goal branch initialization atomically anchors both refs" {
  if !real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-goal-branch-init-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create Goal branch initialization test root")
  }
  let git = async fn(arguments : Array[String]) -> NativeGitCapture {
    match capture_native_goal_git(root, arguments) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
  }
  if git(["init", "-q"]).exit_code != 0 {
    fail("failed to initialize Goal branch repository")
  }
  let tree = git(["hash-object", "-w", "-t", "tree", "/dev/null"])
  let commit = git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-m",
    "base",
  ])
  if tree.exit_code != 0 || commit.exit_code != 0 {
    fail("failed to create Goal branch base")
  }
  let base_oid = @control.GitOid(commit.output.trim().to_owned())
  let goal_id = @control.GoalId("goal-branch-init-test")
  let goal_ref = @workflow.goal_execution_ref(goal_id)
  let initialization = @workflow.initial_goal_branch_initialization(
    goal_id,
    @workflow.RepositoryId("repository-branch-init-test"),
    goal_ref,
    base_oid,
  )
  let config : NativeGitIntegrationConfig = {
    repository_root: root,
    git_directory: root + "/.git",
    object_directory: root + "/.git/objects",
    control_root: root + "/control",
    goal_ref: goal_ref.0,
  }
  assert_eq(
    observe_native_goal_branch_initialization(config, initialization).unwrap(),
    @workflow.GoalBranchInitObservation::GoalBranchInitRefsAbsent,
  )
  apply_native_goal_branch_initialization(config, initialization).unwrap()
  assert_eq(
    observe_native_goal_branch_initialization(config, initialization).unwrap(),
    @workflow.GoalBranchInitObservation::GoalBranchInitRefsAtBase,
  )
  assert_true(
    apply_native_goal_branch_initialization(config, initialization) is Err(_),
  )
  assert_eq(
    observe_native_goal_branch_initialization(config, initialization).unwrap(),
    @workflow.GoalBranchInitObservation::GoalBranchInitRefsAtBase,
  )
  assert_eq(
    git(["update-ref", "-d", initialization.initialization_witness_ref.0]).exit_code,
    0,
  )
  assert_eq(
    observe_native_goal_branch_initialization(config, initialization).unwrap(),
    @workflow.GoalBranchInitObservation::GoalBranchInitBranchOnly,
  )
  ignore(@sys.rm_rf(root))
}

///|
async test "native Goal purge removes only an exact owned Git ref" {
  if !real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-goal-ref-purge-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create Goal ref purge test root")
  }
  let git = async fn(arguments : Array[String]) -> NativeGitCapture {
    match capture_native_goal_git(root, arguments) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
  }
  if git(["init", "-q"]).exit_code != 0 {
    fail("failed to initialize Goal ref purge repository")
  }
  let tree = git(["hash-object", "-w", "-t", "tree", "/dev/null"])
  let commit = git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-m",
    "base",
  ])
  if tree.exit_code != 0 || commit.exit_code != 0 {
    fail("failed to create Goal ref purge base")
  }
  let reference = "refs/choir/witness/purge-test"
  if git(["update-ref", reference, commit.output.trim().to_owned()]).exit_code !=
    0 {
    fail("failed to create Goal-owned purge ref")
  }
  let repository : NativeGoalRepositoryIdentity = {
    root,
    git_directory: root + "/.git",
    object_directory: root + "/.git/objects",
  }
  match delete_native_goal_owned_git_ref(repository, reference) {
    Ok(value) => assert_true(value)
    Err(error) => fail(error.message())
  }
  match delete_native_goal_owned_git_ref(repository, reference) {
    Ok(value) => assert_false(value)
    Err(error) => fail(error.message())
  }
  assert_true(
    delete_native_goal_owned_git_ref(repository, "refs/heads/main") is Err(_),
  )
  ignore(@sys.rm_rf(root))
}

///|
async test "native Goal seal witness is exact and idempotent" {
  if !real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-goal-seal-witness-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create Goal seal test root")
  }
  let git = async fn(arguments : Array[String]) -> NativeGitCapture {
    match capture_native_goal_git(root, arguments) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
  }
  if git(["init", "-q"]).exit_code != 0 {
    fail("failed to initialize Goal seal repository")
  }
  let tree = git(["hash-object", "-w", "-t", "tree", "/dev/null"])
  if tree.exit_code != 0 {
    fail("failed to create Goal seal tree")
  }
  let tree_oid = @control.GitOid(tree.output.trim().to_owned())
  let commit = git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree_oid.0,
    "-m",
    "base",
  ])
  if commit.exit_code != 0 {
    fail("failed to create Goal seal commit")
  }
  let commit_oid = @control.GitOid(commit.output.trim().to_owned())
  let goal_ref = @workflow.GitRefName("refs/heads/choir/goals/seal-test")
  if git(["update-ref", goal_ref.0, commit_oid.0]).exit_code != 0 {
    fail("failed to create Goal ref")
  }
  let repository : NativeGoalRepositoryIdentity = {
    root,
    git_directory: root + "/.git",
    object_directory: root + "/.git/objects",
  }
  let intent : @control.GoalBranchSealIntent = {
    id: @control.GoalBranchSealIntentId("seal-intent-test"),
    goal_id: @control.GoalId("goal-seal-test"),
    expected_head_oid: commit_oid,
    expected_tree_oid: tree_oid,
    integration_receipt_set_digest: @control.Digest(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ),
    assurance_policy_revision: @control.RevisionId("assurance-test"),
    assurance_policy_digest: @control.Digest(
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    ),
    seal_witness_ref: "refs/choir/goals/seal-test/sealed/intent-test",
    idempotency_key: "seal-test",
    lifecycle: @control.GoalBranchSealIntentLifecycle::GoalBranchSealAuthorized,
  }
  let expected = @control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessApplied(
    commit_oid, commit_oid, tree_oid,
  )
  match native_goal_seal_witness(repository, goal_ref, intent) {
    Ok(value) => assert_eq(value, expected)
    Err(error) => fail(error.message())
  }
  match native_goal_seal_witness(repository, goal_ref, intent) {
    Ok(value) => assert_eq(value, expected)
    Err(error) => fail(error.message())
  }
  let moved = git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree_oid.0,
    "-p",
    commit_oid.0,
    "-m",
    "moved",
  ])
  if moved.exit_code != 0 ||
    git(["update-ref", goal_ref.0, moved.output.trim().to_owned()]).exit_code !=
    0 {
    fail("failed to move Goal ref")
  }
  match native_goal_seal_witness(repository, goal_ref, intent) {
    Ok(@control.GoalBranchSealWitnessObservation::GoalBranchSealWitnessDiverged) =>
      ()
    Ok(_) => fail("moved Goal ref did not invalidate publication readiness")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(root))
}

///|
fn native_goal_assurance_plan(
  repository : @workflow.PartWorkflowRepository,
  execution : @workflow.GoalExecutionRecord,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
  head_oid : @control.GitOid,
) -> Result[
  (Array[@control.VerificationSpec], @workflow.GoalAssuranceIdentityPlan),
  @types.ChoirError,
] {
  let key = @storage.digest_text(
    @storage.artifact_digest(
      @utf8.encode(
        "choir.native-goal-assurance-plan.v1\u{00}" +
        execution.goal.id.0 +
        "\u{00}" +
        head_oid.0,
      ),
    ),
  )
  let verification_take = native_goal_submission_take(
    "take-" + key + "-goal-verification-1",
    execution.goal.id,
    @control.TakePurpose::GoalVerification(
      execution.goal.id,
      head_oid,
      execution.goal.contract_digest,
    ),
  )
  let audit_take = native_goal_submission_take(
    "take-" + key + "-goal-audit-1",
    execution.goal.id,
    @control.TakePurpose::GoalAudit(
      execution.goal.id,
      execution.goal.contract_digest,
    ),
  )
  let ordered = snapshots.copy()
  ordered.sort_by(fn(left, right) { left.part.id.compare(right.part.id) })
  let specs : Array[@control.VerificationSpec] = []
  let mut ordinal = 0
  for snapshot in ordered {
    for source_spec in snapshot.task_contract.verification_specs {
      ordinal = ordinal + 1
      let content = match
        (local_part_workflow_repository_adapters().artifacts.read)(
          repository.artifact_store,
          { digest: source_spec.process_spec_digest, max_bytes: 65536 },
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let json = @json.parse(@utf8.decode_lossy(content)) catch {
        _ =>
          return Err(
            native_goal_execution_error("Part verification process is not JSON"),
          )
      }
      let source_process : @sandbox.SandboxProcessSpec = @json.from_json(json) catch {
        _ =>
          return Err(
            native_goal_execution_error(
              "Part verification process schema is invalid",
            ),
          )
      }
      match source_process.authority {
        @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
          take_id,
          spec_id,
          spec_digest
        ) if take_id == snapshot.verification_take.id &&
          spec_id == source_spec.id &&
          spec_digest == source_spec.digest => ()
        _ =>
          return Err(
            native_goal_execution_error(
              "Part verification process authority is stale",
            ),
          )
      }
      let spec_id = @control.VerificationSpecId(
        "goal-verify-" + key + "-" + ordinal.to_string(),
      )
      let spec_digest = native_goal_submission_digest(
        "choir.goal-verification-spec.v1",
        [
          execution.goal.id.to_json(),
          head_oid.to_json(),
          snapshot.part.id.to_json(),
          source_spec.to_json(),
        ].to_json(),
      )
      let process = {
        ..source_process,
        authority: @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
          verification_take.id,
          spec_id,
          spec_digest,
        ),
      }
      let artifact = match
        native_goal_submission_adopt(
          repository,
          @utf8.encode(process.to_json().stringify(indent=0)),
          @storage.ArtifactProvenance::ArtifactVerificationProcessSpec(spec_id),
          @storage.ArtifactRetention::ArtifactUntilGoalTerminal(
            execution.goal.id,
          ),
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      specs.push({
        id: spec_id,
        version: 1,
        digest: spec_digest,
        process_spec_digest: artifact.digest,
      })
    }
  }
  if specs.length() == 0 {
    return Err(native_goal_execution_error("Goal verification plan is empty"))
  }
  let surface = @control.ProviderSurfaceId::CodexSubscriptionCli
  let verification_sandbox = native_goal_submission_sandbox(
    "sandbox-" + key + "-goal-verification-1",
    "generation-" + key + "-goal-verification-1",
    verification_take,
    native_goal_submission_profile_digest(surface, "goal-verification"),
  )
  let audit_sandbox = native_goal_submission_sandbox(
    "sandbox-" + key + "-goal-audit-1",
    "generation-" + key + "-goal-audit-1",
    audit_take,
    native_goal_submission_profile_digest(surface, "goal-audit"),
  )
  Ok(
    (
      specs,
      {
        verification_take,
        verification_sandbox,
        audit_take,
        audit_sandbox,
        audit_session: native_goal_submission_session(
          "session-" + key + "-goal-audit-1",
          audit_take,
          audit_sandbox,
          surface,
        ),
      },
    ),
  )
}

///|
async fn advance_native_goal_assurance(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
) -> Result[@workflow.GoalAssuranceTickOutcome, @types.ChoirError] {
  let git = match discover_native_goal_repository(project_dir, execution) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut current = match
    @workflow.load_goal_assurance_record(
      repository,
      adapters,
      execution.goal.id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut authorized_effect_id : String? = None
  let mut cycles = 0
  while cycles < 64 {
    cycles = cycles + 1
    match current {
      None => {
        let identity = match native_goal_ref_identity(git, execution.goal_ref) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let plan = match
          native_goal_assurance_plan(
            repository,
            execution,
            snapshots,
            identity.0,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let planned = match
          @workflow.initialize_goal_assurance(
            execution,
            snapshots,
            identity.0,
            identity.1,
            plan.0,
            plan.1,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        current = match
          persist_native_goal_assurance_record(
            repository,
            adapters,
            execution,
            planned,
            None,
          ) {
          Ok(Some(value)) => Some(value)
          Ok(None) =>
            return Ok(@workflow.GoalAssuranceTickOutcome::GoalAssurancePending)
          Err(error) => return Err(error)
        }
        continue
      }
      Some(stored) => {
        if stored.record.stage == @workflow.GoalAssuranceStage::GoalAudited {
          ignore(
            match
              finish_native_goal_runtime(true, async fn() {
                cleanup_native_goal_runtime(execution)
              }) {
              Ok(value) => value
              Err(error) => return Err(error)
            },
          )
          return Ok(@workflow.GoalAssuranceTickOutcome::GoalAssuranceComplete)
        }
        if stored.record.stage ==
          @workflow.GoalAssuranceStage::GoalAssuranceBlocked {
          return Ok(@workflow.GoalAssuranceTickOutcome::GoalAssuranceBlocked)
        }
        if stored.record.stage ==
          @workflow.GoalAssuranceStage::GoalAssuranceRecoveryUncertain {
          return Ok(@workflow.GoalAssuranceTickOutcome::GoalAssurancePending)
        }
        if stored.record.stage == @workflow.GoalAssuranceStage::GoalAuditPending &&
          stored.record.audit_result is Some(_) &&
          stored.record.pending_effect is None {
          let completed = match
            @workflow.mint_goal_audit_receipt(
              stored.record,
              {
                receipt_id: @control.ReceiptId(
                  stored.record.goal_id.0 + ":goal-audit-receipt",
                ),
                provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
                provider_identity: "codex-subscription-cli",
                model_identity: @control.ModelIdentity::UnreportedModelIdentity,
              },
              fn(digest) {
                match
                  (adapters.artifacts.contains)(
                    repository.artifact_store,
                    digest,
                  ) {
                  Ok(value) => value
                  Err(_) => false
                }
              },
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          current = match
            persist_native_goal_assurance_record(
              repository,
              adapters,
              execution,
              completed,
              Some(stored.state_record.version),
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          continue
        }
        match stored.record.stage {
          @workflow.GoalAssuranceStage::GoalSealPlanned => {
            let identity = match
              native_goal_ref_identity(git, execution.goal_ref) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            let authorized = match
              @workflow.authorize_goal_assurance_seal(
                stored.record,
                execution.goal,
                identity.0,
                identity.1,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = match
              persist_native_goal_assurance_record(
                repository,
                adapters,
                execution,
                authorized,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            continue
          }
          @workflow.GoalAssuranceStage::GoalSealAuthorized => {
            let observation = match
              native_goal_seal_witness(
                git,
                execution.goal_ref,
                stored.record.seal_intent,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            let witnessed = match
              @workflow.record_goal_assurance_seal_witness(
                stored.record,
                observation,
                @env.now().reinterpret_as_int64() / 1000L,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = match
              persist_native_goal_assurance_record(
                repository,
                adapters,
                execution,
                witnessed,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            continue
          }
          @workflow.GoalAssuranceStage::GoalSealWitnessed => {
            let seal_key = @storage.digest_text(
              @storage.artifact_digest(
                @utf8.encode(stored.record.seal_intent.id.0),
              ),
            )
            let completed = match
              @workflow.commit_goal_assurance_seal(
                stored.record,
                @control.GoalBranchSealId("seal-" + seal_key),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = match
              persist_native_goal_assurance_record(
                repository,
                adapters,
                execution,
                completed,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            continue
          }
          _ => ()
        }
        let record = stored.record
        match record.pending_effect {
          None => {
            let intent = match
              @workflow.plan_next_goal_assurance_effect(record) {
              Ok(Some(value)) => value
              Ok(None) =>
                return Err(
                  native_goal_execution_error(
                    "nonterminal Goal assurance has no next effect",
                  ),
                )
              Err(error) => return Err(error)
            }
            let planned = match
              @workflow.persist_planned_goal_assurance_effect(record, intent) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = match
              persist_native_goal_assurance_record(
                repository,
                adapters,
                execution,
                planned,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            continue
          }
          Some(
            {
              lifecycle: @workflow.GoalAssuranceEffectLifecycle::GoalAssuranceEffectPlanned,
              ..,
            } as intent
          ) => {
            let authorized = match
              @workflow.authorize_pending_goal_assurance_effect(record) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = match
              persist_native_goal_assurance_record(
                repository,
                adapters,
                execution,
                authorized,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            authorized_effect_id = Some(intent.effect_id)
            continue
          }
          Some(
            {
              lifecycle: @workflow.GoalAssuranceEffectLifecycle::GoalAssuranceEffectMayHaveOccurred,
              ..,
            } as intent
          ) => {
            let witness = match
              @workflow.load_goal_assurance_effect_witness(
                repository, adapters, intent,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            let observation = match witness {
              Some(value) => value.observation
              None => {
                let retry_safe = match intent.kind {
                  @workflow.GoalAssuranceEffectKind::PrepareGoalVerificationSandbox(
                    _
                  )
                  | @workflow.GoalAssuranceEffectKind::PrepareGoalAuditSandbox(
                    _
                  )
                  | @workflow.GoalAssuranceEffectKind::StartGoalAuditHarness(_) =>
                    true
                  _ => false
                }
                if authorized_effect_id != Some(intent.effect_id) && !retry_safe {
                  ignore(
                    match
                      reconcile_native_goal_processes_once(
                        repository, execution, git, record, intent,
                      ) {
                      Ok(value) => value
                      Err(error) => return Err(error)
                    },
                  )
                  let uncertain = match
                    @workflow.record_goal_assurance_recovery_uncertain(record) {
                    Ok(value) => value
                    Err(error) => return Err(error)
                  }
                  ignore(
                    match
                      persist_native_goal_assurance_record(
                        repository,
                        adapters,
                        execution,
                        uncertain,
                        Some(stored.state_record.version),
                      ) {
                      Ok(value) => value
                      Err(error) => return Err(error)
                    },
                  )
                  return Ok(
                    @workflow.GoalAssuranceTickOutcome::GoalAssurancePending,
                  )
                }
                let value = match
                  execute_native_goal_assurance_effect_once(
                    repository, execution, git, record, intent,
                  ) {
                  Ok(value) => value
                  Err(error) => return Err(error)
                }
                let witnessed_at = @env.now().reinterpret_as_int64() / 1000L
                match
                  @workflow.record_goal_assurance_effect_witness(
                    repository, adapters, record, intent, value, witnessed_at,
                  ) {
                  Ok(_) => ()
                  Err(error) => return Err(error)
                }
                value
              }
            }
            let observed_at = match witness {
              Some(value) => value.observed_at
              None => @env.now().reinterpret_as_int64() / 1000L
            }
            let observed = match
              @workflow.apply_goal_assurance_effect_observation(
                record,
                observation,
                observed_at,
                fn(reference) {
                  native_part_artifact_exists(repository, reference)
                },
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = match
              persist_native_goal_assurance_record(
                repository,
                adapters,
                execution,
                observed,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            authorized_effect_id = None
            continue
          }
          Some(_) =>
            return Ok(@workflow.GoalAssuranceTickOutcome::GoalAssurancePending)
        }
      }
    }
  } nobreak {
    Err(native_goal_execution_error("Goal assurance exceeded its cycle bound"))
  }
}

///|
pub async fn run_native_goal_execution_tick_with_forge(
  project_dir : String,
  forge : NativePullRequestForgeAdapters,
  beads_capture? : async (Command) -> (Int, String) = capture_command_merged,
) -> Result[@workflow.GoalExecutionTickResult, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let repository_adapters = local_part_workflow_repository_adapters()
  match
    @workflow.initialize_part_workflow_repository(
      repository, repository_adapters,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  @workflow.run_next_goal_execution_tick(
    repository,
    repository_adapters,
    fencing_epoch=current_native_goal_fencing_epoch(),
    {
    initialize: async fn(record) {
      let claimed = match
        advance_native_goal_source_claims(
          project_dir,
          repository,
          repository_adapters,
          record.goal.id,
          capture=beads_capture,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !claimed {
        return Ok(false)
      }
      match
        advance_native_goal_branch_initialization(
          project_dir,
          repository,
          repository_adapters,
          record.goal.id,
        ) {
        Ok(@workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted) =>
          Ok(true)
        Ok(_) => Ok(false)
        Err(error) => Err(error)
      }
    },
    execute: async fn(record, snapshots) {
      execute_native_goal_record(project_dir, repository, record, snapshots)
    },
    assure: async fn(record, snapshots) {
      advance_native_goal_assurance(
        project_dir, repository, repository_adapters, record, snapshots,
      )
    },
    finalize: async fn(record, _) {
      match advance_native_goal_publication(project_dir, record.goal.id) {
        Ok(@workflow.GoalPublicationTickOutcome::GoalPublicationComplete) => ()
        Ok(
          @workflow.GoalPublicationTickOutcome::GoalPublicationRemoteUnavailable
        ) =>
          return Ok(
            @workflow.GoalFinalizationTickOutcome::GoalFinalizationPublicationRemoteUnavailable,
          )
        Ok(@workflow.GoalPublicationTickOutcome::GoalPublicationDrifted) =>
          return Ok(
            @workflow.GoalFinalizationTickOutcome::GoalFinalizationDrifted,
          )
        Ok(
          @workflow.GoalPublicationTickOutcome::GoalPublicationRecoveryUncertain
        ) =>
          return Ok(
            @workflow.GoalFinalizationTickOutcome::GoalFinalizationRecoveryUncertain,
          )
        Ok(_) =>
          return Ok(
            @workflow.GoalFinalizationTickOutcome::GoalFinalizationPending,
          )
        Err(error) => return Err(error)
      }
      match
        advance_native_goal_pull_request_with_adapters(
          project_dir,
          record.goal.id,
          forge,
        ) {
        Ok(@workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete) => ()
        Ok(@workflow.GoalPullRequestTickOutcome::GoalPullRequestNeedsUserInput) =>
          return Ok(
            @workflow.GoalFinalizationTickOutcome::GoalFinalizationNeedsUserInput,
          )
        Ok(
          @workflow.GoalPullRequestTickOutcome::GoalPullRequestRecoveryUncertain
        ) =>
          return Ok(
            @workflow.GoalFinalizationTickOutcome::GoalFinalizationRecoveryUncertain,
          )
        Ok(_) =>
          return Ok(
            @workflow.GoalFinalizationTickOutcome::GoalFinalizationPending,
          )
        Err(error) => return Err(error)
      }
      advance_native_goal_finalization_with_adapters(
        project_dir,
        record.goal.id,
        forge,
      )
    },
    cancel: async fn(record, snapshots) {
      let sources_known = match
        advance_native_goal_source_releases(
          project_dir,
          repository,
          repository_adapters,
          record.goal.id,
          capture=beads_capture,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !sources_known {
        return Ok(false)
      }
      let initialization = match
        advance_native_goal_branch_initialization(
          project_dir,
          repository,
          repository_adapters,
          record.goal.id,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let initialization_known = match initialization {
        @workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted
        | @workflow.GoalBranchInitLifecycle::GoalBranchInitIntegrityBlocked
        | @workflow.GoalBranchInitLifecycle::GoalBranchInitUncertain
        | @workflow.GoalBranchInitLifecycle::GoalBranchInitAbandonedByCancellation =>
          true
        _ => false
      }
      if !initialization_known ||
        record.branch_initialization.lifecycle != initialization {
        return Ok(false)
      }
      match
        reconcile_native_goal_part_cancellation(
          project_dir, repository, repository_adapters, record, snapshots, forge,
        ) {
        Ok((reconciled, finalization_known)) => {
          let terminal_ready = native_goal_cancellation_can_finish(reconciled) &&
            finalization_known
          finish_native_goal_runtime(terminal_ready, async fn() {
            cleanup_native_goal_runtime(record)
          })
        }
        Err(error) => Err(error)
      }
    },
  })
}

///|
pub async fn run_native_goal_execution_tick(
  project_dir : String,
) -> Result[@workflow.GoalExecutionTickResult, @types.ChoirError] {
  run_native_goal_execution_tick_with_forge(
    project_dir,
    native_pull_request_forge_adapters(),
  )
}

///|
fn native_goal_owned_git_ref_is_valid(reference : String) -> Bool {
  valid_git_ref(reference, "refs/heads/choir/goals/") ||
  valid_git_ref(reference, "refs/choir/goals/") ||
  valid_git_ref(reference, "refs/choir/witness/")
}

///|
fn append_native_goal_owned_git_ref(
  refs : Array[String],
  reference : String,
) -> Result[Unit, @types.ChoirError] {
  if !native_goal_owned_git_ref_is_valid(reference) {
    return Err(native_goal_execution_error("owned Git ref is invalid"))
  }
  if !refs.contains(reference) {
    refs.push(reference)
  }
  Ok(())
}

///|
fn native_goal_owned_git_refs(
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.GoalExecutionRecord,
) -> Result[Array[String], @types.ChoirError] {
  if record.goal_ref != @workflow.goal_execution_ref(record.goal.id) ||
    record.branch_initialization.goal_id != record.goal.id ||
    record.branch_initialization.goal_ref != record.goal_ref {
    return Err(native_goal_execution_error("Goal ref ownership is invalid"))
  }
  let adapters = local_part_workflow_repository_adapters()
  let refs : Array[String] = []
  match
    append_native_goal_owned_git_ref(
      refs,
      record.branch_initialization.initialization_witness_ref.0,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  for workflow_id in record.part_workflow_ids {
    let snapshot = match
      @workflow.load_part_snapshot(repository, adapters, workflow_id) {
      Ok(Some(value)) => value.snapshot
      Ok(None) =>
        return Err(native_goal_execution_error("Part disappeared during purge"))
      Err(error) => return Err(error)
    }
    if snapshot.goal.id != record.goal.id {
      return Err(native_goal_execution_error("Part Goal identity changed"))
    }
    match snapshot.integration_intent {
      Some(intent) => {
        if intent.goal_id != record.goal.id {
          return Err(
            native_goal_execution_error("integration Goal identity changed"),
          )
        }
        match append_native_goal_owned_git_ref(refs, intent.git_witness_ref) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      None => ()
    }
  }
  match
    @workflow.load_goal_assurance_record(repository, adapters, record.goal.id) {
    Ok(Some(stored)) => {
      if stored.record.goal_id != record.goal.id ||
        stored.record.goal_ref != record.goal_ref {
        return Err(
          native_goal_execution_error("assurance Goal identity changed"),
        )
      }
      match
        append_native_goal_owned_git_ref(
          refs,
          stored.record.seal_intent.seal_witness_ref,
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
    Ok(None) => ()
    Err(error) => return Err(error)
  }
  // Delete the live Goal ref last so a partial purge never leaves witnesses
  // without the branch they prove.
  match append_native_goal_owned_git_ref(refs, record.goal_ref.0) {
    Ok(_) => Ok(refs)
    Err(error) => Err(error)
  }
}

///|
async fn delete_native_goal_owned_git_ref(
  repository : NativeGoalRepositoryIdentity,
  reference : String,
) -> Result[Bool, @types.ChoirError] {
  if !native_goal_owned_git_ref_is_valid(reference) {
    return Err(native_goal_execution_error("owned Git ref is invalid"))
  }
  let observed = match
    capture_native_goal_git(repository.root, [
      "rev-parse", "--verify", "--quiet", reference,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if observed.exit_code == 1 {
    return Ok(false)
  }
  let oid = observed.output.trim().to_owned()
  if observed.exit_code != 0 || !valid_hex_oid_text(oid) {
    return Err(native_goal_execution_error("owned Git ref observation failed"))
  }
  let deleted = match
    capture_native_goal_git(repository.root, [
      "update-ref", "-d", reference, oid,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if deleted.exit_code == 0 {
    Ok(true)
  } else {
    Err(native_goal_execution_error("owned Git ref changed during purge"))
  }
}

///|
async fn inspect_native_orphaned_goal_source_claims(
  project_dir : String,
  capture : async (Command) -> (Int, String),
) -> Result[Array[NativeOrphanedGoalSourceClaim], @types.ChoirError] {
  let output = match
    native_conductor_capture_beads(
      project_dir,
      "list",
      ["list", "--json", "--all", "--readonly"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let tasks = match native_conductor_tasks_from_output(output) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let claims : Array[NativeOrphanedGoalSourceClaim] = []
  for task in tasks {
    if task.status != @types.TaskStatus::InProgress ||
      !task.assignee.has_prefix("choir:") {
      continue
    }
    let goal_id = task.assignee["choir:".length():].to_owned()
    if goal_id == "" || goal_id.contains("\u{00}") {
      return Err(
        native_goal_execution_error("orphaned Bead claim identity is invalid"),
      )
    }
    claims.push({
      part_id: @control.PartId(task.id),
      claimant: task.assignee,
      goal_id: @control.GoalId(goal_id),
    })
  }
  Ok(claims)
}

///|
async fn release_native_orphaned_goal_source_claims(
  project_dir : String,
  claims : Array[NativeOrphanedGoalSourceClaim],
  capture : async (Command) -> (Int, String),
) -> Result[Int, @types.ChoirError] {
  let mut released = 0
  for claim in claims {
    let output = match
      native_conductor_capture_beads(
        project_dir,
        "release",
        [
          "update",
          claim.part_id.0,
          "--status",
          "open",
          "--assignee",
          "",
          "--actor",
          claim.claimant,
          "--json",
        ],
        capture,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let task = match native_conductor_tasks_from_output(output) {
      Ok([value]) => value
      Ok(_) =>
        return Err(
          native_goal_execution_error(
            "Beads returned an ambiguous orphaned claim release",
          ),
        )
      Err(error) => return Err(error)
    }
    if task.id != claim.part_id.0 ||
      task.status != @types.TaskStatus::Todo ||
      task.assignee != "" {
      return Err(
        native_goal_execution_error(
          "Beads did not confirm the orphaned claim release",
        ),
      )
    }
    released = released + 1
  }
  Ok(released)
}

///|
async fn purge_native_goal_owned_git_ref_namespace(
  project_dir : String,
) -> Result[Int, @types.ChoirError] {
  let root = match
    native_goal_git_value(project_dir, ["rev-parse", "--show-toplevel"]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let canonical_root = match @sys.realpath_native(root) {
    Some(value) => value
    None =>
      return Err(native_goal_execution_error("repository is not canonical"))
  }
  let captured = match
    capture_native_goal_git(canonical_root, [
      "for-each-ref", "--format=%(refname)", "refs/heads/choir/goals/", "refs/choir/goals/",
      "refs/choir/witness/",
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if captured.exit_code != 0 {
    return Err(native_goal_execution_error("owned Git ref listing failed"))
  }
  let repository : NativeGoalRepositoryIdentity = {
    root: canonical_root,
    git_directory: "",
    object_directory: "",
  }
  let mut removed = 0
  for raw in captured.output.split("\n") {
    let reference = raw.trim().to_owned()
    if reference == "" {
      continue
    }
    if !native_goal_owned_git_ref_is_valid(reference) {
      return Err(native_goal_execution_error("owned Git ref is invalid"))
    }
    match delete_native_goal_owned_git_ref(repository, reference) {
      Ok(true) => removed = removed + 1
      Ok(false) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(removed)
}

///|
fn native_goal_control_state_is_current(
  generation : String,
  workflow_store_present : Bool,
) -> Bool {
  generation.trim() == native_goal_control_state_generation &&
  workflow_store_present
}

///|
test "control state generation requires both marker and store" {
  assert_true(
    native_goal_control_state_is_current(
      native_goal_control_state_generation, true,
    ),
  )
  assert_false(
    native_goal_control_state_is_current(
      native_goal_control_state_generation, false,
    ),
  )
  assert_false(native_goal_control_state_is_current("", true))
  assert_false(
    native_goal_control_state_is_current("choir-control-state-v2", true),
  )
  assert_false(
    native_goal_control_state_is_current("choir-control-state-v1", true),
  )
}

///|
pub async fn prepare_native_goal_control_state(
  project_dir : String,
  capture? : async (Command) -> (Int, String) = capture_command_merged,
) -> Result[NativeGoalControlStatePreparation, @types.ChoirError] {
  let control_root = project_dir + "/.choir/state/control"
  let generation_path = control_root + "/generation"
  let workflow_store_path = control_root + "/workflow.db"
  if native_goal_control_state_is_current(
      @sys.read_file(generation_path),
      @sys.path_entry_exists(workflow_store_path),
    ) {
    return Ok(NativeGoalControlStateCurrent)
  }
  let had_control_state = @sys.path_entry_exists(workflow_store_path) ||
    @sys.list_dir_all(control_root).length() > 0
  let claims = match
    inspect_native_orphaned_goal_source_claims(project_dir, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repository_id = match native_goal_repository_id(project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let goal_ids : Array[@control.GoalId] = []
  for claim in claims {
    if !goal_ids.contains(claim.goal_id) {
      goal_ids.push(claim.goal_id)
    }
  }
  let mut runtime_roots_removed = 0
  for goal_id in goal_ids {
    let runtime_root = native_goal_runtime_root(repository_id, goal_id)
    let existed = @sys.path_entry_exists(runtime_root)
    match cleanup_native_goal_runtime_identity(repository_id, goal_id) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    if existed {
      runtime_roots_removed = runtime_roots_removed + 1
    }
  }
  let git_refs_removed = match
    purge_native_goal_owned_git_ref_namespace(project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source_claims_released = match
    release_native_orphaned_goal_source_claims(project_dir, claims, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@sys.rm_rf(control_root) ||
    !@sys.create_dir_all(control_root) ||
    !@sys.write_file_atomic(
      generation_path,
      native_goal_control_state_generation + "\n",
    ) {
    return Err(native_goal_execution_error("control state reset failed"))
  }
  let report : NativeGoalControlStateResetReport = {
    source_claims_released,
    runtime_roots_removed,
    git_refs_removed,
  }
  if had_control_state ||
    source_claims_released > 0 ||
    runtime_roots_removed > 0 ||
    git_refs_removed > 0 {
    Ok(NativeGoalControlStateReset(report))
  } else {
    Ok(NativeGoalControlStateInitialized)
  }
}

///|
async test "orphaned claim reset releases only Choir-owned in-progress Beads" {
  let calls : Array[Array[String]] = []
  let capture = async fn(command : Command) {
    @async.sleep(0)
    calls.push(command.args)
    if command.args[0] == "list" {
      (
        0,
        (
          #|[{"id":"choir-owned","title":"Owned","status":"in_progress","assignee":"choir:goal-owned"},{"id":"human-owned","title":"Human","status":"in_progress","assignee":"justin"},{"id":"closed-owned","title":"Closed","status":"closed","assignee":"choir:goal-closed"}]
        ),
      )
    } else {
      (
        0,
        (
          #|[{"id":"choir-owned","title":"Owned","status":"open","assignee":""}]
        ),
      )
    }
  }
  let claims = inspect_native_orphaned_goal_source_claims("/repo", capture).unwrap()
  assert_eq(claims.length(), 1)
  assert_eq(claims[0].part_id, @control.PartId("choir-owned"))
  assert_eq(claims[0].goal_id, @control.GoalId("goal-owned"))
  assert_eq(
    release_native_orphaned_goal_source_claims("/repo", claims, capture).unwrap(),
    1,
  )
  assert_eq(calls.length(), 2)
  assert_eq(calls[1], [
    "update", "choir-owned", "--status", "open", "--assignee", "", "--actor", "choir:goal-owned",
    "--json",
  ])
}

///|
pub async fn purge_native_goal_resources(
  project_dir : String,
) -> Result[NativeGoalPurgeReport, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  if !@sys.path_exists(repository.state_store.path) {
    return Ok({ runtime_roots_removed: 0, git_refs_removed: 0 })
  }
  let records = match
    @workflow.list_goal_execution_records(
      repository,
      local_part_workflow_repository_adapters(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut runtime_roots_removed = 0
  let mut git_refs_removed = 0
  for stored in records {
    let runtime_root = native_goal_runtime_root(
      stored.record.repository_id,
      stored.record.goal.id,
    )
    if @sys.path_exists(runtime_root) {
      match cleanup_native_goal_runtime(stored.record) {
        Ok(_) => runtime_roots_removed = runtime_roots_removed + 1
        Err(error) => return Err(error)
      }
    }
    let refs = match native_goal_owned_git_refs(repository, stored.record) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let identity = match
      discover_native_goal_repository(project_dir, stored.record) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    for reference in refs {
      match delete_native_goal_owned_git_ref(identity, reference) {
        Ok(true) => git_refs_removed = git_refs_removed + 1
        Ok(false) => ()
        Err(error) => return Err(error)
      }
    }
  }
  Ok({ runtime_roots_removed, git_refs_removed })
}

///|
pub fn cancel_native_goal(
  project_dir : String,
  goal_id : @control.GoalId,
  requested_at : Int64,
) -> Result[@workflow.GoalCancellationPersistenceResult, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  @workflow.persist_goal_cancellation_request(
    repository, adapters, goal_id, requested_at,
  )
}

///|
pub fn steer_native_goal(
  project_dir : String,
  goal_id : @control.GoalId,
  change : @workflow.GoalPolicyChange,
) -> Result[@workflow.GoalSteeringPersistenceResult, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  @workflow.persist_goal_steering(repository, adapters, goal_id, change)
}

///|
fn native_goal_attach_evidence(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  reference : @control.ArtifactReference,
) -> Result[Json, @types.ChoirError] {
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: reference.digest,
      max_bytes: 4 * 1024 * 1024,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let evidence = @json.parse(@utf8.decode_lossy(content)) catch {
    _ =>
      return Err(
        native_goal_execution_error("verification evidence is invalid"),
      )
  }
  guard evidence is Object(fields) else {
    return Err(
      native_goal_execution_error("verification evidence is not an object"),
    )
  }
  guard fields.get("process_result") is Some(Object(process)) else {
    return Ok(evidence)
  }
  guard process.get("output_artifact") is Some(output_artifact_json) else {
    return Ok(evidence)
  }
  let output_artifact : @control.ArtifactReference = @json.from_json(
    output_artifact_json,
  ) catch {
    _ =>
      return Err(
        native_goal_execution_error(
          "verification output artifact reference is invalid",
        ),
      )
  }
  let output = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: output_artifact.digest,
      max_bytes: 2 * 1024 * 1024,
    }) {
    Ok(value) =>
      if @storage.artifact_digest(value) != output_artifact.digest {
        return Err(native_goal_execution_error("verification output changed"))
      } else {
        @utf8.decode_lossy(value)
      }
    Err(error) => return Err(error)
  }
  process.set("output", output.to_json())
  fields.set("process_result", process.to_json())
  Ok(fields.to_json())
}

///|
test "verification attach resolves durable process output" {
  let root = "/tmp/choir-verification-attach-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  let repository = native_goal_repository(root)
  let adapters = local_part_workflow_repository_adapters()
  assert_true(@sys.create_dir_all(root + "/.choir/state/control"))
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  let goal_id = @control.GoalId("goal-verification-attach")
  let output = "moon test failed\npackage dependency is unavailable"
  let output_content = @utf8.encode(output)
  let output_digest = @storage.artifact_digest(output_content)
  let output_adoption = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content: output_content,
      expected_digest: output_digest,
      provenance: @storage.ArtifactProvenance::ArtifactProcessExecution(goal_id),
      retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let output_reference : @control.ArtifactReference = {
    artifact_id: @storage.artifact_id_text(output_adoption.artifact_id),
    digest: output_digest,
  }
  let evidence_content = @utf8.encode(
    {
      "process_result": {
        "exit_code": (2).to_json(),
        "output_digest": output_digest.to_json(),
        "output_artifact": output_reference.to_json(),
      }.to_json(),
    }
    .to_json()
    .stringify(indent=0),
  )
  let evidence_digest = @storage.artifact_digest(evidence_content)
  let evidence_adoption = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content: evidence_content,
      expected_digest: evidence_digest,
      provenance: @storage.ArtifactProvenance::ArtifactProcessExecution(goal_id),
      retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  let evidence = match
    native_goal_attach_evidence(repository, adapters, {
      artifact_id: @storage.artifact_id_text(evidence_adoption.artifact_id),
      digest: evidence_digest,
    }) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard evidence is Object(fields) else {
    fail("verification evidence is not an object")
  }
  guard fields.get("process_result") is Some(Object(process)) else {
    fail("verification evidence has no process result")
  }
  assert_eq(process.get("output"), Some(output.to_json()))
  ignore(@sys.rm_rf(root))
}

///|
pub fn attach_native_goal(
  project_dir : String,
  take_id : @control.TakeId,
) -> Result[Json, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  if !@sys.path_entry_exists(repository.state_store.path) {
    return Err(native_goal_execution_error("Take is not registered"))
  }
  let adapters = local_part_workflow_repository_adapters()
  let records = match
    @workflow.list_goal_execution_records(repository, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut report : @workflow.GoalAttachReport? = None
  let evidence_references : Array[@control.ArtifactReference] = []
  for stored in records {
    let snapshots : Array[@workflow.PartWorkflowSnapshot] = []
    for workflow_id in stored.record.part_workflow_ids {
      match @workflow.load_part_snapshot(repository, adapters, workflow_id) {
        Ok(Some(value)) => snapshots.push(value.snapshot)
        Ok(None) =>
          return Err(native_goal_execution_error("Part is not registered"))
        Err(error) => return Err(error)
      }
    }
    let assurance = match
      @workflow.load_goal_assurance_record(
        repository,
        adapters,
        stored.record.goal.id,
      ) {
      Ok(Some(value)) => Some(value.record)
      Ok(None) => None
      Err(error) => return Err(error)
    }
    match
      @workflow.goal_attach_report(stored.record, snapshots, assurance, take_id) {
      Ok(Some(value)) =>
        if report is Some(_) {
          return Err(native_goal_execution_error("Take identity is ambiguous"))
        } else {
          report = Some(value)
          for snapshot in snapshots {
            if snapshot.verification_take.id == take_id {
              for receipt in snapshot.verification_receipts {
                if receipt.verification_take_id == take_id {
                  evidence_references.push(receipt.evidence)
                }
              }
            }
          }
          match assurance {
            Some(value) if value.verification_take.id == take_id =>
              for receipt in value.verification_receipts {
                if receipt.verification_take_id == take_id {
                  evidence_references.push(receipt.evidence)
                }
              }
            _ => ()
          }
        }
      Ok(None) => ()
      Err(error) => return Err(error)
    }
  }
  match report {
    Some(value) => {
      guard value.to_json() is Object(fields) else {
        return Err(
          native_goal_execution_error("attach report is not an object"),
        )
      }
      let evidence : Array[Json] = []
      for reference in evidence_references {
        evidence.push(
          match native_goal_attach_evidence(repository, adapters, reference) {
            Ok(value) => value
            Err(error) => return Err(error)
          },
        )
      }
      fields.set("verification_evidence", evidence.to_json())
      Ok(fields.to_json())
    }
    None => Err(native_goal_execution_error("Take is not registered"))
  }
}

///|
pub fn answer_native_goal_input(
  project_dir : String,
  request_id : @workflow.GoalInputRequestId,
  answer : String,
  answered_at : Int64,
) -> Result[@workflow.GoalInputAnswerPersistenceResult, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  if !@sys.path_entry_exists(repository.state_store.path) {
    return Err(native_goal_execution_error("input request is not registered"))
  }
  let adapters = local_part_workflow_repository_adapters()
  @workflow.persist_goal_input_answer(
    repository, adapters, request_id, answer, answered_at,
  )
}

///|
pub fn inspect_native_goal(
  project_dir : String,
  goal_id : @control.GoalId,
) -> Result[@workflow.GoalStatusReport, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  if !@sys.path_entry_exists(repository.state_store.path) {
    return Err(native_goal_execution_error("Goal is not registered"))
  }
  let adapters = local_part_workflow_repository_adapters()
  let record = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_goal_execution_error("Goal is not registered"))
    Err(error) => return Err(error)
  }
  let snapshots : Array[@workflow.PartWorkflowSnapshot] = []
  for workflow_id in record.part_workflow_ids {
    match @workflow.load_part_snapshot(repository, adapters, workflow_id) {
      Ok(Some(value)) => snapshots.push(value.snapshot)
      Ok(None) =>
        return Err(native_goal_execution_error("Part is not registered"))
      Err(error) => return Err(error)
    }
  }
  let assurance = match
    @workflow.load_goal_assurance_record(repository, adapters, goal_id) {
    Ok(Some(value)) => Some(value.record)
    Ok(None) => None
    Err(error) => return Err(error)
  }
  let publication = match
    @workflow.load_goal_publication_record(repository, adapters, goal_id) {
    Ok(Some(value)) => Some(value.record)
    Ok(None) => None
    Err(error) => return Err(error)
  }
  let pull_request = match
    @workflow.load_goal_pull_request_record(repository, adapters, goal_id) {
    Ok(Some(value)) => Some(value.record)
    Ok(None) => None
    Err(error) => return Err(error)
  }
  let finalization = match
    @workflow.load_goal_finalization_record(repository, adapters, goal_id) {
    Ok(Some(value)) => Some(value.record)
    Ok(None) => None
    Err(error) => return Err(error)
  }
  @workflow.goal_status_report(
    record, snapshots, assurance, publication, pull_request, finalization,
  )
}

///|
pub fn inspect_native_goal_for_part(
  project_dir : String,
  part_id : @control.PartId,
) -> Result[@workflow.GoalStatusReport, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  if !@sys.path_entry_exists(repository.state_store.path) {
    return Err(
      native_goal_execution_error("no Goal is registered for this Part"),
    )
  }
  let adapters = local_part_workflow_repository_adapters()
  let records = match
    @workflow.list_goal_execution_records(repository, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let active : Array[@control.GoalId] = []
  let mut latest_terminal : (@control.GoalId, Int64)? = None
  let mut terminal_timestamp_is_ambiguous = false
  for stored in records {
    let mut selected_at = 0L
    let owns_part = stored.record.source_claims.any(fn(claim) {
      if claim.part_id != part_id {
        false
      } else {
        match claim.receipt {
          Some(receipt) => selected_at = receipt.observed_at
          None => ()
        }
        true
      }
    })
    if !owns_part {
      continue
    }
    if !@workflow.goal_execution_is_terminal(stored.record) {
      active.push(stored.record.goal.id)
      continue
    }
    match latest_terminal {
      None => {
        latest_terminal = Some((stored.record.goal.id, selected_at))
        terminal_timestamp_is_ambiguous = false
      }
      Some((_, latest_at)) if selected_at > latest_at => {
        latest_terminal = Some((stored.record.goal.id, selected_at))
        terminal_timestamp_is_ambiguous = false
      }
      Some((_, latest_at)) if selected_at == latest_at =>
        terminal_timestamp_is_ambiguous = true
      _ => ()
    }
  }
  match active {
    [goal_id] => inspect_native_goal(project_dir, goal_id)
    [] =>
      match latest_terminal {
        Some((goal_id, _)) if !terminal_timestamp_is_ambiguous =>
          inspect_native_goal(project_dir, goal_id)
        Some(_) =>
          Err(
            native_goal_execution_error(
              "multiple historical Goals for this Part are equally recent",
            ),
          )
        None =>
          Err(
            native_goal_execution_error("no Goal is registered for this Part"),
          )
      }
    _ =>
      Err(
        native_goal_execution_error(
          "multiple active Goals own this Part; durable state is inconsistent",
        ),
      )
  }
}

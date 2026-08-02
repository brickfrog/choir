///|
priv struct NativeGoalRepositoryIdentity {
  root : String
  git_directory : String
  object_directory : String
}

///|
pub(all) struct NativeGoalPurgeReport {
  source_claims_released : Int
  runtime_roots_removed : Int
  git_refs_removed : Int
} derive(Debug, Eq)

///|
/// What a reset destroyed, and the evidence that authorized it. The reason
/// travels with the report because this is the one path that deletes durable
/// state: an operator who finds the control root gone is told which record
/// could not be read, not merely that a generation moved.
pub(all) struct NativeGoalControlStateResetReport {
  source_claims_released : Int
  runtime_roots_removed : Int
  git_refs_removed : Int
  reason : @storage.ControlStateResetReason
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
priv struct NativeGoalPartRuntime {
  snapshot : @workflow.PartWorkflowSnapshot
  runtime : @part_host.NativePartEffectRuntime
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
    max_snapshot_bytes: native_goal_max_snapshot_bytes(),
  }
}

///|
/// The largest durable record this build will read back.
fn native_goal_max_snapshot_bytes() -> Int {
  4 * 1024 * 1024
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
  let epoch = match @storage_host.mint_state_store_epoch(store) {
    Ok(value) => value
    Err(_) =>
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
  let epoch = match @storage_host.read_state_store_epoch(store) {
    Ok(value) => value
    Err(_) =>
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
) -> Result[@git_integration.NativeGitCapture, @types.ChoirError] {
  let environment = @git_host.native_git_environment(false)
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
  let expected_repository_id = @workflow.repository_id(canonical_root)
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
) -> @git_integration.NativeGitIntegrationConfig {
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
  config : @git_integration.NativeGitIntegrationConfig,
  reference : String,
) -> Result[@control.GitOid?, @types.ChoirError] {
  let adapters = @git_host.native_git_integration_adapters()
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
  config : @git_integration.NativeGitIntegrationConfig,
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
  config : @git_integration.NativeGitIntegrationConfig,
  initialization : @workflow.GoalBranchInitialization,
) -> Result[Unit, @types.ChoirError] {
  let zero = if initialization.captured_base_oid.0.length() == 64 {
    @control.GitOid(
      "0000000000000000000000000000000000000000000000000000000000000000",
    )
  } else {
    @control.GitOid("0000000000000000000000000000000000000000")
  }
  let adapters = @git_host.native_git_integration_adapters()
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
    usage: None,
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
    repair_audit: None,
    repair_verification: None,
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
    @process_host.native_path_is_nfc,
  )
}

///|
fn adopt_native_audit_repair_instruction(
  repository : @workflow.PartWorkflowRepository,
  revision_id : @control.RevisionId,
  goal_id : @control.GoalId,
  previous : @control.ArtifactReference,
  assigned_paths : Array[@control.RepoPath],
  audit_output : String,
) -> Result[@control.ArtifactReference, @types.ChoirError] {
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  let original = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: previous.digest,
      max_bytes: 1048576,
    }) {
    Ok(value) => @utf8.decode_lossy(value)
    Err(error) => return Err(error)
  }
  let paths = assigned_paths.map(@control.repo_path_text)
  let content = @utf8.encode(
    original +
    "\n\nAutonomous audit repair\n\nRepair the blocking findings below only where they affect these assigned paths: " +
    paths.join(", ") +
    ". Sibling repair Takes own findings assigned to other paths. Stay within the mutation declaration. Do not merely explain the finding; change the implementation, run the declared verification, and leave the sandbox with a candidate commit.\n\n" +
    audit_output,
  )
  let digest = @storage.artifact_digest(content)
  let receipt = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactTaskInstruction(
        revision_id,
      ),
      retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if receipt.digest != digest || receipt.byte_length != content.length() {
    return Err(native_goal_execution_error("audit repair instruction is false"))
  }
  Ok({ artifact_id: @storage.artifact_id_text(receipt.artifact_id), digest })
}

///|
fn plan_native_audit_repair_attempt(
  repository : @workflow.PartWorkflowRepository,
  snapshot : @workflow.PartWorkflowSnapshot,
  repair : @control.AuditRepairReference,
  terminal_response : String,
  source : @workflow.PartRepairSource,
) -> Result[@workflow.PartAuditRepairDecision, @types.ChoirError] {
  let repair_number = snapshot.task_contract_history.fold(init=1, fn(
    count,
    contract,
  ) {
    if contract.repair_audit is Some(_) {
      count + 1
    } else {
      count
    }
  })
  let identity_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.native-part-audit-repair.v1\u{00}" +
      [
        snapshot.task_contract.digest.to_json(),
        repair.to_json(),
        repair_number.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
  let key = @storage.digest_text(identity_digest)[:20].to_owned()
  let revision_id = @control.RevisionId("audit-repair-" + key)
  let instruction = match
    adopt_native_audit_repair_instruction(
      repository,
      revision_id,
      snapshot.goal.id,
      snapshot.task_contract.instruction_artifact,
      repair.affected_paths,
      terminal_response,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let contract_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.task-contract-audit-repair.v1\u{00}" +
      [
        revision_id.to_json(),
        snapshot.goal.id.to_json(),
        snapshot.part.id.to_json(),
        (snapshot.task_contract.revision + 1).to_json(),
        repair.to_json(),
        instruction.to_json(),
        source.commit_oid.to_json(),
        source.tree_oid.to_json(),
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
    repair_conflict_id: None,
    repair_audit: Some(repair),
    repair_verification: None,
    instruction_artifact: instruction,
    base_commit_oid: source.commit_oid,
    base_tree_oid: source.tree_oid,
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
  @workflow.plan_part_audit_repair(
    snapshot,
    repair,
    source,
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
    @process_host.native_path_is_nfc,
  )
}

///|
fn plan_native_part_audit_repair(
  repository : @workflow.PartWorkflowRepository,
  snapshot : @workflow.PartWorkflowSnapshot,
) -> Result[@workflow.PartAuditRepairDecision, @types.ChoirError] {
  let result = match snapshot.audit_result {
    Some(value) => value
    None =>
      return Err(native_goal_execution_error("Part audit result is absent"))
  }
  let findings_artifact = match result.findings_artifact {
    Some(value) => value
    None =>
      return Err(native_goal_execution_error("Part audit findings are absent"))
  }
  let bytes = match
    (@storage_host.local_part_workflow_repository_adapters().artifacts.read)(
      repository.artifact_store,
      { digest: findings_artifact.digest, max_bytes: 1048576 },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let terminal_response = @utf8.decode_lossy(bytes)
  let affected_paths = match
    @provider_host.native_blocking_audit_repair_paths(
      terminal_response,
      result.total_findings_count,
      result.blocking_findings_count,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repair : @control.AuditRepairReference = {
    scope: @control.AuditRepairScope::PartAuditRepair,
    audit_result_id: result.id,
    audit_result_digest: result.result_digest,
    findings_artifact,
    affected_paths,
  }
  plan_native_audit_repair_attempt(
    repository,
    snapshot,
    repair,
    terminal_response,
    {
      commit_oid: result.subject.candidate_commit_oid,
      tree_oid: result.subject.candidate_tree_oid,
    },
  )
}

///|
fn adopt_native_verification_repair_instruction(
  repository : @workflow.PartWorkflowRepository,
  revision_id : @control.RevisionId,
  goal_id : @control.GoalId,
  previous : @control.ArtifactReference,
  verification_evidence : String,
) -> Result[@control.ArtifactReference, @types.ChoirError] {
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  let original = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: previous.digest,
      max_bytes: 1048576,
    }) {
    Ok(value) => @utf8.decode_lossy(value)
    Err(error) => return Err(error)
  }
  let content = @utf8.encode(
    original +
    "\n\nAutonomous verification repair\n\nThe preceding candidate did not pass its declared verification. Diagnose the durable evidence below, repair the implementation only within the existing mutation declaration, rerun the declared verification, and leave the sandbox with a new candidate commit. Do not ask for user input, weaken or remove the verification, conceal the failure, or change paths outside the mutation declaration. If the evidence reflects a transient execution failure, reproduce the verification before deciding whether code must change.\n\n" +
    verification_evidence,
  )
  let digest = @storage.artifact_digest(content)
  let receipt = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance: @storage.ArtifactProvenance::ArtifactTaskInstruction(
        revision_id,
      ),
      retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if receipt.digest != digest || receipt.byte_length != content.length() {
    return Err(
      native_goal_execution_error("verification repair instruction is false"),
    )
  }
  Ok({ artifact_id: @storage.artifact_id_text(receipt.artifact_id), digest })
}

///|
fn plan_native_verification_repair_attempt(
  repository : @workflow.PartWorkflowRepository,
  snapshot : @workflow.PartWorkflowSnapshot,
  repair : @control.VerificationRepairReference,
  verification_evidence : String,
  source : @workflow.PartRepairSource,
) -> Result[@workflow.PartVerificationRepairDecision, @types.ChoirError] {
  let repair_number = snapshot.task_contract_history.fold(init=1, fn(
    count,
    contract,
  ) {
    if contract.repair_verification is Some(_) {
      count + 1
    } else {
      count
    }
  })
  let identity_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.native-part-verification-repair.v1\u{00}" +
      [
        snapshot.task_contract.digest.to_json(),
        repair.to_json(),
        repair_number.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
  let key = @storage.digest_text(identity_digest)[:20].to_owned()
  let revision_id = @control.RevisionId("verification-repair-" + key)
  let instruction = match
    adopt_native_verification_repair_instruction(
      repository,
      revision_id,
      snapshot.goal.id,
      snapshot.task_contract.instruction_artifact,
      verification_evidence,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let contract_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.task-contract-verification-repair.v1\u{00}" +
      [
        revision_id.to_json(),
        snapshot.goal.id.to_json(),
        snapshot.part.id.to_json(),
        (snapshot.task_contract.revision + 1).to_json(),
        repair.to_json(),
        instruction.to_json(),
        source.commit_oid.to_json(),
        source.tree_oid.to_json(),
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
    repair_conflict_id: None,
    repair_audit: None,
    repair_verification: Some(repair),
    instruction_artifact: instruction,
    base_commit_oid: source.commit_oid,
    base_tree_oid: source.tree_oid,
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
  @workflow.plan_part_verification_repair(
    snapshot,
    repair,
    source,
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
    @process_host.native_path_is_nfc,
  )
}

///|
fn plan_native_part_verification_repair(
  repository : @workflow.PartWorkflowRepository,
  snapshot : @workflow.PartWorkflowSnapshot,
) -> Result[@workflow.PartVerificationRepairDecision, @types.ChoirError] {
  let mut failed : @control.VerificationReceipt? = None
  for receipt in snapshot.verification_receipts {
    if receipt.subject.task_contract_revision_id == snapshot.task_contract.id &&
      receipt.subject.part_id == snapshot.part.id &&
      receipt.outcome != @control.VerificationOutcome::VerificationPassed {
      failed = Some(receipt)
    }
  }
  let receipt = match failed {
    Some(value) => value
    None =>
      return Ok(
        @workflow.PartVerificationRepairDecision::PartVerificationRepairLimitReached,
      )
  }
  let bytes = match
    (@storage_host.local_part_workflow_repository_adapters().artifacts.read)(
      repository.artifact_store,
      { digest: receipt.evidence.digest, max_bytes: 4194304 },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repair : @control.VerificationRepairReference = {
    scope: @control.VerificationRepairScope::PartVerificationRepair,
    receipt_id: receipt.receipt_id,
    verification_execution_id: receipt.verification_execution_id,
    subject_digest: receipt.subject.subject_digest,
    verification_spec: receipt.verification_spec,
    evidence_artifact: receipt.evidence,
    affected_paths: [],
  }
  plan_native_verification_repair_attempt(
    repository,
    snapshot,
    repair,
    @utf8.decode_lossy(bytes),
    {
      commit_oid: receipt.subject.candidate_commit_oid,
      tree_oid: receipt.subject.candidate_tree_oid,
    },
  )
}

///|
/// Fresh Take, sandbox, and session identities for re-arming a Part under its
/// existing task contract, on the surface the control plane selected.
///
/// The identities are a pure derivation from the task contract, the Part, the
/// retry ordinal, and that surface. A restart between planning and persistence
/// therefore re-derives the same plan whenever it selects the same surface —
/// but the failover decision reads the clock, so a restart after a deferral
/// window expired can select a different surface and derive different
/// identities. What keeps that from leaking a second set of live identities is
/// not the derivation: every re-armed Part is written under
/// `expected_store_version` in `persist_bound_part_repair`, so at most one of
/// those plans can ever commit.
fn native_part_retry_identity_plan(
  snapshot : @workflow.PartWorkflowSnapshot,
  surface : @control.ProviderSurfaceId,
) -> @workflow.PartIdentityPlan {
  let retry_number = snapshot.prior_takes.length() / 3 + 1
  let identity_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.native-goal-part-retry.v1\u{00}" +
      [
        snapshot.task_contract.digest.to_json(),
        snapshot.part.id.to_json(),
        retry_number.to_json(),
        surface.to_json(),
      ]
      .to_json()
      .stringify(indent=0),
    ),
  )
  let key = @storage.digest_text(identity_digest)[:20].to_owned()
  let implementation = native_goal_conflict_repair_take(
    "take-" + key + "-implementation",
    snapshot.implementation_take,
    @control.TakePurpose::Implementation(
      snapshot.part.id,
      snapshot.task_contract.id,
    ),
  )
  let verification = native_goal_conflict_repair_take(
    "take-" + key + "-verification",
    snapshot.verification_take,
    @control.TakePurpose::PartVerification(
      snapshot.part.id,
      implementation.id,
      snapshot.task_contract.verification_specs[0].digest,
    ),
  )
  let audit = native_goal_conflict_repair_take(
    "take-" + key + "-audit",
    snapshot.audit_take,
    @control.TakePurpose::PartAudit(
      snapshot.part.id,
      implementation.id,
      snapshot.task_contract.audit_policy_digest,
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
  // The session is built for the selected surface rather than copied from the
  // previous one. A Part that moved to another admitted surface needs that
  // surface's own manifest digest and cursor class; on an unchanged surface
  // this recomputes exactly what submission minted, unless this binary's tool
  // manifest has since changed — and then recomputing is the only thing that
  // can dispatch at all, because neither driver will accept a session whose
  // manifest digest disagrees with the one it derives. Codex checks before
  // dispatch and refuses to launch; Claude checks at ingestion, against the
  // manifest the provider reported, so its Take runs and is then rejected.
  // Either way a stale copied digest cannot yield a usable Take.
  {
    implementation_take: implementation,
    implementation_sandbox,
    implementation_session: native_goal_submission_session(
      "session-" + key + "-implementation",
      implementation,
      implementation_sandbox,
      surface,
    ),
    verification_take: verification,
    verification_sandbox,
    audit_take: audit,
    audit_sandbox,
    audit_session: native_goal_submission_session(
      "session-" + key + "-audit",
      audit,
      audit_sandbox,
      surface,
    ),
  }
}

///|
/// The smallest Part the retry identity plan accepts: accepted on `surface`,
/// admitted under both surfaces, and derived without touching the host.
fn native_retry_identity_fixture(
  surface : @control.ProviderSurfaceId,
  failover : @control.ProviderSurfaceId,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  let goal_id = @control.GoalId("goal-retry-identity")
  let part_id = @control.PartId("part-retry-identity")
  let revision_id = @control.RevisionId("revision-retry-identity")
  let digest = fn(text) { @storage.artifact_digest(@utf8.encode(text)) }
  let contract : @control.TaskContractRevision = {
    id: revision_id,
    goal_id,
    part_id,
    revision: 1,
    digest: digest("retry-identity-contract"),
    commit_title: @control.SemanticCommitTitle("fix: re-arm the Part"),
    repair_conflict_id: None,
    repair_audit: None,
    repair_verification: None,
    instruction_artifact: {
      artifact_id: "instruction-retry-identity",
      digest: digest("retry-identity-instruction"),
    },
    base_commit_oid: @control.GitOid("retry-identity-base-commit"),
    base_tree_oid: @control.GitOid("retry-identity-base-tree"),
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(@control.RepoPath("src/answer.mbt")),
      ],
    ),
    verification_specs: [
      {
        id: @control.VerificationSpecId("verify-retry-identity"),
        version: 1,
        digest: digest("retry-identity-verification-spec"),
        process_spec_digest: digest("retry-identity-verification-process"),
      },
    ],
    audit_policy_digest: digest("retry-identity-audit-policy"),
    migration_contract_ref: None,
    migration_continuation_ref_digest: None,
    implementation_capability_profile_digest: digest(
      "retry-identity-implementation-profile",
    ),
    verification_capability_profile_digest: digest(
      "retry-identity-verification-profile",
    ),
    audit_capability_profile_digest: digest("retry-identity-audit-profile"),
  }
  native_goal_submission_part_snapshot(
    {
      id: goal_id,
      contract_digest: digest("retry-identity-goal-contract"),
      lifecycle: @control.GoalLifecycle::GoalActive(
        @control.GoalActiveCondition::GoalRunning,
      ),
    },
    {
      part: {
        id: part_id,
        goal_id,
        dependency_ids: [],
        task_contract_revision_id: revision_id,
        lifecycle: @control.PartLifecycle::PartPending,
      },
      source_revision_digest: digest("retry-identity-source-revision"),
      source_content_digest: digest("retry-identity-source-content"),
      task_contract: contract,
      provider_surface: surface,
      provider_failover_surfaces: [failover],
      part_context_manifest: None,
    },
    fn(_) { true },
    @control.FencingEpoch(1L),
  )
}

///|
test "a re-armed Part is planned on the surface it was told to run on" {
  let claude = @control.ProviderSurfaceId::ClaudeSubscriptionCli
  let codex = @control.ProviderSurfaceId::CodexSubscriptionCli
  let on_claude = match native_retry_identity_fixture(claude, codex) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  // An ordinary recovery stays where the Part already is, and rebuilding the
  // session there reproduces exactly what submission minted. Neither driver
  // accepts a session whose digest disagrees with the one it derives — Codex
  // before dispatch, Claude at ingestion — so a plan that reproduced anything
  // else could not yield a usable Take.
  let same = native_part_retry_identity_plan(on_claude, claude)
  assert_eq(same.implementation_session.surface, claude)
  assert_eq(same.audit_session.surface, claude)
  assert_eq(
    same.implementation_session.effective_surface_manifest_digest,
    on_claude.identities.implementation_session.effective_surface_manifest_digest,
  )
  assert_eq(
    same.audit_session.effective_surface_manifest_digest,
    on_claude.identities.audit_session.effective_surface_manifest_digest,
  )
  assert_eq(
    same.implementation_session.cursor_class,
    @control.HarnessCursorClass::HarnessCursorNotResumable,
  )
  // A failover target is honored: the host mints identities for the surface
  // the control plane selected, never for the one the Part is leaving. The
  // control plane refuses any plan that came back on another surface, so a
  // host that ignored this argument would turn every failover into an error
  // instead of a move.
  let moved = native_part_retry_identity_plan(on_claude, codex)
  assert_eq(moved.implementation_session.surface, codex)
  assert_eq(moved.audit_session.surface, codex)
  assert_eq(
    moved.implementation_session.cursor_class,
    @control.HarnessCursorClass::HarnessCursorProviderEventId,
  )
  assert_true(
    moved.implementation_session.effective_surface_manifest_digest !=
    same.implementation_session.effective_surface_manifest_digest,
  )
  // The surface feeds the identity digest, so the two plans are distinct Takes
  // rather than one Take pointed at a different provider.
  assert_true(moved.implementation_take.id != same.implementation_take.id)
  assert_true(moved.audit_take.id != same.audit_take.id)
  assert_true(
    moved.implementation_sandbox.generation_id !=
    same.implementation_sandbox.generation_id,
  )
}

///|
/// Unattended recovery from provider loss: discharge an effect that left no
/// artifact and re-arm the Part in the same tick. Without this the Goal worker
/// only ever parked the Part and waited for an operator `retry_part`.
fn plan_native_part_recovery_retry(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> Result[@workflow.PartRecoveryRetryDecision, @types.ChoirError] {
  if snapshot.part.lifecycle
    is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartOwnershipViolation
    ) {
    return match
      @workflow.plan_part_ownership_repair(
        snapshot,
        native_part_retry_identity_plan(
          snapshot,
          snapshot.identities.implementation_session.surface,
        ),
        @process_host.native_path_is_nfc,
      ) {
      Ok(
        @workflow.PartOwnershipRepairDecision::PartOwnershipRepairPlanned(value)
      ) =>
        Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryPlanned(value))
      Ok(@workflow.PartOwnershipRepairDecision::PartOwnershipRepairLimitReached) =>
        Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryLimitReached)
      Err(error) => Err(error)
    }
  }
  @workflow.plan_part_recovery_retry(
    snapshot,
    fn(surface) { native_part_retry_identity_plan(snapshot, surface) },
    @process_host.native_path_is_nfc,
    now=@env.now().reinterpret_as_int64() / 1000L,
  )
}

///|
/// User-requested retry for a blocked Part: re-arm the Part workflow with
/// fresh Take identities under the same task contract, then return the
/// blocked Goal to Running so the scheduler dispatches the fresh Take.
pub fn retry_native_goal_part(
  project_dir : String,
  goal_id : @control.GoalId,
  part_id : @control.PartId?,
) -> Result[@workflow.GoalExecutionRecord, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let stored = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_goal_execution_error("Goal is not registered"))
    Err(error) => return Err(error)
  }
  if stored.record.state != @workflow.GoalExecutionState::GoalExecutionBlocked {
    return Err(native_goal_execution_error("Goal is not blocked"))
  }
  // A Part parked on provider-dispatch uncertainty reports as blocked through
  // its lifecycle but carries the PartRecoveryUncertain stage, so selecting on
  // stage alone hid it from retry entirely: status said "blocked", retry said
  // "no Part is blocked", and the Part had no way forward. Reconcile those
  // first, which discharges the ones whose effect left no artifact behind and
  // leaves the rest parked with their uncertainty intact.
  let blocked : Array[@workflow.PartStoredSnapshot] = []
  let mut retained_uncertain = 0
  for workflow_id in stored.record.part_workflow_ids {
    match @workflow.load_part_snapshot(repository, adapters, workflow_id) {
      Ok(Some(part)) =>
        match part.snapshot.stage {
          @workflow.PartWorkflowStage::PartBlocked => blocked.push(part)
          @workflow.PartWorkflowStage::PartRecoveryUncertain =>
            match @workflow.reconcile_part_recovery_uncertainty(part.snapshot) {
              Ok(
                @workflow.PartUncertaintyReconciliation::PartUncertaintyDischarged(
                  discharged
                )
              ) => {
                match
                  @workflow.persist_part_snapshot(repository, adapters, {
                    snapshot: discharged,
                    expected_store_version: Some(part.state_record.version),
                    fault_point: None,
                  }) {
                  Ok(_) => ()
                  Err(error) => return Err(error)
                }
                match
                  @workflow.load_part_snapshot(
                    repository, adapters, workflow_id,
                  ) {
                  Ok(Some(reloaded)) => blocked.push(reloaded)
                  Ok(None) =>
                    return Err(
                      native_goal_execution_error("Part workflow is absent"),
                    )
                  Err(error) => return Err(error)
                }
              }
              Ok(
                @workflow.PartUncertaintyReconciliation::PartUncertaintyRetained
              ) => retained_uncertain = retained_uncertain + 1
              Err(error) => return Err(error)
            }
          _ => ()
        }
      Ok(None) =>
        return Err(native_goal_execution_error("Part workflow is absent"))
      Err(error) => return Err(error)
    }
  }
  let selected = match part_id {
    Some(id) => {
      let mut found : @workflow.PartStoredSnapshot? = None
      for part in blocked {
        if part.snapshot.part.id == id {
          found = Some(part)
        }
      }
      match found {
        Some(value) => value
        None =>
          return Err(
            native_goal_execution_error(
              "Part '" + id.0 + "' is not blocked in this Goal",
            ),
          )
      }
    }
    None =>
      match blocked {
        [single] => single
        [] =>
          if retained_uncertain > 0 {
            return Err(
              native_goal_execution_error(
                "every blocked Part is parked on an effect that may have occurred; retry cannot decide this",
              ),
            )
          } else {
            return Err(native_goal_execution_error("no Part is blocked"))
          }
        _ =>
          return Err(
            native_goal_execution_error(
              "several Parts are blocked; name the part_id to retry",
            ),
          )
      }
  }
  let snapshot = selected.snapshot
  let retried = match
    @workflow.plan_part_retry(
      snapshot,
      // An operator retry re-arms the Part; it does not move it to another
      // provider. Only a recorded failover decision changes the surface.
      native_part_retry_identity_plan(
        snapshot,
        snapshot.identities.implementation_session.surface,
      ),
      @process_host.native_path_is_nfc,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: retried,
      expected_store_version: Some(selected.state_record.version),
      fault_point: None,
    }) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let running = match
    @workflow.advance_goal_execution_state(
      stored.record,
      @workflow.GoalExecutionState::GoalExecutionRunning,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    @workflow.persist_goal_execution_transition(
      repository, adapters, stored, running,
    ) {
    Ok(value) => Ok(value.record)
    Err(error) => Err(error)
  }
}

///|
fn native_goal_runtime_key(
  repository_id : @workflow.RepositoryId,
  goal_id : @control.GoalId,
) -> String {
  @storage.artifact_digest(@utf8.encode(repository_id.0 + "\u{00}" + goal_id.0)).0[:20].to_owned()
}

///|
fn native_goal_repository_runtime_key(
  repository_id : @workflow.RepositoryId,
) -> String {
  @storage.artifact_digest(@utf8.encode(repository_id.0)).0[:20].to_owned()
}

///|
fn native_goal_runtime_entry_prefix(
  repository_id : @workflow.RepositoryId,
) -> String {
  "choir-take-goal-" + native_goal_repository_runtime_key(repository_id) + "-"
}

///|
fn native_goal_runtime_root(
  repository_id : @workflow.RepositoryId,
  goal_id : @control.GoalId,
) -> String {
  "/tmp/" +
  native_goal_runtime_entry_prefix(repository_id) +
  native_goal_runtime_key(repository_id, goal_id)
}

///|
priv struct NativeGoalRuntimeOwnershipReceipt {
  version : Int
  repository_id : @workflow.RepositoryId
  goal_id : @control.GoalId
  base_box_id : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
fn native_goal_runtime_owner_path(root : String) -> String {
  root + "/state/owner.json"
}

///|
fn native_goal_runtime_receipt(
  repository_id : @workflow.RepositoryId,
  goal_id : @control.GoalId,
  base_box_id : String?,
) -> NativeGoalRuntimeOwnershipReceipt {
  { version: 1, repository_id, goal_id, base_box_id }
}

///|
fn write_native_goal_runtime_receipt(
  root : String,
  receipt : NativeGoalRuntimeOwnershipReceipt,
) -> Result[Unit, @types.ChoirError] {
  let state = root + "/state"
  if !@sys.create_dir_all(state) || @sys.realpath_native(root) != Some(root) {
    return Err(
      native_goal_execution_error("runtime ownership root is unavailable"),
    )
  }
  let content = ToJson::to_json(receipt).stringify(indent=0) + "\n"
  let path = native_goal_runtime_owner_path(root)
  if !@sys.write_file_atomic(path, content) || @sys.read_file(path) != content {
    return Err(native_goal_execution_error("runtime ownership receipt failed"))
  }
  Ok(())
}

///|
fn read_native_goal_runtime_receipt(
  root : String,
) -> NativeGoalRuntimeOwnershipReceipt? {
  if @sys.realpath_native(root) != Some(root) {
    return None
  }
  let json = @json.parse(@sys.read_file(native_goal_runtime_owner_path(root))) catch {
    _ => return None
  }
  let receipt : NativeGoalRuntimeOwnershipReceipt = @json.from_json(json) catch {
    _ => return None
  }
  let invalid_base = match receipt.base_box_id {
    Some(value) => !@sandbox.valid_boxlite_state_token(value)
    None => false
  }
  let expected_entry = native_goal_runtime_entry_prefix(receipt.repository_id) +
    native_goal_runtime_key(receipt.repository_id, receipt.goal_id)
  if receipt.version != 1 ||
    !root.has_suffix("/" + expected_entry) ||
    invalid_base {
    None
  } else {
    Some(receipt)
  }
}

///|
test "runtime ownership receipt binds one canonical repository and Goal" {
  let repository = @workflow.RepositoryId("receipt-test-repository")
  let goal = @control.GoalId("receipt-test-goal")
  let root = native_goal_runtime_root(repository, goal)
  ignore(@sys.rm_rf(root))
  assert_true(@sys.create_dir_all(root))
  write_native_goal_runtime_receipt(
    root,
    native_goal_runtime_receipt(repository, goal, Some("base-owned")),
  ).unwrap()
  assert_eq(
    read_native_goal_runtime_receipt(root),
    Some(native_goal_runtime_receipt(repository, goal, Some("base-owned"))),
  )
  assert_true(
    @sys.write_file_atomic(native_goal_runtime_owner_path(root), "{}\n"),
  )
  assert_eq(read_native_goal_runtime_receipt(root), None)
  ignore(@sys.rm_rf(root))
}

///|
/// Which Goal runtime roots under the temporary directory use this repository's
/// namespace. The pure workflow policy decides whether each owner is live.
///
/// Reclaiming by Bead claim alone misses every Goal whose claim was already
/// released, so an abandoned root survived until the machine rebooted. These
/// roots hold a BoxLite home and a staged toolchain, so a handful of them is
/// gigabytes; on a tmpfs that is memory. Matching on the exact root shape and
/// matching the repository namespace keeps the host enumeration separate from
/// the durable lifecycle decision.
pub fn native_repository_goal_runtime_roots(
  repository_id : @workflow.RepositoryId,
  entries : Array[String],
) -> Array[String] {
  let owned : Array[String] = []
  let prefix = native_goal_runtime_entry_prefix(repository_id)
  for entry in entries {
    if !entry.has_prefix(prefix) {
      continue
    }
    let key = entry[prefix.length():].to_owned()
    if key == "" || key.contains("/") {
      continue
    }
    owned.push(entry)
  }
  owned
}

///|
test "a runtime sweep only selects its repository namespace" {
  let repository = @workflow.RepositoryId("repo-a")
  let prefix = native_goal_runtime_entry_prefix(repository)
  let entries = [
    prefix + "live",
    prefix + "dead",
    prefix,
    "choir-take-goal-foreign-dead",
    "unrelated",
    prefix + "a/b",
  ]
  assert_eq(native_repository_goal_runtime_roots(repository, entries), [
    prefix + "live",
    prefix + "dead",
  ])
}

///|
test "restarting either repository preserves the other's runtime namespace" {
  let repo_a = @workflow.RepositoryId("/repo/a")
  let repo_b = @workflow.RepositoryId("/repo/b")
  let prefix_a = native_goal_runtime_entry_prefix(repo_a)
  let prefix_b = native_goal_runtime_entry_prefix(repo_b)
  let entries = [
    prefix_a + "active-a",
    prefix_a + "stale-a",
    prefix_b + "active-b",
    prefix_b + "stale-b",
  ]
  let selected_a = native_repository_goal_runtime_roots(repo_a, entries)
  assert_eq(selected_a, [prefix_a + "active-a", prefix_a + "stale-a"])
  assert_false(selected_a.contains(prefix_b + "active-b"))
  assert_false(selected_a.contains(prefix_b + "stale-b"))
  let selected_b = native_repository_goal_runtime_roots(repo_b, entries)
  assert_eq(selected_b, [prefix_b + "active-b", prefix_b + "stale-b"])
  assert_false(selected_b.contains(prefix_a + "active-a"))
  assert_false(selected_b.contains(prefix_a + "stale-a"))
}

///|
/// Select the durable data root used by repository-scoped BoxLite homes.
///
/// An empty XDG_DATA_HOME is unspecified by the XDG base-directory contract, so
/// it falls back to HOME just like an absent value.
fn native_boxlite_data_home_from(
  xdg_data_home : String?,
  home : String?,
) -> Result[String, @types.ChoirError] {
  let selected_xdg = match xdg_data_home {
    Some(value) => if value == "" { None } else { Some(value) }
    None => None
  }
  let path = match selected_xdg {
    Some(value) => value
    None =>
      match home {
        Some(value) =>
          if value == "" {
            return Err(
              native_goal_execution_error(
                "durable BoxLite data home is unavailable",
              ),
            )
          } else {
            value + "/.local/share"
          }
        None =>
          return Err(
            native_goal_execution_error(
              "durable BoxLite data home is unavailable",
            ),
          )
      }
  }
  if !path.has_prefix("/") ||
    path == "/" ||
    path.contains("/../") ||
    path.has_suffix("/..") ||
    path.has_suffix("/") {
    return Err(
      native_goal_execution_error("durable BoxLite data home is invalid"),
    )
  }
  Ok(path)
}

///|
/// Read the data-home inputs at the native execution boundary.
fn native_boxlite_data_home() -> Result[String, @types.ChoirError] {
  native_boxlite_data_home_from(
    @sys.getenv("XDG_DATA_HOME"),
    @sys.getenv("HOME"),
  )
}

///|
test "the durable BoxLite data home follows XDG fallback semantics" {
  guard native_boxlite_data_home_from(
      Some("/var/lib/choir-user"),
      Some("/home/user"),
    )
    is Ok(xdg_home) else {
    fail("absolute XDG data home was rejected")
  }
  assert_eq(xdg_home, "/var/lib/choir-user")
  guard native_boxlite_data_home_from(None, Some("/home/user")) is Ok(fallback) else {
    fail("HOME fallback was rejected")
  }
  assert_eq(fallback, "/home/user/.local/share")
  guard native_boxlite_data_home_from(Some(""), Some("/home/user"))
    is Ok(empty_fallback) else {
    fail("empty XDG data home did not fall back")
  }
  assert_eq(empty_fallback, "/home/user/.local/share")
  assert_true(native_boxlite_data_home_from(None, None) is Err(_))
  assert_true(native_boxlite_data_home_from(Some("relative"), None) is Err(_))
  assert_true(
    native_boxlite_data_home_from(Some("/home/user/../other"), None) is Err(_),
  )
}

///|
/// BoxLite home shared by every Goal in a repository.
///
/// The pinned Take image is the same for all of them, and BoxLite only knows an
/// image is cached when its home's database says so, so a home scoped to one
/// Goal pulls the image again for the next one. Keeping the home per repository
/// pulls it once; Goal-scoped state stays under the Goal runtime root and is
/// still discarded with the Goal. The home is durable because it contains the
/// image index and database that make the pinned image a cache hit after reboot.
fn native_goal_boxlite_home_at(
  data_home : String,
  repository_id : @workflow.RepositoryId,
) -> String {
  data_home +
  "/choir/boxlite/repository-" +
  @storage.artifact_digest(@utf8.encode(repository_id.0)).0[:20].to_owned()
}

///|
pub fn native_goal_boxlite_home(
  repository_id : @workflow.RepositoryId,
) -> Result[String, @types.ChoirError] {
  match native_boxlite_data_home() {
    Ok(data_home) => Ok(native_goal_boxlite_home_at(data_home, repository_id))
    Err(error) => Err(error)
  }
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
  Ok(@workflow.repository_id(root))
}

///|
fn native_existing_sandbox_generation(
  runtime_root : String,
  generations : Array[@control.SandboxGenerationId],
  path_exists : (String) -> Bool,
) -> @control.SandboxGenerationId? {
  for generation_id in generations {
    if @sandbox.valid_boxlite_state_token(generation_id.0) &&
      path_exists(
        runtime_root + "/state/sandboxes/" + generation_id.0 + ".json",
      ) {
      return Some(generation_id)
    }
  }
  None
}

///|
test "the BoxLite home outlives the Goals that share it" {
  let repository = @workflow.RepositoryId("repository-a")
  let other_repository = @workflow.RepositoryId("repository-b")
  let goal_a = @control.GoalId("goal-a")
  let goal_b = @control.GoalId("goal-b")
  let data_home = "/home/user/.local/share"
  // Two Goals in one repository share a home, so the pinned Take image is
  // pulled once rather than once per Goal.
  assert_eq(
    native_goal_boxlite_home_at(data_home, repository),
    native_goal_boxlite_home_at(data_home, repository),
  )
  assert_true(
    native_goal_boxlite_home_at(data_home, repository) !=
    native_goal_boxlite_home_at(data_home, other_repository),
  )
  // The home is not inside any Goal runtime root, so discarding a Goal cannot
  // take the image cache with it.
  let home = native_goal_boxlite_home_at(data_home, repository)
  assert_false(home.has_prefix(native_goal_runtime_root(repository, goal_a)))
  assert_false(home.has_prefix(native_goal_runtime_root(repository, goal_b)))
  assert_true(
    native_goal_runtime_root(repository, goal_a) !=
    native_goal_runtime_root(repository, goal_b),
  )
  assert_eq(
    home,
    "/home/user/.local/share/choir/boxlite/repository-" +
    @storage.artifact_digest(@utf8.encode(repository.0)).0[:20].to_owned(),
  )
  assert_false(home.has_prefix("/tmp/"))
}

///|
/// What a Goal runtime root on disk says about the sandboxes it holds.
pub(all) enum NativeGoalRuntimeDisposition {
  /// No runtime root yet; nothing to reuse and nothing to discard.
  NativeGoalRuntimeAbsent
  /// A root exists but has registered no sandbox, which is the ordinary shape
  /// of a runtime that was just built and has not completed a sandbox effect.
  NativeGoalRuntimeUnregistered
  /// A registered sandbox matches one this run expects.
  NativeGoalRuntimeCurrent(@control.SandboxGenerationId)
  /// Every registered sandbox belongs to a generation this run does not expect.
  NativeGoalRuntimeStale
} derive(Debug, Eq)

///|
/// Decide what to do with an existing Goal runtime root.
///
/// Discarding it whenever no expected generation is registered conflates "not
/// registered yet" with "left over from an earlier run". A freshly rebuilt
/// runtime has registered nothing, so that reading wipes the runtime on every
/// tick, re-extracts its base image, and never survives long enough to register
/// a sandbox — a rebuild loop that reports no error because nothing fails. Only
/// registrations that exist and disagree are evidence of staleness.
fn native_goal_runtime_disposition(
  runtime_root : String,
  generations : Array[@control.SandboxGenerationId],
  path_exists : (String) -> Bool,
  list_dir : (String) -> Array[String],
) -> NativeGoalRuntimeDisposition {
  if !path_exists(runtime_root) {
    return NativeGoalRuntimeAbsent
  }
  match
    native_existing_sandbox_generation(runtime_root, generations, path_exists) {
    Some(generation_id) => return NativeGoalRuntimeCurrent(generation_id)
    None => ()
  }
  let registry = runtime_root + "/state/sandboxes"
  if !path_exists(registry) {
    return NativeGoalRuntimeUnregistered
  }
  let mut registered = 0
  for entry in list_dir(registry) {
    if entry.has_suffix(".json") {
      registered = registered + 1
    }
  }
  if registered == 0 {
    NativeGoalRuntimeUnregistered
  } else {
    NativeGoalRuntimeStale
  }
}

///|
test "a runtime that has registered nothing is not stale" {
  let registry = "/tmp/choir-take-goal-test/state/sandboxes"
  let generation = @control.SandboxGenerationId("generation-a")
  // A root that was just rebuilt: present, but no registry yet. Discarding it
  // here is what produced the rebuild loop.
  assert_eq(
    native_goal_runtime_disposition(
      "/tmp/choir-take-goal-test",
      [generation],
      fn(path) { path == "/tmp/choir-take-goal-test" },
      fn(_) { [] },
    ),
    NativeGoalRuntimeUnregistered,
  )
  // A registry directory with no manifests in it reads the same way.
  assert_eq(
    native_goal_runtime_disposition(
      "/tmp/choir-take-goal-test",
      [generation],
      fn(path) { path == "/tmp/choir-take-goal-test" || path == registry },
      fn(_) { [] },
    ),
    NativeGoalRuntimeUnregistered,
  )
  // No root at all.
  assert_eq(
    native_goal_runtime_disposition(
      "/tmp/choir-take-goal-test",
      [generation],
      fn(_) { false },
      fn(_) { [] },
    ),
    NativeGoalRuntimeAbsent,
  )
}

///|
test "registrations that disagree with this run are stale" {
  let root = "/tmp/choir-take-goal-test"
  let registry = root + "/state/sandboxes"
  let generation = @control.SandboxGenerationId("generation-a")
  // A manifest for this run's generation: reuse it.
  assert_eq(
    native_goal_runtime_disposition(
      root,
      [generation],
      fn(path) { path == root || path == registry + "/generation-a.json" },
      fn(_) { ["generation-a.json"] },
    ),
    NativeGoalRuntimeCurrent(generation),
  )
  // Manifests exist but none belong to this run: left over, discard.
  assert_eq(
    native_goal_runtime_disposition(
      root,
      [generation],
      fn(path) { path == root || path == registry },
      fn(_) { ["generation-old.json"] },
    ),
    NativeGoalRuntimeStale,
  )
  // Non-manifest entries do not count as registrations.
  assert_eq(
    native_goal_runtime_disposition(
      root,
      [generation],
      fn(path) { path == root || path == registry },
      fn(_) { ["README", "scratch.tmp"] },
    ),
    NativeGoalRuntimeUnregistered,
  )
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
fn native_goal_executor_port_for_process(
  process_id : Int,
  executor_slot : Int,
) -> Result[Int, @types.ChoirError] {
  if process_id <= 0 ||
    executor_slot < 0 ||
    executor_slot >= @types.maximum_goal_executor_jobs() {
    return Err(
      native_goal_execution_error("executor process or slot is invalid"),
    )
  }
  // Preserve the old process-derived namespace so independent Choir daemons do
  // not all claim the same ports, while keeping every slot in this worker
  // distinct. The slot stride is coprime to the complete 40000..65535 ring, so
  // no two of the maximum 1,024 slots in one process can wrap onto each other;
  // spreading slots around the ring also avoids the guaranteed overlap that
  // contiguous ranges would give workers with neighboring pids.
  let port_span = 25536
  let slot_stride = 7919
  Ok(40000 + (process_id % port_span + executor_slot * slot_stride) % port_span)
}

///|
fn native_goal_executor_port(
  executor_slot : Int,
) -> Result[Int, @types.ChoirError] {
  native_goal_executor_port_for_process(@sys.get_pid(), executor_slot)
}

///|
test "Goal executor ports retain process identity and distinct bounded slots" {
  assert_eq(native_goal_executor_port_for_process(12345, 0).unwrap(), 52345)
  assert_eq(native_goal_executor_port_for_process(12345, 1).unwrap(), 60264)
  assert_eq(native_goal_executor_port_for_process(19999, 1).unwrap(), 42382)
  let all_slots : Array[Int] = []
  for slot = 0; slot < @types.maximum_goal_executor_jobs(); slot = slot + 1 {
    let port = native_goal_executor_port_for_process(12345, slot).unwrap()
    assert_false(all_slots.contains(port))
    assert_true(port >= 40000 && port <= 65535)
    all_slots.push(port)
  }
  assert_eq(all_slots.length(), @types.maximum_goal_executor_jobs())
  let neighbor : Array[Int] = []
  for slot = 0; slot < 4; slot = slot + 1 {
    neighbor.push(native_goal_executor_port_for_process(12346, slot).unwrap())
  }
  for port in all_slots[:4] {
    assert_false(neighbor.contains(port))
  }
  assert_true(native_goal_executor_port_for_process(0, 0) is Err(_))
  assert_true(native_goal_executor_port_for_process(12345, -1) is Err(_))
  assert_true(native_goal_executor_port_for_process(12345, 1024) is Err(_))
}

///|
fn native_goal_boxlite_server_config(
  record : @workflow.GoalExecutionRecord,
  executor_slot? : Int = 0,
) -> Result[@take_host.NativeBoxLiteServerConfig, @types.ChoirError] {
  let port = match native_goal_executor_port(executor_slot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_key = native_goal_runtime_key(
    record.repository_id,
    record.goal.id,
  )
  let binary = match @process_host.native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_dir = match @process_host.native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let home = match native_goal_boxlite_home(record.repository_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    binary,
    runtime_dir,
    root: native_goal_runtime_root(record.repository_id, record.goal.id),
    home,
    port,
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
  let binary = match @process_host.native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_dir = match @process_host.native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let home = match native_goal_boxlite_home(repository_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let receipt = match read_native_goal_runtime_receipt(runtime_root) {
    Some(value) if value.repository_id == repository_id &&
      value.goal_id == goal_id => value
    _ =>
      return Err(native_goal_execution_error("runtime ownership is unproven"))
  }
  let box_ids = match @part_host.native_runtime_owned_box_ids(runtime_root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.base_box_id {
    Some(value) => if !box_ids.contains(value) { box_ids.push(value) }
    None => ()
  }
  @take_host.cleanup_native_boxlite_owned_runtime(
    {
      binary,
      runtime_dir,
      root: runtime_root,
      home,
      port: 40000 + @sys.get_pid() % 10000,
      api_key: "choir-goal-" + native_goal_runtime_key(repository_id, goal_id),
    },
    box_ids,
  )
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
async fn cleanup_failed_native_goal_setup_with(
  server : @take_host.NativeBoxLiteServerHandle,
  prepared : @take_host.NativeBoxLitePreparedEnvironment?,
  stop : async (@take_host.NativeBoxLiteServerHandle) -> Unit,
  settle : async () -> Unit,
  cleanup : async (@take_host.NativeBoxLiteServerConfig, Array[String]) -> Result[
    Unit,
    @types.ChoirError,
  ],
) -> Unit {
  stop(server)
  settle()
  let box_ids : Array[String] = match prepared {
    Some(value) => [value.base_box_id]
    None => []
  }
  ignore(cleanup(server.config, box_ids))
}

///|
async fn cleanup_failed_native_goal_setup(
  server : @take_host.NativeBoxLiteServerHandle,
  prepared : @take_host.NativeBoxLitePreparedEnvironment?,
) -> Unit {
  cleanup_failed_native_goal_setup_with(
    server,
    prepared,
    @take_host.stop_native_boxlite_server,
    async fn() { @async.sleep(400) },
    async fn(config, ids) {
      @take_host.cleanup_native_boxlite_owned_runtime(config, ids)
    },
  )
}

///|
async test "a failed Goal setup preserves a sibling in the shared home" {
  let config_a : @take_host.NativeBoxLiteServerConfig = {
    binary: "/unused/boxlite",
    runtime_dir: "/unused/runtime",
    root: "/tmp/choir-take-goal-a",
    home: "/tmp/choir-boxlite-shared-goals",
    port: 22000,
    api_key: "goal-a",
  }
  let server_a : @take_host.NativeBoxLiteServerHandle = {
    config: config_a,
    pid: 10,
    url: "http://127.0.0.1:22000",
    owner_pid: 11,
    owner_socket_root: config_a.root + "/owner",
    owner_socket: config_a.root + "/owner/socket",
    owner_token: "owner-a",
  }
  let prepared_a : @take_host.NativeBoxLitePreparedEnvironment = {
    server: server_a,
    base_box_id: "base-a",
    image_digest: @sandbox.boxlite_take_image_digest,
    tool_manifest_digest: @sandbox.boxlite_take_tool_manifest_digest(),
    runtime_policy_digest: @sandbox.boxlite_take_runtime_policy_digest(),
  }
  let sibling_boxes = ["base-b", "take-b"]
  let removed : Array[String] = []
  let stopped : Array[String] = []
  cleanup_failed_native_goal_setup_with(
    server_a,
    Some(prepared_a),
    async fn(server) {
      @async.sleep(0)
      stopped.push(server.config.api_key)
    },
    async fn() { @async.sleep(0) },
    async fn(config, owned) {
      @async.sleep(0)
      assert_eq(config.home, "/tmp/choir-boxlite-shared-goals")
      assert_eq(owned, ["base-a"])
      for id in owned {
        removed.push(id)
      }
      Ok(())
    },
  )
  assert_eq(stopped, ["goal-a"])
  assert_eq(removed, ["base-a"])
  assert_eq(sibling_boxes, ["base-b", "take-b"])
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
  capture : async (@process_host.Command) -> (Int, String),
) -> Result[
  (@workflow.GoalSelectionSourcePart, @beads_host.NativeConductorTask)?,
  @types.ChoirError,
] {
  let output = match
    @beads_host.native_conductor_capture_beads(
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
  let tasks = match @beads_host.native_conductor_tasks_from_output(output) {
    Ok(value) => value
    Err(_) => return Ok(None)
  }
  let mut source : @workflow.GoalSelectionSourcePart? = None
  for candidate in snapshot.parts {
    if candidate.part_id == claim.part_id {
      source = Some(candidate)
      break
    }
  }
  if source is None || tasks.length() != 1 || tasks[0].id != claim.part_id.0 {
    return Ok(None)
  }
  Ok(Some((source.unwrap(), tasks[0])))
}

///|
async fn observe_native_goal_source_claim(
  project_dir : String,
  record : @workflow.GoalExecutionRecord,
  claim : @workflow.GoalSourceClaim,
  capture : async (@process_host.Command) -> (Int, String),
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
    // Someone moved the Bead out from under the claim. Blocked and deferred are
    // neither closed nor claimable, and guessing either way would let a Goal
    // proceed on a Bead the tracker says is not startable.
    @types.TaskStatus::Blocked | @types.TaskStatus::Deferred =>
      Ok(@workflow.GoalSourceClaimObservation::GoalSourceAmbiguous)
  }
}

///|
async fn observe_native_goal_source_release(
  project_dir : String,
  record : @workflow.GoalExecutionRecord,
  claim : @workflow.GoalSourceClaim,
  capture : async (@process_host.Command) -> (Int, String),
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
    @types.TaskStatus::Blocked | @types.TaskStatus::Deferred =>
      Ok(@workflow.GoalSourceClaimObservation::GoalSourceAmbiguous)
  }
}

///|
async fn apply_native_goal_source_claim(
  project_dir : String,
  record : @workflow.GoalExecutionRecord,
  claim : @workflow.GoalSourceClaim,
  capture : async (@process_host.Command) -> (Int, String),
) -> Result[@workflow.GoalSourceClaimObservation, @types.ChoirError] {
  let initial = match
    observe_native_goal_source_claim(project_dir, record, claim, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if initial != @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact {
    return Ok(initial)
  }
  let claim_result = @beads_host.native_conductor_capture_beads(
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
  capture : async (@process_host.Command) -> (Int, String),
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
  let release_result = @beads_host.native_conductor_capture_beads(
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
      draft: false,
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
    part_workflow_ids: [@control.WorkflowId("source-claim-workflow")],
    state: @workflow.GoalExecutionState::GoalExecutionRunning,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    work_order_id: None,
    durable_version: 2,
    fencing_epoch: @control.FencingEpoch(1L),
  }
}

///|
async test "Beads claim recovers when delivery succeeded but acknowledgement was lost" {
  let open =
    #|[{"id":"choir-source-claim","title":"Claim me","description":"","acceptance_criteria":"","notes":"","status":"open","priority":2,"issue_type":"task","assignee":"","updated_at":"2026-07-21T00:00:00Z","dependency_count":1,"dependencies":[{"id":"choir-delivered-dependency","title":"Delivered","description":"","acceptance_criteria":"","notes":"","status":"closed","priority":2,"issue_type":"task","assignee":"","updated_at":"2026-07-20T00:00:00Z","dependency_type":"blocks","dependency_count":0}]}]
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
            #|[{"id":"choir-source-claim","title":"Claim me","description":"","acceptance_criteria":"","notes":"","status":"in_progress","priority":2,"issue_type":"task","assignee":"choir:goal-source-claim-test","updated_at":"2026-07-21T00:01:00Z","dependency_count":1,"dependencies":[{"id":"choir-delivered-dependency","title":"Delivered","description":"","acceptance_criteria":"","notes":"","status":"closed","priority":2,"issue_type":"task","assignee":"","updated_at":"2026-07-20T00:00:00Z","dependency_type":"blocks","dependency_count":0}]}]
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
  capture~ : async (@process_host.Command) -> (Int, String),
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
  capture~ : async (@process_host.Command) -> (Int, String),
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
pub fn native_goal_mcp_script() -> String? {
  @process_host.resolve_native_runtime_asset(
    @process_host.ChoirRuntimeAsset::ChoirSandboxMcp,
  )
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
/// One provider slot this process holds, and where to give it back.
///
/// The surface travels with the id because release is keyed by surface record,
/// and the surface a lease was taken on is not recoverable from the id — it is
/// hashed into it.
pub(all) struct NativeProviderLeaseHold {
  surface : @control.ProviderSurfaceId
  lease_id : @workflow.ProviderLeaseId
} derive(Debug, Eq)

///|
/// What the portfolio bound said.
priv enum NativeProviderAdmission {
  NativeProviderAdmitted(NativeProviderLeaseHold)
  /// Refused, and when to come back. Never a bare no.
  NativeProviderDeferredUntil(Int64)
}

///|
/// Take a portfolio provider slot.
///
/// Both admission gates below funnel through here, so the surface bound is
/// decided once. A second gate that called `acquire_provider_lease` for itself
/// would be a second bound the moment either drifted from this one.
///
/// This is also the one place that reports what a surface did this tick, for
/// the same reason. `observe` is what the daemon's sleep reads: a refusal that
/// named an instant nobody recorded degrades a scheduled wake into a poll, and
/// an admission that went unrecorded would let the daemon sleep on another
/// surface's instant while this one was working. Reporting here rather than at
/// each caller means the surface named is always the surface judged — a caller
/// reading it back off a snapshot would name the pre-failover surface.
fn native_provider_lease_admission(
  repository : @workflow.PartWorkflowRepository,
  surface : @control.ProviderSurfaceId,
  request : @workflow.ProviderLeaseRequest,
  capacity : @types.ProviderCapacityPolicy,
  now : Int64,
  observe~ : (@workflow.ProviderSurfaceTickReport) -> Unit,
) -> Result[NativeProviderAdmission, @types.ChoirError] {
  match
    @workflow.acquire_provider_lease(
      repository,
      @storage_host.local_part_workflow_repository_adapters(),
      surface,
      request,
      capacity,
      now,
    ) {
    Ok(@workflow.ProviderLeaseDecision::ProviderLeaseGranted(_, lease)) => {
      observe({
        surface,
        disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceAdmitted,
      })
      Ok(NativeProviderAdmitted({ surface, lease_id: lease.id }))
    }
    Ok(@workflow.ProviderLeaseDecision::ProviderLeaseDeferredUntil(instant)) => {
      observe({
        surface,
        disposition: @workflow.ProviderSurfaceTickDisposition::ProviderSurfaceDeferredUntil(
          instant,
        ),
      })
      Ok(NativeProviderDeferredUntil(instant))
    }
    Err(error) => Err(error)
  }
}

///|
/// The one seam that admits new planner and provider work for a Part.
///
/// Two gates, in this order. The WorkOrder budget and the Goal's own state come
/// first because they are decided from a record this pass already has to read,
/// and a Goal that is over budget or no longer running must not take a provider
/// slot on its way to being refused. Only then is the portfolio-wide provider
/// lease taken, which is the write.
///
/// The lease is derived from the Goal, the Part, and the surface, so the many
/// times a single driver pass re-enters this gate all ask for the same slot and
/// hold one between them. It is given back when that pass returns, and
/// reclaimed by fencing epoch if this worker dies before it does.
///
/// `drive_part_workflow` enters here for two distinct reasons, and the second
/// one is the one that is easy to omit: to authorize a planned effect, and
/// again before re-executing a provider dispatch that an earlier pass left
/// `PartEffectMayHaveOccurred`. That earlier pass returned its slot at
/// `release_after_part_pass` on its way out, so a retry that skipped this gate
/// would start a second provider session with nothing held for it and the
/// portfolio bound would never count it.
///
/// `fencing_epoch` and `now` are parameters rather than reads so a narrow test
/// can drive two generations and a fixed clock through the same code the daemon
/// runs; every other input is read from the durable store here. Public for the
/// same reason: an admission test that stubs this out proves nothing about
/// whether the daemon oversubscribes.
///
/// `observe` is told what this gate decided about `surface`, and this gate is
/// the only place that reports it. The alternative — each Part pass in
/// `goal_part_adapter.mbt` forwarding its own refusal — has to name the surface
/// from the snapshot it happens to hold, which after a provider failover is no
/// longer the surface the lease was judged against, and has to be repeated at
/// every pass that calls this gate.
pub fn native_goal_effect_authorization(
  repository : @workflow.PartWorkflowRepository,
  goal_id : @control.GoalId,
  part_id : @control.PartId,
  surface : @control.ProviderSurfaceId,
  take_id : @control.TakeId,
  capacity : @types.ProviderCapacityPolicy,
  fencing_epoch : @control.FencingEpoch,
  now : Int64,
  observe~ : (@workflow.ProviderSurfaceTickReport) -> Unit,
) -> Result[@workflow.PartGoalAuthorization, @types.ChoirError] {
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  let current = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_goal_execution_error("Goal record disappeared"))
    Err(error) => return Err(error)
  }
  // Reconciling an already-authorized effect from durable evidence continues
  // past the deadline; what this refuses is new spend. That includes a retried
  // provider dispatch, which opens a second real session against the
  // subscription even though the Take is not new — the driver's retry path
  // reaches this gate for exactly that reason. A Goal past its budget, no
  // longer running, or no longer active therefore reads witnesses and finishes
  // what it can while starting nothing on a provider.
  let work_order = match
    @workflow.load_goal_work_order(repository, adapters, current.record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let budget_admits = @workflow.work_order_admits_new_agentic_work(
      work_order.map(fn(stored) { stored.record.budget }),
      now,
    )
    is @workflow.WorkOrderAdmission::WorkOrderAdmitsNewWork
  if !(budget_admits &&
    current.record.state == @workflow.GoalExecutionState::GoalExecutionRunning &&
    current.record.goal.lifecycle ==
    @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    )) {
    return Ok(@workflow.PartGoalAuthorization::PartGoalNotAuthorized)
  }
  match
    native_provider_lease_admission(
      repository,
      surface,
      {
        lease_id: @workflow.provider_lease_id(goal_id, part_id, surface),
        take_id,
        goal_id,
        fencing_epoch,
      },
      capacity,
      now,
      observe~,
    ) {
    Ok(NativeProviderAdmitted(_)) =>
      Ok(
        @workflow.PartGoalAuthorization::PartGoalAuthorized(
          Some({ record: current.state_record }),
        ),
      )
    Ok(NativeProviderDeferredUntil(instant)) =>
      Ok(@workflow.PartGoalAuthorization::PartGoalDeferredUntil(instant))
    Err(error) => Err(error)
  }
}

///|
/// Which provider surface one Goal assurance effect will reach.
///
/// The exhaustive match is the point: a new assurance effect kind does not
/// compile until someone decides whether it dispatches a provider session. The
/// three audit-session kinds run on the surface the audit session was planned
/// for — the sandbox included, because that box is where the session runs and
/// it exists only to serve it. Sealing and combined verification reach no
/// provider: verification runs the Goal's declared commands in a sandbox, so
/// leasing a subscription slot for it would hold a provider seat for the length
/// of a test suite.
fn native_goal_assurance_effect_surface(
  identities : @workflow.GoalAssuranceIdentityPlan,
  kind : @workflow.GoalAssuranceEffectKind,
) -> @control.ProviderSurfaceId? {
  match kind {
    @workflow.GoalAssuranceEffectKind::PrepareGoalAuditSandbox(_)
    | @workflow.GoalAssuranceEffectKind::StartGoalAuditHarness(_)
    | @workflow.GoalAssuranceEffectKind::DispatchGoalAudit(_, _, _) =>
      Some(identities.audit_session.surface)
    @workflow.GoalAssuranceEffectKind::PrepareGoalVerificationSandbox(_)
    | @workflow.GoalAssuranceEffectKind::DispatchGoalVerification(_, _) => None
  }
}

///|
/// The seam that admits the Goal's own audit session.
///
/// `native_goal_effect_authorization` cannot serve this: it demands a Part to
/// key the lease on, and it refuses any Goal that is not `GoalExecutionRunning`
/// — which every assuring Goal is not. So this is the same bound reached
/// through the same `native_provider_lease_admission`, keyed on the audit Take
/// instead. It decides capacity only; whether the Goal may assure at all is the
/// execution tick's decision, made before this is ever called.
///
/// `None` means carry on: either the effect reaches no provider, or the slot it
/// needs is now held and recorded in `holds`. `Some` is the tick's whole
/// outcome — a deferral naming when to come back.
///
/// Idempotent by identity, not by memory: `goal_assurance_provider_lease_id` is
/// derived from the Goal, the audit Take, and the surface, so a tick that
/// re-enters this gate — after a crash, or several times inside one attempt —
/// asks for the slot it already holds. Getting that wrong leaks a slot per
/// tick.
///
/// `fencing_epoch` and `now` are parameters, and this is public, for the reason
/// `native_goal_effect_authorization` is: a capacity test that stubs the gate
/// out proves the stub.
pub fn native_goal_assurance_effect_admission(
  repository : @workflow.PartWorkflowRepository,
  goal_id : @control.GoalId,
  audit_take_id : @control.TakeId,
  identities : @workflow.GoalAssuranceIdentityPlan,
  kind : @workflow.GoalAssuranceEffectKind,
  capacity : @types.ProviderCapacityPolicy,
  fencing_epoch : @control.FencingEpoch,
  now : Int64,
  holds : Array[NativeProviderLeaseHold],
  observe~ : (@workflow.ProviderSurfaceTickReport) -> Unit,
) -> Result[@workflow.GoalAssuranceTickOutcome?, @types.ChoirError] {
  let surface = match native_goal_assurance_effect_surface(identities, kind) {
    Some(value) => value
    None => return Ok(None)
  }
  match
    native_provider_lease_admission(
      repository,
      surface,
      {
        lease_id: @workflow.goal_assurance_provider_lease_id(
          goal_id, audit_take_id, surface,
        ),
        take_id: audit_take_id,
        goal_id,
        fencing_epoch,
      },
      capacity,
      now,
      observe~,
    ) {
    Ok(NativeProviderAdmitted(hold)) => {
      if !holds.contains(hold) {
        holds.push(hold)
      }
      Ok(None)
    }
    Ok(NativeProviderDeferredUntil(instant)) =>
      Ok(
        Some(
          @workflow.GoalAssuranceTickOutcome::GoalAssuranceDeferredUntil(
            instant,
          ),
        ),
      )
    Err(error) => Err(error)
  }
}

///|
/// End one Goal assurance tick: give every slot it took back, whatever happened.
///
/// The attempt's own result wins, so a tick that failed still reports its
/// failure — but the slot goes back first. An assurance attempt that failed
/// while holding a Claude seat and did not return it would starve the surface
/// until the daemon generation ended, which is the failure mode this exists to
/// prevent rather than a detail of it.
///
/// This exit does not report the refusal's wake instant: the admission gate
/// already did, against the surface it judged, which is the only place that
/// knows which surface a refusal was about. Reporting again here would count
/// one refusal twice.
///
/// Releasing is idempotent, so the sweep costs a read and writes nothing for a
/// tick that took no slot. Public so a test can prove the failing path returns
/// the slot without having to make a real provider session fail.
pub fn finish_native_goal_assurance_leases(
  repository : @workflow.PartWorkflowRepository,
  holds : Array[NativeProviderLeaseHold],
  result : Result[@workflow.GoalAssuranceTickOutcome, @types.ChoirError],
  fencing_epoch : @control.FencingEpoch,
) -> Result[@workflow.GoalAssuranceTickOutcome, @types.ChoirError] {
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  let mut released : Result[Unit, @types.ChoirError] = Ok(())
  for hold in holds {
    match
      @workflow.release_provider_lease(
        repository,
        adapters,
        hold.surface,
        hold.lease_id,
        fencing_epoch,
      ) {
      Ok(_) => ()
      Err(error) => released = Err(error)
    }
  }
  match result {
    Err(error) => Err(error)
    Ok(value) =>
      match released {
        Err(error) => Err(error)
        Ok(_) => Ok(value)
      }
  }
}

///|
async fn execute_native_goal_record(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.GoalExecutionRecord,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
  capacity : @types.ProviderCapacityPolicy,
  executor_slot? : Int = 0,
  observe? : (@workflow.ProviderSurfaceTickReport) -> Unit = fn(_) { () },
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
  let generations : Array[@control.SandboxGenerationId] = []
  for snapshot in snapshots {
    for lease in snapshot.sandbox_leases {
      if !generations.contains(lease.generation_id) {
        generations.push(lease.generation_id)
      }
    }
  }
  let disposition = native_goal_runtime_disposition(
    runtime_root, generations, @sys.path_exists, @sys.list_dir,
  )
  let existing_generation = match disposition {
    NativeGoalRuntimeCurrent(generation_id) => Some(generation_id)
    _ => None
  }
  let server_config = match
    native_goal_boxlite_server_config(record, executor_slot~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // Only discard a runtime whose registered sandboxes belong to an earlier run.
  // A runtime that has registered nothing yet is the normal state right after a
  // rebuild, and discarding it there rebuilds it again on the next tick forever.
  if disposition is NativeGoalRuntimeStale {
    match cleanup_native_goal_runtime(record) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  if !@sys.create_dir_all(runtime_root) ||
    @sys.realpath_native(runtime_root) != Some(runtime_root) {
    return Err(native_goal_execution_error("runtime root is unavailable"))
  }
  let initial_receipt = native_goal_runtime_receipt(
    record.repository_id,
    record.goal.id,
    None,
  )
  match read_native_goal_runtime_receipt(runtime_root) {
    Some(receipt) if receipt.repository_id == record.repository_id &&
      receipt.goal_id == record.goal.id => ()
    Some(_) =>
      return Err(native_goal_execution_error("runtime ownership conflicts"))
    None => {
      if @sys.path_entry_exists(native_goal_runtime_owner_path(runtime_root)) {
        return Err(native_goal_execution_error("runtime ownership is invalid"))
      }
      if !(disposition is NativeGoalRuntimeAbsent) &&
        !(disposition is NativeGoalRuntimeStale) {
        return Err(native_goal_execution_error("runtime ownership is unproven"))
      }
      match write_native_goal_runtime_receipt(runtime_root, initial_receipt) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
  }
  let moon_home = match @sys.getenv("CHOIR_MOON_HOME") {
    Some(value) => value
    None =>
      match @sys.getenv("HOME") {
        Some(value) => value + "/.moon"
        None => return Err(native_goal_execution_error("Moon home is absent"))
      }
  }
  let node = match @process_host.resolve_executable_in_path("node") {
    Some(value) => value
    None => return Err(native_goal_execution_error("Node is absent"))
  }
  let mcp_script = match native_goal_mcp_script() {
    Some(value) => value
    None => return Err(native_goal_execution_error("sandbox MCP is absent"))
  }
  let server = match @take_host.start_native_boxlite_server(server_config) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (active_server, initial_prepared) = match existing_generation {
    Some(_) => (server, None)
    None =>
      match
        @take_host.prepare_native_boxlite_environment(
          server,
          moon_home,
          "choir-base-goal-" + runtime_key,
        ) {
        Ok(value) => (value.server, Some(value))
        Err(error) => {
          cleanup_failed_native_goal_setup(server, None)
          return Err(error)
        }
      }
  }
  match initial_prepared {
    Some(value) =>
      match
        write_native_goal_runtime_receipt(
          runtime_root,
          native_goal_runtime_receipt(
            record.repository_id,
            record.goal.id,
            Some(value.base_box_id),
          ),
        ) {
        Ok(_) => ()
        Err(error) => {
          cleanup_failed_native_goal_setup(active_server, Some(value))
          return Err(error)
        }
      }
    None => ()
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
        @storage_host.local_part_workflow_repository_adapters(),
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
        Some(_) => @take_host.stop_native_boxlite_server(active_server)
        None =>
          cleanup_failed_native_goal_setup(active_server, initial_prepared)
      }
      return Err(
        native_goal_execution_error("Part provider assignment drifted"),
      )
    }
    let runtime = match
      @part_host.create_native_part_effect_runtime(
        @part_host.native_part_runtime_config_for_paths(
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
          Some(_) => @take_host.stop_native_boxlite_server(active_server)
          None =>
            cleanup_failed_native_goal_setup(active_server, initial_prepared)
        }
        return Err(error)
      }
    }
    parts.push({ snapshot, runtime, surface })
  }
  if parts.length() == 0 {
    match existing_generation {
      Some(_) => @take_host.stop_native_boxlite_server(active_server)
      None => cleanup_failed_native_goal_setup(active_server, initial_prepared)
    }
    return Err(native_goal_execution_error("Goal has no Part runtimes"))
  }
  let prepared = match initial_prepared {
    Some(value) => value
    None =>
      match existing_generation {
        Some(generation_id) =>
          match
            @part_host.native_runtime_sandbox(parts[0].runtime, generation_id) {
            Ok(value) => value.prepared
            Err(error) => {
              @take_host.stop_native_boxlite_server(active_server)
              return Err(error)
            }
          }
        None => {
          @take_host.stop_native_boxlite_server(active_server)
          return Err(
            native_goal_execution_error("Goal runtime preparation is absent"),
          )
        }
      }
  }
  for part in parts {
    part.runtime.prepared.val = Some(prepared)
  }
  let integration : @git_integration.NativeGitIntegrationConfig = {
    repository_root: git.root,
    git_directory: git.git_directory,
    object_directory: git.object_directory,
    control_root: runtime_root + "/integration-control",
    goal_ref: record.goal_ref.0,
  }
  let boxlite_effect_lock = @ref.new(false)
  let config : @part_adapter.GoalPartWorkflowAdapterConfig = {
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
    repository_adapters: @storage_host.local_part_workflow_repository_adapters(),
    dependencies: fn(part_id, admission) {
      let part = match native_goal_part_runtime(parts, part_id) {
        Some(value) => value
        None =>
          return Err(native_goal_execution_error("Part runtime is absent"))
      }
      let dependencies = @part_host.native_part_runtime_dependencies(
        repository,
        part.runtime,
        clock,
        part.surface,
        boxlite_effect_lock,
        admission,
      )
      Ok({
        ..dependencies,
        goal_authorizes_new_effects: fn() {
          native_goal_effect_authorization(
            repository,
            record.goal.id,
            part_id,
            part.surface,
            part.snapshot.identities.implementation_take.id,
            capacity,
            current_native_goal_fencing_epoch(),
            @env.now().reinterpret_as_int64() / 1000L,
            observe~,
          )
        },
      })
    },
    integration_input: native_goal_integration_input,
    plan_conflict_repair: plan_native_goal_conflict_repair,
    plan_audit_repair: fn(snapshot) {
      plan_native_part_audit_repair(repository, snapshot)
    },
    plan_verification_repair: fn(snapshot) {
      plan_native_part_verification_repair(repository, snapshot)
    },
    plan_recovery_retry: plan_native_part_recovery_retry,
    read_goal_head: async fn() {
      @git_integration.read_native_goal_head(
        integration,
        @git_host.native_git_integration_adapters(),
      )
    },
    release_provider_lease: fn(part_id) {
      match native_goal_part_runtime(parts, part_id) {
        Some(part) =>
          release_native_goal_provider_leases(repository, [part.snapshot])
        None => Err(native_goal_execution_error("Part runtime is absent"))
      }
    },
  }
  let result = @workflow.run_goal_parts(
    config.bindings.map(fn(binding) { binding.scheduling_record }),
    record.maximum_parallel_parts,
    @part_adapter.goal_part_workflow_adapters(config),
  )
  // Each Part gives its slot back as its pass returns; this is the sweep for a
  // pass that failed on its way out. Releasing is idempotent, so a slot already
  // returned costs a read and writes nothing.
  let released = release_native_goal_provider_leases(repository, snapshots)
  match result {
    // Source Beads deliberately stay claimed here: Part integration onto the
    // private Goal branch is not delivery. Closure happens at the Goal
    // delivery boundary, inside finalization once the PR is observed ready.
    Ok(_) => {
      // A successful pass may still be nonterminal. Preserve the Goal-scoped
      // runtime and its sandbox-generation witnesses for the next pass;
      // terminal finalization and cancellation own destructive cleanup.
      @take_host.stop_native_boxlite_server(prepared.server)
      released
    }
    Err(error) => {
      // The authorized effect may still be retriable on the next tick. Keep
      // its persisted sandbox generation while releasing live processes.
      @take_host.stop_native_boxlite_server(prepared.server)
      Err(error)
    }
  }
}

///|
/// Give back every provider slot this Goal's Parts held.
///
/// Derived from the same snapshots the admission gate was bound against, so the
/// surface released is the surface leased. A Part that recorded a provider
/// failover during the tick keeps running on the surface it started on — the
/// move takes effect on the next tick, which leases and releases the new one.
///
/// Idempotent by construction: `release_provider_lease` writes nothing when the
/// lease is not in the held set, so a Part that never reached the gate, a
/// second release, and a lease already reclaimed with a dead generation all
/// come back as "already released" without touching the count. Public so a
/// narrow test can prove the identity released is the identity the gate leased;
/// a mismatch there leaks a slot until the daemon generation ends.
pub fn release_native_goal_provider_leases(
  repository : @workflow.PartWorkflowRepository,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
) -> Result[Unit, @types.ChoirError] {
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  for snapshot in snapshots {
    let surface = snapshot.identities.implementation_session.surface
    match
      @workflow.release_provider_lease(
        repository,
        adapters,
        surface,
        @workflow.provider_lease_id(snapshot.goal.id, snapshot.part.id, surface),
        current_native_goal_fencing_epoch(),
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(())
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
  capture~ : async (@process_host.Command) -> (Int, String),
) -> Result[Unit, @types.ChoirError] {
  let current_output = match
    @beads_host.native_conductor_capture_beads(
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
  let task = match
    @beads_host.native_conductor_tasks_from_output(current_output) {
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
    @beads_host.native_conductor_capture_beads(
      project_dir,
      "update",
      ["update", part_id.0, "--status", "closed", "--json"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let updated = match
    @beads_host.native_conductor_tasks_from_output(updated_output) {
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
  capture~ : async (@process_host.Command) -> (Int, String),
) -> Result[Unit, @types.ChoirError] {
  let adapters = @storage_host.local_part_workflow_repository_adapters()
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
  let close_commands : Array[@process_host.Command] = []
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

  let replay_commands : Array[@process_host.Command] = []
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

  let drift_commands : Array[@process_host.Command] = []
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
  integration : @git_integration.NativeGitIntegrationConfig,
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
    @git_integration.reconcile_native_git_effect(
      integration,
      stored.snapshot,
      intent,
      @git_host.native_git_integration_adapters(),
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
    fn(reference) {
      @part_host.native_part_artifact_exists(repository, reference)
    },
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
  let integration : @git_integration.NativeGitIntegrationConfig? = if needs_integration {
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
  Ok((reconciled, assurance_known))
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
fn native_goal_pull_request_cancellation_disposition(
  record : @workflow.GoalPullRequestRecord,
) -> @workflow.GoalCancellationDisposition {
  if !@workflow.goal_pull_request_cancellation_disposition_is_known(record) {
    @workflow.GoalCancellationDisposition::GoalCancellationPending
  } else if @workflow.goal_pull_request_delivery_superseded_cancellation(record) {
    @workflow.GoalCancellationDisposition::GoalCancellationSupersededByDelivery(
      record,
    )
  } else {
    @workflow.GoalCancellationDisposition::GoalCancellationNeutralized
  }
}

///|
/// Cancellation must strip the forge's authority to merge this Goal's exact
/// pull request before any source claim is released. Every step re-observes
/// the exact remote pull request instead of trusting dispatch output, and at
/// most one neutralize dispatch is issued per tick so retries stay idempotent.
pub async fn reconcile_native_goal_pull_request_cancellation(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  forge : NativePullRequestForgeAdapters,
  observed_at : Int64,
) -> Result[@workflow.GoalCancellationDisposition, @types.ChoirError] {
  let mut stored = match
    @workflow.load_goal_pull_request_record(
      repository,
      adapters,
      execution.goal.id,
    ) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Ok(
        @workflow.GoalCancellationDisposition::GoalCancellationNeutralized,
      )
    Err(error) => return Err(error)
  }
  // A pull request that was never dispatched authorizes no remote effect, so
  // it is abandoned without needing the forge to be reachable at all.
  match stored.record.intent.state {
    @workflow.PullRequestIntentState::PullRequestPlanned
    | @workflow.PullRequestIntentState::PullRequestAuthorized => {
      let next = match
        @workflow.record_goal_pull_request_cancellation(
          stored.record,
          @workflow.PullRequestLookupObservation::PullRequestLookupUncertain,
          observed_at,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match
        persist_native_goal_pull_request_record(
          repository,
          adapters,
          execution,
          next,
          Some(stored.state_record.version),
        ) {
        Ok((Some(_), _)) =>
          return Ok(native_goal_pull_request_cancellation_disposition(next))
        Ok((None, _)) =>
          return Ok(
            @workflow.GoalCancellationDisposition::GoalCancellationPending,
          )
        Err(error) => return Err(error)
      }
    }
    _ => ()
  }
  if @workflow.goal_pull_request_cancellation_disposition_is_known(
      stored.record,
    ) {
    return Ok(native_goal_pull_request_cancellation_disposition(stored.record))
  }
  let git = match discover_native_goal_repository(project_dir, execution) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repository_name = match (forge.resolve_repository)(git.root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut dispatch_neutralize = false
  let mut cycles = 0
  while cycles < 6 {
    cycles = cycles + 1
    let record = stored.record
    let lookup = (forge.lookup)(git.root, repository_name, record.intent)
    let next = match record.intent.cancellation_state {
      @workflow.PullRequestCancellationState::PullRequestCancellationNotRequested =>
        match
          @workflow.record_goal_pull_request_cancellation(
            record, lookup, observed_at,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      @workflow.PullRequestCancellationState::PullRequestCancellationPlanned =>
        match
          @workflow.authorize_goal_pull_request_neutralization(record, lookup) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      @workflow.PullRequestCancellationState::PullRequestNeutralizeAuthorized =>
        match
          @workflow.mark_goal_pull_request_neutralize_may_have_been_issued(
            record,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      @workflow.PullRequestCancellationState::PullRequestNeutralizeMayHaveBeenIssued => {
        if dispatch_neutralize {
          guard record.receipt is Some(receipt) else {
            return Err(
              native_goal_execution_error("neutralize receipt is absent"),
            )
          }
          (forge.neutralize)(git.root, repository_name, record.intent, receipt)
          dispatch_neutralize = false
        }
        match
          @workflow.reconcile_goal_pull_request_neutralization(
            record,
            (forge.lookup)(git.root, repository_name, record.intent),
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
      }
      @workflow.PullRequestCancellationState::PullRequestNeutralized
      | @workflow.PullRequestCancellationState::PullRequestSupersededByMerge =>
        return Ok(native_goal_pull_request_cancellation_disposition(record))
    }
    if next == record {
      // The remote disposition is still unknown. Keep the claims held.
      return Ok(@workflow.GoalCancellationDisposition::GoalCancellationPending)
    }
    let persisted = match
      persist_native_goal_pull_request_record(
        repository,
        adapters,
        execution,
        next,
        Some(stored.state_record.version),
      ) {
      Ok((Some(value), committed)) => (value, committed)
      Ok((None, _)) =>
        return Ok(
          @workflow.GoalCancellationDisposition::GoalCancellationPending,
        )
      Err(error) => return Err(error)
    }
    stored = persisted.0
    if next.intent.cancellation_state ==
      @workflow.PullRequestCancellationState::PullRequestNeutralizeAuthorized &&
      record.intent.cancellation_state ==
      @workflow.PullRequestCancellationState::PullRequestNeutralizeMayHaveBeenIssued {
      // The exact pull request survived a neutralize attempt. Retry on the
      // next tick rather than hammering the forge inside one cycle.
      return Ok(@workflow.GoalCancellationDisposition::GoalCancellationPending)
    }
    if next.intent.cancellation_state ==
      @workflow.PullRequestCancellationState::PullRequestNeutralizeMayHaveBeenIssued {
      dispatch_neutralize = persisted.1
    }
    if @workflow.goal_pull_request_cancellation_disposition_is_known(next) {
      return Ok(native_goal_pull_request_cancellation_disposition(next))
    }
  } nobreak {
    Err(
      native_goal_execution_error(
        "PR cancellation reconciliation exceeded its cycle bound",
      ),
    )
  }
}

///|
async fn reconcile_native_goal_finalization_cancellation(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  forge : NativePullRequestForgeAdapters,
  observed_at : Int64,
) -> Result[@workflow.GoalCancellationDisposition, @types.ChoirError] {
  let publication_known = match
    reconcile_native_goal_publication_cancellation(
      project_dir, repository, adapters, execution, observed_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let pull_request = match
    reconcile_native_goal_pull_request_cancellation(
      project_dir, repository, adapters, execution, forge, observed_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // Delivery supersession is decided by the pull request alone: a merged exact
  // pull request means the branch publication served its purpose.
  match pull_request {
    @workflow.GoalCancellationDisposition::GoalCancellationSupersededByDelivery(
      _
    ) => Ok(pull_request)
    _ =>
      if publication_known &&
        pull_request ==
        @workflow.GoalCancellationDisposition::GoalCancellationNeutralized {
        Ok(@workflow.GoalCancellationDisposition::GoalCancellationNeutralized)
      } else {
        Ok(@workflow.GoalCancellationDisposition::GoalCancellationPending)
      }
  }
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
async test "real exec integration: native Goal branch initialization atomically anchors both refs" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-goal-branch-init-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create Goal branch initialization test root")
  }
  let git = async fn(
    arguments : Array[String],
  ) -> @git_integration.NativeGitCapture {
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
  let config : @git_integration.NativeGitIntegrationConfig = {
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
async test "real exec integration: native Goal purge removes only an exact owned Git ref" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-goal-ref-purge-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create Goal ref purge test root")
  }
  let git = async fn(
    arguments : Array[String],
  ) -> @git_integration.NativeGitCapture {
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
async test "real exec integration: native Goal seal witness is exact and idempotent" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-goal-seal-witness-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root) {
    fail("failed to create Goal seal test root")
  }
  let git = async fn(
    arguments : Array[String],
  ) -> @git_integration.NativeGitCapture {
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
/// The provider surface Goal-level assurance runs on.
///
/// A Part already audits on the surface that Part ran, so a Goal whose Parts
/// all used one surface has no reason to demand a second provider
/// subscription for its combined audit. A mixed-provider Goal keeps the Codex
/// default: no Part surface is more authoritative than another there.
fn native_goal_assurance_surface(
  part_surfaces : Array[@control.ProviderSurfaceId],
) -> @control.ProviderSurfaceId {
  let default = @control.ProviderSurfaceId::CodexSubscriptionCli
  let mut uniform : @control.ProviderSurfaceId? = None
  for surface in part_surfaces {
    match uniform {
      None => uniform = Some(surface)
      Some(value) => if value != surface { return default }
    }
  }
  match uniform {
    Some(value) => value
    None => default
  }
}

///|
test "Goal assurance runs on the surface its Parts already used" {
  let claude = @control.ProviderSurfaceId::ClaudeSubscriptionCli
  let codex = @control.ProviderSurfaceId::CodexSubscriptionCli
  assert_eq(native_goal_assurance_surface([claude, claude]), claude)
  assert_eq(native_goal_assurance_surface([codex]), codex)
  assert_eq(native_goal_assurance_surface([claude, codex]), codex)
  assert_eq(native_goal_assurance_surface([]), codex)
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
        (@storage_host.local_part_workflow_repository_adapters().artifacts.read)(
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
      // A Part that was retried carries a verification spec minted under a
      // superseded Take of that same Part. See the Part-level decode: the
      // spec identity and digest are what authorize it, and a Take this Part
      // has already retired still counts.
      match source_process.authority {
        @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
          take_id,
          spec_id,
          spec_digest
        ) if spec_id == source_spec.id &&
          spec_digest == source_spec.digest &&
          (
            take_id == snapshot.verification_take.id ||
            snapshot.prior_takes.any(fn(prior) { prior.id == take_id })
          ) => ()
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
  let surface = native_goal_assurance_surface(
    ordered.map(fn(snapshot) {
      snapshot.identities.implementation_session.surface
    }),
  )
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
/// Every repo path an integrated Part already owns: its declared exact
/// mutations plus the paths its accepted candidate actually changed. Combined
/// verification output is free-form command text, so routing never invents a
/// path from it — it only recognizes paths a Part already claimed.
fn native_goal_owned_repair_paths(
  snapshots : Array[@workflow.PartWorkflowSnapshot],
) -> Array[@control.RepoPath] {
  let owned : Array[@control.RepoPath] = []
  for snapshot in snapshots {
    match snapshot.task_contract.mutation_declaration {
      @control.MutationDeclaration::CompleteMutationDeclaration(claims) =>
        for claim in claims {
          match claim {
            @control.MutationClaim::ExactPath(path) =>
              if !owned.contains(path) {
                owned.push(path)
              }
            _ => ()
          }
        }
      _ => ()
    }
    match snapshot.candidate {
      Some(candidate) =>
        for path in candidate.changed_paths {
          if !owned.contains(path) {
            owned.push(path)
          }
        }
      None => ()
    }
  }
  owned.sort()
  owned
}

///|
/// Diagnose which owned paths the combined verification output implicates. A
/// path counts only when the evidence names it literally, so unrelated Parts
/// are never dragged into a repair they cannot perform.
fn native_goal_verification_repair_paths(
  evidence : String,
  owned : Array[@control.RepoPath],
) -> Array[@control.RepoPath] {
  let implicated : Array[@control.RepoPath] = []
  for path in owned {
    if evidence.contains(@control.repo_path_text(path)) &&
      !implicated.contains(path) {
      implicated.push(path)
    }
  }
  implicated
}

///|
test "combined verification routing recognizes only paths a Part already owns" {
  let owned = [
    @control.RepoPath("src/alpha/main.mbt"),
    @control.RepoPath("src/beta/main.mbt"),
  ]
  assert_eq(
    native_goal_verification_repair_paths(
      "FAILED src/beta/main.mbt:12 expected 1 got 2", owned,
    ),
    [@control.RepoPath("src/beta/main.mbt")],
  )
  // Undiagnosable output routes nowhere, which is what makes the Goal cancel
  // with retained evidence instead of looping on a repair nobody can perform.
  assert_eq(
    native_goal_verification_repair_paths(
      "combined verification exited 1 with no diagnosis", owned,
    ),
    [],
  )
  assert_eq(
    native_goal_verification_repair_paths(
      "src/alpha/main.mbt and src/beta/main.mbt disagree", owned,
    ),
    owned,
  )
  // A path no Part owns is never routable, however loudly the output names it.
  assert_eq(
    native_goal_verification_repair_paths("FAILED src/gamma/main.mbt:3", owned),
    [],
  )
}

///|
fn plan_and_persist_native_goal_audit_repairs(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  assurance : @workflow.GoalAssuranceRecord,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
) -> Result[@workflow.GoalAssuranceTickOutcome, @types.ChoirError] {
  let result = match assurance.audit_result {
    Some(value) => value
    None =>
      return Err(native_goal_execution_error("Goal audit result is absent"))
  }
  let findings_artifact = match result.findings_artifact {
    Some(value) => value
    None =>
      return Err(native_goal_execution_error("Goal audit findings are absent"))
  }
  let bytes = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: findings_artifact.digest,
      max_bytes: 1048576,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let terminal_response = @utf8.decode_lossy(bytes)
  let affected_paths = match
    @provider_host.native_blocking_audit_repair_paths(
      terminal_response,
      result.total_findings_count,
      result.blocking_findings_count,
    ) {
    Ok(value) => value
    Err(_) =>
      return Ok(
        @workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairFailed(
          @workflow.GoalAssuranceRepairKind::GoalAssuranceAuditRepair,
          result.result_digest,
          result.finished_at,
        ),
      )
  }
  let routes = match
    @workflow.plan_goal_repair_routes(snapshots, affected_paths) {
    Ok(value) => value
    Err(_) =>
      return Ok(
        @workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairFailed(
          @workflow.GoalAssuranceRepairKind::GoalAssuranceAuditRepair,
          result.result_digest,
          result.finished_at,
        ),
      )
  }
  let subject = result.subject
  let mut planned = 0
  for snapshot in snapshots {
    let assigned : Array[@control.RepoPath] = []
    for route in routes {
      if route.part_id == snapshot.part.id {
        for path in route.affected_paths {
          assigned.push(path)
        }
      }
    }
    if assigned.length() == 0 {
      continue
    }
    let repair : @control.AuditRepairReference = {
      scope: @control.AuditRepairScope::GoalAuditRepair,
      audit_result_id: result.id,
      audit_result_digest: result.result_digest,
      findings_artifact,
      affected_paths: assigned,
    }
    let decision = match
      plan_native_audit_repair_attempt(
        repository,
        snapshot,
        repair,
        terminal_response,
        { commit_oid: subject.goal_head_oid, tree_oid: subject.goal_tree_oid },
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let repaired = match decision {
      @workflow.PartAuditRepairDecision::PartAuditRepairPlanned(value) => value
      @workflow.PartAuditRepairDecision::PartAuditRepairLimitReached =>
        return Ok(
          @workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairFailed(
            @workflow.GoalAssuranceRepairKind::GoalAssuranceAuditRepair,
            result.result_digest,
            result.finished_at,
          ),
        )
    }
    let current = match
      @workflow.load_part_snapshot(repository, adapters, snapshot.workflow_id) {
      Ok(Some(value)) => value
      Ok(None) =>
        return Err(native_goal_execution_error("repair Part disappeared"))
      Err(error) => return Err(error)
    }
    if current.snapshot != snapshot {
      return Ok(@workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairing)
    }
    let persistence = match
      @workflow.persist_part_snapshot_guarded(
        repository,
        adapters,
        {
          snapshot: repaired,
          expected_store_version: Some(current.state_record.version),
          fault_point: None,
        },
        @workflow.goal_execution_state_precondition(execution),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match persistence {
      @workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPersisted(
        receipt
      ) =>
        match receipt.transaction_outcome {
          @storage.StateTransactionOutcome::StateTransactionCommitted
          | @storage.StateTransactionOutcome::StateTransactionReplayed
          | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
            planned = planned + 1
          _ =>
            return Err(
              native_goal_execution_error("Goal audit repair did not persist"),
            )
        }
      @workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPreconditionConflict =>
        return Ok(@workflow.GoalAssuranceTickOutcome::GoalAssurancePending)
    }
  }
  if planned == 0 {
    Ok(
      @workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairFailed(
        @workflow.GoalAssuranceRepairKind::GoalAssuranceAuditRepair,
        result.result_digest,
        result.finished_at,
      ),
    )
  } else {
    Ok(@workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairing)
  }
}

///|
/// The latest combined verification receipt that rejected the exact sealed
/// subject. Receipts from an earlier seal are stale evidence: repairing
/// against them would diagnose a tree the Goal no longer has.
fn native_failing_goal_verification_receipt(
  subject : @control.GoalVerificationSubject,
  receipts : Array[@control.GoalVerificationReceipt],
) -> @control.GoalVerificationReceipt? {
  let mut failing : @control.GoalVerificationReceipt? = None
  for receipt in receipts {
    if receipt.subject.subject_digest == subject.subject_digest &&
      receipt.outcome != @control.VerificationOutcome::VerificationPassed {
      match failing {
        Some(current) if current.finished_at >= receipt.finished_at => ()
        _ => failing = Some(receipt)
      }
    }
  }
  failing
}

///|
test "combined verification repair selects the exact sealed subject's newest failure" {
  let subject : @control.GoalVerificationSubject = {
    goal_id: @control.GoalId("goal-repair"),
    goal_branch_seal_id: @control.GoalBranchSealId("seal-repair"),
    goal_branch_seal_digest: @control.Digest("sha256:seal"),
    goal_head_oid: @control.GitOid("head-repair"),
    goal_tree_oid: @control.GitOid("tree-repair"),
    goal_contract_digest: @control.Digest("sha256:contract"),
    assurance_policy_revision: @control.RevisionId("policy-1"),
    integration_receipt_set_digest: @control.Digest("sha256:integrations"),
    subject_digest: @control.Digest("sha256:subject-current"),
  }
  let spec : @control.VerificationSpec = {
    id: @control.VerificationSpecId("spec-1"),
    version: 1,
    digest: @control.Digest("sha256:spec"),
    process_spec_digest: @control.Digest("sha256:process"),
  }
  let receipt = fn(
    label : String,
    subject_digest : @control.Digest,
    outcome : @control.VerificationOutcome,
    finished_at : Int64,
  ) -> @control.GoalVerificationReceipt {
    {
      receipt_id: @control.ReceiptId(label),
      verification_take_id: @control.TakeId("take-" + label),
      verification_execution_id: @control.VerificationExecutionId(
        "execution-" + label,
      ),
      subject: { ..subject, subject_digest, },
      verification_spec: spec,
      prepared_environment_and_image_digest: @control.Digest("sha256:image"),
      sandbox_runtime_and_policy_digest: @control.Digest("sha256:runtime"),
      subject_pre_tree_oid: subject.goal_tree_oid,
      subject_post_tree_oid: subject.goal_tree_oid,
      evidence: {
        artifact_id: "evidence-" + label,
        digest: @control.Digest("sha256:evidence-" + label),
      },
      started_at: finished_at - 1L,
      finished_at,
      outcome,
    }
  }
  let stale = receipt(
    "stale",
    @control.Digest("sha256:subject-previous"),
    @control.VerificationOutcome::VerificationFailed,
    900L,
  )
  let passed = receipt(
    "passed",
    subject.subject_digest,
    @control.VerificationOutcome::VerificationPassed,
    901L,
  )
  let first = receipt(
    "first",
    subject.subject_digest,
    @control.VerificationOutcome::VerificationFailed,
    902L,
  )
  let latest = receipt(
    "latest",
    subject.subject_digest,
    @control.VerificationOutcome::VerificationErrored,
    903L,
  )
  assert_eq(
    native_failing_goal_verification_receipt(subject, [
      stale, passed, latest, first,
    ]),
    Some(latest),
  )
  // A gate rejection with no failing receipt for this subject — a missing slot
  // or receipt — is not repairable and must not adopt stale evidence.
  assert_eq(
    native_failing_goal_verification_receipt(subject, [stale, passed]),
    None,
  )
}

///|
/// Combined Goal verification rejected the sealed tree. Route its retained
/// evidence to the integrated Parts that own the implicated paths and mint one
/// bounded repair revision each. Unrouteable evidence and exhausted repair
/// budgets return a typed repair failure, which the runner turns into a
/// cancellation carrying the failing receipt digest — never an inert block.
fn plan_and_persist_native_goal_verification_repairs(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  assurance : @workflow.GoalAssuranceRecord,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
) -> Result[@workflow.GoalAssuranceTickOutcome, @types.ChoirError] {
  let subject = match assurance.verification_subject {
    Some(value) => value
    None =>
      return Err(
        native_goal_execution_error("Goal verification subject is absent"),
      )
  }
  // No failing receipt means the gate rejected for a reason no repair can
  // answer (a missing slot or receipt). Retain the sealed subject as evidence.
  let receipt = match
    native_failing_goal_verification_receipt(
      subject,
      assurance.verification_receipts,
    ) {
    Some(value) => value
    None =>
      return Ok(
        @workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairFailed(
          @workflow.GoalAssuranceRepairKind::GoalAssuranceVerificationRepair,
          subject.subject_digest,
          assurance.seal_witnessed_at.unwrap_or(
            execution.durable_version.to_int64() + 1L,
          ),
        ),
      )
  }
  let exhausted = @workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairFailed(
    @workflow.GoalAssuranceRepairKind::GoalAssuranceVerificationRepair,
    receipt.evidence.digest,
    receipt.finished_at,
  )
  let bytes = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: receipt.evidence.digest,
      max_bytes: 4194304,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let evidence = @utf8.decode_lossy(bytes)
  let implicated = native_goal_verification_repair_paths(
    evidence,
    native_goal_owned_repair_paths(snapshots),
  )
  if implicated.length() == 0 {
    return Ok(exhausted)
  }
  let routes = match @workflow.plan_goal_repair_routes(snapshots, implicated) {
    Ok(value) => value
    Err(_) => return Ok(exhausted)
  }
  let mut planned = 0
  for snapshot in snapshots {
    let assigned : Array[@control.RepoPath] = []
    for route in routes {
      if route.part_id == snapshot.part.id {
        for path in route.affected_paths {
          assigned.push(path)
        }
      }
    }
    if assigned.length() == 0 {
      continue
    }
    let repair : @control.VerificationRepairReference = {
      scope: @control.VerificationRepairScope::GoalVerificationRepair,
      receipt_id: receipt.receipt_id,
      verification_execution_id: receipt.verification_execution_id,
      subject_digest: receipt.subject.subject_digest,
      verification_spec: receipt.verification_spec,
      evidence_artifact: receipt.evidence,
      affected_paths: assigned,
    }
    let decision = match
      plan_native_verification_repair_attempt(
        repository,
        snapshot,
        repair,
        evidence,
        {
          commit_oid: receipt.subject.goal_head_oid,
          tree_oid: receipt.subject.goal_tree_oid,
        },
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let repaired = match decision {
      @workflow.PartVerificationRepairDecision::PartVerificationRepairPlanned(
        value
      ) => value
      @workflow.PartVerificationRepairDecision::PartVerificationRepairLimitReached =>
        return Ok(exhausted)
    }
    let current = match
      @workflow.load_part_snapshot(repository, adapters, snapshot.workflow_id) {
      Ok(Some(value)) => value
      Ok(None) =>
        return Err(native_goal_execution_error("repair Part disappeared"))
      Err(error) => return Err(error)
    }
    if current.snapshot != snapshot {
      return Ok(@workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairing)
    }
    let persistence = match
      @workflow.persist_part_snapshot_guarded(
        repository,
        adapters,
        {
          snapshot: repaired,
          expected_store_version: Some(current.state_record.version),
          fault_point: None,
        },
        @workflow.goal_execution_state_precondition(execution),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match persistence {
      @workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPersisted(
        receipt
      ) =>
        match receipt.transaction_outcome {
          @storage.StateTransactionOutcome::StateTransactionCommitted
          | @storage.StateTransactionOutcome::StateTransactionReplayed
          | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost =>
            planned = planned + 1
          _ =>
            return Err(
              native_goal_execution_error(
                "Goal verification repair did not persist",
              ),
            )
        }
      @workflow.GuardedPartSnapshotPersistenceResult::GuardedPartSnapshotPreconditionConflict =>
        return Ok(@workflow.GoalAssuranceTickOutcome::GoalAssurancePending)
    }
  }
  if planned == 0 {
    Ok(exhausted)
  } else {
    Ok(@workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairing)
  }
}

///|
/// Advance one Goal's assurance, holding a portfolio provider slot for as long
/// as its audit session needs one.
///
/// The slot is taken lazily rather than for the whole tick: a Goal whose
/// assurance is already complete, blocked, or still sealing must not be refused
/// because Claude is busy — it is not asking Claude for anything. It is taken
/// before the first audit-session effect this tick touches and given back when
/// the tick returns, failure included.
async fn advance_native_goal_assurance(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
  capacity : @types.ProviderCapacityPolicy,
  executor_slot? : Int = 0,
  observe~ : (@workflow.ProviderSurfaceTickReport) -> Unit,
) -> Result[@workflow.GoalAssuranceTickOutcome, @types.ChoirError] {
  let fencing_epoch = current_native_goal_fencing_epoch()
  let holds : Array[NativeProviderLeaseHold] = []
  let result = advance_native_goal_assurance_attempt(
    project_dir,
    repository,
    adapters,
    execution,
    snapshots,
    capacity,
    fencing_epoch,
    holds,
    executor_slot,
    observe~,
  )
  finish_native_goal_assurance_leases(repository, holds, result, fencing_epoch)
}

///|
async fn advance_native_goal_assurance_attempt(
  project_dir : String,
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  snapshots : Array[@workflow.PartWorkflowSnapshot],
  capacity : @types.ProviderCapacityPolicy,
  fencing_epoch : @control.FencingEpoch,
  holds : Array[NativeProviderLeaseHold],
  executor_slot : Int,
  observe~ : (@workflow.ProviderSurfaceTickReport) -> Unit,
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
  let mut authorized_effect_id : @control.EffectId? = None
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
          match stored.record.blocked_reason {
            Some(
              @workflow.GoalAssuranceBlockReason::GoalAssuranceAuditBlocked(
                @control.AuditGateObservation::AuditGateRejected(
                  @control.AuditGateRejectionReason::AuditHasBlockingFindings
                )
              )
            ) => {
              let identity = match
                native_goal_ref_identity(git, execution.goal_ref) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
              let audited_head = match stored.record.audit_subject {
                Some(value) => value.goal_head_oid
                None =>
                  return Err(
                    native_goal_execution_error(
                      "blocked Goal audit subject is absent",
                    ),
                  )
              }
              if identity.0 != audited_head {
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
                let replacement = match
                  @workflow.initialize_goal_assurance(
                    execution,
                    snapshots,
                    identity.0,
                    identity.1,
                    plan.0,
                    plan.1,
                  ) {
                  Ok(value) =>
                    {
                      ..value,
                      durable_version: stored.state_record.version + 1,
                    }
                  Err(error) => return Err(error)
                }
                current = match
                  persist_native_goal_assurance_record(
                    repository,
                    adapters,
                    execution,
                    replacement,
                    Some(stored.state_record.version),
                  ) {
                  Ok(value) => value
                  Err(error) => return Err(error)
                }
                continue
              }
              return plan_and_persist_native_goal_audit_repairs(
                repository,
                adapters,
                execution,
                stored.record,
                snapshots,
              )
            }
            Some(
              @workflow.GoalAssuranceBlockReason::GoalAssuranceAuditBlocked(_)
            ) =>
              match stored.record.audit_result {
                Some(result) =>
                  return Ok(
                    @workflow.GoalAssuranceTickOutcome::GoalAssuranceRepairFailed(
                      @workflow.GoalAssuranceRepairKind::GoalAssuranceAuditRepair,
                      result.result_digest,
                      result.finished_at,
                    ),
                  )
                None =>
                  return Err(
                    native_goal_execution_error(
                      "blocked Goal audit result is absent",
                    ),
                  )
              }
            // Combined verification rejected the sealed tree. Route its
            // evidence to the owning Parts and repair, exactly as a rejected
            // Goal audit does; a stale gate observation reseals first.
            Some(
              @workflow.GoalAssuranceBlockReason::GoalAssuranceVerificationBlocked(
                @control.VerificationGateObservation::VerificationGateRejected(
                  _
                )
              )
            ) => {
              let identity = match
                native_goal_ref_identity(git, execution.goal_ref) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
              let verified_head = match stored.record.verification_subject {
                Some(value) => value.goal_head_oid
                None =>
                  return Err(
                    native_goal_execution_error(
                      "blocked Goal verification subject is absent",
                    ),
                  )
              }
              if identity.0 != verified_head {
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
                let replacement = match
                  @workflow.initialize_goal_assurance(
                    execution,
                    snapshots,
                    identity.0,
                    identity.1,
                    plan.0,
                    plan.1,
                  ) {
                  Ok(value) =>
                    {
                      ..value,
                      durable_version: stored.state_record.version + 1,
                    }
                  Err(error) => return Err(error)
                }
                current = match
                  persist_native_goal_assurance_record(
                    repository,
                    adapters,
                    execution,
                    replacement,
                    Some(stored.state_record.version),
                  ) {
                  Ok(value) => value
                  Err(error) => return Err(error)
                }
                continue
              }
              return plan_and_persist_native_goal_verification_repairs(
                repository,
                adapters,
                execution,
                stored.record,
                snapshots,
              )
            }
            // A stale or corrupt verification gate is an integrity problem, not
            // a failing candidate: no repair can answer it.
            Some(
              @workflow.GoalAssuranceBlockReason::GoalAssuranceVerificationBlocked(
                _
              )
            )
            | None =>
              return Ok(
                @workflow.GoalAssuranceTickOutcome::GoalAssuranceBlocked,
              )
          }
        }
        if stored.record.stage ==
          @workflow.GoalAssuranceStage::GoalAssuranceRecoveryUncertain {
          // A transient assurance provider failure used to park here forever.
          // Discharge the effects that demonstrably left no receipt so the
          // attempt is replanned with fresh identities on the next tick.
          match
            @workflow.reconcile_goal_assurance_recovery_uncertainty(
              stored.record,
            ) {
            Ok(
              @workflow.GoalAssuranceUncertaintyReconciliation::GoalAssuranceUncertaintyDischarged(
                discharged
              )
            ) => {
              current = match
                persist_native_goal_assurance_record(
                  repository,
                  adapters,
                  execution,
                  discharged,
                  Some(stored.state_record.version),
                ) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
              continue
            }
            Ok(
              @workflow.GoalAssuranceUncertaintyReconciliation::GoalAssuranceUncertaintyRetained
            ) =>
              return Ok(
                // The authorized effect may have occurred and cannot be
                // observed safely. Replaying would duplicate authority; the
                // runner converts this fail-closed outcome into typed terminal
                // cancellation instead of parking assurance forever.
                @workflow.GoalAssuranceTickOutcome::GoalAssuranceBlocked,
              )
            Err(error) => return Err(error)
          }
        }
        if stored.record.stage == @workflow.GoalAssuranceStage::GoalAuditPending &&
          stored.record.audit_result is Some(_) &&
          stored.record.pending_effect is None {
          let completed = match
            @workflow.mint_goal_audit_receipt(
              stored.record,
              {
                receipt_id: @control.ReceiptId(
                  stored.record.goal_id.0 +
                  ":" +
                  stored.record.audit_take.id.0 +
                  ":goal-audit-receipt",
                ),
                provider_surface_id: stored.record.identities.audit_session.surface,
                provider_identity: @harness.provider_receipt_identity(
                  stored.record.identities.audit_session.surface,
                ),
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
        // Portfolio admission, before this tick authorizes or runs anything on
        // a provider surface. It sits ahead of the whole `pending_effect`
        // match, not inside one arm, so the authorize step and the retry-safe
        // re-execute step are both covered by one decision: a slot has to be
        // held before an audit effect becomes authorized, or the next tick
        // inherits an effect that may have occurred without one.
        match record.pending_effect {
          Some(intent) =>
            match
              native_goal_assurance_effect_admission(
                repository,
                record.goal_id,
                record.audit_take.id,
                record.identities,
                intent.kind,
                capacity,
                fencing_epoch,
                @env.now().reinterpret_as_int64() / 1000L,
                holds,
                observe~,
              ) {
              Ok(Some(deferred)) => return Ok(deferred)
              Ok(None) => ()
              Err(error) => return Err(error)
            }
          None => ()
        }
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
                        repository, execution, git, record, intent, executor_slot,
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
                    repository, execution, git, record, intent, executor_slot,
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
                  @part_host.native_part_artifact_exists(repository, reference)
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
  pull_request_delivery? : @types.PullRequestDeliveryPolicy = {
    mode: @types.PullRequestDeliveryMode::PullRequestReviewOnly,
    merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
  },
  provider_capacity? : @types.ProviderCapacityPolicy = @types.Config::default().provider_capacity,
  beads_capture~ : async (@process_host.Command) -> (Int, String),
  reconcile_sources~ : async (
    String,
    @workflow.PartWorkflowRepository,
    @workflow.GoalExecutionRecord,
  ) -> Result[Unit, @types.ChoirError],
  goal_id? : @control.GoalId? = None,
  executor_slot? : Int = 0,
  observe? : (@workflow.ProviderSurfaceTickReport) -> Unit = fn(_) { () },
) -> Result[@workflow.GoalExecutionTickResult, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let repository_adapters = @storage_host.local_part_workflow_repository_adapters()
  match
    @workflow.initialize_part_workflow_repository(
      repository, repository_adapters,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let result = @workflow.run_next_goal_execution_tick(
    repository,
    repository_adapters,
    fencing_epoch=current_native_goal_fencing_epoch(),
    goal_id~,
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
        execute_native_goal_record(
          project_dir,
          repository,
          record,
          snapshots,
          provider_capacity,
          executor_slot~,
          observe~,
        )
      },
      assure: async fn(record, snapshots) {
        advance_native_goal_assurance(
          project_dir,
          repository,
          repository_adapters,
          record,
          snapshots,
          provider_capacity,
          executor_slot~,
          observe~,
        )
      },
      finalize: async fn(record, _) {
        match advance_native_goal_publication(project_dir, record.goal.id) {
          Ok(@workflow.GoalPublicationTickOutcome::GoalPublicationComplete) =>
            ()
          Ok(
            @workflow.GoalPublicationTickOutcome::GoalPublicationRemoteUnavailable
          ) =>
            return Ok(
              if pull_request_delivery.mode ==
                @types.PullRequestDeliveryMode::PullRequestAutoMerge {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationPending
              } else {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationPublicationRemoteUnavailable
              },
            )
          Ok(@workflow.GoalPublicationTickOutcome::GoalPublicationDrifted) =>
            return Ok(
              if pull_request_delivery.mode ==
                @types.PullRequestDeliveryMode::PullRequestAutoMerge {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationDeliveryFailed(
                  @storage.artifact_digest(
                    @utf8.encode(
                      "choir.automatic-delivery.publication-drift.v1\u{00}" +
                      record.goal.id.0,
                    ),
                  ),
                )
              } else {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationDrifted
              },
            )
          Ok(
            @workflow.GoalPublicationTickOutcome::GoalPublicationRecoveryUncertain
          ) =>
            return Ok(
              if pull_request_delivery.mode ==
                @types.PullRequestDeliveryMode::PullRequestAutoMerge {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationPending
              } else {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationRecoveryUncertain
              },
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
            delivery_policy=pull_request_delivery,
          ) {
          Ok(@workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete) =>
            ()
          Ok(
            @workflow.GoalPullRequestTickOutcome::GoalPullRequestNeedsUserInput
          ) =>
            return Ok(
              if pull_request_delivery.mode ==
                @types.PullRequestDeliveryMode::PullRequestAutoMerge {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationDeliveryFailed(
                  @storage.artifact_digest(
                    @utf8.encode(
                      "choir.automatic-delivery.pull-request-input.v1\u{00}" +
                      record.goal.id.0,
                    ),
                  ),
                )
              } else {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationNeedsUserInput
              },
            )
          Ok(
            @workflow.GoalPullRequestTickOutcome::GoalPullRequestRecoveryUncertain
          ) =>
            return Ok(
              if pull_request_delivery.mode ==
                @types.PullRequestDeliveryMode::PullRequestAutoMerge {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationPending
              } else {
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationRecoveryUncertain
              },
            )
          Ok(
            @workflow.GoalPullRequestTickOutcome::GoalPullRequestDeliveryFailed(
              digest
            )
          ) =>
            return Ok(
              @workflow.GoalFinalizationTickOutcome::GoalFinalizationDeliveryFailed(
                digest,
              ),
            )
          Ok(_) =>
            return Ok(
              @workflow.GoalFinalizationTickOutcome::GoalFinalizationPending,
            )
          Err(error) => return Err(error)
        }
        let outcome = match
          advance_native_goal_finalization_with_adapters(
            project_dir,
            record.goal.id,
            forge,
            reconcile_sources~,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if pull_request_delivery.mode ==
          @types.PullRequestDeliveryMode::PullRequestAutoMerge {
          match outcome {
            @workflow.GoalFinalizationTickOutcome::GoalFinalizationPublicationRemoteUnavailable
            | @workflow.GoalFinalizationTickOutcome::GoalFinalizationRecoveryUncertain =>
              Ok(@workflow.GoalFinalizationTickOutcome::GoalFinalizationPending)
            @workflow.GoalFinalizationTickOutcome::GoalFinalizationNeedsUserInput
            | @workflow.GoalFinalizationTickOutcome::GoalFinalizationDrifted
            | @workflow.GoalFinalizationTickOutcome::GoalFinalizationAmbiguous =>
              Ok(
                @workflow.GoalFinalizationTickOutcome::GoalFinalizationDeliveryFailed(
                  @storage.artifact_digest(
                    @utf8.encode(
                      "choir.automatic-delivery.finalization.v1\u{00}" +
                      record.goal.id.0 +
                      "\u{00}" +
                      outcome.to_json().stringify(indent=0),
                    ),
                  ),
                ),
              )
            _ => Ok(outcome)
          }
        } else {
          Ok(outcome)
        }
      },
      cancel: async fn(record, snapshots) {
        let pending = @workflow.GoalCancellationDisposition::GoalCancellationPending
        let observed_at = match record.cancellation_request {
          Some(request) => request.requested_at
          None =>
            return Err(
              native_goal_execution_error(
                "canceling Goal has no cancellation request",
              ),
            )
        }
        // Neutralize the remote pull request first. While the forge still has
        // authority to merge this Goal's exact head, its source Beads are not
        // free to release and cancellation must not commit.
        let finalization = match
          reconcile_native_goal_finalization_cancellation(
            project_dir, repository, repository_adapters, record, forge, observed_at,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        match finalization {
          @workflow.GoalCancellationDisposition::GoalCancellationPending =>
            return Ok(pending)
          @workflow.GoalCancellationDisposition::GoalCancellationSupersededByDelivery(
            _
          ) =>
            // Delivery beat cancellation. The integrated work shipped, so its
            // source Beads close at the delivery boundary rather than being
            // released back to the ready queue.
            match
              reconcile_native_integrated_part_sources(
                project_dir,
                repository,
                record,
                capture=beads_capture,
              ) {
              Ok(_) => {
                match cleanup_native_goal_runtime(record) {
                  Ok(_) => ()
                  Err(error) => return Err(error)
                }
                return Ok(finalization)
              }
              Err(error) => return Err(error)
            }
          @workflow.GoalCancellationDisposition::GoalCancellationNeutralized =>
            ()
        }
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
          return Ok(pending)
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
          return Ok(pending)
        }
        match
          reconcile_native_goal_part_cancellation(
            project_dir, repository, repository_adapters, record, snapshots,
          ) {
          Ok((reconciled, assurance_known)) => {
            let terminal_ready = native_goal_cancellation_can_finish(reconciled) &&
              assurance_known
            match
              finish_native_goal_runtime(terminal_ready, async fn() {
                cleanup_native_goal_runtime(record)
              }) {
              Ok(true) =>
                Ok(
                  @workflow.GoalCancellationDisposition::GoalCancellationNeutralized,
                )
              Ok(false) => Ok(pending)
              Err(error) => Err(error)
            }
          }
          Err(error) => Err(error)
        }
      },
    },
  )
  result
}

///|
/// Run one exact durably leased Goal job.
///
/// The lease check is passive: it authorizes this executor but does not create
/// or repair the lease. Provider observations are task-local so one Goal's
/// deferral becomes only that Goal's due-at state.
pub async fn run_native_goal_execution_job_with_forge(
  project_dir : String,
  lease : @workflow.GoalExecutorLease,
  forge : NativePullRequestForgeAdapters,
  pull_request_delivery? : @types.PullRequestDeliveryPolicy = {
    mode: @types.PullRequestDeliveryMode::PullRequestReviewOnly,
    merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
  },
  provider_capacity? : @types.ProviderCapacityPolicy = @types.Config::default().provider_capacity,
  beads_capture~ : async (@process_host.Command) -> (Int, String),
  reconcile_sources~ : async (
    String,
    @workflow.PartWorkflowRepository,
    @workflow.GoalExecutionRecord,
  ) -> Result[Unit, @types.ChoirError],
) -> (
  Result[@workflow.GoalExecutionTickResult, @types.ChoirError],
  Array[@workflow.ProviderSurfaceTickReport],
) {
  if lease.fencing_epoch != current_native_goal_fencing_epoch() {
    return (
      Err(native_goal_execution_error("Goal executor lease fence is stale")),
      [],
    )
  }
  let repository = native_goal_repository(project_dir)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return (Err(error), [])
  }
  match
    @workflow.goal_executor_lease_is_authorized(repository, adapters, lease) {
    Ok(true) => ()
    Ok(false) =>
      return (
        Err(native_goal_execution_error("Goal executor lease is not held")),
        [],
      )
    Err(error) => return (Err(error), [])
  }
  let reports : Array[@workflow.ProviderSurfaceTickReport] = []
  let result = run_native_goal_execution_tick_with_forge(
    project_dir,
    forge,
    pull_request_delivery~,
    provider_capacity~,
    beads_capture~,
    reconcile_sources~,
    goal_id=Some(lease.goal_id),
    executor_slot=lease.slot,
    observe=fn(report) {
      let merged = @workflow.record_provider_surface_tick_report(
        reports, report,
      )
      reports.clear()
      for value in merged {
        reports.push(value)
      }
    },
  )
  (result, reports)
}

///|
pub async fn run_native_goal_execution_job(
  project_dir : String,
  lease : @workflow.GoalExecutorLease,
  pull_request_delivery? : @types.PullRequestDeliveryPolicy = {
    mode: @types.PullRequestDeliveryMode::PullRequestReviewOnly,
    merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
  },
  provider_capacity? : @types.ProviderCapacityPolicy = @types.Config::default().provider_capacity,
) -> (
  Result[@workflow.GoalExecutionTickResult, @types.ChoirError],
  Array[@workflow.ProviderSurfaceTickReport],
) {
  run_native_goal_execution_job_with_forge(
    project_dir,
    lease,
    native_pull_request_forge_adapters(),
    pull_request_delivery~,
    provider_capacity~,
    beads_capture=@process_host.capture_command_merged,
    reconcile_sources=reconcile_native_goal_delivery_sources,
  )
}

///|
pub fn plan_native_goal_executor_dispatches(
  project_dir : String,
  capacity : @types.GoalExecutorCapacityPolicy,
) -> Result[@workflow.GoalExecutorDispatchBatch, @types.ChoirError] {
  match @types.validate_goal_executor_capacity_policy(capacity) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let repository = native_goal_repository(project_dir)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  @workflow.acquire_goal_executor_dispatches(
    repository,
    adapters,
    capacity.maximum_parallel_jobs,
    @env.now().reinterpret_as_int64() / 1000L,
    current_native_goal_fencing_epoch(),
  )
}

///|
pub fn complete_native_goal_executor_dispatch(
  project_dir : String,
  lease : @workflow.GoalExecutorLease,
  outcome : @workflow.GoalExecutionJobTickOutcome,
) -> Result[@workflow.GoalExecutionJob, @types.ChoirError] {
  @workflow.persist_goal_executor_completion(
    native_goal_repository(project_dir),
    @storage_host.local_part_workflow_repository_adapters(),
    lease,
    outcome,
    @env.now().reinterpret_as_int64() / 1000L,
  )
}

///|
pub fn native_goal_executor_provider_reports(
  project_dir : String,
  goal_id : @control.GoalId,
) -> Result[Array[@workflow.ProviderSurfaceTickReport], @types.ChoirError] {
  match
    @workflow.load_goal_execution_job(
      native_goal_repository(project_dir),
      @storage_host.local_part_workflow_repository_adapters(),
      goal_id,
    ) {
    Ok(Some(job)) => Ok(job.provider_reports)
    Ok(None) => Ok([])
    Err(error) => Err(error)
  }
}

///|
pub async fn run_native_goal_execution_tick(
  project_dir : String,
  pull_request_delivery? : @types.PullRequestDeliveryPolicy = {
    mode: @types.PullRequestDeliveryMode::PullRequestReviewOnly,
    merge_method: @types.PullRequestMergeMethod::PullRequestSquashMerge,
  },
  provider_capacity? : @types.ProviderCapacityPolicy = @types.Config::default().provider_capacity,
) -> Result[@workflow.GoalExecutionTickResult, @types.ChoirError] {
  run_native_goal_execution_tick_with_forge(
    project_dir,
    native_pull_request_forge_adapters(),
    pull_request_delivery~,
    provider_capacity~,
    beads_capture=@process_host.capture_command_merged,
    reconcile_sources=reconcile_native_goal_delivery_sources,
  )
}

///|
fn native_goal_owned_git_ref_is_valid(reference : String) -> Bool {
  @git_integration.valid_git_ref(reference, "refs/heads/choir/goals/") ||
  @git_integration.valid_git_ref(reference, "refs/choir/goals/") ||
  @git_integration.valid_git_ref(reference, "refs/choir/witness/")
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
  if observed.exit_code != 0 || !@git_integration.valid_hex_oid_text(oid) {
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
  capture : async (@process_host.Command) -> (Int, String),
) -> Result[Array[NativeOrphanedGoalSourceClaim], @types.ChoirError] {
  let output = match
    @beads_host.native_conductor_capture_beads(
      project_dir,
      "list",
      ["list", "--json", "--all", "--readonly"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let tasks = match @beads_host.native_conductor_tasks_from_output(output) {
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
  capture : async (@process_host.Command) -> (Int, String),
) -> Result[Int, @types.ChoirError] {
  let mut released = 0
  for claim in claims {
    let output = match
      @beads_host.native_conductor_capture_beads(
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
    let task = match @beads_host.native_conductor_tasks_from_output(output) {
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
/// The repository root every owned-ref operation resolves against.
async fn native_goal_canonical_repository_root(
  project_dir : String,
) -> Result[String, @types.ChoirError] {
  let root = match
    native_goal_git_value(project_dir, ["rev-parse", "--show-toplevel"]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match @sys.realpath_native(root) {
    Some(value) => Ok(value)
    None => Err(native_goal_execution_error("repository is not canonical"))
  }
}

///|
async fn purge_native_goal_owned_git_ref_namespace(
  project_dir : String,
) -> Result[Int, @types.ChoirError] {
  let canonical_root = match
    native_goal_canonical_repository_root(project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
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
/// Goal identities this repository is still working on.
pub fn list_native_active_goal_ids(
  project_dir : String,
) -> Result[Array[@control.GoalId], @types.ChoirError] {
  let active : Array[@control.GoalId] = []
  match
    @workflow.list_goal_execution_records(
      native_goal_repository(project_dir),
      @storage_host.local_part_workflow_repository_adapters(),
    ) {
    Ok(records) =>
      for stored in records {
        if !@workflow.goal_execution_state_is_terminal(stored.record.state) {
          active.push(stored.record.goal.id)
        }
      }
    Err(error) => return Err(error)
  }
  Ok(active)
}

///|
async fn cleanup_native_goal_runtime_at_key(
  repository_id : @workflow.RepositoryId,
  temporary_root : String,
  key : String,
) -> Result[Unit, @types.ChoirError] {
  let binary = match @process_host.native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_dir = match @process_host.native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let home = match native_goal_boxlite_home(repository_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let config : @take_host.NativeBoxLiteServerConfig = {
    binary,
    runtime_dir,
    root: temporary_root +
    "/" +
    native_goal_runtime_entry_prefix(repository_id) +
    key,
    home,
    port: 40000 + @sys.get_pid() % 10000,
    api_key: "choir-goal-" + key,
  }
  let root = config.root
  let receipt = match read_native_goal_runtime_receipt(root) {
    Some(value) if value.repository_id == repository_id &&
      native_goal_runtime_key(value.repository_id, value.goal_id) == key =>
      value
    _ =>
      return Err(native_goal_execution_error("runtime ownership is unproven"))
  }
  let box_ids = match @part_host.native_runtime_owned_box_ids(root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.base_box_id {
    Some(value) => if !box_ids.contains(value) { box_ids.push(value) }
    None => ()
  }
  @take_host.cleanup_native_boxlite_owned_runtime(config, box_ids)
}

///|
/// Reclaim Goal runtime roots this repository no longer references.
///
/// Runs on every daemon start rather than only on a control-state generation
/// change. Reclaiming by Bead claim alone missed every Goal whose claim was
/// already released, so an abandoned root survived until the machine
/// rebooted; each root carries a BoxLite home and a staged toolchain, so a
/// few of them fill a tmpfs. Returns how many roots were removed.
pub async fn reclaim_native_goal_runtime_roots(
  project_dir : String,
  temporary_root? : String = "/tmp",
  list_dir? : (String) -> Array[String] = @sys.list_dir_all,
) -> Result[Int, @types.ChoirError] {
  let repository_id = match native_goal_repository_id(project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let goal_states : Array[
    (@workflow.RepositoryId, @control.GoalId, @workflow.GoalExecutionState),
  ] = []
  match
    @workflow.list_goal_execution_records(
      native_goal_repository(project_dir),
      @storage_host.local_part_workflow_repository_adapters(),
    ) {
    Ok(records) =>
      for stored in records {
        goal_states.push(
          (
            stored.record.repository_id,
            stored.record.goal.id,
            stored.record.state,
          ),
        )
      }
    // An unreadable Goal store cannot prove which roots are live, and removing
    // a root a running Goal still owns is worse than leaving it behind.
    Err(_) => return Ok(0)
  }
  let mut removed = 0
  for
    entry in native_repository_goal_runtime_roots(
      repository_id,
      list_dir(temporary_root),
    ) {
    let prefix = native_goal_runtime_entry_prefix(repository_id)
    let key = entry[prefix.length():].to_owned()
    let root = temporary_root + "/" + entry
    if !@sys.path_entry_exists(root) {
      continue
    }
    let receipt = match read_native_goal_runtime_receipt(root) {
      Some(value) if value.repository_id == repository_id &&
        native_goal_runtime_key(value.repository_id, value.goal_id) == key =>
        value
      _ => continue
    }
    let mut owner_state : @workflow.GoalExecutionState? = None
    let mut owner_matches = 0
    for stored in goal_states {
      let (stored_repository, stored_goal, stored_state) = stored
      if stored_repository == receipt.repository_id &&
        stored_goal == receipt.goal_id {
        owner_matches = owner_matches + 1
        owner_state = Some(stored_state)
      }
    }
    if owner_matches > 1 {
      continue
    }
    match
      @workflow.plan_goal_runtime_reclamation(
        repository_id,
        receipt.repository_id,
        owner_state,
      ) {
      @workflow.GoalRuntimeReclaimDecision::GoalRuntimeReclaimOwnedStale => ()
      _ => continue
    }
    match
      cleanup_native_goal_runtime_at_key(repository_id, temporary_root, key) {
      Ok(_) => removed = removed + 1
      Err(error) => return Err(error)
    }
  }
  Ok(removed)
}

///|
/// Observe the control store without deciding anything about it.
fn observe_native_goal_control_state(
  control_root : String,
) -> @storage.ControlStateObservation {
  let workflow_store_path = control_root + "/workflow.db"
  let store_present = @sys.path_entry_exists(workflow_store_path)
  let unreadable : @storage.ControlStateObservation = {
    store_present,
    store_readable: false,
    recorded_generation: None,
    recorded_ddl_version: @storage.control_store_unstamped_ddl_version,
    // Anything left under the root with no store is an unfinished reset.
    residue_present: !store_present &&
    @sys.list_dir_all(control_root).length() > 0,
  }
  if !store_present {
    return unreadable
  }
  let store : @storage.SqliteStateStore = { path: workflow_store_path }
  // Both reads fail on a store that is not a database at all, and either one
  // failing is the same answer: nothing recorded in it can be trusted.
  match
    (
      @storage_host.read_state_store_generation(store),
      @storage_host.read_state_store_ddl_version(store),
    ) {
    (Ok(recorded_generation), Ok(recorded_ddl_version)) =>
      {
        store_present: true,
        store_readable: true,
        recorded_generation,
        recorded_ddl_version,
        residue_present: false,
      }
    _ => unreadable
  }
}

///|
/// What the control store has to say about itself for this build to use it.
///
/// Two independent halves. The generation is derived from the durable value
/// shapes, so it moves when what this build can decode moves. The DDL version
/// is declared beside the `CREATE TABLE` statements, because no digest over
/// values can see that a table is missing a column.
fn native_goal_control_store_schema() -> @storage.ControlStoreSchema {
  {
    generation: @workflow.durable_value_shape_generation(),
    ddl_version: @storage_host.state_store_ddl_version(),
  }
}

///|
/// Record what the store now answers to. Both halves are written together
/// because a plan that adopts a store adopts it whole.
fn record_native_goal_control_store_schema(
  store : @storage.SqliteStateStore,
  schema : @storage.ControlStoreSchema,
) -> Result[Unit, @types.ChoirError] {
  match @storage_host.write_state_store_generation(store, schema.generation) {
    Ok(_) =>
      @storage_host.write_state_store_ddl_version(store, schema.ddl_version)
    Err(error) => Err(error)
  }
}

///|
/// Read every durable record and report the first this build cannot decode.
///
/// This is the evidence the destructive branch needs. A moved generation says
/// the durable shapes changed, not that they changed incompatibly: derived
/// decoding tolerates a missing optional key and ignores keys it does not know,
/// so an added optional field or a new enum variant moves the generation while
/// every stored record still reads. Asking the decoders is the only way to tell
/// those apart, and it is asked only when the generations already disagree.
///
/// A record whose content is not in the artifact store is skipped rather than
/// counted against the schema. Content that is not there cannot demonstrate
/// that the shapes moved incompatibly, and this branch destroys the store.
///
/// A read that fails outright is neither evidence nor a verdict, so it comes
/// back as an error and `choir serve` leaves the store alone and says so. The
/// scan reads under the same size limit `native_goal_repository` reads under,
/// so it does not accept a record the loader for this store would refuse.
pub fn probe_native_durable_record_decoding(
  control_root : String,
) -> Result[@storage.StateRecordKey?, @types.ChoirError] {
  let store : @storage.SqliteStateStore = {
    path: control_root + "/workflow.db",
  }
  let artifacts : @storage.ArtifactStore = { root: control_root + "/artifacts" }
  for kind in @workflow.durable_record_kinds() {
    let records = match
      @storage_host.list_state_records(
        store,
        @workflow.durable_record_key_prefix(kind),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    for record in records {
      match
        @storage_host.artifact_store_contains(artifacts, record.value_digest) {
        Ok(true) => ()
        Ok(false) => continue
        Err(error) => return Err(error)
      }
      let content = match
        @storage_host.read_artifact(artifacts, {
          digest: record.value_digest,
          max_bytes: native_goal_max_snapshot_bytes(),
        }) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !@workflow.durable_record_decodes(kind, content) {
        return Ok(Some(record.key))
      }
    }
  }
  Ok(None)
}

///|
/// Bring the control store to a state this build can use.
///
/// The decision is made in `@storage.decide_control_state` and only applied
/// here. That separation is the point: the destructive branch releases claims,
/// purges Choir's ref namespace, and removes the whole control root, and it
/// used to be authorized by a missing sibling file inside an effect path where
/// nobody could test it in isolation.
///
/// Runtime cleanup and ref purging are injected for the same reason `capture`
/// is: the branch that reaches them is the one worth driving in a test, and it
/// otherwise needs a real repository to reach at all.
pub async fn prepare_native_goal_control_state_with(
  project_dir : String,
  capture~ : async (@process_host.Command) -> (Int, String),
  cleanup_runtime~ : async (@workflow.RepositoryId, @control.GoalId) -> Result[
    Unit,
    @types.ChoirError,
  ],
  purge_refs~ : async (String) -> Result[Int, @types.ChoirError],
) -> Result[NativeGoalControlStatePreparation, @types.ChoirError] {
  let control_root = project_dir + "/.choir/state/control"
  let workflow_store_path = control_root + "/workflow.db"
  let schema = native_goal_control_store_schema()
  let plan = match
    @storage.decide_control_state(
      observe_native_goal_control_state(control_root),
      schema,
    ) {
    @storage.ControlStateDecision::ControlStatePlanned(
      @storage.ControlStatePlan::ControlStateCurrent
    ) =>
      // The stamp is a fast description of the store, not proof about every
      // row still present in it. A retained row can have been adopted under an
      // incomplete shape witness or otherwise become undecodable while the
      // metadata remains current. The real repository decoder would then fail
      // every portfolio tick, so prove the rows at the startup boundary too.
      match probe_native_durable_record_decoding(control_root) {
        Ok(Some(key)) =>
          @storage.decide_control_state_from_records(
            schema.generation,
            schema,
            Some(key),
          )
        Ok(None) => @storage.ControlStatePlan::ControlStateCurrent
        Err(error) => return Err(error)
      }
    @storage.ControlStateDecision::ControlStatePlanned(planned) => planned
    // The generations disagree, which settles nothing on its own. Read the
    // records and let what they decode to decide.
    @storage.ControlStateDecision::ControlStateProveRecordsDecodable(
      recorded,
      _
    ) =>
      match probe_native_durable_record_decoding(control_root) {
        Ok(undecodable) =>
          @storage.decide_control_state_from_records(
            recorded, schema, undecodable,
          )
        Err(error) => return Err(error)
      }
  }
  match plan {
    @storage.ControlStatePlan::ControlStateCurrent =>
      Ok(NativeGoalControlStateCurrent)
    // A store whose records still decode is adopted, not destroyed. Recording
    // what it now answers to is the whole of the migration.
    @storage.ControlStatePlan::ControlStateMigrate(_, target) =>
      match
        record_native_goal_control_store_schema(
          { path: workflow_store_path },
          target,
        ) {
        Ok(_) => Ok(NativeGoalControlStateCurrent)
        Err(error) => Err(error)
      }
    @storage.ControlStatePlan::ControlStateInitialize =>
      match native_goal_control_state_create(control_root, schema) {
        Ok(_) => Ok(NativeGoalControlStateInitialized)
        Err(error) => Err(error)
      }
    @storage.ControlStatePlan::ControlStateAuthorizedReset(reason) => {
      let purged = match
        cleanup_native_goal_owned_resources(
          project_dir, capture, cleanup_runtime, purge_refs,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let report : NativeGoalControlStateResetReport = {
        source_claims_released: purged.source_claims_released,
        runtime_roots_removed: purged.runtime_roots_removed,
        git_refs_removed: purged.git_refs_removed,
        reason,
      }
      // The store is about to be replaced at the same path. A pooled
      // connection would survive the unlink and keep serving the deleted
      // inode, so it is dropped before the file goes.
      @storage_host.forget_state_store({ path: workflow_store_path })
      if !@sys.rm_rf(control_root) {
        return Err(native_goal_execution_error("control state reset failed"))
      }
      match native_goal_control_state_create(control_root, schema) {
        Ok(_) => Ok(NativeGoalControlStateReset(report))
        Err(error) => Err(error)
      }
    }
  }
}

///|
pub async fn prepare_native_goal_control_state(
  project_dir : String,
) -> Result[NativeGoalControlStatePreparation, @types.ChoirError] {
  prepare_native_goal_control_state_with(
    project_dir,
    capture=@process_host.capture_command_merged,
    cleanup_runtime=cleanup_native_goal_runtime_identity,
    purge_refs=purge_native_goal_owned_git_ref_namespace,
  )
}

///|
/// Create an empty control store and record what schema it holds. The
/// generation is written into the store rather than beside it, so losing it
/// separately is not possible.
fn native_goal_control_state_create(
  control_root : String,
  schema : @storage.ControlStoreSchema,
) -> Result[Unit, @types.ChoirError] {
  if !@sys.create_dir_all(control_root) {
    return Err(native_goal_execution_error("control state reset failed"))
  }
  let store : @storage.SqliteStateStore = {
    path: control_root + "/workflow.db",
  }
  match @storage_host.initialize_state_store(store) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  record_native_goal_control_store_schema(store, schema)
}

///|
async fn cleanup_native_goal_owned_resources(
  project_dir : String,
  capture : async (@process_host.Command) -> (Int, String),
  cleanup_runtime : async (@workflow.RepositoryId, @control.GoalId) -> Result[
    Unit,
    @types.ChoirError,
  ],
  purge_refs : async (String) -> Result[Int, @types.ChoirError],
) -> Result[NativeGoalPurgeReport, @types.ChoirError] {
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
    match cleanup_runtime(repository_id, goal_id) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    if existed {
      runtime_roots_removed = runtime_roots_removed + 1
    }
  }
  let git_refs_removed = match purge_refs(project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source_claims_released = match
    release_native_orphaned_goal_source_claims(project_dir, claims, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({ source_claims_released, runtime_roots_removed, git_refs_removed })
}

///|
async test "orphaned claim reset releases only Choir-owned in-progress Beads" {
  let calls : Array[Array[String]] = []
  let capture = async fn(command : @process_host.Command) {
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
pub async fn purge_native_goal_resources_with(
  project_dir : String,
  capture~ : async (@process_host.Command) -> (Int, String),
  cleanup_runtime~ : async (@workflow.RepositoryId, @control.GoalId) -> Result[
    Unit,
    @types.ChoirError,
  ],
  purge_refs~ : async (String) -> Result[Int, @types.ChoirError],
) -> Result[NativeGoalPurgeReport, @types.ChoirError] {
  // Purge is the recovery path for incompatible durable state, so it must not
  // decode that state before deleting it. Discover owned live resources from
  // Bead claims and exact Git namespaces instead.
  cleanup_native_goal_owned_resources(
    project_dir, capture, cleanup_runtime, purge_refs,
  )
}

///|
pub async fn purge_native_goal_resources(
  project_dir : String,
) -> Result[NativeGoalPurgeReport, @types.ChoirError] {
  purge_native_goal_resources_with(
    project_dir,
    capture=@process_host.capture_command_merged,
    cleanup_runtime=cleanup_native_goal_runtime_identity,
    purge_refs=purge_native_goal_owned_git_ref_namespace,
  )
}

///|
/// What archiving one Goal did, or — for a dry run or a refusal — would have
/// done. The counts are what the host actually observed removing, not what the
/// plan asked for: a witness ref another process already deleted, or content an
/// interrupted earlier run already unlinked, is not reported as removed here.
pub(all) struct NativeGoalArchiveReport {
  decision : @workflow.GoalArchiveDecision
  /// False for every refusal and every dry run: nothing was changed.
  applied : Bool
  refs_removed : Int
  artifacts_released : Int
  outbox_events_released : Int
} derive(Debug, Eq)

///|
/// Every ref this repository currently holds under the Goal namespaces.
///
/// The archive names refs from what was listed rather than from what it
/// expects to exist, which is what lets a dry run promise exactly the set an
/// apply removes.
async fn list_native_goal_owned_git_refs(
  project_dir : String,
) -> Result[Array[@workflow.GitRefName], @types.ChoirError] {
  let canonical_root = match
    native_goal_canonical_repository_root(project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // `refs/choir/witness/` holds the per-Part integration witnesses, whose names
  // are digests with no Goal in them. Listing them hands the planner every
  // Goal's; only the ones the archived Goal's own Parts recorded come back as
  // releasable.
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
  let references : Array[@workflow.GitRefName] = []
  for raw in captured.output.split("\n") {
    let reference = raw.trim().to_owned()
    if reference != "" {
      references.push(@workflow.GitRefName(reference))
    }
  }
  Ok(references)
}

///|
async fn delete_native_goal_archived_git_refs(
  project_dir : String,
  references : Array[@workflow.GitRefName],
) -> Result[Int, @types.ChoirError] {
  if references.length() == 0 {
    return Ok(0)
  }
  let canonical_root = match
    native_goal_canonical_repository_root(project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repository : NativeGoalRepositoryIdentity = {
    root: canonical_root,
    git_directory: "",
    object_directory: "",
  }
  let mut removed = 0
  for reference in references {
    match delete_native_goal_owned_git_ref(repository, reference.0) {
      Ok(true) => removed = removed + 1
      Ok(false) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(removed)
}

///|
/// Archive one terminal Goal: observe what it still holds, let
/// `@workflow.plan_goal_archive` decide, and apply that decision unless this
/// is a dry run.
///
/// Nothing here decides what may be released. This gathers the durable record,
/// the refs the repository actually has, and the retention ledger; every
/// judgment about terminality and reachability is the control plane's.
///
/// The Goal's sandbox runtime root is not touched. `cleanup_native_goal_runtime`
/// already removes it at the Goal's terminal boundary, and
/// `reclaim_native_goal_runtime_roots` removes whatever a crash left behind on
/// every daemon start.
///
/// Terminal cleanup and daemon-start reclamation remove only receipt-proven
/// boxes and the exact Goal-scoped runtime root.
///
/// What this function does about it is refuse to add a third: an archive is
/// operator-invoked at an arbitrary moment, so it releases no boxes at all.
///
/// Content is collected last. The preview's artifact list is only a candidate
/// set: the storage boundary re-reads current retention under the repository
/// artifact lock immediately before unlinking, then rewrites the ledger after
/// the bytes are gone so interrupted collection remains retryable.
pub async fn archive_native_goal(
  project_dir : String,
  goal_id : @control.GoalId,
  dry_run~ : Bool,
  now~ : Int64,
  list_refs? : async (String) -> Result[
    Array[@workflow.GitRefName],
    @types.ChoirError,
  ] = list_native_goal_owned_git_refs,
  delete_refs? : async (String, Array[@workflow.GitRefName]) -> Result[
    Int,
    @types.ChoirError,
  ] = delete_native_goal_archived_git_refs,
) -> Result[NativeGoalArchiveReport, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let records = match
    @workflow.list_goal_execution_records(repository, adapters) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  // Terminality is read for every Goal, not just this one: content this Goal
  // adopted may also be kept until a different Goal finishes.
  let terminal_goal_ids : Array[@control.GoalId] = []
  let mut found : @workflow.GoalArchiveSubject? = None
  for stored in records {
    if @workflow.goal_execution_state_is_terminal(stored.record.state) {
      terminal_goal_ids.push(stored.record.goal.id)
    }
    if stored.record.goal.id == goal_id {
      // The Parts are read for their integration witness refs, which are
      // digests no ref listing can attribute to a Goal. A Part whose snapshot
      // is gone contributes nothing rather than failing the archive: the
      // consequence is a witness ref left behind, which is what happens today.
      let parts : Array[@workflow.PartWorkflowSnapshot] = []
      for workflow_id in stored.record.part_workflow_ids {
        match @workflow.load_part_snapshot(repository, adapters, workflow_id) {
          Ok(Some(part)) => parts.push(part.snapshot)
          Ok(None) => ()
          Err(error) => return Err(error)
        }
      }
      found = Some(@workflow.goal_archive_subject(stored.record, parts))
    }
  }
  let subject = match found {
    Some(value) => value
    None =>
      return Err(
        native_goal_execution_error("Goal is not recorded in this repository"),
      )
  }
  let observed_refs = match list_refs(project_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let retention_ledger = match
    @storage_host.read_artifact_retention_ledger(repository.artifact_store) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let decision = @workflow.plan_goal_archive(
    { subject, observed_refs, retention_ledger, now },
    fn(candidate) { terminal_goal_ids.contains(candidate) },
  )
  guard decision is @workflow.GoalArchiveDecision::GoalArchivePlanned(plan) else {
    return Ok({
      decision,
      applied: false,
      refs_removed: 0,
      artifacts_released: 0,
      outbox_events_released: 0,
    })
  }
  if dry_run {
    return Ok({
      decision,
      applied: false,
      refs_removed: 0,
      artifacts_released: 0,
      outbox_events_released: 0,
    })
  }
  let refs_removed = match delete_refs(project_dir, plan.release_refs) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let artifacts_released = match
    @storage_host.collect_artifacts(
      repository.artifact_store,
      plan.release_artifacts,
      now,
      fn(candidate) { terminal_goal_ids.contains(candidate) },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let outbox_events_released = match
    @storage_host.prune_completion_outbox_for_goal(
      repository.state_store,
      goal_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    decision,
    applied: true,
    refs_removed,
    artifacts_released,
    outbox_events_released,
  })
}

///|
pub fn cancel_native_goal(
  project_dir : String,
  goal_id : @control.GoalId,
  requested_at : Int64,
) -> Result[@workflow.GoalCancellationPersistenceResult, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
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
  let adapters = @storage_host.local_part_workflow_repository_adapters()
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
  let adapters = @storage_host.local_part_workflow_repository_adapters()
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
  let adapters = @storage_host.local_part_workflow_repository_adapters()
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
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  @workflow.persist_goal_input_answer(
    repository, adapters, request_id, answer, answered_at,
  )
}

///|
/// Read the portfolio's provider capacity state, for a reader that knows the
/// configured bounds.
///
/// The held sets come from the durable lease records the admission gate
/// commits against, so nothing is counted a second time here. The refusal
/// instants cannot come from the store — no refusal is durable, and inventing
/// one would be a wake nothing named — so they come from what the caller's own
/// tick observed.
fn native_provider_capacity_observation(
  repository : @workflow.PartWorkflowRepository,
  policy : @types.ProviderCapacityPolicy,
  tick_reports : Array[@workflow.ProviderSurfaceTickReport],
) -> Result[@workflow.ProviderCapacityObservation, @types.ChoirError] {
  match
    @workflow.list_provider_surface_lease_records(
      repository,
      @storage_host.local_part_workflow_repository_adapters(),
    ) {
    Ok(lease_records) =>
      Ok({
        lease_records,
        tick_reports,
        policy,
        fencing_epoch: current_native_goal_fencing_epoch(),
      })
    Err(error) => Err(error)
  }
}

///|
/// Both capacity arguments are what this reader observed, and both default to
/// having observed nothing.
///
/// `provider_capacity` is the configured bound, and `None` is honest rather
/// than convenient: a caller without the daemon's configuration would
/// otherwise report a default capacity nobody chose, which an operator cannot
/// tell from a real one. `surface_reports` is what this Goal's durable executor
/// job learned on its last attempt, and is legitimately empty before any
/// provider gate was reached.
pub fn inspect_native_goal(
  project_dir : String,
  goal_id : @control.GoalId,
  provider_capacity? : @types.ProviderCapacityPolicy? = None,
  surface_reports? : Array[@workflow.ProviderSurfaceTickReport] = [],
) -> Result[@workflow.GoalStatusReport, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  if !@sys.path_entry_exists(repository.state_store.path) {
    return Err(native_goal_execution_error("Goal is not registered"))
  }
  let adapters = @storage_host.local_part_workflow_repository_adapters()
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
  let observation = match provider_capacity {
    Some(policy) =>
      match
        native_provider_capacity_observation(
          repository, policy, surface_reports,
        ) {
        Ok(value) => Some(value)
        Err(error) => return Err(error)
      }
    None => None
  }
  let work_order = match
    @workflow.load_goal_work_order(repository, adapters, record) {
    Ok(Some(stored)) => Some(stored.record.budget)
    Ok(None) => None
    Err(error) => return Err(error)
  }
  @workflow.goal_status_report(
    record,
    snapshots,
    assurance,
    publication,
    pull_request,
    finalization,
    work_order~,
    provider_capacity=observation,
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
  let adapters = @storage_host.local_part_workflow_repository_adapters()
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

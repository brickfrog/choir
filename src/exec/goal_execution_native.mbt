///|
struct NativeGoalRepositoryIdentity {
  root : String
  git_directory : String
  object_directory : String
}

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
    _ => return Err(native_goal_execution_error("Git process failed"))
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
async fn reconcile_native_goal_ref(
  repository : NativeGoalRepositoryIdentity,
  record : @workflow.GoalExecutionRecord,
) -> Result[Unit, @types.ChoirError] {
  let goal_ref = record.goal_ref.0
  let observed = capture_native_goal_git(repository.root, [
    "rev-parse",
    "--verify",
    goal_ref + "^{commit}",
  ])
  let head = match observed {
    Ok({ exit_code: 0, output }) => Some(output.trim().to_owned())
    Ok(_) => None
    Err(error) => return Err(error)
  }
  match head {
    None => {
      let zero = if record.base_commit_oid.0.length() == 64 {
        "0000000000000000000000000000000000000000000000000000000000000000"
      } else {
        "0000000000000000000000000000000000000000"
      }
      let created = match
        capture_native_goal_git(repository.root, [
          "update-ref",
          goal_ref,
          record.base_commit_oid.0,
          zero,
        ]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if created.exit_code != 0 {
        return Err(native_goal_execution_error("Goal ref creation conflicted"))
      }
    }
    Some(value) => {
      let ancestry = match
        capture_native_goal_git(repository.root, [
          "merge-base",
          "--is-ancestor",
          record.base_commit_oid.0,
          value,
        ]) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      if ancestry.exit_code != 0 {
        return Err(native_goal_execution_error("Goal ref left its base"))
      }
    }
  }
  let verified = match
    native_goal_git_value(repository.root, [
      "rev-parse",
      "--verify",
      goal_ref + "^{commit}",
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if verified == "" {
    Err(native_goal_execution_error("Goal ref receipt is absent"))
  } else {
    Ok(())
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
        snapshot.part.id.0,
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
fn native_goal_mcp_script(project_dir : String) -> String? {
  match @sys.realpath_native(project_dir + "/scripts/choir_sandbox_mcp.mjs") {
    Some(value) => Some(value)
    None => @sys.realpath_native("scripts/choir_sandbox_mcp.mjs")
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
  match reconcile_native_goal_ref(git, record) {
    Ok(_) => ()
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
  if !@sys.create_dir_all(runtime_root) ||
    @sys.realpath_native(runtime_root) != Some(runtime_root) {
    return Err(native_goal_execution_error("runtime root is unavailable"))
  }
  let binary = match native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runtime_dir = match native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return Err(error)
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
  let mcp_script = match native_goal_mcp_script(project_dir) {
    Some(value) => value
    None => return Err(native_goal_execution_error("sandbox MCP is absent"))
  }
  let server = match
    start_native_boxlite_server({
      binary,
      runtime_dir,
      root: runtime_root,
      port: 40000 + @sys.get_pid() % 10000,
      api_key: "choir-goal-" + runtime_key,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let prepared = match
    prepare_native_boxlite_environment(
      server,
      moon_home,
      "choir-base-goal-" + runtime_key,
    ) {
    Ok(value) => value
    Err(error) => {
      ignore(cleanup_native_boxlite_server(server))
      return Err(error)
    }
  }
  let clock = @ref.new(100000L)
  let now = fn() {
    clock.val = clock.val + 1L
    clock.val
  }
  let goal_cancellation_requested = fn() {
    match
      @workflow.load_goal_execution_record(
        repository,
        local_part_workflow_repository_adapters(),
        record.goal.id,
      ) {
      Ok(Some(current)) =>
        current.record.state ==
        @workflow.GoalExecutionState::GoalExecutionCanceling ||
        current.record.state ==
        @workflow.GoalExecutionState::GoalExecutionCanceled
      _ => true
    }
  }
  let parts : Array[NativeGoalPartRuntime] = []
  for snapshot in snapshots {
    let surface = snapshot.identities.implementation_session.surface
    if snapshot.identities.verification_session.surface != surface ||
      snapshot.identities.audit_session.surface != surface {
      ignore(cleanup_native_boxlite_server(prepared.server))
      return Err(
        native_goal_execution_error("Part provider assignment drifted"),
      )
    }
    let runtime = match
      create_native_part_effect_runtime(
        native_part_runtime_config_for_paths(
          repository,
          prepared.server,
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
        ignore(cleanup_native_boxlite_server(prepared.server))
        return Err(error)
      }
    }
    runtime.prepared.val = Some(prepared)
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
  let integration : NativeGitIntegrationConfig = {
    repository_root: git.root,
    git_directory: git.git_directory,
    object_directory: git.object_directory,
    control_root: runtime_root + "/integration-control",
    goal_ref: record.goal_ref.0,
  }
  let sandbox_prepare_lock = @ref.new(false)
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
        Some(sandbox_prepare_lock),
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
    read_goal_head: async fn() {
      read_native_goal_head(integration, native_git_integration_adapters())
    },
  }
  let result = @workflow.run_goal_parts(
    config.bindings.map(fn(binding) { binding.scheduling_record }),
    record.maximum_parallel_parts,
    goal_part_workflow_adapters(config),
  )
  ignore(cleanup_native_boxlite_server(prepared.server))
  match result {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
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
  let finalization_known = match
    reconcile_native_goal_finalization_cancellation(
      project_dir, repository, adapters, record, forge, observed_at,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok((reconciled, finalization_known))
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
async test "native Goal seal witness is exact and idempotent" {
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
        verification_session: native_goal_submission_session(
          "session-" + key + "-goal-verification-1",
          verification_take,
          verification_sandbox,
          surface,
        ),
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
                  | @workflow.GoalAssuranceEffectKind::StartGoalVerificationHarness(
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
                    project_dir, repository, execution, git, record, intent,
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
  @workflow.run_next_goal_execution_tick(repository, repository_adapters, {
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
      match
        reconcile_native_goal_part_cancellation(
          project_dir, repository, repository_adapters, record, snapshots, forge,
        ) {
        Ok((reconciled, finalization_known)) =>
          Ok(
            native_goal_cancellation_can_finish(reconciled) &&
            finalization_known,
          )
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
pub fn attach_native_goal(
  project_dir : String,
  take_id : @control.TakeId,
) -> Result[@workflow.GoalAttachReport, @types.ChoirError] {
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
        }
      Ok(None) => ()
      Err(error) => return Err(error)
    }
  }
  match report {
    Some(value) => Ok(value)
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

///|
pub(all) struct NativeMixedProviderGoalReport {
  passed : Bool
  maximum_concurrent_parts : Int
  provider_surfaces : Array[@control.ProviderSurfaceId]
  promotion_order : Array[@control.PartId]
  effect_receipt_count : Int
  verification_receipt_count : Int
  audit_receipt_count : Int
  integration_receipt_count : Int
  combined_tree_valid : Bool
  selection_decision_persisted : Bool
  failure : String?
} derive(Debug, Eq, ToJson)

///|
priv struct NativeMixedProviderPart {
  snapshot : @workflow.PartWorkflowSnapshot
  runtime : NativePartEffectRuntime
  counts : NativePartDispatchCounts
  surface : @control.ProviderSurfaceId
}

///|
fn failed_native_mixed_provider_goal(
  message : String,
) -> NativeMixedProviderGoalReport {
  {
    passed: false,
    maximum_concurrent_parts: 0,
    provider_surfaces: [],
    promotion_order: [],
    effect_receipt_count: 0,
    verification_receipt_count: 0,
    audit_receipt_count: 0,
    integration_receipt_count: 0,
    combined_tree_valid: false,
    selection_decision_persisted: false,
    failure: Some(message),
  }
}

///|
fn native_mixed_provider_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("mixed-provider Goal: " + message)
}

///|
fn native_mixed_provider_part(
  parts : Array[NativeMixedProviderPart],
  part_id : @control.PartId,
) -> NativeMixedProviderPart? {
  for part in parts {
    if part.snapshot.part.id == part_id {
      return Some(part)
    }
  }
  None
}

///|
fn native_mixed_provider_record(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> @workflow.GoalPartSchedulingRecord {
  { part: snapshot.part, task_contract: snapshot.task_contract }
}

///|
fn native_mixed_provider_accepted_part(
  decision : @workflow.GoalSelectionDecision,
  part_id : @control.PartId,
) -> @workflow.AcceptedGoalPart? {
  for part in decision.accepted_parts {
    if part.part.id == part_id {
      return Some(part)
    }
  }
  None
}

///|
fn native_mixed_provider_stored_snapshot(
  repository : @workflow.PartWorkflowRepository,
  workflow_id : String,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  match
    @workflow.load_part_snapshot(
      repository,
      local_part_workflow_repository_adapters(),
      workflow_id,
    ) {
    Ok(Some(value)) => Ok(value.snapshot)
    Ok(None) => Err(native_mixed_provider_error("Part snapshot is absent"))
    Err(error) => Err(error)
  }
}

///|
async fn cleanup_failed_native_mixed_provider_goal(
  server : NativeBoxLiteServerHandle,
  message : String,
) -> NativeMixedProviderGoalReport {
  ignore(cleanup_native_boxlite_server(server))
  failed_native_mixed_provider_goal(message)
}

///|
pub async fn run_native_mixed_provider_goal_fixture(
  root : String,
) -> NativeMixedProviderGoalReport {
  if !root.has_prefix("/tmp/choir-take-") ||
    root.contains("/../") ||
    !@sys.create_dir_all(root) ||
    @sys.realpath_native(root) != Some(root) {
    return failed_native_mixed_provider_goal("fixture root is invalid")
  }
  let git = match
    create_native_part_fixture_repository_with_sources(root, [
      (
        "src/claude_answer.mbt", "///|\npub fn claude_answer() -> Int { 1 }\n\n///|\ntest \"Claude Part is corrected\" {\n  assert_eq(claude_answer(), 2)\n}\n",
      ),
      (
        "src/codex_answer.mbt", "///|\npub fn codex_answer() -> Int { 10 }\n\n///|\ntest \"Codex Part is corrected\" {\n  assert_eq(codex_answer(), 20)\n}\n",
      ),
    ]) {
    Ok(value) => value
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  let repository : @workflow.PartWorkflowRepository = {
    state_store: { path: root + "/workflow.db" },
    artifact_store: { root: root + "/artifacts" },
    max_snapshot_bytes: 1024 * 1024,
  }
  match
    @workflow.initialize_part_workflow_repository(
      repository,
      local_part_workflow_repository_adapters(),
    ) {
    Ok(_) => ()
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  let goal_id = @control.GoalId("goal-native-mixed-provider")
  let claude_snapshot = match
    native_part_fixture_snapshot_for_definition(repository, git, {
      key: "mixed-claude",
      goal_id,
      part_id: @control.PartId("part-claude"),
      source_path: @control.RepoPath("src/claude_answer.mbt"),
      instruction: "Change only src/claude_answer.mbt so claude_answer() returns 2. Inspect the file, make the smallest edit, run /opt/moon/bin/moon test --target wasm src/claude_answer.mbt in the sandbox, and finish with the required JSON outcome.",
      surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    }) {
    Ok(value) => value
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  let codex_snapshot = match
    native_part_fixture_snapshot_for_definition(repository, git, {
      key: "mixed-codex",
      goal_id,
      part_id: @control.PartId("part-codex"),
      source_path: @control.RepoPath("src/codex_answer.mbt"),
      instruction: "Change only src/codex_answer.mbt so codex_answer() returns 20. Inspect the file, make the smallest edit, run /opt/moon/bin/moon test --target wasm src/codex_answer.mbt in the sandbox, and finish with the required JSON outcome.",
      surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    }) {
    Ok(value) => value
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  if claude_snapshot.goal != codex_snapshot.goal {
    return failed_native_mixed_provider_goal(
      "Part snapshots disagree about the durable Goal",
    )
  }
  let repository_id = @workflow.RepositoryId("native-mixed-provider-repository")
  let claude_source_revision = @storage.artifact_digest(
    @utf8.encode("native-mixed-provider-source-revision:claude"),
  )
  let codex_source_revision = @storage.artifact_digest(
    @utf8.encode("native-mixed-provider-source-revision:codex"),
  )
  let source_snapshot : @workflow.GoalSelectionSnapshot = {
    repository_id,
    base_commit_oid: git.base_commit_oid,
    base_tree_oid: git.base_tree_oid,
    parts: [
      {
        part_id: claude_snapshot.part.id,
        source_revision_digest: claude_source_revision,
        source_content_digest: claude_source_revision,
        dependency_ids: [],
        state: @workflow.SelectionSourceState::SelectionSourceOpen,
      },
      {
        part_id: codex_snapshot.part.id,
        source_revision_digest: codex_source_revision,
        source_content_digest: codex_source_revision,
        dependency_ids: [],
        state: @workflow.SelectionSourceState::SelectionSourceOpen,
      },
    ],
  }
  let proposal : @workflow.GoalProposal = {
    id: @workflow.GoalProposalId("proposal-native-mixed-provider"),
    goal_id,
    repository_id,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    expected_base_commit_oid: git.base_commit_oid,
    expected_base_tree_oid: git.base_tree_oid,
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    selection_policy: @workflow.GoalSelectionPolicy::ExactClosure,
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    maximum_parallel_parts: 2,
    parts: [
      {
        part_id: claude_snapshot.part.id,
        source_revision_digest: claude_source_revision,
        source_content_digest: claude_source_revision,
        dependency_ids: [],
        task_contract: claude_snapshot.task_contract,
        provider_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        part_context_manifest: None,
      },
      {
        part_id: codex_snapshot.part.id,
        source_revision_digest: codex_source_revision,
        source_content_digest: codex_source_revision,
        dependency_ids: [],
        task_contract: codex_snapshot.task_contract,
        provider_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
        part_context_manifest: None,
      },
    ],
  }
  let selection = match
    @workflow.evaluate_goal_proposal(proposal, source_snapshot, fn(_) { true }) {
    Ok(value) => value
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  if selection.outcome != @workflow.GoalSelectionOutcome::GoalSelectionAccepted ||
    selection.accepted_parts.length() != 2 {
    return failed_native_mixed_provider_goal(
      "Conductor proposal was not accepted exactly",
    )
  }
  let selection_receipt = match
    @workflow.persist_goal_selection_decision(
      repository,
      local_part_workflow_repository_adapters(),
      { decision: selection, fault_point: None },
    ) {
    Ok(value) => value
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  if selection_receipt.transaction_outcome !=
    @storage.StateTransactionOutcome::StateTransactionCommitted {
    return failed_native_mixed_provider_goal(
      "Conductor selection was not durably committed",
    )
  }
  let stored_selection = match
    @workflow.load_goal_selection_decision(
      repository,
      local_part_workflow_repository_adapters(),
      goal_id,
    ) {
    Ok(Some(value)) => value
    Ok(None) =>
      return failed_native_mixed_provider_goal(
        "durable Conductor selection is absent",
      )
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  if stored_selection.decision != selection ||
    stored_selection.state_record.value_digest !=
    selection_receipt.decision_digest {
    return failed_native_mixed_provider_goal(
      "durable Conductor selection does not match its receipt",
    )
  }
  let accepted_goal = match selection.goal {
    Some(value) => value
    None => return failed_native_mixed_provider_goal("accepted Goal is absent")
  }
  let accepted_claude = match
    native_mixed_provider_accepted_part(selection, claude_snapshot.part.id) {
    Some(value) => value
    None =>
      return failed_native_mixed_provider_goal("Claude Part is not accepted")
  }
  let accepted_codex = match
    native_mixed_provider_accepted_part(selection, codex_snapshot.part.id) {
    Some(value) => value
    None =>
      return failed_native_mixed_provider_goal("Codex Part is not accepted")
  }
  let claude_snapshot = { ..claude_snapshot, goal: accepted_goal }
  let codex_snapshot = { ..codex_snapshot, goal: accepted_goal }
  let binary = match native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  let runtime_dir = match native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  let moon_home = match @sys.getenv("CHOIR_MOON_HOME") {
    Some(value) => value
    None =>
      match @sys.getenv("HOME") {
        Some(value) => value + "/.moon"
        None =>
          return failed_native_mixed_provider_goal("Moon home is unavailable")
      }
  }
  let node = match resolve_executable_in_path("node") {
    Some(value) => value
    None => return failed_native_mixed_provider_goal("Node is unavailable")
  }
  let mcp_script = match @sys.realpath_native("scripts/choir_sandbox_mcp.mjs") {
    Some(value) => value
    None =>
      return failed_native_mixed_provider_goal("sandbox MCP is unavailable")
  }
  let server = match
    start_native_boxlite_server({
      binary,
      runtime_dir,
      root,
      port: 36000 + @sys.get_pid() % 12000,
      api_key: "choir-native-mixed-" + @sys.get_pid().to_string(),
    }) {
    Ok(value) => value
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  let clock = @ref.new(2000L)
  let now = fn() {
    clock.val = clock.val + 1L
    clock.val
  }
  let prepared = match
    prepare_native_boxlite_environment(
      server, moon_home, "choir-base-mixed-provider",
    ) {
    Ok(value) => value
    Err(error) =>
      return cleanup_failed_native_mixed_provider_goal(server, error.message())
  }
  let active_server = prepared.server
  let claude_runtime = match
    create_native_part_effect_runtime(
      native_part_runtime_config(
        repository, active_server, git, moon_home, node, mcp_script, now,
      ),
    ) {
    Ok(value) => value
    Err(error) =>
      return cleanup_failed_native_mixed_provider_goal(
        active_server,
        error.message(),
      )
  }
  let codex_runtime = match
    create_native_part_effect_runtime(
      native_part_runtime_config(
        repository, active_server, git, moon_home, node, mcp_script, now,
      ),
    ) {
    Ok(value) => value
    Err(error) =>
      return cleanup_failed_native_mixed_provider_goal(
        active_server,
        error.message(),
      )
  }
  claude_runtime.prepared.val = Some(prepared)
  codex_runtime.prepared.val = Some(prepared)
  let claude_counts : NativePartDispatchCounts = {
    implementation: @ref.new(0),
    verification: @ref.new(0),
    audit: @ref.new(0),
  }
  let codex_counts : NativePartDispatchCounts = {
    implementation: @ref.new(0),
    verification: @ref.new(0),
    audit: @ref.new(0),
  }
  let parts : Array[NativeMixedProviderPart] = [
    {
      snapshot: claude_snapshot,
      runtime: claude_runtime,
      counts: claude_counts,
      surface: accepted_claude.provider_surface,
    },
    {
      snapshot: codex_snapshot,
      runtime: codex_runtime,
      counts: codex_counts,
      surface: accepted_codex.provider_surface,
    },
  ]
  let integration : NativeGitIntegrationConfig = {
    repository_root: git.root,
    git_directory: git.git_directory,
    object_directory: git.object_directory,
    control_root: root + "/integration-control",
    goal_ref: git.goal_ref,
  }
  let active = @ref.new(0)
  let maximum_active = @ref.new(0)
  let sandbox_prepare_lock = @ref.new(false)
  let result = match
    @workflow.run_goal_parts(
      parts.map(fn(part) { native_mixed_provider_record(part.snapshot) }),
      2,
      {
        advance_part: async fn(record) {
          let part = match native_mixed_provider_part(parts, record.part.id) {
            Some(value) => value
            None => return Err(native_mixed_provider_error("Part is absent"))
          }
          active.val = active.val + 1
          if active.val > maximum_active.val {
            maximum_active.val = active.val
          }
          let run = @workflow.run_new_part_workflow(
            repository,
            local_part_workflow_repository_adapters(),
            part.snapshot,
            native_part_dependencies(
              repository,
              part.runtime,
              clock,
              part.counts,
              part.surface,
              None,
              Some(sandbox_prepare_lock),
              fn(_) { None },
            ),
          )
          active.val = active.val - 1
          let observed = match run {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          if observed.outcome !=
            @workflow.PartWorkflowRunOutcome::PartRunAwaitingPromotion {
            return Err(
              native_mixed_provider_error(
                "Part " +
                record.part.id.0 +
                " did not stop at audited promotion admission: outcome=" +
                observed.outcome.to_json().stringify(indent=0) +
                " stage=" +
                observed.snapshot.stage.to_json().stringify(indent=0) +
                " verification=" +
                native_part_verification_debug(repository, observed.snapshot) +
                " audit=" +
                native_part_audit_debug(repository, observed.snapshot),
              ),
            )
          }
          Ok(native_mixed_provider_record(observed.snapshot))
        },
        read_goal_head: async fn() {
          read_native_goal_head(integration, native_git_integration_adapters())
        },
        promote_part: async fn(record, selection) {
          let part = match native_mixed_provider_part(parts, record.part.id) {
            Some(value) => value
            None => return Err(native_mixed_provider_error("Part is absent"))
          }
          let stored = match
            native_mixed_provider_stored_snapshot(
              repository,
              part.snapshot.workflow_id,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let candidate_matches = match stored.candidate {
            Some(value) => value.id == selection.candidate_id
            None => false
          }
          let receipt_matches = match stored.audit_receipt {
            Some(value) => value.receipt_id == selection.audit_receipt_id
            None => false
          }
          if !candidate_matches || !receipt_matches {
            return Err(
              native_mixed_provider_error("promotion selection is stale"),
            )
          }
          let promoted = match
            @workflow.resume_part_workflow(
              repository,
              local_part_workflow_repository_adapters(),
              part.snapshot.workflow_id,
              native_part_dependencies(
                repository,
                part.runtime,
                clock,
                part.counts,
                part.surface,
                Some(selection.expected_goal_head_oid),
                Some(sandbox_prepare_lock),
                fn(_) { None },
              ),
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          if promoted.outcome !=
            @workflow.PartWorkflowRunOutcome::PartRunIntegrated {
            return Err(
              native_mixed_provider_error("Part promotion did not finish"),
            )
          }
          Ok(native_mixed_provider_record(promoted.snapshot))
        },
        resume_promotion: async fn(record) {
          let part = match native_mixed_provider_part(parts, record.part.id) {
            Some(value) => value
            None => return Err(native_mixed_provider_error("Part is absent"))
          }
          let resumed = match
            @workflow.resume_part_workflow(
              repository,
              local_part_workflow_repository_adapters(),
              part.snapshot.workflow_id,
              native_part_dependencies(
                repository,
                part.runtime,
                clock,
                part.counts,
                part.surface,
                None,
                Some(sandbox_prepare_lock),
                fn(_) { None },
              ),
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          Ok(native_mixed_provider_record(resumed.snapshot))
        },
      },
    ) {
    Ok(value) => value
    Err(error) =>
      return cleanup_failed_native_mixed_provider_goal(
        active_server,
        error.message(),
      )
  }
  if result.outcome != @workflow.GoalRunOutcome::GoalRunSucceeded ||
    maximum_active.val != 2 ||
    result.promotion_order !=
    [@control.PartId("part-codex"), @control.PartId("part-claude")] {
    return cleanup_failed_native_mixed_provider_goal(
      active_server,
      "Goal execution, concurrency, or promotion order was invalid: outcome=" +
      result.outcome.to_json().stringify(indent=0) +
      " maximum_concurrent_parts=" +
      maximum_active.val.to_string() +
      " promotion_order=" +
      result.promotion_order.to_json().stringify(indent=0),
    )
  }
  let final_snapshots : Array[@workflow.PartWorkflowSnapshot] = []
  for part in parts {
    let stored = match
      native_mixed_provider_stored_snapshot(
        repository,
        part.snapshot.workflow_id,
      ) {
      Ok(value) => value
      Err(error) =>
        return cleanup_failed_native_mixed_provider_goal(
          active_server,
          error.message(),
        )
    }
    final_snapshots.push(stored)
  }
  let mut effect_receipt_count = 0
  let mut verification_receipt_count = 0
  let mut audit_receipt_count = 0
  let mut integration_receipt_count = 0
  for snapshot in final_snapshots {
    effect_receipt_count = effect_receipt_count +
      snapshot.effect_receipts.length()
    verification_receipt_count = verification_receipt_count +
      snapshot.verification_receipts.length()
    if snapshot.audit_receipt is Some(_) {
      audit_receipt_count = audit_receipt_count + 1
    }
    if snapshot.integration_receipt is Some(_) {
      integration_receipt_count = integration_receipt_count + 1
    }
  }
  let head = match
    read_native_goal_head(integration, native_git_integration_adapters()) {
    Ok(value) => value
    Err(error) =>
      return cleanup_failed_native_mixed_provider_goal(
        active_server,
        error.message(),
      )
  }
  let claude_source = match
    native_part_fixture_git_value(git.root, [
      "show",
      head.0 + ":src/claude_answer.mbt",
    ]) {
    Ok(value) => value
    Err(error) =>
      return cleanup_failed_native_mixed_provider_goal(
        active_server,
        error.message(),
      )
  }
  let codex_source = match
    native_part_fixture_git_value(git.root, [
      "show",
      head.0 + ":src/codex_answer.mbt",
    ]) {
    Ok(value) => value
    Err(error) =>
      return cleanup_failed_native_mixed_provider_goal(
        active_server,
        error.message(),
      )
  }
  let combined_tree_valid = claude_source.contains("-> Int { 2 }") &&
    codex_source.contains("-> Int { 20 }")
  let counts_valid = effect_receipt_count == 24 &&
    verification_receipt_count == 2 &&
    audit_receipt_count == 2 &&
    integration_receipt_count == 2 &&
    claude_counts.implementation.val == 1 &&
    claude_counts.verification.val == 1 &&
    claude_counts.audit.val == 1 &&
    codex_counts.implementation.val == 1 &&
    codex_counts.verification.val == 1 &&
    codex_counts.audit.val == 1
  ignore(cleanup_native_boxlite_server(active_server))
  if !combined_tree_valid || !counts_valid {
    return failed_native_mixed_provider_goal(
      "combined tree or durable receipt cardinality was invalid",
    )
  }
  {
    passed: true,
    maximum_concurrent_parts: maximum_active.val,
    provider_surfaces: parts.map(fn(part) { part.surface }),
    promotion_order: result.promotion_order,
    effect_receipt_count,
    verification_receipt_count,
    audit_receipt_count,
    integration_receipt_count,
    combined_tree_valid,
    selection_decision_persisted: true,
    failure: None,
  }
}

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
fn native_mixed_provider_integration_input(
  snapshot : @workflow.PartWorkflowSnapshot,
  selection : @workflow.DeterministicPromotionSelection,
) -> Result[@workflow.IntegrationPlanInput, @types.ChoirError] {
  let key = @storage.artifact_digest(
      @utf8.encode(
        "choir.native-mixed-provider-promotion.v1\u{00}" +
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
      @utf8.encode(
        "choir.native-mixed-provider-promotion-metadata.v1\u{00}" + key,
      ),
    ),
    git_witness_ref: "refs/choir/witness/" + key,
  })
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
  workflow_id : @control.WorkflowId,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  match
    @workflow.load_part_snapshot(
      repository,
      @storage_host.local_part_workflow_repository_adapters(),
      workflow_id,
    ) {
    Ok(Some(value)) => Ok(value.snapshot)
    Ok(None) => Err(native_mixed_provider_error("Part snapshot is absent"))
    Err(error) => Err(error)
  }
}

///|
async fn cleanup_failed_native_mixed_provider_goal(
  server : @take_host.NativeBoxLiteServerHandle,
  message : String,
) -> NativeMixedProviderGoalReport {
  ignore(@take_host.cleanup_native_boxlite_fixture_server(server))
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
      @storage_host.local_part_workflow_repository_adapters(),
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
    conductor_draft_digest: claude_source_revision,
    repository_id,
    base_ref: @workflow.GitRefName("refs/heads/main"),
    expected_base_commit_oid: git.base_commit_oid,
    expected_base_tree_oid: git.base_tree_oid,
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    selection_policy: @workflow.GoalSelectionPolicy::ExactClosure,
    completion_mode: @workflow.GoalCompletionMode::GoalPublishable,
    pull_request_document: Some({
      title: "test: exercise mixed-provider Goal",
      body: "Exercises the mixed-provider native workflow.",
      draft: false,
    }),
    migration_production_admission: None,
    maximum_parallel_parts: 2,
    parts: [
      {
        part_id: claude_snapshot.part.id,
        source_revision_digest: claude_source_revision,
        source_content_digest: claude_source_revision,
        dependency_ids: [],
        task_contract: claude_snapshot.task_contract,
        provider_surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        provider_failover_surfaces: [],
        part_context_manifest: None,
      },
      {
        part_id: codex_snapshot.part.id,
        source_revision_digest: codex_source_revision,
        source_content_digest: codex_source_revision,
        dependency_ids: [],
        task_contract: codex_snapshot.task_contract,
        provider_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
        provider_failover_surfaces: [],
        part_context_manifest: None,
      },
    ],
    work_order_id: None,
    work_order_planning_round_id: None,
    work_order_objective: None,
    work_order_selection_policy: None,
    work_order_planner: None,
    work_order_primary_target_ids: [
      claude_snapshot.part.id,
      codex_snapshot.part.id,
    ],
    work_order_budget: None,
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
      @storage_host.local_part_workflow_repository_adapters(),
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
      @storage_host.local_part_workflow_repository_adapters(),
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
  let binary = match @process_host.native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return failed_native_mixed_provider_goal(error.message())
  }
  let runtime_dir = match @process_host.native_boxlite_runtime_dir() {
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
  let node = match @process_host.resolve_executable_in_path("node") {
    Some(value) => value
    None => return failed_native_mixed_provider_goal("Node is unavailable")
  }
  let mcp_script = match
    @process_host.resolve_native_runtime_asset(
      @process_host.ChoirRuntimeAsset::ChoirSandboxMcp,
    ) {
    Some(value) => value
    None =>
      return failed_native_mixed_provider_goal("sandbox MCP is unavailable")
  }
  let server = match
    @take_host.start_native_boxlite_server({
      binary,
      runtime_dir,
      root,
      home: "/tmp/choir-boxlite-mixed-" + @sys.get_pid().to_string(),
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
    @take_host.prepare_native_boxlite_environment(
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
  // Native Goal submission persists every accepted Part before the Goal
  // scheduler can admit it. Seed the fixture at the same durable boundary so
  // concurrent adapter passes exercise resume/reconciliation, not two
  // competing first-write paths that production never exposes.
  for part in parts {
    let receipt = match
      @workflow.persist_part_snapshot(
        repository,
        @storage_host.local_part_workflow_repository_adapters(),
        {
          snapshot: part.snapshot,
          expected_store_version: None,
          fault_point: None,
        },
      ) {
      Ok(value) => value
      Err(error) =>
        return cleanup_failed_native_mixed_provider_goal(
          active_server,
          error.message(),
        )
    }
    if receipt.transaction_outcome !=
      @storage.StateTransactionOutcome::StateTransactionCommitted {
      return cleanup_failed_native_mixed_provider_goal(
        active_server, "accepted Part initialization conflicted",
      )
    }
  }
  let integration : @git_integration.NativeGitIntegrationConfig = {
    repository_root: git.root,
    git_directory: git.git_directory,
    object_directory: git.object_directory,
    control_root: root + "/integration-control",
    goal_ref: git.goal_ref,
  }
  let active = @ref.new(0)
  let maximum_active = @ref.new(0)
  let sandbox_prepare_lock = @ref.new(false)
  let config : @part_adapter.GoalPartWorkflowAdapterConfig = {
    bindings: parts.map(fn(part) {
      {
        scheduling_record: native_mixed_provider_record(part.snapshot),
        initial_snapshot: part.snapshot,
        repository,
      }
    }),
    repository_adapters: @storage_host.local_part_workflow_repository_adapters(),
    dependencies: fn(part_id, admission) {
      let part = match native_mixed_provider_part(parts, part_id) {
        Some(value) => value
        None => return Err(native_mixed_provider_error("Part is absent"))
      }
      Ok(
        native_part_dependencies_with_admission(
          repository,
          part.runtime,
          clock,
          part.counts,
          part.surface,
          None,
          Some(sandbox_prepare_lock),
          fn(_) { None },
          explicit_admission=Some(admission),
        ),
      )
    },
    integration_input: native_mixed_provider_integration_input,
    plan_conflict_repair: fn(_) {
      Ok(@workflow.PartConflictRepairDecision::PartConflictRepairLimitReached)
    },
    plan_audit_repair: fn(_) {
      Ok(@workflow.PartAuditRepairDecision::PartAuditRepairLimitReached)
    },
    plan_verification_repair: fn(_) {
      Ok(
        @workflow.PartVerificationRepairDecision::PartVerificationRepairLimitReached,
      )
    },
    plan_recovery_retry: fn(_) {
      Ok(@workflow.PartRecoveryRetryDecision::PartRecoveryRetryRetained)
    },
    read_goal_head: async fn() {
      @git_integration.read_native_goal_head(
        integration,
        @git_host.native_git_integration_adapters(),
      )
    },
    release_provider_lease: fn(_) { Ok(()) },
  }
  let adapters = @part_adapter.goal_part_workflow_adapters(config)
  let result = match
    @workflow.run_goal_parts(
      config.bindings.map(fn(binding) { binding.scheduling_record }),
      2,
      {
        advance_part: async fn(record) {
          active.val = active.val + 1
          if active.val > maximum_active.val {
            maximum_active.val = active.val
          }
          let run = (adapters.advance_part)(record)
          active.val = active.val - 1
          run
        },
        read_goal_head: adapters.read_goal_head,
        promote_part: adapters.promote_part,
        resume_promotion: adapters.resume_promotion,
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
    @git_integration.read_native_goal_head(
      integration,
      @git_host.native_git_integration_adapters(),
    ) {
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
  let counts_valid = effect_receipt_count == 26 &&
    verification_receipt_count == 2 &&
    audit_receipt_count == 2 &&
    integration_receipt_count == 2 &&
    claude_counts.implementation.val == 1 &&
    claude_counts.verification.val == 1 &&
    claude_counts.audit.val == 1 &&
    codex_counts.implementation.val == 1 &&
    codex_counts.verification.val == 1 &&
    codex_counts.audit.val == 1
  ignore(@take_host.cleanup_native_boxlite_fixture_server(active_server))
  if !combined_tree_valid || !counts_valid {
    return failed_native_mixed_provider_goal(
      "combined tree or durable receipt cardinality was invalid: combined_tree=" +
      combined_tree_valid.to_string() +
      " effect_receipts=" +
      effect_receipt_count.to_string() +
      " verification_receipts=" +
      verification_receipt_count.to_string() +
      " audit_receipts=" +
      audit_receipt_count.to_string() +
      " integration_receipts=" +
      integration_receipt_count.to_string() +
      " claude_dispatches=" +
      [
        claude_counts.implementation.val,
        claude_counts.verification.val,
        claude_counts.audit.val,
      ]
      .to_json()
      .stringify(indent=0) +
      " codex_dispatches=" +
      [
        codex_counts.implementation.val,
        codex_counts.verification.val,
        codex_counts.audit.val,
      ]
      .to_json()
      .stringify(indent=0),
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

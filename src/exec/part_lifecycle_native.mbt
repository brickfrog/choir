///|
pub(all) struct NativePartLifecycleReport {
  passed : Bool
  effect_receipt_count : Int
  verification_receipt_count : Int
  audit_receipt_count : Int
  integration_receipt_count : Int
  implementation_dispatches_before_restart : Int
  implementation_dispatches_after_restart : Int
  provider_dispatches_after_restart : Int
  candidate_commit_oid : @control.GitOid?
  promotion_commit_oid : @control.GitOid?
  failure : String?
} derive(Debug, Eq, ToJson)

///|
priv struct NativePartFixtureRepository {
  root : String
  base_commit_oid : @control.GitOid
  base_tree_oid : @control.GitOid
  object_directory : String
  goal_ref : String
}

///|
priv struct NativePartDispatchCounts {
  implementation : Ref[Int]
  verification : Ref[Int]
  audit : Ref[Int]
}

///|
fn failed_native_part_lifecycle(message : String) -> NativePartLifecycleReport {
  {
    passed: false,
    effect_receipt_count: 0,
    verification_receipt_count: 0,
    audit_receipt_count: 0,
    integration_receipt_count: 0,
    implementation_dispatches_before_restart: 0,
    implementation_dispatches_after_restart: 0,
    provider_dispatches_after_restart: 0,
    candidate_commit_oid: None,
    promotion_commit_oid: None,
    failure: Some(message),
  }
}

///|
fn native_part_fixture_git_environment(commit : Bool) -> Map[String, String] {
  let environment = native_git_environment(commit)
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  environment["GIT_ATTR_NOSYSTEM"] = "1"
  environment["XDG_CONFIG_HOME"] = "/nonexistent"
  environment["GIT_TERMINAL_PROMPT"] = "0"
  environment
}

///|
async fn capture_native_part_fixture_git(
  repository_root : String,
  arguments : Array[String],
  commit? : Bool = false,
) -> Result[NativeGitCapture, @types.ChoirError] {
  let captured = @process.collect_output_merged(
    "/usr/bin/git",
    arguments,
    extra_env=native_part_fixture_git_environment(commit),
    inherit_env=false,
    cwd=repository_root,
  ) catch {
    _ => return Err(native_part_effect_error("fixture Git process failed"))
  }
  let output = captured.1.text() catch {
    _ => return Err(native_part_effect_error("fixture Git output is not UTF-8"))
  }
  Ok({ exit_code: captured.0, output })
}

///|
async fn native_part_fixture_git_value(
  repository_root : String,
  arguments : Array[String],
) -> Result[String, @types.ChoirError] {
  let capture = match
    capture_native_part_fixture_git(repository_root, arguments) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let value = capture.output.trim().to_owned()
  if capture.exit_code != 0 || value == "" {
    Err(native_part_effect_error("fixture Git observation failed"))
  } else {
    Ok(value)
  }
}

///|
async fn create_native_part_fixture_repository(
  root : String,
) -> Result[NativePartFixtureRepository, @types.ChoirError] {
  let repository_root = root + "/repository"
  if !@sys.create_dir_all(repository_root + "/src") ||
    !@sys.write_file_sync(
      repository_root + "/moon.mod.json",
      "{\"name\":\"choir/live_part_fixture\",\"version\":\"0.0.1\",\"deps\":{}}\n",
    ) ||
    !@sys.write_file_sync(repository_root + "/src/moon.pkg", "") ||
    !@sys.write_file_sync(
      repository_root + "/.gitignore",
      "_build/\ntarget/\n.mooncakes/\n",
    ) ||
    !@sys.write_file_sync(
      repository_root + "/src/answer.mbt",
      "///|\npub fn answer() -> Int { 1 }\n\n///|\ntest \"answer is corrected\" {\n  assert_eq(answer(), 2)\n}\n",
    ) {
    return Err(native_part_effect_error("fixture repository creation failed"))
  }
  for
    command in [
      ["init", "--quiet", "--initial-branch=main", "."],
      ["add", "-A", "--", "."],
    ] {
    let capture = match
      capture_native_part_fixture_git(repository_root, command) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if capture.exit_code != 0 {
      return Err(native_part_effect_error("fixture Git initialization failed"))
    }
  }
  let committed = match
    capture_native_part_fixture_git(
      repository_root,
      ["commit", "--quiet", "-m", "test: create Part fixture"],
      commit=true,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if committed.exit_code != 0 {
    return Err(native_part_effect_error("fixture base commit failed"))
  }
  let head = match
    native_part_fixture_git_value(repository_root, ["rev-parse", "HEAD"]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let tree = match
    native_part_fixture_git_value(repository_root, [
      "show", "-s", "--format=%T", "--no-show-signature", head,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let object_directory = match
    native_part_fixture_git_value(repository_root, [
      "rev-parse", "--path-format=absolute", "--git-path", "objects",
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !valid_hex_oid_text(head) ||
    !valid_hex_oid_text(tree) ||
    @sys.realpath_native(object_directory) != Some(object_directory) {
    return Err(native_part_effect_error("fixture Git identity is invalid"))
  }
  let goal_ref = "refs/heads/choir-goal"
  let updated = match
    capture_native_part_fixture_git(repository_root, [
      "update-ref", goal_ref, head,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if updated.exit_code != 0 {
    return Err(native_part_effect_error("fixture Goal ref creation failed"))
  }
  Ok({
    root: repository_root,
    base_commit_oid: @control.GitOid(head),
    base_tree_oid: @control.GitOid(tree),
    object_directory,
    goal_ref,
  })
}

///|
fn adopt_native_part_fixture_artifact(
  repository : @workflow.PartWorkflowRepository,
  content : Bytes,
  provenance : @storage.ArtifactProvenance,
  goal_id : @control.GoalId,
) -> Result[@control.ArtifactReference, @types.ChoirError] {
  let digest = @storage.artifact_digest(content)
  let adapters = local_part_workflow_repository_adapters()
  let receipt = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: digest,
      provenance,
      retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    artifact_id: @storage.artifact_id_text(receipt.artifact_id),
    digest: receipt.digest,
  })
}

///|
fn native_part_fixture_take(
  id : String,
  goal_id : @control.GoalId,
  purpose : @control.TakePurpose,
) -> @control.Take {
  {
    id: @control.TakeId(id),
    goal_id,
    purpose,
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
}

///|
fn native_part_fixture_sandbox(
  id : String,
  generation_id : String,
  take : @control.Take,
  capability_profile_digest : @control.Digest,
) -> @control.SandboxLease {
  {
    id: @control.SandboxLeaseId(id),
    take_id: take.id,
    generation_id: @control.SandboxGenerationId(generation_id),
    capability_profile_digest,
    runtime_policy_digest: @sandbox.boxlite_take_runtime_policy_digest(),
    lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  }
}

///|
fn native_part_fixture_session(
  id : String,
  take : @control.Take,
  sandbox : @control.SandboxLease,
  surface_digest : @control.Digest,
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId(id),
    take_id: take.id,
    sandbox_generation_id: sandbox.generation_id,
    surface: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
    effective_surface_manifest_digest: surface_digest,
    cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn native_part_fixture_snapshot(
  repository : @workflow.PartWorkflowRepository,
  git : NativePartFixtureRepository,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  let goal_id = @control.GoalId("goal-native-part")
  let part_id = @control.PartId("part-native")
  let revision_id = @control.RevisionId("revision-native-part")
  let verification_spec_id = @control.VerificationSpecId("verify-native-part")
  let audit_policy_digest = @storage.artifact_digest(
    @utf8.encode("choir.native-part-audit-policy.v1"),
  )
  let implementation_profile_digest = @storage.artifact_digest(
    @utf8.encode("choir.native-part-implementation-profile.v1"),
  )
  let verification_profile_digest = @storage.artifact_digest(
    @utf8.encode("choir.native-part-verification-profile.v1"),
  )
  let audit_profile_digest = @storage.artifact_digest(
    @utf8.encode("choir.native-part-audit-profile.v1"),
  )
  let verification_spec_digest = @storage.artifact_digest(
    @utf8.encode("choir.native-part-verification-spec.v1"),
  )
  let implementation = native_part_fixture_take(
    "take-native-implementation",
    goal_id,
    @control.TakePurpose::Implementation(part_id, revision_id),
  )
  let verification = native_part_fixture_take(
    "take-native-verification",
    goal_id,
    @control.TakePurpose::PartVerification(
      part_id,
      implementation.id,
      verification_spec_digest,
    ),
  )
  let audit = native_part_fixture_take(
    "take-native-audit",
    goal_id,
    @control.TakePurpose::PartAudit(
      part_id,
      implementation.id,
      audit_policy_digest,
    ),
  )
  let instruction = match
    adopt_native_part_fixture_artifact(
      repository,
      @utf8.encode(
        "Change only src/answer.mbt so answer() returns 2. Inspect the file, make the smallest edit, run /opt/moon/bin/moon test --target wasm in the sandbox, and finish with the required JSON outcome.",
      ),
      @storage.ArtifactProvenance::ArtifactTaskInstruction(revision_id),
      goal_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let process : @sandbox.SandboxProcessSpec = {
    authority: @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
      verification.id,
      verification_spec_id,
      verification_spec_digest,
    ),
    executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
      @sandbox.SandboxRegisteredToolId("moon"),
      @sandbox.boxlite_take_tool_manifest_digest(),
    ),
    arguments: ["test", "--target", "wasm"],
    working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceRoot,
    environment: [{ key: "NO_COLOR", value: "1" }],
    stdin: @sandbox.SandboxStdinPolicy::SandboxStdinClosed,
    timeout_ms: 120000L,
    resources: {
      cpu_millis: 2000L,
      memory_bytes: 1073741824L,
      process_count: 128,
      file_bytes: 1073741824L,
    },
    network: {
      profile: @sandbox.SandboxNetworkProfile::NetworkDisabled,
      version: 1L,
      policy_digest: @sandbox.boxlite_take_runtime_policy_digest(),
    },
    output: {
      stdout_limit_bytes: 1048576L,
      stderr_limit_bytes: 1048576L,
      on_limit: @sandbox.SandboxOutputLimitDisposition::SandboxTerminateAndMarkExceeded,
    },
  }
  let process_artifact = match
    adopt_native_part_fixture_artifact(
      repository,
      @utf8.encode(process.to_json().stringify(indent=0)),
      @storage.ArtifactProvenance::ArtifactVerificationProcessSpec(
        verification_spec_id,
      ),
      goal_id,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let contract_digest = @storage.artifact_digest(
    @utf8.encode(
      "choir.native-part-contract.v1\u{00}" +
      git.base_commit_oid.0 +
      "\u{00}" +
      instruction.digest.0 +
      "\u{00}" +
      process_artifact.digest.0,
    ),
  )
  let goal : @control.Goal = {
    id: goal_id,
    contract_digest,
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let part : @control.GoalPart = {
    id: part_id,
    goal_id,
    dependency_ids: [],
    task_contract_revision_id: revision_id,
    lifecycle: @control.PartLifecycle::PartPending,
  }
  let contract : @control.TaskContractRevision = {
    id: revision_id,
    goal_id,
    part_id,
    revision: 1,
    digest: contract_digest,
    instruction_artifact: instruction,
    base_commit_oid: git.base_commit_oid,
    base_tree_oid: git.base_tree_oid,
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(@control.RepoPath("src/answer.mbt")),
      ],
    ),
    verification_specs: [
      {
        id: verification_spec_id,
        version: 1,
        digest: verification_spec_digest,
        process_spec_digest: process_artifact.digest,
      },
    ],
    audit_policy_digest,
    implementation_capability_profile_digest: implementation_profile_digest,
    verification_capability_profile_digest: verification_profile_digest,
    audit_capability_profile_digest: audit_profile_digest,
  }
  let surface_digest = @harness.expected_claude_take_surface_manifest_digest(
    @sandbox.boxlite_take_mcp_tools(),
    "choir_sandbox",
  )
  let implementation_sandbox = native_part_fixture_sandbox(
    "sandbox-native-implementation", "generation-native-implementation", implementation,
    implementation_profile_digest,
  )
  let verification_sandbox = native_part_fixture_sandbox(
    "sandbox-native-verification", "generation-native-verification", verification,
    verification_profile_digest,
  )
  let audit_sandbox = native_part_fixture_sandbox(
    "sandbox-native-audit", "generation-native-audit", audit, audit_profile_digest,
  )
  let identities : @workflow.PartIdentityPlan = {
    implementation_take: implementation,
    implementation_sandbox,
    implementation_session: native_part_fixture_session(
      "session-native-implementation", implementation, implementation_sandbox, surface_digest,
    ),
    verification_take: verification,
    verification_sandbox,
    verification_session: native_part_fixture_session(
      "session-native-verification", verification, verification_sandbox, surface_digest,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: native_part_fixture_session(
      "session-native-audit", audit, audit_sandbox, surface_digest,
    ),
  }
  @workflow.initialize_part_workflow(
    "workflow-native-part",
    goal,
    part,
    contract,
    identities,
    @control.FencingEpoch(1L),
    fn(_) { true },
  )
}

///|
fn counted_native_part_effects(
  effects : @workflow.PartWorkflowDriverAdapters,
  counts : NativePartDispatchCounts,
) -> @workflow.PartWorkflowDriverAdapters {
  {
    execute: async fn(snapshot, intent) {
      match intent.kind {
        @workflow.PartEffectKind::DispatchImplementation(_, _) =>
          counts.implementation.val = counts.implementation.val + 1
        @workflow.PartEffectKind::DispatchVerification(_, _, _) =>
          counts.verification.val = counts.verification.val + 1
        @workflow.PartEffectKind::DispatchAudit(_, _, _) =>
          counts.audit.val = counts.audit.val + 1
        _ => ()
      }
      (effects.execute)(snapshot, intent)
    },
    reconcile: effects.reconcile,
  }
}

///|
fn native_part_artifact_exists(
  repository : @workflow.PartWorkflowRepository,
  reference : @control.ArtifactReference,
) -> Bool {
  match
    (local_part_workflow_repository_adapters().artifacts.contains)(
      repository.artifact_store,
      reference.digest,
    ) {
    Ok(value) => value
    Err(_) => false
  }
}

///|
fn native_part_digest_exists(
  repository : @workflow.PartWorkflowRepository,
  digest : @control.Digest,
) -> Bool {
  native_part_artifact_exists(repository, { artifact_id: "digest", digest })
}

///|
fn native_part_verification_debug(
  repository : @workflow.PartWorkflowRepository,
  snapshot : @workflow.PartWorkflowSnapshot,
) -> String {
  if snapshot.verification_receipts.length() != 1 {
    return "receipt-count=" +
      snapshot.verification_receipts.length().to_string()
  }
  let receipt = snapshot.verification_receipts[0]
  let evidence = match
    (local_part_workflow_repository_adapters().artifacts.read)(
      repository.artifact_store,
      { digest: receipt.evidence.digest, max_bytes: 131072 },
    ) {
    Ok(value) => @utf8.decode_lossy(value)
    Err(error) => "evidence-error=" + error.message()
  }
  "receipt=" + receipt.to_json().stringify(indent=0) + " evidence=" + evidence
}

///|
fn native_part_dependencies(
  repository : @workflow.PartWorkflowRepository,
  runtime : NativePartEffectRuntime,
  git : NativePartFixtureRepository,
  clock : Ref[Int64],
  counts : NativePartDispatchCounts,
  fault : (@workflow.PartPersistenceBoundary) -> @storage.StateStoreFaultPoint?,
) -> @workflow.PartWorkflowDriverDependencies {
  let now = fn() {
    clock.val = clock.val + 1L
    clock.val
  }
  let effects = counted_native_part_effects(
    native_part_effect_adapters(runtime),
    counts,
  )
  {
    now,
    persistence_fault: fault,
    effects: @workflow.witnessed_part_effect_adapters(
      repository,
      local_part_workflow_repository_adapters(),
      effects,
      now,
    ),
    artifact_exists: fn(reference) {
      native_part_artifact_exists(repository, reference)
    },
    artifact_digest_exists: fn(digest) {
      native_part_digest_exists(repository, digest)
    },
    is_nfc: fn(_) { true },
    audit_receipt_metadata: fn(_) {
      Ok({
        receipt_id: @control.ReceiptId("audit-receipt-native-part"),
        provider_surface_id: @control.ProviderSurfaceId::ClaudeSubscriptionCli,
        provider_identity: "claude-code-2.1.215",
        model_identity: @control.ModelIdentity::ReportedModelIdentity(
          "claude-subscription-runtime",
        ),
      })
    },
    integration_plan: fn(snapshot) {
      Ok({
        lease: {
          id: @control.IntegrationLeaseId("integration-lease-native-part"),
          goal_id: snapshot.goal.id,
          fencing_epoch: snapshot.fencing_epoch,
          holder: "choird-native-conformance",
        },
        intent_id: @control.IntegrationIntentId(
          "integration-intent-native-part",
        ),
        expected_goal_head_oid: git.base_commit_oid,
        promotion_metadata_digest: @storage.artifact_digest(
          @utf8.encode("choir.native-part-promotion.v1"),
        ),
        git_witness_ref: "refs/choir/witness/native-part",
      })
    },
    verification_environment_digest: fn(_) {
      native_prepared_environment_digest({
        server: runtime.server.val,
        base_box_id: "digest-only",
        image_digest: @sandbox.boxlite_take_image_digest,
        tool_manifest_digest: @sandbox.boxlite_take_tool_manifest_digest(),
        runtime_policy_digest: @sandbox.boxlite_take_runtime_policy_digest(),
      })
    },
    verification_runtime_digest: fn(_) {
      @sandbox.boxlite_take_runtime_policy_digest()
    },
  }
}

///|
fn native_part_runtime_config(
  repository : @workflow.PartWorkflowRepository,
  server : NativeBoxLiteServerHandle,
  git : NativePartFixtureRepository,
  moon_home : String,
  node : String,
  mcp_script : String,
  now : () -> Int64,
) -> NativePartEffectRuntimeConfig {
  {
    repository,
    repository_adapters: local_part_workflow_repository_adapters(),
    server,
    git_workspace: {
      repository_root: git.root,
      object_directory: git.object_directory,
      staging_root: server.config.root + "/staging",
    },
    git_integration: { repository_root: git.root, goal_ref: git.goal_ref },
    moon_home,
    node_executable: node,
    sandbox_mcp_script: mcp_script,
    claude_root: server.config.root + "/claude/",
    provider_conformance_report_digest: @harness.expected_claude_take_surface_manifest_digest(
      @sandbox.boxlite_take_mcp_tools(),
      "choir_sandbox",
    ),
    now,
  }
}

///|
async fn fail_native_part_runtime(
  runtime : NativePartEffectRuntime,
  message : String,
) -> NativePartLifecycleReport {
  ignore(cleanup_native_part_effect_runtime(runtime))
  failed_native_part_lifecycle(message)
}

///|
pub async fn run_native_part_lifecycle_fixture(
  root : String,
) -> NativePartLifecycleReport {
  if !root.has_prefix("/tmp/choir-v2-take-") ||
    root.contains("/../") ||
    !@sys.create_dir_all(root) ||
    @sys.realpath_native(root) != Some(root) {
    return failed_native_part_lifecycle("native fixture root is invalid")
  }
  let git = match create_native_part_fixture_repository(root) {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
  }
  let repository : @workflow.PartWorkflowRepository = {
    state_store: { path: root + "/workflow.db" },
    artifact_store: { root: root + "/artifacts" },
    max_snapshot_bytes: 1024 * 1024,
  }
  let snapshot = match native_part_fixture_snapshot(repository, git) {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
  }
  let binary = match @sys.getenv("CHOIR_BOXLITE_BINARY") {
    Some(value) => value
    None => "/home/justin/.local/bin/boxlite"
  }
  let runtime_dir = match @sys.getenv("CHOIR_BOXLITE_RUNTIME_DIR") {
    Some(value) => value
    None =>
      "/home/justin/.local/share/choir/runtimes/boxlite-v0.9.7-seccomp-time"
  }
  let moon_home = match @sys.getenv("CHOIR_MOON_HOME") {
    Some(value) => value
    None =>
      match @sys.getenv("HOME") {
        Some(value) => value + "/.moon"
        None => return failed_native_part_lifecycle("Moon home is unavailable")
      }
  }
  let node = match resolve_executable_in_path("node") {
    Some(value) => value
    None => return failed_native_part_lifecycle("Node is unavailable")
  }
  let mcp_script = match @sys.realpath_native("scripts/choir_sandbox_mcp.mjs") {
    Some(value) => value
    None => return failed_native_part_lifecycle("sandbox MCP is unavailable")
  }
  let server = match
    start_native_boxlite_server({
      binary,
      runtime_dir,
      root,
      port: 36000 + @sys.get_pid() % 12000,
      api_key: "choir-native-part-" + @sys.get_pid().to_string(),
    }) {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
  }
  let clock = @ref.new(1000L)
  let now = fn() {
    clock.val = clock.val + 1L
    clock.val
  }
  let first_config = native_part_runtime_config(
    repository, server, git, moon_home, node, mcp_script, now,
  )
  let first_runtime = match create_native_part_effect_runtime(first_config) {
    Ok(value) => value
    Err(error) => {
      ignore(cleanup_native_boxlite_server(server))
      return failed_native_part_lifecycle(error.message())
    }
  }
  let first_counts : NativePartDispatchCounts = {
    implementation: @ref.new(0),
    verification: @ref.new(0),
    audit: @ref.new(0),
  }
  let observed = @ref.new(0)
  let injected = @ref.new(false)
  let first = match
    @workflow.run_new_part_workflow(
      repository,
      local_part_workflow_repository_adapters(),
      snapshot,
      native_part_dependencies(
        repository,
        first_runtime,
        git,
        clock,
        first_counts,
        fn(boundary) {
          if boundary ==
            @workflow.PartPersistenceBoundary::WorkflowEffectObserved {
            observed.val = observed.val + 1
          }
          if !injected.val &&
            boundary ==
            @workflow.PartPersistenceBoundary::WorkflowEffectObserved &&
            observed.val == 3 {
            injected.val = true
            Some(@storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox)
          } else {
            None
          }
        },
      ),
    ) {
    Ok(value) => value
    Err(error) =>
      return fail_native_part_runtime(first_runtime, error.message())
  }
  if first.outcome !=
    @workflow.PartWorkflowRunOutcome::PartRunPersistenceFault(
      @workflow.PartPersistenceBoundary::WorkflowEffectObserved,
      @storage.StateStoreFaultPoint::StateAfterMutationBeforeOutbox,
    ) ||
    first_counts.implementation.val != 1 ||
    first_counts.verification.val != 0 ||
    first_counts.audit.val != 0 {
    return fail_native_part_runtime(
      first_runtime, "implementation fault did not stop at the durable witness boundary",
    )
  }
  let restarted_config = native_part_runtime_config(
    repository,
    first_runtime.server.val,
    git,
    moon_home,
    node,
    mcp_script,
    now,
  )
  let restarted_runtime = match
    create_native_part_effect_runtime(restarted_config) {
    Ok(value) => value
    Err(error) =>
      return fail_native_part_runtime(first_runtime, error.message())
  }
  let restarted_counts : NativePartDispatchCounts = {
    implementation: @ref.new(0),
    verification: @ref.new(0),
    audit: @ref.new(0),
  }
  let resumed = match
    @workflow.resume_part_workflow(
      repository,
      local_part_workflow_repository_adapters(),
      snapshot.workflow_id,
      native_part_dependencies(
        repository,
        restarted_runtime,
        git,
        clock,
        restarted_counts,
        fn(_) { None },
      ),
    ) {
    Ok(value) => value
    Err(error) =>
      return fail_native_part_runtime(restarted_runtime, error.message())
  }
  if resumed.outcome != @workflow.PartWorkflowRunOutcome::PartRunIntegrated {
    return fail_native_part_runtime(
      restarted_runtime,
      "restarted native Part did not integrate: outcome=" +
      resumed.outcome.to_json().stringify(indent=0) +
      " stage=" +
      resumed.snapshot.stage.to_json().stringify(indent=0) +
      " dispatches=" +
      restarted_counts.implementation.val.to_string() +
      "/" +
      restarted_counts.verification.val.to_string() +
      "/" +
      restarted_counts.audit.val.to_string() +
      " verification=" +
      native_part_verification_debug(repository, resumed.snapshot),
    )
  }
  let branch_head = match
    native_part_fixture_git_value(git.root, ["rev-parse", git.goal_ref]) {
    Ok(value) => @control.GitOid(value)
    Err(error) =>
      return fail_native_part_runtime(restarted_runtime, error.message())
  }
  let integrated_source = match
    native_part_fixture_git_value(git.root, [
      "show",
      git.goal_ref + ":src/answer.mbt",
    ]) {
    Ok(value) => value
    Err(error) =>
      return fail_native_part_runtime(restarted_runtime, error.message())
  }
  let candidate = resumed.snapshot.candidate
  let promotion = resumed.snapshot.promotion_commit
  let valid = resumed.snapshot.effect_receipts.length() == 12 &&
    resumed.snapshot.verification_receipts.length() == 1 &&
    resumed.snapshot.audit_receipt is Some(_) &&
    resumed.snapshot.integration_receipt is Some(_) &&
    restarted_counts.implementation.val == 0 &&
    restarted_counts.verification.val == 1 &&
    restarted_counts.audit.val == 1 &&
    candidate
    is Some({ changed_paths: [@control.RepoPath("src/answer.mbt")], .. }) &&
    promotion is Some({ commit_oid, .. }) &&
    commit_oid == branch_head &&
    integrated_source.contains("answer() -> Int { 2 }")
  let cleanup = cleanup_native_part_effect_runtime(restarted_runtime)
  match cleanup {
    Err(error) => return failed_native_part_lifecycle(error.message())
    Ok(_) => ()
  }
  if !valid {
    return failed_native_part_lifecycle(
      "native Part violated receipt, restart, diff, or promotion invariants",
    )
  }
  {
    passed: true,
    effect_receipt_count: resumed.snapshot.effect_receipts.length(),
    verification_receipt_count: resumed.snapshot.verification_receipts.length(),
    audit_receipt_count: 1,
    integration_receipt_count: 1,
    implementation_dispatches_before_restart: first_counts.implementation.val,
    implementation_dispatches_after_restart: restarted_counts.implementation.val,
    provider_dispatches_after_restart: restarted_counts.verification.val +
    restarted_counts.audit.val,
    candidate_commit_oid: candidate.map(fn(value) { value.commit_oid }),
    promotion_commit_oid: promotion.map(fn(value) { value.commit_oid }),
    failure: None,
  }
}

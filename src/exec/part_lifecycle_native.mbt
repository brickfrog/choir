///|
pub(all) struct NativePartLifecycleReport {
  passed : Bool
  provider_surface : @control.ProviderSurfaceId?
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
  git_directory : String
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
priv struct NativePartFixtureDefinition {
  key : String
  goal_id : @control.GoalId
  part_id : @control.PartId
  source_path : @control.RepoPath
  instruction : String
  surface : @control.ProviderSurfaceId
}

///|
fn failed_native_part_lifecycle(message : String) -> NativePartLifecycleReport {
  {
    passed: false,
    provider_surface: None,
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
async fn create_native_part_fixture_repository_with_sources(
  root : String,
  sources : Array[(String, String)],
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
    sources.length() == 0 {
    return Err(native_part_effect_error("fixture repository creation failed"))
  }
  for source in sources {
    if !source.0.has_prefix("src/") ||
      source.0.contains("..") ||
      !@sys.write_file_sync(repository_root + "/" + source.0, source.1) {
      return Err(
        native_part_effect_error("fixture repository source creation failed"),
      )
    }
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
  let git_directory = match
    native_part_fixture_git_value(repository_root, [
      "rev-parse", "--path-format=absolute", "--absolute-git-dir",
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !valid_hex_oid_text(head) ||
    !valid_hex_oid_text(tree) ||
    @sys.realpath_native(git_directory) != Some(git_directory) ||
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
    git_directory,
    object_directory,
    goal_ref,
  })
}

///|
async fn create_native_part_fixture_repository(
  root : String,
) -> Result[NativePartFixtureRepository, @types.ChoirError] {
  create_native_part_fixture_repository_with_sources(root, [
    (
      "src/answer.mbt", "///|\npub fn answer() -> Int { 1 }\n\n///|\ntest \"answer is corrected\" {\n  assert_eq(answer(), 2)\n}\n",
    ),
  ])
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
  surface : @control.ProviderSurfaceId,
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId(id),
    take_id: take.id,
    sandbox_generation_id: sandbox.generation_id,
    surface,
    effective_surface_manifest_digest: surface_digest,
    cursor_class: match surface {
      @control.ProviderSurfaceId::CodexSubscriptionCli =>
        @control.HarnessCursorClass::HarnessCursorProviderEventId
      @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
        @control.HarnessCursorClass::HarnessCursorNotResumable
    },
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn native_part_fixture_snapshot_for_definition(
  repository : @workflow.PartWorkflowRepository,
  git : NativePartFixtureRepository,
  definition : NativePartFixtureDefinition,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  let goal_id = definition.goal_id
  let part_id = definition.part_id
  let key = definition.key
  let revision_id = @control.RevisionId("revision-" + key)
  let verification_spec_id = @control.VerificationSpecId("verify-" + key)
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
    "take-" + key + "-implementation",
    goal_id,
    @control.TakePurpose::Implementation(part_id, revision_id),
  )
  let verification = native_part_fixture_take(
    "take-" + key + "-verification",
    goal_id,
    @control.TakePurpose::PartVerification(
      part_id,
      implementation.id,
      verification_spec_digest,
    ),
  )
  let audit = native_part_fixture_take(
    "take-" + key + "-audit",
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
      @utf8.encode(definition.instruction),
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
    arguments: [
      "test",
      "--target",
      "wasm",
      definition.source_path.0,
      "--target-dir",
      "/scratch/verification-" + key,
    ],
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
      key +
      "\u{00}" +
      git.base_commit_oid.0 +
      "\u{00}" +
      instruction.digest.0 +
      "\u{00}" +
      process_artifact.digest.0,
    ),
  )
  let goal : @control.Goal = {
    id: goal_id,
    contract_digest: @storage.artifact_digest(
      @utf8.encode(
        "choir.native-goal-contract.v1\u{00}" +
        goal_id.0 +
        "\u{00}" +
        git.base_commit_oid.0,
      ),
    ),
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
    repair_conflict_id: None,
    instruction_artifact: instruction,
    base_commit_oid: git.base_commit_oid,
    base_tree_oid: git.base_tree_oid,
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([
        @control.MutationClaim::ExactPath(definition.source_path),
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
    migration_contract_ref: None,
    migration_continuation_ref_digest: None,
    implementation_capability_profile_digest: implementation_profile_digest,
    verification_capability_profile_digest: verification_profile_digest,
    audit_capability_profile_digest: audit_profile_digest,
  }
  let implementation_surface_digest = match definition.surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
      @harness.expected_claude_take_surface_manifest_digest(
        @sandbox.boxlite_take_mcp_tools(),
        "choir_sandbox",
      )
    @control.ProviderSurfaceId::CodexSubscriptionCli =>
      @harness.codex_effective_surface_manifest_digest(
        @sandbox.boxlite_take_codex_mcp_tools(),
        "choir_sandbox",
      )
  }
  let assurance_surface_digest = match definition.surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
      @harness.expected_claude_take_surface_manifest_digest(
        @sandbox.boxlite_assurance_mcp_tools(),
        "choir_sandbox",
      )
    @control.ProviderSurfaceId::CodexSubscriptionCli =>
      @harness.codex_effective_surface_manifest_digest(
        @sandbox.boxlite_assurance_codex_mcp_tools(),
        "choir_sandbox",
      )
  }
  let implementation_sandbox = native_part_fixture_sandbox(
    "sandbox-" + key + "-implementation",
    "generation-" + key + "-implementation",
    implementation,
    implementation_profile_digest,
  )
  let verification_sandbox = native_part_fixture_sandbox(
    "sandbox-" + key + "-verification",
    "generation-" + key + "-verification",
    verification,
    verification_profile_digest,
  )
  let audit_sandbox = native_part_fixture_sandbox(
    "sandbox-" + key + "-audit",
    "generation-" + key + "-audit",
    audit,
    audit_profile_digest,
  )
  let identities : @workflow.PartIdentityPlan = {
    implementation_take: implementation,
    implementation_sandbox,
    implementation_session: native_part_fixture_session(
      "session-" + key + "-implementation",
      implementation,
      implementation_sandbox,
      implementation_surface_digest,
      definition.surface,
    ),
    verification_take: verification,
    verification_sandbox,
    verification_session: native_part_fixture_session(
      "session-" + key + "-verification",
      verification,
      verification_sandbox,
      assurance_surface_digest,
      definition.surface,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: native_part_fixture_session(
      "session-" + key + "-audit",
      audit,
      audit_sandbox,
      assurance_surface_digest,
      definition.surface,
    ),
  }
  @workflow.initialize_part_workflow(
    "workflow-" + key,
    goal,
    part,
    contract,
    identities,
    @control.FencingEpoch(1L),
    fn(_) { true },
  )
}

///|
fn native_part_fixture_snapshot(
  repository : @workflow.PartWorkflowRepository,
  git : NativePartFixtureRepository,
  surface : @control.ProviderSurfaceId,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  native_part_fixture_snapshot_for_definition(repository, git, {
    key: "native-part",
    goal_id: @control.GoalId("goal-native-part"),
    part_id: @control.PartId("part-native"),
    source_path: @control.RepoPath("src/answer.mbt"),
    instruction: "Change only src/answer.mbt so answer() returns 2. Every implementation, verification, or audit role must begin by calling read_file with path src/answer.mbt. Make the smallest edit when authorized, run /opt/moon/bin/moon test --target wasm src/answer.mbt in the sandbox, and finish with the required JSON outcome.",
    surface,
  })
}

///|
fn counted_native_part_effects(
  effects : @workflow.PartWorkflowDriverAdapters,
  counts : NativePartDispatchCounts,
  effect_error : Ref[String]?,
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
      let result = (effects.execute)(snapshot, intent)
      match (result, effect_error) {
        (Err(error), Some(witness)) => witness.val = error.message()
        _ => ()
      }
      result
    },
    reconcile: effects.reconcile,
  }
}

///|
fn native_part_effect_uses_serial_boxlite_cli(
  kind : @workflow.PartEffectKind,
) -> Bool {
  kind is @workflow.PartEffectKind::PrepareImplementationSandbox(_) ||
  kind is @workflow.PartEffectKind::PrepareVerificationSandbox(_) ||
  kind is @workflow.PartEffectKind::PrepareAuditSandbox(_) ||
  kind is @workflow.PartEffectKind::DispatchVerification(_, _, _) ||
  kind is @workflow.PartEffectKind::DispatchAudit(_, _, _)
}

///|
fn serialized_native_part_boxlite_effects(
  effects : @workflow.PartWorkflowDriverAdapters,
  lock : Ref[Bool]?,
) -> @workflow.PartWorkflowDriverAdapters {
  match lock {
    None => effects
    Some(lock) =>
      {
        execute: async fn(snapshot, intent) {
          // Provider implementation sessions remain parallel. BoxLite's
          // host CLI operations share one local server and are serialized so
          // concurrent verification/audit clients cannot close each other's
          // guest execution channel.
          if !native_part_effect_uses_serial_boxlite_cli(intent.kind) {
            return (effects.execute)(snapshot, intent)
          }
          while lock.val {
            @async.sleep(10)
          }
          lock.val = true
          let result = (effects.execute)(snapshot, intent)
          lock.val = false
          result
        },
        reconcile: effects.reconcile,
      }
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
fn native_part_audit_debug(
  repository : @workflow.PartWorkflowRepository,
  snapshot : @workflow.PartWorkflowSnapshot,
) -> String {
  let result = match snapshot.audit_result {
    Some(value) =>
      "outcome=" +
      value.outcome.to_json().stringify(indent=0) +
      " total=" +
      value.total_findings_count.to_string() +
      " blocking=" +
      value.blocking_findings_count.to_string()
    None => "missing"
  }
  let receipt = match snapshot.audit_receipt {
    Some(value) =>
      "outcome=" +
      value.outcome.to_json().stringify(indent=0) +
      " total=" +
      value.total_findings_count.to_string() +
      " blocking=" +
      value.blocking_findings_count.to_string()
    None => "missing"
  }
  let findings = match snapshot.audit_result {
    Some({ findings_artifact: Some(reference), .. }) =>
      match
        (local_part_workflow_repository_adapters().artifacts.read)(
          repository.artifact_store,
          { digest: reference.digest, max_bytes: 131072 },
        ) {
        Ok(value) => @utf8.decode_lossy(value)
        Err(error) => "findings-error=" + error.message()
      }
    _ => "none"
  }
  "result=" +
  result +
  " receipt=" +
  receipt +
  " findings=" +
  findings +
  " take=" +
  snapshot.audit_take.to_json().stringify(indent=0)
}

///|
fn native_part_dependencies(
  repository : @workflow.PartWorkflowRepository,
  runtime : NativePartEffectRuntime,
  clock : Ref[Int64],
  counts : NativePartDispatchCounts,
  surface : @control.ProviderSurfaceId,
  integration_head : @control.GitOid?,
  sandbox_prepare_lock : Ref[Bool]?,
  fault : (@workflow.PartPersistenceBoundary) -> @storage.StateStoreFaultPoint?,
  effect_error? : Ref[String]? = None,
) -> @workflow.PartWorkflowDriverDependencies {
  native_part_dependencies_with_admission(
    repository, runtime, clock, counts, surface, integration_head, sandbox_prepare_lock,
    fault, effect_error~,
  )
}

///|
fn native_part_dependencies_with_admission(
  repository : @workflow.PartWorkflowRepository,
  runtime : NativePartEffectRuntime,
  clock : Ref[Int64],
  counts : NativePartDispatchCounts,
  surface : @control.ProviderSurfaceId,
  integration_head : @control.GitOid?,
  sandbox_prepare_lock : Ref[Bool]?,
  fault : (@workflow.PartPersistenceBoundary) -> @storage.StateStoreFaultPoint?,
  explicit_admission? : @workflow.PartIntegrationAdmission? = None,
  effect_error? : Ref[String]? = None,
) -> @workflow.PartWorkflowDriverDependencies {
  let now = fn() {
    clock.val = clock.val + 1L
    clock.val
  }
  let effects = counted_native_part_effects(
    serialized_native_part_boxlite_effects(
      native_part_effect_adapters(runtime),
      sandbox_prepare_lock,
    ),
    counts,
    effect_error,
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
    is_nfc: native_path_is_nfc,
    audit_receipt_metadata: fn(snapshot) {
      let (provider_identity, model_identity) = match surface {
        @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
          (
            "claude-code-2.1.217",
            @control.ModelIdentity::ReportedModelIdentity(
              "claude-subscription-runtime",
            ),
          )
        @control.ProviderSurfaceId::CodexSubscriptionCli =>
          ("codex-cli-0.145.0", @control.ModelIdentity::UnreportedModelIdentity)
      }
      Ok({
        receipt_id: @control.ReceiptId(
          "audit-receipt-" + snapshot.audit_take.id.0,
        ),
        provider_surface_id: surface,
        provider_identity,
        model_identity,
      })
    },
    goal_authorizes_new_effects: fn() {
      Ok(@workflow.PartGoalAuthorization::PartGoalAuthorized(None))
    },
    integration_admission: fn(snapshot) {
      match explicit_admission {
        Some(admission) => Ok(admission)
        None =>
          match integration_head {
            None =>
              Ok(@workflow.PartIntegrationAdmission::PartIntegrationDeferred)
            Some(expected_goal_head_oid) =>
              Ok(
                @workflow.PartIntegrationAdmission::PartIntegrationAdmitted({
                  lease: {
                    id: @control.IntegrationLeaseId(
                      "integration-lease-" + snapshot.part.id.0,
                    ),
                    goal_id: snapshot.goal.id,
                    fencing_epoch: snapshot.fencing_epoch,
                    holder: "choird-native-conformance",
                  },
                  intent_id: @control.IntegrationIntentId(
                    "integration-intent-" + snapshot.part.id.0,
                  ),
                  expected_goal_head_oid,
                  promotion_metadata_digest: @storage.artifact_digest(
                    @utf8.encode(
                      "choir.native-part-promotion.v1\u{00}" +
                      snapshot.part.id.0,
                    ),
                  ),
                  git_witness_ref: "refs/choir/witness/" + snapshot.part.id.0,
                }),
              )
          }
      }
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
  native_part_runtime_config_for_paths(
    repository,
    server,
    git.root,
    git.git_directory,
    git.object_directory,
    git.goal_ref,
    moon_home,
    node,
    mcp_script,
    now,
  )
}

///|
fn native_part_runtime_config_for_paths(
  repository : @workflow.PartWorkflowRepository,
  server : NativeBoxLiteServerHandle,
  repository_root : String,
  git_directory : String,
  object_directory : String,
  goal_ref : String,
  moon_home : String,
  node : String,
  mcp_script : String,
  now : () -> Int64,
  goal_cancellation_requested? : () -> Bool = fn() { false },
) -> NativePartEffectRuntimeConfig {
  {
    repository,
    repository_adapters: local_part_workflow_repository_adapters(),
    server,
    git_workspace: {
      repository_root,
      object_directory,
      staging_root: server.config.root + "/staging",
    },
    git_integration: {
      repository_root,
      git_directory,
      object_directory,
      control_root: server.config.root + "/integration-control",
      goal_ref,
    },
    moon_home,
    node_executable: node,
    sandbox_mcp_script: mcp_script,
    claude_root: server.config.root + "/claude/",
    codex_root: server.config.root + "/codex/",
    provider_conformance_report_digest: fn(surface) {
      match surface {
        @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
          @harness.expected_claude_take_surface_manifest_digest(
            @sandbox.boxlite_assurance_mcp_tools(),
            "choir_sandbox",
          )
        @control.ProviderSurfaceId::CodexSubscriptionCli =>
          @harness.codex_effective_surface_manifest_digest(
            @sandbox.boxlite_assurance_codex_mcp_tools(),
            "choir_sandbox",
          )
      }
    },
    now,
    goal_cancellation_requested,
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
pub async fn run_native_part_lifecycle_fixture_for_surface(
  root : String,
  surface : @control.ProviderSurfaceId,
) -> NativePartLifecycleReport {
  if !root.has_prefix("/tmp/choir-take-") ||
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
  let snapshot = match native_part_fixture_snapshot(repository, git, surface) {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
  }
  let binary = match native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
  }
  let runtime_dir = match native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
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
  let injected = @ref.new(false)
  let first = match
    @workflow.run_new_part_workflow(
      repository,
      local_part_workflow_repository_adapters(),
      snapshot,
      native_part_dependencies(
        repository,
        first_runtime,
        clock,
        first_counts,
        surface,
        Some(git.base_commit_oid),
        None,
        fn(boundary) {
          if !injected.val &&
            boundary ==
            @workflow.PartPersistenceBoundary::WorkflowEffectObserved &&
            first_counts.implementation.val == 1 {
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
      first_runtime,
      "implementation fault did not stop at the durable witness boundary: outcome=" +
      first.outcome.to_json().stringify(indent=0) +
      " implementation=" +
      first_counts.implementation.val.to_string() +
      " verification=" +
      first_counts.verification.val.to_string() +
      " audit=" +
      first_counts.audit.val.to_string(),
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
  let restarted_effect_error = @ref.new("")
  let resumed = match
    @workflow.resume_part_workflow(
      repository,
      local_part_workflow_repository_adapters(),
      snapshot.workflow_id,
      native_part_dependencies(
        repository,
        restarted_runtime,
        clock,
        restarted_counts,
        surface,
        Some(git.base_commit_oid),
        None,
        fn(_) { None },
        effect_error=Some(restarted_effect_error),
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
      native_part_verification_debug(repository, resumed.snapshot) +
      " audit=" +
      native_part_audit_debug(repository, resumed.snapshot) +
      " effect-error=" +
      restarted_effect_error.val,
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
  let valid = resumed.snapshot.effect_receipts.length() == 15 &&
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
      "native Part violated receipt, restart, diff, or promotion invariants: effects=" +
      resumed.snapshot.effect_receipts.length().to_string() +
      " verification_receipts=" +
      resumed.snapshot.verification_receipts.length().to_string() +
      " audit_receipt=" +
      (resumed.snapshot.audit_receipt is Some(_)).to_string() +
      " integration_receipt=" +
      (resumed.snapshot.integration_receipt is Some(_)).to_string() +
      " dispatches=" +
      restarted_counts.implementation.val.to_string() +
      "/" +
      restarted_counts.verification.val.to_string() +
      "/" +
      restarted_counts.audit.val.to_string() +
      " candidate=" +
      candidate.to_json().stringify(indent=0) +
      " promotion=" +
      promotion.to_json().stringify(indent=0) +
      " branch_head=" +
      branch_head.0 +
      " integrated_answer=" +
      integrated_source.contains("answer() -> Int { 2 }").to_string(),
    )
  }
  {
    passed: true,
    provider_surface: Some(surface),
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

///|
pub async fn run_native_part_lifecycle_fixture(
  root : String,
) -> NativePartLifecycleReport {
  run_native_part_lifecycle_fixture_for_surface(
    root,
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
}

///|
pub async fn run_native_codex_part_lifecycle_fixture(
  root : String,
) -> NativePartLifecycleReport {
  run_native_part_lifecycle_fixture_for_surface(
    root,
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
}

///|
async fn run_native_part_cancellation_fixture_for_surface(
  root : String,
  surface : @control.ProviderSurfaceId,
) -> NativePartLifecycleReport {
  if !root.has_prefix("/tmp/choir-take-") ||
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
  let snapshot = match native_part_fixture_snapshot(repository, git, surface) {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
  }
  let binary = match native_boxlite_binary_path() {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
  }
  let runtime_dir = match native_boxlite_runtime_dir() {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
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
      api_key: "choir-native-cancel-" + @sys.get_pid().to_string(),
    }) {
    Ok(value) => value
    Err(error) => return failed_native_part_lifecycle(error.message())
  }
  let clock = @ref.new(2000L)
  let now = fn() {
    clock.val = clock.val + 1L
    clock.val
  }
  let cancellation_probes = @ref.new(0)
  let config = native_part_runtime_config_for_paths(
    repository,
    server,
    git.root,
    git.git_directory,
    git.object_directory,
    git.goal_ref,
    moon_home,
    node,
    mcp_script,
    now,
    goal_cancellation_requested=fn() {
      cancellation_probes.val = cancellation_probes.val + 1
      cancellation_probes.val >= 5
    },
  )
  let runtime = match create_native_part_effect_runtime(config) {
    Ok(value) => value
    Err(error) => {
      ignore(cleanup_native_boxlite_server(server))
      return failed_native_part_lifecycle(error.message())
    }
  }
  let counts : NativePartDispatchCounts = {
    implementation: @ref.new(0),
    verification: @ref.new(0),
    audit: @ref.new(0),
  }
  let execution = @workflow.run_new_part_workflow(
    repository,
    local_part_workflow_repository_adapters(),
    snapshot,
    native_part_dependencies(
      repository,
      runtime,
      clock,
      counts,
      surface,
      Some(git.base_commit_oid),
      None,
      fn(_) { None },
    ),
  )
  match execution {
    Err(error) if error.to_wire_string() == "canceled" => ()
    Err(error) =>
      return fail_native_part_runtime(
        runtime,
        "provider cancellation returned " + error.message(),
      )
    Ok(_) =>
      return fail_native_part_runtime(
        runtime, "provider Take completed before the cancellation cutoff",
      )
  }
  let stored = match
    @workflow.load_part_snapshot(
      repository,
      local_part_workflow_repository_adapters(),
      snapshot.workflow_id,
    ) {
    Ok(Some(value)) => value
    Ok(None) =>
      return fail_native_part_runtime(
        runtime, "interrupted Part snapshot is absent",
      )
    Err(error) => return fail_native_part_runtime(runtime, error.message())
  }
  if !(stored.snapshot.pending_effect
    is Some(
      {
        lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
        kind: @workflow.PartEffectKind::DispatchImplementation(_, _),
        ..,
      }
    )) ||
    counts.implementation.val != 1 ||
    cancellation_probes.val < 5 {
    return fail_native_part_runtime(
      runtime, "provider interruption did not preserve the authorized provider effect",
    )
  }
  let canceled = match
    @workflow.persist_part_goal_cancellation(
      repository,
      local_part_workflow_repository_adapters(),
      stored,
    ) {
    Ok(value) => value
    Err(error) => return fail_native_part_runtime(runtime, error.message())
  }
  let valid = @workflow.part_cancellation_disposition_is_known(
      canceled.snapshot,
    ) &&
    canceled.snapshot.stage == @workflow.PartWorkflowStage::PartBlocked &&
    canceled.snapshot.pending_effect
    is Some(
      { lifecycle: @workflow.PartEffectLifecycle::PartEffectUncertain, .. }
    ) &&
    canceled.snapshot.implementation_take.lifecycle ==
    @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeInterrupted,
    ) &&
    canceled.snapshot.sandbox_leases.all(fn(lease) {
      lease.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeaseUncertain
    }) &&
    canceled.snapshot.harness_sessions.all(fn(session) {
      session.lifecycle ==
      @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain
    })
  let cleanup = cleanup_native_part_effect_runtime(runtime)
  match cleanup {
    Err(error) => return failed_native_part_lifecycle(error.message())
    Ok(_) => ()
  }
  if !valid {
    return failed_native_part_lifecycle(
      "provider cancellation did not persist an honest uncertain disposition",
    )
  }
  {
    passed: true,
    provider_surface: Some(surface),
    effect_receipt_count: canceled.snapshot.effect_receipts.length(),
    verification_receipt_count: 0,
    audit_receipt_count: 0,
    integration_receipt_count: 0,
    implementation_dispatches_before_restart: counts.implementation.val,
    implementation_dispatches_after_restart: 0,
    provider_dispatches_after_restart: 0,
    candidate_commit_oid: None,
    promotion_commit_oid: None,
    failure: None,
  }
}

///|
pub async fn run_native_claude_cancellation_fixture(
  root : String,
) -> NativePartLifecycleReport {
  run_native_part_cancellation_fixture_for_surface(
    root,
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
}

///|
pub async fn run_native_codex_cancellation_fixture(
  root : String,
) -> NativePartLifecycleReport {
  run_native_part_cancellation_fixture_for_surface(
    root,
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
}

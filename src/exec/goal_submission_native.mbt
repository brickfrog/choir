///|
pub(all) struct NativeConductorGoalSubmissionReport {
  accepted : Bool
  goal_id : @control.GoalId
  proposal_digest : @control.Digest
  selection_decision_digest : @control.Digest
  source_snapshot_digest : @control.Digest
  accepted_part_ids : Array[@control.PartId]
  initialized_part_count : Int
  execution_registered : Bool
  rejections : Array[@workflow.PartSelectionRejection]
  replayed : Bool
} derive(Debug, Eq, ToJson)

///|
fn native_goal_submission_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("native Goal submission: " + detail)
}

///|
fn native_goal_submission_digest(
  domain : String,
  identity : Json,
) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode(domain + "\u{00}" + identity.stringify(indent=0)),
  )
}

///|
fn native_goal_submission_verification_arguments(
  proposed : Array[String],
  resource_key : String,
) -> Result[Array[String], @types.ChoirError] {
  for argument in proposed {
    if argument == "--target-dir" || argument.has_prefix("--target-dir=") {
      return Err(
        native_goal_submission_error(
          "verification target directory is controlled by Choir",
        ),
      )
    }
  }
  let arguments = proposed.copy()
  arguments.push("--target-dir")
  arguments.push("/scratch/verification-" + resource_key)
  Ok(arguments)
}

///|
fn native_goal_submission_resource_key(
  goal_id : @control.GoalId,
  part_id : @control.PartId,
) -> String {
  @storage.digest_text(
    native_goal_submission_digest(
      "choir.goal-part-resource.v1",
      [goal_id.to_json(), part_id.to_json()].to_json(),
    ),
  )
}

///|
fn native_goal_submission_oid(value : String) -> @control.GitOid? {
  let trimmed = value.trim().to_lower().to_owned()
  if trimmed.length() != 40 && trimmed.length() != 64 {
    return None
  }
  for char in trimmed {
    if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
      return None
    }
  }
  Some(@control.GitOid(trimmed))
}

///|
async fn native_goal_submission_capture(
  capture : async (Command) -> (Int, String),
  project_dir : String,
  program : String,
  arguments : Array[String],
  label : String,
) -> Result[String, @types.ChoirError] {
  let (status, output) = capture({
    program,
    args: arguments,
    workdir: Some(project_dir),
  })
  if status == 0 {
    Ok(output.trim().to_owned())
  } else {
    let detail = output.trim().to_owned()
    let suffix = if detail == "" { "" } else { ": " + detail }
    Err(
      native_goal_submission_error(
        label + " capture failed with status " + status.to_string() + suffix,
      ),
    )
  }
}

///|
async fn capture_native_goal_branch_ref(
  project_dir : String,
  capture : async (Command) -> (Int, String),
) -> Result[@workflow.GitRefName, @types.ChoirError] {
  let value = match
    native_goal_submission_capture(
      capture,
      project_dir,
      "git",
      ["symbolic-ref", "--quiet", "HEAD"],
      "current branch",
    ) {
    Ok(value) => value
    Err(_) =>
      return Err(
        native_goal_submission_error(
          "current checkout must be on a named branch",
        ),
      )
  }
  let branch_ref = @workflow.GitRefName(value)
  if !branch_ref.0.has_prefix("refs/heads/") ||
    branch_ref.0.length() == "refs/heads/".length() {
    return Err(native_goal_submission_error("current branch ref is invalid"))
  }
  Ok(branch_ref)
}

///|
fn native_goal_submission_source_part(
  snapshot : @workflow.GoalSelectionSnapshot,
  part_id : @control.PartId,
) -> @workflow.GoalSelectionSourcePart? {
  for part in snapshot.parts {
    if part.part_id == part_id {
      return Some(part)
    }
  }
  None
}

///|
async fn capture_native_goal_selection_snapshot(
  draft : @workflow.ConductorGoalDraft,
  base_ref : @workflow.GitRefName,
  project_dir : String,
  capture : async (Command) -> (Int, String),
) -> Result[@workflow.GoalSelectionSnapshot, @types.ChoirError] {
  let root = match
    native_goal_submission_capture(
      capture,
      project_dir,
      "git",
      ["rev-parse", "--show-toplevel"],
      "repository",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let base_commit = match
    native_goal_submission_capture(
      capture,
      project_dir,
      "git",
      ["rev-parse", "--verify", base_ref.0 + "^{commit}"],
      "base commit",
    ) {
    Ok(value) =>
      match native_goal_submission_oid(value) {
        Some(oid) => oid
        None =>
          return Err(native_goal_submission_error("base commit is invalid"))
      }
    Err(error) => return Err(error)
  }
  let base_tree = match
    native_goal_submission_capture(
      capture,
      project_dir,
      "git",
      ["show", "-s", "--format=%T", "--no-show-signature", base_commit.0],
      "base tree",
    ) {
    Ok(value) =>
      match native_goal_submission_oid(value) {
        Some(oid) => oid
        None => return Err(native_goal_submission_error("base tree is invalid"))
      }
    Err(error) => return Err(error)
  }
  let bead_args : Array[String] = ["show"]
  for part in draft.parts {
    bead_args.push(part.part_id.0)
  }
  bead_args.push("--json")
  bead_args.push("--readonly")
  let beads_json = match
    native_goal_submission_capture(
      capture, project_dir, "bd", bead_args, "Beads source",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let repository_id = @workflow.RepositoryId(
    "sha256:" +
    @storage.digest_text(
      @storage.artifact_digest(@utf8.encode("choir.repository.v1\u{00}" + root)),
    ),
  )
  @workflow.goal_selection_snapshot_from_beads_json(
    repository_id, base_commit, base_tree, beads_json,
  )
}

///|
fn native_goal_submission_adopt(
  repository : @workflow.PartWorkflowRepository,
  content : Bytes,
  provenance : @storage.ArtifactProvenance,
  retention : @storage.ArtifactRetention,
) -> Result[@control.ArtifactReference, @types.ChoirError] {
  let digest = @storage.artifact_digest(content)
  let receipt = match
    (local_part_workflow_repository_adapters().artifacts.adopt)(
      repository.artifact_store,
      { content, expected_digest: digest, provenance, retention },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if receipt.digest != digest || receipt.byte_length != content.length() {
    return Err(
      native_goal_submission_error("artifact adoption receipt is false"),
    )
  }
  Ok({ artifact_id: @storage.artifact_id_text(receipt.artifact_id), digest })
}

///|
fn native_goal_submission_mutation_declaration(
  draft : @workflow.ConductorPartDraft,
) -> @control.MutationDeclaration {
  if draft.repository_wide {
    @control.MutationDeclaration::CompleteMutationDeclaration([
      @control.MutationClaim::RepositoryWide,
    ])
  } else {
    let claims : Array[@control.MutationClaim] = []
    for path in draft.exact_paths {
      claims.push(@control.MutationClaim::ExactPath(path))
    }
    for path in draft.path_trees {
      claims.push(@control.MutationClaim::PathTree(path))
    }
    @control.MutationDeclaration::CompleteMutationDeclaration(claims)
  }
}

///|
fn native_goal_submission_profile_digest(
  surface : @control.ProviderSurfaceId,
  purpose : String,
) -> @control.Digest {
  native_goal_submission_digest(
    "choir.capability-profile.v1",
    [surface.to_json(), purpose.to_json()].to_json(),
  )
}

///|
fn compile_native_conductor_part_proposal(
  repository : @workflow.PartWorkflowRepository,
  draft : @workflow.ConductorGoalDraft,
  part : @workflow.ConductorPartDraft,
  snapshot : @workflow.GoalSelectionSnapshot,
) -> Result[@workflow.ConductorPartProposal, @types.ChoirError] {
  let source = native_goal_submission_source_part(snapshot, part.part_id)
  let source_revision_digest = match source {
    Some(value) => value.source_revision_digest
    None =>
      native_goal_submission_digest(
        "choir.missing-source-revision.v1",
        part.part_id.to_json(),
      )
  }
  let source_content_digest = match source {
    Some(value) => value.source_content_digest
    None =>
      native_goal_submission_digest(
        "choir.missing-source-content.v1",
        part.part_id.to_json(),
      )
  }
  let dependency_ids = match source {
    Some(value) => value.dependency_ids
    None => []
  }
  let revision_id = @control.RevisionId("revision-" + part.part_id.0 + "-1")
  let verification_spec_id = @control.VerificationSpecId(
    "verify-" + part.part_id.0 + "-1",
  )
  let resource_key = native_goal_submission_resource_key(
    draft.goal_id,
    part.part_id,
  )
  let verification_take_id = @control.TakeId(
    "take-" + resource_key + "-verification-1",
  )
  let instruction = match
    native_goal_submission_adopt(
      repository,
      @utf8.encode(part.instruction),
      @storage.ArtifactProvenance::ArtifactTaskInstruction(revision_id),
      @storage.ArtifactRetention::ArtifactUntilGoalTerminal(draft.goal_id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let verification_arguments = match
    native_goal_submission_verification_arguments(
      part.verification.arguments,
      resource_key,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let verification_spec_digest = native_goal_submission_digest(
    "choir.verification-spec.v1",
    [
      draft.goal_id.to_json(),
      part.part_id.to_json(),
      verification_arguments.to_json(),
      part.verification.timeout_ms.to_json(),
    ].to_json(),
  )
  let process : @sandbox.SandboxProcessSpec = {
    authority: @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
      verification_take_id, verification_spec_id, verification_spec_digest,
    ),
    executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
      @sandbox.SandboxRegisteredToolId("moon"),
      @sandbox.boxlite_take_tool_manifest_digest(),
    ),
    arguments: verification_arguments,
    working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceRoot,
    environment: [
      { key: "MOON_HOME", value: "/scratch/home/.moon" },
      { key: "NO_COLOR", value: "1" },
    ],
    stdin: @sandbox.SandboxStdinPolicy::SandboxStdinClosed,
    timeout_ms: part.verification.timeout_ms,
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
    native_goal_submission_adopt(
      repository,
      @utf8.encode(process.to_json().stringify(indent=0)),
      @storage.ArtifactProvenance::ArtifactVerificationProcessSpec(
        verification_spec_id,
      ),
      @storage.ArtifactRetention::ArtifactUntilGoalTerminal(draft.goal_id),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let audit_policy_digest = native_goal_submission_digest(
    "choir.part-audit-policy.v1",
    draft.goal_id.to_json(),
  )
  let implementation_profile_digest = native_goal_submission_profile_digest(
    part.provider_surface,
    "implementation",
  )
  let verification_profile_digest = native_goal_submission_profile_digest(
    part.provider_surface,
    "verification",
  )
  let audit_profile_digest = native_goal_submission_profile_digest(
    part.provider_surface,
    "audit",
  )
  let mutation_declaration = native_goal_submission_mutation_declaration(part)
  let contract_digest = native_goal_submission_digest(
    "choir.task-contract.v2",
    [
      revision_id.to_json(),
      draft.goal_id.to_json(),
      part.part_id.to_json(),
      source_revision_digest.to_json(),
      instruction.digest.to_json(),
      snapshot.base_commit_oid.to_json(),
      snapshot.base_tree_oid.to_json(),
      mutation_declaration.to_json(),
      verification_spec_digest.to_json(),
      process_artifact.digest.to_json(),
      audit_policy_digest.to_json(),
      part.migration_contract_ref.to_json(),
      implementation_profile_digest.to_json(),
      verification_profile_digest.to_json(),
      audit_profile_digest.to_json(),
    ].to_json(),
  )
  let contract : @control.TaskContractRevision = {
    id: revision_id,
    goal_id: draft.goal_id,
    part_id: part.part_id,
    revision: 1,
    digest: contract_digest,
    repair_conflict_id: None,
    instruction_artifact: instruction,
    base_commit_oid: snapshot.base_commit_oid,
    base_tree_oid: snapshot.base_tree_oid,
    path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
    mutation_declaration,
    verification_specs: [
      {
        id: verification_spec_id,
        version: 1,
        digest: verification_spec_digest,
        process_spec_digest: process_artifact.digest,
      },
    ],
    audit_policy_digest,
    migration_contract_ref: part.migration_contract_ref,
    migration_continuation_ref_digest: part.migration_continuation_ref_digest,
    implementation_capability_profile_digest: implementation_profile_digest,
    verification_capability_profile_digest: verification_profile_digest,
    audit_capability_profile_digest: audit_profile_digest,
  }
  let part_context_manifest : @migration.PartContextManifest? = match
    (part.migration_contract_ref, part.migration_context) {
    (None, None) => None
    (Some(reference), Some(context)) =>
      Some({
        migration_contract_ref: reference,
        part_task_contract_revision_id: contract.id,
        part_task_contract_digest: contract.digest,
        context_assembly_policy_digest: context.context_assembly_policy_digest,
        rulebook_section_digests: context.rulebook_section_digests,
        dependency_neighborhood_digest: context.dependency_neighborhood_digest,
        applicable_gap_entry_digests: context.applicable_gap_entry_digests,
        source_path_manifest_digest: context.source_path_manifest_digest,
        prior_take_context_digest: context.prior_take_context_digest,
      })
    _ =>
      return Err(
        native_goal_submission_error("migration context binding is incomplete"),
      )
  }
  Ok({
    part_id: part.part_id,
    source_revision_digest,
    source_content_digest,
    dependency_ids,
    task_contract: contract,
    provider_surface: part.provider_surface,
    part_context_manifest,
  })
}

///|
fn native_goal_submission_persisted(
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
fn native_goal_identity_conflict(
  goal_id : @control.GoalId,
  proposal_id : @workflow.GoalProposalId,
) -> @types.ChoirError {
  native_goal_submission_error(
    "Goal ID `" +
    goal_id.0 +
    "` is already durably registered by proposal `" +
    proposal_id.0 +
    "`. This identity conflict is permanent: do not retry goal_submit in this user turn and do not infer a transient Part lock. Inspect the existing Goal with goal_status.",
  )
}

///|
fn native_goal_submission_take(
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
fn native_goal_submission_sandbox(
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
fn native_goal_submission_session(
  id : String,
  take : @control.Take,
  sandbox : @control.SandboxLease,
  surface : @control.ProviderSurfaceId,
) -> @control.HarnessSession {
  let assurance = !(take.purpose is @control.TakePurpose::Implementation(_, _))
  let surface_digest = match surface {
    @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
      @harness.expected_claude_take_surface_manifest_digest(
        if assurance {
          @sandbox.boxlite_assurance_mcp_tools()
        } else {
          @sandbox.boxlite_take_mcp_tools()
        },
        "choir_sandbox",
      )
    @control.ProviderSurfaceId::CodexSubscriptionCli =>
      @harness.codex_effective_surface_manifest_digest(
        if assurance {
          @sandbox.boxlite_assurance_codex_mcp_tools()
        } else {
          @sandbox.boxlite_take_codex_mcp_tools()
        },
        "choir_sandbox",
      )
  }
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
fn native_goal_submission_part_snapshot(
  goal : @control.Goal,
  accepted : @workflow.AcceptedGoalPart,
) -> Result[@workflow.PartWorkflowSnapshot, @types.ChoirError] {
  let part = accepted.part
  let contract = accepted.task_contract
  let workflow_id = native_goal_part_workflow_id(goal.id, part.id)
  let key = native_goal_submission_resource_key(goal.id, part.id)
  let implementation = native_goal_submission_take(
    "take-" + key + "-implementation-1",
    goal.id,
    @control.TakePurpose::Implementation(part.id, contract.id),
  )
  let verification_spec = contract.verification_specs[0]
  let verification = native_goal_submission_take(
    "take-" + key + "-verification-1",
    goal.id,
    @control.TakePurpose::PartVerification(
      part.id,
      implementation.id,
      verification_spec.digest,
    ),
  )
  let audit = native_goal_submission_take(
    "take-" + key + "-audit-1",
    goal.id,
    @control.TakePurpose::PartAudit(
      part.id,
      implementation.id,
      contract.audit_policy_digest,
    ),
  )
  let implementation_sandbox = native_goal_submission_sandbox(
    "sandbox-" + key + "-implementation-1",
    "generation-" + key + "-implementation-1",
    implementation,
    contract.implementation_capability_profile_digest,
  )
  let verification_sandbox = native_goal_submission_sandbox(
    "sandbox-" + key + "-verification-1",
    "generation-" + key + "-verification-1",
    verification,
    contract.verification_capability_profile_digest,
  )
  let audit_sandbox = native_goal_submission_sandbox(
    "sandbox-" + key + "-audit-1",
    "generation-" + key + "-audit-1",
    audit,
    contract.audit_capability_profile_digest,
  )
  @workflow.initialize_part_workflow(
    workflow_id,
    goal,
    part,
    contract,
    {
      implementation_take: implementation,
      implementation_sandbox,
      implementation_session: native_goal_submission_session(
        "session-" + key + "-implementation-1",
        implementation,
        implementation_sandbox,
        accepted.provider_surface,
      ),
      verification_take: verification,
      verification_sandbox,
      verification_session: native_goal_submission_session(
        "session-" + key + "-verification-1",
        verification,
        verification_sandbox,
        accepted.provider_surface,
      ),
      audit_take: audit,
      audit_sandbox,
      audit_session: native_goal_submission_session(
        "session-" + key + "-audit-1",
        audit,
        audit_sandbox,
        accepted.provider_surface,
      ),
    },
    @control.FencingEpoch(1L),
    native_path_is_nfc,
    part_context_manifest=accepted.part_context_manifest,
  )
}

///|
pub fn native_goal_part_workflow_id(
  goal_id : @control.GoalId,
  part_id : @control.PartId,
) -> String {
  "goal-part-" +
  @storage.digest_text(
    native_goal_submission_digest(
      "choir.goal-part-workflow.v1",
      [goal_id.to_json(), part_id.to_json()].to_json(),
    ),
  )
}

///|
fn native_goal_part_plan_matches(
  stored : @workflow.PartWorkflowSnapshot,
  expected : @workflow.PartWorkflowSnapshot,
) -> Bool {
  stored.workflow_id == expected.workflow_id &&
  stored.goal.id == expected.goal.id &&
  stored.goal.contract_digest == expected.goal.contract_digest &&
  stored.part.id == expected.part.id &&
  stored.part.goal_id == expected.part.goal_id &&
  stored.part.dependency_ids == expected.part.dependency_ids &&
  stored.part.task_contract_revision_id ==
  expected.part.task_contract_revision_id &&
  stored.task_contract == expected.task_contract &&
  stored.part_context_manifest == expected.part_context_manifest &&
  stored.identities == expected.identities
}

///|
fn initialize_native_goal_parts(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  decision : @workflow.GoalSelectionDecision,
) -> Result[Int, @types.ChoirError] {
  if decision.outcome != @workflow.GoalSelectionOutcome::GoalSelectionAccepted {
    return Ok(0)
  }
  let goal = match decision.goal {
    Some(value) => value
    None => return Err(native_goal_submission_error("accepted Goal is absent"))
  }
  let mut initialized = 0
  for accepted in decision.accepted_parts {
    let snapshot = match native_goal_submission_part_snapshot(goal, accepted) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match
      @workflow.load_part_snapshot(repository, adapters, snapshot.workflow_id) {
      Ok(Some(stored)) =>
        if !native_goal_part_plan_matches(stored.snapshot, snapshot) {
          return Err(
            native_goal_submission_error(
              "existing Part initialization disagrees with selection",
            ),
          )
        }
      Ok(None) => {
        let receipt = match
          @workflow.persist_part_snapshot(repository, adapters, {
            snapshot,
            expected_store_version: None,
            fault_point: None,
          }) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if !native_goal_submission_persisted(receipt.transaction_outcome) {
          return Err(
            native_goal_submission_error("Part initialization conflicted"),
          )
        }
      }
      Err(error) => return Err(error)
    }
    initialized = initialized + 1
  }
  Ok(initialized)
}

///|
fn native_goal_execution_plan_matches(
  stored : @workflow.GoalExecutionRecord,
  expected : @workflow.GoalExecutionRecord,
) -> Bool {
  stored.goal.id == expected.goal.id &&
  stored.goal.contract_digest == expected.goal.contract_digest &&
  stored.repository_id == expected.repository_id &&
  stored.selection_decision_digest == expected.selection_decision_digest &&
  stored.base_ref == expected.base_ref &&
  stored.base_commit_oid == expected.base_commit_oid &&
  stored.base_tree_oid == expected.base_tree_oid &&
  stored.integration_target_ref == expected.integration_target_ref &&
  stored.migration_production_admission ==
  expected.migration_production_admission &&
  stored.goal_ref == expected.goal_ref &&
  stored.source_claims == expected.source_claims &&
  stored.maximum_parallel_parts == expected.maximum_parallel_parts &&
  stored.part_workflow_ids == expected.part_workflow_ids
}

///|
fn ensure_native_goal_execution(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  decision : @workflow.GoalSelectionDecision,
  decision_digest : @control.Digest,
) -> Result[Bool, @types.ChoirError] {
  if decision.outcome != @workflow.GoalSelectionOutcome::GoalSelectionAccepted {
    return Ok(false)
  }
  let workflow_ids = decision.accepted_parts.map(fn(accepted) {
    native_goal_part_workflow_id(decision.proposal.goal_id, accepted.part.id)
  })
  let expected = match
    @workflow.goal_execution_record_from_selection(
      decision, decision_digest, workflow_ids,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    @workflow.load_goal_execution_record(
      repository,
      adapters,
      decision.proposal.goal_id,
    ) {
    Ok(Some(stored)) =>
      if native_goal_execution_plan_matches(stored.record, expected) {
        Ok(true)
      } else {
        Err(
          native_goal_submission_error(
            "existing runnable Goal disagrees with selection",
          ),
        )
      }
    Ok(None) => {
      let receipt = match
        @workflow.persist_goal_execution_record(repository, adapters, {
          record: expected,
          expected_store_version: None,
          fault_point: None,
        }) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if native_goal_submission_persisted(receipt.transaction_outcome) {
        Ok(true)
      } else {
        Err(native_goal_submission_error("runnable Goal conflicted"))
      }
    }
    Err(error) => Err(error)
  }
}

///|
pub async fn submit_native_conductor_goal_draft(
  project_dir : String,
  draft_json : String,
  capture : async (Command) -> (Int, String),
  migration_production_admission? : @migration.MigrationProductionAdmissionRef? = None,
) -> Result[NativeConductorGoalSubmissionReport, @types.ChoirError] {
  if exec_path_nfc_available_ffi() != 1 {
    return Err(
      native_goal_submission_error(
        "Unicode NFC validation support is unavailable",
      ),
    )
  }
  let draft = match @workflow.decode_conductor_goal_draft(draft_json) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let state_root = project_dir + "/.choir/state/control"
  if !@sys.create_dir_all(state_root) {
    return Err(
      native_goal_submission_error("control state root is unavailable"),
    )
  }
  let repository : @workflow.PartWorkflowRepository = {
    state_store: { path: state_root + "/workflow.db" },
    artifact_store: { root: state_root + "/artifacts" },
    max_snapshot_bytes: 4 * 1024 * 1024,
  }
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    @workflow.load_goal_selection_decision(repository, adapters, draft.goal_id) {
    Ok(Some(stored)) =>
      if stored.decision.proposal.id != draft.proposal_id {
        return Err(
          native_goal_identity_conflict(
            draft.goal_id,
            stored.decision.proposal.id,
          ),
        )
      }
    Ok(None) => ()
    Err(error) => return Err(error)
  }
  let branch_ref = match capture_native_goal_branch_ref(project_dir, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let snapshot = match
    capture_native_goal_selection_snapshot(
      draft, branch_ref, project_dir, capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let snapshot_bytes = @workflow.goal_selection_snapshot_bytes(snapshot)
  let snapshot_artifact = match
    native_goal_submission_adopt(
      repository,
      snapshot_bytes,
      @storage.ArtifactProvenance::ArtifactGoalSelectionSnapshot(draft.goal_id),
      @storage.ArtifactRetention::ArtifactPermanent,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if snapshot_artifact.digest !=
    @workflow.goal_selection_snapshot_digest(snapshot) {
    return Err(
      native_goal_submission_error("selection snapshot digest drifted"),
    )
  }
  let parts : Array[@workflow.ConductorPartProposal] = []
  for part in draft.parts {
    match
      compile_native_conductor_part_proposal(repository, draft, part, snapshot) {
      Ok(value) => parts.push(value)
      Err(error) => return Err(error)
    }
  }
  let proposal : @workflow.GoalProposal = {
    id: draft.proposal_id,
    goal_id: draft.goal_id,
    repository_id: snapshot.repository_id,
    base_ref: branch_ref,
    expected_base_commit_oid: snapshot.base_commit_oid,
    expected_base_tree_oid: snapshot.base_tree_oid,
    integration_target_ref: branch_ref,
    selection_policy: @workflow.GoalSelectionPolicy::ExactClosure,
    completion_mode: draft.completion_mode,
    migration_production_admission,
    maximum_parallel_parts: draft.maximum_parallel_parts,
    parts,
  }
  let decision = match
    @workflow.evaluate_goal_proposal(proposal, snapshot, native_path_is_nfc) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let persistence = match
    @workflow.persist_goal_selection_decision(repository, adapters, {
      decision,
      fault_point: None,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !native_goal_submission_persisted(persistence.transaction_outcome) {
    match
      @workflow.load_goal_selection_decision(
        repository,
        adapters,
        draft.goal_id,
      ) {
      Ok(Some(stored)) =>
        if stored.decision.proposal.id != draft.proposal_id {
          return Err(
            native_goal_identity_conflict(
              draft.goal_id,
              stored.decision.proposal.id,
            ),
          )
        } else {
          return Err(
            native_goal_submission_error(
              "the replayed proposal disagrees with its durable selection; this is permanent and must not be retried in this user turn",
            ),
          )
        }
      Ok(None) =>
        return Err(
          native_goal_submission_error(
            "selection persistence conflicted without an observable durable owner; do not retry automatically in this user turn",
          ),
        )
      Err(error) => return Err(error)
    }
  }
  let loaded = match
    @workflow.load_goal_selection_decision(repository, adapters, draft.goal_id) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_goal_submission_error("selection was not durable"))
    Err(error) => return Err(error)
  }
  if loaded.decision != decision ||
    loaded.state_record.value_digest != persistence.decision_digest {
    return Err(native_goal_submission_error("selection reload disagrees"))
  }
  let initialized_part_count = match
    initialize_native_goal_parts(repository, adapters, decision) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let execution_registered = match
    ensure_native_goal_execution(
      repository,
      adapters,
      decision,
      persistence.decision_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    accepted: decision.outcome ==
    @workflow.GoalSelectionOutcome::GoalSelectionAccepted,
    goal_id: draft.goal_id,
    proposal_digest: decision.proposal_digest,
    selection_decision_digest: persistence.decision_digest,
    source_snapshot_digest: decision.source_snapshot_digest,
    accepted_part_ids: decision.accepted_parts.map(fn(part) { part.part.id }),
    initialized_part_count,
    execution_registered,
    rejections: decision.rejections,
    replayed: persistence.transaction_outcome ==
    @storage.StateTransactionOutcome::StateTransactionReplayed,
  })
}

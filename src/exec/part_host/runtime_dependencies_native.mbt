///|
fn native_part_effect_uses_serial_boxlite_cli(
  kind : @workflow.PartEffectKind,
) -> Bool {
  kind is @workflow.PartEffectKind::PrepareImplementationSandbox(_) ||
  kind is @workflow.PartEffectKind::PrepareVerificationSandbox(_) ||
  kind is @workflow.PartEffectKind::PrepareAuditSandbox(_) ||
  kind is @workflow.PartEffectKind::DispatchVerification(_, _) ||
  kind is @workflow.PartEffectKind::DispatchAudit(_, _, _)
}

///|
fn serialized_native_part_boxlite_effects(
  effects : @workflow.PartWorkflowDriverAdapters,
  lock : Ref[Bool],
) -> @workflow.PartWorkflowDriverAdapters {
  {
    execute: async fn(snapshot, intent) {
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

///|
pub fn native_part_artifact_exists(
  repository : @workflow.PartWorkflowRepository,
  reference : @control.ArtifactReference,
) -> Bool {
  match
    (@storage_host.local_part_workflow_repository_adapters().artifacts.contains)(
      repository.artifact_store,
      reference.digest,
    ) {
    Ok(value) => value
    Err(_) => false
  }
}

///|
pub fn native_part_runtime_dependencies(
  repository : @workflow.PartWorkflowRepository,
  runtime : NativePartEffectRuntime,
  clock : Ref[Int64],
  surface : @control.ProviderSurfaceId,
  sandbox_prepare_lock : Ref[Bool],
  admission : @workflow.PartIntegrationAdmission,
) -> @workflow.PartWorkflowDriverDependencies {
  let now = fn() {
    clock.val = clock.val + 1L
    clock.val
  }
  let effects = serialized_native_part_boxlite_effects(
    native_part_effect_adapters(runtime),
    sandbox_prepare_lock,
  )
  {
    now,
    persistence_fault: fn(_) { None },
    effects: @workflow.witnessed_part_effect_adapters(
      repository,
      @storage_host.local_part_workflow_repository_adapters(),
      effects,
      now,
    ),
    artifact_exists: fn(reference) {
      native_part_artifact_exists(repository, reference)
    },
    artifact_digest_exists: fn(digest) {
      native_part_artifact_exists(repository, { artifact_id: "digest", digest })
    },
    is_nfc: @process_host.native_path_is_nfc,
    audit_receipt_metadata: fn(snapshot) {
      let model_identity = match surface {
        @control.ProviderSurfaceId::ClaudeSubscriptionCli =>
          @control.ModelIdentity::ReportedModelIdentity(
            "claude-subscription-runtime",
          )
        @control.ProviderSurfaceId::CodexSubscriptionCli =>
          @control.ModelIdentity::UnreportedModelIdentity
      }
      Ok({
        receipt_id: @control.ReceiptId(
          "audit-receipt-" + snapshot.audit_take.id.0,
        ),
        provider_surface_id: surface,
        provider_identity: @harness.provider_receipt_identity(surface),
        model_identity,
      })
    },
    goal_authorizes_new_effects: fn() {
      Ok(@workflow.PartGoalAuthorization::PartGoalAuthorized(None))
    },
    integration_admission: fn(_) { Ok(admission) },
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
pub fn native_part_runtime_config_for_paths(
  repository : @workflow.PartWorkflowRepository,
  server : @take_host.NativeBoxLiteServerHandle,
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
    repository_adapters: @storage_host.local_part_workflow_repository_adapters(),
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

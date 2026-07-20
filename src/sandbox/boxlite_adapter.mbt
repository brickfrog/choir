///|
pub(all) struct SandboxResourceKey(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct PreparedEnvironmentKey(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct RuntimeExecutionKey(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct TransferId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct SandboxRegisteredToolId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) struct SandboxEffectCapability {
  goal_id : @control.GoalId
  take_id : @control.TakeId
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxSecurityPolicy {
  SandboxSecurityRequired
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BoxLiteSandboxPolicy {
  policy_digest : @control.Digest
  image_digest : @control.Digest
  security : SandboxSecurityPolicy
  network : SandboxNetworkProfile
  cpus : Int
  memory_mib : Int
  disk_size_gib : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxWorkingDirectory {
  SandboxWorkspaceRoot
  SandboxWorkspaceSubdirectory(@control.RepoPath)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxInterpreter {
  SandboxPosixShell
  SandboxPython3
  SandboxNode
  SandboxMoon
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxScriptArtifactProvenance {
  SandboxGoalContractArtifact
  SandboxBaseTreeBlob(@control.GitOid, @control.RepoPath, @control.GitOid)
  SandboxTakeArtifact(
    @control.TakeId,
    @control.ArtifactReference,
    @control.Digest
  )
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxExecutable {
  SandboxRegisteredTool(SandboxRegisteredToolId, @control.Digest)
  SandboxInterpreterArtifact(
    SandboxInterpreter,
    @control.ArtifactReference,
    @control.RepoPath,
    SandboxScriptArtifactProvenance
  )
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxEnvironmentEntry {
  key : String
  value : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxProcessAuthority {
  SandboxImplementationTool(@control.TakeId, @control.Digest)
  SandboxVerificationTool(@control.TakeId, @control.Digest, @control.Digest)
  SandboxAuditTool(@control.TakeId, @control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxStdinPolicy {
  SandboxStdinClosed
  SandboxStdinEmpty
  SandboxStdinArtifact(@control.ArtifactReference)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxProcessResourceLimits {
  cpu_millis : Int64
  memory_bytes : Int64
  process_count : Int
  file_bytes : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxNetworkProfileRef {
  profile : SandboxNetworkProfile
  version : Int64
  policy_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxOutputLimitDisposition {
  SandboxTerminateAndMarkExceeded
  SandboxTruncateAndMarkIncomplete
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxOutputPolicy {
  stdout_limit_bytes : Int64
  stderr_limit_bytes : Int64
  on_limit : SandboxOutputLimitDisposition
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxProcessSpec {
  authority : SandboxProcessAuthority
  executable : SandboxExecutable
  arguments : Array[String]
  working_directory : SandboxWorkingDirectory
  environment : Array[SandboxEnvironmentEntry]
  stdin : SandboxStdinPolicy
  timeout_ms : Int64
  resources : SandboxProcessResourceLimits
  network : SandboxNetworkProfileRef
  output : SandboxOutputPolicy
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxTransferDirection {
  SandboxCopyIn
  SandboxCopyOut
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxLogicalRoot {
  SandboxWorkspaceTransferRoot
  SandboxArtifactTransferRoot
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxTransferRequest {
  capability : SandboxEffectCapability
  transfer_id : TransferId
  resource_key : SandboxResourceKey
  direction : SandboxTransferDirection
  logical_root : SandboxLogicalRoot
  manifest : ValidatedTransferManifest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PrepareEnvironmentRequest {
  capability : SandboxEffectCapability
  prepared_environment_key : PreparedEnvironmentKey
  policy : BoxLiteSandboxPolicy
  tool_manifest_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CreateSandboxRequest {
  capability : SandboxEffectCapability
  resource_key : SandboxResourceKey
  prepared_environment_key : PreparedEnvironmentKey
  policy : BoxLiteSandboxPolicy
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct CloneSandboxRequest {
  capability : SandboxEffectCapability
  resource_key : SandboxResourceKey
  prepared_environment_key : PreparedEnvironmentKey
  policy : BoxLiteSandboxPolicy
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ExecuteSandboxRequest {
  capability : SandboxEffectCapability
  resource_key : SandboxResourceKey
  execution_key : RuntimeExecutionKey
  process : SandboxProcessSpec
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxDesiredProcessState {
  SandboxProcessInterrupt
  SandboxProcessTerminate
  SandboxProcessKill
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxProcessControlRequest {
  capability : SandboxEffectCapability
  resource_key : SandboxResourceKey
  execution_key : RuntimeExecutionKey
  desired_state : SandboxDesiredProcessState
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxResourceRequest {
  capability : SandboxEffectCapability
  resource_key : SandboxResourceKey
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum SandboxResourceLifecycle {
  SandboxResourcePrepared
  SandboxResourceCreated
  SandboxResourceRunning
  SandboxResourceStopped
  SandboxResourceDestroyed
  SandboxResourceUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PreparedEnvironmentObservation {
  prepared_environment_key : PreparedEnvironmentKey
  image_digest : @control.Digest
  policy_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxResourceObservation {
  resource_key : SandboxResourceKey
  runtime_id : String
  lifecycle : SandboxResourceLifecycle
  generation_digest : @control.Digest
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxExecutionObservation {
  execution_key : RuntimeExecutionKey
  runtime_execution_id : String
  lifecycle : SandboxResourceLifecycle
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxProcessEventCursor(Int64) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum SandboxProcessEventKind {
  SandboxProcessStdout(@control.ArtifactReference)
  SandboxProcessStderr(@control.ArtifactReference)
  SandboxProcessExited(Int)
  SandboxProcessOutputLimitExceeded
  SandboxProcessLost
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxProcessEvent {
  cursor : SandboxProcessEventCursor
  execution_key : RuntimeExecutionKey
  kind : SandboxProcessEventKind
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct AttachSandboxRequest {
  capability : SandboxEffectCapability
  resource_key : SandboxResourceKey
  execution_key : RuntimeExecutionKey
  after : SandboxProcessEventCursor?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct SandboxTransferObservation {
  transfer_id : TransferId
  manifest_digest : @control.Digest
  bytes_transferred : Int64
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BoxLiteSandboxAdapter {
  prepare : (PrepareEnvironmentRequest) -> Result[
    PreparedEnvironmentObservation,
    @types.ChoirError,
  ]
  create : (CreateSandboxRequest) -> Result[
    SandboxResourceObservation,
    @types.ChoirError,
  ]
  clone : (CloneSandboxRequest) -> Result[
    SandboxResourceObservation,
    @types.ChoirError,
  ]
  execute : (ExecuteSandboxRequest) -> Result[
    SandboxExecutionObservation,
    @types.ChoirError,
  ]
  attach : (AttachSandboxRequest) -> Result[
    Array[SandboxProcessEvent],
    @types.ChoirError,
  ]
  copy : (SandboxTransferRequest) -> Result[
    SandboxTransferObservation,
    @types.ChoirError,
  ]
  signal_or_kill : (SandboxProcessControlRequest) -> Result[
    SandboxExecutionObservation,
    @types.ChoirError,
  ]
  inspect : (SandboxResourceRequest) -> Result[
    SandboxResourceObservation,
    @types.ChoirError,
  ]
  destroy : (SandboxResourceRequest) -> Result[Unit, @types.ChoirError]
}

///|
fn valid_environment_key(key : String) -> Bool {
  if key == "" {
    return false
  }
  for index = 0; index < key.length(); index = index + 1 {
    let code = key[index].to_int()
    let valid = (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int() && index > 0) ||
      code == '_'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
fn forbidden_environment_key(key : String) -> Bool {
  key == "HOME" ||
  key == "PATH" ||
  key == "SHELL" ||
  key == "LD_PRELOAD" ||
  key == "LD_LIBRARY_PATH" ||
  key == "DYLD_INSERT_LIBRARIES" ||
  key.has_prefix("BOXLITE_") ||
  key.has_prefix("CHOIR_") ||
  key.has_prefix("GIT_")
}

///|
pub fn validate_boxlite_policy(
  policy : BoxLiteSandboxPolicy,
) -> Result[Unit, @types.ChoirError] {
  if policy.policy_digest.0 != boxlite_policy_digest ||
    policy.image_digest.0 != boxlite_probe_image_digest ||
    policy.cpus <= 0 ||
    policy.memory_mib < 128 ||
    policy.disk_size_gib <= 0 {
    return Err(
      @types.ChoirError::policy_blocked(
        "BoxLite request does not match the admitted pinned policy",
      ),
    )
  }
  validate_initial_network_profile(policy.network)
}

///|
pub fn validate_sandbox_effect_capability(
  capability : SandboxEffectCapability,
) -> Result[Unit, @types.ChoirError] {
  if capability.goal_id.0 == "" ||
    capability.take_id.0 == "" ||
    capability.fencing_epoch.0 <= 0L {
    return Err(
      @types.ChoirError::policy_blocked(
        "sandbox effect capability is incomplete or expired",
      ),
    )
  }
  Ok(())
}

///|
fn valid_logical_repo_path(path : @control.RepoPath) -> Bool {
  let text = path.0
  if text == "" || text.has_prefix("/") || text.contains("\\") {
    return false
  }
  for segment in text.split("/") {
    if segment == "" || segment == "." || segment == ".." {
      return false
    }
  }
  true
}

///|
fn process_authority_take_id(
  authority : SandboxProcessAuthority,
) -> @control.TakeId {
  match authority {
    SandboxImplementationTool(take_id, _) => take_id
    SandboxVerificationTool(take_id, _, _) => take_id
    SandboxAuditTool(take_id, _) => take_id
  }
}

///|
pub fn validate_sandbox_process_spec(
  process : SandboxProcessSpec,
  capability : SandboxEffectCapability,
  expected_policy_digest : @control.Digest,
  artifact_exists : (@control.ArtifactReference) -> Bool,
  registered_tool : (SandboxRegisteredToolId, @control.Digest) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  match validate_sandbox_effect_capability(capability) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if process_authority_take_id(process.authority) != capability.take_id {
    return Err(
      @types.ChoirError::policy_blocked(
        "sandbox process authority does not match the effect capability",
      ),
    )
  }
  match process.executable {
    SandboxRegisteredTool(tool_id, digest) =>
      if tool_id.0 == "" || digest.0 == "" || !registered_tool(tool_id, digest) {
        return Err(
          @types.ChoirError::policy_blocked(
            "sandbox tool is not present in the prepared tool registry",
          ),
        )
      }
    SandboxInterpreterArtifact(_, artifact, relative_path, provenance) => {
      let invalid_provenance = match provenance {
        SandboxGoalContractArtifact => false
        SandboxBaseTreeBlob(commit, path, blob) =>
          commit.0 == "" || blob.0 == "" || !valid_logical_repo_path(path)
        SandboxTakeArtifact(take_id, source, digest) =>
          take_id != capability.take_id ||
          !artifact_exists(source) ||
          source.digest != digest
      }
      if !artifact_exists(artifact) ||
        !valid_logical_repo_path(relative_path) ||
        invalid_provenance {
        return Err(
          @types.ChoirError::validation_error(
            "interpreter artifact provenance is invalid",
          ),
        )
      }
    }
  }
  match process.working_directory {
    SandboxWorkspaceRoot => ()
    SandboxWorkspaceSubdirectory(path) =>
      if !valid_logical_repo_path(path) {
        return Err(
          @types.ChoirError::validation_error(
            "sandbox working directory is outside the logical workspace",
          ),
        )
      }
  }
  match process.stdin {
    SandboxStdinClosed | SandboxStdinEmpty => ()
    SandboxStdinArtifact(artifact) =>
      if !artifact_exists(artifact) {
        return Err(
          @types.ChoirError::validation_error(
            "sandbox stdin artifact is unavailable",
          ),
        )
      }
  }
  if process.timeout_ms <= 0L ||
    process.resources.cpu_millis <= 0L ||
    process.resources.memory_bytes <= 0L ||
    process.resources.process_count <= 0 ||
    process.resources.file_bytes < 0L ||
    process.output.stdout_limit_bytes < 0L ||
    process.output.stderr_limit_bytes < 0L ||
    process.network.version <= 0L ||
    process.network.policy_digest != expected_policy_digest {
    return Err(
      @types.ChoirError::validation_error(
        "sandbox process limits or policy identity are invalid",
      ),
    )
  }
  match process.network.profile {
    NetworkDisabled => ()
    NetworkAllowlisted(_) =>
      return Err(
        @types.ChoirError::policy_blocked(
          "initial BoxLite process policy requires disabled networking",
        ),
      )
  }
  let seen : Map[String, Bool] = Map([])
  for entry in process.environment {
    if !valid_environment_key(entry.key) ||
      forbidden_environment_key(entry.key) ||
      seen.contains(entry.key) {
      return Err(
        @types.ChoirError::validation_error(
          "sandbox environment key is invalid or duplicated",
        ),
      )
    }
    seen[entry.key] = true
  }
  Ok(())
}

///|
fn validate_sandbox_resource_key(
  resource_key : SandboxResourceKey,
) -> Result[Unit, @types.ChoirError] {
  if resource_key.0 == "" {
    Err(@types.ChoirError::validation_error("sandbox resource key is empty"))
  } else {
    Ok(())
  }
}

///|
pub fn dispatch_boxlite_prepare(
  adapter : BoxLiteSandboxAdapter,
  request : PrepareEnvironmentRequest,
) -> Result[PreparedEnvironmentObservation, @types.ChoirError] {
  match validate_sandbox_effect_capability(request.capability) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_boxlite_policy(request.policy) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if request.prepared_environment_key.0 == "" ||
    request.tool_manifest_digest.0 == "" {
    return Err(
      @types.ChoirError::validation_error(
        "prepared environment identity is incomplete",
      ),
    )
  }
  (adapter.prepare)(request)
}

///|
pub fn dispatch_boxlite_create(
  adapter : BoxLiteSandboxAdapter,
  request : CreateSandboxRequest,
) -> Result[SandboxResourceObservation, @types.ChoirError] {
  match validate_sandbox_effect_capability(request.capability) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_sandbox_resource_key(request.resource_key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_boxlite_policy(request.policy) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if request.prepared_environment_key.0 == "" {
    return Err(
      @types.ChoirError::validation_error("prepared environment key is empty"),
    )
  }
  (adapter.create)(request)
}

///|
pub fn dispatch_boxlite_clone(
  adapter : BoxLiteSandboxAdapter,
  request : CloneSandboxRequest,
) -> Result[SandboxResourceObservation, @types.ChoirError] {
  match validate_sandbox_effect_capability(request.capability) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_sandbox_resource_key(request.resource_key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_boxlite_policy(request.policy) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if request.prepared_environment_key.0 == "" {
    return Err(
      @types.ChoirError::validation_error("prepared environment key is empty"),
    )
  }
  (adapter.clone)(request)
}

///|
pub fn dispatch_boxlite_execute(
  adapter : BoxLiteSandboxAdapter,
  request : ExecuteSandboxRequest,
  expected_policy_digest : @control.Digest,
  artifact_exists : (@control.ArtifactReference) -> Bool,
  registered_tool : (SandboxRegisteredToolId, @control.Digest) -> Bool,
) -> Result[SandboxExecutionObservation, @types.ChoirError] {
  match validate_sandbox_resource_key(request.resource_key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if request.execution_key.0 == "" {
    return Err(
      @types.ChoirError::validation_error("sandbox execution key is empty"),
    )
  }
  match
    validate_sandbox_process_spec(
      request.process,
      request.capability,
      expected_policy_digest,
      artifact_exists,
      registered_tool,
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  (adapter.execute)(request)
}

///|
pub fn dispatch_boxlite_copy(
  adapter : BoxLiteSandboxAdapter,
  request : SandboxTransferRequest,
) -> Result[SandboxTransferObservation, @types.ChoirError] {
  match validate_sandbox_effect_capability(request.capability) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_sandbox_resource_key(request.resource_key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if request.transfer_id.0 == "" {
    return Err(
      @types.ChoirError::validation_error("sandbox transfer id is empty"),
    )
  }
  (adapter.copy)(request)
}

///|
pub fn dispatch_boxlite_attach(
  adapter : BoxLiteSandboxAdapter,
  request : AttachSandboxRequest,
) -> Result[Array[SandboxProcessEvent], @types.ChoirError] {
  match validate_sandbox_effect_capability(request.capability) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_sandbox_resource_key(request.resource_key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if request.execution_key.0 == "" {
    return Err(
      @types.ChoirError::validation_error("sandbox execution key is empty"),
    )
  }
  (adapter.attach)(request)
}

///|
pub fn dispatch_boxlite_process_control(
  adapter : BoxLiteSandboxAdapter,
  request : SandboxProcessControlRequest,
) -> Result[SandboxExecutionObservation, @types.ChoirError] {
  match validate_sandbox_effect_capability(request.capability) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_sandbox_resource_key(request.resource_key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if request.execution_key.0 == "" {
    return Err(
      @types.ChoirError::validation_error("sandbox execution key is empty"),
    )
  }
  (adapter.signal_or_kill)(request)
}

///|
pub fn dispatch_boxlite_inspect(
  adapter : BoxLiteSandboxAdapter,
  request : SandboxResourceRequest,
) -> Result[SandboxResourceObservation, @types.ChoirError] {
  match validate_sandbox_effect_capability(request.capability) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_sandbox_resource_key(request.resource_key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  (adapter.inspect)(request)
}

///|
pub fn dispatch_boxlite_destroy(
  adapter : BoxLiteSandboxAdapter,
  request : SandboxResourceRequest,
) -> Result[Unit, @types.ChoirError] {
  match validate_sandbox_effect_capability(request.capability) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_sandbox_resource_key(request.resource_key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  (adapter.destroy)(request)
}

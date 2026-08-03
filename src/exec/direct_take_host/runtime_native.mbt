///|
pub(all) enum NativeDirectTakeVerificationOutcome {
  NativeDirectTakeVerificationPassed(@take_host.NativeSandboxProcessResult)
  NativeDirectTakeVerificationFailed(@take_host.NativeSandboxProcessResult)
  NativeDirectTakeVerificationInterrupted
  NativeDirectTakeVerificationTimedOut
  NativeDirectTakeVerificationOutputExceeded
} derive(Debug, Eq)

///|
pub(all) struct NativeDirectTakeProviderEvidence {
  surface : @control.ProviderSurfaceId
  surface_manifest_digest : @control.Digest
  response_digest : @control.Digest
  usage : @control.TakeUsage
  started_at : Int64
  finished_at : Int64
} derive(Debug, Eq)

///|
pub(all) struct NativeDirectTakeIsolatedResult {
  patch : NativeDirectTakePatch
  verification : NativeDirectTakeVerificationOutcome
  provider : NativeDirectTakeProviderEvidence
  image_digest : @control.Digest
  tool_manifest_digest : @control.Digest
  runtime_policy_digest : @control.Digest
  verification_process_spec_digest : @control.Digest
} derive(Debug, Eq)

///|
pub(all) struct NativeDirectTakeReport {
  snapshot : NativeDirectTakeSnapshot
  isolated : NativeDirectTakeIsolatedResult
  apply_requested : Bool
  applied : Bool
} derive(Debug, Eq)

///|
pub(all) struct NativeDirectTakeExecutionAdapters {
  capture_snapshot : async () -> Result[
    NativeDirectTakeSnapshot,
    @types.ChoirError,
  ]
  execute_isolated : async (
    NativeDirectTakeSnapshot,
    String,
    @workflow.DirectTakeVerificationPlan,
  ) -> Result[NativeDirectTakeIsolatedResult, @types.ChoirError]
  apply_patch : async (NativeDirectTakeSnapshot, NativeDirectTakePatch) -> Result[
    Unit,
    @types.ChoirError,
  ]
  is_nfc : (String) -> Bool
}

///|
fn native_direct_take_runtime_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("direct Take: " + detail)
}

///|
pub fn native_direct_take_verification_passed(
  outcome : NativeDirectTakeVerificationOutcome,
) -> Bool {
  outcome is NativeDirectTakeVerificationPassed(_)
}

///|
pub fn native_direct_take_report_succeeded(
  report : NativeDirectTakeReport,
) -> Bool {
  native_direct_take_verification_passed(report.isolated.verification) &&
  (
    !report.apply_requested ||
    report.applied ||
    report.isolated.patch.patch == ""
  )
}

///|
fn native_direct_take_runtime_key(
  snapshot : NativeDirectTakeSnapshot,
) -> String {
  snapshot.source_digest.0[:20].to_owned()
}

///|
fn native_direct_take_process_evidence_is_valid(
  outcome : NativeDirectTakeVerificationOutcome,
) -> Bool {
  match outcome {
    NativeDirectTakeVerificationPassed(result)
    | NativeDirectTakeVerificationFailed(result) =>
      @utf8.encode(result.output).length() <= 2097152 &&
      result.output_digest ==
      @storage.artifact_digest(@utf8.encode(result.output))
    NativeDirectTakeVerificationInterrupted
    | NativeDirectTakeVerificationTimedOut
    | NativeDirectTakeVerificationOutputExceeded => true
  }
}

///|
pub async fn run_native_direct_take_with(
  command : @command.DirectTakeCommand,
  adapters : NativeDirectTakeExecutionAdapters,
) -> Result[NativeDirectTakeReport, @types.ChoirError] {
  let snapshot = match (adapters.capture_snapshot)() {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let instruction = match @workflow.render_direct_take_instruction(command) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let verification_plan = match
    @workflow.plan_direct_take_verification(
      command,
      native_direct_take_runtime_key(snapshot),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let isolated = match
    (adapters.execute_isolated)(snapshot, instruction, verification_plan) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let patch_bytes = @utf8.encode(isolated.patch.patch)
  let patch_is_empty = isolated.patch.patch == ""
  if isolated.provider.surface != command.surface ||
    !@control.Digest::is_valid(snapshot.source_digest) ||
    !@git_integration.valid_hex_oid_text(snapshot.commit_oid.0) ||
    !@git_integration.valid_hex_oid_text(snapshot.tree_oid.0) ||
    !@git_integration.valid_hex_oid_text(
      isolated.patch.candidate.candidate_tree_oid.0,
    ) ||
    !@control.Digest::is_valid(isolated.provider.surface_manifest_digest) ||
    !@control.Digest::is_valid(isolated.provider.response_digest) ||
    !@control.Digest::is_valid(isolated.image_digest) ||
    !@control.Digest::is_valid(isolated.tool_manifest_digest) ||
    !@control.Digest::is_valid(isolated.runtime_policy_digest) ||
    !@control.validate_take_usage(isolated.provider.usage) ||
    isolated.provider.started_at <= 0L ||
    isolated.provider.finished_at < isolated.provider.started_at ||
    !native_direct_take_process_evidence_is_valid(isolated.verification) ||
    isolated.verification_process_spec_digest !=
    verification_plan.process_spec_digest ||
    isolated.patch.candidate.base_commit_oid != snapshot.commit_oid ||
    isolated.patch.candidate.base_tree_oid != snapshot.tree_oid ||
    patch_bytes.length() > 1048576 ||
    isolated.patch.patch_digest != @storage.artifact_digest(patch_bytes) ||
    patch_is_empty != (isolated.patch.candidate.changed_paths.length() == 0) ||
    patch_is_empty !=
    (
      isolated.patch.candidate.candidate_tree_oid ==
      isolated.patch.candidate.base_tree_oid
    ) {
    return Err(native_direct_take_runtime_error("evidence identity is invalid"))
  }
  match
    @workflow.validate_direct_take_candidate(
      command,
      isolated.patch.candidate,
      adapters.is_nfc,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let mut applied = false
  if command.apply &&
    isolated.patch.patch != "" &&
    native_direct_take_verification_passed(isolated.verification) {
    match (adapters.apply_patch)(snapshot, isolated.patch) {
      Ok(_) => applied = true
      Err(error) => return Err(error)
    }
  }
  Ok({ snapshot, isolated, apply_requested: command.apply, applied })
}

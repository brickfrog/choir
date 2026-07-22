///|
fn process_fixture() -> @sandbox.ProcessExecution {
  {
    execution_id: @sandbox.ProcessExecutionId("effect-1.process"),
    effect_intent_id: "effect-1",
    runtime_execution_key: @sandbox.RuntimeExecutionKey("effect-1.process"),
    take_id: @control.TakeId("take-1"),
    process_authority: @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
      @control.TakeId("take-1"),
      @control.VerificationSpecId("spec-1"),
      @control.Digest(
        "1111111111111111111111111111111111111111111111111111111111111111",
      ),
    ),
    validated_process_spec_digest: @control.Digest(
      "2222222222222222222222222222222222222222222222222222222222222222",
    ),
    sandbox_lease_id: @control.SandboxLeaseId("lease-1"),
    sandbox_generation_id: @control.SandboxGenerationId("generation-1"),
    capability_profile_digest: @control.Digest(
      "3333333333333333333333333333333333333333333333333333333333333333",
    ),
    input_artifact_set_digest: @control.Digest(
      "4444444444444444444444444444444444444444444444444444444444444444",
    ),
    output_artifact_set_digest: None,
    started_at: None,
    finished_at: None,
    disposition: @sandbox.ProcessExecutionDisposition::ProcessStartPlanned,
  }
}

///|
test "process start becomes terminal only from durable authorization" {
  let planned = process_fixture()
  let authorized = @sandbox.authorize_process_start(planned, 10L).unwrap()
  let output = @control.Digest(
    "5555555555555555555555555555555555555555555555555555555555555555",
  )
  let terminal = @sandbox.record_process_exit(authorized, 0, output, 11L).unwrap()
  assert_eq(
    terminal.disposition,
    @sandbox.ProcessExecutionDisposition::ProcessExited(0, output),
  )
  assert_eq(terminal.output_artifact_set_digest, Some(output))
  assert_true(@sandbox.record_process_exit(planned, 0, output, 11L) is Err(_))
}

///|
test "ambiguous unkeyed start becomes terminal uncertainty" {
  let authorized = @sandbox.authorize_process_start(process_fixture(), 10L).unwrap()
  let uncertain = @sandbox.record_unadoptable_process_start(authorized, 11L).unwrap()
  assert_eq(
    uncertain.disposition,
    @sandbox.ProcessExecutionDisposition::ProcessStartUncertain,
  )
  assert_true(@sandbox.authorize_process_start(uncertain, 12L) is Err(_))
}

///|
test "recovery never retries an ambiguous unkeyed process start" {
  let planned = process_fixture()
  assert_eq(
    @sandbox.recover_process_execution(planned, false).unwrap(),
    @sandbox.ProcessRecoveryAction::ProcessRetryExactStart,
  )
  let authorized = @sandbox.authorize_process_start(planned, 10L).unwrap()
  assert_eq(
    @sandbox.recover_process_execution(authorized, false).unwrap(),
    @sandbox.ProcessRecoveryAction::ProcessRetireSandboxGeneration(
      @control.SandboxGenerationId("generation-1"),
    ),
  )
  assert_eq(
    @sandbox.recover_process_execution(authorized, true).unwrap(),
    @sandbox.ProcessRecoveryAction::ProcessAdoptRuntimeKey(
      @sandbox.RuntimeExecutionKey("effect-1.process"),
    ),
  )
}

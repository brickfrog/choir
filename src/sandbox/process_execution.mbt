///|
pub(all) struct ProcessExecutionId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum ProcessExecutionDisposition {
  ProcessStartPlanned
  ProcessStartMayHaveOccurred
  ProcessExited(Int, @control.Digest)
  ProcessTimedOut
  ProcessLimitExceeded
  ProcessInterrupted
  ProcessSandboxLost
  ProcessStartUncertain
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ProcessRecoveryAction {
  ProcessRetryExactStart
  ProcessAdoptRuntimeKey(RuntimeExecutionKey)
  ProcessRetireSandboxGeneration(@control.SandboxGenerationId)
  ProcessUseTerminal(Int, @control.Digest)
  ProcessRecoveryBlocked
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ProcessExecution {
  execution_id : ProcessExecutionId
  effect_intent_id : String
  runtime_execution_key : RuntimeExecutionKey
  take_id : @control.TakeId
  process_authority : SandboxProcessAuthority
  validated_process_spec_digest : @control.Digest
  sandbox_lease_id : @control.SandboxLeaseId
  sandbox_generation_id : @control.SandboxGenerationId
  capability_profile_digest : @control.Digest
  input_artifact_set_digest : @control.Digest
  output_artifact_set_digest : @control.Digest?
  started_at : Int64?
  finished_at : Int64?
  disposition : ProcessExecutionDisposition
} derive(Debug, Eq, ToJson, FromJson)

///|
fn process_execution_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("process execution: " + message)
}

///|
fn valid_process_execution_token(value : String) -> Bool {
  if value == "" || value.length() > 220 {
    return false
  }
  for char in value {
    if !((char >= 'a' && char <= 'z') ||
      (char >= 'A' && char <= 'Z') ||
      (char >= '0' && char <= '9') ||
      char == '-' ||
      char == '_' ||
      char == ':' ||
      char == '.') {
      return false
    }
  }
  true
}

///|
pub fn validate_process_execution(
  execution : ProcessExecution,
) -> Result[Unit, @types.ChoirError] {
  if !valid_process_execution_token(execution.execution_id.0) ||
    !valid_process_execution_token(execution.effect_intent_id) ||
    execution.runtime_execution_key.0 == "" ||
    execution.take_id.0 == "" ||
    execution.sandbox_lease_id.0 == "" ||
    execution.sandbox_generation_id.0 == "" {
    return Err(process_execution_error("identity is invalid"))
  }
  for
    digest in [
      execution.validated_process_spec_digest,
      execution.capability_profile_digest,
      execution.input_artifact_set_digest,
    ] {
    match @storage.validate_digest(digest) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  match execution.output_artifact_set_digest {
    Some(digest) =>
      match @storage.validate_digest(digest) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    None => ()
  }
  match execution.disposition {
    ProcessStartPlanned =>
      if execution.started_at is Some(_) ||
        execution.finished_at is Some(_) ||
        execution.output_artifact_set_digest is Some(_) {
        return Err(process_execution_error("planned state has observations"))
      }
    ProcessStartMayHaveOccurred =>
      if execution.started_at is None ||
        execution.finished_at is Some(_) ||
        execution.output_artifact_set_digest is Some(_) {
        return Err(process_execution_error("authorized state is inconsistent"))
      }
    ProcessExited(_, output_digest) => {
      if execution.started_at is None ||
        execution.finished_at is None ||
        execution.output_artifact_set_digest != Some(output_digest) {
        return Err(process_execution_error("exit state is inconsistent"))
      }
      match @storage.validate_digest(output_digest) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
    ProcessTimedOut
    | ProcessLimitExceeded
    | ProcessInterrupted
    | ProcessSandboxLost
    | ProcessStartUncertain =>
      if execution.started_at is None || execution.finished_at is None {
        return Err(process_execution_error("terminal state lacks timestamps"))
      }
  }
  Ok(())
}

///|
pub fn authorize_process_start(
  execution : ProcessExecution,
  started_at : Int64,
) -> Result[ProcessExecution, @types.ChoirError] {
  match validate_process_execution(execution) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if execution.disposition != ProcessStartPlanned || started_at <= 0L {
    return Err(process_execution_error("cannot authorize from current state"))
  }
  Ok({
    ..execution,
    started_at: Some(started_at),
    disposition: ProcessStartMayHaveOccurred,
  })
}

///|
pub fn record_process_exit(
  execution : ProcessExecution,
  exit_code : Int,
  output_digest : @control.Digest,
  finished_at : Int64,
) -> Result[ProcessExecution, @types.ChoirError] {
  match validate_process_execution(execution) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if execution.disposition != ProcessStartMayHaveOccurred ||
    finished_at <= execution.started_at.unwrap_or(0L) {
    return Err(process_execution_error("cannot record exit from current state"))
  }
  match @storage.validate_digest(output_digest) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok({
    ..execution,
    output_artifact_set_digest: Some(output_digest),
    finished_at: Some(finished_at),
    disposition: ProcessExited(exit_code, output_digest),
  })
}

///|
pub fn record_unadoptable_process_start(
  execution : ProcessExecution,
  finished_at : Int64,
) -> Result[ProcessExecution, @types.ChoirError] {
  match validate_process_execution(execution) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if execution.disposition != ProcessStartMayHaveOccurred ||
    finished_at <= execution.started_at.unwrap_or(0L) {
    return Err(process_execution_error("cannot mark current state uncertain"))
  }
  Ok({
    ..execution,
    finished_at: Some(finished_at),
    disposition: ProcessStartUncertain,
  })
}

///|
pub fn recover_process_execution(
  execution : ProcessExecution,
  keyed_adoption_supported : Bool,
) -> Result[ProcessRecoveryAction, @types.ChoirError] {
  match validate_process_execution(execution) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok(
    match execution.disposition {
      ProcessStartPlanned => ProcessRetryExactStart
      ProcessStartMayHaveOccurred =>
        if keyed_adoption_supported {
          ProcessAdoptRuntimeKey(execution.runtime_execution_key)
        } else {
          ProcessRetireSandboxGeneration(execution.sandbox_generation_id)
        }
      ProcessExited(exit_code, output_digest) =>
        ProcessUseTerminal(exit_code, output_digest)
      ProcessTimedOut
      | ProcessLimitExceeded
      | ProcessInterrupted
      | ProcessSandboxLost
      | ProcessStartUncertain => ProcessRecoveryBlocked
    },
  )
}

///|
pub(all) enum NativeBoundedProcessOutcome {
  NativeProcessCompleted(Int, String)
  NativeProcessInterrupted(String)
  NativeProcessTimedOut(String)
  NativeProcessOutputExceeded(String)
} derive(Debug, Eq)

///|
priv enum NativeBoundedReadOutcome {
  NativeBoundedReadCompleted(String, String)
  NativeBoundedReadExceeded(String)
  NativeBoundedReadFailed
}

///|
priv enum NativeBoundedWaitOutcome {
  NativeBoundedWaitCompleted(Int)
  NativeBoundedWaitFailed
}

///|
priv enum NativeBoundedStopReason {
  NativeBoundedInterrupted
  NativeBoundedTimedOut
  NativeBoundedOutputExceeded
  NativeBoundedTransportFailure(@types.ChoirError)
}

///|
let native_process_diagnostic_tail_bytes : Int = 64 * 1024

///|
fn decode_native_process_bytes(bytes : BytesView) -> String {
  @terminal.strip_terminal_responses(@utf8.decode_lossy(bytes))
}

///|
fn native_process_diagnostic_tail(
  buffer : FixedArray[Byte],
  length : Int,
) -> String {
  let start = if length > native_process_diagnostic_tail_bytes {
    length - native_process_diagnostic_tail_bytes
  } else {
    0
  }
  decode_native_process_bytes(
    buffer.unsafe_reinterpret_as_bytes()[start:length],
  )
}

///|
async fn drain_native_bounded_process_output(
  reader : @process.ReadFromProcess,
  output_limit_bytes : Int,
  observed : Ref[NativeBoundedReadOutcome?],
) -> NativeBoundedReadOutcome {
  let buffer = FixedArray::make(output_limit_bytes, (0 : Byte))
  let mut total = 0
  while total < output_limit_bytes {
    let read = reader.read(
      buffer,
      offset=total,
      max_len=output_limit_bytes - total,
    ) catch {
      _ => {
        reader.close()
        let outcome = NativeBoundedReadFailed
        observed.val = Some(outcome)
        return outcome
      }
    }
    if read == 0 {
      reader.close()
      let output = decode_native_process_bytes(
        buffer.unsafe_reinterpret_as_bytes()[:total],
      )
      let tail = native_process_diagnostic_tail(buffer, total)
      let outcome = NativeBoundedReadCompleted(output, tail)
      observed.val = Some(outcome)
      return outcome
    }
    total = total + read
  }
  let probe = FixedArray::make(1, (0 : Byte))
  let extra = reader.read(probe, offset=0, max_len=1) catch {
    _ => {
      reader.close()
      let outcome = NativeBoundedReadFailed
      observed.val = Some(outcome)
      return outcome
    }
  }
  reader.close()
  if extra > 0 {
    let outcome = NativeBoundedReadExceeded(
      native_process_diagnostic_tail(buffer, total),
    )
    observed.val = Some(outcome)
    outcome
  } else {
    let output = decode_native_process_bytes(
      buffer.unsafe_reinterpret_as_bytes()[:total],
    )
    let tail = native_process_diagnostic_tail(buffer, total)
    let outcome = NativeBoundedReadCompleted(output, tail)
    observed.val = Some(outcome)
    outcome
  }
}

///|
async fn terminate_native_process_group(
  pgid : Int,
  terminate : (Int) -> Bool,
  force_kill : (Int) -> Bool,
  group_alive : (Int) -> Bool,
  sleep : async (Int) -> Unit,
) -> Result[Unit, @types.ChoirError] {
  let term_delivered = terminate(pgid)
  if term_delivered {
    let mut grace_ms = 0
    while group_alive(pgid) && grace_ms < 5000 {
      sleep(100)
      grace_ms = grace_ms + 100
    }
  }
  if group_alive(pgid) {
    let killed = force_kill(pgid)
    if !killed {
      return Err(
        @types.ChoirError::transport_error(
          "owned process group could not be force-killed",
        ),
      )
    }
  }
  if !term_delivered {
    return Err(
      @types.ChoirError::transport_error(
        "owned process group could not be terminated",
      ),
    )
  }
  Ok(())
}

///|
async fn terminate_native_process_group_default(
  pgid : Int,
) -> Result[Unit, @types.ChoirError] {
  terminate_native_process_group(
    pgid,
    @sys.terminate_pgid_checked,
    @sys.force_kill_pgid_checked,
    @sys.pgid_has_non_zombie_process,
    async fn(milliseconds) { @async.sleep(milliseconds) },
  )
}

///|
fn native_bounded_read_tail(outcome : NativeBoundedReadOutcome) -> String {
  match outcome {
    NativeBoundedReadCompleted(_, tail) => tail
    NativeBoundedReadExceeded(tail) => tail
    NativeBoundedReadFailed => ""
  }
}

///|
pub async fn capture_bounded_process(
  program : String,
  arguments : Array[String],
  environment : Map[String, String],
  stdin_read : &@process.ProcessInput,
  cwd : String,
  timeout_ms : Int,
  output_limit_bytes : Int,
  cancellation_requested : () -> Bool,
  started? : (Int) -> Result[Unit, @types.ChoirError] = fn(_) { Ok(()) },
) -> Result[NativeBoundedProcessOutcome, @types.ChoirError] {
  if !program.has_prefix("/") ||
    !cwd.has_prefix("/") ||
    timeout_ms < 1000 ||
    timeout_ms > 3600000 ||
    output_limit_bytes < 0 {
    return Err(
      @types.ChoirError::validation_error(
        "bounded process specification is invalid",
      ),
    )
  }
  abort_if_hermetic_test_exec(
    command_for_program(program, arguments, Some(cwd)),
  )
  let (reader, writer) = @process.read_from_process() catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error("bounded process output pipe failed"),
      )
  }
  let setsid_arguments : Array[String] = [program]
  for argument in arguments {
    setsid_arguments.push(argument)
  }
  let pid = @process.spawn_orphan(
    "/usr/bin/setsid",
    setsid_arguments,
    extra_env=environment,
    inherit_env=false,
    stdin=stdin_read,
    stdout=writer,
    stderr=writer,
    cwd~,
  ) catch {
    _ => {
      reader.close()
      return Err(
        @types.ChoirError::transport_error("bounded process failed to start"),
      )
    }
  }
  if pid <= 1 {
    reader.close()
    return Err(
      @types.ChoirError::transport_error(
        "bounded process returned an unsafe process id",
      ),
    )
  }
  match started(pid) {
    Ok(_) => ()
    Err(error) => {
      reader.close()
      let cleanup = terminate_native_process_group_default(pid)
      let reaped = @process.wait_pid(pid) catch { _ => -1 }
      match cleanup {
        Err(cleanup_error) => return Err(cleanup_error)
        Ok(_) => ()
      }
      if reaped < 0 || @sys.pgid_has_non_zombie_process(pid) {
        return Err(
          @types.ChoirError::transport_error(
            "bounded process could not be reaped after start rejection",
          ),
        )
      }
      return Err(error)
    }
  }
  @async.with_task_group(async fn(group) {
    let wait_observed : Ref[NativeBoundedWaitOutcome?] = @ref.new(None)
    let read_observed : Ref[NativeBoundedReadOutcome?] = @ref.new(None)
    let waiter = group.spawn(async fn() {
      let code = @process.wait_pid(pid) catch { _ => -1 }
      let outcome = if code < 0 {
        NativeBoundedWaitFailed
      } else {
        NativeBoundedWaitCompleted(code)
      }
      wait_observed.val = Some(outcome)
      outcome
    })
    let drainer = group.spawn(async fn() {
      drain_native_bounded_process_output(
        reader, output_limit_bytes, read_observed,
      )
    })
    let mut elapsed_ms = 0
    let mut stop_reason : NativeBoundedStopReason? = None
    while stop_reason is None {
      match read_observed.val {
        Some(NativeBoundedReadFailed) =>
          stop_reason = Some(
            NativeBoundedTransportFailure(
              @types.ChoirError::transport_error(
                "bounded process output read failed",
              ),
            ),
          )
        Some(NativeBoundedReadExceeded(_)) =>
          stop_reason = Some(NativeBoundedOutputExceeded)
        _ => ()
      }
      if stop_reason is None && cancellation_requested() {
        stop_reason = Some(NativeBoundedInterrupted)
      }
      if stop_reason is None && elapsed_ms >= timeout_ms {
        stop_reason = Some(NativeBoundedTimedOut)
      }
      if stop_reason is None {
        match (wait_observed.val, read_observed.val) {
          (
            Some(NativeBoundedWaitCompleted(_)),
            Some(NativeBoundedReadCompleted(_, _)),
          ) => break
          (Some(NativeBoundedWaitFailed), _) =>
            stop_reason = Some(
              NativeBoundedTransportFailure(
                @types.ChoirError::transport_error(
                  "bounded process wait failed",
                ),
              ),
            )
          _ => {
            @async.sleep(100)
            elapsed_ms = elapsed_ms + 100
          }
        }
      }
    }
    let cleanup = match stop_reason {
      Some(_) => Some(terminate_native_process_group_default(pid))
      None => None
    }
    let wait_outcome = waiter.wait()
    let read_outcome = drainer.wait()
    match cleanup {
      Some(Err(error)) => return Err(error)
      _ => ()
    }
    if wait_outcome is NativeBoundedWaitFailed {
      return Err(
        @types.ChoirError::transport_error("bounded process reap failed"),
      )
    }
    if read_outcome is NativeBoundedReadFailed {
      return Err(
        @types.ChoirError::transport_error("bounded process output read failed"),
      )
    }
    if stop_reason is Some(_) && @sys.pgid_has_non_zombie_process(pid) {
      return Err(
        @types.ChoirError::transport_error(
          "bounded process group survived cleanup",
        ),
      )
    }
    match stop_reason {
      Some(NativeBoundedInterrupted) =>
        Ok(NativeProcessInterrupted(native_bounded_read_tail(read_outcome)))
      Some(NativeBoundedTimedOut) =>
        Ok(NativeProcessTimedOut(native_bounded_read_tail(read_outcome)))
      Some(NativeBoundedOutputExceeded) =>
        Ok(NativeProcessOutputExceeded(native_bounded_read_tail(read_outcome)))
      Some(NativeBoundedTransportFailure(error)) => Err(error)
      None =>
        match (wait_outcome, read_outcome) {
          (
            NativeBoundedWaitCompleted(code),
            NativeBoundedReadCompleted(output, _),
          ) => Ok(NativeProcessCompleted(code, output))
          _ =>
            Err(
              @types.ChoirError::transport_error(
                "bounded process completed without a capture",
              ),
            )
        }
    }
  })
}

///|
async test "process-group cleanup gives a stubborn group five seconds before kill" {
  let events : Array[String] = []
  let alive = @ref.new(true)
  let slept = @ref.new(0)
  let result = terminate_native_process_group(
    42,
    fn(pid) {
      events.push("term:" + pid.to_string())
      true
    },
    fn(pid) {
      events.push("kill:" + pid.to_string())
      alive.val = false
      true
    },
    fn(_) { alive.val },
    async fn(milliseconds) {
      slept.val = slept.val + milliseconds
      @async.sleep(0)
    },
  )
  assert_true(result is Ok(_))
  assert_eq(slept.val, 5000)
  assert_eq(events, ["term:42", "kill:42"])
}

///|
async test "process-group cleanup skips kill after graceful termination" {
  let events : Array[String] = []
  let result = terminate_native_process_group(
    42,
    fn(pid) {
      events.push("term:" + pid.to_string())
      true
    },
    fn(pid) {
      events.push("kill:" + pid.to_string())
      true
    },
    fn(_) { false },
    async fn(_) { @async.sleep(0) },
  )
  assert_true(result is Ok(_))
  assert_eq(events, ["term:42"])
}

///|
async test "process-group cleanup reports TERM failure after forcing cleanup" {
  let events : Array[String] = []
  let alive = @ref.new(true)
  let result = terminate_native_process_group(
    42,
    fn(pid) {
      events.push("term:" + pid.to_string())
      false
    },
    fn(pid) {
      events.push("kill:" + pid.to_string())
      alive.val = false
      true
    },
    fn(_) { alive.val },
    async fn(_) { @async.sleep(0) },
  )
  assert_true(result is Err(_))
  assert_false(alive.val)
  assert_eq(events, ["term:42", "kill:42"])
}

///|
test "bounded process diagnostics retain only the final 64 KiB" {
  let length = native_process_diagnostic_tail_bytes + 5
  let buffer = FixedArray::make(length, (97 : Byte))
  for index = length - 5; index < length; index = index + 1 {
    buffer[index] = 122
  }
  let tail = native_process_diagnostic_tail(buffer, length)
  assert_eq(tail.length(), native_process_diagnostic_tail_bytes)
  assert_true(tail.has_suffix("zzzzz"))
}

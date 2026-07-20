///|
pub(all) enum NativeInterruptibleProcessOutcome {
  NativeProcessCompleted(Int, String)
  NativeProcessInterrupted(String)
  NativeProcessTimedOut(String)
} derive(Debug, Eq)

///|
pub async fn collect_interruptible_process(
  program : String,
  arguments : Array[String],
  environment : Map[String, String],
  stdin_read : &@process.ProcessInput,
  cwd : String,
  timeout_ms : Int,
  cancellation_requested : () -> Bool,
) -> Result[NativeInterruptibleProcessOutcome, @types.ChoirError] {
  if !program.has_prefix("/") ||
    !cwd.has_prefix("/") ||
    timeout_ms < 1000 ||
    timeout_ms > 3600000 {
    return Err(
      @types.ChoirError::validation_error(
        "interruptible provider process specification is invalid",
      ),
    )
  }
  let (reader, writer) = @process.read_from_process() catch {
    _ =>
      return Err(
        @types.ChoirError::transport_error(
          "interruptible provider output pipe failed",
        ),
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
        @types.ChoirError::transport_error(
          "interruptible provider process failed to start",
        ),
      )
    }
  }
  @async.with_task_group(async fn(group) {
    let exit_code : Ref[Int?] = @ref.new(None)
    let waiter = group.spawn(async fn() {
      let code = @process.wait_pid(pid) catch { _ => -1 }
      exit_code.val = Some(code)
      code
    })
    let drainer = group.spawn(async fn() {
      drain_process_stdout(reader, 16 * 1024 * 1024).0
    })
    let mut elapsed_ms = 0
    let mut interrupted = false
    let mut timed_out = false
    while exit_code.val is None {
      if cancellation_requested() {
        interrupted = true
        @sys.kill_pgid_sequence_best_effort(pid)
        break
      }
      if elapsed_ms >= timeout_ms {
        timed_out = true
        @sys.kill_pgid_sequence_best_effort(pid)
        break
      }
      @async.sleep(100)
      elapsed_ms = elapsed_ms + 100
    }
    let code = waiter.wait()
    let output = drainer.wait()
    if interrupted {
      Ok(NativeProcessInterrupted(output))
    } else if timed_out {
      Ok(NativeProcessTimedOut(output))
    } else {
      Ok(NativeProcessCompleted(code, output))
    }
  })
}

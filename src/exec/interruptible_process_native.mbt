///|
pub(all) enum NativeInterruptibleProcessOutcome {
  NativeProcessCompleted(Int, String)
  NativeProcessInterrupted(String)
  NativeProcessTimedOut(String)
} derive(Debug, Eq)

///|
fn valid_native_provider_boundary_token(value : String) -> Bool {
  if value == "" || value.length() > 180 {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let code = value[index].to_int()
    let valid = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '_'.to_int() ||
      code == '-'.to_int()
    if !valid {
      return false
    }
  }
  true
}

///|
fn native_provider_expected_owner_socket_root(sterile_root : String) -> String? {
  for provider in ["claude", "codex"] {
    let parts = sterile_root.split("/" + provider + "/").to_array()
    if parts.length() == 2 &&
      parts[0] != "" &&
      valid_native_provider_boundary_token(parts[1].to_owned()) {
      return Some(parts[0].to_owned() + "/owner-socket")
    }
  }
  None
}

///|
fn native_provider_owner_socket_root() -> String {
  "/tmp/choir-owner"
}

///|
fn native_provider_owner_socket_path() -> String {
  native_provider_owner_socket_root() + "/owner.sock"
}

///|
fn native_provider_host_boundary_args(
  sterile_root : String,
  working_directory : String,
  boxlite_owner_socket_root : String?,
  executable : String,
  executable_args : Array[String],
) -> Array[String] {
  let args : Array[String] = [
    "--die-with-parent", "--ro-bind", "/", "/", "--dev-bind", "/dev", "/dev", "--proc",
    "/proc", "--tmpfs", "/tmp", "--bind", sterile_root, sterile_root, "--chdir",
    working_directory, "--", executable,
  ]
  match boxlite_owner_socket_root {
    Some(source) => {
      let chdir = args.search("--chdir").unwrap()
      args.insert(chdir, "--ro-bind")
      args.insert(chdir + 1, source)
      args.insert(chdir + 2, native_provider_owner_socket_root())
    }
    None => ()
  }
  for argument in executable_args {
    args.push(argument)
  }
  args
}

///|
fn validate_native_provider_host_boundary() -> Result[Unit, @types.ChoirError] {
  if @sys.realpath_native("/usr/bin/bwrap") != Some("/usr/bin/bwrap") ||
    !@sys.path_executable("/usr/bin/bwrap") {
    Err(
      @types.ChoirError::policy_blocked(
        "provider read-only host boundary is unavailable",
      ),
    )
  } else {
    Ok(())
  }
}

///|
pub async fn capture_native_provider_host_boundary(
  root : String,
  surface : @harness.ProviderSurface,
) -> Result[@control.Digest, @types.ChoirError] {
  let label = match surface {
    @harness.ProviderSurface::ClaudeCli => "claude"
    @harness.ProviderSurface::CodexCli => "codex"
  }
  if !root.has_prefix("/tmp/choir-" + label + "-host-boundary-") ||
    @sys.path_entry_exists(root) {
    return Err(
      @types.ChoirError::validation_error(
        "provider host-boundary probe root is invalid",
      ),
    )
  }
  match validate_native_provider_host_boundary() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let outside = root + "-outside"
  let inside = root + "/inside"
  if @sys.path_entry_exists(outside) || !@sys.create_dir_all(root) {
    return Err(
      @types.ChoirError::workspace_error(
        "provider host-boundary probe fixtures are unavailable",
      ),
    )
  }
  let sink = @process.redirect_to_file("/dev/null") catch {
    _ => {
      ignore(@sys.rm_rf(root))
      return Err(
        @types.ChoirError::transport_error(
          "provider host-boundary probe sink failed",
        ),
      )
    }
  }
  let run = async fn(path : String) -> Int {
    @process.run(
      "/usr/bin/bwrap",
      native_provider_host_boundary_args(root, root, None, "/usr/bin/touch", [
        path,
      ]),
      extra_env={ "PATH": "/usr/bin:/bin", "LC_ALL": "C" },
      inherit_env=false,
      stdout=sink,
      stderr=sink,
      cwd="/tmp",
    ) catch {
      _ => -1
    }
  }
  let inside_code = run(inside)
  let outside_code = run(outside)
  let inside_created = @sys.path_exists(inside)
  let outside_absent = !@sys.path_entry_exists(outside)
  let evidence = @storage.artifact_digest(
    @utf8.encode(
      "choir." +
      label +
      "-read-only-host-boundary.v1\u{00}" +
      inside_code.to_string() +
      "\u{00}" +
      outside_code.to_string() +
      "\u{00}" +
      inside_created.to_string() +
      "\u{00}" +
      outside_absent.to_string(),
    ),
  )
  ignore(@sys.rm_rf(root))
  ignore(@sys.delete_file_sync(outside))
  if inside_code == 0 && inside_created && outside_code != 0 && outside_absent {
    Ok(evidence)
  } else {
    Err(
      @types.ChoirError::policy_blocked(
        "provider read-only host boundary did not confine mutation",
      ),
    )
  }
}

///|
pub async fn collect_interruptible_process(
  program : String,
  arguments : Array[String],
  environment : Map[String, String],
  stdin_read : &@process.ProcessInput,
  cwd : String,
  timeout_ms : Int,
  cancellation_requested : () -> Bool,
  started? : (Int) -> Result[Unit, @types.ChoirError] = fn(_) { Ok(()) },
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
  match started(pid) {
    Ok(_) => ()
    Err(error) => {
      @sys.kill_pgid_sequence_best_effort(pid)
      ignore(@process.wait_pid(pid) catch { _ => -1 })
      reader.close()
      return Err(error)
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

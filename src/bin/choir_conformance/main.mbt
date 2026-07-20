///|
fn hermetic_dependencies() -> @conformance.ConformanceDependencies {
  let clock = @ref.new(1L)
  let ids = @ref.new(0)
  {
    now: fn() {
      let current = clock.val
      clock.val = current + 1L
      current
    },
    next_id: fn(kind) {
      ids.val = ids.val + 1
      let prefix = match kind {
        @conformance.ConformanceIdKind::ConformanceReportId => "report"
        @conformance.ConformanceIdKind::ConformanceRunId => "run"
        @conformance.ConformanceIdKind::ConformanceArtifactId => "artifact"
      }
      prefix + "-" + ids.val.to_string()
    },
    fault_enabled: fn(point) {
      point == @conformance.FaultPoint::EventBeforeIngestTransaction
    },
    adapters: {
      read_state: fn(_) {
        Ok(
          @conformance.StateObservation::StateSnapshot(
            @control.Digest("runner-contract-state"),
          ),
        )
      },
      read_artifact: fn(_) {
        Ok(@conformance.ArtifactObservation::ArtifactPresent)
      },
      read_effect_witness: fn(_) {
        Ok(@conformance.EffectWitnessObservation::EffectWitnessPresent)
      },
    },
  }
}

///|
fn run_hermetic() -> Int {
  let report = @conformance.run_hermetic_suite(
    [
      @conformance.runner_dependency_contract_case(),
      @conformance.scheduler_generated_dags_case(),
      @conformance.event_duplicate_conflict_case(),
      @conformance.event_cursor_gap_case(),
      @conformance.event_late_terminal_case(),
      @conformance.event_conflicting_terminal_case(),
      @conformance.selection_exact_snapshot_case(),
      @conformance.ownership_normalization_case(),
      @conformance.ownership_conflict_matrix_case(),
      @conformance.ownership_underclaim_case(),
      @conformance.ownership_rename_delete_generate_case(),
      @conformance.process_validation_matrix_case(),
      @conformance.process_authority_fence_case(),
      @conformance.process_canonical_dispatch_case(),
    ],
    hermetic_dependencies(),
  )
  @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
  if report.failed == 0 {
    0
  } else {
    1
  }
}

///|
fn probe_mcp_launch(
  delay_ms? : Int = 0,
) -> Result[(String, Array[String]), @types.ChoirError] {
  let node = match @exec.resolve_executable_in_path("node") {
    Some(path) => path
    None =>
      return Err(
        @types.ChoirError::workspace_error(
          "node executable is required for the startup probe MCP fixture",
        ),
      )
  }
  let script = match @sys.realpath_native("scripts/choir_probe_mcp.mjs") {
    Some(path) => path
    None =>
      return Err(
        @types.ChoirError::workspace_error(
          "failed to resolve startup probe MCP fixture",
        ),
      )
  }
  if delay_ms < 0 || delay_ms > 30000 {
    return Err(
      @types.ChoirError::validation_error("startup probe delay is invalid"),
    )
  }
  let args = [script]
  if delay_ms > 0 {
    args.push("--delay-ms")
    args.push(delay_ms.to_string())
  }
  Ok((node, args))
}

///|
async fn capture_surface_command(
  surface : @harness.ProviderSurface,
  command : @harness.HarnessProbeCommand,
) -> @harness.HarnessProbeCapture {
  match @exec.capture_harness_probe({ surface, command }) {
    Ok(capture) => capture
    Err(error) => { exit_code: -1, output: error.message() }
  }
}

///|
async fn run_surface_declaration(surface : @harness.ProviderSurface) -> Int {
  let version = capture_surface_command(
    surface,
    @harness.HarnessProbeCommand::ProbeVersion,
  )
  let main_help = capture_surface_command(
    surface,
    @harness.HarnessProbeCommand::ProbeMainHelp,
  )
  let exec_help = match surface {
    @harness.ProviderSurface::ClaudeCli => None
    @harness.ProviderSurface::CodexCli =>
      Some(
        capture_surface_command(
          surface,
          @harness.HarnessProbeCommand::ProbeExecHelp,
        ),
      )
  }
  let report = @harness.evaluate_surface_declaration({
    surface,
    version,
    main_help,
    exec_help,
  })
  @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
  match report.support {
    @harness.ChoirSurfaceSupport::SurfaceCandidate => 0
    _ => 1
  }
}

///|
async fn run_claude_synthetic_startup() -> Int {
  let root = "/tmp/choir-conformance-claude-startup-" +
    @sys.get_pid().to_string()
  if !@sys.create_dir_all(root + "/tmp") || !@sys.create_dir_all(root + "/xdg") {
    @sys.write_stderr("failed to create dedicated synthetic startup root\n")
    return 1
  }
  let (mcp_command, mcp_args) = match probe_mcp_launch() {
    Ok(launch) => launch
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let capture = match
    @exec.capture_claude_synthetic_startup(root, mcp_command, mcp_args) {
    Ok(capture) => capture
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let report = @harness.evaluate_claude_synthetic_startup(capture)
  ignore(@sys.rm_rf(root))
  @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
  match report.support {
    @harness.ChoirSurfaceSupport::SurfaceCandidate => 0
    _ => 1
  }
}

///|
async fn run_claude_live_startup() -> Int {
  let root = "/tmp/choir-conformance-claude-live-" + @sys.get_pid().to_string()
  if !@sys.create_dir_all(root + "/tmp") {
    @sys.write_stderr("failed to create dedicated live startup root\n")
    return 1
  }
  let (mcp_command, mcp_args) = match probe_mcp_launch() {
    Ok(launch) => launch
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let capture = match
    @exec.capture_claude_live_startup(root, mcp_command, mcp_args) {
    Ok(capture) => capture
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let report = @harness.evaluate_claude_live_startup(capture)
  ignore(@sys.rm_rf(root))
  @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
  match report.support {
    @harness.ChoirSurfaceSupport::SurfaceCandidate => 0
    _ => 1
  }
}

///|
async fn run_codex_live_startup() -> Int {
  let root = "/tmp/choir-conformance-codex-live-" + @sys.get_pid().to_string()
  if !@sys.create_dir_all(root + "/tmp") {
    @sys.write_stderr("failed to create dedicated Codex startup root\n")
    return 1
  }
  let (mcp_command, mcp_args) = match probe_mcp_launch() {
    Ok(launch) => launch
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let read_canary = match @sys.realpath_native("GOAL.md") {
    Some(path) => path
    None => {
      @sys.write_stderr("failed to resolve Codex read canary\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let evidence = match
    @exec.capture_codex_live_startup(root, mcp_command, mcp_args, read_canary) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let report = @harness.evaluate_codex_live_startup(evidence)
  ignore(@sys.rm_rf(root))
  @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
  match report.support {
    @harness.ChoirSurfaceSupport::SurfaceCandidate => 0
    _ => 1
  }
}

///|
async fn run_codex_live_driver_at(
  root : String,
  delay_ms : Int,
  crash_after_turn_start : Bool,
  cleanup : Bool,
) -> Int {
  if !@sys.create_dir_all(root + "/tmp") {
    @sys.write_stderr("failed to create dedicated Codex driver root\n")
    return 1
  }
  let (mcp_command, mcp_args) = match probe_mcp_launch(delay_ms~) {
    Ok(launch) => launch
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let planned : @control.HarnessSession = {
    id: @control.HarnessSessionId("codex-live-driver-session"),
    take_id: @control.TakeId("codex-live-driver-take"),
    sandbox_generation_id: @control.SandboxGenerationId(
      "codex-live-driver-sandbox",
    ),
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    effective_surface_manifest_digest: @harness.codex_effective_surface_manifest_digest(
      ["probe"],
      "choir_probe",
    ),
    cursor_class: @control.HarnessCursorClass::HarnessCursorProviderEventId,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
  let started = match @harness.start_codex_harness_session(planned) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let clock = @ref.new(100L)
  let result = match
    @exec.run_native_codex_take(
      {
        sterile_root: root,
        mcp_executable: mcp_command,
        mcp_arguments: mcp_args,
        mcp_server_name: "choir_probe",
        allowed_tools: ["probe"],
        timeout_ms: 120000,
      },
      started,
      @harness.CodexTakeRole::CodexImplementationTake,
      "Call probe exactly once. Only after it returns probe, report the required completed outcome.",
      fn() {
        clock.val = clock.val + 1L
        clock.val
      },
      after_turn_started=fn() { if crash_after_turn_start { @sys.exit(77) } },
    ) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      if cleanup {
        ignore(@sys.rm_rf(root))
      }
      return 1
    }
  }
  if cleanup {
    ignore(@sys.rm_rf(root))
  }
  let report : Map[String, Json] = {
    "surface": "CodexSubscriptionCli".to_json(),
    "outcome": result.outcome.to_json(),
    "event_count": result.events.length().to_json(),
    "terminal_response": result.terminal_response.to_json(),
    "lifecycle": result.session.lifecycle.to_json(),
  }
  @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
  0
}

///|
async fn run_codex_live_driver() -> Int {
  run_codex_live_driver_at(
    "/tmp/choir-conformance-codex-driver-" + @sys.get_pid().to_string(),
    0,
    false,
    true,
  )
}

///|
fn codex_recovery_manifest_identity(root : String) -> (String, String, Int)? {
  let path = root + "/take-session.json"
  if !@sys.path_exists(path) {
    return None
  }
  let json = @json.parse(@sys.read_file(path)) catch { _ => return None }
  guard json is Object(fields) else { return None }
  let thread_id = match @types.json_field_string(fields, "thread_id") {
    Some(value) => value
    None => return None
  }
  let turn_id = match @types.json_field_string(fields, "turn_id") {
    Some(value) => value
    None => return None
  }
  let server_pid = match fields.get("server_pid") {
    Some(Number(value, ..)) => value.to_int()
    _ => return None
  }
  Some((thread_id, turn_id, server_pid))
}

///|
async fn run_codex_live_recovery() -> Int {
  let root = "/tmp/choir-conformance-codex-recovery-" +
    @sys.get_pid().to_string()
  let executable = match
    @sys.realpath_native(
      "_build/native/debug/build/src/bin/choir_conformance/choir_conformance.exe",
    ) {
    Some(value) => value
    None => {
      @sys.write_stderr("failed to resolve conformance executable\n")
      return 1
    }
  }
  let crash_code = @process.run(
    executable,
    [
      "harness", "--surface", "codex-cli", "--profile", "subscription", "--driver-recovery-crash",
      root,
    ],
    inherit_env=true,
    cwd=match @sys.realpath_native(".") {
      Some(value) => value
      None => "/tmp"
    },
  ) catch {
    _ => -1
  }
  if crash_code != 77 {
    @sys.write_stderr(
      "Codex recovery child did not stop at the injected boundary\n",
    )
    ignore(@sys.rm_rf(root))
    return 1
  }
  let before = match codex_recovery_manifest_identity(root) {
    Some(value) => value
    None => {
      @sys.write_stderr("Codex recovery manifest is incomplete\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  if !@sys.pgid_is_alive(before.2) {
    @sys.write_stderr("Codex app-server did not survive client loss\n")
    ignore(@sys.rm_rf(root))
    return 1
  }
  let resumed = run_codex_live_driver_at(root, 5000, false, false)
  let after = codex_recovery_manifest_identity(root)
  let same_turn = match after {
    Some(value) => value.0 == before.0 && value.1 == before.1
    None => false
  }
  @sys.kill_pgid_sequence_best_effort(before.2)
  ignore(@sys.rm_rf(root))
  if resumed != 0 || !same_turn {
    @sys.write_stderr("Codex recovery did not preserve the exact turn\n")
    1
  } else {
    @sys.write_stdout(
      { "recovered_exact_turn": true.to_json() }.to_json().stringify(indent=2) +
      "\n",
    )
    0
  }
}

///|
fn parse_surface(raw : String) -> @harness.ProviderSurface? {
  match raw {
    "claude-cli" => Some(@harness.ProviderSurface::ClaudeCli)
    "codex-cli" => Some(@harness.ProviderSurface::CodexCli)
    _ => None
  }
}

///|
fn run_harness_command(args : Array[String]) -> Unit {
  if args.length() == 7 &&
    args[2] == "--surface" &&
    args[3] == "claude-cli" &&
    args[4] == "--profile" &&
    args[5] == "subscription" &&
    args[6] == "--synthetic-startup" {
    @async.run_async_main(async fn() {
      @sys.exit(run_claude_synthetic_startup())
    })
  } else if args.length() == 7 &&
    args[2] == "--surface" &&
    args[3] == "claude-cli" &&
    args[4] == "--profile" &&
    args[5] == "subscription" &&
    args[6] == "--live" {
    @async.run_async_main(async fn() { @sys.exit(run_claude_live_startup()) })
  } else if args.length() == 7 &&
    args[2] == "--surface" &&
    args[3] == "codex-cli" &&
    args[4] == "--profile" &&
    args[5] == "subscription" &&
    args[6] == "--live" {
    @async.run_async_main(async fn() { @sys.exit(run_codex_live_startup()) })
  } else if args.length() == 7 &&
    args[2] == "--surface" &&
    args[3] == "codex-cli" &&
    args[4] == "--profile" &&
    args[5] == "subscription" &&
    args[6] == "--driver-live" {
    @async.run_async_main(async fn() { @sys.exit(run_codex_live_driver()) })
  } else if args.length() == 7 &&
    args[2] == "--surface" &&
    args[3] == "codex-cli" &&
    args[4] == "--profile" &&
    args[5] == "subscription" &&
    args[6] == "--driver-recovery-live" {
    @async.run_async_main(async fn() { @sys.exit(run_codex_live_recovery()) })
  } else if args.length() == 8 &&
    args[2] == "--surface" &&
    args[3] == "codex-cli" &&
    args[4] == "--profile" &&
    args[5] == "subscription" &&
    args[6] == "--driver-recovery-crash" &&
    args[7].has_prefix("/tmp/choir-conformance-codex-recovery-") {
    @async.run_async_main(async fn() {
      @sys.exit(run_codex_live_driver_at(args[7], 5000, true, false))
    })
  } else if args.length() == 6 &&
    args[2] == "--surface" &&
    args[4] == "--profile" &&
    args[5] == "subscription" {
    match parse_surface(args[3]) {
      Some(surface) =>
        @async.run_async_main(async fn() {
          @sys.exit(run_surface_declaration(surface))
        })
      None => {
        usage()
        @sys.exit(2)
      }
    }
  } else {
    usage()
    @sys.exit(2)
  }
}

///|
fn cleanup_conductor_start_probe(root : String) -> Unit {
  let raw_pid = @sys.read_file(root + "/.choir/run/server.pid")
    .trim()
    .to_owned()
  let pid = @string.parse_int(raw_pid) catch { _ => 0 }
  if pid > 1 {
    @sys.kill_server_pid_sequence_best_effort(pid)
  }
  ignore(@sys.rm_rf(root))
}

///|
async fn run_conductor_start_live() -> Int {
  let root = "/tmp/choir-conductor-start-" + @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  if !@sys.create_dir_all(root + "/bin") {
    @sys.write_stderr("failed to create Conductor start fixture\n")
    return 1
  }
  let (build_code, build_output) = @exec.capture_command_merged({
    program: "moon",
    args: ["build", "--target", "native", "src/bin/choir"],
    workdir: None,
  })
  if build_code != 0 {
    @sys.write_stderr(build_output)
    cleanup_conductor_start_probe(root)
    return 1
  }
  let choir_binary = match
    @sys.realpath_native("_build/native/debug/build/src/bin/choir/choir.exe") {
    Some(value) => value
    None => {
      @sys.write_stderr("built Choir binary is unavailable\n")
      cleanup_conductor_start_probe(root)
      return 1
    }
  }
  let socket_path = root + "/.choir/run/server.sock"
  let conductor_output = root + "/conductor-output.json"
  let fake_conductor = root + "/bin/claude"
  let fake_body = "#!/bin/sh\nif [ -n \"$CHOIR_CONDUCTOR_TOKEN\" ]; then token_state=present; else token_state=missing; fi\nprintf '%s|%s|%s\\n' \"$CHOIR_WORKSPACE\" \"$token_state\" \"$CHOIR_LISTEN_UDS\" > \"$CHOIR_START_TEST_OUTPUT.env\"\nprintf '%s\\n' \"$*\" > \"$CHOIR_START_TEST_OUTPUT.args\"\n\"$CHOIR_START_TEST_BINARY\" goal status missing > \"$CHOIR_START_TEST_OUTPUT\" 2>&1 || true\nexit 0\n"
  if !@sys.write_file_sync(fake_conductor, fake_body) {
    @sys.write_stderr("failed to write fake Conductor\n")
    cleanup_conductor_start_probe(root)
    return 1
  }
  let (chmod_code, chmod_output) = @exec.capture_command_merged({
    program: "/usr/bin/chmod",
    args: ["0700", fake_conductor],
    workdir: None,
  })
  if chmod_code != 0 {
    @sys.write_stderr(chmod_output)
    cleanup_conductor_start_probe(root)
    return 1
  }
  let inherited_path = @sys.getenv("PATH").unwrap_or("/usr/bin:/bin")
  let (start_code, start_output) = @exec.capture_command_merged({
    program: "/usr/bin/env",
    args: [
      "PATH=" + root + "/bin:" + inherited_path,
      "CHOIR_START_TEST_BINARY=" + choir_binary,
      "CHOIR_START_TEST_OUTPUT=" + conductor_output,
      choir_binary,
      "init",
    ],
    workdir: Some(root),
  })
  let conductor_result = @sys.read_file(conductor_output)
  let conductor_environment = @sys.read_file(conductor_output + ".env")
  let conductor_args = @sys.read_file(conductor_output + ".args")
  let (mode_code, socket_mode) = @exec.capture_command_merged({
    program: "/usr/bin/stat",
    args: ["-c", "%a", socket_path],
    workdir: None,
  })
  let project_initialized = @sys.path_exists(root + "/.choir/config.toml") &&
    @sys.path_exists(root + "/.choir/config.local.toml")
  let conductor_surface_restricted = conductor_args.contains("--tools") &&
    conductor_args.contains("--setting-sources") &&
    conductor_args.contains("--strict-mcp-config") &&
    !conductor_args.contains("semble")
  let functional_passed = start_code == 0 &&
    conductor_result.contains("Goal is not registered") &&
    !conductor_result.contains("authentication failed") &&
    project_initialized &&
    @sys.path_exists(root + "/.choir/plugin/skills/goal/SKILL.md") &&
    !@sys.path_entry_exists(root + "/.choir/plugin/skills/audit") &&
    conductor_surface_restricted &&
    mode_code == 0 &&
    socket_mode.trim().to_owned() == "600"
  let daemon_pid = @string.parse_int(
    @sys.read_file(root + "/.choir/run/server.pid").trim().to_owned(),
  ) catch {
    _ => 0
  }
  cleanup_conductor_start_probe(root)
  let daemon_stopped = daemon_pid > 1 && !@sys.pid_is_alive(daemon_pid)
  let passed = functional_passed && daemon_stopped
  let report : Map[String, Json] = {
    "passed": passed.to_json(),
    "start_exit_code": start_code.to_json(),
    "daemon_socket_mode": socket_mode.trim().to_owned().to_json(),
    "conductor_registered": conductor_result
    .contains("Goal is not registered")
    .to_json(),
    "project_initialized": project_initialized.to_json(),
    "zellij_required": false.to_json(),
    "conductor_surface_restricted": conductor_surface_restricted.to_json(),
    "daemon_stopped": daemon_stopped.to_json(),
  }
  if !passed {
    report.set("start_output", start_output.to_json())
    report.set("conductor_output", conductor_result.to_json())
    report.set("conductor_environment", conductor_environment.to_json())
    report.set("conductor_args", conductor_args.to_json())
  }
  @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
  if passed {
    0
  } else {
    1
  }
}

///|
fn run_conductor_command(args : Array[String]) -> Unit {
  if args.length() == 3 && args[2] == "--start-live" {
    @async.run_async_main(async fn() { @sys.exit(run_conductor_start_live()) })
  } else {
    usage()
    @sys.exit(2)
  }
}

///|
async fn run_boxlite_live() -> Int {
  let root = "/tmp/choir-conformance-boxlite-" + @sys.get_pid().to_string()
  if !@sys.create_dir_all(root + "/tmp") || !@sys.create_dir_all(root + "/home") {
    @sys.write_stderr("failed to create dedicated BoxLite probe root\n")
    return 1
  }
  let evidence = match @exec.capture_boxlite_live_evidence(root) {
    Ok(evidence) => evidence
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let report = @sandbox.evaluate_boxlite_live_evidence(evidence)
  ignore(@sys.rm_rf(root))
  @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
  match report.support {
    @sandbox.SandboxRuntimeSupport::SandboxRuntimeCandidate => 0
    @sandbox.SandboxRuntimeSupport::SandboxRuntimeSupported => 0
    @sandbox.SandboxRuntimeSupport::SandboxRuntimeBlockedByConformance => 1
  }
}

///|
async fn exercise_boxlite_take(
  server : @exec.NativeBoxLiteServerHandle,
  active_server : @ref.Ref[@exec.NativeBoxLiteServerHandle],
  moon_home : String,
  source : @exec.NativeGitWorkspaceSource,
  git_config : @exec.NativeGitWorkspaceConfig,
) -> Result[Map[String, Json], @types.ChoirError] {
  let prepared = match
    @exec.prepare_native_boxlite_environment(
      server,
      moon_home,
      "choir-take-base-" + @sys.get_pid().to_string(),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  active_server.val = prepared.server
  let take = match
    @exec.clone_native_boxlite_take(
      prepared,
      "choir-take-live-" + @sys.get_pid().to_string(),
      source.root,
      source.source_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  active_server.val = take.prepared.server
  let inspected = match @exec.inspect_native_boxlite_take(take) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let script = match @sys.realpath_native("scripts/choir_sandbox_mcp.mjs") {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::workspace_error("sandbox MCP bridge is unavailable"),
      )
  }
  let arguments = match @exec.native_boxlite_take_mcp_arguments(take, script) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let node = match @exec.resolve_executable_in_path("node") {
    Some(value) => value
    None =>
      return Err(
        @types.ChoirError::workspace_error(
          "node executable is required for the sandbox MCP bridge",
        ),
      )
  }
  let bridge_probe = match @exec.probe_native_boxlite_mcp(take, node, script) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result_root = match @exec.copy_native_boxlite_take_result(take) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @sys.read_file(result_root + "/.choir-live-roundtrip.txt") !=
    "sandbox mutation\n" {
    return Err(
      @types.ChoirError::workspace_error("sandbox result did not round-trip"),
    )
  }
  let (candidate, path_evidence) = match
    @exec.normalize_native_git_candidate(
      git_config,
      "take-live-" + @sys.get_pid().to_string(),
      @control.GoalId("live-goal"),
      @control.PartId("live-part"),
      @control.TakeId("live-take"),
      source.commit_oid,
      source.source_digest,
      result_root,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let retried = match
    @exec.normalize_native_git_candidate(
      git_config,
      "take-live-" + @sys.get_pid().to_string(),
      @control.GoalId("live-goal"),
      @control.PartId("live-part"),
      @control.TakeId("live-take"),
      source.commit_oid,
      source.source_digest,
      result_root,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if candidate.base_commit_oid != source.commit_oid ||
    candidate.tree_oid == source.tree_oid ||
    candidate.changed_paths != [@control.RepoPath(".choir-live-roundtrip.txt")] ||
    path_evidence.symlink_prefix_paths != [@control.RepoPath("AGENTS.md")] ||
    path_evidence.normalization_collision_paths.length() != 0 ||
    retried != (candidate, path_evidence) {
    return Err(
      @types.ChoirError::git_error(
        "sandbox result did not produce the exact candidate: " +
        candidate.to_json().stringify(indent=0) +
        " evidence=" +
        path_evidence.to_json().stringify(indent=0),
      ),
    )
  }
  let assurance_mutable = match
    @exec.clone_native_boxlite_take(
      prepared,
      "choir-assurance-live-" + @sys.get_pid().to_string(),
      source.root,
      source.source_digest,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let assurance = match
    @exec.seal_native_boxlite_assurance_subject(assurance_mutable) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let assurance_process : @sandbox.SandboxProcessSpec = {
    authority: @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
      @control.TakeId("assurance-live-take"),
      @control.VerificationSpecId("assurance-live-spec"),
      @control.Digest("assurance-live-policy"),
    ),
    executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
      @sandbox.SandboxRegisteredToolId("moon"),
      prepared.tool_manifest_digest,
    ),
    arguments: ["--target-dir", "/scratch/typed-verification", "version"],
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
      policy_digest: prepared.runtime_policy_digest,
    },
    output: {
      stdout_limit_bytes: 1048576L,
      stderr_limit_bytes: 1048576L,
      on_limit: @sandbox.SandboxOutputLimitDisposition::SandboxTerminateAndMarkExceeded,
    },
  }
  let assurance_process_digest = @storage.artifact_digest(
    @utf8.encode(assurance_process.to_json().stringify(indent=0)),
  )
  let assurance_process_result = match
    @exec.execute_native_boxlite_process(
      assurance,
      {
        goal_id: @control.GoalId("assurance-live-goal"),
        take_id: @control.TakeId("assurance-live-take"),
        fencing_epoch: @control.FencingEpoch(1L),
      },
      assurance_process_digest,
      assurance_process,
      fn(_) { false },
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if assurance_process_result.exit_code != 0 {
    return Err(
      @types.ChoirError::workspace_error(
        "read-only typed verification failed: " +
        assurance_process_result.output,
      ),
    )
  }
  let assurance_probe = match
    @exec.probe_native_boxlite_mcp(assurance, node, script) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let assurance_result = match
    @exec.copy_native_boxlite_take_result(assurance) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let assurance_tree = match
    @exec.observe_native_git_result_tree(
      git_config,
      "assurance-live-" + @sys.get_pid().to_string(),
      source.commit_oid,
      source.source_digest,
      assurance_result,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if assurance_tree != source.tree_oid {
    return Err(
      @types.ChoirError::workspace_error("read-only assurance subject changed"),
    )
  }
  match @exec.destroy_native_boxlite_take(take) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match @exec.destroy_native_boxlite_take(assurance) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok({
    "passed": true.to_json(),
    "image_digest": prepared.image_digest.to_json(),
    "runtime_policy_digest": prepared.runtime_policy_digest.to_json(),
    "tool_manifest_digest": prepared.tool_manifest_digest.to_json(),
    "tool_count": @sandbox.boxlite_take_mcp_tools().length().to_json(),
    "bridge_argument_count": arguments.length().to_json(),
    "bridge_probe_digest": @storage.artifact_digest(@utf8.encode(bridge_probe)).to_json(),
    "assurance_probe_digest": @storage.artifact_digest(
      @utf8.encode(assurance_probe),
    ).to_json(),
    "assurance_case_id": "process.audit_scratch_boundary".to_json(),
    "assurance_subject_read_only": true.to_json(),
    "assurance_scratch_output_persisted": true.to_json(),
    "assurance_typed_process_exit": assurance_process_result.exit_code.to_json(),
    "result_round_trip": true.to_json(),
    "candidate_retry_stable": true.to_json(),
    "candidate_commit": candidate.commit_oid.to_json(),
    "candidate_tree": candidate.tree_oid.to_json(),
    "changed_paths": candidate.changed_paths.to_json(),
    "inspection": inspected.to_json(),
  })
}

///|
async fn capture_live_git(
  repository_root : String,
  arguments : Array[String],
) -> String {
  @exec.capture_stdout_with_cwd(
    "/usr/bin/git",
    arguments,
    Some(repository_root),
  )
}

///|
async fn run_boxlite_take_live() -> Int {
  let root = "/tmp/choir-take-live-" + @sys.get_pid().to_string()
  let repository_root = match @sys.realpath_native(".") {
    Some(value) => value
    None => {
      @sys.write_stderr("repository root is unavailable\n")
      return 1
    }
  }
  let staging_root = root + "/staging"
  if !@sys.create_dir_all(staging_root) {
    @sys.write_stderr("failed to create dedicated Take sandbox root\n")
    return 1
  }
  let head = capture_live_git(repository_root, ["rev-parse", "--verify", "HEAD"])
    .trim()
    .to_owned()
  let tree = capture_live_git(repository_root, [
      "show", "-s", "--format=%T", "--no-show-signature", head,
    ])
    .trim()
    .to_owned()
  if head.length() != 40 || tree.length() != 40 {
    @sys.write_stderr("repository source identity is invalid\n")
    ignore(@sys.rm_rf(root))
    return 1
  }
  let host_state_before = capture_live_git(repository_root, [
    "status", "--porcelain=v2", "--untracked-files=all",
  ])
  let source_digest = @storage.artifact_digest(
    @utf8.encode("choir.live-source.v1\u{00}" + head + "\u{00}" + tree),
  )
  let git_config : @exec.NativeGitWorkspaceConfig = {
    repository_root,
    object_directory: capture_live_git(repository_root, [
      "rev-parse", "--path-format=absolute", "--git-path", "objects",
    ])
    .trim()
    .to_owned(),
    staging_root,
  }
  let source = match
    @exec.stage_native_git_workspace(
      git_config,
      "source",
      @control.GitOid(head),
      @control.GitOid(tree),
      source_digest,
    ) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let binary = match @sys.getenv("CHOIR_BOXLITE_BINARY") {
    Some(value) => value
    None => "/home/justin/.local/bin/boxlite"
  }
  let runtime_dir = match @sys.getenv("CHOIR_BOXLITE_RUNTIME_DIR") {
    Some(value) => value
    None =>
      "/home/justin/.local/share/choir/runtimes/boxlite-v0.9.7-seccomp-time"
  }
  let moon_home = match @sys.getenv("CHOIR_MOON_HOME") {
    Some(value) => value
    None =>
      match @sys.getenv("HOME") {
        Some(value) => value + "/.moon"
        None => {
          @sys.write_stderr("Moon toolchain root is unavailable\n")
          return 1
        }
      }
  }
  let server = match
    @exec.start_native_boxlite_server({
      binary,
      runtime_dir,
      root,
      port: 24000 + @sys.get_pid() % 12000,
      api_key: "choir-take-live-" + @sys.get_pid().to_string(),
    }) {
    Ok(value) => value
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      ignore(@sys.rm_rf(root))
      return 1
    }
  }
  let active_server = @ref.new(server)
  let exercised = exercise_boxlite_take(
    server, active_server, moon_home, source, git_config,
  )
  let cleanup = @exec.cleanup_native_boxlite_server(active_server.val)
  let host_head_after = capture_live_git(repository_root, [
      "rev-parse", "--verify", "HEAD",
    ])
    .trim()
    .to_owned()
  let host_state_after = capture_live_git(repository_root, [
    "status", "--porcelain=v2", "--untracked-files=all",
  ])
  ignore(@sys.rm_rf(root))
  if host_head_after != head || host_state_after != host_state_before {
    @sys.write_stderr("host checkout or ref changed during Take\n")
    return 1
  }
  match cleanup {
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      1
    }
    Ok(_) =>
      match exercised {
        Ok(report) => {
          @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
          0
        }
        Err(error) => {
          @sys.write_stderr(error.message() + "\n")
          1
        }
      }
  }
}

///|
fn run_sandbox_command(args : Array[String]) -> Unit {
  if args.length() == 5 &&
    args[2] == "--runtime" &&
    args[3] == "boxlite" &&
    args[4] == "--live" {
    @async.run_async_main(async fn() { @sys.exit(run_boxlite_live()) })
  } else if args.length() == 5 &&
    args[2] == "--runtime" &&
    args[3] == "boxlite" &&
    args[4] == "--take-live" {
    @async.run_async_main(async fn() { @sys.exit(run_boxlite_take_live()) })
  } else {
    usage()
    @sys.exit(2)
  }
}

///|
async fn run_joined_goal_until_settled(
  project_dir : String,
  goal_id : @control.GoalId,
) -> Result[@workflow.GoalExecutionRecord, @types.ChoirError] {
  let mut cycles = 0
  while cycles < 16 {
    cycles = cycles + 1
    match @exec.run_native_goal_execution_tick(project_dir) {
      Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickAdvanced(record)) =>
        if record.goal.id != goal_id {
          continue
        } else {
          match record.state {
            @workflow.GoalExecutionState::GoalExecutionQueued
            | @workflow.GoalExecutionState::GoalExecutionRunning
            | @workflow.GoalExecutionState::GoalExecutionAssuring => continue
            _ => return Ok(record)
          }
        }
      Ok(@workflow.GoalExecutionTickResult::GoalExecutionTickIdle) =>
        return Err(
          @types.ChoirError::validation_error("joined Goal tick found no work"),
        )
      Err(error) => return Err(error)
    }
  } nobreak {
    Err(@types.ChoirError::timeout("joined Goal execution"))
  }
}

///|
async fn run_end_to_end_command(args : Array[String]) -> Unit {
  if args.length() == 6 && args[2] == "--project" && args[4] == "--draft" {
    guard @sys.realpath_native(args[3]) is Some(project_dir) else {
      @sys.write_stderr("joined Goal project is unavailable\n")
      @sys.exit(2)
      return
    }
    let draft = @sys.read_file(args[5])
    let submission = match
      @exec.submit_native_conductor_goal_draft(
        project_dir, draft, @exec.capture_command_merged,
      ) {
      Ok(value) => value
      Err(error) => {
        @sys.write_stderr(error.message() + "\n")
        @sys.exit(1)
        return
      }
    }
    @sys.write_stdout(submission.to_json().stringify(indent=2) + "\n")
    if !submission.accepted || !submission.execution_registered {
      @sys.exit(1)
    }
    if submission.replayed {
      match @exec.inspect_native_goal(project_dir, submission.goal_id) {
        Ok(report) if report.state ==
          @workflow.GoalExecutionState::GoalExecutionAssured => {
          @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
          @sys.exit(0)
          return
        }
        _ => ()
      }
    }
    match run_joined_goal_until_settled(project_dir, submission.goal_id) {
      Ok(record) => {
        @sys.write_stdout(record.to_json().stringify(indent=2) + "\n")
        @sys.exit(
          if record.state == @workflow.GoalExecutionState::GoalExecutionAssured {
            0
          } else {
            1
          },
        )
      }
      Err(error) => {
        @sys.write_stderr(error.message() + "\n")
        @sys.exit(1)
      }
    }
  }
  if args.length() != 4 || args[2] != "--fixture" {
    usage()
    @sys.exit(2)
  }
  match args[3] {
    "part-lifecycle" => {
      let root = "/tmp/choir-conformance-part-lifecycle-" +
        @sys.get_pid().to_string()
      if !@sys.create_dir_all(root) {
        @sys.write_stderr("failed to create Part conformance root\n")
        @sys.exit(1)
      }
      let report = @exec.run_part_conformance_fixture(root)
      ignore(@sys.rm_rf(root))
      @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
      @sys.exit(if report.passed { 0 } else { 1 })
    }
    "native-part-lifecycle" => {
      let root = "/tmp/choir-take-native-part-" + @sys.get_pid().to_string()
      let report = @exec.run_native_part_lifecycle_fixture(root)
      ignore(@sys.rm_rf(root))
      @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
      @sys.exit(if report.passed { 0 } else { 1 })
    }
    "native-codex-part-lifecycle" => {
      let root = "/tmp/choir-take-native-codex-part-" +
        @sys.get_pid().to_string()
      let report = @exec.run_native_codex_part_lifecycle_fixture(root)
      ignore(@sys.rm_rf(root))
      @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
      @sys.exit(if report.passed { 0 } else { 1 })
    }
    "native-codex-cancellation" => {
      let root = "/tmp/choir-take-native-codex-cancel-" +
        @sys.get_pid().to_string()
      let report = @exec.run_native_codex_cancellation_fixture(root)
      ignore(@sys.rm_rf(root))
      @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
      @sys.exit(if report.passed { 0 } else { 1 })
    }
    "mixed-provider-goal" => {
      let root = "/tmp/choir-take-mixed-provider-" + @sys.get_pid().to_string()
      let report = @exec.run_native_mixed_provider_goal_fixture(root)
      ignore(@sys.rm_rf(root))
      @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
      @sys.exit(if report.passed { 0 } else { 1 })
    }
    "parallel-promotion" => {
      let root = "/tmp/choir-goal-conformance-" + @sys.get_pid().to_string()
      let report = @exec.run_native_goal_conformance_fixture(root)
      ignore(@sys.rm_rf(root))
      @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
      @sys.exit(if report.passed { 0 } else { 1 })
    }
    _ => {
      usage()
      @sys.exit(2)
    }
  }
}

///|
fn run_goal_status_command(args : Array[String]) -> Unit {
  if args.length() != 6 || args[2] != "--project" || args[4] != "--goal" {
    usage()
    @sys.exit(2)
    return
  }
  guard @sys.realpath_native(args[3]) is Some(project_dir) else {
    @sys.write_stderr("Goal project is unavailable\n")
    @sys.exit(2)
    return
  }
  match @exec.inspect_native_goal(project_dir, @control.GoalId(args[5])) {
    Ok(report) => {
      @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
      @sys.exit(0)
    }
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      @sys.exit(1)
    }
  }
}

///|
fn run_goal_cancel_command(args : Array[String]) -> Unit {
  if args.length() != 6 || args[2] != "--project" || args[4] != "--goal" {
    usage()
    @sys.exit(2)
    return
  }
  guard @sys.realpath_native(args[3]) is Some(project_dir) else {
    @sys.write_stderr("Goal project is unavailable\n")
    @sys.exit(2)
    return
  }
  match
    @exec.cancel_native_goal(
      project_dir,
      @control.GoalId(args[5]),
      @env.now().reinterpret_as_int64() / 1000L,
    ) {
    Ok(_) => {
      @sys.write_stdout("cancellation recorded\n")
      @sys.exit(0)
    }
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      @sys.exit(1)
    }
  }
}

///|
async fn run_goal_publish_command(args : Array[String]) -> Unit {
  if args.length() != 6 || args[2] != "--project" || args[4] != "--goal" {
    usage()
    @sys.exit(2)
    return
  }
  guard @sys.realpath_native(args[3]) is Some(project_dir) else {
    @sys.write_stderr("Goal project is unavailable\n")
    @sys.exit(2)
    return
  }
  match
    @exec.advance_native_goal_publication(project_dir, @control.GoalId(args[5])) {
    Ok(outcome) => {
      @sys.write_stdout(outcome.to_json().stringify(indent=2) + "\n")
      @sys.exit(
        if outcome ==
          @workflow.GoalPublicationTickOutcome::GoalPublicationComplete {
          0
        } else {
          1
        },
      )
    }
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      @sys.exit(1)
    }
  }
}

///|
async fn run_goal_pull_request_command(args : Array[String]) -> Unit {
  let synthetic = args.length() == 7 && args[6] == "--synthetic"
  if (args.length() != 6 && !synthetic) ||
    args[2] != "--project" ||
    args[4] != "--goal" {
    usage()
    @sys.exit(2)
    return
  }
  guard @sys.realpath_native(args[3]) is Some(project_dir) else {
    @sys.write_stderr("Goal project is unavailable\n")
    @sys.exit(2)
    return
  }
  let result = if synthetic {
    @exec.advance_native_goal_pull_request_with_adapters(
      project_dir,
      @control.GoalId(args[5]),
      @exec.synthetic_pull_request_forge_adapters(),
    )
  } else {
    @exec.advance_native_goal_pull_request(
      project_dir,
      @control.GoalId(args[5]),
    )
  }
  match result {
    Ok(outcome) => {
      @sys.write_stdout(outcome.to_json().stringify(indent=2) + "\n")
      @sys.exit(
        if outcome ==
          @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete {
          0
        } else {
          1
        },
      )
    }
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      @sys.exit(1)
    }
  }
}

///|
async fn run_goal_finish_command(args : Array[String]) -> Unit {
  let synthetic = args.length() == 7 && args[6] == "--synthetic"
  if (args.length() != 6 && !synthetic) ||
    args[2] != "--project" ||
    args[4] != "--goal" {
    usage()
    @sys.exit(2)
    return
  }
  guard @sys.realpath_native(args[3]) is Some(project_dir) else {
    @sys.write_stderr("Goal project is unavailable\n")
    @sys.exit(2)
    return
  }
  let result = if synthetic {
    @exec.advance_native_goal_finalization_with_adapters(
      project_dir,
      @control.GoalId(args[5]),
      @exec.synthetic_pull_request_forge_adapters(),
    )
  } else {
    @exec.advance_native_goal_finalization(
      project_dir,
      @control.GoalId(args[5]),
    )
  }
  match result {
    Ok(outcome) => {
      @sys.write_stdout(outcome.to_json().stringify(indent=2) + "\n")
      @sys.exit(
        if outcome ==
          @workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded {
          0
        } else {
          1
        },
      )
    }
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      @sys.exit(1)
    }
  }
}

///|
async fn run_goal_tick_command(args : Array[String]) -> Unit {
  let synthetic = args.length() == 5 && args[4] == "--synthetic"
  if (args.length() != 4 && !synthetic) || args[2] != "--project" {
    usage()
    @sys.exit(2)
    return
  }
  guard @sys.realpath_native(args[3]) is Some(project_dir) else {
    @sys.write_stderr("Goal project is unavailable\n")
    @sys.exit(2)
    return
  }
  let result = if synthetic {
    @exec.run_native_goal_execution_tick_with_forge(
      project_dir,
      @exec.synthetic_pull_request_forge_adapters(),
    )
  } else {
    @exec.run_native_goal_execution_tick(project_dir)
  }
  match result {
    Ok(outcome) => {
      @sys.write_stdout(outcome.to_json().stringify(indent=2) + "\n")
      @sys.exit(0)
    }
    Err(error) => {
      @sys.write_stderr(error.message() + "\n")
      @sys.exit(1)
    }
  }
}

///|
fn usage() -> Unit {
  @sys.write_stderr(
    "usage: choir_conformance hermetic\n" +
    "       choir_conformance harness --surface <claude-cli|codex-cli> " +
    "--profile subscription\n" +
    "       choir_conformance harness --surface claude-cli " +
    "--profile subscription --synthetic-startup\n" +
    "       choir_conformance harness --surface claude-cli " +
    "--profile subscription --live\n" +
    "       choir_conformance harness --surface codex-cli " +
    "--profile subscription --live\n" +
    "       choir_conformance harness --surface codex-cli " +
    "--profile subscription --driver-live\n" +
    "       choir_conformance harness --surface codex-cli " +
    "--profile subscription --driver-recovery-live\n" +
    "       choir_conformance conductor --start-live\n" +
    "       choir_conformance sandbox --runtime boxlite --live\n" +
    "       choir_conformance sandbox --runtime boxlite --take-live\n" +
    "       choir_conformance e2e --fixture " +
    "<part-lifecycle|native-part-lifecycle|native-codex-part-lifecycle|" +
    "native-codex-cancellation|mixed-provider-goal|parallel-promotion>\n" +
    "       choir_conformance e2e --project <path> --draft <json-path>\n" +
    "       choir_conformance status --project <path> --goal <goal-id>\n" +
    "       choir_conformance publish --project <path> --goal <goal-id>\n" +
    "       choir_conformance pull-request --project <path> --goal <goal-id>\n" +
    "       choir_conformance pull-request --project <path> --goal <goal-id> --synthetic\n" +
    "       choir_conformance finish --project <path> --goal <goal-id>\n" +
    "       choir_conformance finish --project <path> --goal <goal-id> --synthetic\n" +
    "       choir_conformance tick --project <path>\n" +
    "       choir_conformance tick --project <path> --synthetic\n" +
    "       choir_conformance cancel --project <path> --goal <goal-id>\n",
  )
}

///|
fn main {
  let args = @env.args()
  if args.length() == 2 && args[1] == "hermetic" {
    @sys.exit(run_hermetic())
  } else if args.length() >= 2 && args[1] == "harness" {
    run_harness_command(args)
  } else if args.length() >= 2 && args[1] == "conductor" {
    run_conductor_command(args)
  } else if args.length() >= 2 && args[1] == "sandbox" {
    run_sandbox_command(args)
  } else if args.length() >= 2 && args[1] == "e2e" {
    @async.run_async_main(async fn() { run_end_to_end_command(args) })
  } else if args.length() >= 2 && args[1] == "status" {
    run_goal_status_command(args)
  } else if args.length() >= 2 && args[1] == "publish" {
    @async.run_async_main(async fn() { run_goal_publish_command(args) })
  } else if args.length() >= 2 && args[1] == "pull-request" {
    @async.run_async_main(async fn() { run_goal_pull_request_command(args) })
  } else if args.length() >= 2 && args[1] == "finish" {
    @async.run_async_main(async fn() { run_goal_finish_command(args) })
  } else if args.length() >= 2 && args[1] == "tick" {
    @async.run_async_main(async fn() { run_goal_tick_command(args) })
  } else if args.length() >= 2 && args[1] == "cancel" {
    run_goal_cancel_command(args)
  } else {
    usage()
    @sys.exit(2)
  }
}

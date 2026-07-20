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
    [@conformance.runner_dependency_contract_case()],
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
fn probe_mcp_launch() -> Result[(String, Array[String]), @types.ChoirError] {
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
  Ok((node, [script]))
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
    @async.run_async_main(async fn() {
      @sys.exit(run_surface_declaration(@harness.ProviderSurface::CodexCli))
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
  source : String,
  source_digest : @control.Digest,
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
      source,
      source_digest,
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
  match @exec.destroy_native_boxlite_take(take) {
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
    "bridge_probe": bridge_probe.to_json(),
    "inspection": inspected.to_json(),
  })
}

///|
async fn run_boxlite_take_live() -> Int {
  let root = "/tmp/choir-v2-take-live-" + @sys.get_pid().to_string()
  let source = root + "/staging/source"
  let source_digest = @control.Digest(
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  if !@sys.create_dir_all(source) ||
    !@sys.write_file_sync(
      source + "/.choir-source-root",
      source_digest.0 + "\n",
    ) ||
    !@sys.write_file_sync(source + "/README.md", "sandbox fixture\n") {
    @sys.write_stderr("failed to create dedicated Take sandbox root\n")
    return 1
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
    server, active_server, moon_home, source, source_digest,
  )
  let cleanup = @exec.cleanup_native_boxlite_server(active_server.val)
  ignore(@sys.rm_rf(root))
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
async fn run_end_to_end_command(args : Array[String]) -> Unit {
  if args.length() != 4 || args[2] != "--fixture" {
    usage()
    @sys.exit(2)
  }
  match args[3] {
    "one-part" => {
      let root = "/tmp/choir-conformance-one-part-" + @sys.get_pid().to_string()
      if !@sys.create_dir_all(root) {
        @sys.write_stderr("failed to create one-Part conformance root\n")
        @sys.exit(1)
      }
      let report = @exec.run_one_part_conformance_fixture(root)
      ignore(@sys.rm_rf(root))
      @sys.write_stdout(report.to_json().stringify(indent=2) + "\n")
      @sys.exit(if report.passed { 0 } else { 1 })
    }
    "three-part" => {
      let report = @conformance.run_multi_part_conformance_fixture()
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
    "       choir_conformance sandbox --runtime boxlite --live\n" +
    "       choir_conformance sandbox --runtime boxlite --take-live\n" +
    "       choir_conformance e2e --fixture <one-part|three-part>\n",
  )
}

///|
fn main {
  let args = @env.args()
  if args.length() == 2 && args[1] == "hermetic" {
    @sys.exit(run_hermetic())
  } else if args.length() >= 2 && args[1] == "harness" {
    run_harness_command(args)
  } else if args.length() >= 2 && args[1] == "sandbox" {
    run_sandbox_command(args)
  } else if args.length() >= 2 && args[1] == "e2e" {
    @async.run_async_main(async fn() { run_end_to_end_command(args) })
  } else {
    usage()
    @sys.exit(2)
  }
}

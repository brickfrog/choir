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
fn run_sandbox_command(args : Array[String]) -> Unit {
  if args.length() == 5 &&
    args[2] == "--runtime" &&
    args[3] == "boxlite" &&
    args[4] == "--live" {
    @async.run_async_main(async fn() { @sys.exit(run_boxlite_live()) })
  } else {
    usage()
    @sys.exit(2)
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
    "       choir_conformance sandbox --runtime boxlite --live\n" +
    "e2e suites land behind their typed adapters\n",
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
  } else {
    usage()
    @sys.exit(2)
  }
}

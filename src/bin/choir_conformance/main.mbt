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
fn parse_surface(raw : String) -> @harness.ProviderSurface? {
  match raw {
    "claude-cli" => Some(@harness.ProviderSurface::ClaudeCli)
    "codex-cli" => Some(@harness.ProviderSurface::CodexCli)
    _ => None
  }
}

///|
fn run_harness_command(args : Array[String]) -> Unit {
  if args.length() == 6 &&
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
fn usage() -> Unit {
  @sys.write_stderr(
    "usage: choir_conformance hermetic\n" +
    "       choir_conformance harness --surface <claude-cli|codex-cli> " +
    "--profile subscription\n" +
    "live startup, sandbox, and e2e suites land behind their typed adapters\n",
  )
}

///|
fn main {
  let args = @env.args()
  if args.length() == 2 && args[1] == "hermetic" {
    @sys.exit(run_hermetic())
  } else if args.length() >= 2 && args[1] == "harness" {
    run_harness_command(args)
  } else {
    usage()
    @sys.exit(2)
  }
}

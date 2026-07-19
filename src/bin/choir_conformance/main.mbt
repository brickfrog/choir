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
fn usage() -> Unit {
  @sys.write_stderr(
    "usage: choir_conformance hermetic\n" +
    "live sandbox, harness, and e2e suites land behind their typed adapters\n",
  )
}

///|
fn main {
  let args = @env.args()
  if args.length() == 2 && args[1] == "hermetic" {
    @sys.exit(run_hermetic())
  } else {
    usage()
    @sys.exit(2)
  }
}

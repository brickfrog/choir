///|
fn test_dependencies(
  state_error? : Bool = false,
) -> @conformance.ConformanceDependencies {
  let clock = @ref.new(100L)
  let ids = @ref.new(0)
  {
    now: fn() {
      let current = clock.val
      clock.val = current + 1L
      current
    },
    next_id: fn(kind) {
      ids.val = ids.val + 1
      match kind {
        @conformance.ConformanceIdKind::ConformanceReportId =>
          "report-" + ids.val.to_string()
        @conformance.ConformanceIdKind::ConformanceRunId =>
          "run-" + ids.val.to_string()
        @conformance.ConformanceIdKind::ConformanceArtifactId =>
          "artifact-" + ids.val.to_string()
      }
    },
    fault_enabled: fn(point) {
      point == @conformance.FaultPoint::EventBeforeIngestTransaction
    },
    adapters: {
      read_state: fn(_) {
        if state_error {
          Err(@types.ChoirError::transport_error("state adapter failed"))
        } else {
          Ok(
            @conformance.StateObservation::StateSnapshot(
              @control.Digest("runner-contract-state"),
            ),
          )
        }
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
test "hermetic runner uses injected clock IDs adapters and fault source" {
  let report = @conformance.run_hermetic_suite(
    [@conformance.runner_dependency_contract_case()],
    test_dependencies(),
  )
  assert_eq(report.passed, 1)
  assert_eq(report.failed, 0)
  assert_eq(report.report_id, "report-3")
  assert_eq(report.generated_at, 102L)
  assert_eq(report.cases.length(), 1)
  let case = report.cases[0]
  assert_eq(case.run_id, "run-1")
  assert_eq(case.started_at, 100L)
  assert_eq(case.finished_at, 101L)
  assert_eq(case.evidence.length(), 5)
  match case.status {
    @conformance.ConformanceCaseStatus::ConformanceCasePassed => ()
    _ => fail("injected runner contract did not pass")
  }
}

///|
test "adapter failures become typed failed reports" {
  let report = @conformance.run_hermetic_suite(
    [@conformance.runner_dependency_contract_case()],
    test_dependencies(state_error=true),
  )
  assert_eq(report.passed, 0)
  assert_eq(report.failed, 1)
  match report.cases[0].status {
    @conformance.ConformanceCaseStatus::ConformanceCaseFailed(
      @conformance.ConformanceFailureKind::CaseExecutionFailed,
      wire_kind,
      message
    ) => {
      assert_eq(wire_kind, "transport_error")
      assert_true(message.contains("state adapter failed"))
    }
    _ => fail("adapter failure did not produce a failed report")
  }
}

///|
test "multi-Part fixture exercises conflict and stable promotion order" {
  let report = @conformance.run_multi_part_conformance_fixture()
  assert_true(report.passed)
  assert_eq(report.initial_admission_count, 2)
  assert_true(report.running_conflict_deferred)
  assert_eq(report.promotion_count, 3)
  assert_true(report.promotion_head_chain_valid)
}

///|
test "generated DAG fixture covers permutations and concurrency limits" {
  let report = match @conformance.run_generated_dag_conformance_fixture() {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(report.graph_count, 4)
  assert_eq(report.schedule_run_count, 32)
  assert_eq(report.promotion_run_count, 8)
  assert_eq(report.part_evaluation_count, 680)
}

///|
test "selection fixture records exact typed rejection and acceptance sets" {
  let report = @conformance.run_hermetic_case(
    @conformance.selection_exact_snapshot_case(),
    {
      now: fn() { 1L },
      next_id: fn(_) { "selection-fixture-id" },
      fault_enabled: fn(_) { false },
      adapters: {
        read_state: fn(_) { Ok(@conformance.StateObservation::StateMissing) },
        read_artifact: fn(_) {
          Ok(@conformance.ArtifactObservation::ArtifactMissing)
        },
        read_effect_witness: fn(_) {
          Ok(@conformance.EffectWitnessObservation::EffectWitnessAbsent)
        },
      },
    },
  )
  assert_true(
    report.status is @conformance.ConformanceCaseStatus::ConformanceCasePassed,
  )
  assert_eq(report.evidence, [
    @conformance.ConformanceEvidence::ObservedSelectionCase(
      @conformance.SelectionConformanceKind::SelectionExactSnapshot,
      1,
      5,
      0,
    ),
  ])
}

///|
test "branch initialization fixture covers crash and cancellation ordering" {
  let clock = @ref.new(1L)
  let report = @conformance.run_hermetic_case(
    @conformance.branch_initialization_faults_case(),
    {
      now: fn() {
        clock.val = clock.val + 1L
        clock.val
      },
      next_id: fn(_) { "branch-initialization-fixture-id" },
      fault_enabled: fn(_) { true },
      adapters: {
        read_state: fn(_) { Ok(@conformance.StateObservation::StateMissing) },
        read_artifact: fn(_) {
          Ok(@conformance.ArtifactObservation::ArtifactMissing)
        },
        read_effect_witness: fn(_) {
          Ok(@conformance.EffectWitnessObservation::EffectWitnessAbsent)
        },
      },
    },
  )
  assert_true(
    report.status is @conformance.ConformanceCaseStatus::ConformanceCasePassed,
  )
  assert_eq(report.evidence, [
    @conformance.ConformanceEvidence::ObservedBranchInitializationCase(
      @conformance.BranchInitializationConformanceKind::BranchInitializationRecoveryMatrix,
      1,
      true,
      true,
      true,
    ),
  ])
}

///|
test "integration conflict repair preserves history and resets assurance" {
  let report = @conformance.run_hermetic_case(
    @conformance.integration_conflict_repair_case(),
    {
      now: fn() { 1L },
      next_id: fn(_) { "conflict-repair-fixture-id" },
      fault_enabled: fn(_) { false },
      adapters: {
        read_state: fn(_) { Ok(@conformance.StateObservation::StateMissing) },
        read_artifact: fn(_) {
          Ok(@conformance.ArtifactObservation::ArtifactMissing)
        },
        read_effect_witness: fn(_) {
          Ok(@conformance.EffectWitnessObservation::EffectWitnessAbsent)
        },
      },
    },
  )
  assert_eq(
    report.status,
    @conformance.ConformanceCaseStatus::ConformanceCasePassed,
  )
  assert_eq(report.evidence, [
    @conformance.ConformanceEvidence::ObservedIntegrationConflictRepair(
      2,
      3,
      true,
      true,
    ),
  ])
}

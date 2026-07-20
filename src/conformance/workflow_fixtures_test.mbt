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

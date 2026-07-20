///|
test "multi-Part fixture exercises conflict and stable promotion order" {
  let report = @conformance.run_multi_part_conformance_fixture()
  assert_true(report.passed)
  assert_eq(report.initial_admission_count, 2)
  assert_true(report.running_conflict_deferred)
  assert_eq(report.promotion_count, 3)
  assert_true(report.promotion_head_chain_valid)
}

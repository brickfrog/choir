///|
async test "one-Part conformance fixture survives restart and persistence faults" {
  let root = "/tmp/choir-workflow-conformance-test-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  assert_true(@sys.create_dir_all(root))
  let report = @exec.run_one_part_conformance_fixture(root)
  ignore(@sys.rm_rf(root))
  assert_true(report.passed)
  assert_eq(report.effect_receipt_count, 12)
  assert_eq(report.verification_receipt_count, 1)
  assert_eq(report.audit_receipt_count, 1)
  assert_eq(report.integration_receipt_count, 1)
  assert_eq(report.restart_executed_effect_count, 0)
  assert_eq(report.persistence_boundaries_checked, 7)
}

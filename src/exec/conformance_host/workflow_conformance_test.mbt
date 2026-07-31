///|
async test "real exec integration: workflow survives every persistence boundary" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-workflow-conformance"
  ignore(@sys.rm_rf(root))
  assert_true(@sys.create_dir_all(root))
  let report = run_part_conformance_fixture(root)
  ignore(@sys.rm_rf(root))
  assert_true(report.passed)
  assert_eq(report.effect_receipt_count, 13)
  assert_eq(report.verification_receipt_count, 1)
  assert_eq(report.audit_receipt_count, 1)
  assert_eq(report.integration_receipt_count, 1)
  assert_eq(report.restart_executed_effect_count, 0)
  assert_eq(report.persistence_boundaries_checked, 8)
  assert_true(report.audit_result_recovery_checked)
  assert_true(report.audit_receipt_recovery_checked)
  assert_true(report.audit_protocol_conflict_checked)
}

///|
async test "real exec integration: scale fixture preserves bounded concurrency" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let root = "/tmp/choir-scale-conformance"
  ignore(@sys.rm_rf(root))
  let report = run_scale_mixed_conformance_fixture(root)
  ignore(@sys.rm_rf(root))
  assert_true(report.passed)
  assert_eq(report.part_count, 6)
  assert_eq(report.concurrency_limits, [1, 2, 4])
  assert_eq(report.observed_parallelism, [1, 2, 2])
  assert_eq(report.part_verification_receipt_count, 6)
  assert_eq(report.part_audit_receipt_count, 6)
  assert_eq(report.integration_receipt_count, 6)
  assert_eq(report.goal_verification_receipt_count, 1)
  assert_eq(report.goal_audit_receipt_count, 1)
  assert_eq(report.publication_receipt_count, 1)
  assert_eq(report.pull_request_receipt_count, 1)
  assert_true(report.semantic_projection_digest is Some(_))
}

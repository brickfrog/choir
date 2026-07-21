///|
fn event_case_test_dependencies() -> @conformance.ConformanceDependencies {
  let clock = @ref.new(1L)
  let ids = @ref.new(0)
  {
    now: fn() {
      let value = clock.val
      clock.val = value + 1L
      value
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
      point ==
      @conformance.FaultPoint::BranchInitAfterIntentBeforeAuthorized ||
      point ==
      @conformance.FaultPoint::BranchInitAfterAuthorizedBeforeRefTransaction ||
      point == @conformance.FaultPoint::BranchInitDuringRefTransaction ||
      point ==
      @conformance.FaultPoint::BranchInitAfterRefTransactionBeforeReceipt ||
      point == @conformance.FaultPoint::EventBeforeIngestTransaction ||
      point ==
      @conformance.FaultPoint::EventAfterIngestTransactionBeforeSourceAck ||
      point == @conformance.FaultPoint::EventAfterSourceAckBeforeNextRead ||
      point ==
      @conformance.FaultPoint::AuditAfterResultTransactionBeforeReceiptTransaction ||
      point ==
      @conformance.FaultPoint::AuditAfterReceiptTransactionBeforeGateEvaluation
    },
    adapters: {
      read_state: fn(_) { Ok(@conformance.StateObservation::StateMissing) },
      read_artifact: fn(_) {
        Ok(@conformance.ArtifactObservation::ArtifactMissing)
      },
      read_effect_witness: fn(_) {
        Ok(@conformance.EffectWitnessObservation::EffectWitnessAbsent)
      },
    },
  }
}

///|
test "registered pure conformance cases satisfy their typed oracles" {
  let report = @conformance.run_hermetic_suite(
    [
      @conformance.event_duplicate_conflict_case(),
      @conformance.event_cursor_gap_case(),
      @conformance.event_late_terminal_case(),
      @conformance.event_conflicting_terminal_case(),
      @conformance.event_before_ingest_transaction_case(),
      @conformance.event_after_ingest_transaction_before_source_ack_case(),
      @conformance.event_after_source_ack_before_next_read_case(),
      @conformance.event_nonresumable_process_loss_case(),
      @conformance.event_backpressure_case(),
      @conformance.event_redaction_case(),
      @conformance.selection_exact_snapshot_case(),
      @conformance.integration_conflict_repair_case(),
      @conformance.selection_revision_invalidation_case(),
      @conformance.audit_gate_missing_is_passive_case(),
      @conformance.audit_independence_rejects_author_case(),
      @conformance.audit_subject_staleness_case(),
      @conformance.audit_protocol_conflict_case(),
      @conformance.audit_result_reconcile_case(),
      @conformance.audit_receipt_replay_case(),
      @conformance.cancellation_part_effect_ordering_case(),
      @conformance.cancellation_ordering_matrix_case(),
      @conformance.ownership_normalization_case(),
      @conformance.ownership_conflict_matrix_case(),
      @conformance.ownership_underclaim_case(),
      @conformance.ownership_rename_delete_generate_case(),
      @conformance.process_validation_matrix_case(),
      @conformance.process_authority_fence_case(),
      @conformance.process_canonical_dispatch_case(),
    ],
    event_case_test_dependencies(),
  )
  assert_eq(report.passed, 28)
  assert_eq(report.failed, 0)
  assert_eq(report.cases.length(), 28)
}

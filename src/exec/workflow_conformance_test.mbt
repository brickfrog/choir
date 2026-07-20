///|
async test "real exec integration: Part conformance survives restart and faults" {
  let root = "/tmp/choir-workflow-conformance-test-" +
    @sys.get_pid().to_string()
  ignore(@sys.rm_rf(root))
  assert_true(@sys.create_dir_all(root))
  let report = @exec.run_part_conformance_fixture(root)
  ignore(@sys.rm_rf(root))
  assert_true(report.passed)
  assert_eq(report.effect_receipt_count, 12)
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
fn workflow_authorized_implementation_dispatch() -> @workflow.PartWorkflowSnapshot raise {
  let advance = fn(snapshot : @workflow.PartWorkflowSnapshot) {
    let intent = @workflow.plan_next_part_effect(snapshot).unwrap().unwrap()
    let planned = @workflow.persist_planned_part_effect(snapshot, intent).unwrap()
    let authorized = @workflow.authorize_pending_part_effect(planned).unwrap()
    let observation = workflow_driver_observation(authorized, {
      ..intent,
      lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
    }).unwrap()
    @workflow.apply_part_effect_observation(
      authorized,
      observation,
      110L,
      fn(_) { true },
      fn(_) { true },
    ).unwrap()
  }
  let prepared = advance(workflow_store_fixture())
  let running = advance(prepared)
  let dispatch = @workflow.plan_next_part_effect(running).unwrap().unwrap()
  assert_true(
    dispatch.kind is @workflow.PartEffectKind::DispatchImplementation(_, _),
  )
  @workflow.authorize_pending_part_effect(
    @workflow.persist_planned_part_effect(running, dispatch).unwrap(),
  ).unwrap()
}

///|
test "provider effect witnesses retain the first terminal observation" {
  let repository = workflow_repository("effect-witness")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize effect witness repository")
  }
  let authorized = workflow_authorized_implementation_dispatch()
  let intent = authorized.pending_effect.unwrap()
  let observation = workflow_driver_observation(authorized, intent).unwrap()
  let first = @workflow.record_part_effect_witness(
    repository, adapters, authorized, intent, observation, 120L,
  ).unwrap()
  assert_eq(
    @workflow.record_part_effect_witness(
      repository, adapters, authorized, intent, observation, 120L,
    ).unwrap(),
    first,
  )
  let receipt_count_before_conflict = authorized.effect_receipts.length()
  match
    @workflow.record_part_effect_witness(
      repository, adapters, authorized, intent, observation, 121L,
    ) {
    Err(error) => assert_true(error.is_provider_protocol_violation())
    Ok(_) => fail("conflicting effect witness replaced the durable row")
  }
  assert_eq(authorized.effect_receipts.length(), receipt_count_before_conflict)
  assert_true(authorized.audit_receipt is None)
  assert_eq(
    @workflow.load_part_effect_witness(repository, adapters, intent).unwrap(),
    Some(first),
  )
  clean_workflow_repository(repository)
}

///|
async test "driver durably records a provider protocol violation" {
  let repository = workflow_repository("provider-protocol-violation")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize protocol-violation repository")
  }
  let authorized = workflow_authorized_implementation_dispatch()
  ignore(
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: authorized,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let result = @workflow.resume_part_workflow(
    repository,
    adapters,
    authorized.workflow_id,
    workflow_driver_dependencies(
      execute_count,
      reconcile_count,
      fn(_) { None },
      async fn(_, _) {
        Err(
          @types.ChoirError::provider_protocol_violation(
            "conflicting terminal provider result",
          ),
        )
      },
    ),
  ).unwrap()
  assert_eq(
    result.outcome,
    @workflow.PartWorkflowRunOutcome::PartRunRecoveryUncertain,
  )
  assert_eq(execute_count.val, 0)
  assert_eq(reconcile_count.val, 1)
  assert_eq(
    result.snapshot.stage,
    @workflow.PartWorkflowStage::PartRecoveryUncertain,
  )
  let restarted = @workflow.load_part_snapshot(
      repository,
      adapters,
      authorized.workflow_id,
    )
    .unwrap()
    .unwrap()
  assert_eq(restarted.snapshot, result.snapshot)
  clean_workflow_repository(repository)
}

///|
async test "driver durably records provider event ingestion overflow" {
  let repository = workflow_repository("provider-event-overflow")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize event-overflow repository")
  }
  let authorized = workflow_authorized_implementation_dispatch()
  ignore(
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: authorized,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let result = @workflow.resume_part_workflow(
    repository,
    adapters,
    authorized.workflow_id,
    workflow_driver_dependencies(
      @ref.new(0),
      @ref.new(0),
      fn(_) { None },
      async fn(_, _) {
        Err(
          @types.ChoirError::event_ingestion_overflow(
            "provider event spool exceeded its bound",
          ),
        )
      },
    ),
  ).unwrap()
  assert_eq(
    result.outcome,
    @workflow.PartWorkflowRunOutcome::PartRunRecoveryUncertain,
  )
  assert_eq(
    result.snapshot.stage,
    @workflow.PartWorkflowStage::PartRecoveryUncertain,
  )
  assert_true(
    result.snapshot.implementation_take.lifecycle
    is @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeRecoveryUncertain(
        @control.TakeUncertaintyReason::TakeCursorGap
      )
    ),
  )
  assert_true(
    result.snapshot.harness_sessions.any(fn(session) {
      session.id == result.snapshot.identities.implementation_session.id &&
      session.lifecycle ==
      @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain
    }),
  )
  assert_true(
    result.snapshot.pending_effect
    is Some({
      lifecycle: @workflow.PartEffectLifecycle::PartEffectUncertain,
      ..
    }),
  )
  assert_eq(
    @workflow.load_part_snapshot(
      repository,
      adapters,
      authorized.workflow_id,
    ).unwrap().unwrap().snapshot,
    result.snapshot,
  )
  clean_workflow_repository(repository)
}

///|
async test "driver durably records nonresumable provider process loss" {
  let repository = workflow_repository("provider-process-loss")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize process-loss repository")
  }
  let authorized = workflow_authorized_implementation_dispatch()
  ignore(
    @workflow.persist_part_snapshot(repository, adapters, {
      snapshot: authorized,
      expected_store_version: None,
      fault_point: None,
    }).unwrap(),
  )
  let result = @workflow.resume_part_workflow(
    repository,
    adapters,
    authorized.workflow_id,
    workflow_driver_dependencies(
      @ref.new(0),
      @ref.new(0),
      fn(_) { None },
      async fn(_, _) {
        Err(
          @types.ChoirError::provider_process_lost(
            "nonresumable provider process disappeared",
          ),
        )
      },
    ),
  ).unwrap()
  assert_eq(
    result.outcome,
    @workflow.PartWorkflowRunOutcome::PartRunRecoveryUncertain,
  )
  assert_true(
    result.snapshot.implementation_take.lifecycle
    is @control.TakeLifecycle::TakeTerminal(
      @control.TakeTerminalDisposition::TakeRecoveryUncertain(
        @control.TakeUncertaintyReason::TakeEffectUncertain
      )
    ),
  )
  assert_true(
    result.snapshot.harness_sessions.any(fn(session) {
      session.id == result.snapshot.identities.implementation_session.id &&
      session.lifecycle ==
      @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain
    }),
  )
  assert_eq(
    @workflow.load_part_snapshot(
      repository,
      adapters,
      authorized.workflow_id,
    ).unwrap().unwrap().snapshot,
    result.snapshot,
  )
  clean_workflow_repository(repository)
}

///|
async fn prepare_goal_finalization_fixture(
  label : String,
) -> (
  String,
  String,
  @control.GoalId,
  Ref[@workflow.RemotePullRequestSnapshot?],
  @goal_host.NativePullRequestForgeAdapters,
) {
  let fixture = prove_publication_fault_recovery(
    "finalization-" + label,
    @workflow.GoalPublicationFaultPoint::PublicationAfterIntentBeforeAuthorized,
    @workflow.BranchPublicationState::BranchPublicationPlanned,
    false,
  )
  let remote_pull_request : Ref[@workflow.RemotePullRequestSnapshot?] = Ref(
    None,
  )
  let forge : @goal_host.NativePullRequestForgeAdapters = {
    resolve_repository: _ => Ok("choir/finalization-fixture"),
    lookup: (_, _, _) => {
      match remote_pull_request.val {
        Some(snapshot) =>
          @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
            snapshot,
          )
        None => @workflow.PullRequestLookupObservation::PullRequestNoMatch
      }
    },
    create: (_, _, intent, document) => {
      remote_pull_request.val = Some(
        pull_request_fault_snapshot(intent, document),
      )
    },
    merge: (_, _, _, _) => {
      @workflow.PullRequestMergeDispatchObservation::PullRequestMergeDispatchAccepted
    },
    neutralize: (_, _, _, _) => {
      remote_pull_request.val = remote_pull_request.val.map(fn(snapshot) {
        {
          ..snapshot,
          state: @workflow.RemotePullRequestState::RemotePullRequestClosed,
          auto_merge_enabled: false,
        }
      })
    },
  }
  let pull_request_outcome = match
    @goal_host.advance_native_goal_pull_request_with_adapters(
      fixture.0,
      fixture.2,
      forge,
    ) {
    Ok(value) => value
    Err(error) => fail(label + ": PR setup: " + error.message())
  }
  assert_eq(
    pull_request_outcome,
    @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete,
  )
  (fixture.0, fixture.1, fixture.2, remote_pull_request, forge)
}

///|
fn goal_execution_outbox_key(
  goal_id : @control.GoalId,
  version : Int,
) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey(
    "goal-run:" +
    @storage.digest_text(@storage.artifact_digest(@utf8.encode(goal_id.0))) +
    ":state:" +
    version.to_string(),
  )
}

///|
pub(all) enum NativePullRequestRemoteStateCase {
  PullRequestRemoteExact
  PullRequestRemoteClosed
  PullRequestRemoteRetargeted
  PullRequestRemoteHeadChanged
  PullRequestRemoteEdited
  PullRequestRemoteDuplicate
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativePullRequestRemoteStateObservation {
  case : NativePullRequestRemoteStateCase
  outcome : @workflow.GoalFinalizationTickOutcome
  decision : @workflow.PullRequestReadinessDecision
  goal_state : @workflow.GoalExecutionState
  passed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativePullRequestRemoteStateConformanceReport {
  observations : Array[NativePullRequestRemoteStateObservation]
  passed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
fn pull_request_remote_state_label(
  case : NativePullRequestRemoteStateCase,
) -> String {
  match case {
    PullRequestRemoteExact => "exact"
    PullRequestRemoteClosed => "closed"
    PullRequestRemoteRetargeted => "retargeted"
    PullRequestRemoteHeadChanged => "head-changed"
    PullRequestRemoteEdited => "edited"
    PullRequestRemoteDuplicate => "duplicate"
  }
}

///|
async fn observe_pull_request_remote_state(
  case : NativePullRequestRemoteStateCase,
) -> NativePullRequestRemoteStateObservation {
  let fixture = prepare_goal_finalization_fixture(
    pull_request_remote_state_label(case),
  )
  guard fixture.3.val is Some(snapshot) else {
    fail("remote-state fixture has no pull request")
  }
  let lookup = match case {
    PullRequestRemoteExact =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
        snapshot,
      )
    PullRequestRemoteClosed =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..snapshot,
        state: @workflow.RemotePullRequestState::RemotePullRequestClosed,
      })
    PullRequestRemoteRetargeted =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..snapshot,
        base_ref: @workflow.GitRefName("refs/heads/release"),
      })
    PullRequestRemoteHeadChanged =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..snapshot,
        observed_head_oid: @control.GitOid("remote-state-other-head"),
      })
    PullRequestRemoteEdited =>
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch({
        ..snapshot,
        title_digest: @storage.artifact_digest(@utf8.encode("edited title")),
        body_digest: @storage.artifact_digest(@utf8.encode("edited body")),
      })
    PullRequestRemoteDuplicate =>
      @workflow.PullRequestLookupObservation::PullRequestMultipleMarkerMatches
  }
  let forge : @goal_host.NativePullRequestForgeAdapters = {
    resolve_repository: fixture.4.resolve_repository,
    lookup: (_, _, _) => lookup,
    create: fixture.4.create,
    merge: fixture.4.merge,
    neutralize: fixture.4.neutralize,
  }
  let outcome = match
    @goal_host.advance_native_goal_finalization_with_adapters(
      fixture.0,
      fixture.2,
      forge,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    ) {
    Ok(value) => value
    Err(error) => fail("remote-state finalization: " + error.message())
  }
  let repository = @goal_host.native_goal_repository(fixture.0)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  let decision = @workflow.load_goal_finalization_record(
      repository,
      adapters,
      fixture.2,
    )
    .unwrap()
    .unwrap().record.readiness.decision
  let goal_state = @workflow.load_goal_execution_record(
      repository,
      adapters,
      fixture.2,
    )
    .unwrap()
    .unwrap().record.state
  let passed = match case {
    // An open, exact pull request is Choir's deliverable: the Goal succeeds
    // at PR-ready and does not wait to observe a merge.
    PullRequestRemoteExact | PullRequestRemoteEdited =>
      outcome ==
      @workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded &&
      decision == @workflow.PullRequestReadinessDecision::PullRequestReady &&
      goal_state == @workflow.GoalExecutionState::GoalExecutionSucceeded
    PullRequestRemoteClosed =>
      outcome ==
      @workflow.GoalFinalizationTickOutcome::GoalFinalizationNeedsUserInput &&
      decision ==
      @workflow.PullRequestReadinessDecision::PullRequestReadinessNeedsInput(
        @workflow.PullRequestReadinessNeedsInputReason::PullRequestNotOpen,
      ) &&
      goal_state == @workflow.GoalExecutionState::GoalExecutionAssured
    PullRequestRemoteRetargeted | PullRequestRemoteHeadChanged =>
      outcome == @workflow.GoalFinalizationTickOutcome::GoalFinalizationDrifted &&
      decision ==
      @workflow.PullRequestReadinessDecision::PullRequestReadinessDrift(
        @workflow.PullRequestReadinessDriftReason::PullRequestHeadOrBaseChanged,
      ) &&
      goal_state == @workflow.GoalExecutionState::GoalExecutionAssured
    PullRequestRemoteDuplicate =>
      outcome ==
      @workflow.GoalFinalizationTickOutcome::GoalFinalizationAmbiguous &&
      decision ==
      @workflow.PullRequestReadinessDecision::PullRequestReadinessAmbiguous &&
      goal_state == @workflow.GoalExecutionState::GoalExecutionAssured
  }
  ignore(@sys.rm_rf(fixture.0))
  ignore(@sys.rm_rf(fixture.1))
  { case, outcome, decision, goal_state, passed }
}

///|
pub async fn run_native_pull_request_remote_state_conformance() -> NativePullRequestRemoteStateConformanceReport {
  let observations : Array[NativePullRequestRemoteStateObservation] = []
  let cases = [
    NativePullRequestRemoteStateCase::PullRequestRemoteExact,
    NativePullRequestRemoteStateCase::PullRequestRemoteClosed,
    NativePullRequestRemoteStateCase::PullRequestRemoteRetargeted,
    NativePullRequestRemoteStateCase::PullRequestRemoteHeadChanged,
    NativePullRequestRemoteStateCase::PullRequestRemoteEdited,
    NativePullRequestRemoteStateCase::PullRequestRemoteDuplicate,
  ]
  for case in cases {
    observations.push(observe_pull_request_remote_state(case))
  }
  {
    observations,
    passed: observations.length() == cases.length() &&
    observations.all(fn(observation) { observation.passed }),
  }
}

///|
async test "real exec integration: final PR remote states have exact outcomes" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let report = run_native_pull_request_remote_state_conformance()
  assert_true(report.passed)
  assert_eq(report.observations.length(), 6)
}

///|
pub(all) struct NativeGoalFinalizationRaceConformanceReport {
  edit_before_response_accepted : Bool
  edit_after_response_did_not_retroactively_change_decision : Bool
  success_won_before_late_cancellation : Bool
  cancellation_won_after_ready_before_success : Bool
  terminal_outboxes_unique : Bool
  passed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub async fn run_native_goal_finalization_race_conformance() -> NativeGoalFinalizationRaceConformanceReport {
  let before = prepare_goal_finalization_fixture("edit-before-response")
  guard before.3.val is Some(before_snapshot) else {
    fail("pre-response fixture has no remote pull request")
  }
  before.3.val = Some({
    ..before_snapshot,
    body_digest: @storage.artifact_digest(
      @utf8.encode("reviewer edited the PR body"),
    ),
  })
  let before_outcome = match
    @goal_host.advance_native_goal_finalization_with_adapters(
      before.0,
      before.2,
      before.4,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    ) {
    Ok(value) => value
    Err(error) => fail("edit before response: " + error.message())
  }
  let before_repository = @goal_host.native_goal_repository(before.0)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  let before_goal_state = @workflow.load_goal_execution_record(
      before_repository,
      adapters,
      before.2,
    )
    .unwrap()
    .unwrap().record.state
  let edit_before_response_accepted = before_outcome ==
    @workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded &&
    before_goal_state == @workflow.GoalExecutionState::GoalExecutionSucceeded
  assert_true(edit_before_response_accepted)
  ignore(@sys.rm_rf(before.0))
  ignore(@sys.rm_rf(before.1))

  let after = prepare_goal_finalization_fixture("edit-after-response")
  guard after.3.val is Some(after_snapshot) else {
    fail("post-response fixture has no remote pull request")
  }
  let edit_after_response = Ref(true)
  let after_forge : @goal_host.NativePullRequestForgeAdapters = {
    resolve_repository: after.4.resolve_repository,
    lookup: (_, _, _) => {
      let observed = after.3.val.unwrap()
      if edit_after_response.val {
        edit_after_response.val = false
        after.3.val = Some({
          ..observed,
          body_digest: @storage.artifact_digest(
            @utf8.encode("body edited after the readiness observation"),
          ),
        })
      }
      @workflow.PullRequestLookupObservation::PullRequestUniqueMarkerMatch(
        observed,
      )
    },
    create: after.4.create,
    merge: after.4.merge,
    neutralize: after.4.neutralize,
  }
  let original_body_digest = after_snapshot.body_digest
  let after_outcome = match
    @goal_host.advance_native_goal_finalization_with_adapters(
      after.0,
      after.2,
      after_forge,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    ) {
    Ok(value) => value
    Err(error) => fail("edit after response: " + error.message())
  }
  guard after.3.val is Some(edited_snapshot) else {
    fail("post-response remote edit disappeared")
  }
  let edit_after_response_did_not_retroactively_change_decision = after_outcome ==
    @workflow.GoalFinalizationTickOutcome::GoalFinalizationSucceeded &&
    edited_snapshot.body_digest != original_body_digest
  assert_true(edit_after_response_did_not_retroactively_change_decision)
  let after_repository = @goal_host.native_goal_repository(after.0)
  let success_won_before_late_cancellation = @goal_host.cancel_native_goal(
      after.0,
      after.2,
      100L,
    ).unwrap() ==
    @workflow.GoalCancellationPersistenceResult::GoalCancellationTerminal(
      @workflow.GoalExecutionState::GoalExecutionSucceeded,
    )
  assert_true(success_won_before_late_cancellation)
  // Version 2 is the success advance from Assured.
  let success_outbox_present = (adapters.state.read_outbox)(
      after_repository.state_store,
      goal_execution_outbox_key(after.2, 2),
    ).unwrap()
    is Some(_)
  let success_next_outbox_absent = (adapters.state.read_outbox)(
      after_repository.state_store,
      goal_execution_outbox_key(after.2, 3),
    ).unwrap()
    is None
  assert_true(success_outbox_present && success_next_outbox_absent)
  ignore(@sys.rm_rf(after.0))
  ignore(@sys.rm_rf(after.1))

  let canceled = prepare_goal_finalization_fixture("cancellation-wins")
  // Inject the crash between the reviewable-PR observation and the success
  // transaction; a later cancellation must then win.
  assert_true(
    @goal_host.advance_native_goal_finalization_with_adapters(
      canceled.0,
      canceled.2,
      canceled.4,
      reconcile_sources=fn(_, _, _) { Ok(()) },
      fault=Some(
        @workflow.GoalFinalizationFaultPoint::PullRequestAfterReadinessObservationBeforeSuccessTransaction,
      ),
    )
    is Err(_),
  )
  let canceled_repository = @goal_host.native_goal_repository(canceled.0)
  let ready_before_race = @workflow.load_goal_finalization_record(
      canceled_repository,
      adapters,
      canceled.2,
    )
    .unwrap()
    .unwrap().record.readiness.decision ==
    @workflow.PullRequestReadinessDecision::PullRequestReady
  let cancellation_linearized = @goal_host.cancel_native_goal(
      canceled.0,
      canceled.2,
      200L,
    ).unwrap()
    is @workflow.GoalCancellationPersistenceResult::GoalCancellationPersisted(_)
  let success_rejected = @goal_host.advance_native_goal_finalization_with_adapters(
      canceled.0,
      canceled.2,
      canceled.4,
      reconcile_sources=fn(_, _, _) { Ok(()) },
    )
    is Err(_)
  let canceling_record = @workflow.load_goal_execution_record(
      canceled_repository,
      adapters,
      canceled.2,
    )
    .unwrap()
    .unwrap()
  let release_authorized = @workflow.authorize_goal_source_release(
    canceling_record.record,
    canceling_record.record.source_claims[0].part_id,
  ).unwrap()
  let canceling_record = @workflow.persist_goal_execution_transition(
    canceled_repository, adapters, canceling_record, release_authorized,
  ).unwrap()
  let released = @workflow.reconcile_goal_source_release(
    canceling_record.record,
    canceling_record.record.source_claims[0].part_id,
    @workflow.GoalSourceClaimObservation::GoalSourceUnclaimedExact,
    201L,
  ).unwrap()
  let canceling_record = @workflow.persist_goal_execution_transition(
    canceled_repository, adapters, canceling_record, released,
  ).unwrap()
  let canceled_record = match
    @workflow.persist_goal_cancellation_completion(
      canceled_repository, adapters, canceling_record,
    ) {
    Ok(value) => value.record
    Err(error) => fail("cancellation completion: " + error.message())
  }
  let cancellation_won_after_ready_before_success = ready_before_race &&
    cancellation_linearized &&
    success_rejected &&
    canceled_record.state == @workflow.GoalExecutionState::GoalExecutionCanceled
  assert_true(cancellation_won_after_ready_before_success)
  let cancellation_outbox_present = (adapters.state.read_outbox)(
      canceled_repository.state_store,
      goal_execution_outbox_key(canceled.2, canceled_record.durable_version),
    ).unwrap()
    is Some(_)
  let cancellation_next_outbox_absent = (adapters.state.read_outbox)(
      canceled_repository.state_store,
      goal_execution_outbox_key(canceled.2, canceled_record.durable_version + 1),
    ).unwrap()
    is None
  let terminal_outboxes_unique = success_outbox_present &&
    success_next_outbox_absent &&
    cancellation_outbox_present &&
    cancellation_next_outbox_absent
  assert_true(terminal_outboxes_unique)
  ignore(@sys.rm_rf(canceled.0))
  ignore(@sys.rm_rf(canceled.1))
  {
    edit_before_response_accepted,
    edit_after_response_did_not_retroactively_change_decision,
    success_won_before_late_cancellation,
    cancellation_won_after_ready_before_success,
    terminal_outboxes_unique,
    passed: edit_before_response_accepted &&
    edit_after_response_did_not_retroactively_change_decision &&
    success_won_before_late_cancellation &&
    cancellation_won_after_ready_before_success &&
    terminal_outboxes_unique,
  }
}

///|
async test "real exec integration: final PR readiness and terminal decisions linearize exactly" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let report = run_native_goal_finalization_race_conformance()
  assert_true(report.passed)
}

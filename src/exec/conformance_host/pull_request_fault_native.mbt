///|
fn pull_request_fault_snapshot(
  intent : @workflow.PullRequestIntent,
  document : @workflow.PullRequestDocument,
) -> @workflow.RemotePullRequestSnapshot {
  {
    remote_id: @workflow.RemotePullRequestId("PR_fault_" + intent.goal_id.0),
    number: @workflow.PullRequestNumber(1),
    url: @workflow.PullRequestUrl("https://example.invalid/choir/pull/1"),
    provider_repository_id: intent.canonical_repository_id,
    head_repository_id: intent.head_repository_id,
    head_ref: intent.head_ref,
    base_repository_id: intent.base_repository_id,
    base_ref: intent.base_ref,
    observed_head_oid: intent.expected_head_oid,
    state: @workflow.RemotePullRequestState::RemotePullRequestOpen,
    draft: document.draft,
    auto_merge_enabled: false,
    marker_state: @workflow.PullRequestMarkerState::PullRequestMarkerExact,
    title_digest: @storage.artifact_digest(@utf8.encode(document.title)),
    body_digest: @storage.artifact_digest(@utf8.encode(document.body)),
  }
}

///|
pub(all) struct NativePullRequestFaultObservation {
  fault : @workflow.GoalPullRequestFaultPoint
  interrupted_state : @workflow.PullRequestIntentState
  create_count : Int
  completion_expected : Bool
  expected_outcome_observed : Bool
  duplicate_free : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct NativePullRequestFaultConformanceReport {
  observations : Array[NativePullRequestFaultObservation]
  passed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
async fn prove_pull_request_fault_recovery(
  label : String,
  fault : @workflow.GoalPullRequestFaultPoint,
  expected_state : @workflow.PullRequestIntentState,
  create_expected : Bool,
  completion_expected : Bool,
) -> NativePullRequestFaultObservation {
  let fixture = prove_publication_fault_recovery(
    "pull-request-" + label,
    @workflow.GoalPublicationFaultPoint::PublicationAfterIntentBeforeAuthorized,
    @workflow.BranchPublicationState::BranchPublicationPlanned,
    false,
  )
  let root = fixture.0
  let remote = fixture.1
  let goal_id = fixture.2
  let created = Ref(0)
  let remote_pull_request : Ref[@workflow.RemotePullRequestSnapshot?] = Ref(
    None,
  )
  let forge : @goal_host.NativePullRequestForgeAdapters = {
    resolve_repository: _ => Ok("choir/fault-fixture"),
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
      created.val = created.val + 1
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
  assert_true(
    @goal_host.advance_native_goal_pull_request_with_adapters(
      root,
      goal_id,
      forge,
      fault=Some(fault),
    )
    is Err(_),
  )
  let repository = @goal_host.native_goal_repository(root)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  let interrupted = @workflow.load_goal_pull_request_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record
  assert_eq(interrupted.intent.state, expected_state)
  assert_eq(created.val > 0, create_expected)
  let recovered = @goal_host.advance_native_goal_pull_request_with_adapters(
    root, goal_id, forge,
  ).unwrap()
  let durable = @workflow.load_goal_pull_request_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record
  if completion_expected {
    assert_eq(
      recovered,
      @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete,
    )
    assert_eq(
      durable.intent.state,
      @workflow.PullRequestIntentState::PullRequestReceipted,
    )
    assert_true(durable.receipt is Some(_))
    assert_eq(created.val, 1)
    assert_eq(
      @goal_host.advance_native_goal_pull_request_with_adapters(
        root, goal_id, forge,
      ).unwrap(),
      @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete,
    )
    assert_eq(created.val, 1)
  } else {
    assert_eq(
      recovered,
      @workflow.GoalPullRequestTickOutcome::GoalPullRequestRecoveryUncertain,
    )
    assert_eq(
      durable.intent.state,
      @workflow.PullRequestIntentState::PullRequestRemoteCreateUncertain,
    )
    assert_true(durable.receipt is None)
    assert_eq(created.val, 0)
  }
  assert_eq(
    @workflow.load_goal_execution_record(repository, adapters, goal_id)
    .unwrap()
    .unwrap().record.state,
    @workflow.GoalExecutionState::GoalExecutionAssured,
  )
  let observation = {
    fault,
    interrupted_state: interrupted.intent.state,
    create_count: created.val,
    completion_expected,
    expected_outcome_observed: if completion_expected {
      recovered == @workflow.GoalPullRequestTickOutcome::GoalPullRequestComplete &&
      durable.intent.state ==
      @workflow.PullRequestIntentState::PullRequestReceipted &&
      durable.receipt is Some(_)
    } else {
      recovered ==
      @workflow.GoalPullRequestTickOutcome::GoalPullRequestRecoveryUncertain &&
      durable.intent.state ==
      @workflow.PullRequestIntentState::PullRequestRemoteCreateUncertain &&
      durable.receipt is None
    },
    duplicate_free: created.val <= 1,
  }
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(remote))
  observation
}

///|
pub async fn run_native_pull_request_fault_conformance() -> NativePullRequestFaultConformanceReport {
  let observations : Array[NativePullRequestFaultObservation] = []
  let cases : Array[
    (
      String,
      @workflow.GoalPullRequestFaultPoint,
      @workflow.PullRequestIntentState,
      Bool,
      Bool,
    ),
  ] = [
    (
      "after-intent",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterIntentBeforeLookup,
      @workflow.PullRequestIntentState::PullRequestPlanned,
      false,
      true,
    ),
    (
      "after-empty-lookup",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterEmptyLookupBeforeAuthorized,
      @workflow.PullRequestIntentState::PullRequestPlanned,
      false,
      true,
    ),
    (
      "after-authorization",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterAuthorizedBeforeCreateMayHaveBeenIssued,
      @workflow.PullRequestIntentState::PullRequestAuthorized,
      false,
      true,
    ),
    (
      "before-dispatch",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterCreateMayHaveBeenIssuedBeforeDispatch,
      @workflow.PullRequestIntentState::PullRequestCreateMayHaveBeenIssued,
      false,
      false,
    ),
    (
      "after-create",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterRemoteCreateBeforeResponse,
      @workflow.PullRequestIntentState::PullRequestCreateMayHaveBeenIssued,
      true,
      true,
    ),
    (
      "after-response",
      @workflow.GoalPullRequestFaultPoint::PullRequestAfterResponseBeforeReceipt,
      @workflow.PullRequestIntentState::PullRequestCreateMayHaveBeenIssued,
      true,
      true,
    ),
    (
      "during-receipt",
      @workflow.GoalPullRequestFaultPoint::PullRequestDuringReceiptTransaction,
      @workflow.PullRequestIntentState::PullRequestReceipted,
      true,
      true,
    ),
  ]
  for config in cases {
    observations.push(
      prove_pull_request_fault_recovery(
        config.0,
        config.1,
        config.2,
        config.3,
        config.4,
      ),
    )
  }
  {
    observations,
    passed: observations.length() == cases.length() &&
    observations.all(fn(observation) {
      observation.expected_outcome_observed && observation.duplicate_free
    }),
  }
}

///|
async test "real exec integration: final PR creation recovers without duplicate dispatch" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let report = run_native_pull_request_fault_conformance()
  assert_true(report.passed)
  assert_eq(report.observations.length(), 7)
}

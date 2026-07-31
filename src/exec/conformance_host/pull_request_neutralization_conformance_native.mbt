///|
async fn prove_native_pull_request_neutralization(
  label : String,
  merge_wins : Bool,
) -> (
  @workflow.GoalCancellationDisposition,
  @workflow.GoalCancellationDisposition,
  Int,
  @workflow.PullRequestCancellationState,
) {
  let fixture = prepare_goal_finalization_fixture(label)
  let root = fixture.0
  let remote_root = fixture.1
  let goal_id = fixture.2
  let snapshot = fixture.3
  // GitHub holds automatic merge authority over the exact pull request.
  snapshot.val = snapshot.val.map(fn(value) {
    { ..value, auto_merge_enabled: true }
  })
  let neutralize_calls = @ref.new(0)
  let survives = @ref.new(true)
  let forge : @goal_host.NativePullRequestForgeAdapters = {
    ..fixture.4,
    neutralize: (_, _, _, _) => {
      neutralize_calls.val = neutralize_calls.val + 1
      if survives.val {
        return
      }
      snapshot.val = snapshot.val.map(fn(value) {
        if merge_wins {
          {
            ..value,
            state: @workflow.RemotePullRequestState::RemotePullRequestMerged,
            auto_merge_enabled: false,
          }
        } else {
          {
            ..value,
            state: @workflow.RemotePullRequestState::RemotePullRequestClosed,
            auto_merge_enabled: false,
          }
        }
      })
    },
  }
  let repository = @goal_host.native_goal_repository(root)
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  let execution = @workflow.load_goal_execution_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record
  let first = @goal_host.reconcile_native_goal_pull_request_cancellation(
    root, repository, adapters, execution, forge, 900L,
  ).unwrap()
  // Restart mid-neutralization: the durable state resumes and retries once.
  survives.val = false
  let second = @goal_host.reconcile_native_goal_pull_request_cancellation(
    root, repository, adapters, execution, forge, 901L,
  ).unwrap()
  let dispatches = neutralize_calls.val
  let replay = @goal_host.reconcile_native_goal_pull_request_cancellation(
    root, repository, adapters, execution, forge, 902L,
  ).unwrap()
  assert_eq(replay, second)
  assert_eq(neutralize_calls.val, dispatches)
  let durable = @workflow.load_goal_pull_request_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(remote_root))
  (first, second, dispatches, durable.intent.cancellation_state)
}

///|
async test "real exec integration: cancellation strips merge authority before it settles" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let observed = prove_native_pull_request_neutralization(
    "cancellation-neutralize", false,
  )
  // An open pull request that survived the attempt keeps the Goal canceling.
  assert_eq(
    observed.0,
    @workflow.GoalCancellationDisposition::GoalCancellationPending,
  )
  assert_eq(
    observed.1,
    @workflow.GoalCancellationDisposition::GoalCancellationNeutralized,
  )
  assert_eq(observed.2, 2)
  assert_eq(
    observed.3,
    @workflow.PullRequestCancellationState::PullRequestNeutralized,
  )
}

///|
async test "real exec integration: a merge racing neutralization wins delivery" {
  if !@test_support.real_exec_integration_enabled() {
    return
  }
  let observed = prove_native_pull_request_neutralization(
    "cancellation-merge-race", true,
  )
  assert_eq(
    observed.0,
    @workflow.GoalCancellationDisposition::GoalCancellationPending,
  )
  assert_true(
    observed.1
    is @workflow.GoalCancellationDisposition::GoalCancellationSupersededByDelivery(
      _
    ),
  )
  assert_eq(observed.2, 2)
  assert_eq(
    observed.3,
    @workflow.PullRequestCancellationState::PullRequestSupersededByMerge,
  )
}

///|

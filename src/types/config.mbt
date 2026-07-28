///|
pub(all) enum PullRequestDeliveryMode {
  PullRequestReviewOnly
  PullRequestAutoMerge
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum PullRequestMergeMethod {
  PullRequestSquashMerge
  PullRequestRebaseMerge
  PullRequestMergeCommit
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct PullRequestDeliveryPolicy {
  mode : PullRequestDeliveryMode
  merge_method : PullRequestMergeMethod
} derive(Debug, Eq, ToJson, FromJson)

///|
/// How many provider Takes this installation may have in flight at once.
///
/// One field per provider surface rather than a map: the surfaces are a closed
/// domain, and a `Map[String, Int]` would accept a misspelled key and silently
/// give that surface no ceiling at all. The field names are not the key —
/// `@workflow.provider_surface_capacity` matches exhaustively on
/// `@control.ProviderSurfaceId` to read them, so a new surface does not compile
/// until it is given a bound here. The record lives in `src/types` because
/// `Config` does, and `src/control` imports `src/types`: naming
/// `ProviderSurfaceId` here would close an import cycle.
///
/// `maximum_parallel_parts` is unrelated and stays where it is: that is one
/// Goal's own ceiling on concurrent Parts, while this is the ceiling across
/// every Goal in the portfolio.
pub(all) struct ProviderCapacityPolicy {
  claude_subscription_cli : Int
  codex_subscription_cli : Int
  /// Ceiling across every surface together, when one is configured. Absent
  /// means the per-surface bounds are the only ceiling.
  global_execution_ceiling : Int?
} derive(Debug, Eq, ToJson, FromJson)

///|
/// How many Goal executor jobs this daemon may keep in flight.
///
/// A Goal executor owns one bounded execution tick. The tick may spend most of
/// an hour inside a provider Take, so this is deliberately independent from
/// provider capacity: the provider policy bounds subscription sessions, while
/// this policy bounds concurrent Goal runtimes and their BoxLite servers.
pub(all) struct GoalExecutorCapacityPolicy {
  maximum_parallel_jobs : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WorkOrderExecutorCapacityPolicy {
  maximum_parallel_jobs : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn maximum_goal_executor_jobs() -> Int {
  1024
}

///|
/// Executor slots become BoxLite ports in the native host adapter. Keep the
/// configured range both positive and within the durable slot/port domain
/// before the daemon can launch it. The deliberately small default is the
/// ordinary host-capacity protection; larger explicit values are operator
/// policy.
pub fn validate_goal_executor_capacity_policy(
  policy : GoalExecutorCapacityPolicy,
) -> Result[Unit, ChoirError] {
  if policy.maximum_parallel_jobs <= 0 ||
    policy.maximum_parallel_jobs > maximum_goal_executor_jobs() {
    Err(
      ChoirError::validation_error("capacity.goals must be between 1 and 1024"),
    )
  } else {
    Ok(())
  }
}

///|
pub fn validate_work_order_executor_capacity_policy(
  policy : WorkOrderExecutorCapacityPolicy,
) -> Result[Unit, ChoirError] {
  if policy.maximum_parallel_jobs <= 0 ||
    policy.maximum_parallel_jobs > maximum_goal_executor_jobs() {
    Err(
      ChoirError::validation_error(
        "capacity.work_orders must be between 1 and 1024",
      ),
    )
  } else {
    Ok(())
  }
}

///|
/// Reject a capacity policy that cannot admit work.
///
/// A non-positive bound is not "unlimited", it is a daemon that never
/// dispatches, so it is refused at load rather than discovered as a Goal that
/// never advances. A global ceiling below the largest per-surface bound is
/// accepted: the global ceiling is allowed to be the binding one.
pub fn validate_provider_capacity_policy(
  policy : ProviderCapacityPolicy,
) -> Result[Unit, ChoirError] {
  if policy.claude_subscription_cli <= 0 || policy.codex_subscription_cli <= 0 {
    return Err(
      ChoirError::validation_error(
        "capacity.claude and capacity.codex must be positive",
      ),
    )
  }
  match policy.global_execution_ceiling {
    Some(ceiling) if ceiling <= 0 =>
      Err(ChoirError::validation_error("capacity.global must be positive"))
    _ => Ok(())
  }
}

///|
/// The complete local daemon launch configuration.
pub(all) struct Config {
  project_dir : String
  listen_uds : String
  pull_request_delivery : PullRequestDeliveryPolicy
  provider_capacity : ProviderCapacityPolicy
  goal_executor_capacity : GoalExecutorCapacityPolicy
  work_order_executor_capacity : WorkOrderExecutorCapacityPolicy
} derive(Debug, Eq)

///|
pub fn Config::default() -> Config {
  {
    project_dir: ".",
    listen_uds: ".choir/run/server.sock",
    pull_request_delivery: {
      mode: PullRequestDeliveryMode::PullRequestReviewOnly,
      merge_method: PullRequestMergeMethod::PullRequestSquashMerge,
    },
    // Four, not one. Admission is a new bound on work that already runs: a
    // single Goal drafted with `maximum_parallel_parts` above the surface bound
    // would advance its Parts one at a time instead of together, which is a
    // slowdown rather than the protection this exists for. Four sits at or
    // above the parallelism Goals are drafted with in practice, and an operator
    // whose subscription is tighter than that lowers it.
    provider_capacity: {
      claude_subscription_cli: 4,
      codex_subscription_cli: 4,
      global_execution_ceiling: None,
    },
    // Four Goal runtimes can advance independently without turning a newly
    // accepted portfolio into an unbounded number of BoxLite servers. Provider
    // leases remain the tighter bound whenever these jobs reach a subscription.
    goal_executor_capacity: { maximum_parallel_jobs: 4 },
    work_order_executor_capacity: { maximum_parallel_jobs: 4 },
  }
}

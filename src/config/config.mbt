///|
fn config_value(
  primary : TomlDoc,
  machine : TomlDoc,
  key : String,
  fallback : String,
) -> String {
  match machine.get_optional_nonempty(key) {
    Some(value) => value
    None => primary.get_optional_nonempty(key).unwrap_or(fallback)
  }
}

///|
fn parse_pull_request_delivery_mode(
  value : String,
) -> Result[@types.PullRequestDeliveryMode, @types.ChoirError] {
  match value {
    "review_only" => Ok(@types.PullRequestDeliveryMode::PullRequestReviewOnly)
    "auto_merge" => Ok(@types.PullRequestDeliveryMode::PullRequestAutoMerge)
    _ =>
      Err(
        @types.ChoirError::validation_error(
          "delivery.pull_requests must be review_only or auto_merge",
        ),
      )
  }
}

///|
fn parse_pull_request_merge_method(
  value : String,
) -> Result[@types.PullRequestMergeMethod, @types.ChoirError] {
  match value {
    "squash" => Ok(@types.PullRequestMergeMethod::PullRequestSquashMerge)
    "rebase" => Ok(@types.PullRequestMergeMethod::PullRequestRebaseMerge)
    "merge" => Ok(@types.PullRequestMergeMethod::PullRequestMergeCommit)
    _ =>
      Err(
        @types.ChoirError::validation_error(
          "delivery.merge_method must be squash, rebase, or merge",
        ),
      )
  }
}

///|
/// Read one positive capacity bound. An unparsable or absent value is the
/// default rather than a silent zero, and anything else is refused: a bound
/// nobody meant is a daemon that dispatches nothing or oversubscribes.
fn parse_capacity_bound(
  primary : TomlDoc,
  machine : TomlDoc,
  key : String,
  fallback : Int,
) -> Result[Int, @types.ChoirError] {
  match config_value(primary, machine, key, "") {
    "" => Ok(fallback)
    text =>
      Ok(@string.parse_int(text)) catch {
        _ =>
          Err(@types.ChoirError::validation_error(key + " must be an integer"))
      }
  }
}

///|
/// Read the optional global ceiling. Absent means the per-surface bounds are
/// the only ceiling, which is not the same as a ceiling of zero.
fn parse_optional_capacity_bound(
  primary : TomlDoc,
  machine : TomlDoc,
  key : String,
) -> Result[Int?, @types.ChoirError] {
  match config_value(primary, machine, key, "") {
    "" => Ok(None)
    text =>
      Ok(Some(@string.parse_int(text))) catch {
        _ =>
          Err(@types.ChoirError::validation_error(key + " must be an integer"))
      }
  }
}

///|
/// Parse launcher paths, the checked-in pull-request delivery policy, and the
/// provider capacity ceilings. Machine-local values override the checked-in
/// project file.
pub fn parse_config(
  content : String,
  local_content? : String? = None,
) -> Result[@types.Config, @types.ChoirError] {
  let primary = parse_toml_doc(content)
  let machine = parse_toml_doc(local_content.unwrap_or(""))
  let defaults = @types.Config::default()
  let delivery_mode = match
    parse_pull_request_delivery_mode(
      config_value(primary, machine, "delivery.pull_requests", "review_only"),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let merge_method = match
    parse_pull_request_merge_method(
      config_value(primary, machine, "delivery.merge_method", "squash"),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let claude = match
    parse_capacity_bound(
      primary,
      machine,
      "capacity.claude",
      defaults.provider_capacity.claude_subscription_cli,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let codex = match
    parse_capacity_bound(
      primary,
      machine,
      "capacity.codex",
      defaults.provider_capacity.codex_subscription_cli,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let global_execution_ceiling = match
    parse_optional_capacity_bound(primary, machine, "capacity.global") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let maximum_parallel_goal_jobs = match
    parse_capacity_bound(
      primary,
      machine,
      "capacity.goals",
      defaults.goal_executor_capacity.maximum_parallel_jobs,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let provider_capacity : @types.ProviderCapacityPolicy = {
    claude_subscription_cli: claude,
    codex_subscription_cli: codex,
    global_execution_ceiling,
  }
  match @types.validate_provider_capacity_policy(provider_capacity) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let goal_executor_capacity : @types.GoalExecutorCapacityPolicy = {
    maximum_parallel_jobs: maximum_parallel_goal_jobs,
  }
  match @types.validate_goal_executor_capacity_policy(goal_executor_capacity) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok({
    project_dir: config_value(
      primary,
      machine,
      "project_dir",
      defaults.project_dir,
    ),
    listen_uds: config_value(
      primary,
      machine,
      "listen_uds",
      defaults.listen_uds,
    ),
    pull_request_delivery: { mode: delivery_mode, merge_method },
    provider_capacity,
    goal_executor_capacity,
  })
}

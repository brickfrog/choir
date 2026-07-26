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
/// Parse launcher paths and the checked-in pull-request delivery policy.
/// Machine-local values override the checked-in project file.
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
  })
}

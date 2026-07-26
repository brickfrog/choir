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
/// The complete local daemon launch configuration.
pub(all) struct Config {
  project_dir : String
  listen_uds : String
  pull_request_delivery : PullRequestDeliveryPolicy
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
  }
}

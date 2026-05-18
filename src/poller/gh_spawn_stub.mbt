///|
/// Non-native: `@process` is unavailable; poller PR view is native-only in practice.
pub async fn gh_poll_pr(
  _pr_number : Int,
  _skip_issue_comment_fetch : Bool,
) -> (
  Bool,
  ReviewState,
  String,
  CiRollupStatus,
  String,
  Bool,
  Bool,
  Mergeable,
  MergeStateStatus,
  Int64?,
) {
  (
    false,
    None_,
    "",
    CiRollupStatus::Unknown,
    "",
    true,
    false,
    Mergeable::Unknown,
    MergeStateStatus::Unknown,
    None,
  )
}

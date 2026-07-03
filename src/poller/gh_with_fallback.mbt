///|
pub(all) enum GhFallbackOutcome {
  Fresh(String)
  Stall
  EmptyOutput
  Error(Int)
} derive(Debug, Eq)

///|
pub fn gh_fallback_classify(
  exit_code : Int,
  output : String,
) -> GhFallbackOutcome {
  if exit_code == 124 {
    Stall
  } else if exit_code == 0 {
    let trimmed = output.trim().to_owned()
    if trimmed == "" {
      EmptyOutput
    } else {
      Fresh(output)
    }
  } else {
    Error(exit_code)
  }
}

///|
pub(all) struct GhWithFallback {
  data : String
  stale : Bool
  age_sec : Int
} derive(Debug, Eq)

///|
fn review_state_json_value(review : ReviewState) -> String {
  match review {
    None_ => ""
    Approved => "APPROVED"
    ChangesRequested => "CHANGES_REQUESTED"
    Commented => "COMMENTED"
  }
}

///|
fn ci_rollup_snapshot_json(rollup : CiRollupStatus) -> Array[Json] {
  match rollup {
    Unknown => [{ "state": "UNKNOWN".to_json() }.to_json()]
    NoChecks => []
    InProgress => [{ "state": "IN_PROGRESS".to_json() }.to_json()]
    Success => [{ "conclusion": "SUCCESS".to_json() }.to_json()]
    Failure => [{ "conclusion": "FAILURE".to_json() }.to_json()]
  }
}

///|
fn review_snapshot_json(review : ReviewState, body : String) -> Array[Json] {
  let state = review_state_json_value(review)
  if state == "" {
    []
  } else {
    [
      {
        "state": state.to_json(),
        "body": body.to_json(),
        "author": { "login": "choir-poller-cache".to_json() }.to_json(),
      }.to_json(),
    ]
  }
}

///|
fn tracked_unresolved_threads_count(tracked : TrackedPR) -> Int {
  if tracked.unresolved_thread_ids_fetched {
    tracked.unresolved_thread_ids.length()
  } else {
    0
  }
}

///|
fn tracked_optional_int64_json(value : Int64?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => null
  }
}

///|
pub fn tracked_pr_snapshot_json(tracked : TrackedPR) -> String {
  {
    "number": tracked.pr_number.to_json(),
    "url": tracked.pr_url.to_json(),
    "state": "OPEN".to_json(),
    "reviews": review_snapshot_json(
      tracked.last_review_state,
      tracked.last_review_bodies,
    ).to_json(),
    "comments": ([] : Array[Json]).to_json(),
    "headRefOid": tracked.last_sha.to_json(),
    "statusCheckRollup": ci_rollup_snapshot_json(tracked.last_ci_rollup).to_json(),
    "mergeable": tracked.mergeable.to_wire_string().to_json(),
    "mergeStateStatus": tracked.merge_state_status.to_wire_string().to_json(),
    "merged_at_unix": tracked_optional_int64_json(tracked.merged_at_unix),
    "unresolved_threads": tracked_unresolved_threads_count(tracked).to_json(),
    "copilot_issue_comment_seen": tracked.copilot_issue_comment_seen.to_json(),
    "last_sha": tracked.last_sha.to_json(),
  }
  .to_json()
  .stringify()
}

///|
fn bounded_gh_pr_view_command(pr_number : Int) -> @workspace.Command {
  {
    program: "timeout",
    args: [
      "30s",
      "gh",
      "pr",
      "view",
      pr_number.to_string(),
      "--json",
      gh_pr_view_fallback_json_fields,
    ],
    workdir: None,
  }
}

///|
fn gh_fallback_age_sec(tracked : TrackedPR, now : Int64) -> Int {
  let age = now - tracked.first_seen
  if age <= 0L {
    0
  } else if age > 2_147_483_647L {
    2_147_483_647
  } else {
    age.to_int()
  }
}

///|
pub async fn gh_pr_view_with_fallback(
  pr_number : Int,
  poller_state : PollerState,
  capture~ : async (@workspace.Command) -> (Int, String),
  now_sec? : () -> Int64 = now_sec,
) -> GhWithFallback {
  let (exit_code, output) = capture(bounded_gh_pr_view_command(pr_number))
  match gh_fallback_classify(exit_code, output) {
    Fresh(data) => { data, stale: false, age_sec: 0 }
    Stall | EmptyOutput | Error(_) =>
      match poller_state.get(pr_number) {
        Some(tracked) =>
          {
            data: tracked_pr_snapshot_json(tracked),
            stale: true,
            age_sec: gh_fallback_age_sec(tracked, now_sec()),
          }
        None => { data: "", stale: true, age_sec: 0 }
      }
  }
}

///|
/// Ordered host-side steps for `merge_pr` preflight when `force` is false
/// (poller read is synchronous; thread fetch uses `capture`). Matches
/// `interpret_merge_pr_preflight`.
pub(all) enum MergePrPreflightHostStep {
  PollerSnapshot
  FetchUnresolvedReviewThreads
} derive(Debug, Eq)

///|
pub impl Show for MergePrPreflightHostStep with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn merge_pr_preflight_host_steps() -> Array[MergePrPreflightHostStep] {
  [
    MergePrPreflightHostStep::PollerSnapshot,
    MergePrPreflightHostStep::FetchUnresolvedReviewThreads,
  ]
}

///|
pub fn parse_github_owner_repo_from_url(raw : String) -> (String, String)? {
  let value = raw.trim().to_string()
  let mut path = if value.has_prefix("https://github.com/") {
    value["https://github.com/".length():].to_string()
  } else if value.has_prefix("http://github.com/") {
    value["http://github.com/".length():].to_string()
  } else if value.has_prefix("git@github.com:") {
    value["git@github.com:".length():].to_string()
  } else if value.has_prefix("ssh://git@github.com/") {
    value["ssh://git@github.com/".length():].to_string()
  } else {
    return None
  }
  if path.has_suffix(".git") {
    path = path[:path.length() - ".git".length()].to_string()
  }
  let parts = []
  for part in path.split("/") {
    parts.push(part.to_string())
  }
  if parts.length() < 2 {
    return None
  }
  let owner = parts[0]
  let repo = parts[1]
  if owner == "" || repo == "" {
    None
  } else {
    Some((owner, repo))
  }
}

///|
fn merge_pr_owner_repo_from_tracked(
  poller_state : @poller.PollerState?,
  pr_number : Int,
) -> (String, String)? {
  match poller_state {
    Some(ps) =>
      match ps.get(pr_number) {
        Some(tracked) => parse_github_owner_repo_from_url(tracked.pr_url)
        None => None
      }
    None => None
  }
}

///|
async fn merge_pr_owner_repo(
  pr_number : Int,
  poller_state : @poller.PollerState?,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[(String, String), @types.ChoirError] {
  match merge_pr_owner_repo_from_tracked(poller_state, pr_number) {
    Some(pair) => Ok(pair)
    None => {
      let cmd : @workspace.Command = {
        program: "git",
        args: ["remote", "get-url", "origin"],
        workdir: Some(project_dir),
      }
      let (exit_code, output) = capture(cmd)
      if exit_code != 0 || output.trim().to_string() == "" {
        return Err(
          @types.ChoirError::validation_error(
            "merge blocked: could not resolve GitHub repository owner/name from tracked PR URL or origin remote",
          ),
        )
      }
      match parse_github_owner_repo_from_url(output) {
        Some(pair) => Ok(pair)
        None =>
          Err(
            @types.ChoirError::validation_error(
              "merge blocked: origin remote is not a GitHub repository URL",
            ),
          )
      }
    }
  }
}

///|
pub fn merge_pr_reviews_command(
  owner : String,
  repo : String,
  pr_number : Int,
  project_dir : String,
) -> @workspace.Command {
  {
    program: "gh",
    args: [
      "api",
      "repos/" +
      owner +
      "/" +
      repo +
      "/pulls/" +
      pr_number.to_string() +
      "/reviews",
    ],
    workdir: Some(project_dir),
  }
}

///|
fn merge_pr_review_reviewer_key(
  fields : Map[String, Json],
  fallback_index : Int,
) -> String {
  match fields.get("user") {
    Some(Object(user)) =>
      match user.get("login") {
        Some(String(login)) =>
          if login != "" {
            "user:" + login
          } else {
            "review:" + fallback_index.to_string()
          }
        _ => "review:" + fallback_index.to_string()
      }
    _ => "review:" + fallback_index.to_string()
  }
}

///|
fn merge_pr_review_submitted_at(fields : Map[String, Json]) -> String {
  match fields.get("submitted_at") {
    Some(String(value)) => value
    _ => ""
  }
}

///|
/// Parse a GitHub `submitted_at` string (ISO-8601 UTC) into Unix seconds.
/// `None` when the string is empty or not a recognized shape. Today GitHub
/// emits fixed-width `YYYY-MM-DDTHH:MM:SSZ` and a lexicographic compare is
/// coincidentally ordered — but we don't want that coincidence to be a
/// load-bearing invariant.
fn merge_pr_parse_submitted_at(s : String) -> Int64? {
  if s == "" {
    return None
  }
  Some(@tempo.DateTime::parse(s).to_unix_seconds()) catch {
    _ => None
  }
}

///|
fn merge_pr_should_replace_review_state(
  latest_times : Map[String, String],
  latest_indexes : Map[String, Int],
  key : String,
  submitted_at : String,
  index : Int,
) -> Bool {
  match latest_times.get(key) {
    None => true
    Some(prev_time) => {
      let now_ts = merge_pr_parse_submitted_at(submitted_at)
      let prev_ts = merge_pr_parse_submitted_at(prev_time)
      match (now_ts, prev_ts) {
        (Some(a), Some(b)) => a >= b
        _ =>
          // One or both timestamps unparseable — fall back to array-order
          // to preserve the existing last-wins-in-response semantics.
          match latest_indexes.get(key) {
            Some(prev_index) => index >= prev_index
            None => true
          }
      }
    }
  }
}

///|
pub fn merge_pr_review_gate_block_message(
  pr_number : Int,
  reviews_json : String,
) -> Result[String?, @types.ChoirError] {
  let json = @json.parse(reviews_json) catch {
    _ =>
      return Err(
        @types.ChoirError::validation_error(
          "merge blocked: invalid JSON from GitHub PR reviews API",
        ),
      )
  }
  guard json is Array(reviews) else {
    return Err(
      @types.ChoirError::validation_error(
        "merge blocked: unexpected GitHub PR reviews response shape",
      ),
    )
  }
  let latest_states : Map[String, String] = {}
  let latest_times : Map[String, String] = {}
  let latest_indexes : Map[String, Int] = {}
  for i = 0; i < reviews.length(); i = i + 1 {
    let review = reviews[i]
    match review {
      Object(fields) => {
        let state = match fields.get("state") {
          Some(String(value)) => value
          _ => ""
        }
        if state != "" {
          let key = merge_pr_review_reviewer_key(fields, i)
          let submitted_at = merge_pr_review_submitted_at(fields)
          if merge_pr_should_replace_review_state(
              latest_times, latest_indexes, key, submitted_at, i,
            ) {
            latest_states.set(key, state)
            latest_times.set(key, submitted_at)
            latest_indexes.set(key, i)
          }
        }
      }
      _ => ()
    }
  }
  for state in latest_states.values() {
    if state == "CHANGES_REQUESTED" {
      return Ok(
        Some(
          "PR #" +
          pr_number.to_string() +
          " has a GitHub review requesting changes. Address it before merging.",
        ),
      )
    }
  }
  Ok(None)
}

///|
async fn enforce_merge_pr_github_review_gate(
  pr_number : Int,
  poller_state : @poller.PollerState?,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[Unit, @types.ChoirError] {
  let (owner, repo) = match
    merge_pr_owner_repo(pr_number, poller_state, project_dir, capture) {
    Ok(pair) => pair
    Err(e) => return Err(e)
  }
  let cmd = merge_pr_reviews_command(owner, repo, pr_number, project_dir)
  let (exit_code, output) = capture(cmd)
  if exit_code != 0 || output.trim().to_string() == "" {
    return Err(
      @types.ChoirError::validation_error(
        "merge blocked: could not fetch GitHub review state for PR #" +
        pr_number.to_string(),
      ),
    )
  }
  match merge_pr_review_gate_block_message(pr_number, output) {
    Ok(Some(msg)) => Err(@types.ChoirError::validation_error(msg))
    Ok(None) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// `merge_pr` preflight: GitHub changes-requested reviews are checked first and
/// are never bypassed by `force`. When `force` is false, poller snapshot,
/// unresolved review-thread fetch, then `merge_pr_preflight_block_message`.
/// When `force` is true, those checks are skipped after the GitHub review gate
/// (historical inline `force` behavior for poller/threads only).
pub async fn interpret_merge_pr_preflight(
  force : Bool,
  pr_number : Int,
  poller_state : @poller.PollerState?,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
  registry : @registry.AgentRegistry?,
  review_mode? : @types.ReviewMode = @types.ReviewMode::SinglePass,
) -> Result[Unit, @types.ChoirError] {
  match
    enforce_merge_pr_github_review_gate(
      pr_number, poller_state, project_dir, capture,
    ) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if force {
    return Ok(())
  }
  let poller_tracked = match poller_state {
    Some(ps) => ps.get(pr_number)
    None => None
  }
  let (thread_count, thread_text) = fetch_unresolved_review_threads(
    pr_number, project_dir, capture,
  )
  let policy_decision = match poller_tracked {
    Some(tracked) => {
      let task_contract = match registry {
        Some(reg) =>
          @workspace.task_contract_for_agent_workspace(
            project_dir,
            Some(reg.get(tracked.agent_id).workspace) catch {
              _ => None
            },
            @phase.extract_slug(tracked.agent_id),
          )
        None => None
      }
      Some(
        @poller.merge_policy_decision_for_tracked_pr(
          tracked,
          Some(thread_count),
          task_contract~,
          review_mode~,
        ),
      )
    }
    None => None
  }
  match
    merge_pr_preflight_block_message(
      pr_number,
      poller_tracked,
      thread_count,
      thread_text,
      policy_decision,
      review_mode~,
    ) {
    Some(msg) => Err(@types.ChoirError::validation_error(msg))
    None => Ok(())
  }
}

///|
/// Pre-merge gating for `merge_pr` when `force` is false: poller review state
/// is checked first, then unresolved GraphQL review threads. Returns `Some(err)`
/// when the merge must not proceed; `None` when checks pass.
pub fn merge_pr_preflight_block_message(
  pr_number : Int,
  poller_tracked : @poller.TrackedPR?,
  unresolved_thread_count : Int,
  unresolved_thread_text : String,
  policy_decision : @policy.MergeDecision?,
  review_mode? : @types.ReviewMode = @types.ReviewMode::SinglePass,
) -> String? {
  match poller_tracked {
    Some(tracked) =>
      if tracked.last_review_state == @poller.ReviewState::ChangesRequested &&
        !(review_mode == @types.ReviewMode::SinglePass &&
        tracked.changes_requested_since == 0L &&
        tracked.last_sha != "") {
        return Some(
          "PR #" +
          pr_number.to_string() +
          " has unresolved review comments (ChangesRequested). " +
          "Wait for the owning agent to push fixes, or pass force=true to override.",
        )
      }
    None => ()
  }
  match policy_decision {
    Some(@policy.MergeDecision::Blocked(reason~)) =>
      return Some(
        "policy blocked: " +
        reason +
        ". Address the blocking policy condition before merging, or pass force=true to override.",
      )
    Some(@policy.MergeDecision::Wait(reason~)) =>
      return Some(
        "policy wait: " +
        reason +
        ". Wait for the policy condition to clear, or pass force=true to override.",
      )
    Some(@policy.MergeDecision::NeedsHuman(reason~)) =>
      return Some(
        "policy requires human check: " +
        reason +
        ". Request the required human check before merging, or pass force=true to override.",
      )
    _ => ()
  }
  if unresolved_thread_count > 0 {
    if unresolved_thread_text == review_thread_fetch_failed_marker {
      return Some(
        "merge blocked: gh unavailable (could not fetch review thread state) — contact TL to manually advance lifecycle.",
      )
    }
    return Some(
      "PR #" +
      pr_number.to_string() +
      " has " +
      unresolved_thread_count.to_string() +
      " unresolved review thread(s). Address or resolve them before merging:\n" +
      unresolved_thread_text +
      "\nUse resolve_review_thread to mark threads resolved, or pass force=true to override.",
    )
  }
  None
}

///|
/// TL-facing re-check snapshot after actionable CI poller transitions
/// (`CIFailureCleared`, `CILatestHeadRollupSucceeded`). Honest about review state,
/// CI rollup, and unresolved threads; does not claim merge or call `merge_pr`.
/// `unresolved_thread_count` is `None` when the GraphQL fetch was not performed.
pub fn format_tl_pr_recheck_summary(
  tracked : @poller.TrackedPR,
  _project_dir : String,
  unresolved_thread_count : Int?,
  task_contract? : @types.TaskContract? = None,
) -> String {
  ignore(task_contract)
  let review = match tracked.last_review_state {
    None_ => "none"
    Commented => "commented"
    Approved => "approved"
    ChangesRequested => "changes_requested"
  }
  let ci = match tracked.last_ci_rollup {
    Unknown => "unknown"
    InProgress => "in_progress"
    Success => "success"
    Failure => "failure"
  }
  let threads_line = match unresolved_thread_count {
    Some(n) => "Unresolved inline review threads (GraphQL): " + n.to_string()
    None => "Unresolved inline review threads (GraphQL): not fetched"
  }
  let copilot_line = if tracked.copilot_issue_comment_seen {
    "GitHub Copilot issue comment (REST): seen"
  } else {
    "GitHub Copilot issue comment (REST): not seen"
  }
  let gate = @poller.tl_tracked_pr_recheck_gate_line(
    tracked, unresolved_thread_count,
  )

  let advisory = @poller.advisory_evaluation_summary_line(
    tracked,
    unresolved_thread_count,
    task_contract~,
  )
  let policy = @poller.merge_policy_summary_line(
    tracked,
    unresolved_thread_count,
    task_contract~,
  )

  "PR re-check summary (Choir snapshot; not merge approval):\n" +
  "- GitHub review rollup: " +
  review +
  "\n" +
  "- " +
  threads_line +
  "\n" +
  "- " +
  copilot_line +
  "\n" +
  "- Latest head CI rollup: " +
  ci +
  "\n" +
  "- " +
  gate +
  "\n" +
  "- " +
  advisory +
  "\n" +
  "- " +
  policy
}

///|
/// Map `gh pr merge` stderr (or log) captured after a failed merge attempt into
/// the user-facing error string. Pure policy: conflict/not-mergeable vs other.
pub fn merge_pr_merge_failure_message(
  pr_number : Int,
  gh_stderr_trimmed : String,
) -> String {
  let lower = gh_stderr_trimmed.to_lower()
  if lower.contains("conflict") || lower.contains("not mergeable") {
    "merge conflict on PR #" + pr_number.to_string() + ": " + gh_stderr_trimmed
  } else if gh_stderr_trimmed.length() > 0 {
    "merge failed for PR #" + pr_number.to_string() + ": " + gh_stderr_trimmed
  } else {
    "merge failed for PR #" + pr_number.to_string()
  }
}

///|
/// `TLEvent::PRMerged` `url` field: slug from tracked branch when known, else
/// a stable `PR-{n}` placeholder (matches prior dispatch behavior).
pub fn merge_pr_pr_merged_event_url_slug(
  pr_number : Int,
  tracked_branch : String?,
) -> String {
  match tracked_branch {
    Some(branch) => @phase.extract_slug(branch)
    None => "PR-" + pr_number.to_string()
  }
}

///|
/// Pure plan for `merge_pr` after the merge command succeeds: `TLEvent::PRMerged`
/// payload (url slug from tracked branch when poller is available), whether to
/// untrack the PR and persist poller state, and the tool success response.
pub(all) struct MergePrPostSuccessPlan {
  tl_event : @phase.TLEvent
  poller_untrack_and_write_state : Bool
  response : @types.Response
}

///|
pub fn merge_pr_post_success_plan(
  pr_number : Int,
  poller_available : Bool,
  tracked_branch : String?,
) -> MergePrPostSuccessPlan {
  let branch_for_slug = if poller_available { tracked_branch } else { None }
  let slug = merge_pr_pr_merged_event_url_slug(pr_number, branch_for_slug)
  let tl_event = @phase.TLEvent::PRMerged(number=pr_number, url=slug)
  {
    tl_event,
    poller_untrack_and_write_state: poller_available,
    response: @types.Response::ok_values({ "status": String::to_json("merged") }),
  }
}

///|
/// Mutex key for per-parent-branch merge serialization (matches prior inline
/// `merge_pr` behavior).
pub fn merge_pr_mutex_name(parent_branch : String) -> String {
  "branch:" + parent_branch
}

///|
/// TTL passed to `MutexRegistry::acquire` for merge serialization.
pub let merge_pr_mutex_ttl_sec : Int64 = 120L

///|
pub fn merge_pr_serialization_busy_message() -> String {
  "merge serialization lock held by another agent, retry shortly"
}

///|
/// Same busy notice but annotated with the caller's queue position at the
/// moment of the failed acquire. `position == 0` (shouldn't happen on busy)
/// or `position == 1` is suppressed; `position >= 2` means "N callers ahead
/// of you" and is appended so operators can tell apart 'first in line' from
/// 'backed up behind a queue'.
pub fn merge_pr_serialization_busy_message_with_position(
  position : Int,
) -> String {
  if position <= 1 {
    merge_pr_serialization_busy_message()
  } else {
    merge_pr_serialization_busy_message() +
    " (position " +
    position.to_string() +
    " in queue)"
  }
}

///|
/// Ordered host steps for `merge_pr` after preflight: `gh pr merge` then
/// `git fetch` (see `merge_pr_commands` in `pr.mbt`).
pub(all) enum MergePrHostStep {
  GhPrMerge
  GitFetch
} derive(Debug, Eq)

///|
pub impl Show for MergePrHostStep with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn merge_pr_host_step_sequence() -> Array[MergePrHostStep] {
  [MergePrHostStep::GhPrMerge, MergePrHostStep::GitFetch]
}

///|
/// Mutex bracket + strict command run + failure capture/mapping. Preserves the
/// historical sequence: acquire (optional) → `run_strict(merge_pr_commands)` →
/// release → on `run_strict` failure, ignore its string and derive the user
/// error from a fresh `capture(merge_pr_command)` only.
pub async fn interpret_merge_pr_merge_host(
  parent_branch : String,
  pr_number : Int,
  caller_id : String,
  mutex_registry : @registry.MutexRegistry?,
  now_sec : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
) -> Result[Unit, @types.ChoirError] {
  let mutex_name = merge_pr_mutex_name(parent_branch)
  match mutex_registry {
    Some(reg) => {
      let (acquired, queue_position) = reg.acquire(
        mutex_name, caller_id, merge_pr_mutex_ttl_sec, now_sec,
      )
      if !acquired {
        ignore(reg.release(mutex_name, caller_id, now_sec))
        return Err(
          @types.ChoirError::validation_error(
            merge_pr_serialization_busy_message_with_position(queue_position),
          ),
        )
      }
    }
    None => ()
  }
  let cmds = merge_pr_commands(pr_number)
  let merge_result = run_strict(runner, cmds, capture~)
  // Release before result inspection so the failure-capture path below
  // does not hold the lock across another `gh` call; failure-capture
  // does not mutate the remote.
  match mutex_registry {
    Some(reg) => ignore(reg.release(mutex_name, caller_id, now_sec))
    None => ()
  }
  match merge_result {
    Err(_) => {
      let (_, output) = capture(merge_pr_command(pr_number))
      let trimmed = output.trim().to_string()
      Err(
        @types.ChoirError::git_error(
          merge_pr_merge_failure_message(pr_number, trimmed),
        ),
      )
    }
    Ok(_) => Ok(())
  }
}

///|
/// Tracked branch string for `merge_pr_post_success_plan` when the poller is
/// present and lists this PR; `None` when the poller is absent or has no entry.
pub fn merge_pr_tracked_branch_for_post_success(
  poller_state : @poller.PollerState?,
  pr_number : Int,
) -> String? {
  match poller_state {
    Some(ps) =>
      match ps.get(pr_number) {
        Some(tracked) => Some(tracked.branch)
        None => None
      }
    None => None
  }
}

///|
/// After `interpret_merge_pr_merge_host` succeeds: resolve tracked branch,
/// build `merge_pr_post_success_plan`, apply the TL lifecycle event, optionally
/// untrack and persist poller state, return the tool response.
pub fn interpret_merge_pr_post_success(
  project_dir : String,
  caller_id : String,
  pr_number : Int,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
) -> @types.Response {
  let tracked_branch = merge_pr_tracked_branch_for_post_success(
    poller_state, pr_number,
  )
  let plan = merge_pr_post_success_plan(
    pr_number,
    poller_state is Some(_),
    tracked_branch,
  )
  let tl_effects = @phase.plan_tl_event_for_scope(
    project_dir,
    caller_id,
    plan.tl_event,
    registry~,
  )
  @phase.interpret_lifecycle_effects(project_dir, tl_effects, registry~)
  if plan.poller_untrack_and_write_state {
    match poller_state {
      Some(ps) => {
        ps.untrack(pr_number)
        ignore(ps.write_state_file(project_dir))
      }
      None => ()
    }
  }
  plan.response
}

///|
/// End-to-end `merge_pr`: preflight, mutex-bracketed merge host, then
/// post-success TL lifecycle and poller untrack. Dispatcher delegates here;
/// behavior matches the prior `ToolRequest::MergePr` inline arm.
pub async fn interpret_merge_pr(
  merge_args : MergePrArgs,
  project_dir : String,
  poller_state : @poller.PollerState?,
  mutex_registry : @registry.MutexRegistry?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  match
    interpret_merge_pr_preflight(
      merge_args.force,
      merge_args.pr_number,
      poller_state,
      project_dir,
      capture,
      registry,
      review_mode=merge_args.review_mode.unwrap_or(
        @types.ReviewMode::SinglePass,
      ),
    ) {
    Err(e) => @types.Response::Err(e.message())
    Ok(_) =>
      match
        interpret_merge_pr_merge_host(
          merge_args.parent_branch,
          merge_args.pr_number,
          merge_args.caller_id,
          mutex_registry,
          @poller.now_sec(),
          runner,
          capture,
        ) {
        Err(e) => @types.Response::Err(e.message())
        Ok(_) =>
          interpret_merge_pr_post_success(
            project_dir,
            merge_args.caller_id,
            merge_args.pr_number,
            poller_state,
            registry,
          )
      }
  }
}

///|
/// GraphQL mutation body for `resolve_review_thread` (thread id is passed as a
/// variable; matches historical `ToolRequest::ResolveReviewThread` dispatch).
pub fn resolve_review_thread_graphql_mutation() -> String {
  "mutation($threadId: ID!) { resolveReviewThread(input: { threadId: $threadId }) { thread { isResolved } } }"
}

///|
/// `gh api graphql` command for resolving a review thread (routing-only callers
/// supply `project_dir` and `capture`).
pub fn resolve_review_thread_gh_command(
  project_dir : String,
  thread_id : String,
) -> @workspace.Command {
  {
    program: "gh",
    args: [
      "api",
      "graphql",
      "-f",
      "query=" + resolve_review_thread_graphql_mutation(),
      "-F",
      "threadId=" + thread_id,
    ],
    workdir: Some(project_dir),
  }
}

///|
/// Interpret `gh` exit code and JSON body for `resolve_review_thread`. Preserves
/// exact user-facing strings from the prior inline dispatch arm.
pub fn interpret_resolve_review_thread_result(
  exit_code : Int,
  output : String,
  thread_id : String,
) -> @types.Response {
  if exit_code != 0 {
    let trimmed = output.trim().to_string()
    return @types.Response::Err(
      if trimmed != "" {
        "resolve_review_thread failed: " + trimmed
      } else {
        "resolve_review_thread failed (exit " + exit_code.to_string() + ")"
      },
    )
  }
  if output.trim().to_string() == "" {
    return @types.Response::Err(
      "resolve_review_thread failed: empty response from gh",
    )
  }
  let json = @json.parse(output) catch {
    _ =>
      return @types.Response::Err(
        "resolve_review_thread: invalid JSON in gh response",
      )
  }
  guard json is Object(root) else {
    return @types.Response::Err(
      "resolve_review_thread: unexpected response shape",
    )
  }
  match root.get("errors") {
    Some(Array(errs)) =>
      if errs.length() > 0 {
        let msg = match errs[0] {
          Object(e) =>
            match e.get("message") {
              Some(String(v)) => v
              _ => "GraphQL error"
            }
          _ => "GraphQL error"
        }
        return @types.Response::Err("resolve_review_thread failed: " + msg)
      }
    _ => ()
  }
  let is_resolved = match root.get("data") {
    Some(Object(data)) =>
      match data.get("resolveReviewThread") {
        Some(Object(rt)) =>
          match rt.get("thread") {
            Some(Object(thread)) =>
              match thread.get("isResolved") {
                Some(True) => true
                _ => false
              }
            _ => false
          }
        _ => false
      }
    _ => false
  }
  if !is_resolved {
    return @types.Response::Err(
      "resolve_review_thread: thread was not marked resolved (check permissions)",
    )
  }
  @types.Response::ok_values({
    "status": String::to_json("ok"),
    "thread_id": String::to_json(thread_id),
    "resolved": Bool::to_json(true),
  })
}

///|
/// `resolve_review_thread`: capture GraphQL result and map to the tool response.
pub async fn interpret_resolve_review_thread(
  resolve_args : ResolveReviewThreadArgs,
  project_dir : String,
  capture : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  let cmd = resolve_review_thread_gh_command(
    project_dir,
    resolve_args.thread_id,
  )
  let (exit_code, output) = capture(cmd)
  interpret_resolve_review_thread_result(
    exit_code,
    output,
    resolve_args.thread_id,
  )
}

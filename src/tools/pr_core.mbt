///|
pub(all) struct FilePrPlanResult {
  response : @types.Response
  tracked_pr : @poller.TrackedPR?
  dev_event : @phase.DevEvent
  notify_message : String
}

///|
/// Pure interpreter-facing plan for side effects after `ensure_pull_request`
/// succeeds: poller registration, dev lifecycle append, and optional parent
/// auto-notify. Capability flags mirror host availability (`poller_state` /
/// `registry` injected into dispatch).
pub(all) struct FilePrPostSuccessEffects {
  poller_track : @poller.TrackedPR?
  dev_event : @phase.DevEvent
  notify_message_for_parent : String?
  response : @types.Response
}

///|
pub fn file_pr_post_success_effects(
  plan : FilePrPlanResult,
  poller_available : Bool,
  registry_available : Bool,
) -> FilePrPostSuccessEffects {
  let poller_track = match plan.tracked_pr {
    Some(tracked) => if poller_available { Some(tracked) } else { None }
    None => None
  }
  let notify_message_for_parent = if registry_available {
    Some(plan.notify_message)
  } else {
    None
  }
  {
    poller_track,
    dev_event: plan.dev_event,
    notify_message_for_parent,
    response: plan.response,
  }
}

///|
pub fn file_pr_plan(
  args : FilePrArgs,
  parent_branch : String,
  pr : PullRequestInfo,
  tracked : Bool,
) -> FilePrPlanResult {
  let tracked_pr = if tracked {
    Some(@poller.TrackedPR::{
      pr_number: pr.number,
      agent_id: args.tracked_agent_id,
      branch: args.branch,
      parent_branch,
      pr_url: pr.url,
      first_seen: 0L,
      consecutive_failures: 0,
      backoff_until: 0L,
      last_review_state: @poller.ReviewState::None_,
      last_review_bodies: "",
      last_sha: "",
      notified_parent: false,
      last_ci_failed: false,
      last_timeout_at: 0L,
    })
  } else {
    None
  }
  let dev_event = @phase.DevEvent::PRCreated(
    pr_number=pr.number,
    url=pr.url,
    branch=args.branch,
  )
  let notify_message = "[PR READY] PR #" +
    pr.number.to_string() +
    " filed: " +
    pr.url
  let response = @types.Response::ok_values({
    "status": String::to_json("pr_created"),
    "pr_number": Int::to_json(pr.number),
    "pr_url": String::to_json(pr.url),
    "tracked": Bool::to_json(tracked),
  })
  { response, tracked_pr, dev_event, notify_message }
}

///|
/// Pure plan for `file_pr` post-success auto-notify: parent resolution outcome
/// maps to delivery intent plus exact delivery-log append text. The dispatcher
/// interprets this (append logs, `execute_delivery`, moontrace on failures).
pub(all) enum FilePrAutoNotifyPlan {
  Deliver(delivery~ : @message.DeliveryMethod, delivery_log_append~ : String)
  ParentResolutionFailed(
    delivery_log_append~ : String,
    parent_resolve_error~ : String
  )
} derive(Show, Eq)

///|
pub fn file_pr_auto_notify_plan(
  parent_result : Result[@types.Agent, @types.ChoirError],
  tracked_agent_id : String,
  notify_message : String,
) -> FilePrAutoNotifyPlan {
  match parent_result {
    Ok(parent) => {
      let delivery = @message.plan_delivery(
        parent, tracked_agent_id, notify_message, "success",
      )
      let delivery_log_append = "[auto-notify] caller=" +
        tracked_agent_id +
        " parent=" +
        parent.agent_id.to_string() +
        " delivery=" +
        delivery.to_string() +
        "\n"
      Deliver(delivery~, delivery_log_append~)
    }
    Err(e) => {
      let msg = e.message()
      ParentResolutionFailed(
        delivery_log_append="[auto-notify] resolve_parent_for_notify failed error=" +
          msg +
          "\n",
        parent_resolve_error=msg,
      )
    }
  }
}

///|
pub fn file_pr_auto_notify_delivery_failed_log_append(error : String) -> String {
  "[auto-notify] delivery failed error=" + error + "\n"
}

///|
/// Typed inputs for the preflight → push → ensure-PR pipeline (before poller
/// registration and other post-success effects).
pub(all) struct FilePrPreflightCreateInputs {
  branch : String
  parent_branch : String
  file_pr_dir : String
  title : String?
  body : String?
}

///|
pub fn file_pr_preflight_create_inputs(
  args : FilePrArgs,
  parent_branch : String,
  file_pr_dir : String,
) -> FilePrPreflightCreateInputs {
  {
    branch: args.branch,
    parent_branch,
    file_pr_dir,
    title: args.title,
    body: args.body,
  }
}

///|
/// Ordered host steps for `file_pr` before post-success effects. The
/// interpreter runs this exact sequence; kept as data for tests and docs.
pub(all) enum FilePrPreflightHostStep {
  EnsureBranchReady
  GitPush
  EnsurePullRequest
} derive(Eq, Show)

///|
pub fn file_pr_preflight_host_steps() -> Array[FilePrPreflightHostStep] {
  [
    FilePrPreflightHostStep::EnsureBranchReady,
    FilePrPreflightHostStep::GitPush,
    FilePrPreflightHostStep::EnsurePullRequest,
  ]
}

///|
/// Preflight → `git push` → `ensure_pull_request`, matching the ordering and
/// `Result` error strings previously inlined in `ToolRequest::FilePr`.
pub async fn interpret_file_pr_preflight_create(
  inputs : FilePrPreflightCreateInputs,
  ensure_branch_ready : async (String, String, String) -> Result[Unit, String],
  runner : async (Array[@workspace.Command]) -> Array[Int],
  capture : async (@workspace.Command) -> (Int, String),
  ensure_pr : async (String, String, String, String?, String?) -> Result[
    PullRequestInfo,
    String,
  ],
) -> Result[PullRequestInfo, String] {
  match
    ensure_branch_ready(inputs.branch, inputs.parent_branch, inputs.file_pr_dir) {
    Err(e) => Err(e)
    Ok(_) =>
      match
        run_strict(
          runner,
          [
            {
              ..@workspace.git_push(inputs.branch),
              workdir: Some(inputs.file_pr_dir),
            },
          ],
          capture~,
        ) {
        Err(e) => Err(e)
        Ok(_) =>
          ensure_pr(
            inputs.branch,
            inputs.parent_branch,
            inputs.file_pr_dir,
            inputs.title,
            inputs.body,
          )
      }
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
) -> String? {
  match poller_tracked {
    Some(tracked) =>
      if tracked.last_review_state == @poller.ReviewState::ChangesRequested {
        return Some(
          "PR #" +
          pr_number.to_string() +
          " has unresolved review comments (ChangesRequested). " +
          "Wait for the owning agent to push fixes, or pass force=true to override.",
        )
      }
    None => ()
  }
  if unresolved_thread_count > 0 {
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

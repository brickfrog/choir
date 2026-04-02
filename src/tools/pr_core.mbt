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

///|
pub(all) enum PostToolAction {
  FinalizeAgent(
    agent_id~ : String,
    exit_reason~ : String,
    notify_parent~ : Bool
  )
  FailAgent(
    agent_id~ : String,
    reason~ : @phase.FailureReason,
    parent_message~ : String,
    exit_reason~ : String,
    close_target~ : Bool
  )
  WatchPane(agent_id~ : String)
  UpdateDevLifecycle(agent_id~ : String, event~ : @phase.DevEvent)
  DeliverToParentMerged(
    leaf_id~ : String,
    pr_number~ : Int,
    branch~ : String,
    parent_branch~ : String,
    url~ : String
  )
} derive(Show, Eq)

///|
pub fn plan_post_tool_actions(
  req : @types.Request,
  resp : @types.Response,
  merged_agent_id~ : String?,
  poller : @poller.PollerState,
  registry : @registry.AgentRegistry,
) -> Array[PostToolAction] {
  let actions : Array[PostToolAction] = []
  if !resp.is_ok() {
    return actions
  }

  // shutdown
  if req.name == "shutdown" {
    match request_agent_id(req) {
      Some(agent_id) =>
        match resp.ok_field("status") {
          Some("shutdown") =>
            actions.push(
              FinalizeAgent(
                agent_id~,
                exit_reason="shutdown",
                notify_parent=true,
              ),
            )
          _ => ()
        }
      None => ()
    }
  }

  // merge_pr
  if req.name == "merge_pr" {
    match (request_int_arg(req, "pr_number"), merged_agent_id) {
      (Some(pr_number), Some(agent_id)) => {
        actions.push(
          UpdateDevLifecycle(
            agent_id~,
            event=@phase.DevEvent::MergeObserved(pr_number~),
          ),
        )
        match registry.get(agent_id) {
          Ok(leaf) => {
            let (branch, parent_branch, url) = match poller.get(pr_number) {
              Some(t) => (t.branch, t.parent_branch, t.pr_url)
              None => (leaf.branch, "", "")
            }
            actions.push(
              DeliverToParentMerged(
                leaf_id=agent_id,
                pr_number~,
                branch~,
                parent_branch~,
                url~,
              ),
            )
          }
          Err(_) => ()
        }
        actions.push(
          FinalizeAgent(agent_id~, exit_reason="merged", notify_parent=false),
        )
      }
      _ => ()
    }
  }

  // kill_agent
  if req.name == "kill_agent" {
    match req.args.get("agent_id") {
      Some(agent_id) =>
        actions.push(
          FailAgent(
            agent_id~,
            reason=@phase.FailureReason::ParentKilled,
            parent_message="agent killed by parent",
            exit_reason="killed",
            close_target=false,
          ),
        )
      None => ()
    }
  }

  // spawn/rescue pane watchers
  if req.name == "fork_wave" ||
    req.name == "spawn_worker" ||
    req.name == "rescue_leaf" {
    let watch_ids : Array[String] = []
    match resp.ok_field("agent_ids") {
      Some(ids) =>
        for part in ids.split(",") {
          let agent_id = part.to_string().trim().to_string()
          if agent_id != "" {
            watch_ids.push(agent_id)
          }
        }
      None => ()
    }
    if req.name == "rescue_leaf" {
      match resp.ok_field("agent_id") {
        Some(agent_id) => {
          let aid = agent_id.trim().to_string()
          if aid != "" {
            watch_ids.push(aid)
          }
        }
        None => ()
      }
    }
    for agent_id in watch_ids {
      actions.push(WatchPane(agent_id~))
    }
  }
  actions
}

///|
/// Parent-facing text after `merge_pr` tool succeeds — distinct from poller pre-merge signals.
pub fn merged_pr_parent_message(
  pr_number : Int,
  leaf_agent_id : String,
  branch : String,
  parent_branch : String,
  pr_url : String,
) -> String {
  let branch_disp = if branch == "" { "<unknown>" } else { branch }
  let parent_disp = if parent_branch == "" {
    "<unknown>"
  } else {
    parent_branch
  }
  let url_line = if pr_url == "" { "" } else { "\npr_url: " + pr_url }
  "[PR MERGED] merge_pr succeeded — PR #" +
  pr_number.to_string() +
  " is merged on the remote." +
  "\nleaf_agent: " +
  leaf_agent_id +
  "\nbranch: " +
  branch_disp +
  "\nparent_branch: " +
  parent_disp +
  url_line +
  "\nAuthoritative merge signal: do not treat [PR READY], [FIXES PUSHED], or leaf updates as merged state."
}

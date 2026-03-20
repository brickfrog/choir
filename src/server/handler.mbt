///|
fn request_agent_id(req : @types.Request) -> String? {
  match req.args.get("agent_id") {
    Some(agent_id) => Some(agent_id)
    None =>
      match req.args.get("caller_id") {
        Some(agent_id) => Some(agent_id)
        None =>
          match req.args.get("sender_id") {
            Some(agent_id) => Some(agent_id)
            None => None
          }
      }
  }
}

///|
fn request_span_name(req : @types.Request) -> String {
  if req.req_method == "tools/list" {
    "tools/list"
  } else {
    "tools/call " + req.name
  }
}

///|
fn next_span_id(state : ServerState) -> String {
  let span_id = state.span_counter.to_string()
  state.span_counter = state.span_counter + 1
  span_id
}

///|
async fn emit_span(
  state : ServerState,
  req : @types.Request,
  start_sec : Int64,
  end_sec : Int64,
  resp : @types.Response,
) -> Unit {
  let (status, error_msg) = match resp {
    @types.Response::Ok(_) => ("ok", None)
    @types.Response::Err(msg) => ("error", Some(msg))
  }
  let span = Span::{
    trace_id: state.run_id,
    span_id: next_span_id(state),
    name: request_span_name(req),
    agent_id: request_agent_id(req),
    role: Some(req.role.to_string()),
    start_sec,
    end_sec,
    status,
    error_msg,
  }
  span.emit()
  match state.config.otlp_endpoint {
    Some(ep) => span.export_otlp(ep) catch { _ => () }
    None => ()
  }
}

///|
pub async fn ServerState::handle(
  self : ServerState,
  req : @types.Request,
) -> @types.Response {
  self.handle_with_runner(req, runner=@exec.run_sequence)
}

///|
pub async fn ServerState::handle_with_runner(
  self : ServerState,
  req : @types.Request,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> @types.Response {
  let start_sec = @poller.now_sec()
  let resp = if req.req_method == "tools/list" {
    @types.Response::Ok({ "tools_list": "true" })
  } else {
    @tools.handle_request(
      self.tool_registry,
      req,
      project_dir=self.config.project_dir,
      session=self.config.tmux_session,
      runner~,
      extra_mcp_servers_json=self.config.extra_mcp_servers_json,
      shell_command=self.config.shell_command,
      agent_registry=Some(self.registry),
      mutex_registry=Some(self.mutex_registry),
      poller_state=Some(self.poller),
      plugins_json=self.config.plugins_json,
    )
  }
  let end_sec = @poller.now_sec()
  emit_span(self, req, start_sec, end_sec, resp)
  resp
}

///|
pub fn ServerState::register_agent(
  self : ServerState,
  agent : @types.Agent,
) -> Result[Unit, @types.ExoError] {
  self.registry.insert(agent)
}

///|
pub fn ServerState::notify_parent(
  self : ServerState,
  caller_id : String,
  message : String,
  status : String,
) -> Result[@message.DeliveryMethod, @types.ExoError] {
  match self.registry.get_parent(caller_id) {
    Ok(parent) => Ok(@message.plan_delivery(parent, caller_id, message, status))
    Err(e) => Err(e)
  }
}

///|
fn render_parent_next_action(
  pr_number : Int,
  parent_branch : String?,
) -> String {
  match parent_branch {
    Some(branch) =>
      "Next action: `merge_pr(pr_number: \"" +
      pr_number.to_string() +
      "\", parent_branch: \"" +
      branch +
      "\")`"
    None =>
      "Next action: merge PR #" +
      pr_number.to_string() +
      " once the parent branch is confirmed."
  }
}

///|
fn parent_poll_event_message(
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
) -> (String, String)? {
  let agent_id = tracked.agent_id
  let branch = tracked.branch
  let parent_branch = if tracked.parent_branch == "" {
    None
  } else {
    Some(tracked.parent_branch)
  }
  let pr_url = if tracked.pr_url == "" {
    ""
  } else {
    "\npr_url: " + tracked.pr_url
  }
  match event {
    PRReady(n) => {
      let message = "[PR READY] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " approved\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        render_parent_next_action(n, parent_branch)
      Some((message, "success"))
    }
    FixesPushed(n) => {
      let message = "[FIXES PUSHED] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " has new commits after review\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        "Next action: re-check the PR and merge when ready."
      Some((message, "info"))
    }
    ReviewTimeout(n) => {
      let message = "[REVIEW TIMEOUT] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " has no review after 15min\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        "Next action: inspect the PR or retrigger review."
      Some((message, "failure"))
    }
    ReviewReceived(_, _) => None
    CIFailed(_) => None
  }
}

///|
fn poll_event_pr_number(event : @poller.PollEvent) -> Int {
  match event {
    PRReady(n) => n
    ReviewReceived(n, _) => n
    FixesPushed(n) => n
    ReviewTimeout(n) => n
    CIFailed(n) => n
  }
}

///|
fn owner_poll_event_message(event : @poller.PollEvent) -> (String, String)? {
  match event {
    ReviewReceived(n, comments) =>
      if comments == "" {
        Some(("[REVIEW] PR #" + n.to_string() + " has review comments", "info"))
      } else {
        Some(
          (
            "[REVIEW] PR #" +
            n.to_string() +
            " has review comments:\n" +
            comments,
            "info",
          ),
        )
      }
    CIFailed(n) =>
      Some(
        ("[CI FAILED] PR #" + n.to_string() + " CI checks failing", "failure"),
      )
    PRReady(_) => None
    FixesPushed(_) => None
    ReviewTimeout(_) => None
  }
}

///|
pub fn ServerState::plan_poll_event_delivery(
  self : ServerState,
  event : @poller.PollEvent,
  agent_id : String,
) -> @message.DeliveryMethod? {
  let owner = match self.registry.get(agent_id) {
    Ok(agent) => Some(agent)
    Err(_) => None
  }
  let tracked = self.poller.get(poll_event_pr_number(event))
  match owner {
    Some(agent) => {
      let parent_message = match tracked {
        Some(pr) => parent_poll_event_message(pr, event)
        None => None
      }
      match parent_message {
        Some((message, status)) =>
          match self.registry.get_parent(agent_id) {
            Ok(parent) =>
              Some(@message.plan_delivery(parent, agent_id, message, status))
            Err(_) =>
              Some(@message.plan_delivery(agent, "poller", message, status))
          }
        None =>
          match owner_poll_event_message(event) {
            Some((message, status)) =>
              Some(@message.plan_delivery(agent, "poller", message, status))
            None => None
          }
      }
    }
    None => None
  }
}

///|
pub fn ServerState::list_agents(self : ServerState) -> Array[@types.Agent] {
  self.registry.list()
}

///|
pub fn ServerState::get_agent(
  self : ServerState,
  agent_id : String,
) -> Result[@types.Agent, @types.ExoError] {
  self.registry.get(agent_id)
}

///|
/// Called when a connection closes. Detects unexpected agent death and notifies parent.
pub async fn ServerState::handle_disconnect(
  self : ServerState,
  agent_id : String,
) -> Unit {
  match self.registry.get(agent_id) {
    Err(_) => ()
    Ok(agent) =>
      match agent.state {
        Done | Failed => ()
        Completing =>
          ignore(self.registry.set_state(agent_id, @types.AgentState::Done))
        _ => {
          ignore(self.registry.set_state(agent_id, @types.AgentState::Failed))
          match self.registry.get_parent(agent_id) {
            Err(_) => ()
            Ok(parent) => {
              let msg = "[FAILED: " +
                agent_id +
                "] disconnected unexpectedly - agent may have crashed or run out of context"
              let delivery = @message.plan_delivery(
                parent, agent_id, msg, "failure",
              )
              ignore(
                @tools.execute_delivery(delivery, @exec.run_sequence) catch {
                  _ => Ok(())
                },
              )
            }
          }
        }
      }
  }
}

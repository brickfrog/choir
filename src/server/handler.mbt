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
  let span = Span::{
    trace_id: state.run_id,
    span_id: next_span_id(state),
    name: request_span_name(req),
    agent_id: request_agent_id(req),
    role: Some(req.role.to_string()),
    start_sec,
    end_sec,
    status: resp.status_tag(),
    error_msg: resp.error_message(),
  }
  span.emit()
  match state.config.otlp_endpoint {
    Some(ep) => span.export_otlp(ep) catch { _ => () }
    None => ()
  }
  let agent_id_str = request_agent_id(req).unwrap_or("")
  if agent_id_str != "" {
    let data = "{\"tool\":\"" +
      escape_for_json(req.name) +
      "\",\"status\":\"" +
      resp.status_tag() +
      "\"}"
    ignore(
      append_event(state.config.project_dir, agent_id_str, "tools.call", data),
    )
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
    @types.Response::ok({ "tools_list": "true" })
  } else {
    @tools.handle_request(
      self.tool_registry,
      req,
      project_dir=self.config.project_dir,
      session=self.config.terminal_session,
      terminal_backend=self.config.terminal_backend,
      runner~,
      extra_mcp_servers_json=self.config.extra_mcp_servers_json,
      shell_command=self.config.shell_command,
      listen_uds=self.config.listen_uds,
      listen_tcp=self.config.listen_tcp,
      tcp_auth_token=self.config.tcp_auth_token,
      agent_registry=Some(self.registry),
      mutex_registry=Some(self.mutex_registry),
      poller_state=Some(self.poller),
      plugins_json=self.config.plugins_json,
    )
  }
  let end_sec = @poller.now_sec()
  emit_span(self, req, start_sec, end_sec, resp) catch {
    _ => ()
  }
  resp
}

///|
pub fn ServerState::register_agent(
  self : ServerState,
  agent : @types.Agent,
) -> Result[Unit, @types.ExoError] {
  self.clear_pending_disconnect(agent.agent_id)
  ignore(self.registry.upsert(agent))
  Ok(())
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
    ReviewReceived(n, comments) =>
      if comments == "" {
        Some(
          (
            "[REVIEW] " +
            agent_id +
            " PR #" +
            n.to_string() +
            " has review comments\n" +
            "branch: " +
            branch +
            "\n" +
            "parent_branch: " +
            parent_branch.unwrap_or("<unknown>") +
            pr_url,
            "info",
          ),
        )
      } else {
        Some(
          (
            "[REVIEW] " +
            agent_id +
            " PR #" +
            n.to_string() +
            " has review comments:\n" +
            comments,
            "info",
          ),
        )
      }
    CIFailed(n) =>
      Some(
        (
          "[CI FAILED] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " CI checks failing\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url,
          "failure",
        ),
      )
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
pub fn ServerState::plan_poll_event_deliveries(
  self : ServerState,
  event : @poller.PollEvent,
  agent_id : String,
) -> Array[@message.DeliveryMethod] {
  let deliveries : Array[@message.DeliveryMethod] = []
  let owner = match self.registry.get(agent_id) {
    Ok(agent) => Some(agent)
    Err(_) => None
  }
  let tracked = self.poller.get(poll_event_pr_number(event))
  match (tracked, event) {
    (Some(_), ReviewReceived(n, body)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        agent_id,
        @phase.DevEvent::ReviewReceivedEv(n, body),
      )
    (Some(_), PRReady(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        agent_id,
        @phase.DevEvent::ReviewApprovedEv(n),
      )
    (Some(pr), FixesPushed(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        agent_id,
        @phase.DevEvent::FixesPushedEv(n, pr.last_sha),
      )
    _ => ()
  }
  // Parent notification — all event types
  match tracked {
    Some(pr) =>
      match parent_poll_event_message(pr, event) {
        Some((message, status)) =>
          match self.registry.get_parent(agent_id) {
            Ok(parent) => {
              ignore(
                @sys.append_file_sync(
                  ".choir/delivery.log",
                  "[poller-parent] agent=" +
                  agent_id +
                  " parent=" +
                  parent.agent_id +
                  " terminal_target=" +
                  parent.terminal_target.unwrap_or("NONE") +
                  "\n",
                ),
              )
              deliveries.push(
                @message.plan_delivery(parent, agent_id, message, status),
              )
            }
            Err(_) => ()
          }
        None => ()
      }
    None => ()
  }
  // Owner notification — review details, CI status — only if agent is alive
  match owner {
    Some(agent) =>
      match agent.state {
        @types.AgentState::Active | @types.AgentState::Completing =>
          match owner_poll_event_message(event) {
            Some((message, status)) =>
              deliveries.push(
                @message.plan_delivery(agent, "poller", message, status),
              )
            None => ()
          }
        _ => () // Done/Failed/Spawning — skip owner delivery
      }
    None => ()
  }
  deliveries
}

///|
/// Generate a PR comment body for a poll event, if it warrants one.
fn pr_comment_body(
  event : @poller.PollEvent,
  agent_id : String,
) -> (Int, String)? {
  match event {
    ReviewReceived(n, _) =>
      Some(
        (
          n,
          "**Choir:** review received — routed to `" +
          agent_id +
          "` and parent for triage.",
        ),
      )
    PRReady(n) =>
      Some(
        (
          n, "**Choir:** PR approved — parent notified, awaiting merge decision.",
        ),
      )
    CIFailed(n) =>
      Some(
        (
          n,
          "**Choir:** CI checks failing — routed to `" +
          agent_id +
          "` for fixes.",
        ),
      )
    FixesPushed(n) =>
      Some(
        (
          n,
          "**Choir:** fixes pushed by `" +
          agent_id +
          "` — awaiting re-review.",
        ),
      )
    ReviewTimeout(_) => None
  }
}

///|
async fn deliver_pending_poll_events(
  state : ServerState,
  pending_events : Array[@poller.PollEvent],
  pending_agent_ids : Array[String],
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  for i = 0; i < pending_events.length(); i = i + 1 {
    let event = pending_events[i]
    let agent_id = pending_agent_ids[i]
    for delivery in state.plan_poll_event_deliveries(event, agent_id) {
      ignore(@tools.execute_delivery(delivery, runner))
    }
    // Post a comment on the PR for audit trail
    match pr_comment_body(event, agent_id) {
      Some((pr_number, body)) =>
        ignore(
          runner([
            @workspace.gh_pr_comment(pr_number, body, state.config.project_dir),
          ]),
        )
      None => ()
    }
  }
}

///|
pub async fn ServerState::process_poller_tick_with(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  poll : async (Int) -> (@poller.ReviewState, String, Bool, String, Bool),
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  let pending_events = []
  let pending_agent_ids = []
  self.poller.tick_with(now, timeout, poll, fn(event, agent_id) {
    pending_events.push(event)
    pending_agent_ids.push(agent_id)
  })
  deliver_pending_poll_events(self, pending_events, pending_agent_ids, runner)
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
pub async fn ServerState::process_poller_tick(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  let n_before = self.poller.tracked.length()
  let pending_events = []
  let pending_agent_ids = []
  self.poller.tick(now, timeout, fn(event, agent_id) {
    pending_events.push(event)
    pending_agent_ids.push(agent_id)
  })
  let n_after = self.poller.tracked.length()
  if pending_events.length() > 0 || n_before != n_after {
    println(
      "[poller] tick at \{now}: \{n_before} PRs, \{pending_events.length()} events",
    )
    for i = 0; i < pending_events.length(); i = i + 1 {
      println(
        "[poller] event: \{pending_events[i]} for \{pending_agent_ids[i]}",
      )
    }
    if n_before != n_after {
      println("[poller] tracked PRs: \{n_before} -> \{n_after}")
    }
  }
  deliver_pending_poll_events(self, pending_events, pending_agent_ids, runner)
  ignore(self.poller.write_state_file(self.config.project_dir))
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
/// Agents with tracked PRs are skipped — the poller manages their lifecycle.
pub async fn ServerState::handle_disconnect_with_runner(
  self : ServerState,
  agent_id : String,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  // If the agent has a tracked PR, the poller owns its lifecycle.
  // Connection drops are normal for per-request agents (Gemini) that go idle
  // between tool calls or while waiting for review.
  if self.poller.has_tracked_pr(agent_id) {
    return
  }
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
                @tools.execute_delivery(delivery, runner) catch {
                  _ => Ok(())
                },
              )
            }
          }
        }
      }
  }
}

///|
pub async fn ServerState::handle_disconnect(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.handle_disconnect_with_runner(agent_id, runner=@exec.run_sequence)
}

///|
/// Schedule a disconnect instead of firing immediately.
/// The pending disconnect is resolved on the next poller tick after the grace period.
pub fn ServerState::schedule_disconnect(
  self : ServerState,
  agent_id : String,
  now : Int64,
) -> Unit {
  self.pending_disconnects.set(agent_id, now)
}

///|
/// Clear a pending disconnect (called when an agent re-registers).
pub fn ServerState::clear_pending_disconnect(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.pending_disconnects.remove(agent_id)
}

///|
/// Process pending disconnects older than grace_seconds. Fire handle_disconnect for stale ones.
pub async fn ServerState::process_pending_disconnects_with_runner(
  self : ServerState,
  now : Int64,
  grace_seconds : Int64,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  let stale : Array[String] = []
  for agent_id, disconnect_time in self.pending_disconnects {
    if now - disconnect_time >= grace_seconds {
      stale.push(agent_id)
    }
  }
  for agent_id in stale {
    self.pending_disconnects.remove(agent_id)
    self.handle_disconnect_with_runner(agent_id, runner~)
  }
}

///|
pub async fn ServerState::process_pending_disconnects(
  self : ServerState,
  now : Int64,
  grace_seconds : Int64,
) -> Unit {
  self.process_pending_disconnects_with_runner(
    now,
    grace_seconds,
    runner=@exec.run_sequence,
  )
}

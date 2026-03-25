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
async fn emit_span(
  state : ServerState,
  req : @types.Request,
  start_ms : UInt64,
  end_ms : UInt64,
  resp : @types.Response,
) -> Unit {
  let name = request_span_name(req)
  let agent_id_str = request_agent_id(req).unwrap_or("")
  let role_str = req.role.to_string()
  let status = resp.status_tag()
  let duration_ms = end_ms - start_ms
  let fields = @moontrace.fields([
    ("agent_id", agent_id_str.to_json()),
    ("role", role_str.to_json()),
    ("status", status.to_json()),
    ("duration_ms", duration_ms.to_json()),
  ])
  match resp.error_message() {
    Some(msg) => fields.push({ key: "error", value: msg.to_json() })
    None => ()
  }
  @moontrace.info(name, fields~)
  match state.config.otlp_endpoint {
    Some(ep) => {
      let mt_span = @moontrace.span_with_trace(
        name,
        normalize_trace_id(state.run_id),
        fields~,
      )
      mt_span.start_time = start_ms
      mt_span.end_time = end_ms
      let status_code = if resp.is_ok() { 1 } else { 2 }
      let status_message = resp.error_message().unwrap_or("")
      let otlp_span = @otlp.span_to_otlp(mt_span, status_code~, status_message~)
      export_otlp_span(otlp_span, ep) catch {
        _ => ()
      }
    }
    None => ()
  }
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
  let start_ms = @env.now()
  let resp = if req.req_method == "tools/list" {
    @types.Response::ok({ "tools_list": "true" })
  } else {
    @tools.handle_request(
      self.tool_registry,
      req,
      project_dir=self.config.project_dir,
      session=self.config.terminal_session,
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
  let end_ms = @env.now()
  emit_span(self, req, start_ms, end_ms, resp) catch {
    _ => ()
  }
  // Start pane watchers for newly spawned agents
  if (req.name == "fork_wave" || req.name == "spawn_worker") && resp.is_ok() {
    match resp.ok_field("agent_ids") {
      Some(ids) =>
        for part in ids.split(",") {
          let agent_id = part.to_string().trim().to_string()
          if agent_id == "" {
            continue
          }
          match self.registry.get(agent_id) {
            Ok(agent) =>
              match agent.terminal_target {
                Some(_) => self.watch_pane(agent_id)
                None => ()
              }
            Err(_) => ()
          }
        }
      None => ()
    }
  }
  resp
}

///|
pub fn ServerState::register_agent(
  self : ServerState,
  agent : @types.Agent,
) -> Result[Unit, @types.ExoError] {
  self.clear_pending_disconnect(agent.agent_id.to_string())
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
        @phase.DevEvent::ReviewReceivedEv(pr_number=n, body~),
      )
    (Some(_), PRReady(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        agent_id,
        @phase.DevEvent::ReviewApprovedEv(pr_number=n),
      )
    (Some(pr), FixesPushed(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        agent_id,
        @phase.DevEvent::FixesPushedEv(pr_number=n, sha=pr.last_sha),
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
                  parent.agent_id.to_string() +
                  " terminal_target=" +
                  parent.terminal_target
                  .map(@types.LocalTarget::to_string)
                  .unwrap_or("NONE") +
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
    @moontrace.info(
      "poller tick",
      fields=@moontrace.fields([
        ("prs", n_before.to_json()),
        ("events", pending_events.length().to_json()),
      ]),
    )
    for i = 0; i < pending_events.length(); i = i + 1 {
      @moontrace.info(
        "poller event",
        fields=@moontrace.fields([
          ("event", pending_events[i].to_string().to_json()),
          ("agent", pending_agent_ids[i].to_json()),
        ]),
      )
    }
    if n_before != n_after {
      @moontrace.info(
        "poller tracking changed",
        fields=@moontrace.fields([
          ("before", n_before.to_json()),
          ("after", n_after.to_json()),
        ]),
      )
    }
  }
  deliver_pending_poll_events(self, pending_events, pending_agent_ids, runner)
  ignore(self.poller.write_state_file(self.config.project_dir))
}

///|
/// Register a pane for idle watchdog monitoring.
/// Starts a `zellij subscribe` process that streams pane viewport updates
/// to a snapshot file, replacing the old dump-screen polling approach.
pub fn ServerState::watch_pane(self : ServerState, agent_id : String) -> Unit {
  self.pane_watchers.set(agent_id, @poller.now_sec())
  let agent = match self.registry.get(agent_id) {
    Ok(a) => a
    Err(_) => return
  }
  let target = match agent.terminal_target {
    Some(t) => t
    None => return
  }
  let snapshot_path = "/tmp/choir-viewport-" + agent_id + ".json"
  // Pipe: zellij subscribe streams JSON, shell overwrites snapshot on each line
  let cmd = "zellij --session '" +
    target.session +
    "' subscribe pane-viewport --pane-id '" +
    target.name +
    "' --format json 2>/dev/null | while IFS= read -r line; do printf '%s' \"$line\" > '" +
    snapshot_path +
    "'; done"
  // Background the subscribe pipeline; store its PID via a pidfile
  let pid_path = "/tmp/choir-subscribe-" + agent_id + ".pid"
  let bg_cmd = cmd + " & echo $! > '" + pid_path + "'"
  ignore(c_system(string_to_null_terminated_bytes(bg_cmd)))
  let pid_str = @sys.read_file(pid_path).trim().to_string()
  let pid = parse_int_simple(pid_str)
  if pid > 0 {
    self.subscribe_pids.set(agent_id, pid)
  }
}

///|
fn parse_int_simple(s : String) -> Int {
  let mut result = 0
  for c in s {
    let d = c.to_int() - '0'.to_int()
    if d >= 0 && d <= 9 {
      result = result * 10 + d
    }
  }
  result
}

///|
/// Stop the zellij subscribe process for an agent and clean up state.
fn ServerState::stop_subscribe(self : ServerState, agent_id : String) -> Unit {
  match self.subscribe_pids.get(agent_id) {
    Some(pid) => {
      ignore(
        c_system(
          string_to_null_terminated_bytes(
            "kill " + pid.to_string() + " 2>/dev/null || true",
          ),
        ),
      )
      self.subscribe_pids.remove(agent_id)
    }
    None => ()
  }
  ignore(
    c_system(
      string_to_null_terminated_bytes(
        "rm -f '/tmp/choir-viewport-" +
        agent_id +
        ".json' '/tmp/choir-subscribe-" +
        agent_id +
        ".pid'",
      ),
    ),
  )
}

///|
/// Extract viewport text from a zellij subscribe JSON snapshot.
/// Format: {"event":"pane_update","viewport":["line1","line2",...]}
fn extract_viewport_text(json_str : String) -> String {
  if json_str == "" {
    return ""
  }
  let parsed : Json = @json.parse(json_str) catch { _ => return json_str }
  match parsed {
    Object(obj) =>
      match obj.get("viewport") {
        Some(Array(lines)) => {
          let buf = StringBuilder::new()
          for line in lines {
            match line {
              String(s) => {
                buf.write_string(s)
                buf.write_char('\n')
              }
              _ => ()
            }
          }
          buf.to_string()
        }
        _ => json_str
      }
    _ => json_str
  }
}

///|
fn simple_hash(s : String) -> Int {
  let mut h = 0
  for c in s {
    h = h * 31 + c.to_int()
  }
  h
}

///|
/// Check for idle agents by dumping pane screens and comparing hashes.
/// If a pane's screen hasn't changed for `timeout` seconds, kill the agent.
pub async fn ServerState::check_idle_agents(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  let agent_ids = []
  self.pane_watchers.each(fn(agent_id, _) { agent_ids.push(agent_id) })
  for agent_id in agent_ids {
    let agent = match self.registry.get(agent_id) {
      Ok(a) => a
      Err(_) => {
        self.stop_subscribe(agent_id)
        self.pane_watchers.remove(agent_id)
        self.pane_hashes.remove(agent_id)
        continue
      }
    }
    if agent.state != @types.AgentState::Active {
      self.stop_subscribe(agent_id)
      self.pane_watchers.remove(agent_id)
      self.pane_hashes.remove(agent_id)
      continue
    }
    if agent.role == @types.Role::Root || agent.role == @types.Role::TL {
      continue
    }
    // Skip agents with tracked PRs awaiting review
    let mut has_tracked_pr = false
    self.poller.tracked.each(fn(_pr_num, tracked) {
      if tracked.agent_id == agent_id {
        has_tracked_pr = true
      }
    })
    if has_tracked_pr {
      continue
    }
    let target = match agent.terminal_target {
      Some(t) => t
      None => continue
    }
    // Read viewport snapshot written by the zellij subscribe process
    let snapshot_path = "/tmp/choir-viewport-" + agent_id + ".json"
    let snapshot = @sys.read_file(snapshot_path)
    // Extract viewport lines from JSON: {"viewport":["line1","line2",...]}
    let screen = extract_viewport_text(snapshot)
    let hash = simple_hash(screen)
    let prev_hash = self.pane_hashes.get(agent_id).unwrap_or(0)
    if hash != prev_hash {
      self.pane_watchers.set(agent_id, now)
      self.pane_hashes.set(agent_id, hash)
      continue
    }
    // Screen unchanged — check if idle too long
    let last_change = self.pane_watchers.get(agent_id).unwrap_or(now)
    let elapsed = now - last_change
    if elapsed < timeout {
      continue
    }
    // Kill the agent
    @moontrace.warn(
      "watchdog killing idle agent",
      fields=@moontrace.fields([
        ("agent", agent_id.to_json()),
        ("idle_sec", elapsed.to_json()),
      ]),
    )
    @tools.fire_hook_async(
      @hooks.HookEvent::AgentExit,
      {
        event: @hooks.HookEvent::AgentExit,
        session_id: None,
        agent_id: Some(agent_id),
        role: Some(agent.role),
        tool_name: None,
        tool_args: None,
        tool_result_status: None,
        exit_reason: Some("watchdog"),
      },
      self.config.project_dir,
      runner,
    )
    ignore(runner([@workspace.local_close_target(target)]) catch { _ => [] })
    ignore(self.registry.set_state(agent_id, @types.AgentState::Failed))
    self.stop_subscribe(agent_id)
    self.pane_watchers.remove(agent_id)
    self.pane_hashes.remove(agent_id)
    // Notify parent
    match agent.parent {
      Some(parent_id) =>
        match self.registry.get(parent_id) {
          Ok(parent) => {
            let message = "[WATCHDOG] agent " +
              agent_id +
              " killed after " +
              elapsed.to_string() +
              "s idle (no pane output change)"
            let delivery = @message.plan_delivery(
              parent, agent_id, message, "failure",
            )
            ignore(@tools.execute_delivery(delivery, runner))
          }
          Err(_) => ()
        }
      None => ()
    }
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

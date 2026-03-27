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
  let merged_agent_id = if req.name == "merge_pr" {
    match req.args.get_int("pr_number") {
      Some(pr_number) =>
        match self.poller.get(pr_number) {
          Some(tracked) => Some(tracked.agent_id)
          None => None
        }
      None => None
    }
  } else {
    None
  }
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
  if req.name == "shutdown" && resp.is_ok() {
    match request_agent_id(req) {
      Some(agent_id) =>
        match resp.ok_field("status") {
          Some("shutdown") =>
            self.finalize_agent_with_runner(
              agent_id,
              "shutdown",
              runner,
              notify_parent=true,
            )
          _ => ()
        }
      None => ()
    }
  }
  if req.name == "merge_pr" && resp.is_ok() {
    match (req.args.get_int("pr_number"), merged_agent_id) {
      (Some(pr_number), Some(agent_id)) => {
        ignore(
          @tools.apply_dev_event_checked(
            self.config.project_dir,
            agent_id,
            @phase.DevEvent::MergeObserved(pr_number~),
          ),
        )
        match self.registry.get(agent_id) {
          Ok(leaf) =>
            match leaf.parent {
              Some(parent_id) =>
                match self.resolve_parent_by_id(parent_id) {
                  Ok(parent) => {
                    let (branch, parent_branch_str, url) = match
                      self.poller.get(pr_number) {
                      Some(t) => (t.branch, t.parent_branch, t.pr_url)
                      None => (leaf.branch, "", "")
                    }
                    let body = merged_pr_parent_message(
                      pr_number, agent_id, branch, parent_branch_str, url,
                    )
                    let delivery = @message.plan_delivery(
                      parent, agent_id, body, "success",
                    )
                    ignore(
                      @tools.execute_delivery(delivery, runner) catch {
                        _ => Ok(())
                      },
                    )
                  }
                  Err(_) => ()
                }
              None => ()
            }
          Err(_) => ()
        }
        self.finalize_agent_with_runner(
          agent_id,
          "merged",
          runner,
          notify_parent=false,
        )
      }
      _ => ()
    }
  }
  if req.name == "kill_agent" && resp.is_ok() {
    match req.args.get("agent_id") {
      Some(agent_id) =>
        self.fail_agent_with_runner(
          agent_id,
          @phase.FailureReason::ParentKilled,
          "agent killed by parent",
          "killed",
          runner,
          close_target=false,
        )
      _ => ()
    }
  }
  let end_ms = @env.now()
  emit_span(self, req, start_ms, end_ms, resp) catch {
    _ => ()
  }
  // Start pane watchers for newly spawned agents
  if (
      req.name == "fork_wave" ||
      req.name == "spawn_worker" ||
      req.name == "rescue_leaf"
    ) &&
    resp.is_ok() {
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
      match self.registry.get(agent_id) {
        Ok(agent) =>
          match agent.terminal_target {
            Some(_) => self.watch_pane(agent_id)
            None => ()
          }
        Err(_) => ()
      }
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
  let agent_id = agent.agent_id.to_string()
  let lifecycle = match
    @phase.read_lifecycle(self.config.project_dir, agent_id) {
    Some(existing) =>
      match existing.process {
        @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) =>
          existing
        _ => { ..existing, process: @phase.ProcessState::Connected }
      }
    None => @phase.lifecycle_for_agent(agent)
  }
  ignore(self.registry.upsert({ ..agent, state: lifecycle.to_agent_state() }))
  ignore(self.persist_lifecycle(lifecycle))
  self.sync_parent_child_lifecycle(agent_id, lifecycle)
  Ok(())
}

///|
pub fn ServerState::notify_parent(
  self : ServerState,
  caller_id : String,
  message : String,
  status : String,
) -> Result[@message.DeliveryMethod, @types.ExoError] {
  match self.resolve_parent_for_delivery(caller_id) {
    Ok(parent) => Ok(@message.plan_delivery(parent, caller_id, message, status))
    Err(e) => Err(e)
  }
}

///|
fn synthesized_parent_terminal_target(
  session : String,
  parent_id : String,
  role : @types.Role,
) -> @types.LocalTarget {
  let slug = match role {
    @types.Role::Root | @types.Role::TL => "TL"
    _ => @phase.extract_slug(parent_id)
  }
  @workspace.local_target_for(session, slug, @types.IsolationMode::Worktree)
}

///|
fn synthesized_parent_agent_type(role : @types.Role) -> @types.AgentType {
  match role {
    @types.Role::Worker => @types.AgentType::Claude
    _ => @types.AgentType::Claude
  }
}

///|
fn ServerState::resolve_parent_by_id(
  self : ServerState,
  parent_id : String,
) -> Result[@types.Agent, @types.ExoError] {
  match self.registry.get(parent_id) {
    Ok(parent) => Ok(parent)
    Err(_) =>
      match @phase.read_lifecycle(self.config.project_dir, parent_id) {
        Some(lifecycle) =>
          Ok({
            agent_id: parent_id,
            role: lifecycle.role,
            agent_type: synthesized_parent_agent_type(lifecycle.role),
            parent: None,
            workspace: self.config.project_dir,
            branch: parent_id,
            terminal_target: Some(
              synthesized_parent_terminal_target(
                self.config.terminal_session,
                parent_id,
                lifecycle.role,
              ),
            ),
            host: @types.Host::Local,
            state: lifecycle.to_agent_state(),
            spawn_depth: 0,
          })
        None => Err(@types.ExoError::AgentNotFound(parent_id))
      }
  }
}

///|
fn ServerState::resolve_parent_for_delivery(
  self : ServerState,
  caller_id : String,
) -> Result[@types.Agent, @types.ExoError] {
  match self.registry.get(caller_id) {
    Ok(agent) =>
      match agent.parent {
        Some(parent_id) => self.resolve_parent_by_id(parent_id)
        None =>
          Err(@types.ExoError::AgentNotFound("no parent for " + caller_id))
      }
    Err(e) => Err(e)
  }
}

///|
/// Parent-facing text after `merge_pr` tool succeeds — distinct from poller pre-merge signals.
fn merged_pr_parent_message(
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
        " approved (not merged yet)\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        "Pre-merge: wait for [PR MERGED] after merge_pr succeeds (or verify merged on GitHub) before claiming merged.\n" +
        render_parent_next_action(n, parent_branch)
      Some((message, "success"))
    }
    FixesPushed(n) => {
      let message = "[FIXES PUSHED] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " has new commits after review (not merged yet)\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        "Pre-merge: re-check the PR; merge only after review is clear and merge_pr succeeds.\n" +
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
    ReviewCommented(n, comments) =>
      if comments == "" {
        Some(
          (
            "[REVIEW] " +
            agent_id +
            " PR #" +
            n.to_string() +
            " has non-blocking review comments\n" +
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
            " has non-blocking review comments:\n" +
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
    ReviewCommented(n, _) => n
    FixesPushed(n) => n
    ReviewTimeout(n) => n
    CIFailed(n) => n
  }
}

///|
/// Cap API review bodies for terminal injection (Copilot/GitHub can return full PR markdown).
let review_summary_pane_max_chars : Int = 2500

///|
fn clamp_review_summary_for_pane(body : String) -> String {
  let suffix = "\n... [truncated; open PR on GitHub for full review text]"
  if body.length() <= review_summary_pane_max_chars {
    body
  } else {
    body[0:review_summary_pane_max_chars].to_string() + suffix
  }
}

///|
/// Direct review/CI injection for the owning leaf pane (`plan_delivery` adds `[from: …]`).
/// Parent still receives `parent_poll_event_message` for triage/merge except
/// `ReviewCommented` (non-blocking thread goes to the leaf only).
fn leaf_poll_review_injection_message(
  event : @poller.PollEvent,
) -> (String, String)? {
  match event {
    ReviewReceived(n, body) =>
      Some(
        (
          if body == "" {
            "[REVIEW] PR #" + n.to_string() + ": changes requested"
          } else {
            "[REVIEW] PR #" +
            n.to_string() +
            ": " +
            clamp_review_summary_for_pane(body)
          },
          "info",
        ),
      )
    ReviewCommented(n, body) =>
      Some(
        (
          if body == "" {
            "[REVIEW] PR #" + n.to_string() + ": non-blocking review comments"
          } else {
            "[REVIEW] PR #" +
            n.to_string() +
            ": " +
            clamp_review_summary_for_pane(body)
          },
          "info",
        ),
      )
    CIFailed(n) =>
      Some(("[REVIEW] PR #" + n.to_string() + ": CI checks failing", "failure"))
    PRReady(n) =>
      Some(
        (
          "[REVIEW] PR #" +
          n.to_string() +
          ": approved (not merged until merge_pr succeeds)",
          "success",
        ),
      )
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
  let tracked = self.poller.get(poll_event_pr_number(event))
  let leaf_agent_id = match tracked {
    Some(pr) => pr.agent_id
    None => agent_id
  }
  let leaf_owner = match self.registry.get(leaf_agent_id) {
    Ok(agent) => Some(agent)
    Err(_) => None
  }
  match (tracked, event) {
    (Some(_), ReviewReceived(n, body)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::ReviewReceivedEv(pr_number=n, body~),
      )
    (Some(_), ReviewCommented(_, _)) => ()
    (Some(_), PRReady(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::ReviewApprovedEv(pr_number=n),
      )
    (Some(pr), FixesPushed(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::FixesPushedEv(pr_number=n, sha=pr.last_sha),
      )
    _ => ()
  }
  self.sync_parent_child_lifecycle(
    leaf_agent_id,
    self.current_lifecycle(leaf_agent_id),
  )
  // Parent notification — TL triage / merge signals (comment-only reviews: leaf only)
  match tracked {
    Some(pr) =>
      match parent_poll_event_message(pr, event) {
        Some((message, status)) =>
          match event {
            ReviewCommented(_, _) => () // comment-only: owning leaf pane only
            _ =>
              match self.resolve_parent_for_delivery(leaf_agent_id) {
                Ok(parent) => {
                  ignore(
                    @sys.append_file_sync(
                      ".choir/delivery.log",
                      "[poller-parent] agent=" +
                      leaf_agent_id +
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
                    @message.plan_delivery(
                      parent, leaf_agent_id, message, status,
                    ),
                  )
                }
                Err(_) => ()
              }
          }
        None => ()
      }
    None => ()
  }
  // Owning leaf — direct `[REVIEW] PR #n: …` injection (terminal_target in registry)
  match leaf_owner {
    Some(agent) =>
      match agent.state {
        @types.AgentState::Active | @types.AgentState::Completing =>
          match leaf_poll_review_injection_message(event) {
            Some((message, status)) =>
              deliveries.push(
                @message.plan_delivery(agent, "poller", message, status),
              )
            None => ()
          }
        _ => () // Done/Failed/Spawning — skip leaf delivery
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
    ReviewCommented(n, _) =>
      Some(
        (
          n,
          "**Choir:** comment-only review received — routed to `" +
          agent_id +
          "` (leaf pane).",
        ),
      )
    PRReady(n) =>
      Some(
        (
          n, "**Choir:** PR approved — parent notified. PR is not merged until merge_pr succeeds.",
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
          "` — awaiting re-review (not merged yet).",
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
fn append_poller_delivery_line(line : String) -> Unit {
  ignore(
    @sys.append_file_sync(".choir/delivery.log", "[poller] " + line + "\n"),
  )
}

///|
fn poller_sanitize_event_for_log(raw : String) -> String {
  let buf = StringBuilder::new()
  for c in raw {
    if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else {
      buf.write_char(c)
    }
  }
  let escaped = buf.to_string()
  let max_len = 200
  if escaped.length() <= max_len {
    escaped
  } else {
    escaped[0:max_len].to_string() + "..."
  }
}

///|
fn poll_events_delivery_summary(events : Array[@poller.PollEvent]) -> String {
  if events.length() == 0 {
    return "no change"
  }
  let parts : Array[String] = []
  for e in events {
    parts.push(poller_sanitize_event_for_log(e.to_string()))
  }
  parts.join("; ")
}

///|
fn log_poller_pr_tick(log : @poller.PollerPrTickLog) -> Unit {
  let action = if log.skipped_backoff {
    "skipped_backoff"
  } else if log.untracked_closed {
    "untracked_closed"
  } else if log.polled_network && not(log.poll_succeeded) {
    "poll_failed"
  } else {
    "polled"
  }
  let events_summary = poll_events_delivery_summary(log.events)
  let skip_reason = if log.skipped_backoff {
    "backoff_until=" + log.backoff_until.to_string()
  } else {
    ""
  }
  @moontrace.info(
    "poller pr",
    fields=@moontrace.fields([
      ("pr", log.pr_number.to_json()),
      ("agent", log.agent_id.to_json()),
      ("action", action.to_json()),
      ("skip_reason", skip_reason.to_json()),
      ("prior_review", log.prior_review_state.to_string().to_json()),
      ("detected_review", log.detected_review_state.to_string().to_json()),
      ("events", events_summary.to_json()),
      ("failures", log.consecutive_failures.to_json()),
      ("prev_failures", log.previous_consecutive_failures.to_json()),
    ]),
  )
  let line = "pr=" +
    log.pr_number.to_string() +
    " agent=" +
    log.agent_id +
    " action=" +
    action +
    (if skip_reason != "" { " " + skip_reason } else { "" }) +
    " prior=" +
    log.prior_review_state.to_string() +
    " detected=" +
    log.detected_review_state.to_string() +
    " events=" +
    events_summary +
    " failures=" +
    log.consecutive_failures.to_string()
  append_poller_delivery_line(line)
  if log.consecutive_failures > log.previous_consecutive_failures {
    @moontrace.info(
      "poller backoff",
      fields=@moontrace.fields([
        ("pr", log.pr_number.to_json()),
        ("agent", log.agent_id.to_json()),
        ("consecutive_failures", log.consecutive_failures.to_json()),
        ("backoff_until", log.backoff_until.to_json()),
      ]),
    )
    append_poller_delivery_line(
      "backoff pr=" +
      log.pr_number.to_string() +
      " consecutive_failures=" +
      log.consecutive_failures.to_string() +
      " backoff_until=" +
      log.backoff_until.to_string(),
    )
  }
}

///|
pub async fn ServerState::process_poller_tick_with(
  self : ServerState,
  now : Int64,
  timeout : Int64,
  poll : async (Int) -> (Bool, @poller.ReviewState, String, Bool, String, Bool),
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  let pending_events = []
  let pending_agent_ids = []
  self.poller.tick_with(
    now,
    timeout,
    poll,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(_) { () },
  )
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
  let tracked_before = self.poller.tracked.length()
  let pending_events = []
  let pending_agent_ids = []
  let mut tick_event_total = 0
  @moontrace.info(
    "poller tick start",
    fields=@moontrace.fields([("tracked_prs", tracked_before.to_json())]),
  )
  append_poller_delivery_line(
    "tick_start tracked_prs=" + tracked_before.to_string(),
  )
  self.poller.tick_with(
    now,
    timeout,
    @poller.gh_poll_pr,
    fn(event, agent_id) {
      pending_events.push(event)
      pending_agent_ids.push(agent_id)
    },
    fn(log) {
      tick_event_total = tick_event_total + log.events.length()
      log_poller_pr_tick(log)
    },
  )
  let tracked_after = self.poller.tracked.length()
  @moontrace.info(
    "poller tick end",
    fields=@moontrace.fields([
      ("events_generated", tick_event_total.to_json()),
      ("tracked_after", tracked_after.to_json()),
    ]),
  )
  append_poller_delivery_line(
    "tick_end events_generated=" +
    tick_event_total.to_string() +
    " tracked_after=" +
    tracked_after.to_string(),
  )
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
fn child_exists(
  children : Array[@phase.ChildLifecycle],
  child_id : String,
) -> Bool {
  for child in children {
    if child.child_id == child_id {
      return true
    }
  }
  false
}

///|
fn ServerState::current_lifecycle(
  self : ServerState,
  agent_id : String,
) -> @phase.AgentLifecycle {
  match self.registry.get(agent_id) {
    Ok(agent) =>
      @phase.read_or_default_lifecycle(
        self.config.project_dir,
        agent_id,
        agent.role,
      )
    Err(_) =>
      match @phase.read_lifecycle(self.config.project_dir, agent_id) {
        Some(lifecycle) => lifecycle
        None => @phase.lifecycle_for_role(agent_id, @types.Role::Dev)
      }
  }
}

///|
fn ServerState::persist_lifecycle(
  self : ServerState,
  lifecycle : @phase.AgentLifecycle,
) -> Bool {
  let ok = @phase.write_lifecycle(self.config.project_dir, lifecycle)
  match self.registry.get(lifecycle.agent_id) {
    Ok(agent) =>
      ignore(
        self.registry.upsert({ ..agent, state: lifecycle.to_agent_state() }),
      )
    Err(_) => ()
  }
  ok
}

///|
fn ServerState::sync_parent_child_lifecycle(
  self : ServerState,
  agent_id : String,
  lifecycle : @phase.AgentLifecycle,
) -> Unit {
  let agent = match self.registry.get(agent_id) {
    Ok(agent) => agent
    Err(_) => return
  }
  let parent_id = match agent.parent {
    Some(parent_id) => parent_id
    None => return
  }
  let parent = match self.resolve_parent_by_id(parent_id) {
    Ok(parent) => parent
    Err(_) => return
  }
  let child : @phase.ChildLifecycle = {
    child_id: agent_id,
    slug: @phase.extract_slug(agent_id),
    branch: agent.branch,
    agent_type: @config.agent_type_to_string(agent.agent_type),
    summary: @phase.child_summary_from_lifecycle(lifecycle),
  }
  let parent_lifecycle = @phase.read_or_default_lifecycle(
    self.config.project_dir,
    parent_id,
    parent.role,
  )
  let supervisor = match parent_lifecycle.workflow {
    @phase.WorkflowState::Supervisor(supervisor) => supervisor
    _ => @phase.SupervisorLifecycle::Planning
  }
  let (transitioned, supervisor_trigger) = match supervisor {
    @phase.SupervisorLifecycle::Supervising(children~, ..)
    | @phase.SupervisorLifecycle::WaveComplete(children~, ..) =>
      if child_exists(children, agent_id) {
        (
          @phase.supervisor_transition(
            supervisor,
            @phase.SupervisorEvent::ChildUpdated(
              child_id=agent_id,
              summary=child.summary,
            ),
          ),
          "ChildUpdated",
        )
      } else {
        (
          @phase.supervisor_transition(
            supervisor,
            @phase.SupervisorEvent::ChildSpawned(child~),
          ),
          "ChildSpawned",
        )
      }
    _ =>
      (
        @phase.supervisor_transition(
          supervisor,
          @phase.SupervisorEvent::ChildSpawned(child~),
        ),
        "ChildSpawned",
      )
  }
  match transitioned {
    Transitioned(new_supervisor) => {
      let next_parent = {
        ..parent_lifecycle,
        workflow: @phase.WorkflowState::Supervisor(new_supervisor),
      }
      if self.persist_lifecycle(next_parent) {
        ignore(
          append_lifecycle_event(
            self.config.project_dir,
            parent_id,
            @phase.lifecycle_to_json(parent_lifecycle),
            @phase.lifecycle_to_json(next_parent),
            supervisor_trigger,
          ),
        )
      }
    }
    InvalidTransition(_) => ()
  }
}

///|
fn ServerState::remove_parent_child_lifecycle(
  self : ServerState,
  agent_id : String,
) -> Unit {
  let agent = match self.registry.get(agent_id) {
    Ok(agent) => agent
    Err(_) => return
  }
  let parent_id = match agent.parent {
    Some(parent_id) => parent_id
    None => return
  }
  let parent = match self.registry.get(parent_id) {
    Ok(parent) => parent
    Err(_) => return
  }
  let parent_lifecycle = @phase.read_or_default_lifecycle(
    self.config.project_dir,
    parent_id,
    parent.role,
  )
  let supervisor = match parent_lifecycle.workflow {
    @phase.WorkflowState::Supervisor(supervisor) => supervisor
    _ => @phase.SupervisorLifecycle::Planning
  }
  match
    @phase.supervisor_transition(
      supervisor,
      @phase.SupervisorEvent::ChildRemoved(child_id=agent_id),
    ) {
    Transitioned(new_supervisor) => {
      let next_parent = {
        ..parent_lifecycle,
        workflow: @phase.WorkflowState::Supervisor(new_supervisor),
      }
      if self.persist_lifecycle(next_parent) {
        ignore(
          append_lifecycle_event(
            self.config.project_dir,
            parent_id,
            @phase.lifecycle_to_json(parent_lifecycle),
            @phase.lifecycle_to_json(next_parent),
            "ChildRemoved",
          ),
        )
      }
    }
    InvalidTransition(_) => ()
  }
}

///|
pub fn ServerState::transfer_leaf_ownership(
  self : ServerState,
  from_agent_id : String,
  to_agent_id : String,
) -> Result[Int, @types.ExoError] {
  if from_agent_id == to_agent_id {
    return Ok(0)
  }
  let from_agent = match self.registry.get(from_agent_id) {
    Ok(agent) => agent
    Err(e) => return Err(e)
  }
  let to_agent = match self.registry.get(to_agent_id) {
    Ok(agent) => agent
    Err(e) => return Err(e)
  }
  if from_agent.parent != to_agent.parent {
    return Err(
      @types.ExoError::ValidationError(
        "cannot transfer ownership across different parents",
      ),
    )
  }
  if from_agent.role != to_agent.role {
    return Err(
      @types.ExoError::ValidationError(
        "cannot transfer ownership across different roles",
      ),
    )
  }
  match from_agent.role {
    @types.Role::Dev | @types.Role::Worker => ()
    _ =>
      return Err(
        @types.ExoError::ValidationError(
          "ownership transfer only supports leaf roles",
        ),
      )
  }
  let transferred = self.poller.transfer_owner(
    from_agent_id,
    to_agent_id,
    to_agent.branch,
    @workspace.parent_branch(to_agent.branch).unwrap_or(""),
  )
  let from_lifecycle = self.current_lifecycle(from_agent_id)
  let to_lifecycle = self.current_lifecycle(to_agent_id)
  let workflow = match (from_lifecycle.workflow, to_lifecycle.workflow) {
    (@phase.WorkflowState::Dev(from_dev), @phase.WorkflowState::Dev(_)) =>
      @phase.WorkflowState::Dev(from_dev)
    (@phase.WorkflowState::Worker(from_worker), @phase.WorkflowState::Worker(_)) =>
      @phase.WorkflowState::Worker(from_worker)
    _ => to_lifecycle.workflow
  }
  let carried_lifecycle = {
    ..to_lifecycle,
    agent_id: to_agent_id,
    role: to_agent.role,
    workflow,
  }
  ignore(self.persist_lifecycle(carried_lifecycle))
  self.sync_parent_child_lifecycle(to_agent_id, carried_lifecycle)
  self.remove_parent_child_lifecycle(from_agent_id)
  Ok(transferred)
}

///|
fn ServerState::clear_agent_runtime_tracking(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.stop_subscribe(agent_id)
  self.pane_watchers.remove(agent_id)
  self.pane_hashes.remove(agent_id)
  self.pending_disconnects.remove(agent_id)
}

///|
fn finalize_reason_for_exit(exit_reason : String) -> @phase.FinalizeReason {
  match exit_reason {
    "merged" => @phase.FinalizeReason::Merged
    "disconnect" => @phase.FinalizeReason::DisconnectFinalized
    _ => @phase.FinalizeReason::Shutdown
  }
}

///|
async fn ServerState::finalize_agent_with_runner(
  self : ServerState,
  agent_id : String,
  exit_reason : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  notify_parent? : Bool = false,
  close_target? : Bool = true,
  remove_worktree? : Bool = true,
) -> Unit {
  let agent = match self.registry.get(agent_id) {
    Ok(agent) => agent
    Err(_) => {
      self.clear_agent_runtime_tracking(agent_id)
      return
    }
  }
  let finalize_reason = finalize_reason_for_exit(exit_reason)
  let lifecycle = self.current_lifecycle(agent_id)
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => {
      self.clear_agent_runtime_tracking(agent_id)
      return
    }
    _ => {
      let with_finalizing = {
        ..lifecycle,
        process: @phase.ProcessState::Finalizing(reason=finalize_reason),
      }
      if self.persist_lifecycle(with_finalizing) {
        ignore(
          append_lifecycle_event(
            self.config.project_dir,
            agent_id,
            @phase.lifecycle_to_json(lifecycle),
            @phase.lifecycle_to_json(with_finalizing),
            exit_reason,
          ),
        )
      }
    }
  }
  if notify_parent {
    match agent.parent {
      Some(parent_id) => {
        ignore(
          @workspace.remove_team_member_native(
            parent_id,
            @phase.extract_slug(agent_id),
          ),
        )
        match self.resolve_parent_by_id(parent_id) {
          Ok(parent) => {
            let delivery = @message.plan_delivery(
              parent, agent_id, "agent shutdown", "success",
            )
            ignore(
              @tools.execute_delivery(delivery, runner) catch {
                _ => Ok(())
              },
            )
          }
          Err(_) => ()
        }
      }
      None => ()
    }
  }
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
      exit_reason: Some(exit_reason),
    },
    self.config.project_dir,
    runner,
  )
  if remove_worktree && agent.workspace.contains(".choir/worktrees/") {
    ignore(
      runner([@workspace.git_worktree_remove(agent.workspace)]) catch {
        _ => []
      },
    )
  }
  if close_target {
    match agent.terminal_target {
      Some(target) =>
        ignore(
          runner([@workspace.local_close_target(target)]) catch {
            _ => []
          },
        )
      None => ()
    }
  }
  let finalized_workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(_) =>
      @phase.WorkflowState::Dev(
        @phase.DevLifecycle::Done(reason=finalize_reason),
      )
    @phase.WorkflowState::Worker(_) =>
      @phase.WorkflowState::Worker(
        @phase.WorkerLifecycle::Done(reason=finalize_reason),
      )
    @phase.WorkflowState::Supervisor(_) =>
      @phase.WorkflowState::Supervisor(@phase.SupervisorLifecycle::Done)
  }
  let finalized = {
    ..lifecycle,
    process: @phase.ProcessState::Finalized(reason=finalize_reason),
    workflow: finalized_workflow,
  }
  let with_finalizing = {
    ..lifecycle,
    process: @phase.ProcessState::Finalizing(reason=finalize_reason),
  }
  if self.persist_lifecycle(finalized) {
    ignore(
      append_lifecycle_event(
        self.config.project_dir,
        agent_id,
        @phase.lifecycle_to_json(with_finalizing),
        @phase.lifecycle_to_json(finalized),
        "FinalizeComplete",
      ),
    )
  }
  self.sync_parent_child_lifecycle(agent_id, finalized)
  self.clear_agent_runtime_tracking(agent_id)
}

///|
async fn ServerState::fail_agent_with_runner(
  self : ServerState,
  agent_id : String,
  reason : @phase.FailureReason,
  parent_message : String,
  exit_reason : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  close_target? : Bool = false,
) -> Unit {
  let agent = match self.registry.get(agent_id) {
    Ok(agent) => agent
    Err(_) => {
      self.clear_agent_runtime_tracking(agent_id)
      return
    }
  }
  let lifecycle = self.current_lifecycle(agent_id)
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => {
      self.clear_agent_runtime_tracking(agent_id)
      return
    }
    _ => ()
  }
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
      exit_reason: Some(exit_reason),
    },
    self.config.project_dir,
    runner,
  )
  if close_target {
    match agent.terminal_target {
      Some(target) =>
        ignore(
          runner([@workspace.local_close_target(target)]) catch {
            _ => []
          },
        )
      None => ()
    }
  }
  let failed_workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(_) =>
      @phase.WorkflowState::Dev(@phase.DevLifecycle::Failed(reason~))
    @phase.WorkflowState::Worker(_) =>
      @phase.WorkflowState::Worker(@phase.WorkerLifecycle::Failed(reason~))
    @phase.WorkflowState::Supervisor(_) =>
      @phase.WorkflowState::Supervisor(
        @phase.SupervisorLifecycle::Failed(reason~),
      )
  }
  let failed = {
    ..lifecycle,
    process: @phase.ProcessState::Failed(reason~),
    workflow: failed_workflow,
  }
  if self.persist_lifecycle(failed) {
    ignore(
      append_lifecycle_event(
        self.config.project_dir,
        agent_id,
        @phase.lifecycle_to_json(lifecycle),
        @phase.lifecycle_to_json(failed),
        exit_reason,
      ),
    )
  }
  self.sync_parent_child_lifecycle(agent_id, failed)
  match agent.parent {
    Some(parent_id) =>
      match self.resolve_parent_by_id(parent_id) {
        Ok(parent) => {
          let delivery = @message.plan_delivery(
            parent, agent_id, parent_message, "failure",
          )
          ignore(
            @tools.execute_delivery(delivery, runner) catch {
              _ => Ok(())
            },
          )
        }
        Err(_) => ()
      }
    None => ()
  }
  self.clear_agent_runtime_tracking(agent_id)
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
    match @phase.lifecycle_disconnect_policy(self.current_lifecycle(agent_id)) {
      @phase.LifecycleDisconnectPolicy::Preserve
      | @phase.LifecycleDisconnectPolicy::Ignore => continue
      _ => ()
    }
    match agent.terminal_target {
      Some(_) => ()
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
    let message = "[WATCHDOG] agent " +
      agent_id +
      " killed after " +
      elapsed.to_string() +
      "s idle (no pane output change)"
    self.fail_agent_with_runner(
      agent_id,
      @phase.FailureReason::WatchdogTimeout,
      message,
      "watchdog",
      runner,
      close_target=true,
    )
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
/// Review-owned agents are preserved; agent-owned disconnects fail.
pub async fn ServerState::handle_disconnect_with_runner(
  self : ServerState,
  agent_id : String,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  match self.registry.get(agent_id) {
    Err(_) => ()
    Ok(agent) =>
      match agent.state {
        Done | Failed => ()
        Completing => {
          let lifecycle = self.current_lifecycle(agent_id)
          let exit_reason = match lifecycle.process {
            @phase.ProcessState::Finalizing(
              reason=@phase.FinalizeReason::Merged
            ) => "merged"
            @phase.ProcessState::Finalizing(
              reason=@phase.FinalizeReason::DisconnectFinalized
            ) => "disconnect"
            _ => "shutdown"
          }
          self.finalize_agent_with_runner(
            agent_id,
            exit_reason,
            runner,
            notify_parent=false,
            close_target=false,
            remove_worktree=false,
          )
        }
        _ =>
          match
            @phase.lifecycle_disconnect_policy(self.current_lifecycle(agent_id)) {
            @phase.LifecycleDisconnectPolicy::Preserve => ()
            @phase.LifecycleDisconnectPolicy::FinalizeDone(..) =>
              self.finalize_agent_with_runner(
                agent_id,
                "disconnect",
                runner,
                notify_parent=false,
                close_target=false,
                remove_worktree=false,
              )
            @phase.LifecycleDisconnectPolicy::Ignore => ()
            @phase.LifecycleDisconnectPolicy::Fail(reason=default_reason) => {
              let snapshot_path = "/tmp/choir-viewport-" + agent_id + ".json"
              let snapshot = @sys.read_file(snapshot_path)
              let screen = extract_viewport_text(snapshot)
              let (reason, msg) = if screen != "" {
                let classified = @phase.classify_failure(screen)
                match classified {
                  @phase.FailureReason::ChildFailure(_) =>
                    (
                      default_reason,
                      "[FAILED: " +
                      agent_id +
                      "] disconnected unexpectedly - agent may have crashed or run out of context",
                    )
                  _ =>
                    (
                      classified,
                      "[FAILED: " +
                      agent_id +
                      "] " +
                      @phase.failure_reason_message(classified),
                    )
                }
              } else {
                (
                  default_reason,
                  "[FAILED: " +
                  agent_id +
                  "] disconnected unexpectedly - agent may have crashed or run out of context",
                )
              }
              self.fail_agent_with_runner(
                agent_id, reason, msg, "disconnect", runner,
              )
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

///|
test "merged_pr_parent_message is distinct from pre-merge signals" {
  let msg = merged_pr_parent_message(
    42, "main.leaf-z", "feat/z", "main", "https://github.com/o/r/pull/42",
  )
  assert_true(msg.contains("[PR MERGED]"))
  assert_true(msg.contains("merge_pr succeeded"))
  assert_true(msg.contains("PR #42"))
  assert_true(msg.contains("main.leaf-z"))
  assert_true(msg.contains("feat/z"))
  assert_true(msg.contains("parent_branch: main"))
  assert_true(msg.contains("pr_url: https://github.com/o/r/pull/42"))
  assert_true(msg.contains("[PR READY]"))
  assert_true(msg.contains("[FIXES PUSHED]"))
}

///|
test "merged_pr_parent_message uses unknown when branch or parent_branch missing" {
  let msg = merged_pr_parent_message(3, "leaf", "", "", "")
  assert_true(msg.contains("branch: <unknown>"))
  assert_true(msg.contains("parent_branch: <unknown>"))
  assert_false(msg.contains("pr_url:"))
}

///|
test "poll_events_delivery_summary escapes newlines and truncates long events" {
  let tail = "b".repeat(220)
  let ev = @poller.PollEvent::ReviewReceived(3, "alpha\nbeta\n" + tail)
  let s = poll_events_delivery_summary([ev])
  assert_false(s.contains("\n"))
  assert_true(s.contains("\\n"))
  assert_eq(s.length(), 203)
}

///|
test "parent_poll_event_message PR READY stresses not merged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 7,
    agent_id: "main.dev-a",
    branch: "work/a",
    parent_branch: "main",
    pr_url: "https://ex/pr/7",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_failed: false,
    last_timeout_at: 0L,
  }
  match parent_poll_event_message(tracked, @poller.PollEvent::PRReady(7)) {
    Some((message, status)) => {
      assert_eq(status, "success")
      assert_true(message.contains("[PR READY]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("[PR MERGED]"))
    }
    None => fail("expected PRReady message")
  }
}

///|
test "parent_poll_event_message FixesPushed stresses not merged" {
  let tracked : @poller.TrackedPR = {
    pr_number: 8,
    agent_id: "main.dev-b",
    branch: "work/b",
    parent_branch: "main",
    pr_url: "",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_failed: false,
    last_timeout_at: 0L,
  }
  match parent_poll_event_message(tracked, @poller.PollEvent::FixesPushed(8)) {
    Some((message, status)) => {
      assert_eq(status, "info")
      assert_true(message.contains("[FIXES PUSHED]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("Pre-merge:"))
    }
    None => fail("expected FixesPushed message")
  }
}

///|
test "clamp_review_summary_for_pane leaves short text unchanged" {
  let s = "fix the typo in handler"
  assert_eq(clamp_review_summary_for_pane(s), s)
}

///|
test "clamp_review_summary_for_pane truncates long Copilot-style bodies" {
  let long = "x".repeat(review_summary_pane_max_chars + 500)
  let out = clamp_review_summary_for_pane(long)
  assert_true(out.contains("[truncated"))
  assert_true(out.length() < long.length())
}

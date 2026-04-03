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
fn request_int_arg(req : @types.Request, key : String) -> Int? {
  match req.args.get_int(key) {
    Some(value) => Some(value)
    None =>
      match req.args.get(key) {
        Some(value) => {
          let parsed = @json.parse(value) catch { _ => return None }
          match parsed {
            Number(n, ..) => Some(n.to_int())
            _ => None
          }
        }
        None => None
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
  let role_str = req.role.to_wire_string()
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
    let data : Map[String, Json] = {
      "tool": req.name.to_json(),
      "status": resp.status_tag().to_json(),
    }
    ignore(
      append_event(
        state.append_file,
        state.config.project_dir,
        agent_id_str,
        "tools.call",
        data.to_json(),
      ),
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
    match request_int_arg(req, "pr_number") {
      Some(pr_number) =>
        match self.poller.get(pr_number) {
          Some(tracked) => Some(tracked.agent_id)
          None =>
            // Poller doesn't have this PR (server restart, file_pr bypassed).
            // Fall back to scanning the registry for an agent in ReviewOwned
            // for this PR number.
            @runtime.find_agent_for_pr_in_lifecycle(
              self.recovery_provider,
              self.config.project_dir,
              pr_number,
            )
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
      pr_review=self.config.pr_review,
    ) catch {
      e => @tools.tool_response_err_from_caught(e)
    }
  }

  let effects = plan_post_tool_actions(
    req,
    resp,
    merged_agent_id~,
    self.poller,
    self.registry,
    self.config.project_dir,
    self.config.terminal_session,
  )
  // Yield like the legacy `fail_agent_with_runner` path so other fibers can observe registry
  // updates before teardown side effects run (kill_agent is entirely effect-driven now).
  if req.name == "kill_agent" {
    @async.sleep(0)
  }
  self.interpret_teardown_effects(effects, runner)

  let end_ms = @env.now()
  emit_span(self, req, start_ms, end_ms, resp) catch {
    _ => ()
  }
  resp
}

///|
pub fn ServerState::register_agent(
  self : ServerState,
  agent : @types.Agent,
) -> Unit {
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
  ignore(
    @phase.persist_lifecycle(self.config.project_dir, self.registry, lifecycle),
  )
  @phase.sync_parent_child_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    agent_id,
    lifecycle,
  )
}

///|
pub fn ServerState::apply_recovered_agent(
  self : ServerState,
  agent : @types.Agent,
  alive : Bool,
) -> Unit {
  try {
    self.register_agent(agent)
    if !alive {
      ignore(self.registry.set_alive(agent.agent_id.to_string(), false))
    }
  } catch {
    _ => ()
  }
}

///|
pub fn ServerState::restore_recovered_pr_tracking(
  self : ServerState,
  tracked : @poller.TrackedPR,
) -> Unit {
  self.poller.restore(tracked)
}

///|
pub fn ServerState::track_recovered_pr(
  self : ServerState,
  pr_number : Int,
  agent_id : String,
  branch : String,
  parent_branch : String,
  pr_url : String,
  created_at : Int64,
  review : @poller.ReviewState,
  review_bodies : String,
  sha : String,
  ci_rollup : @poller.CiRollupStatus,
  copilot_issue_comment_seen : Bool,
) -> Unit {
  self.poller.track_recovered(
    pr_number, agent_id, branch, parent_branch, pr_url, created_at, review, review_bodies,
    sha, ci_rollup, copilot_issue_comment_seen,
  )
}

///|
pub fn ServerState::sync_recovered_pr_lifecycle(
  self : ServerState,
  agent_id : String,
  pr : @runtime.OpenPR,
  review : @poller.ReviewState,
) -> Unit {
  let agent_opt = try self.registry.get(agent_id) catch {
    _ => None
  } noraise {
    a => Some(a)
  }
  let lifecycle = self.current_lifecycle(agent_id)
  let workflow = match lifecycle.workflow {
    @phase.WorkflowState::Dev(dev) =>
      @phase.WorkflowState::Dev(
        @runtime.recover_dev_lifecycle_for_pr(dev, pr.pr_number, pr.url, review),
      )
    other => other
  }
  let recovered = {
    ..lifecycle,
    workflow,
    process: match agent_opt {
      Some(agent) if agent.terminal_target is Some(_) =>
        @phase.ProcessState::Connected
      _ => lifecycle.process
    },
  }
  @phase.apply_recovered_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    agent_id,
    recovered,
  )
}

///|
pub fn ServerState::finalize_recovered_offline_agent(
  self : ServerState,
  agent_id : String,
) -> Unit {
  let lifecycle = self.current_lifecycle(agent_id)
  match lifecycle.process {
    @phase.ProcessState::Finalized(..) | @phase.ProcessState::Failed(..) => ()
    _ => {
      let finalized = {
        ..lifecycle,
        process: @phase.ProcessState::Finalized(
          reason=@phase.FinalizeReason::RecoveredDone,
        ),
      }
      @phase.apply_recovered_lifecycle(
        self.config.project_dir,
        self.config.terminal_session,
        self.registry,
        agent_id,
        finalized,
      )
    }
  }
}

///|
pub async fn ServerState::persist_recovered_poller_state(
  self : ServerState,
) -> Unit {
  let tracked = []
  self.poller.tracked.each(fn(_k, v) { tracked.push(v) })
  (self.recovery_provider.write_poller_state)(self.config.project_dir, tracked)
}

///|
pub fn ServerState::notify_parent(
  self : ServerState,
  caller_id : String,
  message : String,
  status : String,
) -> @message.DeliveryMethod raise @types.ChoirError {
  let parent = self.resolve_parent_for_delivery(caller_id)
  @message.plan_delivery(parent, caller_id, message, status)
}

///|
fn ServerState::resolve_parent_by_id(
  self : ServerState,
  parent_id : String,
) -> @types.Agent raise @types.ChoirError {
  @phase.resolve_agent_with_fallback(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    parent_id,
  )
}

///|
fn ServerState::resolve_parent_for_delivery(
  self : ServerState,
  caller_id : String,
) -> @types.Agent raise @types.ChoirError {
  @phase.resolve_parent_with_fallback(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    caller_id,
  )
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
/// When review-wait already timed out with no review in snapshot, CI-only parent lines must not read like ordinary progress.
fn parent_poll_ci_escalation_prefix(tracked : @poller.TrackedPR) -> String {
  if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(tracked) {
    "Choir already escalated a review wait timeout for this PR (no review in snapshot; the reviewer request may not have been accepted).\n\n"
  } else {
    ""
  }
}

///|
/// Canonical TL decision line for parent delivery (see `@poller.plan_tl_poll_event_parent`).
fn parent_poll_tl_decision_suffix(
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
) -> String {
  match event {
    PRMerged(_) => ""
    _ =>
      "\nTLDecision: " +
      @poller.tl_tracked_pr_workflow_category_sentence(
        @poller.plan_tl_poll_event_parent(
          event, tracked, unresolved_threads_for_recheck,
        ),
      )
  }
}

///|
fn parent_poll_event_message(
  tracked : @poller.TrackedPR,
  event : @poller.PollEvent,
  unresolved_threads_for_recheck : Int?,
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
        render_parent_next_action(n, parent_branch) +
        parent_poll_tl_decision_suffix(
          tracked, event, unresolved_threads_for_recheck,
        )
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
        "Next action: re-check the PR and merge when ready." +
        parent_poll_tl_decision_suffix(
          tracked, event, unresolved_threads_for_recheck,
        )
      Some((message, "info"))
    }
    ReviewTimeout(n) => {
      let message = "[REVIEW TIMEOUT] " +
        agent_id +
        " PR #" +
        n.to_string() +
        " — review wait window elapsed; Choir snapshot still shows no PR review\n" +
        "branch: " +
        branch +
        "\n" +
        "parent_branch: " +
        parent_branch.unwrap_or("<unknown>") +
        pr_url +
        "\n" +
        "The reviewer request may not have been accepted; inspect the PR on GitHub or add a reviewer manually. Do not infer progress from CI alone while review is missing from snapshot.\n" +
        "Next action: verify the review request on GitHub or add a reviewer manually." +
        parent_poll_tl_decision_suffix(
          tracked, event, unresolved_threads_for_recheck,
        )
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
            pr_url +
            parent_poll_tl_decision_suffix(
              tracked, event, unresolved_threads_for_recheck,
            ),
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
            comments +
            parent_poll_tl_decision_suffix(
              tracked, event, unresolved_threads_for_recheck,
            ),
            "info",
          ),
        )
      }
    ReviewCommented(_, _) => None
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
          pr_url +
          parent_poll_tl_decision_suffix(
            tracked, event, unresolved_threads_for_recheck,
          ),
          "failure",
        ),
      )
    CIFailureCleared(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked, unresolved_threads_for_recheck,
      )
      let prefix = parent_poll_ci_escalation_prefix(tracked)
      Some(
        (
          "[CI FAILURE CLEARED] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " latest head: rollup no longer reports FAILURE/ERROR (may still be pending or incomplete; not a merge/review verdict)\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n" +
          prefix +
          "Next action: re-check the PR thread and full CI status on GitHub before merging or requesting review.\n\n" +
          summary +
          parent_poll_tl_decision_suffix(
            tracked, event, unresolved_threads_for_recheck,
          ),
          "info",
        ),
      )
    }
    CILatestHeadRollupSucceeded(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked, unresolved_threads_for_recheck,
      )
      let prefix = parent_poll_ci_escalation_prefix(tracked)
      Some(
        (
          "[CI LATEST HEAD] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " GitHub Actions rollup reports all checks successful on the current head (not merge approval, mergeability, or review verdict).\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n" +
          prefix +
          "Next action: re-check Copilot/review thread and branch policy, then merge_pr only if appropriate.\n\n" +
          summary +
          parent_poll_tl_decision_suffix(
            tracked, event, unresolved_threads_for_recheck,
          ),
          "info",
        ),
      )
    }
    CopilotIssueCommentSeen(n) => {
      let summary = @tools.format_tl_pr_recheck_summary(
        tracked, unresolved_threads_for_recheck,
      )
      Some(
        (
          "[COPILOT ISSUE COMMENT] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " — GitHub Copilot issue-thread comment observed (REST). Re-check remaining review/CI/thread gates and policy.\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n\n" +
          summary +
          parent_poll_tl_decision_suffix(
            tracked, event, unresolved_threads_for_recheck,
          ),
          "info",
        ),
      )
    }
    PRMerged(n) =>
      Some(
        (
          "[PR MERGED] " +
          agent_id +
          " PR #" +
          n.to_string() +
          " merged externally\n" +
          "branch: " +
          branch +
          "\n" +
          "parent_branch: " +
          parent_branch.unwrap_or("<unknown>") +
          pr_url +
          "\n" +
          "Next action: the leaf will shut down automatically." +
          parent_poll_tl_decision_suffix(
            tracked, event, unresolved_threads_for_recheck,
          ),
          "success",
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
    CIFailureCleared(n) => n
    CILatestHeadRollupSucceeded(n) => n
    CopilotIssueCommentSeen(n) => n
    PRMerged(n) => n
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
/// `tracked` supplies poller snapshot for CI lines when review-wait timeout escalation applies.
fn leaf_poll_review_injection_message(
  event : @poller.PollEvent,
  tracked : @poller.TrackedPR?,
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
    CIFailureCleared(n) => {
      let base = "[REVIEW] PR #" +
        n.to_string() +
        ": CI no longer reports failure on latest head — verify full status on GitHub (not merge or approval)"
      let msg = match tracked {
        Some(pr) =>
          if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(pr) {
            "[REVIEW] PR #" +
            n.to_string() +
            ": CI no longer reports failure on latest head — review wait already timed out with no review in snapshot; the reviewer request may not have been accepted. Verify GitHub and add a reviewer manually if needed (not merge or approval)"
          } else {
            base
          }
        None => base
      }
      Some((msg, "info"))
    }
    CILatestHeadRollupSucceeded(n) => {
      let base = "[REVIEW] PR #" +
        n.to_string() +
        ": Actions rollup: all checks successful on latest head — re-check review thread and policy (not merge or approval by itself)"
      let msg = match tracked {
        Some(pr) =>
          if @poller.tl_tracked_pr_copilot_review_silent_escalation_active(pr) {
            "[REVIEW] PR #" +
            n.to_string() +
            ": Actions rollup all-success on latest head — review wait already timed out with no review in snapshot; the reviewer request may not have been accepted. Inspect the PR on GitHub or add a reviewer manually (not merge or approval by itself)"
          } else {
            base
          }
        None => base
      }
      Some((msg, "info"))
    }
    CopilotIssueCommentSeen(n) =>
      Some(
        (
          "[REVIEW] PR #" +
          n.to_string() +
          ": GitHub Copilot issue-thread comment observed — re-check remaining gates (not merge or approval by itself)",
          "info",
        ),
      )
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
    PRMerged(n) =>
      Some(
        (
          "[PR MERGED] PR #" + n.to_string() + " merged — call shutdown",
          "success",
        ),
      )
  }
}

///|
pub fn ServerState::plan_poll_event_deliveries(
  self : ServerState,
  event : @poller.PollEvent,
  agent_id : String,
  unresolved_threads_for_recheck : Int?,
) -> Array[@message.DeliveryMethod] {
  let deliveries : Array[@message.DeliveryMethod] = []
  let tracked = self.poller.get(poll_event_pr_number(event))
  let leaf_agent_id = match tracked {
    Some(pr) => pr.agent_id
    None => agent_id
  }
  let leaf_owner = try self.registry.get(leaf_agent_id) catch {
    _ => None
  } noraise {
    agent => Some(agent)
  }
  match (tracked, event) {
    (Some(_), ReviewReceived(n, body)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::ReviewReceivedEv(pr_number=n, body~),
        registry=Some(self.registry),
      )
    (Some(_), ReviewCommented(_, _)) => ()
    (Some(_), PRReady(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::ReviewApprovedEv(pr_number=n),
        registry=Some(self.registry),
      )
    (Some(pr), FixesPushed(n)) =>
      @tools.apply_dev_event(
        self.config.project_dir,
        leaf_agent_id,
        @phase.DevEvent::FixesPushedEv(pr_number=n, sha=pr.last_sha),
        registry=Some(self.registry),
      )
    (Some(_), PRMerged(n)) =>
      ignore(
        @tools.apply_dev_event_checked(
          self.config.project_dir,
          leaf_agent_id,
          @phase.DevEvent::MergeObserved(pr_number=n),
          registry=Some(self.registry),
        ),
      )
    _ => ()
  }
  @phase.sync_parent_child_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    leaf_agent_id,
    self.current_lifecycle(leaf_agent_id),
  )
  // Parent notification — TL triage / merge signals (comment-only reviews: leaf only)
  match tracked {
    Some(pr) =>
      match
        parent_poll_event_message(pr, event, unresolved_threads_for_recheck) {
        Some((message, status)) =>
          try {
            let parent = self.resolve_parent_for_delivery(leaf_agent_id)
            ignore(
              (self.append_file)(
                self.config.project_dir + "/.choir/delivery.log",
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
              @message.plan_delivery(parent, leaf_agent_id, message, status),
            )
          } catch {
            _ => ()
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
          match leaf_poll_review_injection_message(event, tracked) {
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
    CIFailureCleared(n) =>
      Some(
        (
          n, "**Choir:** CI rollup no longer shows FAILURE/ERROR on the latest head (may still be pending) — re-check the PR on GitHub (not a merge signal).",
        ),
      )
    CILatestHeadRollupSucceeded(n) =>
      Some(
        (
          n, "**Choir:** GitHub Actions rollup reports all checks successful on the latest head — re-check review/merge policy on GitHub (not an approval or merge signal by itself).",
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
    CopilotIssueCommentSeen(n) =>
      Some(
        (
          n, "**Choir:** GitHub Copilot issue-thread comment observed on PR — parent notified with updated gate snapshot (not merge approval).",
        ),
      )
    PRMerged(_) => None
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
    let unresolved_threads : Int? = match event {
      @poller.PollEvent::CIFailureCleared(_)
      | @poller.PollEvent::CILatestHeadRollupSucceeded(_) => {
        let (count, _) = @tools.fetch_unresolved_review_threads(
          poll_event_pr_number(event),
          state.config.project_dir,
          @exec.capture_command_stdout,
        )
        Some(count)
      }
      _ => None
    }
    for
      delivery in state.plan_poll_event_deliveries(
        event, agent_id, unresolved_threads,
      ) {
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
fn append_poller_delivery_line(
  append_file : (String, String) -> Bool,
  project_dir : String,
  line : String,
) -> Unit {
  ignore(
    append_file(project_dir + "/.choir/delivery.log", "[poller] " + line + "\n"),
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
fn log_poller_pr_tick(
  append_file : (String, String) -> Bool,
  project_dir : String,
  log : @poller.PollerPrTickLog,
) -> Unit {
  let action = if log.skipped_backoff {
    "skipped_backoff"
  } else if log.untracked_closed {
    "untracked_closed"
  } else if log.polled_network && !log.poll_succeeded {
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
  append_poller_delivery_line(append_file, project_dir, line)
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
      append_file,
      project_dir,
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
  poll : async (Int, Bool) -> (
    Bool,
    @poller.ReviewState,
    String,
    @poller.CiRollupStatus,
    String,
    Bool,
    Bool,
  ),
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
  let project_dir = self.config.project_dir
  let append_file = self.append_file
  append_poller_delivery_line(
    append_file,
    project_dir,
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
      log_poller_pr_tick(append_file, project_dir, log)
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
    append_file,
    project_dir,
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
  let agent = self.registry.get(agent_id) catch { _ => return }
  let target = match agent.terminal_target {
    Some(t) => t
    None => return
  }
  self.pane_watcher.watch_pane(agent_id, target, @poller.now_sec())
}

///|
/// Stop the zellij subscribe process for an agent and clean up state.
fn ServerState::stop_subscribe(self : ServerState, agent_id : String) -> Unit {
  self.pane_watcher.stop_subscribe(agent_id)
}

///|
fn ServerState::current_lifecycle(
  self : ServerState,
  agent_id : String,
) -> @phase.AgentLifecycle {
  try self.registry.get(agent_id) catch {
    _ =>
      match @phase.read_lifecycle(self.config.project_dir, agent_id) {
        Some(lifecycle) => lifecycle
        None => @phase.lifecycle_for_role(agent_id, @types.Role::Dev)
      }
  } noraise {
    agent =>
      @phase.read_or_default_lifecycle(
        self.config.project_dir,
        agent_id,
        agent.role,
      )
  }
}

///|
pub fn ServerState::transfer_leaf_ownership(
  self : ServerState,
  from_agent_id : String,
  to_agent_id : String,
) -> Int raise @types.ChoirError {
  if from_agent_id == to_agent_id {
    return 0
  }
  let from_agent = self.registry.get(from_agent_id)
  let to_agent = self.registry.get(to_agent_id)
  if from_agent.parent != to_agent.parent {
    raise @types.ChoirError::validation_error(
      "cannot transfer ownership across different parents",
    )
  }
  if from_agent.role != to_agent.role {
    raise @types.ChoirError::validation_error(
      "cannot transfer ownership across different roles",
    )
  }
  match from_agent.role {
    @types.Role::Dev | @types.Role::Worker => ()
    _ =>
      raise @types.ChoirError::validation_error(
        "ownership transfer only supports leaf roles",
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
  ignore(
    @phase.persist_lifecycle(
      self.config.project_dir,
      self.registry,
      carried_lifecycle,
    ),
  )
  @phase.sync_parent_child_lifecycle(
    self.config.project_dir,
    self.config.terminal_session,
    self.registry,
    to_agent_id,
    carried_lifecycle,
  )
  @phase.remove_parent_child_lifecycle(
    self.config.project_dir,
    self.registry,
    from_agent_id,
  )
  transferred
}

///|
fn ServerState::clear_agent_runtime_tracking(
  self : ServerState,
  agent_id : String,
) -> Unit {
  self.stop_subscribe(agent_id)
  self.pending_disconnects.remove(agent_id)
}

///|
async fn ServerState::finalize_agent_with_runner(
  self : ServerState,
  agent_id : String,
  exit_reason : @types.ExitReason,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  notify_parent? : Bool = false,
  close_target? : Bool = true,
  remove_worktree? : Bool = true,
) -> Unit {
  try self.registry.get(agent_id) catch {
    _ => self.clear_agent_runtime_tracking(agent_id)
  } noraise {
    agent => {
      let lifecycle = self.current_lifecycle(agent_id)
      let effects = plan_finalize(
        agent,
        lifecycle,
        exit_reason,
        notify_parent~,
        close_target~,
        remove_worktree~,
      )
      self.interpret_teardown_effects(effects, runner)
    }
  }
}

///|
async fn ServerState::fail_agent_with_runner(
  self : ServerState,
  agent_id : String,
  reason : @phase.FailureReason,
  parent_message : String,
  exit_reason : @types.ExitReason,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  close_target? : Bool = false,
) -> Unit {
  @async.sleep(0)
  try self.registry.get(agent_id) catch {
    _ => self.clear_agent_runtime_tracking(agent_id)
  } noraise {
    agent => {
      let lifecycle = self.current_lifecycle(agent_id)
      let parent = match agent.parent {
        Some(pid) =>
          try self.resolve_parent_by_id(pid) catch {
            _ => None
          } noraise {
            p => Some(p)
          }
        None => None
      }
      let effects = plan_fail(
        agent,
        lifecycle,
        reason,
        parent_message,
        exit_reason,
        parent,
        close_target~,
      )
      self.interpret_teardown_effects(effects, runner)
    }
  }
}

///|
async fn ServerState::interpret_teardown_effects(
  self : ServerState,
  effects : Array[TeardownEffect],
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> Unit {
  for effect in effects {
    match effect {
      PersistLifecycle(agent_id~, lifecycle~, trigger~) => {
        let prev = self.current_lifecycle(agent_id)
        if @phase.persist_lifecycle(
            self.config.project_dir,
            self.registry,
            lifecycle,
          ) {
          ignore(
            append_lifecycle_event(
              self.config.project_dir,
              agent_id,
              @phase.lifecycle_to_json(prev),
              @phase.lifecycle_to_json(lifecycle),
              trigger,
            ),
          )
        }
      }
      SyncParentLifecycle(agent_id~, lifecycle~) =>
        @phase.sync_parent_child_lifecycle(
          self.config.project_dir,
          self.config.terminal_session,
          self.registry,
          agent_id,
          lifecycle,
        )
      NotifyParent(parent_id~, agent_id~, message~, status~) =>
        try {
          let parent = self.resolve_parent_by_id(parent_id)
          let delivery = @message.plan_delivery(
            parent, agent_id, message, status,
          )
          ignore(
            @tools.execute_delivery(delivery, runner) catch {
              _ => Ok(())
            },
          )
        } catch {
          _ => ()
        }
      RemoveTeamMember(parent_id~, slug~) =>
        ignore(@workspace.remove_team_member(parent_id, slug))
      FireHook(agent_id~, role~, exit_reason~) =>
        @tools.fire_hook_async(
          @hooks.HookEvent::AgentExit,
          {
            event: @hooks.HookEvent::AgentExit,
            session_id: None,
            agent_id: Some(agent_id),
            role: Some(role),
            tool_name: None,
            tool_args: None,
            tool_result_status: None,
            exit_reason: Some(exit_reason),
          },
          self.config.project_dir,
        )
      RemoveWorktree(path) =>
        ignore(runner([@workspace.git_worktree_remove(path)]) catch { _ => [] })
      CloseTerminal(target) =>
        ignore(
          runner([@workspace.local_close_target(target)]) catch {
            _ => []
          },
        )
      InjectTerminalMessage(target, message) =>
        ignore(
          @tools.execute_delivery(
            @message.DeliveryMethod::LocalTerminalInput(target, message),
            runner,
          ) catch {
            _ => Ok(())
          },
        )
      ClearRuntimeTracking(agent_id) =>
        self.clear_agent_runtime_tracking(agent_id)
      WatchPane(agent_id~) =>
        try self.registry.get(agent_id) catch {
          _ => ()
        } noraise {
          agent =>
            match agent.terminal_target {
              Some(_) => self.watch_pane(agent_id)
              None => ()
            }
        }
      UpdateDevLifecycle(agent_id~, event~) =>
        ignore(
          @tools.apply_dev_event_checked(
            self.config.project_dir,
            agent_id,
            event,
            registry=Some(self.registry),
          ),
        )
      DeliverToParentMerged(
        leaf_id~,
        pr_number~,
        branch~,
        parent_branch~,
        url~,
        parent_id~
      ) =>
        match parent_id {
          Some(pid) =>
            try {
              let parent = self.resolve_parent_by_id(pid)
              let body = merged_pr_parent_message(
                pr_number, leaf_id, branch, parent_branch, url,
              )
              let delivery = @message.plan_delivery(
                parent, leaf_id, body, "success",
              )
              ignore(
                @tools.execute_delivery(delivery, runner) catch {
                  _ => Ok(())
                },
              )
            } catch {
              _ => ()
            }
          None => ()
        }
      ParentFailureTerminalEchoIfNeeded(
        parent_id~,
        agent_id~,
        parent_message~,
        reason~
      ) =>
        try {
          let p = self.resolve_parent_by_id(parent_id)
          let delivery = @message.plan_delivery(
            p, agent_id, parent_message, "failure",
          )
          let already_terminal = match delivery {
            @message.DeliveryMethod::LocalTerminalInput(_, _) => true
            _ => false
          }
          let is_self_reported = match reason {
            @phase.FailureReason::ChildFailure(_) => true
            _ => false
          }
          if !is_self_reported && !already_terminal {
            match p.terminal_target {
              Some(target) => {
                let reason_str = reason.to_string()
                let msg = @message.format_failure(agent_id, reason_str)
                ignore(
                  @tools.execute_delivery(
                    @message.DeliveryMethod::LocalTerminalInput(target, msg),
                    runner,
                  ) catch {
                    _ => Ok(())
                  },
                )
              }
              None => ()
            }
          }
        } catch {
          _ => ()
        }
    }
  }
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
  let agent_ids = self.pane_watcher.watched_agents()
  for agent_id in agent_ids {
    let agent = try self.registry.get(agent_id) catch {
      _ => {
        self.stop_subscribe(agent_id)
        continue
      }
    } noraise {
      a => a
    }
    if agent.state != @types.AgentState::Active {
      self.stop_subscribe(agent_id)
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

    // Check if idle too long
    match self.pane_watcher.check_idle(agent_id, now, timeout) {
      Some(screen) => {
        ignore(screen) // We could extract failure reason from screen if desired, but watchdog just kills it
        // Kill the agent
        @moontrace.warn(
          "watchdog killing idle agent",
          fields=@moontrace.fields([
            ("agent", agent_id.to_json()),
            ("idle_sec", timeout.to_json()),
          ]),
        )
        let message = "[WATCHDOG] agent " +
          agent_id +
          " killed after " +
          timeout.to_string() +
          "s idle (no pane output change)"
        self.fail_agent_with_runner(
          agent_id,
          @phase.FailureReason::WatchdogTimeout,
          message,
          @types.ExitReason::Shutdown,
          runner,
          close_target=true,
        )
      }
      None => continue
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
) -> @types.Agent raise @types.ChoirError {
  self.registry.get(agent_id)
}

///|
/// Called when a connection closes. Detects unexpected agent death and notifies parent.
/// Review-owned agents are preserved; agent-owned disconnects fail.
fn disconnect_pr_recovery_candidate(agent : @types.Agent) -> Bool {
  agent.role == @types.Role::Dev && agent.branch.trim() != ""
}

///|
pub async fn ServerState::handle_disconnect_with_runner(
  self : ServerState,
  agent_id : String,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> Unit {
  let agent = self.registry.get(agent_id) catch { _ => return }
  match agent.state {
    Done | Failed => ()
    Completing => {
      let lifecycle = self.current_lifecycle(agent_id)
      let exit_reason = match lifecycle.process {
        @phase.ProcessState::Finalizing(reason=@phase.FinalizeReason::Merged) =>
          @types.ExitReason::Merged
        @phase.ProcessState::Finalizing(
          reason=@phase.FinalizeReason::DisconnectFinalized
        ) => @types.ExitReason::Disconnected
        _ => @types.ExitReason::Shutdown
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
            @types.ExitReason::Disconnected,
            runner,
            notify_parent=false,
            close_target=false,
            remove_worktree=false,
          )
        @phase.LifecycleDisconnectPolicy::Ignore => ()
        @phase.LifecycleDisconnectPolicy::Fail(reason=default_reason) => {
          // Before failing: check if a dev leaf filed a PR via raw `gh pr create`
          // (bypassing file_pr). Restrict this to branch-owning dev agents so
          // top-level TLs/workers with empty branches cannot steal tracked PR ownership.
          let recovered_pr = if disconnect_pr_recovery_candidate(agent) {
            @runtime.find_pr_for_branch_in_provider(
              self.recovery_provider,
              self.config.project_dir,
              agent.branch,
            )
          } else {
            None
          }
          match recovered_pr {
            Some((pr_number, pr_url)) => {
              let parent_branch = match @workspace.parent_branch(agent.branch) {
                Some(pb) => pb
                None => "main"
              }
              @tools.apply_dev_event(
                self.config.project_dir,
                agent.branch,
                @phase.DevEvent::PRCreated(
                  pr_number~,
                  url=pr_url,
                  branch=agent.branch,
                ),
                registry=Some(self.registry),
              )
              self.poller.ensure_tracked(
                pr_number,
                agent_id,
                agent.branch,
                parent_branch,
                pr_url,
                @poller.now_sec(),
              )
              ignore(self.poller.write_state_file(self.config.project_dir))
            }
            None => {
              let snapshot = self.pane_watcher.read_viewport(agent_id)
              let screen = @runtime.extract_viewport_text(snapshot)
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
                agent_id,
                reason,
                msg,
                @types.ExitReason::Disconnected,
                runner,
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
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
  }
  match
    parent_poll_event_message(tracked, @poller.PollEvent::PRReady(7), None) {
    Some((message, status)) => {
      assert_eq(status, "success")
      assert_true(message.contains("[PR READY]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("[PR MERGED]"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Waiting on a GitHub Copilot issue comment"))
    }
    None => fail("expected PRReady message")
  }
}

///|
test "parent_poll_event_message PR READY shows merge gate when snapshot allows" {
  let tracked : @poller.TrackedPR = {
    pr_number: 70,
    agent_id: "main.dev-a",
    branch: "work/a",
    parent_branch: "main",
    pr_url: "https://ex/pr/70",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
  }
  match
    parent_poll_event_message(tracked, @poller.PollEvent::PRReady(70), Some(0)) {
    Some((message, status)) => {
      assert_eq(status, "success")
      assert_true(message.contains("TLDecision:"))
      assert_true(
        message.contains("no Copilot issue comment has been observed"),
      )
    }
    None => fail("expected merge-gate-open PRReady message")
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
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
  }
  match
    parent_poll_event_message(tracked, @poller.PollEvent::FixesPushed(8), None) {
    Some((message, status)) => {
      assert_eq(status, "info")
      assert_true(message.contains("[FIXES PUSHED]"))
      assert_true(message.contains("(not merged yet)"))
      assert_true(message.contains("Pre-merge:"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Waiting on a GitHub Copilot issue comment"))
    }
    None => fail("expected FixesPushed message")
  }
}

///|
test "parent_poll_event_message CIFailureCleared stresses re-check not merge" {
  let tracked : @poller.TrackedPR = {
    pr_number: 10,
    agent_id: "main.dev-x",
    branch: "work/x",
    parent_branch: "main",
    pr_url: "https://ex/pr/10",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::ChangesRequested,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
  }
  match
    parent_poll_event_message(
      tracked,
      @poller.PollEvent::CIFailureCleared(10),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, "info")
      assert_true(message.contains("[CI FAILURE CLEARED]"))
      assert_true(message.contains("not a merge/review verdict"))
      assert_true(message.contains("pending"))
      assert_true(message.contains("re-check"))
      assert_false(message.contains("CI PASSED"))
      assert_false(message.to_lower().contains("green"))
      assert_true(message.contains("PR re-check summary"))
      assert_true(message.contains("changes_requested"))
      assert_true(message.contains("GitHub review requests changes"))
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Blocked on review changes"))
    }
    None => fail("expected CIFailureCleared message")
  }
}

///|
test "leaf_poll_review_injection_message CIFailureCleared is honest about scope" {
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CIFailureCleared(44),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, "info")
      assert_true(message.contains("no longer reports failure"))
      assert_true(message.contains("GitHub"))
      assert_true(message.contains("not merge"))
      assert_false(message.to_lower().contains("green"))
    }
    None => fail("expected leaf CIFailureCleared injection")
  }
}

///|
test "pr_comment_body CIFailureCleared contains pending caveat and no merge signal" {
  match pr_comment_body(@poller.PollEvent::CIFailureCleared(55), "main.dev-x") {
    Some((pr_number, body)) => {
      assert_eq(pr_number, 55)
      assert_true(body.contains("pending"))
      assert_true(body.contains("not a merge signal"))
      assert_false(body.to_lower().contains("passed"))
      assert_false(body.to_lower().contains("green"))
    }
    None => fail("expected pr_comment_body for CIFailureCleared")
  }
}

///|
test "parent_poll_event_message CILatestHeadRollupSucceeded stresses not merge or approval" {
  let tracked : @poller.TrackedPR = {
    pr_number: 171,
    agent_id: "main.dev-z",
    branch: "work/z",
    parent_branch: "main",
    pr_url: "https://ex/pr/171",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
  }
  match
    parent_poll_event_message(
      tracked,
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, "info")
      assert_true(message.contains("[CI LATEST HEAD]"))
      assert_true(message.contains("not merge approval"))
      assert_true(message.contains("re-check"))
      assert_false(message.to_lower().contains("mergeable"))
      assert_true(message.contains("PR re-check summary"))
      assert_true(message.contains("approved"))
      assert_true(message.contains("success"))
      assert_true(message.contains("no tracked blockers"))
      assert_true(message.contains("Does not merge"))
      assert_true(message.contains("TLDecision:"))
      assert_true(
        message.contains("no Copilot issue comment has been observed"),
      )
    }
    None => fail("expected CILatestHeadRollupSucceeded message")
  }
}

///|
test "leaf_poll_review_injection_message CILatestHeadRollupSucceeded is scoped" {
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, "info")
      assert_true(message.contains("all checks successful"))
      assert_true(message.contains("not merge"))
    }
    None => fail("expected leaf CILatestHeadRollupSucceeded injection")
  }
}

///|
test "leaf_poll_review_injection_message CILatestHeadRollupSucceeded escalates when review timed out with no snapshot review" {
  let tracked : @poller.TrackedPR = {
    pr_number: 178,
    agent_id: "main.dev-leaf",
    branch: "work/leaf",
    parent_branch: "main",
    pr_url: "https://ex/pr/178",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::None_,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 100L,
    copilot_issue_comment_seen: false,
  }
  match
    leaf_poll_review_injection_message(
      @poller.PollEvent::CILatestHeadRollupSucceeded(178),
      Some(tracked),
    ) {
    Some((message, status)) => {
      assert_eq(status, "info")
      assert_true(message.contains("timed out"))
      assert_true(message.contains("reviewer request"))
      assert_true(message.contains("reviewer manually"))
      assert_false(message.contains("re-check review thread and policy"))
    }
    None => fail("expected leaf CI escalation injection")
  }
}

///|
test "pr_comment_body CILatestHeadRollupSucceeded avoids approval language" {
  match
    pr_comment_body(
      @poller.PollEvent::CILatestHeadRollupSucceeded(60),
      "main.dev-z",
    ) {
    Some((pr_number, body)) => {
      assert_eq(pr_number, 60)
      assert_true(body.contains("successful"))
      assert_true(body.contains("not an approval"))
      assert_false(body.to_lower().contains("approved"))
    }
    None => fail("expected pr_comment_body for CILatestHeadRollupSucceeded")
  }
}

///|
test "parent_poll_event_message suppresses non-blocking review comments" {
  let tracked : @poller.TrackedPR = {
    pr_number: 9,
    agent_id: "main.dev-c",
    branch: "work/c",
    parent_branch: "main",
    pr_url: "https://ex/pr/9",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Commented,
    last_review_bodies: "note",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Unknown,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
  }
  assert_eq(
    parent_poll_event_message(
      tracked,
      @poller.PollEvent::ReviewCommented(9, "minor suggestion"),
      None,
    ),
    None,
  )
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

///|
test "disconnect PR recovery only applies to branch-owning dev agents" {
  let mk = fn(role : @types.Role, branch : String) {
    @types.Agent::{
      agent_id: "agent",
      role,
      agent_type: @types.AgentType::Claude,
      parent: Some("root"),
      workspace: "/proj",
      branch,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }
  }
  assert_true(
    disconnect_pr_recovery_candidate(mk(@types.Role::Dev, "main.leaf")),
  )
  assert_false(disconnect_pr_recovery_candidate(mk(@types.Role::Dev, "")))
  assert_false(
    disconnect_pr_recovery_candidate(mk(@types.Role::Worker, "main.worker")),
  )
  assert_false(disconnect_pr_recovery_candidate(mk(@types.Role::TL, "main")))
}

///|
async test "fail_agent_with_runner injects failure to parent terminal" {
  let project_dir = "/tmp/choir-watchdog-test-" +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  ignore(@sys.system("mkdir -p " + project_dir + "/.choir/kv"))

  let terminal_session = "test-session"
  let config = { ..@types.Config::default(), project_dir, terminal_session }
  let state = ServerState::new(config, make_recovery_provider())

  let parent_id = "main.parent"
  let live_target = match
    @types.LocalTarget::parse("zellij-tab:" + terminal_session + ":live-parent") {
    Some(t) => t
    None => fail("expected parseable local target")
  }

  ignore(
    state.register_agent({
      agent_id: parent_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: None,
      workspace: project_dir,
      branch: parent_id,
      terminal_target: Some(live_target),
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  let caller_id = "main.child"
  ignore(
    state.register_agent({
      agent_id: caller_id,
      role: @types.Role::Dev,
      agent_type: @types.AgentType::Claude,
      parent: Some(parent_id),
      workspace: project_dir,
      branch: caller_id,
      terminal_target: None,
      host: @types.Host::Local,
      spawn_depth: 0,
      state: @types.AgentState::Active,
    }),
  )

  ignore(
    @phase.write_lifecycle(
      project_dir,
      @phase.lifecycle_for_role(caller_id, @types.Role::Dev),
    ),
  )

  @async.sleep(0)

  let mut injected_failure_msg = false
  let runner = async fn(cmds : Array[@workspace.Command]) {
    @async.sleep(0)
    for cmd in cmds {
      if cmd.program == "choir" &&
        cmd.args.contains("zellij-action") &&
        cmd.args.contains("send") {
        let text = cmd.args[cmd.args.length() - 1]
        if text.contains("[from: " + caller_id + "]") &&
          text.contains("watchdog timeout") {
          injected_failure_msg = true
        }
      }
    }
    [0]
  }

  state.fail_agent_with_runner(
    caller_id,
    @phase.FailureReason::WatchdogTimeout,
    "watchdog timeout",
    @types.ExitReason::Shutdown,
    runner,
  )

  assert_true(injected_failure_msg)
}

///|
test "parent_poll_event_message REVIEW TIMEOUT uses attention-required decision" {
  let tracked : @poller.TrackedPR = {
    pr_number: 61,
    agent_id: "main.dev-timeout",
    branch: "work/timeout",
    parent_branch: "main",
    pr_url: "https://ex/pr/61",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
  }
  match
    parent_poll_event_message(
      tracked,
      @poller.PollEvent::ReviewTimeout(61),
      None,
    ) {
    Some((message, status)) => {
      assert_eq(status, "failure")
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Attention required: review wait timed out"))
      assert_true(message.contains("reviewer request"))
      assert_true(message.contains("inspect the PR on GitHub"))
      assert_false(message.contains("15min"))
    }
    None => fail("expected ReviewTimeout message")
  }
}

///|
test "parent_poll_event_message CI LATEST HEAD adds escalation when review timeout already fired" {
  let tracked : @poller.TrackedPR = {
    pr_number: 171,
    agent_id: "main.dev-z",
    branch: "work/z",
    parent_branch: "main",
    pr_url: "https://ex/pr/171",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::None_,
    last_review_bodies: "",
    last_sha: "abc",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 999L,
    copilot_issue_comment_seen: false,
  }
  match
    parent_poll_event_message(
      tracked,
      @poller.PollEvent::CILatestHeadRollupSucceeded(171),
      Some(0),
    ) {
    Some((message, status)) => {
      assert_eq(status, "info")
      assert_true(
        message.contains("Choir already escalated a review wait timeout"),
      )
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Attention required: review wait timed out"))
    }
    None => fail("expected CILatestHeadRollupSucceeded escalation message")
  }
}

///|
test "parent_poll_event_message CI FAILED uses attention-required decision" {
  let tracked : @poller.TrackedPR = {
    pr_number: 62,
    agent_id: "main.dev-ci",
    branch: "work/ci",
    parent_branch: "main",
    pr_url: "https://ex/pr/62",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Failure,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
  }
  match
    parent_poll_event_message(tracked, @poller.PollEvent::CIFailed(62), None) {
    Some((message, status)) => {
      assert_eq(status, "failure")
      assert_true(message.contains("TLDecision:"))
      assert_true(message.contains("Attention required: CI is failing"))
    }
    None => fail("expected CIFailed message")
  }
}

///|
test "parent_poll_event_message PRMerged does not append TLDecision suffix" {
  let tracked : @poller.TrackedPR = {
    pr_number: 63,
    agent_id: "main.dev-merged",
    branch: "work/merged",
    parent_branch: "main",
    pr_url: "https://ex/pr/63",
    first_seen: 0,
    consecutive_failures: 0,
    backoff_until: 0L,
    last_review_state: @poller.ReviewState::Approved,
    last_review_bodies: "",
    last_sha: "sha",
    notified_parent: false,
    last_ci_rollup: @poller.CiRollupStatus::Success,
    last_timeout_at: 0L,
    copilot_issue_comment_seen: false,
  }
  match
    parent_poll_event_message(tracked, @poller.PollEvent::PRMerged(63), Some(0)) {
    Some((message, status)) => {
      assert_eq(status, "success")
      assert_false(message.contains("TLDecision:"))
      assert_true(message.contains("leaf will shut down automatically"))
    }
    None => fail("expected PRMerged message")
  }
}

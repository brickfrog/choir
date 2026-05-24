///|
fn request_span_name(req : @types.Request) -> String {
  "tools/call " + req.name
}

///|
pub(all) enum RequestLogLevel {
  Trace
  Info
} derive(Debug, Eq)

///|
pub fn request_log_level(tool_def : @types.ToolDef) -> RequestLogLevel {
  if tool_def.read_only {
    Trace
  } else {
    Info
  }
}

///|
pub fn request_log_level_for_request(
  state : ServerState,
  req : @types.Request,
) -> RequestLogLevel {
  if req.req_method != "tools/call" {
    return Info
  }
  try state.tool_registry.lookup(req.role, req.name) catch {
    _ => Info
  } noraise {
    def => request_log_level(def)
  }
}

///|
fn emit_request_log(
  level : RequestLogLevel,
  name : String,
  fields : Array[@moontrace.Field],
) -> Unit {
  match level {
    Trace => @moontrace.trace(name, fields~)
    Info => @moontrace.info(name, fields~)
  }
}

///|
fn emit_span(
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
  let fields = [
    @moontrace.field("agent_id", agent_id_str),
    @moontrace.field("role", role_str),
    @moontrace.field("status", status),
    @moontrace.field("duration_ms", duration_ms),
  ]
  match resp.error_message() {
    Some(msg) => fields.push(@moontrace.field("error", msg))
    None => ()
  }
  emit_request_log(request_log_level_for_request(state, req), name, fields)
  match state.config.otlp_endpoint {
    Some(ep) => {
      let mt_span = @moontrace.span_with_trace(
        name,
        normalize_trace_id(state.run_id),
        fields~,
      )
      mt_span.start_time = start_ms
      mt_span.end_time = end_ms
      mt_span.status = if resp.is_ok() {
        @moontrace.Ok
      } else {
        @moontrace.SpanError
      }
      mt_span.status_message = resp.error_message().unwrap_or("")
      let otlp_span = @otlp.span_to_otlp(mt_span)
      export_otlp_span(otlp_span, ep)
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
  self.handle_with_runner_and_capture(
    req,
    runner=@exec.run_sequence,
    capture=@exec.capture_command_merged,
  )
}

///|
pub async fn ServerState::handle_with_runner(
  self : ServerState,
  req : @types.Request,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
) -> @types.Response {
  self.handle_with_runner_and_capture(
    req,
    runner~,
    capture=@exec.capture_command_merged,
  )
}

///|
pub async fn ServerState::handle_with_runner_and_capture(
  self : ServerState,
  req : @types.Request,
  runner? : async (Array[@workspace.Command]) -> Array[Int] = @exec.run_sequence,
  capture? : async (@workspace.Command) -> (Int, String) = @exec.capture_command_merged,
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> @types.Response {
  let start_ms = @env.now()
  let effective_req = self.request_with_review_mode_default(req)
  let merged_pr_context : MergedPrContext? = if effective_req.name == "merge_pr" {
    match request_int_arg(effective_req, "pr_number") {
      Some(pr_number) =>
        match self.poller.get(pr_number) {
          Some(tracked) =>
            Some({
              agent_id: tracked.agent_id,
              branch: tracked.branch,
              parent_branch: tracked.parent_branch,
              url: tracked.pr_url,
            })
          None =>
            // Poller doesn't have this PR (server restart, file_pr bypassed).
            // Fall back to scanning the registry for an agent in ReviewOwned
            // for this PR number.
            match
              @runtime.find_agent_for_pr_in_lifecycle(
                self.recovery_provider,
                self.config.project_dir,
                pr_number,
              ) {
              Some(agent_id) =>
                Some({ agent_id, branch: "", parent_branch: "", url: "" })
              None => None
            }
        }
      None => None
    }
  } else {
    None
  }
  let resp = if effective_req.req_method == "tools/call" &&
    effective_req.name == "server_reload" {
    self.handle_server_reload_request(effective_req)
  } else {
    @tools.handle_request(
      self.tool_registry,
      effective_req,
      project_dir=self.config.project_dir,
      session=self.config.terminal_session,
      runner~,
      sleep_fn~,
      capture~,
      extra_mcp_servers_json=self.config.extra_mcp_servers_json,
      shell_command=self.config.shell_command,
      listen_uds=self.config.listen_uds,
      listen_tcp=self.config.listen_tcp,
      tcp_auth_token=self.config.tcp_auth_token,
      agent_registry=Some(self.registry),
      mutex_registry=Some(self.mutex_registry),
      poller_state=Some(self.poller),
      task_contract_reader=fn(agent_id) {
        self.task_contract_for_agent(agent_id)
      },
      record_task_contract=fn(agent_id, contract) {
        self.record_agent_task_contract(agent_id, contract)
      },
      tdd_phase_reader=fn(agent_id) { self.leaf_tdd_phase_for_agent(agent_id) },
      tdd_state_reader=fn(agent_id) { self.leaf_tdd_state_for_agent(agent_id) },
      tdd_state_writer=fn(agent_id, state) {
        self.record_leaf_tdd_state(agent_id, state)
      },
      list_panes_cache=Some(self.list_panes_cache),
      plugins_json=self.config.plugins_json,
      pr_review=self.config.pr_review,
      global_review_mode=self.config.review_mode,
      moon_verify_target=self.config.moon_verify_target,
      audit_heartbeat_sec=self.config.audit_heartbeat_sec,
      audit_max_rounds=self.config.audit_max_rounds,
      prenotify_checks=self.config.prenotify_checks,
      mutation_kill_rate_min=self.config.mutation_kill_rate_min,
      agy_migration_incomplete=self.config.agy_migration_incomplete,
      goal_deliver=async fn(message, status) {
        self.deliver_goal_judge_message(message, status, runner)
      },
      goal_request_tick=fn() { self.request_goal_judge_tick() },
      record_handoff_delivered=fn(agent_id) {
        self.mark_handoff_delivered(agent_id)
      },
      on_resolve_review_thread=async fn(pr_numbers : Array[Int]) {
        if pr_numbers.length() > 0 {
          self.sweep_tracked_prs_for_automerge(runner, sleep_fn~) catch {
            e =>
              @moontrace.warn(
                "failed to sweep PRs after resolve_review_thread",
                fields=[
                  @moontrace.field("pr_count", pr_numbers.length()),
                  @moontrace.field("error", e.to_string()),
                ],
              )
          }
        }
      },
      prepare_audit_report=fn(agent_id) {
        self.prepare_audit_on_file_pr_report(agent_id)
      },
      record_audit_cycle_for_agent=fn(agent_id) {
        self.record_audit_cycle_for_agent(agent_id)
      },
      audit_cycle_count_for_agent=fn(agent_id) {
        self.audit_cycle_count_for_agent(agent_id)
      },
      clear_audit_cycle_for_agent=fn(agent_id) {
        self.clear_audit_cycle_count_for_agent(agent_id)
      },
      notify_audit_started=async fn(agent_id, pr_number, cycle_number) {
        self.notify_parent_audit_started(
          agent_id,
          cycle_number,
          pr_number~,
          runner~,
        )
      },
      audit_progress_reader=fn(agent_id) {
        match self.audit_progress_for_agent(agent_id) {
          Some(progress) =>
            Some(@tools.WaveStateAuditProgress::{
              cycles_so_far: progress.cycles_so_far,
              last_findings_count: progress.last_findings_count,
              last_receipt_path: progress.last_receipt_path,
              last_cycle_at_ms: progress.last_cycle_at_ms,
              exhausted: progress.exhausted,
            })
          None => None
        }
      },
      audit_worker_alive=fn(agent_id) {
        self.registry.is_alive(agent_id).unwrap_or(false)
      },
      wait_for_audit_report=async fn(agent_id) {
        self.wait_for_audit_on_file_pr_report(agent_id)
      },
      capture_audit_on_file_pr_report=async fn(agent_id, report) {
        self.capture_audit_on_file_pr_report(
          agent_id,
          report,
          runner~,
          capture~,
        )
      },
      cleanup_audit_report=async fn(agent_id) {
        self.cleanup_audit_on_file_pr_report(agent_id)
        let kill_resp = @tools.interpret_kill_agent(
          { agent_id, reason: "audit-on-file-pr timed out" },
          Some(self.registry),
          runner,
          project_dir=self.config.project_dir,
          capture~,
        )
        if kill_resp.is_ok() {
          self.fail_agent_with_runner(
            agent_id,
            @phase.FailureReason::WatchdogTimeout,
            "[FAILED: " +
            agent_id +
            "] audit-on-file-pr timed out; cleanup attempted",
            @types.ExitReason::Shutdown,
            runner,
            close_target=false,
          )
        } else {
          @moontrace.warn("audit-on-file-pr reap failed", fields=[
            @moontrace.field("agent_id", agent_id),
            @moontrace.field(
              "error",
              kill_resp.error_message().unwrap_or("unknown error"),
            ),
          ])
        }
      },
      prepare_mutation_gate_report=fn(agent_id) {
        self.prepare_mutation_gate_report(agent_id)
      },
      wait_for_mutation_gate_report=async fn(agent_id) {
        self.wait_for_mutation_gate_report(agent_id)
      },
      capture_mutation_gate_report=async fn(agent_id, report) {
        self.capture_mutation_gate_report(agent_id, report)
        @async.sleep(0)
      },
      cleanup_mutation_gate_report=fn(agent_id) {
        self.cleanup_mutation_gate_report(agent_id)
      },
    ) catch {
      e => @tools.tool_response_err_from_caught(e)
    }
  }
  if effective_req.req_method == "register" &&
    effective_req.name == "register" &&
    resp.is_ok() {
    match request_agent_id(effective_req) {
      Some(agent_id) =>
        try self.registry.get(agent_id) catch {
          _ => ()
        } noraise {
          agent => self.register_agent(agent)
        }
      None => ()
    }
  }

  let effects = plan_post_tool_actions(
    effective_req,
    resp,
    merged_agent_id=match merged_pr_context {
      Some(ctx) => Some(ctx.agent_id)
      None => None
    },
    self.poller,
    self.registry,
    self.config.project_dir,
    self.config.terminal_session,
    merged_pr_context~,
  )
  // Yield like the legacy `fail_agent_with_runner` path so other fibers can observe registry
  // updates before teardown side effects run (kill_agent is entirely effect-driven now).
  if req.name == "kill_agent" {
    @async.sleep(0)
  }
  // Reap pgroup BEFORE teardown_effects runs ClearRuntimeTracking (which removes agent_pids).
  if req.name == "kill_agent" && resp.is_ok() {
    match req.args.get("agent_id") {
      Some(agent_id) =>
        self.kill_tracked_agent_pgroup(agent_id, default_kill_pgid_best_effort)
      None => ()
    }
  }
  self.interpret_teardown_effects(effects, runner, sleep_fn~)
  if req.name == "kill_agent" && resp.is_ok() {
    let caller_id = req.args
      .get("caller_id")
      .unwrap_or(request_agent_id(req).unwrap_or(""))
    // Empty caller_id → cannot resolve a caller branch; the downstream
    // guard in `reconcile_killed_agent_tracked_prs` short-circuits when
    // caller_branch is empty and would then match every tracked PR.
    // Enforce the precondition at the boundary.
    if caller_id != "" {
      match req.args.get("agent_id") {
        Some(agent_id) =>
          reconcile_killed_agent_tracked_prs(
            self, agent_id, caller_id, runner, capture,
          )
        None => ()
      }
    }
  }
  ignore(
    self.maybe_trigger_automerge_for_blocked_gh_notify(
      effective_req, runner, capture,
    ),
  )
  if goal_judge_post_tool_trigger(effective_req, resp) {
    self.request_goal_judge_tick()
  }

  let end_ms = @env.now()
  emit_span(self, req, start_ms, end_ms, resp)
  match merged_pr_context {
    Some(ctx) =>
      append_merge_pr_evidence_if_needed(
        self,
        req,
        resp,
        Some(ctx.agent_id),
        evidence_optional_string(ctx.url),
      )
    None => append_merge_pr_evidence_if_needed(self, req, resp, None, None)
  }
  resp
}

///|

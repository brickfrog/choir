///|
fn request_span_name(req : @types.Request) -> String {
  "tools/call " + req.name
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
) -> @types.Response {
  let start_ms = @env.now()
  let effective_req = self.request_with_review_mode_default(req)
  let merged_pr_context : (String, String?)? = if effective_req.name ==
    "merge_pr" {
    match request_int_arg(effective_req, "pr_number") {
      Some(pr_number) =>
        match self.poller.get(pr_number) {
          Some(tracked) =>
            Some((tracked.agent_id, evidence_optional_string(tracked.pr_url)))
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
              Some(agent_id) => Some((agent_id, None))
              None => None
            }
        }
      None => None
    }
  } else {
    None
  }
  let resp = @tools.handle_request(
    self.tool_registry,
    effective_req,
    project_dir=self.config.project_dir,
    session=self.config.terminal_session,
    runner~,
    capture~,
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

  let effects = plan_post_tool_actions(
    effective_req,
    resp,
    merged_agent_id=match merged_pr_context {
      Some((agent_id, _)) => Some(agent_id)
      None => None
    },
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
  if req.name == "kill_agent" && resp.is_ok() {
    let caller_id = req.args
      .get("caller_id")
      .unwrap_or(request_agent_id(req).unwrap_or(""))
    match req.args.get("agent_id") {
      Some(agent_id) =>
        reconcile_killed_agent_tracked_prs(
          self, agent_id, caller_id, runner, capture,
        )
      None => ()
    }
  }

  let end_ms = @env.now()
  emit_span(self, req, start_ms, end_ms, resp)
  match merged_pr_context {
    Some((agent_id, pr_url)) =>
      append_merge_pr_evidence_if_needed(
        self,
        req,
        resp,
        Some(agent_id),
        pr_url,
      )
    None => append_merge_pr_evidence_if_needed(self, req, resp, None, None)
  }
  resp
}

///|

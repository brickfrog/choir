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
  let start_sec = @poller.now_sec()
  let resp = if req.req_method == "tools/list" {
    @types.Response::Ok({ "tools_list": "true" })
  } else {
    @tools.handle_request(
      self.tool_registry,
      req,
      project_dir=self.config.project_dir,
      extra_mcp_servers_json=self.config.extra_mcp_servers_json,
      shell_command=self.config.shell_command,
      agent_registry=Some(self.registry),
      mutex_registry=Some(self.mutex_registry),
      poller_state=Some(self.poller),
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

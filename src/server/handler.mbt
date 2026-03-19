///|
pub async fn ServerState::handle(
  self : ServerState,
  req : @types.Request,
) -> @types.Response {
  if req.req_method == "tools/list" {
    return @types.Response::Ok({ "tools_list": "true" }) // sentinel for mcp-stdio
  }
  @tools.handle_request(
    self.tool_registry,
    req,
    project_dir=self.config.project_dir,
    extra_mcp_servers_json=self.config.extra_mcp_servers_json,
    agent_registry=Some(self.registry),
    poller_state=Some(self.poller),
  )
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

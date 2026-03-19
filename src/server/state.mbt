///|
/// Shared server state, passed to all tool handlers.
pub struct ServerState {
  config : @types.Config
  registry : @registry.AgentRegistry
  tool_registry : @tools.ToolRegistry
  poller : @poller.PollerState
}

///|
/// Create initial server state from config.
pub fn ServerState::new(config : @types.Config) -> ServerState {
  {
    config,
    registry: @registry.AgentRegistry::new(),
    tool_registry: @tools.ToolRegistry::new(),
    poller: @poller.PollerState::new(),
  }
}

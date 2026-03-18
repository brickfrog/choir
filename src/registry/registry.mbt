///|
/// In-memory agent registry.
pub(all) struct AgentRegistry {
  agents : Map[String, @types.Agent]
}

///|
/// Create a new empty registry.
pub fn AgentRegistry::new() -> AgentRegistry {
  { agents: {} }
}

///|
/// Register a new agent. Returns error if ID already exists.
pub fn AgentRegistry::insert(
  self : AgentRegistry,
  agent : @types.Agent,
) -> Result[Unit, @types.ExoError] {
  if self.agents.contains(agent.agent_id) {
    Err(
      @types.ExoError::ValidationError(
        "agent already exists: " + agent.agent_id,
      ),
    )
  } else {
    self.agents.set(agent.agent_id, agent)
    Ok(())
  }
}

///|
/// Look up an agent by ID.
pub fn AgentRegistry::get(
  self : AgentRegistry,
  agent_id : String,
) -> Result[@types.Agent, @types.ExoError] {
  match self.agents.get(agent_id) {
    Some(agent) => Ok(agent)
    None => Err(@types.ExoError::AgentNotFound(agent_id))
  }
}

///|
/// Get the parent agent for a given agent ID.
pub fn AgentRegistry::get_parent(
  self : AgentRegistry,
  agent_id : String,
) -> Result[@types.Agent, @types.ExoError] {
  match self.get(agent_id) {
    Err(e) => Err(e)
    Ok(agent) =>
      match agent.parent {
        Some(parent_id) => self.get(parent_id)
        None => Err(@types.ExoError::AgentNotFound("no parent for " + agent_id))
      }
  }
}

///|
/// Remove an agent from the registry.
pub fn AgentRegistry::remove(
  self : AgentRegistry,
  agent_id : String,
) -> Result[@types.Agent, @types.ExoError] {
  match self.agents.get(agent_id) {
    Some(agent) => {
      self.agents.remove(agent_id)
      Ok(agent)
    }
    None => Err(@types.ExoError::AgentNotFound(agent_id))
  }
}

///|
/// List all agents.
pub fn AgentRegistry::list(self : AgentRegistry) -> Array[@types.Agent] {
  self.agents.values().collect()
}

///|
/// List children of a given agent.
pub fn AgentRegistry::children(
  self : AgentRegistry,
  parent_id : String,
) -> Array[@types.Agent] {
  self.agents.values()
  |> Iter::filter(fn(a) { a.parent == Some(parent_id) })
  |> Iter::collect()
}

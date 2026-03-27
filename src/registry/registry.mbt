///|
/// In-memory agent registry.
pub(all) struct AgentRegistry {
  agents : Map[String, @types.Agent]
  alive : Map[String, Bool]
}

///|
/// Create a new empty registry.
pub fn AgentRegistry::new() -> AgentRegistry {
  { agents: {}, alive: {} }
}

///|
/// Register a new agent. Returns error if ID already exists.
pub fn AgentRegistry::insert(
  self : AgentRegistry,
  agent : @types.Agent,
) -> Result[Unit, @types.ChoirError] {
  let id = agent.agent_id.to_string()
  if self.agents.contains(id) {
    Err(@types.ChoirError::ValidationError("agent already exists: " + id))
  } else {
    self.agents.set(id, agent)
    self.alive.set(id, true)
    Ok(())
  }
}

///|
/// Register or refresh an agent in place, marking it alive.
pub fn AgentRegistry::upsert(
  self : AgentRegistry,
  agent : @types.Agent,
) -> Bool {
  let id = agent.agent_id.to_string()
  let existed = self.agents.contains(id)
  self.agents.set(id, agent)
  self.alive.set(id, true)
  existed
}

///|
/// Look up an agent by ID.
pub fn AgentRegistry::get(
  self : AgentRegistry,
  agent_id : String,
) -> Result[@types.Agent, @types.ChoirError] {
  match self.agents.get(agent_id) {
    Some(agent) => Ok(agent)
    None => Err(@types.ChoirError::AgentNotFound(agent_id))
  }
}

///|
/// Get the parent agent for a given agent ID.
pub fn AgentRegistry::get_parent(
  self : AgentRegistry,
  agent_id : String,
) -> Result[@types.Agent, @types.ChoirError] {
  match self.get(agent_id) {
    Err(e) => Err(e)
    Ok(agent) =>
      match agent.parent {
        Some(parent_id) => self.get(parent_id)
        None =>
          Err(@types.ChoirError::AgentNotFound("no parent for " + agent_id))
      }
  }
}

///|
/// Remove an agent from the registry.
pub fn AgentRegistry::remove(
  self : AgentRegistry,
  agent_id : String,
) -> Result[@types.Agent, @types.ChoirError] {
  match self.agents.get(agent_id) {
    Some(agent) => {
      self.agents.remove(agent_id)
      self.alive.remove(agent_id)
      Ok(agent)
    }
    None => Err(@types.ChoirError::AgentNotFound(agent_id))
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

///|
/// Update agent state with validation.
pub fn AgentRegistry::set_state(
  self : AgentRegistry,
  agent_id : String,
  new_state : @types.AgentState,
) -> Result[Unit, @types.ChoirError] {
  match self.agents.get(agent_id) {
    Some(agent) => {
      let valid = match (agent.state, new_state) {
        (Spawning, Active) => true
        (Active, Completing) => true
        (Active, Failed) => true
        (Completing, Done) => true
        (Failed, Done) => true
        _ => false
      }
      if valid {
        let updated_agent = { ..agent, state: new_state }
        self.agents.set(agent_id, updated_agent)
        Ok(())
      } else {
        Err(
          @types.ChoirError::ValidationError(
            "invalid state transition: " +
            agent.state.to_string() +
            " -> " +
            new_state.to_string(),
          ),
        )
      }
    }
    None => Err(@types.ChoirError::AgentNotFound(agent_id))
  }
}

///|
/// Set agent alive status.
pub fn AgentRegistry::set_alive(
  self : AgentRegistry,
  agent_id : String,
  alive : Bool,
) -> Result[Unit, @types.ChoirError] {
  match self.agents.get(agent_id) {
    Some(_) => {
      self.alive.set(agent_id, alive)
      Ok(())
    }
    None => Err(@types.ChoirError::AgentNotFound(agent_id))
  }
}

///|
/// Get all active agents.
pub fn AgentRegistry::active_agents(
  self : AgentRegistry,
) -> Array[@types.Agent] {
  self.agents.values()
  |> Iter::filter(fn(a) { a.state == @types.AgentState::Active })
  |> Iter::collect()
}

///|
/// Get agents by role.
pub fn AgentRegistry::by_role(
  self : AgentRegistry,
  role : @types.Role,
) -> Array[@types.Agent] {
  self.agents.values()
  |> Iter::filter(fn(a) { a.role == role })
  |> Iter::collect()
}

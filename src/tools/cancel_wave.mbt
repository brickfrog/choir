///|
/// Resolved parent id for `cancel_wave` when `caller_id` is omitted from the
/// tool request (matches historical `dispatch` default).
pub fn cancel_wave_resolved_caller_id(caller_id : String?) -> String {
  match caller_id {
    Some(v) => v
    None => "main"
  }
}

///|
/// Children targeted by `cancel_wave`: `Spawning` or `Active` only.
pub fn cancel_wave_non_terminal_agents(
  children : Array[@types.Agent],
) -> Array[@types.Agent] {
  children.filter(fn(agent) {
    agent.state == @types.AgentState::Spawning ||
    agent.state == @types.AgentState::Active
  })
}

///|
/// User-facing error when `force=false` and the poller reports a critical-phase
/// PR for the agent (stable `cancel_wave` wording).
pub fn cancel_wave_poller_block_message(
  agent_id : String,
  pr_number : Int,
) -> String {
  "cancel_wave: agent " +
  agent_id +
  " is blocked by PR #" +
  pr_number.to_string() +
  " with changes requested -- use force=true to override"
}

///|
/// Preflight when `force=false`: first matching non-terminal agent in iteration
/// order yields a block message; `None` means proceed. Poller absence skips the
/// gate (same as inline `cancel_wave`).
pub fn cancel_wave_preflight_block_message(
  force : Bool,
  non_terminal : Array[@types.Agent],
  poller_state : @poller.PollerState?,
) -> String? {
  if force {
    return None
  }
  let ps = match poller_state {
    Some(p) => p
    None => return None
  }
  for agent in non_terminal {
    let agent_id_str = agent.agent_id.to_string()
    match ps.critical_phase_pr_number(agent_id_str) {
      Some(pr_number) =>
        return Some(cancel_wave_poller_block_message(agent_id_str, pr_number))
      None => ()
    }
  }
  None
}

///|
/// Success JSON for `cancel_wave` after per-agent teardown.
pub fn cancel_wave_ok_response(cancelled : Int) -> @types.Response {
  @types.Response::ok_values({
    "status": String::to_json("ok"),
    "cancelled": Int::to_json(cancelled),
  })
}

///|
/// Per-agent host steps for `cancel_wave` (ordering matches dispatch).
pub(all) enum CancelWavePerAgentHostStep {
  PaneClose
  WorktreeRemove
  RegistryFailed
  PollerUntrack
} derive(Debug, Eq)

///|
pub impl Show for CancelWavePerAgentHostStep with output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
pub fn cancel_wave_per_agent_host_steps() -> Array[CancelWavePerAgentHostStep] {
  [
    CancelWavePerAgentHostStep::PaneClose,
    CancelWavePerAgentHostStep::WorktreeRemove,
    CancelWavePerAgentHostStep::RegistryFailed,
    CancelWavePerAgentHostStep::PollerUntrack,
  ]
}

///|
/// Effectful `cancel_wave` adapter: preflight gate, per-agent pane/worktree/
/// registry/poller steps, optional poller persistence. Preserves historical
/// `ToolRequest::CancelWave` control flow while keeping `dispatch` as a thin caller.
pub async fn interpret_cancel_wave(
  args : CancelWaveArgs,
  caller_id : String?,
  project_dir : String,
  poller_state : @poller.PollerState?,
  registry : @registry.AgentRegistry?,
  runner : async (Array[@workspace.Command]) -> Array[Int],
) -> @types.Response {
  match registry {
    None => @types.Response::Err("no agent registry available")
    Some(reg) => {
      let resolved_caller = cancel_wave_resolved_caller_id(caller_id)
      let children = reg.children(resolved_caller)
      let non_terminal = cancel_wave_non_terminal_agents(children)
      match
        cancel_wave_preflight_block_message(
          args.force,
          non_terminal,
          poller_state,
        ) {
        Some(msg) => return @types.Response::Err(msg)
        None => ()
      }
      let mut cancelled = 0
      let mut poller_changed = false
      for agent in non_terminal {
        let agent_id_str = agent.agent_id.to_string()
        match agent.terminal_target {
          Some(t) => {
            let kill_cmd = @workspace.local_close_target(t)
            let _ = runner([kill_cmd])
            ()
          }
          None => ()
        }
        if agent.workspace.contains(".choir/worktrees/") {
          let _ = runner([@workspace.git_worktree_remove(agent.workspace)])
          ()
        }
        let _ = reg.set_state(agent_id_str, @types.AgentState::Failed)
        match poller_state {
          Some(ps) => {
            let untracked = ps.untrack_by_agent_id(agent_id_str)
            if untracked > 0 {
              poller_changed = true
            }
          }
          None => ()
        }
        cancelled += 1
      }
      if poller_changed {
        match poller_state {
          Some(ps) => ignore(ps.write_state_file(project_dir))
          None => ()
        }
      }
      cancel_wave_ok_response(cancelled)
    }
  }
}

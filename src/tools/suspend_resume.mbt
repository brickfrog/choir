///|
/// Suspend an agent: transitions Active → Suspended and fires the
/// AgentSuspended hook so operators can page themselves.
///
/// Only the TL role may call this; enforcement is in the tool registry
/// allowlist (see `registry.mbt`). Leaves must not be able to self-suspend
/// as that would be a trivial denial-of-service.
pub async fn interpret_suspend(
  args : SuspendArgs,
  registry : @registry.AgentRegistry?,
  project_dir : String,
  hook_capture? : async (String, String, String?) -> (Int, String) = @exec.capture_hook_script_merged,
) -> @types.Response {
  match registry {
    None => @types.Response::Err("no agent registry available")
    Some(reg) => {
      ignore(reg.set_state(args.agent_id, @types.AgentState::Suspended)) catch {
        e => return @types.Response::Err(e.message())
      }
      @moontrace.warn("agent suspended", fields=[
        @moontrace.field("agent_id", args.agent_id),
        @moontrace.field("reason", args.reason),
      ])
      fire_hook_async(
        @hooks.HookEvent::AgentSuspended,
        {
          event: @hooks.HookEvent::AgentSuspended,
          session_id: None,
          agent_id: Some(args.agent_id),
          role: None,
          tool_name: None,
          tool_args: None,
          tool_result_status: None,
          exit_reason: None,
          suspend_reason: Some(args.reason),
        },
        project_dir,
        hook_capture~,
      )
      @types.Response::ok_values({
        "status": "suspended".to_json(),
        "agent_id": args.agent_id.to_json(),
      })
    }
  }
}

///|
/// Resume a suspended agent: transitions Suspended → Active, unblocks poll
/// delivery, and fires the AgentResumed hook so operators who paged on the
/// matching AgentSuspended event see the paired recovery.
pub async fn interpret_resume(
  args : ResumeArgs,
  registry : @registry.AgentRegistry?,
  project_dir : String,
  hook_capture? : async (String, String, String?) -> (Int, String) = @exec.capture_hook_script_merged,
) -> @types.Response {
  match registry {
    None => @types.Response::Err("no agent registry available")
    Some(reg) => {
      ignore(reg.set_state(args.agent_id, @types.AgentState::Active)) catch {
        e => return @types.Response::Err(e.message())
      }
      @moontrace.info("agent resumed", fields=[
        @moontrace.field("agent_id", args.agent_id),
      ])
      fire_hook_async(
        @hooks.HookEvent::AgentResumed,
        {
          event: @hooks.HookEvent::AgentResumed,
          session_id: None,
          agent_id: Some(args.agent_id),
          role: None,
          tool_name: None,
          tool_args: None,
          tool_result_status: None,
          exit_reason: None,
          suspend_reason: None,
        },
        project_dir,
        hook_capture~,
      )
      @types.Response::ok_values({
        "status": "resumed".to_json(),
        "agent_id": args.agent_id.to_json(),
      })
    }
  }
}

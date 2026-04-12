///|
fn hook_agent_id(input : @hooks.HookInput) -> String? {
  match input.agent_id {
    Some(agent_id) => Some(agent_id)
    None => @sys.getenv("CHOIR_AGENT_ID")
  }
}

///|
fn persist_hook_session(input : @hooks.HookInput) -> Unit {
  match input.event {
    @hooks.HookEvent::SessionStart =>
      match (input.session_id, hook_agent_id(input)) {
        (Some(session_id), Some(agent_id)) =>
          ignore(
            @sys.write_file_sync(
              ".choir/sessions/claude/" + agent_id + ".session_id",
              session_id,
            ),
          )
        _ => ()
      }
    _ => ()
  }
}

///|
fn hook_run() -> Unit {
  @async.run_async_main(async fn() {
    let line = match @sys.read_stdin_line(8192) {
      Some(line) => line
      None => {
        @sys.write_stdout(
          @hooks.HookResponse::fail_open().to_json_string() + "\n",
        )
        return
      }
    }
    let input = match @hooks.HookInput::from_json_string(line) {
      Some(i) => i
      None => {
        @sys.write_stdout(
          @hooks.HookResponse::fail_open().to_json_string() + "\n",
        )
        return
      }
    }
    persist_hook_session(input)

    let config_content = @sys.read_file(".choir/config.toml")

    let hook_key = match input.event {
      @hooks.HookEvent::SessionStart => "hook.session_start"
      @hooks.HookEvent::PreToolUse => "hook.pre_tool_use"
      @hooks.HookEvent::PostToolUse => "hook.post_tool_use"
      @hooks.HookEvent::AgentExit => "hook.agent_exit"
      @hooks.HookEvent::AgentSuspended => "hook.agent_suspended"
      @hooks.HookEvent::SessionStop => "hook.session_stop"
      @hooks.HookEvent::BeforeModel => "hook.before_model"
      @hooks.HookEvent::AfterModel => "hook.after_model"
    }

    match @config.hook_command_path(config_content, hook_key) {
      None =>
        @sys.write_stdout(@hooks.HookResponse::allow().to_json_string() + "\n")
      Some(cmd_path) => {
        let cmd = @workspace.Command::{
          program: cmd_path,
          args: [],
          workdir: None,
        }
        let exit_code = @exec.run(cmd) catch { _ => 1 }
        if exit_code == 0 {
          @sys.write_stdout(
            @hooks.HookResponse::allow().to_json_string() + "\n",
          )
        } else {
          @sys.write_stdout(
            @hooks.HookResponse::block("blocked").to_json_string() + "\n",
          )
        }
      }
    }
  })
}

///|
fn main {
  let (stdin_buf, len) = @io.read_stdin_line(8192)
  if len == 0 {
    @io.write_stdout(@hooks.HookResponse::fail_open().to_json_string() + "\n")
    return
  }

  let line = stdin_buf.to_unchecked_string(offset=0, length=len)
  let input = match @hooks.HookInput::from_json_string(line) {
    Some(i) => i
    None => {
      @io.write_stdout(@hooks.HookResponse::fail_open().to_json_string() + "\n")
      return
    }
  }

  let config_content = @io.read_file(".exo/config.toml")
  let config_map = @config.parse_toml(config_content)

  let hook_key = match input.event {
    @hooks.HookEvent::SessionStart => "hook.session_start"
    @hooks.HookEvent::PreToolUse => "hook.pre_tool_use"
  }

  match config_map.get(hook_key) {
    None =>
      @io.write_stdout(@hooks.HookResponse::allow().to_json_string() + "\n")
    Some(cmd_path) => {
      let cmd = @workspace.Command::{
        program: cmd_path,
        args: [],
        workdir: None,
      }
      match @exec.run(cmd) {
        Ok(0) =>
          @io.write_stdout(@hooks.HookResponse::allow().to_json_string() + "\n")
        _ =>
          @io.write_stdout(
            @hooks.HookResponse::block("blocked").to_json_string() + "\n",
          )
      }
    }
  }
}

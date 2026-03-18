///|
#borrow(path)
extern "C" fn c_get_file_size(path : Bytes) -> Int = "choir_get_file_size"

///|
#borrow(path, buf)
extern "C" fn c_read_file_to_buf(path : Bytes, buf : Bytes, size : Int) = "choir_read_file_to_buf"

///|
#borrow(buf)
extern "C" fn c_stdin_read_line(buf : Bytes, max_size : Int) -> Int = "choir_stdin_read_line"

///|
#borrow(buf)
extern "C" fn c_stdout_write(buf : Bytes, size : Int) = "choir_stdout_write"

///|
fn string_to_null_terminated_bytes(s : String) -> Bytes {
  let b = s.to_bytes()
  let len = b.length()
  let result = FixedArray::make(len + 1, (0 : Byte))
  for i = 0; i < len; i = i + 1 {
    result[i] = b[i]
  }
  result[len] = (0 : Byte)
  result.unsafe_reinterpret_as_bytes()
}

///|
fn read_file_to_string(path : String) -> String {
  let path_bytes = string_to_null_terminated_bytes(path)
  let size = c_get_file_size(path_bytes)
  if size < 0 {
    return ""
  }
  let buf = Bytes::new(size)
  c_read_file_to_buf(path_bytes, buf, size)
  buf.to_unchecked_string(offset=0, length=size)
}

///|
fn write_stdout(s : String) -> Unit {
  let b = s.to_bytes()
  c_stdout_write(b, b.length())
}

///|
fn main {
  let stdin_buf = Bytes::new(8192)
  let len = c_stdin_read_line(stdin_buf, 8192)
  if len == 0 {
    write_stdout(@hooks.HookResponse::fail_open().to_json_string() + "\n")
    return
  }

  let line = stdin_buf.to_unchecked_string(offset=0, length=len)
  let input = match @hooks.HookInput::from_json_string(line) {
    Some(i) => i
    None => {
      write_stdout(@hooks.HookResponse::fail_open().to_json_string() + "\n")
      return
    }
  }

  let config_content = read_file_to_string(".exo/config.toml")
  let config_map = @config.parse_toml(config_content)

  let hook_key = match input.event {
    @hooks.HookEvent::SessionStart => "hook.session_start"
    @hooks.HookEvent::PreToolUse => "hook.pre_tool_use"
  }

  match config_map.get(hook_key) {
    None => write_stdout(@hooks.HookResponse::allow().to_json_string() + "\n")
    Some(cmd_path) => {
      let cmd = @workspace.Command::{
        program: cmd_path,
        args: [],
        workdir: None,
      }
      match @exec.run(cmd) {
        Ok(0) =>
          write_stdout(@hooks.HookResponse::allow().to_json_string() + "\n")
        _ =>
          write_stdout(
            @hooks.HookResponse::block("blocked").to_json_string() + "\n",
          )
      }
    }
  }
}

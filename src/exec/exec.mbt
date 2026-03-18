///|
pub fn quote(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('\'')
  for c in s {
    if c == '\'' {
      buf.write_string("'\\''")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('\'')
  buf.to_string()
}

///|
pub fn command_to_shell_string(cmd : @workspace.Command) -> String {
  let mut shell_cmd = quote(cmd.program)
  for arg in cmd.args {
    shell_cmd = shell_cmd + " " + quote(arg)
  }
  match cmd.workdir {
    None => shell_cmd
    Some(dir) => "cd " + quote(dir) + " && " + shell_cmd
  }
}

///|
pub fn run(cmd : @workspace.Command) -> Result[Int, String] {
  let shell_str = command_to_shell_string(cmd)
  let bytes = string_to_null_terminated_bytes(shell_str)
  let status = c_system(bytes)
  if status == -1 {
    Err("system() failed")
  } else {
    Ok(status)
  }
}

///|
pub fn run_sequence(
  cmds : Array[@workspace.Command],
) -> Result[Array[Int], String] {
  let results = []
  for cmd in cmds {
    match run(cmd) {
      Ok(status) => {
        results.push(status)
        if status != 0 {
          return Ok(results)
        }
      }
      Err(err) => return Err(err)
    }
  }
  Ok(results)
}

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

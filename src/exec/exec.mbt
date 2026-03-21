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
pub async fn run(cmd : @workspace.Command) -> Int {
  let prog = cmd.program
  let args = cmd.args[:]
  match cmd.workdir {
    Some(dir) => @process.run(prog, args, cwd=dir)
    None => @process.run(prog, args)
  }
}

///|
pub async fn run_sequence(cmds : Array[@workspace.Command]) -> Array[Int] {
  let results = []
  for cmd in cmds {
    let status = run(cmd)
    results.push(status)
    if status != 0 {
      return results
    }
  }
  results
}

///|
pub fn quote(s : String) -> String {
  @sys.shell_quote(s)
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
/// Read up to `max_bytes` from a pipe wired to process stdout (or stderr), close the reader,
/// and return the captured output as lossy UTF-8 plus the number of bytes read.
pub async fn drain_process_stdout(
  reader : @process.ReadFromProcess,
  max_bytes : Int,
) -> (String, Int) {
  let buf = FixedArray::make(max_bytes, (0 : Byte))
  let mut total = 0
  for ;; {
    if total >= buf.length() {
      break
    }
    let n = reader.read(buf, offset=total, max_len=buf.length() - total) catch {
      _ => 0
    }
    if n == 0 {
      break
    }
    total = total + n
  }
  reader.close()
  (@utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:total]), total)
}

///|
/// Spawn `program` with `args`, capture stdout (up to 64KiB), wait for exit, return decoded output.
pub async fn capture_stdout(program : String, args : Array[String]) -> String {
  let (reader, writer) = @process.read_from_process() catch { _ => return "" }
  let pid = @process.spawn_orphan(program, args[:], stdout=writer) catch {
    _ => {
      reader.close()
      return ""
    }
  }
  let (output, _) = drain_process_stdout(reader, 65536)
  ignore(@process.wait_pid(pid) catch { _ => -1 })
  output
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

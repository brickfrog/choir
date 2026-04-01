///|
pub struct PaneWatcher {
  subscribe_pids : Map[String, Int]
}

///|
pub fn PaneWatcher::new() -> PaneWatcher {
  { subscribe_pids: {} }
}

///|
pub fn PaneWatcher::watch_pane(
  self : PaneWatcher,
  agent_id : String,
  target : @types.LocalTarget,
) -> Unit {
  let snapshot_path = "/tmp/choir-viewport-" + agent_id + ".json"
  // Pipe: zellij subscribe streams JSON, shell overwrites snapshot on each line
  let cmd = "zellij --session " +
    @sys.shell_quote(target.session) +
    " subscribe pane-viewport --pane-id " +
    @sys.shell_quote(target.name) +
    " --format json 2>/dev/null | while IFS= read -r line; do printf '%s' \"$line\" > " +
    @sys.shell_quote(snapshot_path) +
    "; done"
  // Background the subscribe pipeline; store its PID via a pidfile
  let pid_path = "/tmp/choir-subscribe-" + agent_id + ".pid"
  let bg_cmd = cmd + " & echo $! > " + @sys.shell_quote(pid_path)
  ignore(@sys.system(bg_cmd))
  let pid_str = @sys.read_file(pid_path).trim().to_string()
  let pid = parse_int_simple(pid_str)
  if pid > 0 {
    self.subscribe_pids.set(agent_id, pid)
  }
}

///|
pub fn PaneWatcher::stop_subscribe(
  self : PaneWatcher,
  agent_id : String,
) -> Unit {
  match self.subscribe_pids.get(agent_id) {
    Some(pid) => {
      ignore(@sys.system("kill " + pid.to_string() + " 2>/dev/null || true"))
      self.subscribe_pids.remove(agent_id)
    }
    None => ()
  }
  ignore(
    @sys.system(
      "rm -f " +
      @sys.shell_quote("/tmp/choir-viewport-" + agent_id + ".json") +
      " " +
      @sys.shell_quote("/tmp/choir-subscribe-" + agent_id + ".pid"),
    ),
  )
}

///|
pub fn PaneWatcher::read_viewport(
  self : PaneWatcher,
  agent_id : String,
) -> String {
  ignore(self)
  let snapshot_path = "/tmp/choir-viewport-" + agent_id + ".json"
  @sys.read_file(snapshot_path)
}

///|
pub fn parse_int_simple(s : String) -> Int {
  let mut result = 0
  for c in s {
    let d = c.to_int() - '0'.to_int()
    if d >= 0 && d <= 9 {
      result = result * 10 + d
    }
  }
  result
}

///|
/// Path for the zellij pane-viewport JSON snapshot for `agent_id` (under `/tmp`).
pub fn pane_snapshot_path(agent_id : String) -> String {
  "/tmp/choir-viewport-" + agent_id + ".json"
}

///|
pub struct PaneWatcher {
  subscribe_pids : Map[String, Int]
  last_change_at : Map[String, Int64]
  last_hashes : Map[String, Int]
}

///|
pub fn PaneWatcher::new() -> PaneWatcher {
  { subscribe_pids: {}, last_change_at: {}, last_hashes: {} }
}

///|
pub async fn PaneWatcher::watch_pane(
  self : PaneWatcher,
  agent_id : String,
  target : @types.LocalTarget,
  now : Int64,
) -> Unit {
  self.last_change_at.set(agent_id, now)
  let snapshot_path = pane_snapshot_path(agent_id)
  // Pipe: zellij subscribe streams JSON, shell overwrites snapshot on each line
  let cmd = "zellij --session " +
    @sys.shell_quote(target.session) +
    " subscribe pane-viewport --pane-id " +
    @sys.shell_quote(target.name) +
    " --format json 2>/dev/null | while IFS= read -r line; do printf '%s' \"$line\" > " +
    @sys.shell_quote(snapshot_path) +
    "; done"
  let pid = @process.spawn_orphan("sh", ["-c", cmd]) catch { _ => return }
  if pid > 0 {
    self.subscribe_pids.set(agent_id, pid)
  }
}

///|
pub fn PaneWatcher::stop_subscribe(
  self : PaneWatcher,
  agent_id : String,
) -> Unit {
  self.last_change_at.remove(agent_id)
  self.last_hashes.remove(agent_id)
  match self.subscribe_pids.get(agent_id) {
    Some(pid) => {
      @sys.kill_pid_best_effort(pid)
      self.subscribe_pids.remove(agent_id)
    }
    None => ()
  }
  ignore(@sys.delete_file_sync(pane_snapshot_path(agent_id)))
}

///|
pub fn PaneWatcher::read_viewport(
  self : PaneWatcher,
  agent_id : String,
) -> String {
  ignore(self)
  let snapshot_path = pane_snapshot_path(agent_id)
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

///|
/// Extract viewport text from a zellij subscribe JSON snapshot.
/// Format: {"event":"pane_update","viewport":["line1","line2",...]}
pub fn extract_viewport_text(json_str : String) -> String {
  if json_str == "" {
    return ""
  }
  let parsed : Json = @json.parse(json_str) catch { _ => return json_str }
  match parsed {
    Object(obj) =>
      match obj.get("viewport") {
        Some(Array(lines)) => {
          let buf = StringBuilder::new()
          for line in lines {
            match line {
              String(s) => {
                buf.write_string(s)
                buf.write_char('\n')
              }
              _ => ()
            }
          }
          buf.to_string()
        }
        _ => json_str
      }
    _ => json_str
  }
}

///|
pub fn simple_hash(s : String) -> Int {
  let mut h = 5381
  for c in s {
    h = (h * 31 + c.to_int()) % 1_000_000_007
  }
  // Reserve 0 as sentinel for "no snapshot yet"
  if h == 0 {
    1
  } else {
    h
  }
}

///|
/// Checks if the agent's pane has been idle. Returns `Some(screen_text)` if idle, `None` if not idle or not being watched.
pub fn PaneWatcher::check_idle(
  self : PaneWatcher,
  agent_id : String,
  now : Int64,
  timeout : Int64,
) -> String? {
  let snapshot = self.read_viewport(agent_id)
  if snapshot.trim().to_string() == "" {
    return None
  }
  let screen = extract_viewport_text(snapshot)
  let hash = simple_hash(screen)
  let prev_hash = self.last_hashes.get(agent_id).unwrap_or(0)

  if hash != prev_hash {
    self.last_change_at.set(agent_id, now)
    self.last_hashes.set(agent_id, hash)
    return None
  }

  let last_change = self.last_change_at.get(agent_id).unwrap_or(now)
  let elapsed = now - last_change
  if elapsed >= timeout {
    Some(screen)
  } else {
    None
  }
}

///|
pub fn PaneWatcher::watched_agents(self : PaneWatcher) -> Array[String] {
  let ids = []
  self.subscribe_pids.each(fn(agent_id, _) { ids.push(agent_id) })
  ids
}

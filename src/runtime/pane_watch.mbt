///|
/// Path for the zellij pane-viewport JSON snapshot for `agent_id` (under `/tmp`).
pub fn pane_snapshot_path(agent_id : String) -> String {
  "/tmp/choir-viewport-" + agent_id + ".json"
}

///|
/// Host I/O for pane viewport subscribe: zellij child processes, pid cleanup, and snapshot files.
pub(all) struct PaneWatchHost {
  spawn_zellij_pane_viewport_subscribe : (String, String, String) -> Int
  kill_pid_best_effort : (Int) -> Unit
  delete_file_sync : (String) -> Unit
  read_file : (String) -> String
}

///|
pub fn PaneWatchHost::native() -> PaneWatchHost {
  {
    spawn_zellij_pane_viewport_subscribe: @sys.spawn_zellij_pane_viewport_subscribe,
    kill_pid_best_effort: @sys.kill_pid_best_effort,
    delete_file_sync: fn(path) { ignore(@sys.delete_file_sync(path)) },
    read_file: @sys.read_file,
  }
}

///|
pub(all) struct WatchState {
  pid : Int
  mut last_change_at : Int64
  mut last_hash : Int
  mut last_len : Int
}

///|
pub struct PaneWatcher {
  watches : Map[String, WatchState]
  host : PaneWatchHost
}

///|
pub fn PaneWatcher::new() -> PaneWatcher {
  PaneWatcher::with_host(PaneWatchHost::native())
}

///|
pub fn PaneWatcher::with_host(host : PaneWatchHost) -> PaneWatcher {
  { watches: {}, host }
}

///|
pub fn PaneWatcher::watch_pane(
  self : PaneWatcher,
  agent_id : String,
  target : @types.LocalTarget,
  now : Int64,
) -> Unit {
  let snapshot_path = pane_snapshot_path(agent_id)
  let pid = (self.host.spawn_zellij_pane_viewport_subscribe)(
    target.session,
    target.name,
    snapshot_path,
  )
  if pid > 0 {
    self.watches.set(agent_id, {
      pid,
      last_change_at: now,
      last_hash: 0,
      last_len: 0,
    })
  }
}

///|
pub fn PaneWatcher::stop_subscribe(
  self : PaneWatcher,
  agent_id : String,
) -> Unit {
  match self.watches.get(agent_id) {
    Some(watch) => {
      (self.host.kill_pid_best_effort)(watch.pid)
      self.watches.remove(agent_id)
    }
    None => ()
  }
  (self.host.delete_file_sync)(pane_snapshot_path(agent_id))
}

///|
pub fn PaneWatcher::read_viewport(
  self : PaneWatcher,
  agent_id : String,
) -> String {
  let snapshot_path = pane_snapshot_path(agent_id)
  (self.host.read_file)(snapshot_path)
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
  let h = s.hash()
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
  let watch = match self.watches.get(agent_id) {
    Some(w) => w
    None => return None
  }
  let snapshot = self.read_viewport(agent_id)
  if snapshot.trim().to_owned() == "" {
    return None
  }
  let screen = extract_viewport_text(snapshot)
  let hash = simple_hash(screen)
  let len = screen.length()

  if hash != watch.last_hash || len != watch.last_len {
    watch.last_change_at = now
    watch.last_hash = hash
    watch.last_len = len
    return None
  }

  let elapsed = now - watch.last_change_at
  if elapsed >= timeout {
    Some(screen)
  } else {
    None
  }
}

///|
pub fn PaneWatcher::watched_agents(self : PaneWatcher) -> Array[String] {
  let ids = []
  self.watches.each(fn(agent_id, _) { ids.push(agent_id) })
  ids
}

///|
pub(all) struct PaneWatchHost {
  dump_pane_screen : async (String, String) -> String
}

///|
async fn empty_dump_pane_screen(_session : String, _pane_id : String) -> String {
  @async.sleep(0)
  ""
}

///|
pub fn PaneWatchHost::empty() -> PaneWatchHost {
  { dump_pane_screen: empty_dump_pane_screen }
}

///|
// AUDIT: Visibility kept at pub(all) for blackbox test field reads. Tightening
// would require moving tests inline (whitebox).
pub(all) struct WatchObservation {
  last_change_at : Int64
  last_hash : Int
  last_len : Int
}

///|
pub(all) struct WatchState {
  session : String
  pane_id : String?
  mut observation : WatchObservation
}

///|
pub(all) struct PaneIdleObservation {
  screen : String
  idle_sec : Int64
}

///|
pub struct PaneWatcher {
  watches : Map[String, WatchState]
  host : PaneWatchHost
}

///|
pub fn PaneWatcher::new() -> PaneWatcher {
  PaneWatcher::with_host(PaneWatchHost::empty())
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
  pane_id? : String? = None,
) -> Unit {
  let resolved = match pane_id {
    Some(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed == "" {
        None
      } else {
        Some(trimmed)
      }
    }
    None => None
  }
  self.watches.set(agent_id, {
    session: target.session,
    pane_id: resolved,
    observation: { last_change_at: now, last_hash: 0, last_len: 0 },
  })
}

///|
pub fn PaneWatcher::pane_id_for_agent(
  self : PaneWatcher,
  agent_id : String,
) -> String? {
  match self.watches.get(agent_id) {
    Some(watch) => watch.pane_id
    None => None
  }
}

///|
pub fn PaneWatcher::is_watching_agent(
  self : PaneWatcher,
  agent_id : String,
) -> Bool {
  self.watches.contains(agent_id)
}

///|
pub fn PaneWatcher::stop_watching(
  self : PaneWatcher,
  agent_id : String,
) -> Unit {
  self.watches.remove(agent_id)
}

///|
pub async fn PaneWatcher::current_screen(
  self : PaneWatcher,
  agent_id : String,
) -> String? {
  let watch = match self.watches.get(agent_id) {
    Some(watch) => watch
    None => return None
  }
  let pane_id = match watch.pane_id {
    Some(value) => value
    None => return None
  }
  let screen = (self.host.dump_pane_screen)(watch.session, pane_id)
  if screen.trim().to_owned() == "" {
    None
  } else {
    Some(screen)
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
fn PaneWatcher::record_observation(
  self : PaneWatcher,
  agent_id : String,
  hash : Int,
  len : Int,
  now : Int64,
) -> Bool {
  match self.watches.get(agent_id) {
    Some(watch) => {
      watch.observation = {
        last_change_at: now,
        last_hash: hash,
        last_len: len,
      }
      true
    }
    None => false
  }
}

///|
/// Checks if the agent's pane has been idle. Returns `Some(screen_text)` if idle, `None` if not idle or not being watched.
/// This is the pane-watch idle/no-heartbeat proxy signal; it emits no hard
/// disconnect notification by itself.
pub async fn PaneWatcher::observe_idle(
  self : PaneWatcher,
  agent_id : String,
  now : Int64,
) -> PaneIdleObservation? {
  let watch = match self.watches.get(agent_id) {
    Some(watch) => watch
    None => return None
  }
  let pane_id = match watch.pane_id {
    Some(value) => value
    None => return None
  }
  let screen = (self.host.dump_pane_screen)(watch.session, pane_id)
  if screen.trim().to_owned() == "" {
    return None
  }
  let hash = simple_hash(screen)
  let len = screen.length()
  let observation = watch.observation

  if hash != observation.last_hash || len != observation.last_len {
    ignore(self.record_observation(agent_id, hash, len, now))
    return None
  }

  let elapsed = now - observation.last_change_at
  Some({ screen, idle_sec: elapsed })
}

///|
/// Checks if the agent's pane has been idle. Returns `Some(screen_text)` if idle, `None` if not idle or not being watched.
/// This is the pane-watch idle/no-heartbeat proxy signal; it emits no hard
/// disconnect notification by itself.
pub async fn PaneWatcher::check_idle(
  self : PaneWatcher,
  agent_id : String,
  now : Int64,
  timeout : Int64,
) -> String? {
  match self.observe_idle(agent_id, now) {
    Some(observation) if observation.idle_sec >= timeout =>
      Some(observation.screen)
    _ => None
  }
}

///|
pub fn PaneWatcher::watched_agents(self : PaneWatcher) -> Array[String] {
  let ids = []
  self.watches.each(fn(agent_id, _) { ids.push(agent_id) })
  ids
}

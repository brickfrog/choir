///|
pub(all) struct MutexEntry {
  mut holder : String?
  mut acquired_sec : Int64
  ttl_sec : Int64
  queue : Array[String]
}

///|
pub(all) struct MutexRegistry {
  locks : Map[String, MutexEntry]
}

///|
pub fn MutexRegistry::new() -> MutexRegistry {
  { locks: Map::new() }
}

///|
fn queue_contains(queue : Array[String], agent_id : String) -> Bool {
  for queued_id in queue {
    if queued_id == agent_id {
      return true
    }
  }
  false
}

///|
fn clear_queue(queue : Array[String]) -> Unit {
  queue.clear()
}

///|
pub fn MutexRegistry::acquire(
  self : MutexRegistry,
  name : String,
  agent_id : String,
  ttl_sec : Int64,
  now : Int64,
) -> (Bool, Int) {
  match self.locks.get(name) {
    None => {
      self.locks.set(name, {
        holder: Some(agent_id),
        acquired_sec: now,
        ttl_sec,
        queue: [],
      })
      (true, 0)
    }
    Some(entry) =>
      if entry.holder != None && now - entry.acquired_sec > entry.ttl_sec {
        entry.holder = Some(agent_id)
        entry.acquired_sec = now
        clear_queue(entry.queue)
        (true, 0)
      } else if entry.holder == None {
        entry.holder = Some(agent_id)
        entry.acquired_sec = now
        (true, 0)
      } else if entry.holder == Some(agent_id) {
        entry.acquired_sec = now
        (true, 0)
      } else {
        let mut idx = -1
        for i = 0; i < entry.queue.length(); i = i + 1 {
          if entry.queue[i] == agent_id {
            idx = i
            break
          }
        }
        if idx >= 0 {
          (false, idx + 1)
        } else {
          entry.queue.push(agent_id)
          (false, entry.queue.length())
        }
      }
  }
}

///|
pub fn MutexRegistry::release(
  self : MutexRegistry,
  name : String,
  agent_id : String,
) -> String? {
  match self.locks.get(name) {
    None => None
    Some(entry) =>
      if entry.holder == Some(agent_id) {
        if entry.queue.length() > 0 {
          let next = entry.queue.remove(0)
          entry.holder = Some(next)
          entry.acquired_sec = 0L
          Some(next)
        } else {
          entry.holder = None
          None
        }
      } else {
        let mut i = 0
        while i < entry.queue.length() {
          if entry.queue[i] == agent_id {
            ignore(entry.queue.remove(i))
            break
          }
          i = i + 1
        }
        None
      }
  }
}

///|
pub fn MutexRegistry::status(
  self : MutexRegistry,
  name : String,
) -> (String?, Array[String]) {
  match self.locks.get(name) {
    None => (None, [])
    Some(entry) => (entry.holder, entry.queue)
  }
}

///|
pub fn MutexRegistry::expire(self : MutexRegistry, now : Int64) -> Unit {
  for entry in self.locks.values() {
    if entry.holder is Some(_) && now - entry.acquired_sec > entry.ttl_sec {
      if entry.queue.length() > 0 {
        let next = entry.queue.remove(0)
        entry.holder = Some(next)
        entry.acquired_sec = now
      } else {
        entry.holder = None
      }
    }
  }
}

///|
pub fn MutexRegistry::is_waiting(
  self : MutexRegistry,
  name : String,
  agent_id : String,
) -> Bool {
  match self.locks.get(name) {
    None => false
    Some(entry) => queue_contains(entry.queue, agent_id)
  }
}

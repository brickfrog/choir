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
  now_sec : Int64,
) -> String? {
  match self.locks.get(name) {
    None => None
    Some(entry) =>
      if entry.holder == Some(agent_id) {
        if entry.queue.length() > 0 {
          let next = entry.queue.remove(0)
          entry.holder = Some(next)
          // The new holder's TTL starts now; a sentinel (e.g. 0L) would
          // make `expire()` (now - 0L > ttl_sec) fire instantly under
          // real Unix-scale timestamps.
          entry.acquired_sec = now_sec
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

///|
pub fn MutexRegistry::clear(self : MutexRegistry) -> Unit {
  let names : Array[String] = []
  self.locks.each(fn(name, _entry) { names.push(name) })
  for name in names {
    self.locks.remove(name)
  }
}

///|
fn mutex_optional_string_json(value : String?) -> Json {
  match value {
    Some(v) => v.to_json()
    None => @json.parse("null") catch { _ => "".to_json() }
  }
}

///|
fn mutex_entry_snapshot_json(name : String, entry : MutexEntry) -> Json {
  {
    "name": name.to_json(),
    "holder": mutex_optional_string_json(entry.holder),
    "acquired_sec": entry.acquired_sec.to_json(),
    "ttl_sec": entry.ttl_sec.to_json(),
    "queue": entry.queue.to_json(),
  }.to_json()
}

///|
pub fn MutexRegistry::to_snapshot_json(self : MutexRegistry) -> Json {
  let locks : Array[Json] = []
  self.locks.each(fn(name, entry) {
    locks.push(mutex_entry_snapshot_json(name, entry))
  })
  { "version": (1).to_json(), "locks": locks.to_json() }.to_json()
}

///|
fn mutex_parse_error(message : String) -> @types.ChoirError {
  @types.ChoirError::validation_error(
    "mutex registry snapshot parse error: " + message,
  )
}

///|
fn mutex_string_field(
  obj : Map[String, Json],
  key : String,
) -> Result[String, @types.ChoirError] {
  match obj.get(key) {
    Some(String(value)) => Ok(value)
    _ => Err(mutex_parse_error("missing string field: " + key))
  }
}

///|
fn mutex_optional_string_field(
  obj : Map[String, Json],
  key : String,
) -> Result[String?, @types.ChoirError] {
  match obj.get(key) {
    Some(String(value)) => Ok(Some(value))
    // Absent or explicit JSON `null` both mean "no value"; the encoder
    // writes `null` for None on a released lock, so accept it on read.
    None | Some(Null) => Ok(None)
    // Present-but-malformed (a non-string, non-null value) must reject
    // rather than silently coerce to None — a corrupt holder field would
    // otherwise drop the lock owner and the lock would appear unheld
    // after restore.
    Some(_) => Err(mutex_parse_error("optional field is not a string: " + key))
  }
}

///|
fn mutex_int64_field(
  obj : Map[String, Json],
  key : String,
) -> Result[Int64, @types.ChoirError] {
  match @types.json_field_int64(obj, key) {
    Some(value) => Ok(value)
    None => Err(mutex_parse_error("missing numeric field: " + key))
  }
}

///|
fn mutex_string_array_field(
  obj : Map[String, Json],
  key : String,
) -> Result[Array[String], @types.ChoirError] {
  match obj.get(key) {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(value) => out.push(value)
          _ => return Err(mutex_parse_error(key + " contains non-string"))
        }
      }
      Ok(out)
    }
    _ => Err(mutex_parse_error("missing string array field: " + key))
  }
}

///|
fn mutex_parse_entry(
  obj : Map[String, Json],
) -> Result[(String, MutexEntry), @types.ChoirError] {
  let name = match mutex_string_field(obj, "name") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let holder = match mutex_optional_string_field(obj, "holder") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let acquired_sec = match mutex_int64_field(obj, "acquired_sec") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let ttl_sec = match mutex_int64_field(obj, "ttl_sec") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let queue = match mutex_string_array_field(obj, "queue") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  Ok((name, { holder, acquired_sec, ttl_sec, queue }))
}

///|
pub(all) struct MutexRegistrySnapshot {
  locks : Array[(String, MutexEntry)]
}

///|
/// Parse a mutex-registry snapshot JSON into a staging value without
/// touching the live registry. Commit via `apply_parsed_snapshot`.
pub fn parse_mutex_registry_snapshot_json(
  json : Json,
) -> Result[MutexRegistrySnapshot, @types.ChoirError] {
  guard json is Object(root) else {
    return Err(mutex_parse_error("expected object"))
  }
  guard root.get("locks") is Some(Array(items)) else {
    return Err(mutex_parse_error("missing locks array"))
  }
  let parsed : Array[(String, MutexEntry)] = []
  for item in items {
    guard item is Object(obj) else {
      return Err(mutex_parse_error("lock entry is not an object"))
    }
    match mutex_parse_entry(obj) {
      Ok(pair) => parsed.push(pair)
      Err(e) => return Err(e)
    }
  }
  Ok({ locks: parsed })
}

///|
/// Replace the mutex registry contents with a previously-parsed snapshot.
/// Caller-owned parse+validation; this is the commit step.
///
/// When `is_known_agent` is provided, any held lock whose holder is NOT in
/// that set is RELEASED on restore rather than persisted as held. Without
/// this, a snapshot from before a re-exec can leave a lock held by an
/// agent id that doesn't exist in the new process's registry — the lock
/// would only clear when TTL expires, blocking unrelated callers for the
/// TTL window. The caller (server reload path) populates the registry
/// first, then passes `is_known_agent` from the live registry so this
/// runs against fresh state.
pub fn MutexRegistry::apply_parsed_snapshot(
  self : MutexRegistry,
  snapshot : MutexRegistrySnapshot,
  is_known_agent? : (String) -> Bool = fn(_id) { true },
) -> Unit {
  self.clear()
  for pair in snapshot.locks {
    let (name, entry) = pair
    let entry_to_restore = match entry.holder {
      Some(holder) =>
        if is_known_agent(holder) {
          entry
        } else {
          { ..entry, holder: None, acquired_sec: 0L }
        }
      None => entry
    }
    self.locks.set(name, entry_to_restore)
  }
}

///|
pub fn MutexRegistry::restore_snapshot_json(
  self : MutexRegistry,
  json : Json,
) -> Result[Unit, @types.ChoirError] {
  match parse_mutex_registry_snapshot_json(json) {
    Ok(snapshot) => {
      self.apply_parsed_snapshot(snapshot)
      Ok(())
    }
    Err(e) => Err(e)
  }
}

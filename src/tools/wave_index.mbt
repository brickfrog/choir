///|
/// Persistent per-wave record for telemetry: replay (`choir log`) and usage
/// rollups (`choir stats`). Lives at `.choir/waves/<wave_id>.json`, one file
/// per wave, written at fork time by `fork_wave`, updated as leaves report
/// usage and as rescue/merge events happen.
pub(all) struct WaveIndex {
  wave_id : String
  parent_branch : String
  fork_ts_ms : Int64
  agent_ids : Array[String]
  rescued : Map[String, String]
  usage : Map[String, WaveUsage]
} derive(Debug, Eq)

///|
pub(all) struct WaveUsage {
  agent_type : @types.AgentType
  tokens_in : Int
  tokens_out : Int
  elapsed_s : Int
  cost_usd : Double?
  reported_at_ms : Int64
} derive(Debug, Eq)

///|
pub fn WaveIndex::new(
  wave_id : String,
  parent_branch : String,
  fork_ts_ms : Int64,
  agent_ids : Array[String],
) -> WaveIndex {
  { wave_id, parent_branch, fork_ts_ms, agent_ids, rescued: {}, usage: {} }
}

///|
pub fn wave_index_dir(project_dir : String) -> String {
  project_dir + "/.choir/waves"
}

///|
pub fn wave_index_path(project_dir : String, wave_id : String) -> String {
  wave_index_dir(project_dir) + "/" + wave_id + ".json"
}

///|
fn wave_usage_to_json(u : WaveUsage) -> Json {
  let obj : Map[String, Json] = {
    "agent_type": u.agent_type.to_wire_string().to_json(),
    "tokens_in": u.tokens_in.to_json(),
    "tokens_out": u.tokens_out.to_json(),
    "elapsed_s": u.elapsed_s.to_json(),
    "reported_at_ms": Json::number(u.reported_at_ms.to_double()),
  }
  match u.cost_usd {
    Some(c) => obj.set("cost_usd", c.to_json())
    None => ()
  }
  obj.to_json()
}

///|
pub fn render_wave_index_json(idx : WaveIndex) -> String {
  let usage_obj : Map[String, Json] = {}
  for k, v in idx.usage {
    usage_obj.set(k, wave_usage_to_json(v))
  }
  let rescued_obj : Map[String, Json] = {}
  for k, v in idx.rescued {
    rescued_obj.set(k, v.to_json())
  }
  let agent_ids_json : Array[Json] = []
  for a in idx.agent_ids {
    agent_ids_json.push(a.to_json())
  }
  let root : Map[String, Json] = {
    "wave_id": idx.wave_id.to_json(),
    "parent_branch": idx.parent_branch.to_json(),
    "fork_ts_ms": Json::number(idx.fork_ts_ms.to_double()),
    "agent_ids": agent_ids_json.to_json(),
    "rescued": rescued_obj.to_json(),
    "usage": usage_obj.to_json(),
  }
  root.to_json().stringify()
}

///|
fn parse_wave_usage(v : Json) -> Result[WaveUsage, @types.ChoirError] {
  guard v is Object(obj) else {
    return Err(@types.ChoirError::config_error("usage entry must be an object"))
  }
  let agent_type = match obj.get("agent_type") {
    Some(String(s)) =>
      match @types.AgentType::try_parse_wire(s) {
        Ok(@types.AgentType::Unknown) =>
          return Err(
            @types.ChoirError::config_error("unknown agent_type: " + s),
          )
        Ok(t) => t
        Err(e) => return Err(e)
      }
    _ =>
      return Err(
        @types.ChoirError::config_error("usage entry missing 'agent_type'"),
      )
  }
  let tokens_in = match obj.get("tokens_in") {
    Some(Number(n, ..)) => n.to_int()
    _ =>
      return Err(
        @types.ChoirError::config_error("usage entry missing 'tokens_in'"),
      )
  }
  let tokens_out = match obj.get("tokens_out") {
    Some(Number(n, ..)) => n.to_int()
    _ =>
      return Err(
        @types.ChoirError::config_error("usage entry missing 'tokens_out'"),
      )
  }
  let elapsed_s = match obj.get("elapsed_s") {
    Some(Number(n, ..)) => n.to_int()
    _ =>
      return Err(
        @types.ChoirError::config_error("usage entry missing 'elapsed_s'"),
      )
  }
  let reported_at_ms = match obj.get("reported_at_ms") {
    Some(Number(n, ..)) => n.to_int64()
    _ =>
      return Err(
        @types.ChoirError::config_error("usage entry missing 'reported_at_ms'"),
      )
  }
  let cost_usd = match obj.get("cost_usd") {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
  Ok({ agent_type, tokens_in, tokens_out, elapsed_s, cost_usd, reported_at_ms })
}

///|
pub fn parse_wave_index_json(
  s : String,
) -> Result[WaveIndex, @types.ChoirError] {
  let parsed = @json.parse(s) catch {
    e =>
      return Err(
        @types.ChoirError::config_error(
          "malformed wave index JSON: " + e.to_string(),
        ),
      )
  }
  guard parsed is Object(obj) else {
    return Err(@types.ChoirError::config_error("wave index must be an object"))
  }
  let wave_id = match obj.get("wave_id") {
    Some(String(s)) => s
    _ =>
      return Err(
        @types.ChoirError::config_error("wave index missing 'wave_id'"),
      )
  }
  let parent_branch = match obj.get("parent_branch") {
    Some(String(s)) => s
    _ =>
      return Err(
        @types.ChoirError::config_error("wave index missing 'parent_branch'"),
      )
  }
  let fork_ts_ms = match obj.get("fork_ts_ms") {
    Some(Number(n, ..)) => n.to_int64()
    _ =>
      return Err(
        @types.ChoirError::config_error("wave index missing 'fork_ts_ms'"),
      )
  }
  let agent_ids : Array[String] = []
  match obj.get("agent_ids") {
    Some(Array(arr)) =>
      for a in arr {
        match a {
          String(s) => agent_ids.push(s)
          _ =>
            return Err(
              @types.ChoirError::config_error(
                "wave index 'agent_ids' entries must be strings",
              ),
            )
        }
      }
    _ =>
      return Err(
        @types.ChoirError::config_error("wave index missing 'agent_ids' array"),
      )
  }
  let rescued : Map[String, String] = {}
  match obj.get("rescued") {
    Some(Object(r)) =>
      for k, v in r {
        match v {
          String(s) => rescued.set(k, s)
          _ =>
            return Err(
              @types.ChoirError::config_error(
                "wave index 'rescued' values must be strings",
              ),
            )
        }
      }
    None => ()
    _ =>
      return Err(
        @types.ChoirError::config_error(
          "wave index 'rescued' must be an object",
        ),
      )
  }
  let usage : Map[String, WaveUsage] = {}
  match obj.get("usage") {
    Some(Object(u)) =>
      for k, v in u {
        match parse_wave_usage(v) {
          Ok(wu) => usage.set(k, wu)
          Err(e) => return Err(e)
        }
      }
    None => ()
    _ =>
      return Err(
        @types.ChoirError::config_error("wave index 'usage' must be an object"),
      )
  }
  Ok({ wave_id, parent_branch, fork_ts_ms, agent_ids, rescued, usage })
}

///|
pub fn save_wave_index(
  project_dir : String,
  idx : WaveIndex,
) -> Result[Unit, @types.ChoirError] {
  let dir = wave_index_dir(project_dir)
  if !@sys.create_dir_all(dir) {
    return Err(@types.ChoirError::workspace_error("failed to create " + dir))
  }
  let path = wave_index_path(project_dir, idx.wave_id)
  let tmp_path = path +
    ".tmp." +
    @sys.get_pid().to_string() +
    "-" +
    @env.now().reinterpret_as_int64().to_string()
  let body = render_wave_index_json(idx)
  if !@sys.write_file_sync(tmp_path, body) {
    return Err(
      @types.ChoirError::workspace_error("failed to write " + tmp_path),
    )
  }
  if !@sys.rename_file_sync(tmp_path, path) {
    ignore(@sys.rm_rf(tmp_path))
    return Err(
      @types.ChoirError::workspace_error(
        "failed to rename " + tmp_path + " -> " + path,
      ),
    )
  }
  Ok(())
}

///|
pub fn load_wave_index(
  project_dir : String,
  wave_id : String,
) -> Result[WaveIndex, @types.ChoirError] {
  let path = wave_index_path(project_dir, wave_id)
  if !@sys.path_exists(path) {
    return Err(
      @types.ChoirError::workspace_error("wave index not found: " + path),
    )
  }
  let body = @sys.read_file(path)
  parse_wave_index_json(body)
}

///|
pub fn list_wave_ids(project_dir : String) -> Array[String] {
  let dir = wave_index_dir(project_dir)
  let out : Array[String] = []
  if !@sys.path_entry_exists(dir) {
    return out
  }
  for entry in @sys.list_dir(dir) {
    if entry.has_suffix(".json") {
      let stem = entry[0:entry.length() - 5].to_owned()
      out.push(stem)
    }
  }
  out
}

///|
/// Append an agent id if not already present. Idempotent — safe for
/// `depends_on` waves that add members over time, and for retry paths.
pub fn append_agent_id(
  project_dir : String,
  wave_id : String,
  agent_id : String,
) -> Result[Unit, @types.ChoirError] {
  match load_wave_index(project_dir, wave_id) {
    Ok(idx) => {
      for existing in idx.agent_ids {
        if existing == agent_id {
          return Ok(())
        }
      }
      idx.agent_ids.push(agent_id)
      save_wave_index(project_dir, idx)
    }
    Err(e) => Err(e)
  }
}

///|
/// Record a rescue: old_id was killed, new_id took its place. Both remain
/// in `agent_ids` (so their events are still collected in `choir log`), and
/// the `rescued` map records the mapping for display.
pub fn record_rescue(
  project_dir : String,
  wave_id : String,
  old_id : String,
  new_id : String,
) -> Result[Unit, @types.ChoirError] {
  match load_wave_index(project_dir, wave_id) {
    Ok(idx) => {
      idx.rescued.set(old_id, new_id)
      let mut has_new = false
      for existing in idx.agent_ids {
        if existing == new_id {
          has_new = true
          break
        }
      }
      if !has_new {
        idx.agent_ids.push(new_id)
      }
      save_wave_index(project_dir, idx)
    }
    Err(e) => Err(e)
  }
}

///|
/// Record self-reported usage for an agent. Overwrites on repeat call.
pub fn record_usage(
  project_dir : String,
  wave_id : String,
  agent_id : String,
  usage : WaveUsage,
) -> Result[Unit, @types.ChoirError] {
  match load_wave_index(project_dir, wave_id) {
    Ok(idx) => {
      idx.usage.set(agent_id, usage)
      save_wave_index(project_dir, idx)
    }
    Err(e) => Err(e)
  }
}

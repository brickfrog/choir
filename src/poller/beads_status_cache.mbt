///|
pub(all) struct BeadsStatusCounts {
  ready : Int
  in_progress : Int
  blocked : Int
  deferred : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for BeadsStatusCounts with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}

///|
fn beads_status_array_count(
  label : String,
  content : String,
) -> Result[Int, @types.ChoirError] {
  let json = @json.parse(content) catch {
    _ =>
      return Err(
        @types.ChoirError::validation_error(label + ": invalid beads JSON"),
      )
  }
  match json {
    Array(items) => Ok(items.length())
    _ =>
      Err(@types.ChoirError::validation_error(label + ": expected JSON array"))
  }
}

///|
pub fn parse_beads_status_counts_from_bd_json(
  ready_json : String,
  in_progress_json : String,
  blocked_json : String,
  deferred_json : String,
) -> Result[BeadsStatusCounts, @types.ChoirError] {
  let ready = match beads_status_array_count("bd ready --json", ready_json) {
    Ok(count) => count
    Err(e) => return Err(e)
  }
  let in_progress = match
    beads_status_array_count(
      "bd list --json --status in_progress", in_progress_json,
    ) {
    Ok(count) => count
    Err(e) => return Err(e)
  }
  let blocked = match
    beads_status_array_count("bd list --json --status blocked", blocked_json) {
    Ok(count) => count
    Err(e) => return Err(e)
  }
  let deferred = match
    beads_status_array_count("bd list --json --status deferred", deferred_json) {
    Ok(count) => count
    Err(e) => return Err(e)
  }
  Ok({ ready, in_progress, blocked, deferred })
}

///|
pub fn beads_status_cache_path(project_dir : String) -> String {
  project_dir + "/.choir/state/beads_status_cache.json"
}

///|
fn beads_status_cache_json(
  counts : BeadsStatusCounts,
  taken_at_unix_sec : Int64,
) -> Json {
  {
    "taken_at_unix_sec": taken_at_unix_sec.to_json(),
    "ready": counts.ready.to_json(),
    "in_progress": counts.in_progress.to_json(),
    "blocked": counts.blocked.to_json(),
    "deferred": counts.deferred.to_json(),
  }.to_json()
}

///|
pub fn write_beads_status_cache(
  project_dir : String,
  counts : BeadsStatusCounts,
  taken_at_unix_sec : Int64,
  write_file~ : (String, String) -> Bool,
) -> Bool {
  write_file(
    beads_status_cache_path(project_dir),
    beads_status_cache_json(counts, taken_at_unix_sec).stringify(indent=2) +
    "\n",
  )
}

///|
pub fn read_beads_status_cache(
  project_dir : String,
  read_file~ : (String) -> String,
) -> (BeadsStatusCounts, Int64)? {
  let content = read_file(beads_status_cache_path(project_dir))
    .trim()
    .to_owned()
  if content == "" {
    return None
  }
  let json = @json.parse(content) catch { _ => return None }
  guard json is Object(fields) else { return None }
  let taken_at = match @types.json_field_int64(fields, "taken_at_unix_sec") {
    Some(value) => value
    None => return None
  }
  let counts : BeadsStatusCounts = @json.from_json(json) catch {
    _ => return None
  }
  Some((counts, taken_at))
}

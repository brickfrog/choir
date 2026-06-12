///|
fn request_int64_arg(req : @types.Request, key : String) -> Int64? {
  match req.args.get_int(key) {
    Some(value) => Some(value.to_int64())
    None =>
      match req.args.get(key) {
        Some(raw) => {
          let trimmed = raw.trim().to_owned()
          let mut result = 0L
          let mut valid = trimmed != ""
          for c in trimmed {
            if c >= '0' && c <= '9' {
              result = result * 10L + (c.to_int() - '0'.to_int()).to_int64()
            } else {
              valid = false
            }
          }
          if valid {
            Some(result)
          } else {
            None
          }
        }
        None => None
      }
  }
}

///|
/// `tui_snapshot`: the canonical full-state read model plus the current
/// journal sequence number. Zero network I/O — the only effects are the
/// lazily refreshed bead cache (`bd` CLI, local Dolt db) and a once-per-
/// process local-git default-branch read.
pub async fn ServerState::handle_tui_snapshot_request(
  self : ServerState,
  req : @types.Request,
  capture : async (@workspace.Command) -> (Int, String),
  bd_capture : async (@workspace.Command) -> (Int, String),
) -> @types.Response {
  ignore(self.tool_registry.lookup(req.role, req.name)) catch {
    e => return @tools.tool_response_err_from_caught(e)
  }
  let now_ms = @env.now().reinterpret_as_int64()
  self.refresh_tui_beads_cache_if_stale(now_ms, bd_capture)
  let default_branch = self.tui_default_branch_cached(capture)
  let snapshot = self.build_tui_snapshot(now_ms, default_branch~)
  @types.Response::ok_values({ "snapshot": snapshot.to_json() })
}

///|
/// `tui_events_since(seq)`: all journal events with sequence > cursor as a
/// bounded batch, plus the latest seq. When the cursor predates the retained
/// journal the response says so (`stale: true`) and the client re-snapshots.
pub fn ServerState::handle_tui_events_since_request(
  self : ServerState,
  req : @types.Request,
) -> @types.Response {
  ignore(self.tool_registry.lookup(req.role, req.name)) catch {
    e => return @tools.tool_response_err_from_caught(e)
  }
  let cursor = match request_int64_arg(req, "seq") {
    Some(value) => value
    None =>
      return @types.Response::Err(
        "tui_events_since requires a numeric seq cursor",
      )
  }
  let max = match request_int64_arg(req, "max") {
    Some(value) if value > 0L && value < tui_events_since_max_batch.to_int64() =>
      value.to_int()
    _ => tui_events_since_max_batch
  }
  match self.journal.events_since(cursor, max~) {
    TuiEventsSinceResult::Events(envelopes) => {
      let events : Array[Json] = []
      for envelope in envelopes {
        events.push(envelope.to_json())
      }
      @types.Response::ok_values({
        "events": events.to_json(),
        "latest_seq": self.journal.latest_seq().to_json(),
        "stale": false.to_json(),
      })
    }
    TuiEventsSinceResult::StaleCursor =>
      @types.Response::ok_values({
        "events": ([] : Array[Json]).to_json(),
        "latest_seq": self.journal.latest_seq().to_json(),
        "stale": true.to_json(),
      })
  }
}

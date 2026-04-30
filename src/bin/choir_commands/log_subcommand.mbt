///|
pub(all) struct Event {
  ts_ms : Int64
  agent_id : String
  type_ : String
  data : Json
}

///|
pub fn parse_event_jsonl_line(line : String) -> Event? {
  let trimmed = line.trim().to_owned()
  if trimmed == "" {
    return None
  }
  let parsed = @json.parse(trimmed) catch { _ => return None }
  guard parsed is Object(root) else { return None }
  let ts_ms = match @types.json_field_int64(root, "ts_ms") {
    Some(value) => value
    None =>
      match @types.json_field_int64(root, "ts") {
        Some(value) => value * 1000L
        None => return None
      }
  }
  let agent_id = match @types.json_field_string(root, "agent_id") {
    Some(value) => value
    None => return None
  }
  let type_ = match @types.json_field_string(root, "type") {
    Some(value) => value
    None => return None
  }
  let data = match root.get("data") {
    Some(value) => value
    None => {
      let empty : Map[String, Json] = {}
      empty.to_json()
    }
  }
  Some({ ts_ms, agent_id, type_, data })
}

///|
pub fn read_agent_events(
  project_dir : String,
  agent_id : String,
) -> Array[Event] {
  let path = project_dir +
    "/.choir/events/" +
    @types.sanitize_agent_id(agent_id) +
    ".jsonl"
  let out : Array[Event] = []
  let content = @sys.read_file(path)
  if content == "" {
    return out
  }
  for line in content.split("\n") {
    match parse_event_jsonl_line(line.to_owned()) {
      Some(event) => out.push(event)
      None => ()
    }
  }
  out
}

///|
fn event_compare(left : Event, right : Event) -> Int {
  let ts_cmp = left.ts_ms.compare(right.ts_ms)
  if ts_cmp != 0 {
    ts_cmp
  } else {
    left.agent_id.compare(right.agent_id)
  }
}

///|
pub fn interleave_events(all : Array[Event]) -> Array[Event] {
  let sorted : Array[Event] = []
  for event in all {
    let mut inserted = false
    for i = 0; i < sorted.length(); i = i + 1 {
      if event_compare(event, sorted[i]) < 0 {
        sorted.insert(i, event)
        inserted = true
        break
      }
    }
    if !inserted {
      sorted.push(event)
    }
  }
  sorted
}

///|
fn utc_datetime_from_ms(ms : Int64) -> @tempo.DateTime {
  @tempo.DateTime::from_unix_seconds(ms / 1000L)
}

///|
fn utc_datetime_text(ms : Int64) -> String {
  let formatted = utc_datetime_from_ms(ms).format()
  let without_z = if formatted.has_suffix("Z") {
    formatted[0:formatted.length() - 1].to_owned()
  } else {
    formatted
  }
  without_z.replace(old="T", new=" ")
}

///|
fn utc_time_text(ms : Int64) -> String {
  utc_datetime_from_ms(ms).time.format()
}

///|
fn last_dot_segment(s : String) -> String {
  let parts = s.split(".")
  let mut last = s
  for part in parts {
    last = part.to_owned()
  }
  last
}

///|
fn event_summary(event : Event) -> String {
  match event.data {
    Object(fields) =>
      if event.type_ == "lifecycle.transition" {
        @types.json_field_string(fields, "to").unwrap_or("?")
      } else if event.type_ == "evidence.ci_observed" {
        "ci_observed(" +
        @types.json_field_string(fields, "status").unwrap_or("?") +
        ")"
      } else if event.type_ == "evidence.review_observed" {
        "review_observed(" +
        @types.json_field_string(fields, "state").unwrap_or("?") +
        ")"
      } else {
        let (_, subtype) = event_category_and_subtype(event.type_)
        if subtype == "" {
          event.data.stringify()
        } else {
          subtype + " " + event.data.stringify()
        }
      }
    _ => event.data.stringify()
  }
}

///|
fn event_category_and_subtype(type_ : String) -> (String, String) {
  match type_.split_once(".") {
    Some((category, subtype)) => (category.to_owned(), subtype.to_owned())
    None => (type_, "")
  }
}

///|
fn event_line_label(event : Event) -> String {
  let (category, _) = event_category_and_subtype(event.type_)
  category
}

///|
pub fn format_log_plain(
  idx : @tools.WaveIndex,
  events : Array[Event],
) -> String {
  let out = StringBuilder::new()
  out.write_string(
    "wave " +
    idx.wave_id +
    " (" +
    idx.parent_branch +
    ", forked " +
    utc_datetime_text(idx.fork_ts_ms) +
    " UTC)\n",
  )
  out.write_string("members: ")
  let members : Array[String] = []
  for agent_id in idx.agent_ids {
    let agent_type = match idx.usage.get(agent_id) {
      Some(u) => u.agent_type.to_wire_string()
      None => "<unknown>"
    }
    members.push(last_dot_segment(agent_id) + " (" + agent_type + ")")
  }
  out.write_string(members.join(", "))
  out.write_string("\n")
  if events.length() > 0 {
    out.write_string("\n")
  }
  for event in events {
    out.write_string(utc_time_text(event.ts_ms))
    out.write_string("  [")
    out.write_string(last_dot_segment(event.agent_id))
    out.write_string("]  ")
    out.write_string(event_line_label(event))
    out.write_string(": ")
    out.write_string(event_summary(event))
    out.write_string("\n")
  }
  out.to_string()
}

///|
fn event_to_json(event : Event) -> Json {
  let obj : Map[String, Json] = {
    "ts_ms": Json::number(event.ts_ms.to_double()),
    "agent_id": event.agent_id.to_json(),
    "type": event.type_.to_json(),
    "data": event.data,
  }
  obj.to_json()
}

///|
pub fn format_log_json(
  _idx : @tools.WaveIndex,
  events : Array[Event],
) -> String {
  let out = StringBuilder::new()
  for event in events {
    out.write_string(event_to_json(event).stringify())
    out.write_string("\n")
  }
  out.to_string()
}

///|
fn log_help() -> Unit {
  @sys.write_stdout(
    (
      #|Usage: choir log --wave <wave_id> [--format plain|json]
      #|
      #|Render timeline of all events across agents in the wave.
      #|--format defaults to plain.
      #|
      #|Example:
      #|  choir log --wave wv-demo
      #|
    ),
  )
}

///|
fn log_subcommand_error(msg : String) -> Unit {
  @sys.write_stderr("error: " + msg + "\n")
  @sys.exit(1)
}

///|
pub fn log_subcommand_run() -> Unit {
  let args = @env.args()
  let mut wave_id : String? = None
  let mut format = "plain"
  let mut i = 2
  while i < args.length() {
    let arg = args[i]
    if arg == "--help" || arg == "-h" {
      log_help()
      return
    } else if arg == "--wave" {
      if i + 1 >= args.length() {
        log_subcommand_error("missing value for --wave")
        return
      }
      wave_id = Some(args[i + 1])
      i = i + 2
      continue
    } else if arg == "--format" {
      if i + 1 >= args.length() {
        log_subcommand_error("missing value for --format")
        return
      }
      let value = args[i + 1]
      if value != "plain" && value != "json" {
        log_subcommand_error("invalid --format: " + value)
        return
      }
      format = value
      i = i + 2
      continue
    } else {
      log_subcommand_error("unknown argument: " + arg)
      return
    }
    i = i + 1
  }
  let id = match wave_id {
    Some(id) => id
    None => {
      log_subcommand_error("missing required --wave <wave_id>")
      return
    }
  }
  let project_dir = @env.current_dir().unwrap_or(".")
  let idx = match @tools.load_wave_index(project_dir, id) {
    Ok(idx) => idx
    Err(e) => {
      @sys.write_stderr("error: " + e.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  let all : Array[Event] = []
  for agent_id in idx.agent_ids {
    for event in read_agent_events(project_dir, agent_id) {
      all.push(event)
    }
  }
  let events = interleave_events(all)
  let rendered = if format == "json" {
    format_log_json(idx, events)
  } else {
    format_log_plain(idx, events)
  }
  @sys.write_stdout(rendered)
}

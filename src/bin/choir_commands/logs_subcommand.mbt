///|
pub(all) enum LogLevel {
  Trace
  Debug
  Info
  Warn
  Error
} derive(Debug, Eq)

///|
pub(all) enum LogsSource {
  Merged
  Serve
  Delivery
  Events(String)
  Wave(String)
} derive(Debug, Eq)

///|
pub(all) struct LogsCliOptions {
  source : LogsSource
  tail_n : Int
  tail_explicit : Bool
  follow : Bool
  grep : String?
  level : LogLevel?
  help : Bool
} derive(Debug, Eq)

///|
fn default_logs_options() -> LogsCliOptions {
  {
    source: LogsSource::Merged,
    tail_n: 100,
    tail_explicit: false,
    follow: false,
    grep: None,
    level: None,
    help: false,
  }
}

///|
pub fn parse_log_level(raw : String) -> LogLevel? {
  match raw.trim().to_lower() {
    "trace" => Some(LogLevel::Trace)
    "debug" => Some(LogLevel::Debug)
    "info" => Some(LogLevel::Info)
    "warn" | "warning" => Some(LogLevel::Warn)
    "error" => Some(LogLevel::Error)
    _ => None
  }
}

///|
fn log_level_rank(level : LogLevel) -> Int {
  match level {
    Trace => 0
    Debug => 1
    Info => 2
    Warn => 3
    Error => 4
  }
}

///|
fn parse_positive_int(
  raw : String,
  flag : String,
) -> Result[Int, @types.ChoirError] {
  let value = @string.parse_int(raw.trim().to_owned()) catch {
    _ =>
      return Err(
        @types.ChoirError::validation_error(flag + " must be a number"),
      )
  }
  if value <= 0 {
    return Err(@types.ChoirError::validation_error(flag + " must be positive"))
  }
  Ok(value)
}

///|
pub fn parse_logs_cli_args(
  args : Array[String],
) -> Result[LogsCliOptions, @types.ChoirError] {
  let mut opts = default_logs_options()
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--help" | "-h" => {
        opts = { ..opts, help: true }
        i = i + 1
      }
      "--follow" | "-f" => {
        opts = { ..opts, follow: true }
        i = i + 1
      }
      "--tail" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--tail requires a number"),
          )
        }
        let n = match parse_positive_int(args[i + 1], "--tail") {
          Ok(n) => n
          Err(e) => return Err(e)
        }
        opts = { ..opts, tail_n: n, tail_explicit: true }
        i = i + 2
      }
      "--grep" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--grep requires a pattern"),
          )
        }
        opts = { ..opts, grep: Some(args[i + 1]) }
        i = i + 2
      }
      "--level" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--level requires a level"),
          )
        }
        match parse_log_level(args[i + 1]) {
          Some(level) => opts = { ..opts, level: Some(level) }
          None =>
            return Err(
              @types.ChoirError::validation_error(
                "unknown log level: " + args[i + 1],
              ),
            )
        }
        i = i + 2
      }
      "--source" => {
        if i + 1 >= args.length() {
          return Err(
            @types.ChoirError::validation_error("--source requires a value"),
          )
        }
        match args[i + 1] {
          "serve" => {
            opts = { ..opts, source: LogsSource::Serve }
            i = i + 2
          }
          "delivery" => {
            opts = { ..opts, source: LogsSource::Delivery }
            i = i + 2
          }
          "events" => {
            if i + 2 >= args.length() {
              return Err(
                @types.ChoirError::validation_error(
                  "--source events requires an agent",
                ),
              )
            }
            opts = { ..opts, source: LogsSource::Events(args[i + 2]) }
            i = i + 3
          }
          "wave" => {
            if i + 2 >= args.length() {
              return Err(
                @types.ChoirError::validation_error(
                  "--source wave requires a wave id",
                ),
              )
            }
            opts = { ..opts, source: LogsSource::Wave(args[i + 2]) }
            i = i + 3
          }
          other =>
            return Err(
              @types.ChoirError::validation_error(
                "unknown logs source: " + other,
              ),
            )
        }
      }
      other =>
        return Err(
          @types.ChoirError::validation_error("unknown logs flag: " + other),
        )
    }
  }
  Ok(opts)
}

///|
fn is_digit_at(s : String, i : Int) -> Bool {
  i >= 0 && i < s.length() && s[i] >= '0' && s[i] <= '9'
}

///|
fn parse_bounded_int(raw : String, min : Int, max : Int) -> Bool {
  let value = @string.parse_int(raw) catch { _ => return false }
  value >= min && value <= max
}

///|
fn normalize_time_at(line : String, start : Int) -> String? {
  if line.length() < start + 8 {
    return None
  }
  if !is_digit_at(line, start) ||
    !is_digit_at(line, start + 1) ||
    line[start + 2] != ':' ||
    !is_digit_at(line, start + 3) ||
    !is_digit_at(line, start + 4) ||
    line[start + 5] != ':' ||
    !is_digit_at(line, start + 6) ||
    !is_digit_at(line, start + 7) {
    return None
  }
  let hour = line[start:start + 2].to_owned()
  let minute = line[start + 3:start + 5].to_owned()
  let second = line[start + 6:start + 8].to_owned()
  if !parse_bounded_int(hour, 0, 23) ||
    !parse_bounded_int(minute, 0, 59) ||
    !parse_bounded_int(second, 0, 59) {
    return None
  }
  let mut millis = "000"
  let dot = start + 8
  if dot < line.length() && line[dot] == '.' {
    let mut end = dot + 1
    while end < line.length() && end < dot + 4 && is_digit_at(line, end) {
      end = end + 1
    }
    if end == dot + 1 {
      return None
    }
    millis = line[dot + 1:end].to_owned()
    if millis.length() == 1 {
      millis = millis + "00"
    } else if millis.length() == 2 {
      millis = millis + "0"
    }
  }
  Some(hour + ":" + minute + ":" + second + "." + millis)
}

///|
fn has_iso_date_prefix(line : String) -> Bool {
  line.length() >= 19 &&
  is_digit_at(line, 0) &&
  is_digit_at(line, 1) &&
  is_digit_at(line, 2) &&
  is_digit_at(line, 3) &&
  line[4] == '-' &&
  is_digit_at(line, 5) &&
  is_digit_at(line, 6) &&
  line[7] == '-' &&
  is_digit_at(line, 8) &&
  is_digit_at(line, 9) &&
  (line[10] == 'T' || line[10] == ' ')
}

///|
/// Sortable timestamp key for a log line. Lines with an ISO date prefix
/// (delivery.log) yield "YYYY-MM-DDTHH:MM:SS.mmm" so ordering survives across
/// dates and restarts; bare serve.log lines yield "HH:MM:SS.mmm".
pub fn line_timestamp(line : String) -> String? {
  if has_iso_date_prefix(line) {
    match normalize_time_at(line, 11) {
      Some(ts) => return Some(line[0:10].to_owned() + "T" + ts)
      None => ()
    }
  }
  normalize_time_at(line, 0)
}

///|
fn timestamp_is_dated(ts : String) -> Bool {
  ts.length() > 12 && ts[10] == 'T'
}

///|
fn timestamp_time_only(ts : String) -> String {
  if timestamp_is_dated(ts) {
    ts[11:].to_owned()
  } else {
    ts
  }
}

///|
pub fn line_level(line : String) -> LogLevel? {
  // Only serve.log lines carry a level field ("HH:MM:SS.mmm | LEVEL | choir — …").
  // delivery.log lines start with an ISO date prefix and have no level — they
  // must pass any --level filter rather than be matched on stray "| INFO |" text.
  if has_iso_date_prefix(line) {
    return None
  }
  if normalize_time_at(line, 0) is None {
    return None
  }
  let parts : Array[String] = []
  for part in line.split("|") {
    parts.push(part.to_owned())
  }
  if parts.length() < 3 {
    return None
  }
  parse_log_level(parts[1])
}

///|
fn compare_log_line_timestamp(left : String, right : String) -> Int {
  match (line_timestamp(left), line_timestamp(right)) {
    (Some(a), Some(b)) =>
      if timestamp_is_dated(a) == timestamp_is_dated(b) {
        a.compare(b)
      } else {
        // One side has a date, the other does not — fall back to time-of-day.
        timestamp_time_only(a).compare(timestamp_time_only(b))
      }
    (Some(_), None) => -1
    (None, Some(_)) => 1
    (None, None) => 0
  }
}

///|
pub fn merge_log_lines(
  serve_lines : Array[String],
  delivery_lines : Array[String],
) -> Array[String] {
  let sorted : Array[String] = []
  for line in serve_lines {
    let mut inserted = false
    for i = 0; i < sorted.length(); i = i + 1 {
      if compare_log_line_timestamp(line, sorted[i]) < 0 {
        sorted.insert(i, line)
        inserted = true
        break
      }
    }
    if !inserted {
      sorted.push(line)
    }
  }
  for line in delivery_lines {
    let mut inserted = false
    for i = 0; i < sorted.length(); i = i + 1 {
      if compare_log_line_timestamp(line, sorted[i]) < 0 {
        sorted.insert(i, line)
        inserted = true
        break
      }
    }
    if !inserted {
      sorted.push(line)
    }
  }
  sorted
}

///|
fn passes_level_filter(line : String, min_level : LogLevel?) -> Bool {
  match min_level {
    None => true
    Some(minimum) =>
      match line_level(line) {
        Some(level) => log_level_rank(level) >= log_level_rank(minimum)
        None => true
      }
  }
}

///|
pub fn tail_n(lines : Array[String], n : Int) -> Array[String] {
  if n <= 0 {
    return []
  }
  let start = if lines.length() > n { lines.length() - n } else { 0 }
  let out : Array[String] = []
  for i = start; i < lines.length(); i = i + 1 {
    out.push(lines[i])
  }
  out
}

///|
fn apply_filters_with_tail(
  lines : Array[String],
  opts : LogsCliOptions,
  include_tail : Bool,
) -> Array[String] {
  let filtered : Array[String] = []
  for line in lines {
    if !passes_level_filter(line, opts.level) {
      continue
    }
    match opts.grep {
      Some(pattern) => if !line.contains(pattern) { continue }
      None => ()
    }
    filtered.push(line)
  }
  if include_tail {
    tail_n(filtered, opts.tail_n)
  } else {
    filtered
  }
}

///|
pub fn apply_filters(
  lines : Array[String],
  opts : LogsCliOptions,
) -> Array[String] {
  apply_filters_with_tail(lines, opts, true)
}

///|
fn logs_project_path(project_dir : String, rel : String) -> String {
  if project_dir == "" || project_dir == "." {
    rel
  } else {
    project_dir + "/" + rel
  }
}

///|
fn split_log_lines(content : String) -> Array[String] {
  let out : Array[String] = []
  let raw : Array[String] = []
  for part in content.split("\n") {
    raw.push(part.to_owned())
  }
  for i = 0; i < raw.length(); i = i + 1 {
    let line = raw[i]
    if !(i == raw.length() - 1 && line == "") {
      out.push(line)
    }
  }
  out
}

///|
fn read_log_lines(project_dir : String, rel : String) -> Array[String] {
  split_log_lines(@sys.read_file(logs_project_path(project_dir, rel)))
}

///|
/// A caller-supplied `.jsonl` name is only safe to join under `.choir/state/events`
/// if it has no path separators or `..` segments — otherwise it could escape
/// the events directory.
fn safe_jsonl_filename(name : String) -> String? {
  if name.contains("/") || name.contains("\\") || name.contains("..") {
    None
  } else {
    Some(name)
  }
}

///|
fn event_log_path(project_dir : String, agent_arg : String) -> String? {
  let events_dir = logs_project_path(project_dir, ".choir/state/events")
  let sanitized = @types.sanitize_agent_id(agent_arg)
  let candidates : Array[String] = []
  if agent_arg.has_suffix(".jsonl") {
    match safe_jsonl_filename(agent_arg) {
      Some(name) => candidates.push(name)
      None => ()
    }
  }
  candidates.push(sanitized + ".jsonl")
  candidates.push("agent-" + sanitized + ".jsonl")
  for candidate in candidates {
    let path = events_dir + "/" + candidate
    if @sys.path_entry_exists(path) {
      return Some(path)
    }
  }
  let entries = @sys.list_dir(events_dir)
  entries.sort_by(fn(a, b) { a.compare(b) })
  for entry in entries {
    if entry.has_suffix(".jsonl") &&
      (
        entry == agent_arg ||
        entry == sanitized ||
        entry == sanitized + ".jsonl" ||
        entry == "agent-" + sanitized + ".jsonl" ||
        entry.contains(sanitized)
      ) {
      return Some(events_dir + "/" + entry)
    }
  }
  None
}

///|
fn event_follow_candidate_paths(
  project_dir : String,
  agent_arg : String,
) -> Array[String] {
  let events_dir = logs_project_path(project_dir, ".choir/state/events")
  let sanitized = @types.sanitize_agent_id(agent_arg)
  let candidates : Array[String] = []
  if agent_arg.has_suffix(".jsonl") {
    match safe_jsonl_filename(agent_arg) {
      Some(name) => candidates.push(events_dir + "/" + name)
      None => ()
    }
  }
  candidates.push(events_dir + "/" + sanitized + ".jsonl")
  candidates.push(events_dir + "/agent-" + sanitized + ".jsonl")
  candidates
}

///|
fn read_events_source_lines(
  project_dir : String,
  agent_arg : String,
) -> Array[String] {
  let path = match event_log_path(project_dir, agent_arg) {
    Some(path) => path
    None => return []
  }
  let events : Array[Event] = []
  for line in split_log_lines(@sys.read_file(path)) {
    match parse_event_jsonl_line(line) {
      Some(event) => events.push(event)
      None => ()
    }
  }
  let idx = @tools.WaveIndex::new(
    "events-" + @types.sanitize_agent_id(agent_arg),
    "events",
    0L,
    [agent_arg],
  )
  split_log_lines(format_log_json(idx, interleave_events(events)))
}

///|
fn read_wave_source_lines(
  project_dir : String,
  wave_id : String,
) -> Result[Array[String], @types.ChoirError] {
  let idx = match @tools.load_wave_index(project_dir, wave_id) {
    Ok(idx) => idx
    Err(e) => return Err(e)
  }
  let all : Array[Event] = []
  for agent_id in idx.agent_ids {
    for event in read_agent_events(project_dir, agent_id) {
      all.push(event)
    }
  }
  Ok(split_log_lines(format_log_plain(idx, interleave_events(all))))
}

///|
fn read_source_lines(
  project_dir : String,
  source : LogsSource,
) -> Result[Array[String], @types.ChoirError] {
  match source {
    Merged =>
      Ok(
        merge_log_lines(
          read_log_lines(project_dir, ".choir/logs/serve.log"),
          read_log_lines(project_dir, ".choir/logs/delivery.log"),
        ),
      )
    Serve => Ok(read_log_lines(project_dir, ".choir/logs/serve.log"))
    Delivery => Ok(read_log_lines(project_dir, ".choir/logs/delivery.log"))
    Events(agent_arg) => Ok(read_events_source_lines(project_dir, agent_arg))
    Wave(wave_id) => read_wave_source_lines(project_dir, wave_id)
  }
}

///|
fn source_follow_paths(
  project_dir : String,
  source : LogsSource,
) -> Result[Array[String], @types.ChoirError] {
  match source {
    Merged =>
      Ok([
        logs_project_path(project_dir, ".choir/logs/serve.log"),
        logs_project_path(project_dir, ".choir/logs/delivery.log"),
      ])
    Serve => Ok([logs_project_path(project_dir, ".choir/logs/serve.log")])
    Delivery => Ok([logs_project_path(project_dir, ".choir/logs/delivery.log")])
    Events(agent_arg) =>
      match event_log_path(project_dir, agent_arg) {
        Some(path) => Ok([path])
        None => Ok(event_follow_candidate_paths(project_dir, agent_arg))
      }
    Wave(wave_id) => {
      let idx = match @tools.load_wave_index(project_dir, wave_id) {
        Ok(idx) => idx
        Err(e) => return Err(e)
      }
      let paths : Array[String] = []
      for agent_id in idx.agent_ids {
        for path in event_follow_candidate_paths(project_dir, agent_id) {
          paths.push(path)
        }
      }
      Ok(paths)
    }
  }
}

///|
fn file_size_snapshot(paths : Array[String]) -> Array[Int] {
  let sizes : Array[Int] = []
  for path in paths {
    sizes.push(@sys.file_size(path))
  }
  sizes
}

///|
fn file_size_snapshot_changed(left : Array[Int], right : Array[Int]) -> Bool {
  if left.length() != right.length() {
    return true
  }
  for i = 0; i < left.length(); i = i + 1 {
    if left[i] != right[i] {
      return true
    }
  }
  false
}

///|
fn render_lines(lines : Array[String]) -> String {
  let out = StringBuilder::new()
  for line in lines {
    out.write_string(line)
    out.write_string("\n")
  }
  out.to_string()
}

///|

///|
/// The default ~100-line tail applies to the file sources (merged/serve/
/// delivery). The events/wave sources mirror `choir log --wave` formatting,
/// which shows the whole timeline — only an explicit `--tail N` truncates them.
fn source_tails_by_default(source : LogsSource) -> Bool {
  match source {
    Merged | Serve | Delivery => true
    Events(_) | Wave(_) => false
  }
}

///|
fn render_logs(
  project_dir : String,
  opts : LogsCliOptions,
  include_tail : Bool,
) -> Result[String, @types.ChoirError] {
  let lines = match read_source_lines(project_dir, opts.source) {
    Ok(lines) => lines
    Err(e) => return Err(e)
  }
  let do_tail = include_tail &&
    (opts.tail_explicit || source_tails_by_default(opts.source))
  Ok(render_lines(apply_filters_with_tail(lines, opts, do_tail)))
}

///|
fn logs_help() -> String {
  (
    #|usage: choir logs [--source serve|delivery|events <agent>|wave <id>] [--tail N] [--follow|-f] [--grep PATTERN] [--level trace|debug|info|warn|error]
    #|
    #|Default source is the merged serve and delivery logs. --tail defaults to 100.
    #|
    #|Examples:
    #|  choir logs --tail 50
    #|  choir logs --source serve --grep poller
    #|  choir logs --level warn
    #|  choir logs --source wave wv-demo
  )
}

///|
fn follow_logs(project_dir : String, opts : LogsCliOptions) -> Unit {
  let paths = match source_follow_paths(project_dir, opts.source) {
    Ok(paths) => paths
    Err(e) => {
      @sys.write_stderr("choir logs: " + e.message() + "\n")
      return
    }
  }
  let mut previous_sizes = file_size_snapshot(paths)
  let mut previous = match render_logs(project_dir, opts, false) {
    Ok(rendered) => rendered
    Err(e) => {
      @sys.write_stderr("choir logs: " + e.message() + "\n")
      return
    }
  }
  while true {
    @sys.sleep_milliseconds(750)
    let next_sizes = file_size_snapshot(paths)
    if !file_size_snapshot_changed(previous_sizes, next_sizes) {
      continue
    }
    previous_sizes = next_sizes
    match render_logs(project_dir, opts, false) {
      Ok(next) =>
        if next.length() > previous.length() && next.has_prefix(previous) {
          @sys.write_stdout(next[previous.length():].to_owned())
          previous = next
        } else if next != previous {
          previous = next
        }
      Err(e) => {
        @sys.write_stderr("choir logs: " + e.message() + "\n")
        return
      }
    }
  }
}

///|
pub fn logs_subcommand_run() -> Unit {
  let opts = match parse_logs_cli_args(@env.args()) {
    Ok(opts) => opts
    Err(e) => {
      @sys.write_stderr("choir logs: " + e.message() + "\n")
      @sys.write_stderr(logs_help())
      @sys.exit(1)
      return
    }
  }
  if opts.help {
    @sys.write_stdout(logs_help())
    return
  }
  let project_dir = @env.current_dir().unwrap_or(".")
  match render_logs(project_dir, opts, true) {
    Ok(rendered) => @sys.write_stdout(rendered)
    Err(e) => {
      @sys.write_stderr("choir logs: " + e.message() + "\n")
      @sys.exit(1)
      return
    }
  }
  if opts.follow {
    follow_logs(project_dir, opts)
  }
}

///|
test "safe_jsonl_filename rejects path traversal" {
  @debug.assert_eq(safe_jsonl_filename("agent-a.jsonl"), Some("agent-a.jsonl"))
  @debug.assert_eq(safe_jsonl_filename("../secrets.jsonl"), None)
  @debug.assert_eq(safe_jsonl_filename("sub/dir.jsonl"), None)
  @debug.assert_eq(safe_jsonl_filename("..\\evil.jsonl"), None)
}

///|
test "source_tails_by_default only for file sources" {
  assert_true(source_tails_by_default(LogsSource::Merged))
  assert_true(source_tails_by_default(LogsSource::Serve))
  assert_true(source_tails_by_default(LogsSource::Delivery))
  assert_false(source_tails_by_default(LogsSource::Events("a")))
  assert_false(source_tails_by_default(LogsSource::Wave("wv-x")))
}

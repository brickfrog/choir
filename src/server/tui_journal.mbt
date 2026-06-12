///|
/// Relative path of the TUI event journal: an append-only JSONL file written
/// by the daemon as a second sink next to the logger. Rotated like serve.log
/// (boot-time rotation to `<path>.1` past the size cap).
pub let tui_journal_rel_path : String = ".choir/events.journal.jsonl"

///|
/// Hot-tail ring capacity. The ring serves `tui_events_since` without
/// touching disk; cursors older than the ring fall back to the journal file.
pub let tui_journal_default_ring_cap : Int = 4096

///|
/// Bounded batch size for `tui_events_since` responses.
pub let tui_events_since_max_batch : Int = 500

///|
/// Journal-backed event ring. Sequence numbers are monotonically increasing
/// and survive daemon restart (recovered from the journal tail at open), so
/// client cursors stay gap-free across ring overflow and restarts.
pub(all) struct TuiJournal {
  path : String
  ring_cap : Int
  mut next_seq : Int64
  mut ring : Array[@types.TuiEventEnvelope]
  append_file : (String, String) -> Bool
  read_file : (String) -> String
  mut last_event_ts_ms : Int64?
  mut append_failure_warned : Bool
}

///|
fn tui_journal_path(project_dir : String) -> String {
  server_log_project_path(project_dir, tui_journal_rel_path)
}

///|
fn tui_journal_last_envelope_in_content(
  content : String,
) -> @types.TuiEventEnvelope? {
  let mut last : @types.TuiEventEnvelope? = None
  for raw_line in content.split("\n") {
    let line = raw_line.to_owned()
    if line.trim() == "" {
      continue
    }
    match @types.parse_tui_event_envelope_line(line) {
      Ok(envelope) => last = Some(envelope)
      Err(_) => ()
    }
  }
  last
}

///|
/// Open (or create) the journal for `project_dir`. Rotates an oversized
/// journal to `<path>.1` first (same policy as serve.log), then recovers the
/// next sequence number from the retained journal tail so restarts never
/// reissue a sequence number.
pub fn TuiJournal::open(
  project_dir : String,
  append_file? : (String, String) -> Bool = @sys.append_file_sync,
  read_file? : (String) -> String = @sys.read_file,
  file_size? : (String) -> Int = @sys.file_size,
  rename_file? : (String, String) -> Bool = @sys.rename_file_sync,
  ring_cap? : Int = tui_journal_default_ring_cap,
) -> TuiJournal {
  ignore(
    serve_rotate_log_if_large(
      project_dir,
      tui_journal_rel_path,
      file_size,
      rename_file,
    ),
  )
  let path = tui_journal_path(project_dir)
  let mut recovered : @types.TuiEventEnvelope? = tui_journal_last_envelope_in_content(
    read_file(path),
  )
  if recovered is None {
    recovered = tui_journal_last_envelope_in_content(read_file(path + ".1"))
  }
  let (next_seq, last_event_ts_ms) = match recovered {
    Some(envelope) => (envelope.seq + 1L, Some(envelope.ts_ms))
    None => (1L, None)
  }
  {
    path,
    ring_cap: if ring_cap <= 0 {
      1
    } else {
      ring_cap
    },
    next_seq,
    ring: [],
    append_file,
    read_file,
    last_event_ts_ms,
    append_failure_warned: false,
  }
}

///|
pub fn TuiJournal::latest_seq(self : TuiJournal) -> Int64 {
  self.next_seq - 1L
}

///|
/// Age of the most recent journal event in seconds, or `None` when no event
/// has ever been observed (renders as the red unknown marker in vitals).
pub fn TuiJournal::last_event_age_sec(
  self : TuiJournal,
  now_ms : Int64,
) -> Int64? {
  match self.last_event_ts_ms {
    Some(ts_ms) => Some(@types.non_negative_i64((now_ms - ts_ms) / 1000L))
    None => None
  }
}

///|
fn TuiJournal::enforce_ring_cap(self : TuiJournal) -> Unit {
  if self.ring.length() < self.ring_cap * 2 {
    return
  }
  let kept : Array[@types.TuiEventEnvelope] = []
  for i = self.ring.length() - self.ring_cap; i < self.ring.length(); i = i + 1 {
    kept.push(self.ring[i])
  }
  self.ring = kept
}

///|
/// Append one event: assigns the next sequence number, stamps the timestamp,
/// pushes onto the hot ring, and appends a JSONL line to the journal file.
/// A failed file append keeps the in-memory event (and warns once) so the
/// hot path never raises.
pub fn TuiJournal::emit(
  self : TuiJournal,
  event : @types.TuiEvent,
  now_ms : Int64,
) -> Int64 {
  let seq = self.next_seq
  self.next_seq = seq + 1L
  let envelope : @types.TuiEventEnvelope = { seq, ts_ms: now_ms, event }
  self.ring.push(envelope)
  self.enforce_ring_cap()
  self.last_event_ts_ms = Some(now_ms)
  if !(self.append_file)(self.path, envelope.to_jsonl_line()) &&
    !self.append_failure_warned {
    self.append_failure_warned = true
    @moontrace.warn("tui journal append failed; ring continues in-memory", fields=[
      @moontrace.field("path", self.path),
      @moontrace.field("seq", seq),
    ])
  }
  seq
}

///|
/// Result of a cursored read. `StaleCursor` means the cursor predates the
/// retained journal (rotation discarded the gap); the client must
/// re-snapshot.
pub(all) enum TuiEventsSinceResult {
  Events(Array[@types.TuiEventEnvelope])
  StaleCursor
} derive(Debug, Eq)

///|
fn TuiJournal::ring_first_seq(self : TuiJournal) -> Int64? {
  if self.ring.length() == 0 {
    None
  } else {
    Some(self.ring[0].seq)
  }
}

///|
fn tui_journal_collect_since(
  content : String,
  cursor : Int64,
  max : Int,
  out : Array[@types.TuiEventEnvelope],
  first_retained : Ref[Int64?],
) -> Unit {
  for raw_line in content.split("\n") {
    let line = raw_line.to_owned()
    if line.trim() == "" {
      continue
    }
    match @types.parse_tui_event_envelope_line(line) {
      Ok(envelope) => {
        if first_retained.val is None {
          first_retained.val = Some(envelope.seq)
        }
        if envelope.seq > cursor && out.length() < max {
          out.push(envelope)
        }
      }
      Err(_) => ()
    }
  }
}

///|
/// All events with sequence > `cursor`, bounded to `max` per call, oldest
/// first. Served from the ring when it covers the cursor, falling back to
/// the journal file (including the rotated `.1` predecessor) otherwise.
pub fn TuiJournal::events_since(
  self : TuiJournal,
  cursor : Int64,
  max? : Int = tui_events_since_max_batch,
) -> TuiEventsSinceResult {
  let max = if max <= 0 { 1 } else { max }
  if cursor >= self.latest_seq() {
    return Events([])
  }
  match self.ring_first_seq() {
    Some(first) if cursor + 1L >= first => {
      let out : Array[@types.TuiEventEnvelope] = []
      for envelope in self.ring {
        if envelope.seq > cursor && out.length() < max {
          out.push(envelope)
        }
      }
      return Events(out)
    }
    _ => ()
  }
  // Cursor predates the ring (or the ring is empty after restart): replay
  // from the journal file. The rotated predecessor is consulted first so a
  // cursor that lands inside `.1` still drains gap-free.
  let out : Array[@types.TuiEventEnvelope] = []
  let first_retained : Ref[Int64?] = @ref.new(None)
  tui_journal_collect_since(
    (self.read_file)(self.path + ".1"),
    cursor,
    max,
    out,
    first_retained,
  )
  tui_journal_collect_since(
    (self.read_file)(self.path),
    cursor,
    max,
    out,
    first_retained,
  )
  match first_retained.val {
    Some(first) =>
      if cursor + 1L < first {
        StaleCursor
      } else {
        Events(out)
      }
    // Nothing retained on disk at all, yet latest_seq() says events exist:
    // the journal was deleted or never writable. The gap is unservable.
    None => StaleCursor
  }
}

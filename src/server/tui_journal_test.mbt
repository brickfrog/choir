///|
struct TuiJournalTestFs {
  files : Map[String, String]
}

///|
fn TuiJournalTestFs::new() -> TuiJournalTestFs {
  { files: {} }
}

///|
fn TuiJournalTestFs::append(
  self : TuiJournalTestFs,
) -> (String, String) -> Bool {
  fn(path, content) {
    self.files.set(path, self.files.get(path).unwrap_or("") + content)
    true
  }
}

///|
fn TuiJournalTestFs::read(self : TuiJournalTestFs) -> (String) -> String {
  fn(path) { self.files.get(path).unwrap_or("") }
}

///|
fn TuiJournalTestFs::file_size(self : TuiJournalTestFs) -> (String) -> Int {
  fn(path) { self.files.get(path).unwrap_or("").length() }
}

///|
fn TuiJournalTestFs::rename(
  self : TuiJournalTestFs,
) -> (String, String) -> Bool {
  fn(from_path, to_path) {
    let content = self.files.get(from_path).unwrap_or("")
    self.files.set(to_path, content)
    ignore(self.files.remove(from_path))
    true
  }
}

///|
fn tui_journal_test_open(
  fs : TuiJournalTestFs,
  ring_cap? : Int = @server.tui_journal_default_ring_cap,
  rotate_cap_bytes? : Int = @server.server_log_rotate_cap_bytes,
) -> @server.TuiJournal {
  @server.TuiJournal::open(
    "/proj",
    append_file=fs.append(),
    read_file=fs.read(),
    file_size=fs.file_size(),
    rename_file=fs.rename(),
    ring_cap~,
    rotate_cap_bytes~,
  )
}

///|
fn tui_journal_test_event(n : Int) -> @types.TuiEvent {
  @types.TuiEvent::ToolCallCompleted(
    agent_id="agent-" + n.to_string(),
    tool="test_tool",
    ok=true,
    duration_ms=n.to_int64(),
  )
}

///|
fn tui_journal_test_seqs(content : String) -> Array[Int64] {
  let seqs : Array[Int64] = []
  for raw_line in content.split("\n") {
    let line = raw_line.to_owned()
    if line.trim() == "" {
      continue
    }
    match @types.parse_tui_event_envelope_line(line) {
      Ok(envelope) => seqs.push(envelope.seq)
      Err(_) => ()
    }
  }
  seqs
}

///|
test "journal assigns monotonic seqs and appends jsonl lines" {
  let fs = TuiJournalTestFs::new()
  let journal = tui_journal_test_open(fs)
  assert_eq(journal.latest_seq(), 0L)
  assert_eq(journal.emit(tui_journal_test_event(1), 1000L), 1L)
  assert_eq(journal.emit(tui_journal_test_event(2), 2000L), 2L)
  assert_eq(journal.latest_seq(), 2L)
  let content = fs.files.get("/proj/.choir/events.journal.jsonl").unwrap_or("")
  let mut lines = 0
  for raw in content.split("\n") {
    if raw.to_owned().trim() != "" {
      lines = lines + 1
    }
  }
  assert_eq(lines, 2)
  match @server.TuiJournal::events_since(journal, 0L) {
    @server.TuiEventsSinceResult::Events(events) => {
      assert_eq(events.length(), 2)
      assert_eq(events[0].seq, 1L)
      assert_eq(events[0].ts_ms, 1000L)
      assert_eq(events[1].seq, 2L)
    }
    @server.TuiEventsSinceResult::StaleCursor => fail("expected events")
  }
}

///|
test "events_since serves from ring with bounded batches" {
  let fs = TuiJournalTestFs::new()
  let journal = tui_journal_test_open(fs)
  for i = 1; i <= 7; i = i + 1 {
    ignore(journal.emit(tui_journal_test_event(i), i.to_int64() * 100L))
  }
  match journal.events_since(2L, max=3) {
    @server.TuiEventsSinceResult::Events(events) => {
      assert_eq(events.length(), 3)
      assert_eq(events[0].seq, 3L)
      assert_eq(events[2].seq, 5L)
    }
    _ => fail("expected bounded batch")
  }
  match journal.events_since(7L) {
    @server.TuiEventsSinceResult::Events(events) =>
      assert_eq(events.length(), 0)
    _ => fail("expected empty batch at head")
  }
}

///|
test "events_since falls back to journal file when cursor predates ring" {
  let fs = TuiJournalTestFs::new()
  // Small ring: cap 2 means the ring holds at most 4 entries and compacts
  // down to the last 2; early seqs are only on disk.
  let journal = tui_journal_test_open(fs, ring_cap=2)
  for i = 1; i <= 10; i = i + 1 {
    ignore(journal.emit(tui_journal_test_event(i), i.to_int64() * 100L))
  }
  match journal.events_since(0L, max=500) {
    @server.TuiEventsSinceResult::Events(events) => {
      assert_eq(events.length(), 10)
      assert_eq(events[0].seq, 1L)
      assert_eq(events[9].seq, 10L)
    }
    _ => fail("expected journal fallback to serve full history")
  }
}

///|
test "restart recovers seq from journal tail; old cursors stay gap-free" {
  let fs = TuiJournalTestFs::new()
  let first = tui_journal_test_open(fs)
  for i = 1; i <= 3; i = i + 1 {
    ignore(first.emit(tui_journal_test_event(i), i.to_int64() * 100L))
  }
  // Restart: fresh journal over the same files. Ring is empty, but seq
  // continues and pre-restart cursors replay from disk.
  let second = tui_journal_test_open(fs)
  assert_eq(second.latest_seq(), 3L)
  assert_eq(second.emit(tui_journal_test_event(4), 400L), 4L)
  match second.events_since(1L) {
    @server.TuiEventsSinceResult::Events(events) => {
      assert_eq(events.length(), 3)
      assert_eq(events[0].seq, 2L)
      assert_eq(events[2].seq, 4L)
    }
    _ => fail("expected gap-free replay across restart")
  }
}

///|
test "cursor older than retained journal reports stale" {
  let fs = TuiJournalTestFs::new()
  let first = tui_journal_test_open(fs)
  for i = 1; i <= 5; i = i + 1 {
    ignore(first.emit(tui_journal_test_event(i), i.to_int64() * 100L))
  }
  // Simulate rotation discarding seqs 1-5: journal restarts with the file
  // gone but a tail-recovered seq continuing from a `.1` that then also
  // disappears (full retention loss).
  let rotated = TuiJournalTestFs::new()
  rotated.files.set(
    "/proj/.choir/events.journal.jsonl.1",
    fs.files.get("/proj/.choir/events.journal.jsonl").unwrap_or(""),
  )
  let second = tui_journal_test_open(rotated)
  assert_eq(second.latest_seq(), 5L)
  ignore(second.emit(tui_journal_test_event(6), 600L))
  // Cursor 0 wants seq 1; `.1` retains 1-5 so the read is still served.
  match second.events_since(0L) {
    @server.TuiEventsSinceResult::Events(events) => {
      assert_eq(events.length(), 6)
      assert_eq(events[0].seq, 1L)
    }
    _ => fail("expected .1 fallback")
  }
  // Drop the rotated file: now seqs 1-5 are unretained and cursor 0 is stale.
  rotated.files.remove("/proj/.choir/events.journal.jsonl.1")
  match second.events_since(0L) {
    @server.TuiEventsSinceResult::StaleCursor => ()
    _ => fail("expected stale cursor after retention loss")
  }
  // A cursor inside the retained range still works.
  match second.events_since(5L) {
    @server.TuiEventsSinceResult::Events(events) => {
      assert_eq(events.length(), 1)
      assert_eq(events[0].seq, 6L)
    }
    _ => fail("expected retained tail")
  }
}

///|
test "last_event_age_sec is unknown until an event exists" {
  let fs = TuiJournalTestFs::new()
  let journal = tui_journal_test_open(fs)
  @debug.assert_eq(journal.last_event_age_sec(99999L), None)
  ignore(journal.emit(tui_journal_test_event(1), 10_000L))
  @debug.assert_eq(journal.last_event_age_sec(14_000L), Some(4L))
  // Clock skew never reports negative age.
  @debug.assert_eq(journal.last_event_age_sec(8_000L), Some(0L))
}

///|
test "journal rotates during a long daemon run before appending past cap" {
  let fs = TuiJournalTestFs::new()
  let probe : @types.TuiEventEnvelope = {
    seq: 1L,
    ts_ms: 100L,
    event: tui_journal_test_event(1),
  }
  let cap = probe.to_jsonl_line().length() * 2 + 1
  let journal = tui_journal_test_open(fs, ring_cap=1, rotate_cap_bytes=cap)
  for i = 1; i <= 4; i = i + 1 {
    ignore(journal.emit(tui_journal_test_event(i), i.to_int64() * 100L))
  }
  let active = fs.files.get("/proj/.choir/events.journal.jsonl").unwrap_or("")
  let rotated = fs.files
    .get("/proj/.choir/events.journal.jsonl.1")
    .unwrap_or("")
  @debug.assert_eq(tui_journal_test_seqs(rotated), [1L, 2L])
  @debug.assert_eq(tui_journal_test_seqs(active), [3L, 4L])
  assert_eq(journal.latest_seq(), 4L)
  match journal.events_since(0L, max=10) {
    @server.TuiEventsSinceResult::Events(events) => {
      assert_eq(events.length(), 4)
      assert_eq(events[0].seq, 1L)
      assert_eq(events[3].seq, 4L)
    }
    _ => fail("expected rotated and active journal files to replay")
  }
}

///|
test "oversized journal rotates to .1 at open" {
  let fs = TuiJournalTestFs::new()
  let renames : Array[(String, String)] = []
  ignore(
    @server.TuiJournal::open(
      "/proj",
      append_file=fs.append(),
      read_file=fs.read(),
      file_size=fn(_path) { @server.server_log_rotate_cap_bytes + 1 },
      rename_file=fn(from_path, to_path) {
        renames.push((from_path, to_path))
        true
      },
    ),
  )
  assert_eq(renames.length(), 1)
  assert_eq(renames[0].0, "/proj/.choir/events.journal.jsonl")
  assert_eq(renames[0].1, "/proj/.choir/events.journal.jsonl.1")
}

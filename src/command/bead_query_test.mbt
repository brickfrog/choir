///|
fn bead_query_fixture(
  id : String,
  priority : @command.BeadPriority,
  updated_at : String,
) -> @command.BeadRecord {
  {
    id,
    title: id,
    status: @types.TaskStatus::Todo,
    priority,
    issue_type: @command.BeadIssueType::BeadTask,
    labels: [],
    edges: [],
    parent: None,
    updated_at,
  }
}

///|
fn bead_query_ids(page : @command.BeadPage) -> Array[String] {
  page.beads.map(fn(record) { record.id })
}

///|
test "a Bead query pushes its filters down to the tracker" {
  let query = {
    ..@command.default_bead_query(),
    statuses: [@types.TaskStatus::Todo, @types.TaskStatus::InProgress],
    ready_only: true,
    issue_types: [
      @command.BeadIssueType::BeadBug,
      @command.BeadIssueType::BeadFeature,
    ],
    labels_all: ["autonomy"],
    labels_any: ["product", "durability"],
    priority_min: Some(@command.BeadPriority::BeadP0),
    priority_max: Some(@command.BeadPriority::BeadP2),
  }
  // The tracker stores `open` where Choir says `todo`, and repeating --status
  // silently overwrites it, so a multi-status filter must be one value.
  // The priority flags bound the rank numerically, verified against the
  // tracker: --priority-min 0 --priority-max 2 keeps P0 through P2.
  // Issue type is absent on purpose; the tracker cannot filter a set of types.
  @debug.assert_eq(@command.bead_query_arguments(query).unwrap(), [
    "list", "--json", "--readonly", "--flat", "--limit", "0", "--status", "open,in_progress",
    "--ready", "--label", "autonomy", "--label-any", "product,durability", "--priority-min",
    "0", "--priority-max", "2",
  ])
}

///|
/// The tracker's `--type` takes one value, rejects `bug,feature` outright, and
/// silently keeps only the last when the flag repeats. Choir asking for two
/// types must therefore still get exactly those two.
test "a multi-type filter is applied by Choir, not pushed to the tracker" {
  let typed = fn(id : String, issue_type : @command.BeadIssueType) {
    {
      ..bead_query_fixture(
        id,
        @command.BeadPriority::BeadP1,
        "2026-07-01T00:00:00Z",
      ),
      issue_type,
    }
  }
  let records = [
    typed("choir-a", @command.BeadIssueType::BeadBug),
    typed("choir-b", @command.BeadIssueType::BeadEpic),
    typed("choir-c", @command.BeadIssueType::BeadFeature),
  ]
  let query = {
    ..@command.default_bead_query(),
    issue_types: [
      @command.BeadIssueType::BeadBug,
      @command.BeadIssueType::BeadFeature,
    ],
  }
  assert_true(!@command.bead_query_arguments(query).unwrap().contains("--type"))
  @debug.assert_eq(bead_query_ids(@command.page_beads(records, query)), [
    "choir-a", "choir-c",
  ])
}

///|
test "an unfiltered Bead query reads every state" {
  @debug.assert_eq(
    @command.bead_query_arguments(@command.default_bead_query()).unwrap(),
    ["list", "--json", "--readonly", "--flat", "--limit", "0", "--all"],
  )
}

///|
test "a Bead query refuses bounds it could not have meant" {
  fn reject(query : @command.BeadQuery) raise {
    assert_true(@command.bead_query_arguments(query) is Err(_))
  }
  reject({ ..@command.default_bead_query(), limit: 0 })
  reject({
    ..@command.default_bead_query(),
    limit: @command.maximum_bead_page_size() + 1,
  })
  // P3 through P1 is not a band; it is a caller who transposed the bounds.
  reject({
    ..@command.default_bead_query(),
    priority_min: Some(@command.BeadPriority::BeadP3),
    priority_max: Some(@command.BeadPriority::BeadP1),
  })
  // A comma in a label would silently become two filters at the tracker.
  reject({ ..@command.default_bead_query(), labels_all: ["a,b"] })
  reject({ ..@command.default_bead_query(), labels_any: [""] })
}

///|
test "Bead pages are totally ordered and resume exactly once" {
  let records = [
    bead_query_fixture(
      "choir-c",
      @command.BeadPriority::BeadP0,
      "2026-07-01T00:00:00Z",
    ),
    bead_query_fixture(
      "choir-a",
      @command.BeadPriority::BeadP0,
      "2026-07-03T00:00:00Z",
    ),
    bead_query_fixture(
      "choir-b",
      @command.BeadPriority::BeadP1,
      "2026-07-02T00:00:00Z",
    ),
  ]
  // Priority orders first, then id breaks the tie between the two P0s.
  let query = { ..@command.default_bead_query(), limit: 2 }
  let first = @command.page_beads(records, query)
  @debug.assert_eq(bead_query_ids(first), ["choir-a", "choir-c"])
  guard first.next_cursor is Some(cursor) else { fail("page did not resume") }
  let second = @command.page_beads(records, { ..query, cursor: Some(cursor) })
  @debug.assert_eq(bead_query_ids(second), ["choir-b"])
  // The last page reports no cursor, so a planner knows the graph is exhausted
  // rather than polling forever.
  assert_eq(second.next_cursor, None)
  // Every Bead appears exactly once across the pages.
  @debug.assert_eq([..bead_query_ids(first), ..bead_query_ids(second)], [
    "choir-a", "choir-c", "choir-b",
  ])
}

///|
test "a cursor survives the Bead it ended on disappearing" {
  let records = [
    bead_query_fixture(
      "choir-a",
      @command.BeadPriority::BeadP0,
      "2026-07-03T00:00:00Z",
    ),
    bead_query_fixture(
      "choir-b",
      @command.BeadPriority::BeadP1,
      "2026-07-02T00:00:00Z",
    ),
    bead_query_fixture(
      "choir-c",
      @command.BeadPriority::BeadP2,
      "2026-07-01T00:00:00Z",
    ),
  ]
  let query = { ..@command.default_bead_query(), limit: 1 }
  let first = @command.page_beads(records, query)
  @debug.assert_eq(bead_query_ids(first), ["choir-a"])
  // The cursor carries its ordering key, so resumption is a comparison rather
  // than a search. A cursor that had to find its own Bead would return an
  // empty page forever once that Bead was closed out of the filter.
  let without_first = [records[1], records[2]]
  let second = @command.page_beads(without_first, {
    ..query,
    cursor: first.next_cursor,
  })
  @debug.assert_eq(bead_query_ids(second), ["choir-b"])
}

///|
test "recency order reads newest first and still breaks ties by id" {
  let records = [
    bead_query_fixture(
      "choir-b",
      @command.BeadPriority::BeadP2,
      "2026-07-01T00:00:00Z",
    ),
    bead_query_fixture(
      "choir-a",
      @command.BeadPriority::BeadP0,
      "2026-07-01T00:00:00Z",
    ),
    bead_query_fixture(
      "choir-c",
      @command.BeadPriority::BeadP1,
      "2026-07-05T00:00:00Z",
    ),
  ]
  let page = @command.page_beads(records, {
    ..@command.default_bead_query(),
    order: @command.BeadListOrder::BeadOrderByUpdated,
  })
  @debug.assert_eq(bead_query_ids(page), ["choir-c", "choir-a", "choir-b"])
}

///|
test "a Bead is read with the metadata a planner selects on" {
  let parsed = @command.bead_records_from_json(
    @json.parse(
      (
        #|[{"id":"choir-g3n.8","title":"Converge","status":"open","priority":0,"issue_type":"bug","updated_at":"2026-07-26T05:01:50Z","labels":["recovery","autonomy"],"parent":"choir-g3n","dependencies":[{"depends_on_id":"choir-g3n.7","type":"blocks"},{"depends_on_id":"choir-g3n","type":"parent-child"},{"depends_on_id":"choir-g3n.4","type":"blocks"}]}]
      ),
    ),
  ).unwrap()
  assert_eq(parsed.length(), 1)
  let record = parsed[0]
  assert_true(record.priority is @command.BeadPriority::BeadP0)
  assert_true(record.issue_type is @command.BeadIssueType::BeadBug)
  assert_eq(record.parent, Some("choir-g3n"))
  assert_eq(record.updated_at, "2026-07-26T05:01:50Z")
  // Labels and edges are sorted so two reads of an unchanged Bead compare
  // equal, which is what a pre-admission reread relies on.
  @debug.assert_eq(record.labels, ["autonomy", "recovery"])
  @debug.assert_eq(@command.bead_blocking_dependency_ids(record), [
    "choir-g3n.4", "choir-g3n.7",
  ])
  // The parent-child edge is retained but is not a blocker.
  assert_eq(record.edges.length(), 3)
}

///|
test "an unreadable Bead is rejected rather than silently narrowed" {
  fn reject(text : String) raise {
    let json = @json.parse(text) catch { _ => fail("fixture is not JSON") }
    assert_true(@command.bead_records_from_json(json) is Err(_))
  }
  reject(
    (
      #|[{"title":"no identity","status":"open","priority":0}]
    ),
  )
  reject(
    (
      #|[{"id":"choir-a","status":"archived","priority":0}]
    ),
  )
  reject(
    (
      #|[{"id":"choir-a","status":"open","priority":9}]
    ),
  )
  reject(
    (
      #|[{"id":"choir-a","status":"open"}]
    ),
  )
  // An edge with no target would silently shrink the blocking closure.
  reject(
    (
      #|[{"id":"choir-a","status":"open","priority":0,"dependencies":[{"type":"blocks"}]}]
    ),
  )
  // A type this build does not know is retained, not rejected: one new tracker
  // type must not make the whole graph unreadable.
  let unknown = @command.bead_records_from_json(
    @json.parse(
      (
        #|[{"id":"choir-a","status":"open","priority":0,"issue_type":"convoy-of-the-future"}]
      ),
    ),
  ).unwrap()
  assert_true(
    unknown[0].issue_type
    is @command.BeadIssueType::BeadUnknownIssueType("convoy-of-the-future"),
  )
}

///|
test "a planner query is read off the tool surface with typed rejections" {
  fn parse(text : String) raise {
    let json = @json.parse(text) catch { _ => fail("fixture is not JSON") }
    guard json is Object(fields) else { fail("fixture is not an object") }
    @command.bead_query_from_json(fields)
  }
  let query = parse(
    (
      #|{"status":["todo"],"ready":true,"type":["bug"],"labels_all":["autonomy"],"priority_min":0,"priority_max":2,"order":"updated","limit":10,"cursor":"k\u001fchoir-a"}
    ),
  ).unwrap()
  assert_eq(query.limit, 10)
  assert_true(query.ready_only)
  assert_true(query.order is @command.BeadListOrder::BeadOrderByUpdated)
  assert_eq(query.cursor, Some("k\u{1f}choir-a"))
  // An empty request is the whole graph at the default page size.
  let bare = parse("{}").unwrap()
  assert_eq(bare, @command.default_bead_query())
  fn reject(text : String) raise {
    assert_true(parse(text) is Err(_))
  }
  reject(
    (
      #|{"status":["archived"]}
    ),
  )
  reject(
    (
      #|{"type":["convoy-of-the-future"]}
    ),
  )
  reject(
    (
      #|{"order":"title"}
    ),
  )
  reject(
    (
      #|{"limit":500}
    ),
  )
  reject(
    (
      #|{"priority_min":7}
    ),
  )
  reject(
    (
      #|{"labels_all":"autonomy"}
    ),
  )
}

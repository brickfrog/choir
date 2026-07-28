///|
/// Beads' priority band. Closed at five values by the tracker itself, so a
/// planner filter cannot ask for a priority that cannot exist.
pub(all) enum BeadPriority {
  BeadP0
  BeadP1
  BeadP2
  BeadP3
  BeadP4
} derive(Debug, Eq, Compare, ToJson, FromJson)

///|
pub fn bead_priority_rank(priority : BeadPriority) -> Int {
  match priority {
    BeadP0 => 0
    BeadP1 => 1
    BeadP2 => 2
    BeadP3 => 3
    BeadP4 => 4
  }
}

///|
pub fn bead_priority_from_rank(
  rank : Int,
) -> Result[BeadPriority, @types.ChoirError] {
  match rank {
    0 => Ok(BeadP0)
    1 => Ok(BeadP1)
    2 => Ok(BeadP2)
    3 => Ok(BeadP3)
    4 => Ok(BeadP4)
    _ => Err(bead_query_error("priority is outside the P0-P4 band"))
  }
}

///|
/// The tracker's issue types. `BeadUnknownIssueType` retains a type this build
/// does not know rather than rejecting the Bead: a tracker that grows a type
/// must not make an entire graph unreadable, and a planner that cannot match
/// the type simply does not select it.
pub(all) enum BeadIssueType {
  BeadBug
  BeadFeature
  BeadTask
  BeadEpic
  BeadChore
  BeadDecision
  BeadMergeRequest
  BeadMolecule
  BeadGate
  BeadConvoy
  BeadUnknownIssueType(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn bead_issue_type_text(issue_type : BeadIssueType) -> String {
  match issue_type {
    BeadBug => "bug"
    BeadFeature => "feature"
    BeadTask => "task"
    BeadEpic => "epic"
    BeadChore => "chore"
    BeadDecision => "decision"
    BeadMergeRequest => "merge-request"
    BeadMolecule => "molecule"
    BeadGate => "gate"
    BeadConvoy => "convoy"
    BeadUnknownIssueType(text) => text
  }
}

///|
pub fn bead_issue_type_from_text(text : String) -> BeadIssueType {
  match text {
    "bug" => BeadBug
    "feature" => BeadFeature
    "task" => BeadTask
    "epic" => BeadEpic
    "chore" => BeadChore
    "decision" => BeadDecision
    "merge-request" => BeadMergeRequest
    "molecule" => BeadMolecule
    "gate" => BeadGate
    "convoy" => BeadConvoy
    _ => BeadUnknownIssueType(text)
  }
}

///|
/// One dependency edge, with its kind retained. A planner that treats a
/// parent-child edge as blocking builds the wrong closure, so the kind is not
/// flattened away on the way in.
pub(all) enum BeadEdgeKind {
  BeadBlocks
  BeadParentChild
  BeadRelated
  BeadUnknownEdgeKind(String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub fn bead_edge_kind_text(kind : BeadEdgeKind) -> String {
  match kind {
    BeadBlocks => "blocks"
    BeadParentChild => "parent-child"
    BeadRelated => "related"
    BeadUnknownEdgeKind(text) => text
  }
}

///|
pub fn bead_edge_kind_from_text(text : String) -> BeadEdgeKind {
  match text {
    "blocks" => BeadBlocks
    "parent-child" => BeadParentChild
    "related" => BeadRelated
    _ => BeadUnknownEdgeKind(text)
  }
}

///|
pub(all) struct BeadEdge {
  depends_on_id : String
  kind : BeadEdgeKind
} derive(Debug, Eq)

///|
/// One Bead as a planner needs it: enough to select by policy and to walk the
/// dependency graph, plus the revision identity a later reread compares
/// against.
pub(all) struct BeadRecord {
  id : String
  title : String
  status : @types.TaskStatus
  priority : BeadPriority
  issue_type : BeadIssueType
  labels : Array[String]
  edges : Array[BeadEdge]
  parent : String?
  /// The tracker's own last-write stamp, retained verbatim. Choir compares it
  /// for equality before admitting a Goal and never parses it into a clock.
  updated_at : String
} derive(Debug, Eq)

///|
pub fn bead_graph_digest(records : Array[BeadRecord]) -> @control.Digest {
  let rows = records.map(bead_record_to_json)
  rows.sort_by(fn(left, right) {
    let left_id = match left {
      Object(fields) => fields.get("id").unwrap_or(Json::null()).stringify()
      _ => ""
    }
    let right_id = match right {
      Object(fields) => fields.get("id").unwrap_or(Json::null()).stringify()
      _ => ""
    }
    left_id.compare(right_id)
  })
  @control.Digest(
    @crypto.bytes_to_hex_string(
      @crypto.sha256(
        @utf8.encode(
          "choir.bead-graph.v1\u{00}" + rows.to_json().stringify(indent=0),
        ),
      ),
    ),
  )
}

///|
/// How a page is ordered. The chosen key is never the whole order: id is
/// always the final tie-breaker, so two Beads that agree on the key still
/// have one stable position and a cursor cannot skip or repeat them.
pub(all) enum BeadListOrder {
  BeadOrderByPriority
  BeadOrderByUpdated
  BeadOrderById
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Which Beads a planner is asking for. Every field is a filter the tracker
/// can apply itself; ordering and paging are applied here afterwards so the
/// result does not depend on the tracker's own tie-breaking.
pub(all) struct BeadQuery {
  statuses : Array[@types.TaskStatus]
  ready_only : Bool
  issue_types : Array[BeadIssueType]
  /// Every label must be present.
  labels_all : Array[String]
  /// At least one label must be present.
  labels_any : Array[String]
  priority_min : BeadPriority?
  priority_max : BeadPriority?
  order : BeadListOrder
  limit : Int
  /// The id the previous page ended on. The next page resumes strictly after
  /// it in the same total order.
  cursor : String?
} derive(Debug, Eq)

///|
pub(all) struct BeadPage {
  beads : Array[BeadRecord]
  /// Absent when this page reached the end of the ordered result.
  next_cursor : String?
} derive(Debug, Eq)

///|
/// The largest page a single request may return. A planner that asks for more
/// gets this instead of an unbounded read that would have to be held in memory
/// and shipped through the tool surface in one message.
pub fn maximum_bead_page_size() -> Int {
  200
}

///|
pub fn default_bead_page_size() -> Int {
  50
}

///|
fn bead_query_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Bead query: " + detail)
}

///|
pub fn default_bead_query() -> BeadQuery {
  {
    statuses: [],
    ready_only: false,
    issue_types: [],
    labels_all: [],
    labels_any: [],
    priority_min: None,
    priority_max: None,
    order: BeadListOrder::BeadOrderByPriority,
    limit: default_bead_page_size(),
    cursor: None,
  }
}

///|
fn bead_status_filter_text(status : @types.TaskStatus) -> String {
  // The tracker stores `open` where Choir's wire vocabulary says `todo`.
  match status {
    @types.TaskStatus::Todo => "open"
    other => other.to_wire_string()
  }
}

///|
/// Build the tracker invocation for this query. Filters the tracker can apply
/// are pushed down to it; ordering and paging deliberately are not, because
/// the tracker's `--sort` is not a total order and its offset paging is only
/// available against a proxied server.
pub fn bead_query_arguments(
  query : BeadQuery,
) -> Result[Array[String], @types.ChoirError] {
  if query.limit <= 0 || query.limit > maximum_bead_page_size() {
    return Err(bead_query_error("page size is outside its bounds"))
  }
  match (query.priority_min, query.priority_max) {
    (Some(low), Some(high)) =>
      if bead_priority_rank(low) > bead_priority_rank(high) {
        return Err(bead_query_error("priority band is inverted"))
      }
    _ => ()
  }
  for label in [..query.labels_all, ..query.labels_any] {
    if label == "" || label.contains(",") {
      return Err(bead_query_error("label filter is empty or ambiguous"))
    }
  }
  // Issue type is deliberately absent: the tracker's --type takes exactly one
  // value, rejects a comma-separated list, and silently keeps only the last
  // when the flag repeats. A multi-type filter pushed down there would quietly
  // return the wrong set, so type selection is applied here instead.
  let arguments : Array[String] = ["list", "--json", "--readonly", "--flat"]
  // Unlimited at the tracker: this layer decides the page, and a tracker-side
  // limit would truncate before the total order is applied.
  arguments.push("--limit")
  arguments.push("0")
  if query.statuses.length() == 0 {
    arguments.push("--all")
  } else {
    let names : Array[String] = []
    for status in query.statuses {
      let name = bead_status_filter_text(status)
      if !names.contains(name) {
        names.push(name)
      }
    }
    arguments.push("--status")
    // Repeating the flag silently overwrites it, so multi-status filters must
    // be one comma-separated value.
    arguments.push(names.join(","))
  }
  if query.ready_only {
    arguments.push("--ready")
  }
  if query.labels_all.length() > 0 {
    arguments.push("--label")
    arguments.push(query.labels_all.join(","))
  }
  if query.labels_any.length() > 0 {
    arguments.push("--label-any")
    arguments.push(query.labels_any.join(","))
  }
  // Verified against the tracker rather than inferred from the flag names:
  // --priority-min/--priority-max bound the rank numerically, so P0 is the
  // minimum and P4 the maximum, not the other way round.
  match query.priority_min {
    Some(priority) => {
      arguments.push("--priority-min")
      arguments.push(bead_priority_rank(priority).to_string())
    }
    None => ()
  }
  match query.priority_max {
    Some(priority) => {
      arguments.push("--priority-max")
      arguments.push(bead_priority_rank(priority).to_string())
    }
    None => ()
  }
  Ok(arguments)
}

///|
/// The ordering key for one Bead under one order. Rendered as text so a cursor
/// can carry it verbatim and a later page can resume without re-reading the
/// Bead it ended on — which may since have been closed or deleted.
fn bead_order_key(record : BeadRecord, order : BeadListOrder) -> String {
  match order {
    BeadOrderByPriority => bead_priority_rank(record.priority).to_string()
    BeadOrderByUpdated => record.updated_at
    BeadOrderById => ""
  }
}

///|
/// Whether this order reads its key largest-first. Recency is the only one:
/// a planner asking for recently touched Beads wants the newest first.
fn bead_order_is_descending(order : BeadListOrder) -> Bool {
  order is BeadOrderByUpdated
}

///|
fn bead_compare_keyed(
  left_key : String,
  left_id : String,
  right_key : String,
  right_id : String,
  order : BeadListOrder,
) -> Int {
  if left_key != right_key {
    let forward = left_key.compare(right_key)
    return if bead_order_is_descending(order) { -forward } else { forward }
  }
  // Id is the final tie-breaker and always ascends, so every Bead has exactly
  // one position no matter which key was chosen.
  left_id.compare(right_id)
}

///|
/// The cursor a page ends on. Opaque to callers: it carries the ordering key
/// as well as the id so resumption is a comparison rather than a search for a
/// Bead that may no longer exist.
fn bead_cursor_of(record : BeadRecord, order : BeadListOrder) -> String {
  bead_order_key(record, order) + "\u{1f}" + record.id
}

///|
fn bead_cursor_parts(cursor : String) -> (String, String) {
  let segments = cursor.split("\u{1f}").collect()
  match segments {
    [key, id] => (key.to_owned(), id.to_owned())
    _ => ("", cursor)
  }
}

///|
/// Apply the total order and cut one page. Kept out of the tracker call so the
/// order does not depend on the tracker's own tie-breaking, which is
/// unspecified and would make a cursor unstable between reads.
pub fn page_beads(records : Array[BeadRecord], query : BeadQuery) -> BeadPage {
  let ordered = if query.issue_types.length() == 0 {
    records.copy()
  } else {
    records.filter(fn(record) { query.issue_types.contains(record.issue_type) })
  }
  ordered.sort_by(fn(left, right) {
    bead_compare_keyed(
      bead_order_key(left, query.order),
      left.id,
      bead_order_key(right, query.order),
      right.id,
      query.order,
    )
  })
  let page : Array[BeadRecord] = []
  let mut truncated = false
  for record in ordered {
    match query.cursor {
      Some(cursor) => {
        let (cursor_key, cursor_id) = bead_cursor_parts(cursor)
        if bead_compare_keyed(
            bead_order_key(record, query.order),
            record.id,
            cursor_key,
            cursor_id,
            query.order,
          ) <=
          0 {
          continue
        }
      }
      None => ()
    }
    if page.length() >= query.limit {
      truncated = true
      break
    }
    page.push(record)
  }
  {
    beads: page,
    next_cursor: if truncated {
      Some(bead_cursor_of(page[page.length() - 1], query.order))
    } else {
      None
    },
  }
}

///|
fn bead_json_string(fields : Map[String, Json], name : String) -> String {
  @types.json_field_string(fields, name).unwrap_or("")
}

///|
/// Read one Bead from the tracker's own list JSON. Parsing lives here rather
/// than at the host boundary because it is a pure decision about a closed
/// vocabulary, and because a planner reading a graph must not depend on which
/// process shelled out to the tracker.
pub fn bead_record_from_json(
  value : Json,
) -> Result[BeadRecord, @types.ChoirError] {
  guard value is Object(fields) else {
    return Err(bead_query_error("Bead is not an object"))
  }
  let id = bead_json_string(fields, "id")
  if id == "" {
    return Err(bead_query_error("Bead has no identity"))
  }
  let status = match
    @types.TaskStatus::try_parse_wire(bead_json_string(fields, "status")) {
    Ok(value) => value
    Err(_) => return Err(bead_query_error("Bead " + id + " has no known state"))
  }
  let priority = match fields.get("priority") {
    Some(Number(rank, ..)) =>
      match bead_priority_from_rank(rank.to_int()) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    _ => return Err(bead_query_error("Bead " + id + " has no priority"))
  }
  let labels : Array[String] = []
  match fields.get("labels") {
    Some(Array(values)) =>
      for label in values {
        guard label is String(text) else {
          return Err(bead_query_error("Bead " + id + " has an invalid label"))
        }
        labels.push(text)
      }
    // Labels are hydrated separately by the tracker and may be absent.
    _ => ()
  }
  labels.sort_by(fn(left, right) { left.compare(right) })
  let edges : Array[BeadEdge] = []
  match fields.get("dependencies") {
    Some(Array(values)) =>
      for edge in values {
        guard edge is Object(edge_fields) else {
          return Err(bead_query_error("Bead " + id + " has an invalid edge"))
        }
        let depends_on_id = bead_json_string(edge_fields, "depends_on_id")
        let kind = bead_json_string(edge_fields, "type")
        if depends_on_id == "" || kind == "" {
          return Err(bead_query_error("Bead " + id + " has an incomplete edge"))
        }
        edges.push({ depends_on_id, kind: bead_edge_kind_from_text(kind) })
      }
    _ => ()
  }
  edges.sort_by(fn(left, right) {
    if left.depends_on_id != right.depends_on_id {
      return left.depends_on_id.compare(right.depends_on_id)
    }
    bead_edge_kind_text(left.kind).compare(bead_edge_kind_text(right.kind))
  })
  let parent = match bead_json_string(fields, "parent") {
    "" => None
    value => Some(value)
  }
  Ok({
    id,
    title: bead_json_string(fields, "title"),
    status,
    priority,
    issue_type: bead_issue_type_from_text(
      bead_json_string(fields, "issue_type"),
    ),
    labels,
    edges,
    parent,
    updated_at: bead_json_string(fields, "updated_at"),
  })
}

///|
pub fn bead_records_from_json(
  value : Json,
) -> Result[Array[BeadRecord], @types.ChoirError] {
  let items = match value {
    Array(values) => values
    Object(_) => [value]
    _ => return Err(bead_query_error("Bead list is not JSON"))
  }
  let records : Array[BeadRecord] = []
  for item in items {
    match bead_record_from_json(item) {
      Ok(record) => records.push(record)
      Err(error) => return Err(error)
    }
  }
  Ok(records)
}

///|
pub fn bead_record_to_json(record : BeadRecord) -> Json {
  {
    "id": record.id.to_json(),
    "title": record.title.to_json(),
    "status": record.status.to_wire_string().to_json(),
    "priority": bead_priority_rank(record.priority).to_json(),
    "issue_type": bead_issue_type_text(record.issue_type).to_json(),
    "labels": record.labels.to_json(),
    "dependencies": record.edges
    .map(fn(edge) {
      {
        "depends_on_id": edge.depends_on_id.to_json(),
        "type": bead_edge_kind_text(edge.kind).to_json(),
      }.to_json()
    })
    .to_json(),
    "blocking_dependency_ids": bead_blocking_dependency_ids(record).to_json(),
    "parent": match record.parent {
      Some(value) => value.to_json()
      None => Json::null()
    },
    "updated_at": record.updated_at.to_json(),
  }.to_json()
}

///|
/// The ids that actually block this Bead. Parent-child and related edges are
/// retained on the record but are not blockers, and a planner that treated
/// them as such would refuse to start work that is ready.
pub fn bead_blocking_dependency_ids(record : BeadRecord) -> Array[String] {
  let ids : Array[String] = []
  for edge in record.edges {
    if edge.kind is BeadBlocks && !ids.contains(edge.depends_on_id) {
      ids.push(edge.depends_on_id)
    }
  }
  ids
}

///|
pub fn bead_page_to_json(page : BeadPage) -> Json {
  {
    "beads": page.beads.map(bead_record_to_json).to_json(),
    "next_cursor": match page.next_cursor {
      Some(cursor) => cursor.to_json()
      None => Json::null()
    },
  }.to_json()
}

///|
fn bead_query_strings(
  fields : Map[String, Json],
  name : String,
) -> Result[Array[String], @types.ChoirError] {
  match fields.get(name) {
    None | Some(Null) => Ok([])
    Some(Array(values)) => {
      let items : Array[String] = []
      for value in values {
        guard value is String(text) else {
          return Err(bead_query_error(name + " must be a list of strings"))
        }
        items.push(text)
      }
      Ok(items)
    }
    _ => Err(bead_query_error(name + " must be a list of strings"))
  }
}

///|
fn bead_query_priority(
  fields : Map[String, Json],
  name : String,
) -> Result[BeadPriority?, @types.ChoirError] {
  match fields.get(name) {
    None | Some(Null) => Ok(None)
    Some(Number(rank, ..)) =>
      match bead_priority_from_rank(rank.to_int()) {
        Ok(value) => Ok(Some(value))
        Err(error) => Err(error)
      }
    _ => Err(bead_query_error(name + " must be a P0-P4 rank"))
  }
}

///|
/// Read a planner's query off the tool surface. Every rejection is typed and
/// names the field, so a planner that asked for something impossible is told
/// what, rather than silently receiving a differently-filtered graph.
pub fn bead_query_from_json(
  fields : Map[String, Json],
) -> Result[BeadQuery, @types.ChoirError] {
  let statuses : Array[@types.TaskStatus] = []
  match bead_query_strings(fields, "status") {
    Ok(values) =>
      for value in values {
        match @types.TaskStatus::try_parse_wire(value) {
          Ok(status) => if !statuses.contains(status) { statuses.push(status) }
          Err(_) => return Err(bead_query_error("unknown status " + value))
        }
      }
    Err(error) => return Err(error)
  }
  let issue_types : Array[BeadIssueType] = []
  match bead_query_strings(fields, "type") {
    Ok(values) =>
      for value in values {
        let issue_type = bead_issue_type_from_text(value)
        if issue_type is BeadUnknownIssueType(_) {
          return Err(bead_query_error("unknown Bead type " + value))
        }
        if !issue_types.contains(issue_type) {
          issue_types.push(issue_type)
        }
      }
    Err(error) => return Err(error)
  }
  let labels_all = match bead_query_strings(fields, "labels_all") {
    Ok(values) => values
    Err(error) => return Err(error)
  }
  let labels_any = match bead_query_strings(fields, "labels_any") {
    Ok(values) => values
    Err(error) => return Err(error)
  }
  let priority_min = match bead_query_priority(fields, "priority_min") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let priority_max = match bead_query_priority(fields, "priority_max") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let order = match @types.json_field_string(fields, "order") {
    None | Some("priority") => BeadListOrder::BeadOrderByPriority
    Some("updated") => BeadListOrder::BeadOrderByUpdated
    Some("id") => BeadListOrder::BeadOrderById
    Some(value) => return Err(bead_query_error("unknown order " + value))
  }
  let limit = match fields.get("limit") {
    None | Some(Null) => default_bead_page_size()
    Some(Number(value, ..)) => value.to_int()
    _ => return Err(bead_query_error("limit must be a number"))
  }
  let ready_only = match fields.get("ready") {
    None | Some(Null) => false
    Some(True) => true
    Some(False) => false
    _ => return Err(bead_query_error("ready must be a boolean"))
  }
  let cursor = match @types.json_field_string(fields, "cursor") {
    Some("") | None => None
    Some(value) => Some(value)
  }
  let query : BeadQuery = {
    statuses,
    ready_only,
    issue_types,
    labels_all,
    labels_any,
    priority_min,
    priority_max,
    order,
    limit,
    cursor,
  }
  // Validate through the argument builder so the tool surface and the tracker
  // invocation cannot disagree about what is acceptable.
  match bead_query_arguments(query) {
    Ok(_) => Ok(query)
    Err(error) => Err(error)
  }
}

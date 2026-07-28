///|
/// Whether this item introduces a Bead or revises one that already exists.
///
/// The distinction is load-bearing rather than cosmetic. The tracker's create
/// accepts an explicit id and, given one that is already taken, silently
/// overwrites that Bead and exits zero. A batch that did not declare its own
/// intent could therefore destroy work while reporting success.
pub(all) enum BeadMutationIntent {
  BeadCreateIntent
  BeadUpdateIntent
} derive(Debug, Eq, ToJson, FromJson)

///|
/// One Bead a planner wants to write. Absent fields are left alone; the
/// tracker's update leaves omitted fields unchanged, and this mirrors that so
/// a partial revision cannot blank a field it never mentioned.
pub(all) struct BeadMutation {
  id : String
  intent : BeadMutationIntent
  title : String?
  description : String?
  acceptance_criteria : String?
  notes : String?
  priority : BeadPriority?
  issue_type : BeadIssueType?
  /// Replaces the Bead's labels wholesale when present.
  labels : Array[String]?
  /// The Beads that must close before this one can start. Named in the
  /// direction a planner thinks in — "I am blocked by these" — which is not
  /// the direction the tracker's own create flag reads.
  blocked_by : Array[String]
  parent : String?
  /// The `updated_at` the planner last read for this Bead. An update whose
  /// stamp no longer matches is reported as drift rather than applied over
  /// whatever changed underneath it.
  expected_updated_at : String?
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BeadBatchProposal {
  mutations : Array[BeadMutation]
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Why one item of a batch cannot be applied as written.
///
/// The first two exist because the tracker will not report them: a create over
/// a taken id silently overwrites, and a dependency naming a Bead that does not
/// exist is a warning on the way to a successful exit with the edge simply
/// missing. Both would leave a planner believing it materialized a graph it did
/// not.
pub(all) enum BeadItemOutcome {
  BeadItemAdmitted
  /// A create naming a Bead that already exists.
  BeadItemDuplicateIdentity
  /// The same id appears twice in one batch.
  BeadItemRepeatedInBatch
  /// An update naming a Bead that exists nowhere.
  BeadItemUnknownTarget
  /// A blocking edge naming a Bead that is neither in the tracker nor created
  /// by this batch.
  BeadItemMissingDependency(String)
  BeadItemSelfDependency
  /// The blocking edges close a loop. Carries the cycle in the order walked.
  BeadItemDependencyCycle(Array[String])
  /// The Bead moved since the planner read it, so the revision it based this
  /// mutation on is stale.
  BeadItemOwnershipDrift(String, String)
  /// The item cannot be executed as written for a reason the planner must
  /// resolve, with what contradicts retained verbatim.
  BeadItemContradictoryContract(String)
  /// A redelivery found this item already written, edges included.
  BeadItemAlreadyApplied
  /// A redelivery found the Bead written but these blocking edges still
  /// missing. One item is several tracker invocations, so a crash between them
  /// leaves exactly this state.
  BeadItemPartiallyApplied(Array[String])
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct BeadItemVerdict {
  id : String
  outcome : BeadItemOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
fn bead_batch_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("Bead batch: " + detail)
}

///|
fn bead_mutation_fields(mutation : BeadMutation) -> Array[String] {
  let optional = fn(value : String?) {
    match value {
      Some(text) => "s" + text
      None => ""
    }
  }
  [
    mutation.id,
    match mutation.intent {
      BeadCreateIntent => "create"
      BeadUpdateIntent => "update"
    },
    optional(mutation.title),
    optional(mutation.description),
    optional(mutation.acceptance_criteria),
    optional(mutation.notes),
    optional(
      mutation.priority.map(fn(value) { bead_priority_rank(value).to_string() }),
    ),
    optional(mutation.issue_type.map(bead_issue_type_text)),
    optional(mutation.labels.map(fn(values) { values.join(",") })),
    mutation.blocked_by.join(","),
    optional(mutation.parent),
    optional(mutation.expected_updated_at),
  ]
}

///|
/// The identity one batch is delivered under. Two proposals that ask for the
/// same writes digest the same, so a redelivery after a crash is recognizable
/// as the same batch rather than applied twice.
pub fn bead_batch_digest(proposal : BeadBatchProposal) -> @control.Digest {
  let fields : Array[String] = []
  // Order-independent: the same writes proposed in a different order are the
  // same batch, and a planner should not be able to change the identity of its
  // own work by shuffling it.
  let rendered = proposal.mutations.map(fn(mutation) {
    canonical_fields("choir.bead-mutation.v1", bead_mutation_fields(mutation))
    |> @crypto.sha256
    |> @crypto.bytes_to_hex_string
  })
  rendered.sort_by(fn(left, right) { left.compare(right) })
  for entry in rendered {
    fields.push(entry)
  }
  digest_bytes(canonical_fields("choir.bead-batch.v1", fields))
}

///|
fn bead_batch_known_ids(
  proposal : BeadBatchProposal,
  existing : Array[BeadRecord],
) -> Array[String] {
  let known : Array[String] = []
  for record in existing {
    known.push(record.id)
  }
  for mutation in proposal.mutations {
    if !known.contains(mutation.id) {
      known.push(mutation.id)
    }
  }
  known
}

///|
/// Walk the blocking edges from `start` looking for a way back to it. Edges
/// come from the batch where the batch names them and from the tracker
/// otherwise, so a cycle closed jointly by new and existing Beads is still
/// found.
fn bead_batch_cycle_from(
  start : String,
  edges : Map[String, Array[String]],
) -> Array[String]? {
  let path : Array[String] = []
  let visited : Array[String] = []
  fn walk(node : String) -> Bool {
    path.push(node)
    for next in edges.get(node).unwrap_or([]) {
      if next == start {
        path.push(next)
        return true
      }
      if visited.contains(next) {
        continue
      }
      visited.push(next)
      if walk(next) {
        return true
      }
    }
    ignore(path.pop())
    false
  }

  if walk(start) {
    Some(path)
  } else {
    None
  }
}

///|
/// Decide every item of a batch against the graph as it stands.
///
/// Validation is whole-batch rather than per-item because the answers depend on
/// each other: a Bead may depend on one the same batch creates, and a cycle can
/// be closed by two items neither of which is wrong alone.
pub fn validate_bead_batch(
  proposal : BeadBatchProposal,
  existing : Array[BeadRecord],
) -> Array[BeadItemVerdict] {
  let known = bead_batch_known_ids(proposal, existing)
  let existing_ids = existing.map(fn(record) { record.id })
  let edges : Map[String, Array[String]] = Map([])
  for record in existing {
    edges.set(record.id, bead_blocking_dependency_ids(record))
  }
  for mutation in proposal.mutations {
    // A batch that names blockers replaces what the tracker holds for that
    // Bead, so the cycle check reads the graph the batch would produce.
    if mutation.blocked_by.length() > 0 {
      edges.set(mutation.id, mutation.blocked_by)
    }
  }
  let seen : Array[String] = []
  let verdicts : Array[BeadItemVerdict] = []
  for mutation in proposal.mutations {
    let verdict = fn(outcome : BeadItemOutcome) -> BeadItemVerdict {
      { id: mutation.id, outcome }
    }
    if mutation.id == "" {
      verdicts.push(
        verdict(BeadItemContradictoryContract("mutation has no Bead identity")),
      )
      continue
    }
    if seen.contains(mutation.id) {
      verdicts.push(verdict(BeadItemRepeatedInBatch))
      continue
    }
    seen.push(mutation.id)
    let already_exists = existing_ids.contains(mutation.id)
    match mutation.intent {
      BeadCreateIntent =>
        if already_exists {
          verdicts.push(verdict(BeadItemDuplicateIdentity))
          continue
        } else if mutation.title is None {
          verdicts.push(
            verdict(BeadItemContradictoryContract("a new Bead needs a title")),
          )
          continue
        }
      BeadUpdateIntent =>
        if !already_exists {
          verdicts.push(verdict(BeadItemUnknownTarget))
          continue
        }
    }
    match bead_batch_revision_drift(mutation, existing) {
      Some(outcome) => {
        verdicts.push(verdict(outcome))
        continue
      }
      None => ()
    }
    let mut settled = false
    for blocker in mutation.blocked_by {
      if blocker == mutation.id {
        verdicts.push(verdict(BeadItemSelfDependency))
        settled = true
        break
      }
      if !known.contains(blocker) {
        verdicts.push(verdict(BeadItemMissingDependency(blocker)))
        settled = true
        break
      }
    }
    if settled {
      continue
    }
    match bead_batch_cycle_from(mutation.id, edges) {
      Some(cycle) => verdicts.push(verdict(BeadItemDependencyCycle(cycle)))
      None => verdicts.push(verdict(BeadItemAdmitted))
    }
  }
  verdicts
}

///|
fn bead_batch_revision_drift(
  mutation : BeadMutation,
  existing : Array[BeadRecord],
) -> BeadItemOutcome? {
  guard mutation.expected_updated_at is Some(expected) else { return None }
  for record in existing {
    if record.id == mutation.id && record.updated_at != expected {
      return Some(BeadItemOwnershipDrift(expected, record.updated_at))
    }
  }
  None
}

///|
pub fn bead_batch_is_admitted(verdicts : Array[BeadItemVerdict]) -> Bool {
  verdicts.all(fn(verdict) { verdict.outcome is BeadItemAdmitted })
}

///|
/// Whether every item is either still to write or already written. A batch is
/// a graph, so applying the half of it that happens to be valid would leave a
/// shape the planner never asked for.
pub fn bead_batch_is_admitted_or_applied(
  verdicts : Array[BeadItemVerdict],
) -> Bool {
  verdicts.all(fn(verdict) {
    match verdict.outcome {
      BeadItemAdmitted | BeadItemAlreadyApplied | BeadItemPartiallyApplied(_) =>
        true
      _ => false
    }
  })
}

///|
/// The tracker invocations one admitted item becomes, in the order they must
/// run.
///
/// Blocking edges are a separate `dep add` rather than the create flag on
/// purpose: `bd create X --deps Y` records that Y depends on X, the reverse of
/// what a planner declaring "X is blocked by Y" means, and the bare-id form
/// that does read the intended direction reports a missing target as a warning
/// with a zero exit. `bd dep add X Y` states the same edge in the intended
/// direction and fails loudly on a cycle or a self-edge.
pub fn bead_mutation_arguments(
  mutation : BeadMutation,
) -> Result[Array[Array[String]], @types.ChoirError] {
  if mutation.id == "" {
    return Err(bead_batch_error("mutation has no Bead identity"))
  }
  for label in mutation.labels.unwrap_or([]) {
    if label == "" || label.contains(",") {
      return Err(bead_batch_error("label is empty or ambiguous"))
    }
  }
  let arguments : Array[String] = []
  match mutation.intent {
    BeadCreateIntent => {
      guard mutation.title is Some(title) else {
        return Err(bead_batch_error("a new Bead needs a title"))
      }
      // --force is omitted so a mis-prefixed id fails instead of being forced
      // into the database. It is not what protects an existing Bead: the
      // tracker overwrites a taken id and exits zero either way, which is why
      // duplicate identity is refused by validation before anything runs.
      arguments.push("create")
      arguments.push(title)
      arguments.push("--id")
      arguments.push(mutation.id)
    }
    BeadUpdateIntent => {
      arguments.push("update")
      arguments.push(mutation.id)
      match mutation.title {
        Some(title) => {
          arguments.push("--title")
          arguments.push(title)
        }
        None => ()
      }
    }
  }
  let push_option = fn(flag : String, value : String?) {
    match value {
      Some(text) => {
        arguments.push(flag)
        arguments.push(text)
      }
      None => ()
    }
  }
  push_option("--description", mutation.description)
  push_option("--acceptance", mutation.acceptance_criteria)
  push_option("--notes", mutation.notes)
  push_option(
    "--priority",
    mutation.priority.map(fn(value) { bead_priority_rank(value).to_string() }),
  )
  push_option("--type", mutation.issue_type.map(bead_issue_type_text))
  push_option("--parent", mutation.parent)
  match mutation.labels {
    Some(labels) => {
      // Replace rather than add: a planner that sent a label set means that
      // set, and adding would leave a removed label in place.
      arguments.push(
        match mutation.intent {
          BeadCreateIntent => "--labels"
          BeadUpdateIntent => "--set-labels"
        },
      )
      arguments.push(labels.join(","))
    }
    None => ()
  }
  arguments.push("--json")
  let invocations : Array[Array[String]] = [arguments]
  for blocker in mutation.blocked_by {
    if blocker == "" {
      return Err(bead_batch_error("blocking dependency has no identity"))
    }
    if blocker == mutation.id {
      return Err(bead_batch_error("a Bead cannot block itself"))
    }
    invocations.push(["dep", "add", mutation.id, blocker])
  }
  Ok(invocations)
}

///|
/// Whether the tracker already holds what this mutation asked for.
///
/// Compared field by field against the proposal rather than by a stored
/// receipt: the tracker is the authority on its own graph, so a redelivery
/// reads it instead of trusting a record of what Choir believes it wrote.
/// Fields the mutation did not name are not compared, because it never claimed
/// them.
fn bead_mutation_matches(mutation : BeadMutation, record : BeadRecord) -> Bool {
  let matches = fn(claimed : String?, observed : String) {
    match claimed {
      Some(value) => value == observed
      None => true
    }
  }
  if !matches(mutation.title, record.title) {
    return false
  }
  if !matches(mutation.parent, record.parent.unwrap_or("")) {
    return false
  }
  match mutation.priority {
    Some(priority) if priority != record.priority => return false
    _ => ()
  }
  match mutation.issue_type {
    Some(issue_type) if issue_type != record.issue_type => return false
    _ => ()
  }
  match mutation.labels {
    // Compared as a set: the tracker does not promise an order, so ordering
    // one side and not the other would report a match as drift.
    Some(labels) =>
      if labels.length() != record.labels.length() ||
        !labels.all(fn(label) { record.labels.contains(label) }) {
        return false
      }
    None => ()
  }
  true
}

///|
/// What a redelivery of this batch still has to do.
///
/// A batch is several tracker invocations per item, so a crash can land the
/// Bead without its edges. Rather than keep a durable record of what Choir
/// believes it wrote — which a crash can also lose — this rereads the graph and
/// decides each item from what is actually there. Redelivering an applied batch
/// therefore reports it applied instead of failing on its own earlier success.
pub fn reconcile_bead_batch(
  proposal : BeadBatchProposal,
  existing : Array[BeadRecord],
) -> Array[BeadItemVerdict] {
  let verdicts = validate_bead_batch(proposal, existing)
  let reconciled : Array[BeadItemVerdict] = []
  for verdict in verdicts {
    guard verdict.outcome is BeadItemDuplicateIdentity else {
      reconciled.push(verdict)
      continue
    }
    let mut found_mutation : BeadMutation? = None
    for item in proposal.mutations {
      if item.id == verdict.id && found_mutation is None {
        found_mutation = Some(item)
      }
    }
    let mut found_record : BeadRecord? = None
    for item in existing {
      if item.id == verdict.id && found_record is None {
        found_record = Some(item)
      }
    }
    guard found_mutation is Some(mutation) else {
      reconciled.push(verdict)
      continue
    }
    guard found_record is Some(record) else {
      reconciled.push(verdict)
      continue
    }
    if !bead_mutation_matches(mutation, record) {
      // The id is taken by a Bead this batch did not write. Applying over it
      // would destroy whatever it holds, and the tracker would exit zero.
      reconciled.push(verdict)
      continue
    }
    let present = bead_blocking_dependency_ids(record)
    let missing = mutation.blocked_by.filter(fn(blocker) {
      !present.contains(blocker)
    })
    reconciled.push({
      id: verdict.id,
      outcome: if missing.length() == 0 {
        BeadItemAlreadyApplied
      } else {
        BeadItemPartiallyApplied(missing)
      },
    })
  }
  reconciled
}

///|
/// What still has to run for one item of a redelivered batch. An item already
/// applied contributes nothing; one missing only edges contributes only those.
pub fn bead_reconciled_arguments(
  mutation : BeadMutation,
  outcome : BeadItemOutcome,
) -> Result[Array[Array[String]], @types.ChoirError] {
  match outcome {
    BeadItemAlreadyApplied => Ok([])
    BeadItemPartiallyApplied(missing) => {
      let invocations : Array[Array[String]] = []
      for blocker in missing {
        if blocker == "" || blocker == mutation.id {
          return Err(bead_batch_error("blocking dependency is invalid"))
        }
        invocations.push(["dep", "add", mutation.id, blocker])
      }
      Ok(invocations)
    }
    BeadItemAdmitted => bead_mutation_arguments(mutation)
    _ => Err(bead_batch_error("item was not admitted"))
  }
}

///|
fn bead_batch_json_string(fields : Map[String, Json], name : String) -> String? {
  match fields.get(name) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
fn bead_batch_json_strings(
  fields : Map[String, Json],
  name : String,
) -> Result[Array[String], @types.ChoirError] {
  match fields.get(name) {
    None | Some(Null) => Ok([])
    Some(Array(values)) => {
      let items : Array[String] = []
      for value in values {
        guard value is String(text) else {
          return Err(bead_batch_error(name + " must be a list of strings"))
        }
        items.push(text)
      }
      Ok(items)
    }
    _ => Err(bead_batch_error(name + " must be a list of strings"))
  }
}

///|
/// Read one item off the tool surface. Absent is not the same as empty: an
/// omitted field is left alone, so a planner revising a title cannot blank a
/// description it never mentioned.
pub fn bead_mutation_from_json(
  value : Json,
) -> Result[BeadMutation, @types.ChoirError] {
  guard value is Object(fields) else {
    return Err(bead_batch_error("item is not an object"))
  }
  guard bead_batch_json_string(fields, "id") is Some(id) else {
    return Err(bead_batch_error("item has no Bead identity"))
  }
  let intent = match bead_batch_json_string(fields, "intent") {
    Some("create") => BeadCreateIntent
    Some("update") => BeadUpdateIntent
    _ =>
      return Err(
        bead_batch_error("item " + id + " has no create or update intent"),
      )
  }
  let priority = match fields.get("priority") {
    None | Some(Null) => None
    Some(Number(rank, ..)) =>
      match bead_priority_from_rank(rank.to_int()) {
        Ok(value) => Some(value)
        Err(error) => return Err(error)
      }
    _ => return Err(bead_batch_error("item " + id + " has an invalid priority"))
  }
  let issue_type = match bead_batch_json_string(fields, "type") {
    None => None
    Some(text) => {
      let parsed = bead_issue_type_from_text(text)
      if parsed is BeadUnknownIssueType(_) {
        return Err(
          bead_batch_error("item " + id + " has an unknown type " + text),
        )
      }
      Some(parsed)
    }
  }
  let labels = match fields.get("labels") {
    None | Some(Null) => None
    _ =>
      match bead_batch_json_strings(fields, "labels") {
        Ok(values) => Some(values)
        Err(error) => return Err(error)
      }
  }
  let blocked_by = match bead_batch_json_strings(fields, "blocked_by") {
    Ok(values) => values
    Err(error) => return Err(error)
  }
  Ok({
    id,
    intent,
    title: bead_batch_json_string(fields, "title"),
    description: bead_batch_json_string(fields, "description"),
    acceptance_criteria: bead_batch_json_string(fields, "acceptance_criteria"),
    notes: bead_batch_json_string(fields, "notes"),
    priority,
    issue_type,
    labels,
    blocked_by,
    parent: bead_batch_json_string(fields, "parent"),
    expected_updated_at: bead_batch_json_string(fields, "expected_updated_at"),
  })
}

///|
pub fn bead_batch_from_json(
  fields : Map[String, Json],
) -> Result[BeadBatchProposal, @types.ChoirError] {
  guard fields.get("items") is Some(Array(values)) else {
    return Err(bead_batch_error("batch has no items"))
  }
  if values.length() == 0 {
    return Err(bead_batch_error("batch has no items"))
  }
  if values.length() > maximum_bead_batch_size() {
    return Err(bead_batch_error("batch is larger than one delivery may carry"))
  }
  let mutations : Array[BeadMutation] = []
  for value in values {
    match bead_mutation_from_json(value) {
      Ok(mutation) => mutations.push(mutation)
      Err(error) => return Err(error)
    }
  }
  Ok({ mutations, })
}

///|
/// The most items one delivery may carry. Every item is several tracker
/// invocations, and a batch large enough to run for minutes is one a crash is
/// likely to interrupt.
pub fn maximum_bead_batch_size() -> Int {
  100
}

///|
pub fn bead_item_outcome_text(outcome : BeadItemOutcome) -> String {
  match outcome {
    BeadItemAdmitted => "admitted"
    BeadItemAlreadyApplied => "already_applied"
    BeadItemPartiallyApplied(missing) =>
      "partially_applied: missing " + missing.join(",")
    BeadItemDuplicateIdentity => "duplicate_identity"
    BeadItemRepeatedInBatch => "repeated_in_batch"
    BeadItemUnknownTarget => "unknown_target"
    BeadItemMissingDependency(id) => "missing_dependency: " + id
    BeadItemSelfDependency => "self_dependency"
    BeadItemDependencyCycle(cycle) => "dependency_cycle: " + cycle.join(" -> ")
    BeadItemOwnershipDrift(expected, observed) =>
      "ownership_drift: read " + expected + " but tracker holds " + observed
    BeadItemContradictoryContract(detail) => "contradictory_contract: " + detail
  }
}

///|
pub fn bead_item_verdict_to_json(verdict : BeadItemVerdict) -> Json {
  let applied = match verdict.outcome {
    BeadItemAdmitted | BeadItemAlreadyApplied | BeadItemPartiallyApplied(_) =>
      true
    _ => false
  }
  {
    "id": verdict.id.to_json(),
    "outcome": bead_item_outcome_text(verdict.outcome).to_json(),
    "applied": applied.to_json(),
  }.to_json()
}

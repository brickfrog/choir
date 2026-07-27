///| Which stored artifacts are still needed, and which may be collected.
///
/// `artifact_retention_expired` has existed since the store was written but
/// nothing could call it: adoption returns the retention in a receipt and then
/// drops it, so the store knows only digests and bytes. Nothing on disk could
/// say what any artifact was being kept for.
///
/// The ledger closes that gap. It is deliberately a set of retentions per
/// digest rather than one merged value, because the store is content-addressed
/// and the same content is adopted by unrelated callers under unrelated terms.
/// A single value would have to pick a winner, and picking wrong deletes an
/// artifact something still needs.

///|
/// Everything one digest is being kept for.
pub(all) struct ArtifactRetentionEntry {
  digest : @control.Digest
  /// Every distinct retention this content has been adopted under. Collectable
  /// only when all of them have expired.
  retentions : Array[ArtifactRetention]
} derive(Debug, Eq)

///|
pub(all) struct ArtifactSweepPlan {
  /// Digests whose every retention has expired.
  collect : Array[@control.Digest]
  /// Entries that survive, carried forward as the next ledger.
  retain : Array[ArtifactRetentionEntry]
} derive(Debug, Eq)

///|
fn artifact_retention_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("artifact retention: " + detail)
}

///|
/// Add a retention to the ledger, keeping the ones already recorded.
///
/// Adopting the same content again under different terms extends what it is
/// kept for; it never replaces it. A Take output adopted until its Goal goes
/// terminal, and the same bytes adopted permanently by something else, must
/// survive the Goal.
pub fn record_artifact_retention(
  ledger : Array[ArtifactRetentionEntry],
  digest : @control.Digest,
  retention : ArtifactRetention,
) -> Array[ArtifactRetentionEntry] {
  let updated : Array[ArtifactRetentionEntry] = []
  let mut found = false
  for entry in ledger {
    if entry.digest != digest {
      updated.push(entry)
      continue
    }
    found = true
    if entry.retentions.contains(retention) {
      updated.push(entry)
    } else {
      updated.push({ ..entry, retentions: [..entry.retentions, retention] })
    }
  }
  if !found {
    updated.push({ digest, retentions: [retention] })
  }
  updated
}

///|
/// Decide what may be collected.
///
/// An entry with no retentions at all is retained rather than collected: it
/// means the ledger lost what the artifact was for, and deleting on absent
/// evidence is how a garbage collector eats live data.
pub fn plan_artifact_sweep(
  ledger : Array[ArtifactRetentionEntry],
  now : Int64,
  goal_terminal : (@control.GoalId) -> Bool,
) -> ArtifactSweepPlan {
  let collect : Array[@control.Digest] = []
  let retain : Array[ArtifactRetentionEntry] = []
  for entry in ledger {
    if entry.retentions.length() == 0 {
      retain.push(entry)
      continue
    }
    let expired = entry.retentions.all(fn(retention) {
      artifact_retention_expired(retention, now, goal_terminal)
    })
    if expired {
      collect.push(entry.digest)
    } else {
      retain.push(entry)
    }
  }
  { collect, retain }
}

///|
fn artifact_retention_text(retention : ArtifactRetention) -> String {
  match retention {
    ArtifactPermanent => "permanent"
    ArtifactUntilGoalTerminal(goal_id) => "goal:" + goal_id.0
    ArtifactUntilTimestamp(instant) => "until:" + instant.to_string()
  }
}

///|
fn artifact_retention_from_text(
  text : String,
) -> Result[ArtifactRetention, @types.ChoirError] {
  if text == "permanent" {
    return Ok(ArtifactPermanent)
  }
  if text.has_prefix("goal:") {
    let goal = text["goal:".length():].to_owned()
    if goal == "" {
      return Err(artifact_retention_error("goal retention names no Goal"))
    }
    return Ok(ArtifactUntilGoalTerminal(@control.GoalId(goal)))
  }
  if text.has_prefix("until:") {
    let instant = @string.parse_int64(text["until:".length():].to_owned()) catch {
      _ => return Err(artifact_retention_error("retention instant is invalid"))
    }
    return Ok(ArtifactUntilTimestamp(instant))
  }
  Err(artifact_retention_error("unknown retention " + text))
}

///|
/// Render the ledger one digest per line.
///
/// Text rather than JSON because this is appended to on every adoption and read
/// in full on every sweep, and a line-oriented file survives a truncated write
/// with the loss of one entry instead of the whole ledger.
pub fn encode_artifact_retention_ledger(
  ledger : Array[ArtifactRetentionEntry],
) -> String {
  let rendered = StringBuilder::new()
  for entry in ledger {
    if entry.retentions.length() == 0 {
      continue
    }
    rendered.write_string(digest_text(entry.digest))
    for retention in entry.retentions {
      rendered.write_string(" ")
      rendered.write_string(artifact_retention_text(retention))
    }
    rendered.write_string("\n")
  }
  rendered.to_string()
}

///|
/// Read a ledger back.
///
/// A line that cannot be read is skipped rather than failing the whole file: a
/// torn append must not make every other artifact uncollectable forever, and
/// the cost of skipping one is that its content is retained.
pub fn decode_artifact_retention_ledger(
  content : String,
) -> Array[ArtifactRetentionEntry] {
  let mut ledger : Array[ArtifactRetentionEntry] = []
  for line in content.split("\n") {
    let fields = line.to_owned().trim().to_owned().split(" ").to_array()
    if fields.length() < 2 {
      continue
    }
    let digest = @control.Digest(fields[0].to_owned())
    if validate_digest(digest) is Err(_) {
      continue
    }
    // A line whose terms are all unreadable contributes no entry at all. That
    // leaves its content invisible to the sweeper, which is the safe direction:
    // unknown means retained.
    for index = 1; index < fields.length(); index = index + 1 {
      match artifact_retention_from_text(fields[index].to_owned()) {
        Ok(retention) =>
          ledger = record_artifact_retention(ledger, digest, retention)
        Err(_) => ()
      }
    }
  }
  ledger
}

///|
/// The manifest line for one durable type, without its name.
fn durable_shape_entry(name : String) -> String {
  for line in @workflow.durable_value_shape_manifest().split("\n") {
    let text = line.to_owned()
    if text.has_prefix(name + " ") {
      return text[name.length() + 1:].to_owned()
    }
  }
  ""
}

///|
/// The generation identifies what this build can decode, and a store that
/// disagrees with it is destroyed. So it has to be a digest of the shapes and
/// nothing else: a label a human maintains is exactly what this replaced.
test "the durable shape generation is a digest of the shape manifest" {
  let generation = @workflow.durable_value_shape_generation()
  assert_true(generation.has_prefix("choir-durable-shape-"))
  let digest = generation["choir-durable-shape-".length():].to_owned()
  assert_eq(digest.length(), 64)
  for character in digest {
    assert_true(
      (character >= '0' && character <= '9') ||
      (character >= 'a' && character <= 'f'),
    )
  }
  // Nothing in it is observed from the host, so every process of one build
  // reports the same value.
  assert_eq(generation, @workflow.durable_value_shape_generation())
}

///|
/// Every record the control store holds under its own key has to be in the
/// manifest. One that is missing is a record whose shape can change without
/// the generation moving, which is the failure this exists to prevent.
test "the shape manifest covers every durably stored record" {
  let stored = [
    "PartWorkflowSnapshot", "PartEffectWitness", "GoalExecutionRecord", "GoalAssuranceRecord",
    "GoalAssuranceEffectWitness", "GoalFinalizationRecord", "GoalPublicationRecord",
    "GoalPullRequestRecord", "GoalSelectionDecision", "ProcessExecution",
  ]
  for name in stored {
    let entry = durable_shape_entry(name)
    assert_true(entry.length() > 0)
    assert_true(entry.contains("{"))
  }
}

///|
/// The witness has to serialize the same keys the real record does, or it
/// describes a shape nothing stores. Compared against a snapshot built by
/// driving the workflow rather than against a second hand-written list.
test "the shape manifest names every key a stored snapshot serializes" {
  let snapshot = drive_to_integration_authorized()
  let entry = durable_shape_entry("PartWorkflowSnapshot")
  let serialized = @json.parse(
    @utf8.decode_lossy(@workflow.part_snapshot_bytes(snapshot)),
  )
  let fields = match serialized {
    Json::Object(value) => value
    _ => fail("a snapshot serializes to an object")
  }
  let mut counted : Int = 0
  for key in fields.keys() {
    assert_true(
      entry.contains("{" + key + ":") || entry.contains("," + key + ":"),
    )
    counted = counted + 1
  }
  assert_true(counted >= 30)
}

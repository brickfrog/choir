///| How the durable value shapes are turned into one identity.
///
/// `durable_shape.mbt` holds the witness: one exhaustive instance of every type
/// that reaches a durable record. This file turns those instances into a text
/// that describes their structure, and digests it.
///
/// The subtle part is optionality. A field declared `T?` and a field declared
/// `T` serialize identically when the optional one is present — MoonBit omits
/// the key only for `None` — so a witness that sets every option to `Some`
/// cannot see a required field become optional or the reverse. That is a real
/// decode-compatibility change, and missing it is exactly the failure a derived
/// generation exists to prevent.
///
/// So optionality is not read off the instance. It is measured against the
/// type's own `FromJson`: for every key, the manifest asks whether the value
/// still decodes with that key removed, and records the answer. Nothing is
/// inferred about the declaration — the decoder is asked directly what it
/// tolerates, which is the property the generation is actually about.

///|
/// One durable type: the serialized form of every shape it can take, and its
/// own decoder.
priv struct DurableShapeEntry {
  name : String
  shapes : Array[Json]
  /// The type's derived `FromJson`, closed over the type. Used to measure which
  /// keys it tolerates being absent.
  decodes : (Json) -> Bool
}

///|
/// Build one manifest entry from typed values.
///
/// Taking the values typed rather than pre-serialized is what makes the decoder
/// available: the caller cannot supply JSON that no type claims.
fn[T : ToJson + @json.FromJson] durable_shape_entry(
  name : String,
  values : Array[T],
) -> DurableShapeEntry {
  {
    name,
    shapes: values.map(fn(value) { ToJson::to_json(value) }),
    decodes: fn(candidate) {
      let _ : T = @json.from_json(candidate) catch { _ => return false }
      true
    },
  }
}

///|
/// One step into a serialized shape. Removal has to address a key inside an
/// array element too, because an enum variant with a payload serializes as
/// `["Variant", payload]`.
priv enum DurableShapeStep {
  DurableShapeKey(String)
  DurableShapeIndex(Int)
}

///|
/// The whole value with one key removed at `path`.
///
/// The whole value, not the sub-object: the decoder under test is the top-level
/// one, so what it is asked to decode has to stay a complete instance.
fn durable_shape_without(
  value : Json,
  path : ArrayView[DurableShapeStep],
  key : String,
) -> Json {
  if path.length() == 0 {
    return match value {
      Json::Object(fields) => {
        let rebuilt : Map[String, Json] = Map([])
        for name in fields.keys() {
          if name != key {
            rebuilt[name] = fields.get(name).unwrap()
          }
        }
        Json::object(rebuilt)
      }
      _ => value
    }
  }
  match (path[0], value) {
    (DurableShapeKey(step), Json::Object(fields)) => {
      let rebuilt : Map[String, Json] = Map([])
      for name in fields.keys() {
        let child = fields.get(name).unwrap()
        rebuilt[name] = if name == step {
          durable_shape_without(child, path[1:], key)
        } else {
          child
        }
      }
      Json::object(rebuilt)
    }
    (DurableShapeIndex(step), Json::Array(items)) => {
      let rebuilt : Array[Json] = []
      for position, item in items {
        rebuilt.push(
          if position == step {
            durable_shape_without(item, path[1:], key)
          } else {
            item
          },
        )
      }
      Json::array(rebuilt)
    }
    _ => value
  }
}

///|
/// Write one line per path in a shape.
///
/// A line per path rather than one nested blob: a nested rendering cannot be
/// checked for a specific top-level key without re-parsing it, and a test that
/// searches the blob for `,name:` finds a same-named key nested three levels
/// down and reports coverage that is not there.
///
/// Object keys are sorted, because MoonBit emits them in declaration order and
/// reordering a declaration does not change what decodes. A key that the type's
/// decoder tolerates being absent is marked `?`. Scalar values are kept: the
/// tag of an enum variant is a string in the serialized form, and losing it
/// would let a renamed variant pass unnoticed. Every value in the witness is a
/// fixed placeholder, so nothing but structure can move the result.
fn durable_shape_render(
  root : Json,
  decodes : (Json) -> Bool,
  path : Array[DurableShapeStep],
  label : String,
  value : Json,
  rendered : StringBuilder,
) -> Unit {
  rendered.write_string(label)
  rendered.write_string(" = ")
  match value {
    Json::Object(fields) => {
      rendered.write_string("object\n")
      let keys : Array[String] = []
      for key in fields.keys() {
        keys.push(key)
      }
      keys.sort_by(fn(left, right) { left.compare(right) })
      for key in keys {
        let optional = decodes(durable_shape_without(root, path[:], key))
        durable_shape_render(
          root,
          decodes,
          [..path, DurableShapeKey(key)],
          label + "." + key + (if optional { "?" } else { "" }),
          fields.get(key).unwrap(),
          rendered,
        )
      }
    }
    Json::Array(items) => {
      rendered.write_string("array\n")
      for index, item in items {
        durable_shape_render(
          root,
          decodes,
          [..path, DurableShapeIndex(index)],
          label + "[" + index.to_string() + "]",
          item,
          rendered,
        )
      }
    }
    Json::String(text) => {
      rendered.write_string("\"")
      rendered.write_string(text)
      rendered.write_string("\"\n")
    }
    Json::Number(number, ..) => {
      rendered.write_string(number.to_string())
      rendered.write_string("\n")
    }
    Json::True => rendered.write_string("true\n")
    Json::False => rendered.write_string("false\n")
    Json::Null => rendered.write_string("null\n")
  }
}

///|
/// The full structure of everything this build can store, one path per line.
///
/// Public because the generation is otherwise a digest with nothing behind it:
/// this is the evidence a reset is decided on, and it is what lets a test check
/// that a record's real keys are the ones being digested.
///
/// Each shape is labelled `Type#index` because an enum contributes one shape
/// per variant and they have to stay distinguishable. That makes the digest
/// sensitive to the order variants are listed in, which costs nothing: a moved
/// generation no longer destroys anything on its own, it only asks for the
/// stored records to be read.
///
/// The record kinds lead, because which records exist under which key prefix is
/// part of what this build can read: move a prefix and the records written
/// under the old one stop being found at all.
pub fn durable_value_shape_manifest() -> String {
  let rendered = StringBuilder::new()
  let kinds = durable_record_kinds()
  kinds.sort_by(fn(left, right) {
    durable_record_shape_name(left).compare(durable_record_shape_name(right))
  })
  for kind in kinds {
    rendered.write_string("record ")
    rendered.write_string(durable_record_shape_name(kind))
    rendered.write_string(" = \"")
    rendered.write_string(durable_record_key_prefix(kind))
    rendered.write_string("\"\n")
  }
  let table = durable_shape_table()
  table.sort_by(fn(left, right) { left.name.compare(right.name) })
  for entry in table {
    for index, shape in entry.shapes {
      durable_shape_render(
        shape,
        entry.decodes,
        [],
        entry.name + "#" + index.to_string(),
        shape,
        rendered,
      )
    }
  }
  rendered.to_string()
}

///|
/// What this build calls the durable shapes it can decode.
///
/// Recorded in the control store when it is created or adopted, and compared on
/// every start. A mismatch is evidence that the shapes moved — not, on its own,
/// that the stored records became unreadable, which is why the comparison is a
/// fast path and `@storage.decide_control_state` sends a mismatch on to be
/// proven against the records themselves.
///
/// Building the manifest asks every type's decoder about every key of every
/// shape, which is thousands of decodes. That is paid once, when `choird`
/// starts and prepares the control store.
pub fn durable_value_shape_generation() -> String {
  "choir-durable-shape-" +
  @storage.digest_text(
    @storage.artifact_digest(@utf8.encode(durable_value_shape_manifest())),
  )
}

///|
/// A kind of record the control store holds under its own key prefix.
///
/// The prefix lives here and the repository that writes those records reads it
/// from here, so the scan that has to find them cannot drift away from the
/// writer. A record kind missing from this enum is a record nothing would read
/// when deciding whether this build can still decode the store.
pub(all) enum DurableRecordKind {
  DurablePartWorkflowSnapshot
  DurablePartEffectWitness
  DurableGoalExecutionRecord
  DurableGoalAssuranceRecord
  DurableGoalAssuranceEffectWitness
  DurableGoalFinalizationRecord
  DurableGoalPublicationRecord
  DurableGoalPullRequestRecord
  DurableGoalSelectionDecision
  DurableProcessExecution
  DurableProviderSurfaceLease
  DurableGoalExecutorSchedule
} derive(Debug, Eq)

///|
pub fn durable_record_kinds() -> Array[DurableRecordKind] {
  [
    DurablePartWorkflowSnapshot,
    DurablePartEffectWitness,
    DurableGoalExecutionRecord,
    DurableGoalAssuranceRecord,
    DurableGoalAssuranceEffectWitness,
    DurableGoalFinalizationRecord,
    DurableGoalPublicationRecord,
    DurableGoalPullRequestRecord,
    DurableGoalSelectionDecision,
    DurableProcessExecution,
    DurableProviderSurfaceLease,
    DurableGoalExecutorSchedule,
  ]
}

///|
/// The state-record key prefix every record of this kind is stored under.
pub fn durable_record_key_prefix(kind : DurableRecordKind) -> String {
  match kind {
    DurablePartWorkflowSnapshot => "workflow:"
    DurablePartEffectWitness => "effect-witness:"
    DurableGoalExecutionRecord => "goal-run:"
    DurableGoalAssuranceRecord => "goal-assurance:"
    DurableGoalAssuranceEffectWitness => "goal-assurance-witness:"
    DurableGoalFinalizationRecord => "goal-finalization:"
    DurableGoalPublicationRecord => "goal-publication:"
    DurableGoalPullRequestRecord => "goal-pull-request:"
    DurableGoalSelectionDecision => "goal-selection:"
    DurableProcessExecution => "process-execution:"
    DurableProviderSurfaceLease => "provider-lease:"
    DurableGoalExecutorSchedule => "goal-executor:"
  }
}

///|
/// The manifest entry describing this kind's record type.
pub fn durable_record_shape_name(kind : DurableRecordKind) -> String {
  match kind {
    DurablePartWorkflowSnapshot => "PartWorkflowSnapshot"
    DurablePartEffectWitness => "PartEffectWitness"
    DurableGoalExecutionRecord => "GoalExecutionRecord"
    DurableGoalAssuranceRecord => "GoalAssuranceRecord"
    DurableGoalAssuranceEffectWitness => "GoalAssuranceEffectWitness"
    DurableGoalFinalizationRecord => "GoalFinalizationRecord"
    DurableGoalPublicationRecord => "GoalPublicationRecord"
    DurableGoalPullRequestRecord => "GoalPullRequestRecord"
    DurableGoalSelectionDecision => "GoalSelectionDecision"
    DurableProcessExecution => "ProcessExecution"
    DurableProviderSurfaceLease => "ProviderSurfaceLeaseRecord"
    DurableGoalExecutorSchedule => "GoalExecutorScheduleRecord"
  }
}

///|
/// Whether this build can still read one stored record.
///
/// The real loader's decoder, including the identity checks it runs after
/// `FromJson` — a record that parses into the right shape and then fails the
/// check the loader makes is one the loader would refuse, so it counts as
/// unreadable here too.
pub fn durable_record_decodes(
  kind : DurableRecordKind,
  content : Bytes,
) -> Bool {
  match kind {
    DurablePartWorkflowSnapshot => decode_part_snapshot(content) is Ok(_)
    DurablePartEffectWitness => decode_part_effect_witness(content) is Ok(_)
    DurableGoalExecutionRecord => decode_goal_execution_record(content) is Ok(_)
    DurableGoalAssuranceRecord => decode_goal_assurance_record(content) is Ok(_)
    DurableGoalAssuranceEffectWitness =>
      decode_goal_assurance_effect_witness(content) is Ok(_)
    DurableGoalFinalizationRecord =>
      decode_goal_finalization_record(content) is Ok(_)
    DurableGoalPublicationRecord =>
      decode_goal_publication_record(content) is Ok(_)
    DurableGoalPullRequestRecord =>
      decode_goal_pull_request_record(content) is Ok(_)
    DurableGoalSelectionDecision =>
      decode_goal_selection_decision(content) is Ok(_)
    DurableProcessExecution =>
      @sandbox.decode_process_execution(content) is Ok(_)
    DurableProviderSurfaceLease =>
      decode_provider_surface_lease_record(content) is Ok(_)
    DurableGoalExecutorSchedule =>
      decode_goal_executor_schedule_record(content) is Ok(_)
  }
}

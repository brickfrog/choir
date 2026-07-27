///| Whether the durable control store on disk can be used as it stands, and
/// what to do when it cannot.
///
/// This was previously a hand-bumped `choir-control-state-v8` constant in the
/// host-effect package, compared against a sibling `generation` file. Two
/// things were wrong with that. A forgotten bump wedged decoding, because
/// nothing derived the identity from the thing it described. And the marker's
/// absence alone authorized deleting the entire control store — releasing
/// claims, purging refs, and removing runtime roots — so losing one small file
/// discarded healthy state that decoded perfectly well.
///
/// Both are gone. The expected generation is derived from the durable value
/// shapes by `@workflow.durable_value_shape_generation`, and the store records
/// its own inside itself.
///
/// What a derived generation cannot do is say *how* two generations differ. A
/// digest reports only "not equal". Derived decoding tolerates a missing
/// optional key and ignores keys it does not know, so adding an optional field
/// or an enum variant moves the generation while every stored record still
/// decodes perfectly. Treating a moved generation as authority to destroy would
/// wipe healthy state on every additive change — a broader version of the harm
/// this decision was written to remove.
///
/// So the generation is a fast path, not the authority. Equal means usable
/// without reading anything. Not equal means the question is still open, and
/// the caller answers it by reading the records: they decode, or they do not,
/// and only "they do not" authorizes a reset.

///|
/// What Choir observed about the control store before deciding anything.
pub(all) struct ControlStateObservation {
  /// Whether the durable store itself exists.
  store_present : Bool
  /// Whether it could be opened and read. A store that exists but cannot be
  /// read is not the same as one that disagrees about its schema.
  store_readable : Bool
  /// The schema generation recorded inside the store. Absent means the store
  /// predates recording it, not that it is incompatible.
  recorded_generation : String?
  /// Whether anything else remains under the control root. Residue with no
  /// store is the leftovers of a partial reset.
  residue_present : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Why a reset was authorized. Every variant names evidence that the state on
/// disk cannot be used, never merely that something was missing or different.
pub(all) enum ControlStateResetReason {
  /// The store exists and cannot be read. Nothing can be recovered from it.
  ControlStoreUnreadable
  /// The store holds this record and this build cannot decode it. Carries the
  /// generations either side so a log says what moved as well as what broke.
  ControlRecordUndecodable(StateRecordKey, String, String)
  /// No store, but the control root is not empty: a previous reset did not
  /// finish, so what remains belongs to no live generation.
  ControlStoreResidue
} derive(Debug, Eq, ToJson, FromJson)

///|
/// What to do with the control store. Reaching one of these takes evidence, not
/// merely a difference.
pub(all) enum ControlStatePlan {
  /// Usable as it stands.
  ControlStateCurrent
  /// Nothing is there. Create it; there is nothing to destroy.
  ControlStateInitialize
  /// Usable, but the recorded generation has to be brought up to date. Carries
  /// what was recorded and what will be, so an adoption is distinguishable
  /// from a no-op in a log.
  ControlStateMigrate(String?, String)
  ControlStateAuthorizedReset(ControlStateResetReason)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// The outcome of looking at the store, which is either a plan or a question.
pub(all) enum ControlStateDecision {
  ControlStatePlanned(ControlStatePlan)
  /// The store records a generation this build does not derive. Whether that
  /// matters cannot be read off the two strings, so the caller reads the stored
  /// records and returns through `decide_control_state_from_records`. Carries
  /// the recorded and expected generations so the answer can name both.
  ControlStateProveRecordsDecodable(String, String)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Decide what to do with the control store, as far as observing it allows.
///
/// The ordering matters. Unreadable is checked before the generation, because
/// a store that cannot be opened has no trustworthy generation to compare.
/// A store that reads but has recorded no generation is adopted rather than
/// destroyed: it decodes, and its schema is this one, so the only thing
/// missing is the note saying so.
pub fn decide_control_state(
  observation : ControlStateObservation,
  expected_generation : String,
) -> ControlStateDecision {
  if !observation.store_present {
    return ControlStatePlanned(
      if observation.residue_present {
        ControlStateAuthorizedReset(ControlStoreResidue)
      } else {
        ControlStateInitialize
      },
    )
  }
  if !observation.store_readable {
    return ControlStatePlanned(
      ControlStateAuthorizedReset(ControlStoreUnreadable),
    )
  }
  match observation.recorded_generation {
    Some(recorded) if recorded == expected_generation =>
      ControlStatePlanned(ControlStateCurrent)
    Some(recorded) =>
      ControlStateProveRecordsDecodable(recorded, expected_generation)
    // A readable store that never recorded its generation is this schema by
    // construction: an incompatible one would not have decoded. Adopting it is
    // what stops a lost marker from discarding healthy state.
    None => ControlStatePlanned(ControlStateMigrate(None, expected_generation))
  }
}

///|
/// Decide what a generation mismatch actually meant, once the records have been
/// read.
///
/// `undecodable` names the first stored record this build could not decode, and
/// nothing else authorizes destroying the store. Records that all decode under
/// a moved generation are records this build can use: the shapes grew in a way
/// their encoding tolerates, and the only stale thing is the note saying which
/// generation wrote them.
///
/// What decoding answers is "can this build read the record", not "does it
/// still mean the same thing". Renaming an optional field is the case where
/// those come apart: the old key is ignored, the new one is absent, the record
/// decodes with that field dropped, and it is adopted. The alternative — treat
/// every moved generation as authority to destroy — loses the whole store on
/// changes that cost nothing, which is worse in every case but that one, so a
/// durable field is renamed rather than reused deliberately or not at all.
pub fn decide_control_state_from_records(
  recorded_generation : String,
  expected_generation : String,
  undecodable : StateRecordKey?,
) -> ControlStatePlan {
  match undecodable {
    Some(key) =>
      ControlStateAuthorizedReset(
        ControlRecordUndecodable(key, recorded_generation, expected_generation),
      )
    None => ControlStateMigrate(Some(recorded_generation), expected_generation)
  }
}

///|
/// Whether this plan authorizes destroying durable state. The one question a
/// reviewer actually needs answered, kept in one place so no caller has to
/// enumerate the variants and get it subtly wrong.
pub fn control_state_plan_destroys(plan : ControlStatePlan) -> Bool {
  plan is ControlStateAuthorizedReset(_)
}

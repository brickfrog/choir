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
/// The decision is pure and the reason is explicit, so the destructive branch
/// is reviewable on its own terms rather than inferred from filesystem checks
/// scattered through an effect path.

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
/// disk cannot be used, never merely that something was missing.
pub(all) enum ControlStateResetReason {
  /// The store exists and cannot be read. Nothing can be recovered from it.
  ControlStoreUnreadable
  /// The store records a schema this build cannot decode.
  ControlSchemaIncompatible(String, String)
  /// No store, but the control root is not empty: a previous reset did not
  /// finish, so what remains belongs to no live generation.
  ControlStoreResidue
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ControlStateDecision {
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
/// Decide what to do with the control store.
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
    return if observation.residue_present {
      ControlStateAuthorizedReset(ControlStoreResidue)
    } else {
      ControlStateInitialize
    }
  }
  if !observation.store_readable {
    return ControlStateAuthorizedReset(ControlStoreUnreadable)
  }
  match observation.recorded_generation {
    Some(recorded) if recorded == expected_generation => ControlStateCurrent
    Some(recorded) =>
      ControlStateAuthorizedReset(
        ControlSchemaIncompatible(recorded, expected_generation),
      )
    // A readable store that never recorded its generation is this schema by
    // construction: an incompatible one would not have decoded. Adopting it is
    // what stops a lost marker from discarding healthy state.
    None => ControlStateMigrate(None, expected_generation)
  }
}

///|
/// Whether this decision authorizes destroying durable state. The one question
/// a reviewer actually needs answered, kept in one place so no caller has to
/// enumerate the variants and get it subtly wrong.
pub fn control_state_decision_destroys(decision : ControlStateDecision) -> Bool {
  decision is ControlStateAuthorizedReset(_)
}

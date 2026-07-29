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
///
/// The generation answers for the record VALUES only. It says nothing about the
/// SQL tables those values are stored in, which change independently and whose
/// failure mode is the opposite: `CREATE TABLE IF NOT EXISTS` finds a table
/// built by an older DDL, leaves it alone, and every query against a column
/// that table does not have fails at runtime with no record ever read and no
/// reset ever reached. Nothing about that is visible in a value digest, so the
/// DDL carries its own declared version, and the two are compared separately.

///|
/// What the control store must say about itself for this build to use it as it
/// stands.
pub(all) struct ControlStoreSchema {
  /// Digest of the durable value shapes, derived by
  /// `@workflow.durable_value_shape_generation`.
  generation : String
  /// The version of the SQL DDL that creates the store's tables, declared
  /// beside those statements and bumped by hand with them. It is not derived
  /// and cannot be: a digest over the DDL text would move for a reformatting,
  /// and this comparison authorizes destroying the store. What keeps the hand
  /// bump honest is a test that pins the DDL text's digest to the version, so a
  /// forgotten bump fails the build instead of shipping.
  ddl_version : Int
} derive(Debug, Eq, ToJson, FromJson)

///|
/// The DDL version of a store whose tables were created before the version was
/// stamped at all. Distinct from every real version, and never authority to
/// destroy: the set of stores that can hold it is exactly the set created by
/// the DDL this constant was introduced alongside.
pub let control_store_unstamped_ddl_version : Int = 0

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
  /// The DDL version the store's tables were created under, or
  /// `control_store_unstamped_ddl_version` when they predate the stamp.
  recorded_ddl_version : Int
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
  /// The store's tables were created by a DDL this build has declared it does
  /// not write SQL against and for which no exact migration is declared.
  /// Carries the recorded and expected versions.
  ///
  /// Unlike a moved generation this is authority on its own, and the asymmetry
  /// is deliberate. A generation is a digest, so "different" is all it can say
  /// and the records are asked what it meant. A DDL version only moves because
  /// somebody edited the `CREATE TABLE` statements and said so in the same
  /// commit, and no generic probe can recover from it: the records cannot be
  /// read to settle the question, because reading them is the query that
  /// fails. A specifically declared additive DDL migration is the sole
  /// exception.
  ControlStoreDdlSuperseded(Int, Int)
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
  /// Usable, but what the store records about itself has to be brought up to
  /// date. Carries the generation that was recorded, if any, and the whole
  /// schema that will be, so an adoption is distinguishable from a no-op in a
  /// log.
  ControlStateMigrate(String?, ControlStoreSchema)
  /// The store uses a specifically supported older table shape. The host may
  /// apply only the exact migration named by these versions, then record the
  /// target schema. Every other DDL mismatch remains destructive.
  ControlStateMigrateDdl(Int, ControlStoreSchema)
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
  ControlStateProveRecordsDecodable(String, String, Int?)
} derive(Debug, Eq, ToJson, FromJson)

///|
/// Declared compatibility policy for table shapes. Version 2 adds only the
/// nullable outbox owner column; existing idempotency rows remain deliberately
/// unowned and therefore unprunable.
fn control_store_ddl_migration_supported(
  recorded : Int,
  expected : Int,
) -> Bool {
  recorded == 1 && expected == 2
}

///|
/// Decide what to do with the control store, as far as observing it allows.
///
/// The ordering matters. Unreadable is checked before anything recorded,
/// because a store that cannot be opened has no trustworthy generation or
/// version to compare. The DDL version is checked before the generation,
/// because a table without the columns this build queries fails before any
/// record is read, so the records cannot answer for it.
///
/// A store that reads but has recorded no generation, or whose tables predate
/// the DDL stamp, is adopted rather than destroyed: it decodes, its tables are
/// the ones this DDL creates, and the only thing missing is the note saying so.
pub fn decide_control_state(
  observation : ControlStateObservation,
  expected : ControlStoreSchema,
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
  let ddl_stamped = observation.recorded_ddl_version !=
    control_store_unstamped_ddl_version
  if ddl_stamped && observation.recorded_ddl_version != expected.ddl_version {
    if control_store_ddl_migration_supported(
        observation.recorded_ddl_version,
        expected.ddl_version,
      ) {
      return match observation.recorded_generation {
        Some(recorded) if recorded != expected.generation =>
          ControlStateProveRecordsDecodable(
            recorded,
            expected.generation,
            Some(observation.recorded_ddl_version),
          )
        _ =>
          ControlStatePlanned(
            ControlStateMigrateDdl(observation.recorded_ddl_version, expected),
          )
      }
    }
    return ControlStatePlanned(
      ControlStateAuthorizedReset(
        ControlStoreDdlSuperseded(
          observation.recorded_ddl_version,
          expected.ddl_version,
        ),
      ),
    )
  }
  match observation.recorded_generation {
    // Current is the one answer that reads nothing and writes nothing, so it
    // requires the store to already say everything this build expects. An
    // unstamped store still has to be stamped, or the DDL version would never
    // become load-bearing for it.
    Some(recorded) if recorded == expected.generation && ddl_stamped =>
      ControlStatePlanned(ControlStateCurrent)
    Some(recorded) if recorded == expected.generation =>
      ControlStatePlanned(ControlStateMigrate(Some(recorded), expected))
    Some(recorded) =>
      ControlStateProveRecordsDecodable(recorded, expected.generation, None)
    // A readable store that never recorded its generation is this schema by
    // construction: an incompatible one would not have decoded. Adopting it is
    // what stops a lost marker from discarding healthy state.
    None => ControlStatePlanned(ControlStateMigrate(None, expected))
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
  expected : ControlStoreSchema,
  undecodable : StateRecordKey?,
  ddl_migration_from? : Int? = None,
) -> ControlStatePlan {
  match undecodable {
    Some(key) =>
      ControlStateAuthorizedReset(
        ControlRecordUndecodable(key, recorded_generation, expected.generation),
      )
    None =>
      match ddl_migration_from {
        Some(version) => ControlStateMigrateDdl(version, expected)
        None => ControlStateMigrate(Some(recorded_generation), expected)
      }
  }
}

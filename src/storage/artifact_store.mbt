///|
pub(all) struct ArtifactStore {
  root : String
} derive(Debug, Eq)

///|
pub(all) struct ArtifactId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum ArtifactRetention {
  ArtifactPermanent
  ArtifactUntilGoalTerminal(@control.GoalId)
  ArtifactUntilTimestamp(Int64)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) enum ArtifactProvenance {
  ArtifactTaskInstruction(@control.RevisionId)
  ArtifactVerificationProcessSpec(@control.VerificationSpecId)
  ArtifactTakeOutput(@control.TakeId)
  ArtifactVerificationEvidence(@control.TakeId)
  ArtifactAuditFindings(@control.TakeId)
  ArtifactConformanceEvidence
  ArtifactGoalSelectionSnapshot(@control.GoalId)
  ArtifactGoalSelectionDecision(@control.GoalId)
  ArtifactGoalExecutionRecord(@control.GoalId)
  ArtifactGoalInputAnswer(@control.GoalId)
  ArtifactGoalAssuranceRecord(@control.GoalId)
  ArtifactGoalPublicationRecord(@control.GoalId)
  ArtifactPullRequestDocument(@control.GoalId)
  ArtifactGoalPullRequestRecord(@control.GoalId)
  ArtifactGoalFinalizationRecord(@control.GoalId)
  ArtifactWorkflowSnapshot(@control.GoalId)
  ArtifactEffectWitness(@control.GoalId)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ArtifactAdoptionRequest {
  content : Bytes
  expected_digest : @control.Digest
  provenance : ArtifactProvenance
  retention : ArtifactRetention
}

///|
pub(all) enum ArtifactAdoptionOutcome {
  ArtifactAdopted
  ArtifactAlreadyPresent
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ArtifactReceipt {
  artifact_id : ArtifactId
  digest : @control.Digest
  byte_length : Int
  provenance : ArtifactProvenance
  retention : ArtifactRetention
  outcome : ArtifactAdoptionOutcome
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct ArtifactStoreAdapters {
  adopt : (ArtifactStore, ArtifactAdoptionRequest) -> Result[
    ArtifactReceipt,
    @types.ChoirError,
  ]
  contains : (ArtifactStore, @control.Digest) -> Result[Bool, @types.ChoirError]
  read : (ArtifactStore, ArtifactReadRequest) -> Result[
    Bytes,
    @types.ChoirError,
  ]
}

///|
pub(all) struct ArtifactReadRequest {
  digest : @control.Digest
  max_bytes : Int
} derive(Debug, Eq)

///|
pub fn validate_artifact_read(
  request : ArtifactReadRequest,
) -> Result[Unit, @types.ChoirError] {
  match validate_digest(request.digest) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if request.max_bytes <= 0 {
    Err(
      @types.ChoirError::validation_error(
        "artifact read requires a positive byte limit",
      ),
    )
  } else {
    Ok(())
  }
}

///|
pub fn artifact_digest(content : Bytes) -> @control.Digest {
  @control.Digest(@crypto.bytes_to_hex_string(@crypto.sha256(content)))
}

///|
pub fn artifact_id_for_digest(digest : @control.Digest) -> ArtifactId {
  ArtifactId("sha256:" + digest_text(digest))
}

///|
pub fn artifact_id_text(id : ArtifactId) -> String {
  guard id is ArtifactId(value) else { return "" }
  value
}

///|
pub fn artifact_object_relative_path(digest : @control.Digest) -> String {
  let value = digest_text(digest)
  if value.length() != 64 {
    ""
  } else {
    "sha256/" + value[:2].to_owned() + "/" + value
  }
}

///|
pub fn validate_artifact_adoption(
  request : ArtifactAdoptionRequest,
) -> Result[Unit, @types.ChoirError] {
  match validate_digest(request.expected_digest) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if artifact_digest(request.content) != request.expected_digest {
    return Err(
      @types.ChoirError::validation_error(
        "artifact content does not match the expected digest",
      ),
    )
  }
  match request.retention {
    ArtifactUntilTimestamp(timestamp) if timestamp <= 0L =>
      Err(
        @types.ChoirError::validation_error(
          "artifact retention timestamp must be positive",
        ),
      )
    _ => Ok(())
  }
}

///|
pub fn artifact_retention_expired(
  retention : ArtifactRetention,
  now : Int64,
  goal_terminal : (@control.GoalId) -> Bool,
) -> Bool {
  match retention {
    ArtifactPermanent => false
    ArtifactUntilGoalTerminal(goal_id) => goal_terminal(goal_id)
    ArtifactUntilTimestamp(timestamp) => now >= timestamp
  }
}

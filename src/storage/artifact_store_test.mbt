///|
test "artifact identity is content addressed and validates bytes" {
  let content = b"choir artifact"
  let digest = @storage.artifact_digest(content)
  let request : @storage.ArtifactAdoptionRequest = {
    content,
    expected_digest: digest,
    provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
    retention: @storage.ArtifactRetention::ArtifactPermanent,
  }
  assert_true(@storage.validate_artifact_adoption(request) is Ok(_))
  assert_eq(
    @storage.artifact_object_relative_path(digest),
    "sha256/02/02805abdc54a773078c146f800ae1cb890e8d0c4fe14dc293183450d44894e47",
  )
  assert_eq(
    @storage.artifact_id_text(@storage.artifact_id_for_digest(digest)),
    "sha256:02805abdc54a773078c146f800ae1cb890e8d0c4fe14dc293183450d44894e47",
  )
  assert_true(
    @storage.validate_artifact_adoption({ ..request, content: b"different" })
    is Err(_),
  )
}

///|
test "artifact retention decisions are typed and deterministic" {
  let goal_id = @control.GoalId("goal-1")
  assert_false(
    @storage.artifact_retention_expired(
      @storage.ArtifactRetention::ArtifactPermanent,
      100L,
      fn(_) { true },
    ),
  )
  assert_true(
    @storage.artifact_retention_expired(
      @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
      100L,
      fn(actual) { actual == goal_id },
    ),
  )
  assert_true(
    @storage.artifact_retention_expired(
      @storage.ArtifactRetention::ArtifactUntilTimestamp(100L),
      100L,
      fn(_) { false },
    ),
  )
}

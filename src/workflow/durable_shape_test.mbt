///|
/// Every line of the manifest.
///
/// The manifest is one line per path rather than one nested blob so that a
/// check can name an exact path. Searching a nested rendering for `,name:`
/// finds a same-named key three levels down and reports coverage that is not
/// there.
fn manifest_lines() -> Array[String] {
  let lines : Array[String] = []
  for line in @workflow.durable_value_shape_manifest().split("\n") {
    let text = line.to_owned()
    if text != "" {
      lines.push(text)
    }
  }
  lines
}

///|
/// The labels the manifest gives the immediate keys of one shape — `name`, or
/// `name?` where the type's own decoder tolerates the key being absent.
fn manifest_top_level_labels(
  lines : Array[String],
  shape : String,
) -> Array[String] {
  let prefix = shape + "."
  let labels : Array[String] = []
  for line in lines {
    if !line.has_prefix(prefix) {
      continue
    }
    let label = line[prefix.length():].to_owned().split(" = ").to_array()[0].to_owned()
    if label.contains(".") || label.contains("[") {
      continue
    }
    labels.push(label)
  }
  labels
}

///|
fn sorted_text(values : Array[String]) -> Array[String] {
  let ordered = [..values]
  ordered.sort_by(fn(left, right) { left.compare(right) })
  ordered
}

///|
/// The generation is what a store is compared against, and disagreeing with it
/// sends Choir off to read every durable record. So it has to be a digest of
/// the manifest and nothing else: an implementation that digested a label a
/// human maintains would be the hand-edited constant this replaced, wearing a
/// digest costume, and would pass a test that only checked the shape of the
/// string.
test "the generation is the digest of the manifest and nothing else" {
  assert_eq(
    @workflow.durable_value_shape_generation(),
    "choir-durable-shape-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode(@workflow.durable_value_shape_manifest()),
      ),
    ),
  )
}

///|
/// The failure this mechanism exists to catch and could not see before: a field
/// declared `T?` and a field declared `T` serialize identically when the
/// optional one is present, because MoonBit omits the key only for `None`. A
/// manifest built from the serialized witness alone therefore cannot tell a
/// required field from an optional one, so making a field required — a change
/// that stops every record written without it from decoding — would not move
/// the generation at all.
///
/// `GoalPublicationRecord` carries both cases at once: `intent` is required and
/// `receipt` is optional, both serialize to an object, and records really are
/// persisted with `receipt` absent while publication is pending.
test "the manifest tells an optional field from a required one" {
  let labels = manifest_top_level_labels(
    manifest_lines(),
    "GoalPublicationRecord#0",
  )
  assert_true(labels.contains("receipt?"))
  assert_false(labels.contains("receipt"))
  assert_true(labels.contains("intent"))
  assert_false(labels.contains("intent?"))
}

///|
/// Every record the control store holds under its own key prefix has to be in
/// the manifest. One that is missing is a record whose shape can change without
/// the generation moving, which is a store this build cannot read being adopted
/// as though it could.
/// The prefixes are written out rather than read back from the function under
/// test: they are an on-disk format. Renaming one leaves every record already
/// written under the old prefix where no scan and no loader will ever look
/// again, so the rename has to be a deliberate edit here as well.
test "the manifest covers every durably stored record" {
  let expected : Array[(@workflow.DurableRecordKind, String)] = [
    (DurablePartWorkflowSnapshot, "workflow:"),
    (DurablePartEffectWitness, "effect-witness:"),
    (DurableGoalExecutionRecord, "goal-run:"),
    (DurableGoalAssuranceRecord, "goal-assurance:"),
    (DurableGoalAssuranceEffectWitness, "goal-assurance-witness:"),
    (DurableGoalFinalizationRecord, "goal-finalization:"),
    (DurableGoalPublicationRecord, "goal-publication:"),
    (DurableGoalPullRequestRecord, "goal-pull-request:"),
    (DurableGoalSelectionDecision, "goal-selection:"),
    (DurableProcessExecution, "process-execution:"),
  ]
  assert_eq(expected.length(), @workflow.durable_record_kinds().length())
  let lines = manifest_lines()
  let prefixes : Array[String] = []
  for entry in expected {
    let shape = @workflow.durable_record_shape_name(entry.0)
    assert_eq(@workflow.durable_record_key_prefix(entry.0), entry.1)
    assert_true(@storage.validate_state_record_prefix(entry.1) is Ok(_))
    // Both in the manifest: the record type's shape, and the prefix its records
    // live under. Either moving is a change in what this build can read.
    assert_true(lines.contains(shape + "#0 = object"))
    assert_true(lines.contains("record " + shape + " = \"" + entry.1 + "\""))
    // One kind's prefix must not swallow another's, or a scan of the first
    // would try the wrong decoder on the second's records and report a store
    // this build reads perfectly well as unreadable.
    for other in prefixes {
      assert_false(entry.1.has_prefix(other))
      assert_false(other.has_prefix(entry.1))
    }
    prefixes.push(entry.1)
  }
}

///|
/// A stored snapshot with every optional field populated.
///
/// Driving the workflow reaches 32 of the 36 fields; the remaining four are
/// states a single snapshot cannot be in at once. They are filled here so that
/// the manifest can be checked against a snapshot that has every key, which is
/// what makes a witness field quietly left at `None` visible.
fn maximal_part_snapshot() -> @workflow.PartWorkflowSnapshot raise {
  let driven = drive_to_integration_authorized()
  {
    ..driven,
    part_context_manifest: Some({
      migration_contract_ref: {
        contract_id: @control.MigrationContractId("migration-contract-1"),
        migration_lineage_id: @control.MigrationLineageId("migration-lineage-1"),
        revision: 1,
        contract_artifact_digest: workflow_digest_a,
      },
      part_task_contract_revision_id: driven.task_contract.id,
      part_task_contract_digest: driven.task_contract.digest,
      context_assembly_policy_digest: workflow_digest_b,
      rulebook_section_digests: [workflow_digest_c],
      dependency_neighborhood_digest: workflow_digest_d,
      applicable_gap_entry_digests: [workflow_digest_e],
      source_path_manifest_digest: workflow_digest_a,
      prior_take_context_digest: Some(workflow_digest_b),
    }),
    pending_effect: Some({
      effect_id: @control.EffectId("effect-maximal-1"),
      kind: @workflow.PartEffectKind::PrepareVerificationSandbox(
        driven.identities.verification_sandbox,
      ),
      request_digest: workflow_digest_c,
      lifecycle: @workflow.PartEffectLifecycle::PartEffectPlanned,
    }),
    integration_receipt: Some({
      id: @control.IntegrationReceiptId("integration-receipt-1"),
      intent_id: @control.IntegrationIntentId("integration-intent-1"),
      goal_id: driven.goal.id,
      part_id: driven.part.id,
      candidate_id: @control.CandidateId("candidate-1"),
      candidate_commit_oid: @control.GitOid("candidate-commit"),
      candidate_tree_oid: @control.GitOid("candidate-tree"),
      from_head_oid: @control.GitOid("goal-head"),
      promotion_commit_oid: @control.GitOid("promotion-commit"),
      promotion_tree_oid: @control.GitOid("promotion-tree"),
      witness_ref: "refs/choir/witness/integration-intent-1",
      integrated_at: 27L,
    }),
    dispatch_diagnostic: Some({
      take_id: driven.implementation_take.id,
      session_id: Some(@control.HarnessSessionId("harness-session-1")),
      reason: Some(@control.TakeUncertaintyReason::TakeEffectUncertain),
      detail: "dispatch failed",
      recovery: Some("no evidence the Take ran"),
      availability: @control.ProviderAvailability::ProviderAllowanceExhausted(
        Some(30L),
      ),
      observed_at: 29L,
    }),
  }
}

///|
/// The witness has to serialize the same keys the real record does, or the
/// generation describes a shape nothing stores and stops moving when that key's
/// type changes.
///
/// The oracle is a record the workflow itself produced with every optional
/// field populated, not a second hand-written list, and the comparison is an
/// exact set: a key the manifest describes and the record does not have is a
/// witness that drifted, and a manifest missing a key the record has is a
/// witness whose option was quietly left at `None`.
///
/// Nothing here is specific to one type, so every stored type that has a
/// maximal instance somewhere in this suite is checked through this function
/// at the point that instance exists.
fn assert_manifest_names_stored_keys(
  shape : String,
  content : Bytes,
) -> Unit raise {
  let fields = match @json.parse(@utf8.decode_lossy(content)) {
    Json::Object(value) => value
    _ => fail(shape + " does not serialize to an object")
  }
  let observed : Array[String] = []
  for key in fields.keys() {
    observed.push(key)
  }
  let labels = manifest_top_level_labels(manifest_lines(), shape + "#0")
  guard labels.length() > 0 else { fail(shape + " is not in the manifest") }
  let described : Array[String] = []
  for label in labels {
    described.push(
      if label.has_suffix("?") {
        label[:label.length() - 1].to_owned()
      } else {
        label
      },
    )
  }
  assert_eq(sorted_text(described), sorted_text(observed))
}

///|
test "the manifest names exactly the keys a stored snapshot serializes" {
  assert_manifest_names_stored_keys(
    "PartWorkflowSnapshot",
    @workflow.part_snapshot_bytes(maximal_part_snapshot()),
  )
}

///|
test "the manifest names exactly the keys a stored execution serializes" {
  assert_manifest_names_stored_keys(
    "GoalExecutionRecord",
    @workflow.goal_execution_record_bytes(maximal_goal_execution_record()),
  )
}

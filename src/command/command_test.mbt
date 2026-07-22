///|
fn fixture_digest(value : String) -> @control.Digest {
  @control.Digest(
    @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(value))),
  )
}

///|
fn fixture_context(value : String) -> @command.CommandContextArtifact {
  { digest: fixture_digest(value), content: @utf8.encode(value) }
}

///|
fn fixture_contract_ref() -> @control.MigrationContractRef {
  {
    contract_id: @control.MigrationContractId("migration-1"),
    migration_lineage_id: @control.MigrationLineageId("lineage-1"),
    revision: 3,
    contract_artifact_digest: fixture_digest("migration contract"),
  }
}

///|
fn fixture_manifest() -> @migration.PartContextManifest {
  {
    migration_contract_ref: fixture_contract_ref(),
    part_task_contract_revision_id: @control.RevisionId("task-revision-1"),
    part_task_contract_digest: fixture_digest("task contract"),
    context_assembly_policy_digest: fixture_digest("context policy"),
    rulebook_section_digests: [fixture_digest("rulebook section")],
    dependency_neighborhood_digest: fixture_digest("dependency neighborhood"),
    applicable_gap_entry_digests: [fixture_digest("gap entry")],
    source_path_manifest_digest: fixture_digest("source path manifest"),
    prior_take_context_digest: None,
  }
}

///|
fn fixture_request() -> @command.CommandPreparationRequest {
  let template_text = "Follow the supplied task and repository rules."
  {
    schema_version: 1,
    take: {
      id: @control.TakeId("implementation-take-1"),
      goal_id: @control.GoalId("goal-1"),
      purpose: @control.TakePurpose::Implementation(
        @control.PartId("part-1"),
        @control.RevisionId("task-revision-1"),
      ),
      ordinal: 1,
      fencing_epoch: Some(@control.FencingEpoch(4L)),
      lifecycle: @control.TakeLifecycle::TakeRunning,
    },
    subject: @command.CommandExecutionSubject::ImplementationCommandSubject(
      @control.PartId("part-1"),
      @control.RevisionId("task-revision-1"),
      fixture_digest("task contract"),
    ),
    goal_contract_digest: fixture_digest("goal contract"),
    task_contract_revision_id: @control.RevisionId("task-revision-1"),
    task_contract_digest: fixture_digest("task contract"),
    instruction_artifact_digest: fixture_digest("Implement the exact task."),
    migration_contract_ref: Some(fixture_contract_ref()),
    provider_surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    provider_surface_and_profile_digest: fixture_digest("provider profile"),
    context_assembly_policy_digest: fixture_digest("context policy"),
    context_manifest: Some(fixture_manifest()),
    template: {
      schema_version: 1,
      role: @command.CommandRole::ImplementationCommand,
      digest: fixture_digest(template_text),
      content: @utf8.encode(template_text),
    },
    context_artifacts: [
      fixture_context("Implement the exact task."),
      fixture_context("migration contract"),
      fixture_context("rulebook section"),
      fixture_context("dependency neighborhood"),
      fixture_context("gap entry"),
      fixture_context("source path manifest"),
    ],
    maximum_command_bytes: 16384,
  }
}

///|
test "command canonical encoders have fixed versioned byte fixtures" {
  let prepared = @command.prepare_command(fixture_request()).unwrap()
  inspect(
    @utf8.decode_lossy(
      @command.canonical_take_purpose_bytes(fixture_request().take.purpose),
    ),
    content="21#choir.take-purpose.v11#314#implementation6#part-115#task-revision-1",
  )
  inspect(
    @utf8.decode_lossy(
      @command.canonical_command_subject_bytes(fixture_request().subject),
    ),
    content="24#choir.command-subject.v11#414#implementation6#part-115#task-revision-164#358dfd98b7d3b94a713eac2f06b153539b989acd114c496cfbc67a367301eebc",
  )
  inspect(
    @utf8.decode_lossy(
      @command.canonical_command_provenance_bytes(prepared.provenance),
    ),
    content="39#choir.command-preparation-provenance.v12#191#121#implementation-take-164#9597229b200d93c4b1933d7b632d1ffcd4c5b00093115715825696f288d8e31964#2a4503b89032c97bff72d4e4ec3d4e76aea8b062fe827e0dd46acb2ce64b94b564#d65c724d5e14c60388589f6599fea5e3590de112c39f1dcef0128c6fe3761ad315#task-revision-164#358dfd98b7d3b94a713eac2f06b153539b989acd114c496cfbc67a367301eebc4#some132#31#choir.migration-contract-ref.v11#411#migration-19#lineage-11#364#56497acc72dcc8dd980e65a98a22468ea2e472588bde2f09be7f57c331f5567864#f8217dceef577751d3f709e7556044371a88d7fd64c4741d808fca03b8ae730822#codex-subscription-cli64#1a3cb2de07a9667b3b3f1ebd7b11b5a854f8f7df39783976218fe7d829c612f064#b93804d84f0540513da73472f8e285c69012ef2029a27af6ecd7e2b44fcd5f1a4#some64#2b6aa50d6d876fcd952f67aae8c500ec5bd1662c4151c768ae42c0ac80b011ef64#962be26b738ed5c8d4bb08d1826aeca215a1230c0496b90a57cbc9deef85952f5#1638464#a661bac2fdc9156a59ef38ccf15cc8716a08258684001d4275a5ef98b5679a544#1480",
  )
}

///|
test "command preparation is deterministic and byte complete" {
  let first = @command.prepare_command(fixture_request()).unwrap()
  let replay = @command.prepare_command(fixture_request()).unwrap()
  assert_eq(first, replay)
  assert_eq(
    first.provenance.command_artifact_digest,
    fixture_digest(@utf8.decode_lossy(first.command_bytes)),
  )
  let without_rulebook = {
    ..fixture_request(),
    context_artifacts: fixture_request().context_artifacts.filter(fn(value) {
      value.digest != fixture_digest("rulebook section")
    }),
  }
  match @command.prepare_command(without_rulebook) {
    Err(error) => assert_true(error.is_command_preparation_blocked())
    Ok(_) => fail("missing required context must block preparation")
  }
}

///|
test "command preparation reports stale, corrupt, and oversized inputs" {
  let stale = {
    ..fixture_request(),
    task_contract_digest: fixture_digest("stale task contract"),
  }
  assert_true(@command.prepare_command(stale) is Err(_))
  let contexts = fixture_request().context_artifacts.copy()
  contexts[0] = { ..contexts[0], content: @utf8.encode("corrupt") }
  assert_true(
    @command.prepare_command({
      ..fixture_request(),
      context_artifacts: contexts,
    })
    is Err(_),
  )
  assert_true(
    @command.prepare_command({ ..fixture_request(), maximum_command_bytes: 64 })
    is Err(_),
  )
}

///|
test "property: context input ordering cannot change prepared bytes" {
  @quickcheck.quick_check_fn(
    fn(reverse : Bool) -> Bool {
      let request = fixture_request()
      let contexts = if reverse {
        request.context_artifacts.rev()
      } else {
        request.context_artifacts
      }
      match
        (
          @command.prepare_command(request),
          @command.prepare_command({ ..request, context_artifacts: contexts }),
        ) {
        (Ok(left), Ok(right)) => left == right
        _ => false
      }
    },
    max_success=128,
    max_size=8,
  )
}

///|
test "Conductor draft decodes friendly provider and verification fields" {
  let draft = match
    @workflow.decode_conductor_goal_draft(
      (
        #|{
        #|  "proposal_id": "proposal-1",
        #|  "goal_id": "goal-1",
        #|  "maximum_parallel_parts": 2,
        #|  "parts": [
        #|    {
        #|      "part_id": "choir-a",
        #|      "instruction": "Change the answer.",
        #|      "provider": "claude",
        #|      "exact_paths": ["src/a.mbt"],
        #|      "moon_args": ["test", "--target", "native", "src/a.mbt"]
        #|    },
        #|    {
        #|      "part_id": "choir-b",
        #|      "instruction": "Change the other answer.",
        #|      "provider": "codex",
        #|      "path_trees": ["src/b"],
        #|      "moon_args": ["test", "--target", "native", "src/b"]
        #|    }
        #|  ]
        #|}
      ),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(draft.parts.length(), 2)
  assert_eq(
    draft.parts[0].provider_surface,
    @control.ProviderSurfaceId::ClaudeSubscriptionCli,
  )
  assert_eq(
    draft.parts[1].provider_surface,
    @control.ProviderSurfaceId::CodexSubscriptionCli,
  )
  assert_eq(draft.parts[0].verification.timeout_ms, 120000L)
  assert_eq(draft.parts[0].migration_contract_ref, None)
  assert_eq(
    draft.completion_mode,
    @workflow.GoalCompletionMode::GoalPublishable,
  )
}

///|
test "Conductor draft binds exact evidence-only completion" {
  let draft = @workflow.decode_conductor_goal_draft(
    (
      #|{"proposal_id":"p","goal_id":"g","completion_mode":"evidence_only","evidence_only_binding_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","maximum_parallel_parts":1,"parts":[{"part_id":"a","instruction":"x","provider":"codex","repository_wide":true,"moon_args":["test"]}]}
    ),
  ).unwrap()
  assert_eq(
    draft.completion_mode,
    @workflow.GoalCompletionMode::GoalEvidenceOnly(
      @control.Digest(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      ),
    ),
  )
  assert_true(
    @workflow.decode_conductor_goal_draft(
      (
        #|{"proposal_id":"p","goal_id":"g","completion_mode":"evidence_only","maximum_parallel_parts":1,"parts":[{"part_id":"a","instruction":"x","provider":"codex","repository_wide":true,"moon_args":["test"]}]}
      ),
    )
    is Err(_),
  )
}

///|
test "Conductor Part draft carries one exact migration contract reference" {
  let draft = @workflow.decode_conductor_goal_draft(
    (
      #|{"proposal_id":"p","goal_id":"g","maximum_parallel_parts":1,"parts":[{"part_id":"a","instruction":"x","provider":"codex","repository_wide":true,"moon_args":["test"],"migration_contract_id":"contract-1","migration_lineage_id":"lineage-1","migration_contract_revision":3,"migration_contract_artifact_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","context_assembly_policy_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","rulebook_section_digests":["cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"],"dependency_neighborhood_digest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","applicable_gap_entry_digests":[],"source_path_manifest_digest":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}]}
    ),
  ).unwrap()
  assert_eq(
    draft.parts[0].migration_contract_ref,
    Some({
      contract_id: @control.MigrationContractId("contract-1"),
      migration_lineage_id: @control.MigrationLineageId("lineage-1"),
      revision: 3,
      contract_artifact_digest: @control.Digest(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      ),
    }),
  )
  assert_true(draft.parts[0].migration_context is Some(_))
  assert_true(
    @workflow.decode_conductor_goal_draft(
      (
        #|{"proposal_id":"p","goal_id":"g","maximum_parallel_parts":1,"parts":[{"part_id":"a","instruction":"x","provider":"codex","repository_wide":true,"moon_args":["test"],"migration_contract_id":"contract-1"}]}
      ),
    )
    is Err(_),
  )
}

///|
test "Conductor draft rejects unknown fields and ambiguous mutation scope" {
  match
    @workflow.decode_conductor_goal_draft(
      (
        #|{"proposal_id":"p","goal_id":"g","maximum_parallel_parts":1,"surprise":true,"parts":[]}
      ),
    ) {
    Err(error) => {
      assert_true(error.message().contains("unknown fields: surprise"))
      assert_true(error.message().contains("allowed fields: proposal_id"))
    }
    Ok(_) => fail("unknown Goal field was accepted")
  }
  match
    @workflow.decode_conductor_goal_draft(
      (
        #|{"proposal_id":"p","goal_id":"g","maximum_parallel_parts":1,"parts":[{"part_id":"a","instruction":"x","provider":"codex","repository_wide":true,"moon_args":["test"],"command":"moon test","dependencies":[]}]}
      ),
    ) {
    Err(error) => {
      assert_true(
        error.message().contains("unknown fields: command, dependencies"),
      )
      assert_true(error.message().contains("allowed fields: part_id"))
    }
    Ok(_) => fail("unknown Part fields were accepted")
  }
  assert_true(
    @workflow.decode_conductor_goal_draft(
      (
        #|{"proposal_id":"p","goal_id":"g","maximum_parallel_parts":1,"parts":[{"part_id":"a","instruction":"x","provider":"codex","repository_wide":true,"exact_paths":["src/a"],"moon_args":["test"]}]}
      ),
    )
    is Err(_),
  )
}

///|
test "Conductor draft rejects the Moon executable inside moon_args" {
  match
    @workflow.decode_conductor_goal_draft(
      (
        #|{"proposal_id":"p","goal_id":"g","maximum_parallel_parts":1,"parts":[{"part_id":"a","instruction":"x","provider":"codex","repository_wide":true,"moon_args":["moon","test","--target","native"]}]}
      ),
    ) {
    Err(error) =>
      assert_true(
        error.message().contains("moon_args must start with a Moon subcommand"),
      )
    Ok(_) => fail("Moon executable was accepted as its own first argument")
  }
}

///|
test "Conductor draft rejects Git refs owned by choird" {
  match
    @workflow.decode_conductor_goal_draft(
      (
        #|{"proposal_id":"p","goal_id":"g","base_ref":"refs/heads/guessed","integration_target_ref":"refs/heads/guessed","maximum_parallel_parts":1,"parts":[]}
      ),
    ) {
    Err(error) =>
      assert_true(
        error
        .message()
        .contains("unknown fields: base_ref, integration_target_ref"),
      )
    Ok(_) => fail("Conductor-owned Git refs were accepted")
  }
}

///|
test "Beads capture snapshots blocking dependencies and relevant revisions" {
  let snapshot = match
    @workflow.goal_selection_snapshot_from_beads_json(
      @workflow.RepositoryId("repository-1"),
      @control.GitOid("base-commit"),
      @control.GitOid("base-tree"),
      (
        #|[
        #|  {
        #|    "id":"choir-a",
        #|    "title":"Dependency A",
        #|    "description":"First task",
        #|    "acceptance_criteria":"A passes",
        #|    "status":"open",
        #|    "priority":2,
        #|    "issue_type":"task",
        #|    "dependency_count":0,
        #|    "updated_at":"2026-07-20T00:00:00Z"
        #|  },
        #|  {
        #|    "id":"choir-b",
        #|    "title":"Dependent B",
        #|    "description":"Second task",
        #|    "acceptance_criteria":"B passes",
        #|    "status":"open",
        #|    "priority":2,
        #|    "issue_type":"task",
        #|    "dependency_count":1,
        #|    "updated_at":"2026-07-20T00:00:01Z",
        #|    "dependencies":[
        #|      {
        #|        "id":"choir-a",
        #|        "title":"Dependency A",
        #|        "description":"First task",
        #|        "acceptance_criteria":"A passes",
        #|        "status":"open",
        #|        "priority":2,
        #|        "issue_type":"task",
        #|        "updated_at":"2026-07-20T00:00:00Z",
        #|        "dependency_type":"blocks"
        #|      }
        #|    ]
        #|  }
        #|]
      ),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(snapshot.parts.length(), 2)
  assert_eq(snapshot.parts[1].part_id, @control.PartId("choir-b"))
  assert_eq(snapshot.parts[1].dependency_ids, [@control.PartId("choir-a")])
  assert_eq(
    snapshot.parts[0].state,
    @workflow.SelectionSourceState::SelectionSourceOpen,
  )
}

///|
test "Beads capture rejects incomplete dependency details" {
  let malformed =
    #|[{"id":"choir-b","title":"Dependent B","status":"open","priority":2,"issue_type":"task","updated_at":"2026-07-20T00:00:01Z","dependency_count":1}]
  assert_true(
    @workflow.goal_selection_snapshot_from_beads_json(
      @workflow.RepositoryId("repository-1"),
      @control.GitOid("base-commit"),
      @control.GitOid("base-tree"),
      malformed,
    )
    is Err(_),
  )
}

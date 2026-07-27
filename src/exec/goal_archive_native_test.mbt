///|
/// The finalization identity a succeeded record must carry, recomputed from
/// the same formula `goal_execution_lifecycle` uses. A record whose lifecycle
/// disagrees with its state does not decode, so this is what lets the test
/// persist a terminal Goal without driving the whole state machine.
fn archive_succeeded_lifecycle(
  goal_id : @control.GoalId,
) -> @control.GoalLifecycle {
  @control.GoalLifecycle::GoalSucceeded(
    @control.FinalizationId(
      "finalization-" +
      @storage.digest_text(
        @storage.artifact_digest(
          @utf8.encode("choir.goal-execution.v1\u{00}" + goal_id.0),
        ),
      ),
    ),
  )
}

///|
fn archive_native_repository(
  root : String,
) -> (
  @workflow.PartWorkflowRepository,
  @workflow.PartWorkflowRepositoryAdapters,
) raise {
  ignore(@sys.rm_rf(root))
  assert_true(@sys.create_dir_all(root + "/.choir/state/control"))
  let repository = native_goal_repository(root)
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  (repository, adapters)
}

///|
fn archive_native_queued_record() -> @workflow.GoalExecutionRecord raise {
  let decision = selection_store_decision()
  match
    @workflow.goal_execution_record_from_selection(
      decision,
      @workflow.goal_selection_decision_digest(decision),
      [@control.WorkflowId("workflow-archive")],
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
}

///|
/// A Goal that reached a terminal state necessarily initialized its branch,
/// and the record decoder enforces exactly that. Receipting the initialization
/// here is what makes the persisted terminal record a real one.
fn archive_native_initialized(
  record : @workflow.GoalExecutionRecord,
) -> @workflow.GoalExecutionRecord {
  let initialization = record.branch_initialization
  {
    ..record,
    branch_initialization: {
      ..initialization,
      lifecycle: @workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted,
      receipt: Some({
        intent_id: initialization.intent_id,
        idempotency_key: initialization.idempotency_key,
        repository_id: initialization.repository_id,
        goal_ref: initialization.goal_ref,
        initialized_oid: initialization.captured_base_oid,
        initialization_witness_ref: initialization.initialization_witness_ref,
        observed_at: 1L,
      }),
    },
  }
}

///|
fn archive_native_persist(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  record : @workflow.GoalExecutionRecord,
) -> Unit raise {
  match
    @workflow.persist_goal_execution_record(repository, adapters, {
      record,
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
}

///|
/// The daemon reads a Conductor's park from the top-level `goal_id` and
/// `state` of any `goal_` response, and an unrecognized state parks. An
/// archive response that hid them would park a Conductor on a Goal that had
/// already finished.
test "an archive response names the terminal state the park reads" {
  let plan : @workflow.GoalArchivePlan = {
    goal_id: @control.GoalId("goal-response"),
    state: @workflow.GoalExecutionState::GoalExecutionSucceeded,
    release_runtime_root: true,
    release_refs: [@workflow.GitRefName("refs/choir/goals/abc/initialized")],
    release_artifacts: [],
    retain_refs: [@workflow.GitRefName("refs/heads/choir/goals/abc")],
    retain_artifacts: [],
  }
  let fields = native_goal_archive_response_fields(
    plan,
    {
      decision: @workflow.GoalArchiveDecision::GoalArchivePlanned(plan),
      applied: true,
      runtime_root_removed: true,
      refs_removed: 1,
      artifacts_released: 0,
    },
    dry_run=false,
  )
  // Either shape the daemon's park resolution accepts: a bare id or the
  // tagged newtype every other Goal response carries.
  assert_true(
    match fields.get("goal_id") {
      Some(String("goal-response"))
      | Some(Array([String(_), String("goal-response")])) => true
      _ => false
    },
  )
  assert_eq(
    @workflow.parse_goal_execution_state(
      match fields.get("state") {
        Some(String(tag)) => tag
        _ => ""
      },
    ),
    Some(@workflow.GoalExecutionState::GoalExecutionSucceeded),
  )
  assert_false(
    @workflow.conductor_park_for_goal_state(
      @workflow.parse_goal_execution_state(
        match fields.get("state") {
          Some(String(tag)) => tag
          _ => ""
        },
      ),
    ),
  )
  assert_eq(fields.get("archived"), Some(true.to_json()))
  assert_eq(fields.get("dry_run"), Some(false.to_json()))
  assert_eq(fields.get("refs_removed"), Some((1).to_json()))
}

///|
/// Drive a whole archive against a real durable store: a persisted terminal
/// Goal, real adopted content under three different retentions, and a real
/// retention ledger. Only the Git surface is injected, so the test never needs
/// a repository on disk.
async test "an archived Goal releases only its own expired content" {
  let root = "/tmp/choir-goal-archive-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let queued = archive_native_queued_record()
  let goal_id = queued.goal.id
  archive_native_persist(
    repository,
    adapters,
    archive_native_initialized({
      ..queued,
      state: @workflow.GoalExecutionState::GoalExecutionSucceeded,
      goal: { ..queued.goal, lifecycle: archive_succeeded_lifecycle(goal_id) },
    }),
  )
  let adopt = fn(content : String, retention : @storage.ArtifactRetention) {
    let bytes = @utf8.encode(content)
    adopt_artifact(repository.artifact_store, {
      content: bytes,
      expected_digest: @storage.artifact_digest(bytes),
      provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
      retention,
    }).unwrap().digest
  }
  let mine = adopt(
    "archive-mine",
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  )
  // The same content, also kept until a Goal that is not recorded here has
  // finished. Nothing may release it on this Goal's behalf.
  let shared = adopt(
    "archive-shared",
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  )
  ignore(
    adopt(
      "archive-shared",
      @storage.ArtifactRetention::ArtifactUntilGoalTerminal(
        @control.GoalId("goal-live"),
      ),
    ),
  )
  let permanent = adopt(
    "archive-permanent",
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  )
  ignore(
    adopt("archive-permanent", @storage.ArtifactRetention::ArtifactPermanent),
  )
  let branch = queued.goal_ref
  let witness = queued.branch_initialization.initialization_witness_ref
  let part_witness = @workflow.GitRefName("refs/choir/witness/part-archive")
  let deleted : Array[@workflow.GitRefName] = []
  let mut cleanups = 0
  let list_refs = async fn(_project_dir : String) {
    @async.sleep(0)
    Ok([branch, witness, part_witness])
  }
  let delete_refs = async fn(
    _project_dir : String,
    references : Array[@workflow.GitRefName],
  ) {
    @async.sleep(0)
    for reference in references {
      deleted.push(reference)
    }
    Ok(references.length())
  }
  let cleanup_runtime = async fn(
    _repository_id : @workflow.RepositoryId,
    _goal_id : @control.GoalId,
  ) {
    @async.sleep(0)
    cleanups = cleanups + 1
    Ok(())
  }
  let preview = match
    archive_native_goal(
      root,
      goal_id,
      dry_run=true,
      now=1_000L,
      list_refs~,
      delete_refs~,
      cleanup_runtime~,
    ) {
    Ok(value) => value
    Err(error) => fail("preview: " + error.message())
  }
  assert_false(preview.applied)
  guard preview.decision
    is @workflow.GoalArchiveDecision::GoalArchivePlanned(planned) else {
    fail("a succeeded Goal was refused archival")
  }
  assert_eq(planned.release_refs, [witness])
  assert_eq(planned.retain_refs, [branch])
  assert_eq(planned.release_artifacts, [mine])
  assert_eq(planned.retain_artifacts, [shared, permanent])
  // A dry run reports and stops.
  assert_eq(deleted, [])
  assert_eq(cleanups, 0)
  assert_true(artifact_store_contains(repository.artifact_store, mine).unwrap())
  let applied = archive_native_goal(
    root,
    goal_id,
    dry_run=false,
    now=1_000L,
    list_refs~,
    delete_refs~,
    cleanup_runtime~,
  ).unwrap()
  assert_true(applied.applied)
  assert_eq(applied.decision, preview.decision)
  assert_eq(deleted, [witness])
  assert_eq(applied.refs_removed, 1)
  assert_eq(applied.artifacts_released, 1)
  // No runtime root was observed, so none was reclaimed.
  assert_false(applied.runtime_root_removed)
  assert_eq(cleanups, 0)
  assert_false(
    artifact_store_contains(repository.artifact_store, mine).unwrap(),
  )
  assert_true(
    artifact_store_contains(repository.artifact_store, shared).unwrap(),
  )
  assert_true(
    artifact_store_contains(repository.artifact_store, permanent).unwrap(),
  )
  // Archiving is not deleting: the durable record still loads, which is what
  // makes the Goal's outcome readable after its working storage is gone.
  match @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(stored)) =>
      assert_eq(
        stored.record.state,
        @workflow.GoalExecutionState::GoalExecutionSucceeded,
      )
    Ok(None) => fail("archiving deleted the durable Goal record")
    Err(error) => fail(error.message())
  }
  ignore(@sys.rm_rf(root))
}

///|
async test "a refused archive touches nothing" {
  let root = "/tmp/choir-goal-archive-refused-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let queued = archive_native_queued_record()
  let goal_id = queued.goal.id
  archive_native_persist(repository, adapters, queued)
  let bytes = @utf8.encode("archive-refused")
  let digest = @storage.artifact_digest(bytes)
  adopt_artifact(repository.artifact_store, {
    content: bytes,
    expected_digest: digest,
    provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
    retention: @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  }).unwrap()
  |> ignore
  let witness = queued.branch_initialization.initialization_witness_ref
  let deleted : Array[@workflow.GitRefName] = []
  let report = archive_native_goal(
    root,
    goal_id,
    dry_run=false,
    now=1_000L,
    list_refs=async fn(_project_dir : String) {
      @async.sleep(0)
      Ok([witness])
    },
    delete_refs=async fn(
      _project_dir : String,
      references : Array[@workflow.GitRefName],
    ) {
      @async.sleep(0)
      for reference in references {
        deleted.push(reference)
      }
      Ok(references.length())
    },
    cleanup_runtime=async fn(
      _repository_id : @workflow.RepositoryId,
      _goal_id : @control.GoalId,
    ) {
      @async.sleep(0)
      Ok(())
    },
  ).unwrap()
  assert_eq(
    report.decision,
    @workflow.GoalArchiveDecision::GoalArchiveRefused(
      @workflow.GoalArchiveRefusal::GoalArchiveGoalActive(
        @workflow.GoalExecutionState::GoalExecutionQueued,
      ),
    ),
  )
  assert_false(report.applied)
  assert_eq(deleted, [])
  assert_true(
    artifact_store_contains(repository.artifact_store, digest).unwrap(),
  )
  ignore(@sys.rm_rf(root))
}

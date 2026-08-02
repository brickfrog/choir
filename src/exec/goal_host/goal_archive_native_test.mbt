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
  let adapters = @storage_host.local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => fail(error.message())
  }
  (repository, adapters)
}

///|
fn archive_native_queued_record(
  label? : String = "selection-store",
) -> @workflow.GoalExecutionRecord raise {
  let decision = selection_store_decision(label~)
  match
    @workflow.goal_execution_record_from_selection(
      decision,
      @workflow.goal_selection_decision_digest(decision),
      [@control.WorkflowId("workflow-" + label)],
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
/// The same record, moved to a succeeded terminal state.
fn archive_native_succeeded(
  record : @workflow.GoalExecutionRecord,
) -> @workflow.GoalExecutionRecord {
  archive_native_initialized({
    ..record,
    state: @workflow.GoalExecutionState::GoalExecutionSucceeded,
    goal: {
      ..record.goal,
      lifecycle: archive_succeeded_lifecycle(record.goal.id),
    },
  })
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
fn archive_native_adopt(
  repository : @workflow.PartWorkflowRepository,
  content : String,
  retention : @storage.ArtifactRetention,
) -> @control.Digest {
  let bytes = @utf8.encode(content)
  @storage_host.adopt_artifact(repository.artifact_store, {
    content: bytes,
    expected_digest: @storage.artifact_digest(bytes),
    provenance: @storage.ArtifactProvenance::ArtifactConformanceEvidence,
    retention,
  }).unwrap().digest
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
      refs_removed: 1,
      artifacts_released: 0,
      outbox_events_released: 0,
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
/// Drive a whole archive against a real durable store: two persisted Goals —
/// one succeeded, one still queued — real adopted content under three
/// different retentions, and a real retention ledger. Only the Git surface is
/// injected, so the test never needs a repository on disk.
///
/// The live Goal is *recorded*, which is the point. `archive_native_goal`
/// builds its terminality answer by walking the durable records, and a live
/// Goal that is absent from the store answers "not terminal" whether or not
/// that walk checks anything. Persisting a queued record is what makes the
/// check load-bearing: drop the state guard and the shared content below
/// becomes collectable.
async test "an archived Goal releases only its own expired content" {
  let root = "/tmp/choir-goal-archive-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let terminal = archive_native_queued_record(label="archive-terminal")
  let goal_id = terminal.goal.id
  archive_native_persist(
    repository,
    adapters,
    archive_native_succeeded(terminal),
  )
  let live = archive_native_queued_record(label="archive-live")
  let live_goal_id = live.goal.id
  archive_native_persist(repository, adapters, live)
  let mine = archive_native_adopt(
    repository,
    "archive-mine",
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  )
  // The same content, also kept until the queued Goal finishes. Nothing may
  // release it on the archived Goal's behalf while that Goal is still moving.
  let shared = archive_native_adopt(
    repository,
    "archive-shared",
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  )
  ignore(
    archive_native_adopt(
      repository,
      "archive-shared",
      @storage.ArtifactRetention::ArtifactUntilGoalTerminal(live_goal_id),
    ),
  )
  let permanent = archive_native_adopt(
    repository,
    "archive-permanent",
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  )
  ignore(
    archive_native_adopt(
      repository,
      "archive-permanent",
      @storage.ArtifactRetention::ArtifactPermanent,
    ),
  )
  let branch = terminal.goal_ref
  let witness = terminal.branch_initialization.initialization_witness_ref
  // Both refs the live Goal owns are inside the namespaces production's
  // `for-each-ref` enumerates, so an archive really does see them. Neither is
  // the archived Goal's to release.
  let live_branch = live.goal_ref
  let live_witness = live.branch_initialization.initialization_witness_ref
  let listed = @ref.new([branch, witness, live_branch, live_witness])
  let deleted : Array[@workflow.GitRefName] = []
  let list_refs = async fn(_project_dir : String) {
    @async.sleep(0)
    Ok(listed.val)
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
  let preview = match
    archive_native_goal(
      root,
      goal_id,
      dry_run=true,
      now=1_000L,
      list_refs~,
      delete_refs~,
    ) {
    Ok(value) => value
    Err(error) => fail("preview: " + error.message())
  }
  assert_false(preview.applied)
  assert_eq(preview.outbox_events_released, 0)
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
  assert_true(
    @storage_host.artifact_store_contains(repository.artifact_store, mine).unwrap(),
  )
  let applied = archive_native_goal(
    root,
    goal_id,
    dry_run=false,
    now=1_000L,
    list_refs~,
    delete_refs~,
  ).unwrap()
  assert_true(applied.applied)
  assert_eq(applied.decision, preview.decision)
  assert_eq(deleted, [witness])
  assert_eq(applied.refs_removed, 1)
  assert_eq(applied.artifacts_released, 1)
  assert_true(applied.outbox_events_released > 0)
  assert_false(
    @storage_host.artifact_store_contains(repository.artifact_store, mine).unwrap(),
  )
  assert_true(
    @storage_host.artifact_store_contains(repository.artifact_store, shared).unwrap(),
  )
  assert_true(
    @storage_host.artifact_store_contains(repository.artifact_store, permanent).unwrap(),
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
  // Archiving is idempotent, which is why it mints no durable marker. Re-run
  // it against a repository that reflects the deletion: the plan is empty, it
  // still applies, and it removes nothing a second time.
  listed.val = [branch, live_branch, live_witness]
  let again = archive_native_goal(
    root,
    goal_id,
    dry_run=false,
    now=1_000L,
    list_refs~,
    delete_refs~,
  ).unwrap()
  assert_true(again.applied)
  guard again.decision
    is @workflow.GoalArchiveDecision::GoalArchivePlanned(replanned) else {
    fail("an archived Goal was refused a second archive")
  }
  assert_eq(replanned.release_refs, [])
  assert_eq(replanned.release_artifacts, [])
  assert_eq(replanned.retain_refs, [branch])
  assert_eq(replanned.retain_artifacts, [shared, permanent])
  assert_eq(again.refs_removed, 0)
  assert_eq(again.artifacts_released, 0)
  assert_eq(again.outbox_events_released, 0)
  assert_eq(deleted, [witness])
  assert_true(
    @storage_host.artifact_store_contains(repository.artifact_store, shared).unwrap(),
  )
  ignore(@sys.rm_rf(root))
}

///|
/// Reproduce the scan's exact plan-to-delete interleaving deterministically:
/// the archive observes one expired retention, then another active Goal adopts
/// the same digest before collection reaches its destructive sink.
async test "archive revalidates a concurrent adoption before collection" {
  let root = "/tmp/choir-goal-archive-race-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  defer ignore(@sys.rm_rf(root))
  let terminal = archive_native_queued_record(label="archive-race-terminal")
  let goal_id = terminal.goal.id
  archive_native_persist(
    repository,
    adapters,
    archive_native_succeeded(terminal),
  )
  let live = archive_native_queued_record(label="archive-race-live")
  archive_native_persist(repository, adapters, live)
  let digest = archive_native_adopt(
    repository,
    "archive-race-shared",
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  )
  let adopted_during_archive = @ref.new(false)
  let report = archive_native_goal(
    root,
    goal_id,
    dry_run=false,
    now=1_000L,
    list_refs=async fn(_) {
      @async.sleep(0)
      Ok([
        terminal.goal_ref,
        terminal.branch_initialization.initialization_witness_ref,
      ])
    },
    delete_refs=async fn(_, references) {
      @async.sleep(0)
      ignore(
        archive_native_adopt(
          repository,
          "archive-race-shared",
          @storage.ArtifactRetention::ArtifactUntilGoalTerminal(live.goal.id),
        ),
      )
      adopted_during_archive.val = true
      Ok(references.length())
    },
  ).unwrap()
  assert_true(adopted_during_archive.val)
  guard report.decision
    is @workflow.GoalArchiveDecision::GoalArchivePlanned(plan) else {
    fail("terminal Goal was refused archival")
  }
  @debug.assert_eq(plan.release_artifacts, [digest])
  assert_eq(report.artifacts_released, 0)
  assert_true(
    @storage_host.artifact_store_contains(repository.artifact_store, digest).unwrap(),
  )
  assert_eq(
    @utf8.decode_lossy(
      @storage_host.read_artifact(repository.artifact_store, {
        digest,
        max_bytes: 1024,
      }).unwrap(),
    ),
    "archive-race-shared",
  )
  let ledger = @storage_host.read_artifact_retention_ledger(
    repository.artifact_store,
  ).unwrap()
  let matching = ledger.filter(fn(entry) { entry.digest == digest })
  guard matching.length() == 1 else { fail("shared retention disappeared") }
  let entry = matching[0]
  assert_true(
    entry.retentions.contains(
      @storage.ArtifactRetention::ArtifactUntilGoalTerminal(live.goal.id),
    ),
  )
}

///|
async test "a refused archive touches nothing" {
  let root = "/tmp/choir-goal-archive-refused-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let queued = archive_native_queued_record()
  let goal_id = queued.goal.id
  archive_native_persist(repository, adapters, queued)
  let digest = archive_native_adopt(
    repository,
    "archive-refused",
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  )
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
    @storage_host.artifact_store_contains(repository.artifact_store, digest).unwrap(),
  )
  ignore(@sys.rm_rf(root))
}

///|
/// `--dry-run` is the archive's only safety affordance, and the boolean the
/// CLI puts on the wire is read in the dispatcher, not in the planner. Drive
/// the dispatcher from a request so the read is what the test exercises: with
/// `dry_run` on the request nothing may be released, and with it off the same
/// request must release exactly what the preview named.
async test "the dispatcher releases nothing for a dry-run request" {
  let root = "/tmp/choir-goal-archive-wire-" + @sys.get_pid().to_string()
  let (repository, adapters) = archive_native_repository(root)
  let record = archive_native_queued_record(label="archive-wire")
  let goal_id = record.goal.id
  archive_native_persist(repository, adapters, archive_native_succeeded(record))
  let digest = archive_native_adopt(
    repository,
    "archive-wire",
    @storage.ArtifactRetention::ArtifactUntilGoalTerminal(goal_id),
  )
  let witness = record.branch_initialization.initialization_witness_ref
  let deleted : Array[@workflow.GitRefName] = []
  let list_refs = async fn(_project_dir : String) {
    @async.sleep(0)
    Ok([record.goal_ref, witness])
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
  let archive = async fn(dry_run : Bool) {
    dispatch_native_goal_archive(
      root,
      {
        req_method: @types.WireMethod::WireToolsCall,
        name: "goal_archive",
        args: @types.RequestArgs::from_values({
          "goal_id": goal_id.0.to_json(),
          "dry_run": dry_run.to_json(),
        }),
      },
      1_000L,
      list_refs~,
      delete_refs~,
    )
  }
  let preview = archive(true).ok_payload().unwrap()
  // What the host did, before what the response says about it: a response
  // field is the dispatcher quoting itself, and this has to fail when the
  // dry run stops holding the release back.
  assert_eq(deleted, [])
  assert_true(
    @storage_host.artifact_store_contains(repository.artifact_store, digest).unwrap(),
  )
  assert_eq(preview.get_json("dry_run"), Some(true.to_json()))
  assert_eq(preview.get_json("archived"), Some(false.to_json()))
  // The preview named a witness and a digest to release, so "nothing
  // happened" above is a dry run holding them back, not an empty plan.
  assert_eq(preview.get_json("release_refs"), Some([witness].to_json()))
  assert_eq(preview.get_json("release_artifacts"), Some([digest].to_json()))
  assert_eq(preview.get_json("refs_removed"), Some((0).to_json()))
  // The same request without the dry run releases exactly that.
  let applied = archive(false).ok_payload().unwrap()
  assert_eq(deleted, [witness])
  assert_false(
    @storage_host.artifact_store_contains(repository.artifact_store, digest).unwrap(),
  )
  assert_eq(applied.get_json("dry_run"), Some(false.to_json()))
  assert_eq(applied.get_json("archived"), Some(true.to_json()))
  assert_eq(applied.get_json("refs_removed"), Some((1).to_json()))
  assert_eq(applied.get_json("artifacts_released"), Some((1).to_json()))
  assert_true(applied.get_json("outbox_events_released") != Some((0).to_json()))
  ignore(@sys.rm_rf(root))
}

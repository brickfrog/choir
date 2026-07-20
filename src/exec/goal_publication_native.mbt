///|
enum NativeGoalPublicationRemoteIdentity {
  NativeGoalPublicationRemoteAvailable(@workflow.RemoteRepositoryId)
  NativeGoalPublicationRemoteUnavailable
} derive(Debug, Eq)

///|
async fn native_goal_publication_remote_identity(
  repository : NativeGoalRepositoryIdentity,
  remote_name : @workflow.RemoteName,
) -> Result[NativeGoalPublicationRemoteIdentity, @types.ChoirError] {
  let captured = match
    capture_native_goal_git(repository.root, [
      "remote",
      "get-url",
      remote_name.0,
    ]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let url = captured.output.trim().to_owned()
  if captured.exit_code != 0 || url == "" || url.contains("\u{00}") {
    return Ok(NativeGoalPublicationRemoteUnavailable)
  }
  Ok(
    NativeGoalPublicationRemoteAvailable(
      @workflow.RemoteRepositoryId(
        "sha256:" +
        @storage.digest_text(
          @storage.artifact_digest(
            @utf8.encode("choir.remote-repository.v1\u{00}" + url),
          ),
        ),
      ),
    ),
  )
}

///|
async fn native_remote_branch_observation(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
) -> @workflow.RemoteBranchObservation {
  let captured = match
    capture_native_goal_git(repository.root, [
      "ls-remote",
      "--refs",
      intent.remote_name.0,
      intent.remote_head_ref.0,
    ]) {
    Ok(value) => value
    Err(_) =>
      return @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain
  }
  if captured.exit_code != 0 {
    return @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain
  }
  let observed : Array[@control.GitOid] = []
  for raw in captured.output.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let fields = line.split("\t").to_array()
    if fields.length() != 2 || fields[1] != intent.remote_head_ref.0 {
      return @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain
    }
    let oid = fields[0].trim().to_owned()
    if oid.length() != intent.sealed_head_oid.0.length() {
      return @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain
    }
    observed.push(@control.GitOid(oid))
  }
  match observed {
    [] => @workflow.RemoteBranchObservation::RemoteBranchAbsent
    [oid] => @workflow.RemoteBranchObservation::RemoteBranchAt(oid)
    _ => @workflow.RemoteBranchObservation::RemoteBranchObservationUncertain
  }
}

///|
async fn native_publication_prior_is_ancestor(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
  observation : @workflow.RemoteBranchObservation,
) -> Bool {
  guard observation is @workflow.RemoteBranchObservation::RemoteBranchAt(oid) &&
    intent.expected_prior_remote_oid == Some(oid) else {
    return false
  }
  match
    capture_native_goal_git(repository.root, [
      "merge-base",
      "--is-ancestor",
      oid.0,
      intent.sealed_head_oid.0,
    ]) {
    Ok(value) => value.exit_code == 0
    Err(_) => false
  }
}

///|
async fn publish_native_goal_ref(
  repository : NativeGoalRepositoryIdentity,
  intent : @workflow.BranchPublicationIntent,
) -> Unit {
  let expected_remote = match intent.expected_prior_remote_oid {
    Some(oid) => oid.0
    None => ""
  }
  let lease = "--force-with-lease=" +
    intent.remote_head_ref.0 +
    ":" +
    expected_remote
  // The exact prior OID is part of the remote mutation, closing the race
  // between preflight observation and push. Authorization separately proves
  // ancestry, so the lease never authorizes a non-fast-forward transition.
  ignore(
    capture_native_goal_git(repository.root, [
      "-c",
      "core.hooksPath=/dev/null",
      "push",
      "--porcelain",
      "--no-verify",
      lease,
      intent.remote_name.0,
      intent.sealed_head_oid.0 + ":" + intent.remote_head_ref.0,
    ]),
  )
}

///|
fn native_goal_publication_transaction_completed(
  outcome : @storage.StateTransactionOutcome,
) -> Bool {
  match outcome {
    @storage.StateTransactionOutcome::StateTransactionCommitted
    | @storage.StateTransactionOutcome::StateTransactionReplayed
    | @storage.StateTransactionOutcome::StateTransactionCommittedAckLost => true
    _ => false
  }
}

///|
fn persist_native_goal_publication_record(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  execution : @workflow.GoalExecutionRecord,
  record : @workflow.GoalPublicationRecord,
  expected_store_version : Int?,
  fault_point? : @storage.StateStoreFaultPoint? = None,
) -> Result[@workflow.StoredGoalPublicationRecord?, @types.ChoirError] {
  let receipt = match
    @workflow.persist_goal_publication_record(repository, adapters, {
      record,
      expected_store_version,
      goal_precondition: @workflow.goal_execution_state_precondition(execution),
      fault_point,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match receipt.outcome {
    @workflow.GoalPublicationPersistenceOutcome::GoalPublicationGoalPreconditionConflict =>
      Ok(None)
    @workflow.GoalPublicationPersistenceOutcome::GoalPublicationPersistenceCompleted(
      outcome
    ) => {
      let observed = match
        @workflow.load_goal_publication_record(
          repository,
          adapters,
          execution.goal.id,
        ) {
        Ok(Some(value)) => value
        Ok(None) =>
          return Err(
            native_goal_execution_error("Goal publication record disappeared"),
          )
        Err(error) => return Err(error)
      }
      if observed.record == record &&
        (
          native_goal_publication_transaction_completed(outcome) ||
          outcome ==
          @storage.StateTransactionOutcome::StateTransactionVersionConflict
        ) {
        Ok(Some(observed))
      } else {
        Err(
          native_goal_execution_error("Goal publication persistence conflicted"),
        )
      }
    }
  }
}

///|
pub async fn advance_native_goal_publication(
  project_dir : String,
  goal_id : @control.GoalId,
  fault? : @workflow.GoalPublicationFaultPoint? = None,
) -> Result[@workflow.GoalPublicationTickOutcome, @types.ChoirError] {
  let repository = native_goal_repository(project_dir)
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let execution = match
    @workflow.load_goal_execution_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_goal_execution_error("Goal is not registered"))
    Err(error) => return Err(error)
  }
  if execution.state != @workflow.GoalExecutionState::GoalExecutionAssured {
    return Err(native_goal_execution_error("Goal is not assured"))
  }
  let assurance = match
    @workflow.load_goal_assurance_record(repository, adapters, goal_id) {
    Ok(Some(value)) => value.record
    Ok(None) =>
      return Err(native_goal_execution_error("Goal assurance is absent"))
    Err(error) => return Err(error)
  }
  let git = match discover_native_goal_repository(project_dir, execution) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let local_identity = match native_goal_ref_identity(git, execution.goal_ref) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard assurance.seal is Some(seal) else {
    return Err(native_goal_execution_error("Goal seal is absent"))
  }
  if local_identity.0 != seal.head_oid || local_identity.1 != seal.tree_oid {
    return Err(native_goal_execution_error("sealed Goal ref diverged"))
  }
  let remote_name = @workflow.RemoteName("origin")
  let remote_repository_id = match
    native_goal_publication_remote_identity(git, remote_name) {
    Ok(NativeGoalPublicationRemoteAvailable(value)) => value
    Ok(NativeGoalPublicationRemoteUnavailable) =>
      return Ok(
        @workflow.GoalPublicationTickOutcome::GoalPublicationRemoteUnavailable,
      )
    Err(error) => return Err(error)
  }
  let mut current = match
    @workflow.load_goal_publication_record(repository, adapters, goal_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut cycles = 0
  while cycles < 8 {
    cycles = cycles + 1
    match current {
      None => {
        let planned = match
          @workflow.initialize_goal_publication(
            execution,
            assurance,
            remote_repository_id,
            remote_name,
            execution.goal_ref,
            None,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        current = match
          persist_native_goal_publication_record(
            repository,
            adapters,
            execution,
            planned,
            None,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if fault ==
          Some(
            @workflow.GoalPublicationFaultPoint::PublicationAfterIntentBeforeAuthorized,
          ) {
          return Err(native_goal_execution_error("injected publication fault"))
        }
      }
      Some(stored) =>
        match stored.record.intent.state {
          @workflow.BranchPublicationState::BranchPublicationPlanned
          | @workflow.BranchPublicationState::BranchPublicationPreflightUncertain => {
            let observation = native_remote_branch_observation(
              git,
              stored.record.intent,
            )
            let authorized = match
              @workflow.authorize_goal_publication(
                stored.record,
                execution,
                assurance,
                local_identity.0,
                observation,
                native_publication_prior_is_ancestor(
                  git,
                  stored.record.intent,
                  observation,
                ),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            if authorized == stored.record {
              return Ok(
                @workflow.GoalPublicationTickOutcome::GoalPublicationRecoveryUncertain,
              )
            }
            current = match
              persist_native_goal_publication_record(
                repository,
                adapters,
                execution,
                authorized,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            if authorized.intent.state ==
              @workflow.BranchPublicationState::BranchPublicationAuthorized &&
              fault ==
              Some(
                @workflow.GoalPublicationFaultPoint::PublicationAfterAuthorizedBeforeRemoteUpdate,
              ) {
              return Err(
                native_goal_execution_error("injected publication fault"),
              )
            }
          }
          @workflow.BranchPublicationState::BranchPublicationAuthorized => {
            let before = native_remote_branch_observation(
              git,
              stored.record.intent,
            )
            let (after, origin, prior, mutated) = match before {
              @workflow.RemoteBranchObservation::RemoteBranchAt(oid) if oid ==
                stored.record.intent.sealed_head_oid =>
                (
                  before,
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
                  Some(oid),
                  false,
                )
              @workflow.RemoteBranchObservation::RemoteBranchAbsent => {
                publish_native_goal_ref(git, stored.record.intent)
                if fault ==
                  Some(
                    @workflow.GoalPublicationFaultPoint::PublicationAfterRemoteUpdateBeforeResponse,
                  ) {
                  return Err(
                    native_goal_execution_error("injected publication fault"),
                  )
                }
                (
                  native_remote_branch_observation(git, stored.record.intent),
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
                  None,
                  true,
                )
              }
              @workflow.RemoteBranchObservation::RemoteBranchAt(oid) if stored.record.intent.expected_prior_remote_oid ==
                Some(oid) => {
                publish_native_goal_ref(git, stored.record.intent)
                if fault ==
                  Some(
                    @workflow.GoalPublicationFaultPoint::PublicationAfterRemoteUpdateBeforeResponse,
                  ) {
                  return Err(
                    native_goal_execution_error("injected publication fault"),
                  )
                }
                (
                  native_remote_branch_observation(git, stored.record.intent),
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
                  Some(oid),
                  true,
                )
              }
              _ =>
                (
                  before,
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
                  None,
                  false,
                )
            }
            if mutated &&
              fault ==
              Some(
                @workflow.GoalPublicationFaultPoint::PublicationAfterResponseBeforeReceipt,
              ) {
              return Err(
                native_goal_execution_error("injected publication fault"),
              )
            }
            let observed = match
              @workflow.record_goal_publication_observation(
                stored.record,
                after,
                origin,
                prior,
                @env.now().reinterpret_as_int64() / 1000L,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            current = match
              persist_native_goal_publication_record(
                repository,
                adapters,
                execution,
                observed,
                Some(stored.state_record.version),
                fault_point=if observed.intent.state ==
                  @workflow.BranchPublicationState::BranchPublicationReceipted &&
                  fault ==
                  Some(
                    @workflow.GoalPublicationFaultPoint::PublicationDuringReceiptTransaction,
                  ) {
                  Some(@storage.StateStoreFaultPoint::StateAfterCommitBeforeAck)
                } else {
                  None
                },
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            if observed.intent.state ==
              @workflow.BranchPublicationState::BranchPublicationReceipted &&
              fault ==
              Some(
                @workflow.GoalPublicationFaultPoint::PublicationDuringReceiptTransaction,
              ) {
              return Err(
                native_goal_execution_error("injected publication fault"),
              )
            }
          }
          @workflow.BranchPublicationState::BranchPublicationReceipted =>
            return Ok(
              @workflow.GoalPublicationTickOutcome::GoalPublicationComplete,
            )
          @workflow.BranchPublicationState::BranchPublicationDrift =>
            return Ok(
              @workflow.GoalPublicationTickOutcome::GoalPublicationDrifted,
            )
          @workflow.BranchPublicationState::BranchPublicationMutationUncertain => {
            let observation = native_remote_branch_observation(
              git,
              stored.record.intent,
            )
            let reconciled = match
              @workflow.record_goal_publication_observation(
                stored.record,
                observation,
                @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
                None,
                @env.now().reinterpret_as_int64() / 1000L,
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            if reconciled == stored.record {
              return Ok(
                @workflow.GoalPublicationTickOutcome::GoalPublicationRecoveryUncertain,
              )
            }
            current = match
              persist_native_goal_publication_record(
                repository,
                adapters,
                execution,
                reconciled,
                Some(stored.state_record.version),
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
          }
          @workflow.BranchPublicationState::BranchPublicationAbandonedByCancellation =>
            return Ok(
              @workflow.GoalPublicationTickOutcome::GoalPublicationPending,
            )
        }
    }
  } nobreak {
    Err(
      native_goal_execution_error("Goal publication exceeded its cycle bound"),
    )
  }
}

///|
async test "native Goal publication creates, adopts, and refuses remote drift" {
  let root = "/tmp/choir-goal-publication-" + @sys.get_pid().to_string()
  let remote = root + "-remote.git"
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(remote))
  if !@sys.create_dir_all(root) || !@sys.create_dir_all(remote) {
    fail("failed to create publication test roots")
  }
  let local_git = async fn(arguments : Array[String]) -> NativeGitCapture {
    match capture_native_goal_git(root, arguments) {
      Ok(value) => value
      Err(error) => fail(error.message())
    }
  }
  let remote_git = @process.collect_output_merged(
    "/usr/bin/git",
    ["init", "--bare", "-q", remote],
    inherit_env=false,
  ) catch {
    _ => fail("failed to initialize bare remote")
  }
  if remote_git.0 != 0 || local_git(["init", "-q"]).exit_code != 0 {
    fail("failed to initialize publication repositories")
  }
  let tree = local_git(["hash-object", "-w", "-t", "tree", "/dev/null"])
  let base = local_git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-m",
    "publication base",
  ])
  let middle = local_git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-p",
    base.output.trim().to_owned(),
    "-m",
    "publication middle",
  ])
  let commit = local_git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-p",
    middle.output.trim().to_owned(),
    "-m",
    "publication",
  ])
  if tree.exit_code != 0 ||
    base.exit_code != 0 ||
    middle.exit_code != 0 ||
    commit.exit_code != 0 {
    fail("failed to create publication commit")
  }
  let base_oid = @control.GitOid(base.output.trim().to_owned())
  let middle_oid = @control.GitOid(middle.output.trim().to_owned())
  let oid = @control.GitOid(commit.output.trim().to_owned())
  let repository : NativeGoalRepositoryIdentity = {
    root,
    git_directory: root + "/.git",
    object_directory: root + "/.git/objects",
  }
  guard native_goal_publication_remote_identity(
      repository,
      @workflow.RemoteName("origin"),
    )
    is Ok(NativeGoalPublicationRemoteUnavailable) else {
    fail("absent publication remote was not reported")
  }
  if local_git(["remote", "add", "origin", remote]).exit_code != 0 {
    fail("failed to add publication remote")
  }
  guard native_goal_publication_remote_identity(
      repository,
      @workflow.RemoteName("origin"),
    )
    is Ok(NativeGoalPublicationRemoteAvailable(_)) else {
    fail("publication remote identity remained unavailable")
  }
  let intent : @workflow.BranchPublicationIntent = {
    id: @workflow.BranchPublicationIntentId("publication-test"),
    goal_id: @control.GoalId("goal-publication-test"),
    canonical_repository_id: @workflow.RemoteRepositoryId("remote-test"),
    remote_name: @workflow.RemoteName("origin"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/publication-test",
    ),
    expected_prior_remote_oid: None,
    sealed_head_oid: oid,
    goal_branch_seal_id: @control.GoalBranchSealId("seal-publication-test"),
    goal_branch_seal_digest: @control.Digest("seal-digest"),
    idempotency_key: "publication-test",
    state: @workflow.BranchPublicationState::BranchPublicationAuthorized,
  }
  let create_race_intent : @workflow.BranchPublicationIntent = {
    ..intent,
    id: @workflow.BranchPublicationIntentId("publication-create-race"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/publication-create-race",
    ),
    idempotency_key: "publication-create-race",
  }
  let create_race = local_git([
    "push",
    "origin",
    middle_oid.0 + ":" + create_race_intent.remote_head_ref.0,
  ])
  if create_race.exit_code != 0 {
    fail("failed to install concurrent publication creation")
  }
  publish_native_goal_ref(repository, create_race_intent)
  assert_eq(
    native_remote_branch_observation(repository, create_race_intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(middle_oid),
  )
  let exact_update_intent : @workflow.BranchPublicationIntent = {
    ..intent,
    id: @workflow.BranchPublicationIntentId("publication-exact-update"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/publication-exact-update",
    ),
    expected_prior_remote_oid: Some(base_oid),
    idempotency_key: "publication-exact-update",
  }
  let exact_prior = local_git([
    "push",
    "origin",
    base_oid.0 + ":" + exact_update_intent.remote_head_ref.0,
  ])
  if exact_prior.exit_code != 0 {
    fail("failed to install exact publication prior")
  }
  publish_native_goal_ref(repository, exact_update_intent)
  assert_eq(
    native_remote_branch_observation(repository, exact_update_intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(oid),
  )
  let update_race_intent : @workflow.BranchPublicationIntent = {
    ..intent,
    id: @workflow.BranchPublicationIntentId("publication-update-race"),
    remote_head_ref: @workflow.GitRefName(
      "refs/heads/choir/goals/publication-update-race",
    ),
    expected_prior_remote_oid: Some(base_oid),
    idempotency_key: "publication-update-race",
  }
  let raced_prior = local_git([
    "push",
    "origin",
    middle_oid.0 + ":" + update_race_intent.remote_head_ref.0,
  ])
  if raced_prior.exit_code != 0 {
    fail("failed to install concurrent publication update")
  }
  publish_native_goal_ref(repository, update_race_intent)
  assert_eq(
    native_remote_branch_observation(repository, update_race_intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(middle_oid),
  )
  assert_eq(
    native_remote_branch_observation(repository, intent),
    @workflow.RemoteBranchObservation::RemoteBranchAbsent,
  )
  publish_native_goal_ref(repository, intent)
  assert_eq(
    native_remote_branch_observation(repository, intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(oid),
  )
  publish_native_goal_ref(repository, intent)
  assert_eq(
    native_remote_branch_observation(repository, intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(oid),
  )
  let other = local_git([
    "-c",
    "user.name=Choir Test",
    "-c",
    "user.email=choir@example.invalid",
    "commit-tree",
    tree.output.trim().to_owned(),
    "-m",
    "other",
  ])
  let drift = local_git([
    "push",
    "--force",
    "origin",
    other.output.trim().to_owned() + ":" + intent.remote_head_ref.0,
  ])
  if other.exit_code != 0 || drift.exit_code != 0 {
    fail("failed to install remote drift")
  }
  publish_native_goal_ref(repository, intent)
  assert_eq(
    native_remote_branch_observation(repository, intent),
    @workflow.RemoteBranchObservation::RemoteBranchAt(
      @control.GitOid(other.output.trim().to_owned()),
    ),
  )
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(remote))
}

///|
fn publication_digest(label : String) -> @control.Digest {
  @storage.artifact_digest(
    @utf8.encode("publication-conformance\u{00}" + label),
  )
}

///|
fn publication_initialized_branch(
  goal_id : @control.GoalId,
  repository_id : @workflow.RepositoryId,
  goal_ref : @workflow.GitRefName,
  base_oid : @control.GitOid,
) -> @workflow.GoalBranchInitialization {
  let planned = @workflow.initial_goal_branch_initialization(
    goal_id, repository_id, goal_ref, base_oid,
  )
  {
    ..planned,
    lifecycle: @workflow.GoalBranchInitLifecycle::GoalBranchInitReceipted,
    receipt: Some({
      intent_id: planned.intent_id,
      idempotency_key: planned.idempotency_key,
      repository_id,
      goal_ref,
      initialized_oid: base_oid,
      initialization_witness_ref: planned.initialization_witness_ref,
      observed_at: 1L,
    }),
  }
}

///|
fn publication_take(
  goal_id : @control.GoalId,
  id : String,
  purpose : @control.TakePurpose,
) -> @control.Take {
  {
    id: @control.TakeId(id),
    goal_id,
    purpose,
    ordinal: 1,
    fencing_epoch: None,
    lifecycle: @control.TakeLifecycle::TakePlanned,
  }
}

///|
fn publication_sandbox(
  id : String,
  generation : String,
  take : @control.Take,
) -> @control.SandboxLease {
  {
    id: @control.SandboxLeaseId(id),
    take_id: take.id,
    generation_id: @control.SandboxGenerationId(generation),
    capability_profile_digest: publication_digest(id + "-capability"),
    runtime_policy_digest: publication_digest(id + "-runtime"),
    lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
  }
}

///|
fn publication_session(
  id : String,
  take : @control.Take,
  sandbox : @control.SandboxLease,
) -> @control.HarnessSession {
  {
    id: @control.HarnessSessionId(id),
    take_id: take.id,
    sandbox_generation_id: sandbox.generation_id,
    surface: @control.ProviderSurfaceId::CodexSubscriptionCli,
    effective_surface_manifest_digest: publication_digest(id + "-surface"),
    cursor_class: @control.HarnessCursorClass::HarnessCursorNotResumable,
    provider_cursor: None,
    last_choir_sequence: @control.EventSequence(0L),
    open_tool_execution_ids: [],
    lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
  }
}

///|
fn publication_assurance_identities(
  goal_id : @control.GoalId,
  head : @control.GitOid,
) -> @workflow.GoalAssuranceIdentityPlan {
  let verification = publication_take(
    goal_id,
    "publication-goal-verification",
    @control.TakePurpose::GoalVerification(
      goal_id,
      head,
      publication_digest("goal-verification"),
    ),
  )
  let audit = publication_take(
    goal_id,
    "publication-goal-audit",
    @control.TakePurpose::GoalAudit(goal_id, publication_digest("goal-audit")),
  )
  let verification_sandbox = publication_sandbox(
    "publication-goal-verification-sandbox", "publication-goal-verification-generation",
    verification,
  )
  let audit_sandbox = publication_sandbox(
    "publication-goal-audit-sandbox", "publication-goal-audit-generation", audit,
  )
  {
    verification_take: verification,
    verification_sandbox,
    verification_session: publication_session(
      "publication-goal-verification-session", verification, verification_sandbox,
    ),
    audit_take: audit,
    audit_sandbox,
    audit_session: publication_session(
      "publication-goal-audit-session", audit, audit_sandbox,
    ),
  }
}

///|
fn publication_integrated_part(
  goal : @control.Goal,
  base : @control.GitOid,
  tree : @control.GitOid,
  head : @control.GitOid,
) -> @workflow.PartWorkflowSnapshot {
  let part_id = @control.PartId("publication-part")
  let contract_id = @control.RevisionId("publication-contract")
  let implementation = publication_take(
    goal.id,
    "publication-implementation",
    @control.TakePurpose::Implementation(part_id, contract_id),
  )
  let verification = publication_take(
    goal.id,
    "publication-verification",
    @control.TakePurpose::PartVerification(
      part_id,
      implementation.id,
      publication_digest("part-verification"),
    ),
  )
  let audit = publication_take(
    goal.id,
    "publication-audit",
    @control.TakePurpose::PartAudit(
      part_id,
      implementation.id,
      publication_digest("part-audit"),
    ),
  )
  let implementation_sandbox = publication_sandbox(
    "publication-implementation-sandbox", "publication-implementation-generation",
    implementation,
  )
  let verification_sandbox = publication_sandbox(
    "publication-verification-sandbox", "publication-verification-generation", verification,
  )
  let audit_sandbox = publication_sandbox(
    "publication-audit-sandbox", "publication-audit-generation", audit,
  )
  let receipt_id = @control.IntegrationReceiptId("publication-integration")
  let receipt : @control.IntegrationReceipt = {
    id: receipt_id,
    intent_id: @control.IntegrationIntentId("publication-integration-intent"),
    goal_id: goal.id,
    part_id,
    candidate_id: @control.CandidateId("publication-candidate"),
    candidate_commit_oid: head,
    candidate_tree_oid: tree,
    from_head_oid: base,
    promotion_commit_oid: head,
    promotion_tree_oid: tree,
    witness_ref: "refs/choir/witness/publication-integration",
    integrated_at: 1L,
  }
  {
    workflow_id: "publication-workflow",
    durable_version: 1,
    fencing_epoch: @control.FencingEpoch(1L),
    stage: @workflow.PartWorkflowStage::PartIntegrated,
    goal,
    part: {
      id: part_id,
      goal_id: goal.id,
      dependency_ids: [],
      task_contract_revision_id: contract_id,
      lifecycle: @control.PartLifecycle::PartIntegrated(
        @control.ReceiptId(receipt_id.0),
      ),
    },
    task_contract: {
      id: contract_id,
      goal_id: goal.id,
      part_id,
      revision: 1,
      digest: publication_digest("contract"),
      instruction_artifact: {
        artifact_id: "publication-instruction",
        digest: publication_digest("instruction"),
      },
      base_commit_oid: base,
      base_tree_oid: tree,
      path_mode: @control.RepositoryPathMode::CaseSensitiveNfc,
      mutation_declaration: @control.MutationDeclaration::CompleteMutationDeclaration([],
      ),
      verification_specs: [
        {
          id: @control.VerificationSpecId("publication-verification-spec"),
          version: 1,
          digest: publication_digest("verification-spec"),
          process_spec_digest: publication_digest("verification-process"),
        },
      ],
      audit_policy_digest: publication_digest("part-audit-policy"),
      implementation_capability_profile_digest: publication_digest(
        "implementation-capability",
      ),
      verification_capability_profile_digest: publication_digest(
        "verification-capability",
      ),
      audit_capability_profile_digest: publication_digest("audit-capability"),
    },
    identities: {
      implementation_take: implementation,
      implementation_sandbox,
      implementation_session: publication_session(
        "publication-implementation-session", implementation, implementation_sandbox,
      ),
      verification_take: verification,
      verification_sandbox,
      verification_session: publication_session(
        "publication-verification-session", verification, verification_sandbox,
      ),
      audit_take: audit,
      audit_sandbox,
      audit_session: publication_session(
        "publication-audit-session", audit, audit_sandbox,
      ),
    },
    implementation_take: implementation,
    verification_take: verification,
    audit_take: audit,
    sandbox_leases: [],
    harness_sessions: [],
    harness_events: [],
    implementation_result: None,
    candidate: None,
    verification_subject: None,
    verification_slots: [],
    verification_receipts: [],
    verification_authorization: None,
    audit_subject: None,
    audit_result: None,
    audit_receipt: None,
    integration_lease: None,
    integration_intent: None,
    promotion_commit: None,
    integration_receipt: Some(receipt),
    pending_effect: None,
    effect_receipts: [],
  }
}

///|
fn publication_audited_assurance(
  planned : @workflow.GoalAssuranceRecord,
  head : @control.GitOid,
  tree : @control.GitOid,
) -> @workflow.GoalAssuranceRecord {
  let unfinished : @control.GoalBranchSeal = {
    id: @control.GoalBranchSealId("publication-seal"),
    intent_id: planned.seal_intent.id,
    goal_id: planned.goal_id,
    seal_epoch: planned.fencing_epoch,
    goal_ref: planned.goal_ref.0,
    seal_witness_ref: planned.seal_intent.seal_witness_ref,
    head_oid: head,
    tree_oid: tree,
    goal_contract_digest: planned.goal_contract_digest,
    assurance_policy_revision: planned.assurance_policy_revision,
    assurance_policy_digest: planned.assurance_policy_digest,
    integration_receipt_set_digest: planned.integration_receipt_set_digest,
    sealed_at: 2L,
    seal_digest: publication_digest("unfinished-seal"),
  }
  let seal = {
    ..unfinished,
    seal_digest: @workflow.goal_branch_seal_digest(unfinished),
  }
  let authorization : @control.GoalVerificationAuthorizationSet = {
    subject_digest: publication_digest("verification-subject"),
    receipt_ids: [@control.ReceiptId("publication-verification-receipt")],
    receipt_set_digest: publication_digest("verification-receipt-set"),
    evidence_manifest_digest: publication_digest("verification-evidence"),
  }
  let audit_subject : @control.GoalAuditSubject = {
    goal_id: planned.goal_id,
    goal_branch_seal_id: seal.id,
    goal_branch_seal_digest: seal.seal_digest,
    goal_head_oid: head,
    goal_tree_oid: tree,
    goal_contract_digest: planned.goal_contract_digest,
    assurance_policy_revision: planned.assurance_policy_revision,
    integration_receipt_set_digest: planned.integration_receipt_set_digest,
    goal_verification_receipt_set_digest: authorization.receipt_set_digest,
    goal_verification_evidence_manifest_digest: authorization.evidence_manifest_digest,
    subject_digest: publication_digest("audit-subject"),
  }
  let result_digest = publication_digest("audit-result")
  let result : @control.GoalAuditResult = {
    id: @control.AuditResultId("publication-audit-result"),
    audit_take_id: planned.audit_take.id,
    take_fencing_epoch: planned.fencing_epoch,
    audit_harness_session_id: planned.identities.audit_session.id,
    subject: audit_subject,
    auditor_capability_profile_digest: publication_digest("auditor-capability"),
    effective_surface_manifest_digest: publication_digest("audit-surface"),
    provider_conformance_report_digest: publication_digest(
      "provider-conformance",
    ),
    audit_policy_digest: publication_digest("goal-audit-policy"),
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: 3L,
    finished_at: 4L,
    outcome: @control.AuditOutcome::AuditPassed,
    result_digest,
  }
  let receipt : @control.GoalAuditReceipt = {
    receipt_id: @control.ReceiptId("publication-audit-receipt"),
    audit_result_id: result.id,
    audit_result_digest: result.result_digest,
    subject: audit_subject,
    audit_take_id: planned.audit_take.id,
    audit_harness_session_id: planned.identities.audit_session.id,
    audit_sandbox_generation_id: planned.identities.audit_sandbox.generation_id,
    auditor_capability_profile_digest: result.auditor_capability_profile_digest,
    provider_surface_id: @control.ProviderSurfaceId::CodexSubscriptionCli,
    provider_identity: "codex-cli",
    model_identity: @control.ModelIdentity::ReportedModelIdentity("codex"),
    provider_conformance_report_digest: result.provider_conformance_report_digest,
    audit_policy_digest: result.audit_policy_digest,
    findings_artifact: None,
    total_findings_count: 0,
    blocking_findings_count: 0,
    started_at: result.started_at,
    finished_at: result.finished_at,
    outcome: @control.AuditOutcome::AuditPassed,
  }
  {
    ..planned,
    seal_intent: {
      ..planned.seal_intent,
      lifecycle: @control.GoalBranchSealIntentLifecycle::GoalBranchSealed,
    },
    seal_witnessed_at: Some(2L),
    seal: Some(seal),
    verification_authorization: Some(authorization),
    audit_subject: Some(audit_subject),
    audit_result: Some(result),
    audit_receipt: Some(receipt),
    stage: @workflow.GoalAssuranceStage::GoalAudited,
  }
}

///|
async fn prove_publication_fault_recovery(
  label : String,
  fault : @workflow.GoalPublicationFaultPoint,
  expected_state : @workflow.BranchPublicationState,
  remote_updated : Bool,
) -> (String, String, @control.GoalId) {
  let root = "/tmp/choir-publication-fault-" +
    @sys.get_pid().to_string() +
    "-" +
    label
  let remote = root + "-remote.git"
  ignore(@sys.rm_rf(root))
  ignore(@sys.rm_rf(remote))
  assert_true(@sys.create_dir_all(root))
  let git = async fn(cwd : String, arguments : Array[String]) -> (Int, String) {
    let captured = @process.collect_output_merged(
      "/usr/bin/git",
      arguments,
      extra_env={
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
      },
      inherit_env=false,
      cwd~,
    ) catch {
      _ => fail("publication Git command failed")
    }
    let output = captured.1.text() catch {
      _ => fail("publication Git output was not UTF-8")
    }
    (captured.0, output)
  }
  assert_eq(git(root, ["init", "-q"]).0, 0)
  assert_eq(git(root, ["init", "--bare", "-q", remote]).0, 0)
  let tree = git(root, ["hash-object", "-w", "-t", "tree", "/dev/null"])
  let tree_oid = tree.1.trim().to_owned()
  let base = git(root, [
    "-c", "user.name=Choir Test", "-c", "user.email=choir@example.invalid", "commit-tree",
    tree_oid, "-m", "publication base",
  ])
  let base_oid = base.1.trim().to_owned()
  let head = git(root, [
    "-c", "user.name=Choir Test", "-c", "user.email=choir@example.invalid", "commit-tree",
    tree_oid, "-p", base_oid, "-m", "publication head",
  ])
  let head_oid = head.1.trim().to_owned()
  assert_eq(tree.0, 0)
  assert_eq(base.0, 0)
  assert_eq(head.0, 0)
  assert_eq(git(root, ["remote", "add", "origin", remote]).0, 0)
  let goal_id = @control.GoalId("publication-goal-" + label)
  let goal_ref = @workflow.goal_execution_ref(goal_id)
  assert_eq(git(root, ["update-ref", goal_ref.0, head_oid]).0, 0)
  let canonical_root = @sys.realpath_native(root).unwrap()
  let repository_id = @workflow.RepositoryId(
    "sha256:" +
    @storage.artifact_digest(
      @utf8.encode("choir.repository.v1\u{00}" + canonical_root),
    ).0,
  )
  let goal : @control.Goal = {
    id: goal_id,
    contract_digest: publication_digest("goal-contract-" + label),
    lifecycle: @control.GoalLifecycle::GoalActive(
      @control.GoalActiveCondition::GoalRunning,
    ),
  }
  let integrated = publication_integrated_part(
    goal,
    @control.GitOid(base_oid),
    @control.GitOid(tree_oid),
    @control.GitOid(head_oid),
  )
  let assuring : @workflow.GoalExecutionRecord = {
    goal,
    repository_id,
    selection_decision_digest: publication_digest("selection-" + label),
    base_ref: @workflow.GitRefName("refs/heads/main"),
    base_commit_oid: @control.GitOid(base_oid),
    base_tree_oid: @control.GitOid(tree_oid),
    integration_target_ref: @workflow.GitRefName("refs/heads/main"),
    goal_ref,
    branch_initialization: publication_initialized_branch(
      goal_id,
      repository_id,
      goal_ref,
      @control.GitOid(base_oid),
    ),
    maximum_parallel_parts: 1,
    policy_revisions: [@workflow.initial_goal_policy_revision(goal_id, 1)],
    part_workflow_ids: [integrated.workflow_id],
    state: @workflow.GoalExecutionState::GoalExecutionAssuring,
    pause: None,
    active_input_request: None,
    input_answers: [],
    cancellation_request: None,
    durable_version: 1,
    fencing_epoch: @control.FencingEpoch(1L),
  }
  let planned = match
    @workflow.initialize_goal_assurance(
      assuring,
      [integrated],
      @control.GitOid(head_oid),
      @control.GitOid(tree_oid),
      integrated.task_contract.verification_specs,
      publication_assurance_identities(goal_id, @control.GitOid(head_oid)),
    ) {
    Ok(value) => value
    Err(error) => fail(label + ": " + error.message())
  }
  let assured = {
    ..assuring,
    state: @workflow.GoalExecutionState::GoalExecutionAssured,
  }
  let assurance = publication_audited_assurance(
    planned,
    @control.GitOid(head_oid),
    @control.GitOid(tree_oid),
  )
  assert_true(@sys.create_dir_all(root + "/.choir/state/control/artifacts"))
  let repository = native_goal_repository(root)
  let adapters = local_part_workflow_repository_adapters()
  match @workflow.initialize_part_workflow_repository(repository, adapters) {
    Ok(_) => ()
    Err(error) => fail(label + ": " + error.message())
  }
  match
    @workflow.persist_goal_execution_record(repository, adapters, {
      record: assured,
      expected_store_version: None,
      fault_point: None,
    }) {
    Ok(_) => ()
    Err(error) => fail(label + ": " + error.message())
  }
  match
    @workflow.persist_goal_assurance_record(repository, adapters, {
      record: assurance,
      expected_store_version: None,
      goal_precondition: @workflow.goal_execution_state_precondition(assured),
      fault_point: None,
    }) {
    Ok(_) => ()
    Err(error) => fail(label + ": " + error.message())
  }
  assert_true(
    advance_native_goal_publication(root, goal_id, fault=Some(fault)) is Err(_),
  )
  let interrupted = @workflow.load_goal_publication_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record
  assert_eq(interrupted.intent.state, expected_state)
  let observed = git(root, ["ls-remote", "--refs", "origin", goal_ref.0])
  assert_eq(observed.0, 0)
  if remote_updated {
    assert_true(observed.1.has_prefix(head_oid))
  } else {
    assert_eq(observed.1.trim(), "")
  }
  let recovered = match advance_native_goal_publication(root, goal_id) {
    Ok(value) => value
    Err(error) => fail(label + ": recovery: " + error.message())
  }
  assert_eq(
    recovered,
    @workflow.GoalPublicationTickOutcome::GoalPublicationComplete,
  )
  let completed = @workflow.load_goal_publication_record(
      repository, adapters, goal_id,
    )
    .unwrap()
    .unwrap().record
  assert_eq(
    completed.intent.state,
    @workflow.BranchPublicationState::BranchPublicationReceipted,
  )
  assert_true(completed.receipt is Some(_))
  assert_eq(
    advance_native_goal_publication(root, goal_id).unwrap(),
    @workflow.GoalPublicationTickOutcome::GoalPublicationComplete,
  )
  assert_eq(
    @workflow.load_goal_publication_record(repository, adapters, goal_id)
    .unwrap()
    .unwrap().record,
    completed,
  )
  assert_eq(
    @workflow.load_goal_execution_record(repository, adapters, goal_id)
    .unwrap()
    .unwrap().record.state,
    @workflow.GoalExecutionState::GoalExecutionAssured,
  )
  (root, remote, goal_id)
}

///|
async test "real exec integration: Goal publication recovers across every external-effect boundary" {
  let cleanup = fn(fixture : (String, String, @control.GoalId)) {
    ignore(@sys.rm_rf(fixture.0))
    ignore(@sys.rm_rf(fixture.1))
  }
  cleanup(
    prove_publication_fault_recovery(
      "after-intent",
      @workflow.GoalPublicationFaultPoint::PublicationAfterIntentBeforeAuthorized,
      @workflow.BranchPublicationState::BranchPublicationPlanned,
      false,
    ),
  )
  cleanup(
    prove_publication_fault_recovery(
      "after-authorization",
      @workflow.GoalPublicationFaultPoint::PublicationAfterAuthorizedBeforeRemoteUpdate,
      @workflow.BranchPublicationState::BranchPublicationAuthorized,
      false,
    ),
  )
  cleanup(
    prove_publication_fault_recovery(
      "after-update",
      @workflow.GoalPublicationFaultPoint::PublicationAfterRemoteUpdateBeforeResponse,
      @workflow.BranchPublicationState::BranchPublicationAuthorized,
      true,
    ),
  )
  cleanup(
    prove_publication_fault_recovery(
      "after-response",
      @workflow.GoalPublicationFaultPoint::PublicationAfterResponseBeforeReceipt,
      @workflow.BranchPublicationState::BranchPublicationAuthorized,
      true,
    ),
  )
  cleanup(
    prove_publication_fault_recovery(
      "during-receipt",
      @workflow.GoalPublicationFaultPoint::PublicationDuringReceiptTransaction,
      @workflow.BranchPublicationState::BranchPublicationReceipted,
      true,
    ),
  )
}

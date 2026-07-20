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
) -> Result[@workflow.StoredGoalPublicationRecord?, @types.ChoirError] {
  let receipt = match
    @workflow.persist_goal_publication_record(repository, adapters, {
      record,
      expected_store_version,
      goal_precondition: @workflow.goal_execution_state_precondition(execution),
      fault_point: None,
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
          }
          @workflow.BranchPublicationState::BranchPublicationAuthorized => {
            let before = native_remote_branch_observation(
              git,
              stored.record.intent,
            )
            let (after, origin, prior) = match before {
              @workflow.RemoteBranchObservation::RemoteBranchAt(oid) if oid ==
                stored.record.intent.sealed_head_oid =>
                (
                  before,
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
                  Some(oid),
                )
              @workflow.RemoteBranchObservation::RemoteBranchAbsent => {
                publish_native_goal_ref(git, stored.record.intent)
                (
                  native_remote_branch_observation(git, stored.record.intent),
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
                  None,
                )
              }
              @workflow.RemoteBranchObservation::RemoteBranchAt(oid) if stored.record.intent.expected_prior_remote_oid ==
                Some(oid) => {
                publish_native_goal_ref(git, stored.record.intent)
                (
                  native_remote_branch_observation(git, stored.record.intent),
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationMutationApplied,
                  Some(oid),
                )
              }
              _ =>
                (
                  before,
                  @workflow.BranchPublicationReceiptOrigin::BranchPublicationAdopted,
                  None,
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
              ) {
              Ok(value) => value
              Err(error) => return Err(error)
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

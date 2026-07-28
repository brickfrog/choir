///| The promotion half of the Goal Part adapter, driven the way the Goal runner
/// drives it.
///
/// `promote_bound_part` and `resume_bound_promotion` are private, and the only
/// way in is the `promote_part` / `resume_promotion` pair that
/// `goal_part_workflow_adapters` returns. So these tests build a real Part in a
/// real repository, drive it to the audited state
/// `select_next_deterministic_promotion` promotes from, and then go through the
/// adapters — a test that called the private functions would prove the
/// functions, not the seam the runner uses.

///|
/// The Goal head the promotion is planned against.
///
/// It has to agree with `promotion_harness_input`, because the adapter refuses
/// a selection whose expected head disagrees with the integration input.
let promotion_harness_head : @control.GitOid = @control.GitOid(
  "goal-head-store",
)

///|
/// The integration plan the Goal would hand a promotion. Mirrors the shape
/// `native_goal_integration_input` builds: the selection names the head, the
/// plan carries the Goal's lease and intent identity.
fn promotion_harness_input(
  snapshot : @workflow.PartWorkflowSnapshot,
  selection : @workflow.DeterministicPromotionSelection,
) -> Result[@workflow.IntegrationPlanInput, @types.ChoirError] {
  Ok({
    lease: {
      id: @control.IntegrationLeaseId("integration-lease-store"),
      goal_id: snapshot.goal.id,
      fencing_epoch: snapshot.fencing_epoch,
      holder: "choird-test",
    },
    intent_id: @control.IntegrationIntentId("integration-intent-store"),
    expected_goal_head_oid: selection.expected_goal_head_oid,
    promotion_metadata_digest: workflow_store_digest_a,
    git_witness_ref: "refs/choir/witness/integration-intent-store",
  })
}

///|
/// Drive a fresh Part to the state the Goal runner promotes from: audited, with
/// integration admission still deferred, persisted in `repository`.
async fn promotion_harness_audited(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  dependencies : @workflow.PartWorkflowDriverDependencies,
) -> @workflow.PartWorkflowSnapshot {
  guard @workflow.initialize_part_workflow_repository(repository, adapters)
    is Ok(_) else {
    fail("initialize promotion repository")
  }
  let deferred : @workflow.PartWorkflowDriverDependencies = {
    ..dependencies,
    integration_admission: fn(_) {
      Ok(@workflow.PartIntegrationAdmission::PartIntegrationDeferred)
    },
  }
  let waiting = match
    @workflow.run_new_part_workflow(
      repository,
      adapters,
      workflow_store_fixture(),
      deferred,
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  guard waiting.outcome
    is @workflow.PartWorkflowRunOutcome::PartRunAwaitingPromotion else {
    fail("Part did not reach Goal promotion admission")
  }
  waiting.snapshot
}

///|
/// The promotion the Goal runner would select for this record, chosen by the
/// runner's own selector rather than hand-built.
fn promotion_harness_selection(
  record : @workflow.GoalPartSchedulingRecord,
) -> @workflow.DeterministicPromotionSelection raise {
  match
    @workflow.select_next_deterministic_promotion(
      [record],
      promotion_harness_head,
    ) {
    Ok(Some(value)) => value
    Ok(None) => fail("the runner selected no promotion")
    Err(error) => fail(error.message())
  }
}

///|
/// Effects that conflict the promotion and drive everything else normally.
///
/// `conflicted` is set the moment the conflict is reported, so a test can make
/// the admission gate change its answer exactly between the promotion attempt
/// and the repair that follows it.
fn promotion_harness_conflicting_effects(
  dependencies : @workflow.PartWorkflowDriverDependencies,
  execute_count : Ref[Int],
  conflicted : Ref[Bool],
) -> @workflow.PartWorkflowDriverAdapters {
  {
    execute: (snapshot, intent) => {
      execute_count.val = execute_count.val + 1
      match intent.kind {
        @workflow.PartEffectKind::GeneratePromotion(planned) => {
          conflicted.val = true
          Ok(
            @workflow.PartEffectObservation::PromotionConflictObserved({
              id: @control.IntegrationConflictId("integration-conflict-store"),
              intent_id: planned.id,
              candidate_id: planned.candidate_id,
              candidate_commit_oid: planned.candidate_commit_oid,
              expected_goal_head_oid: planned.expected_goal_head_oid,
              expected_goal_head_tree_oid: @control.GitOid(
                "goal-head-tree-store",
              ),
              merge_base_oid: snapshot.task_contract.base_commit_oid,
              conflicting_paths: [@control.RepoPath("src/store.mbt")],
              evidence_digest: workflow_store_digest_b,
            }),
          )
        }
        _ => workflow_driver_observation(snapshot, intent)
      }
    },
    reconcile: dependencies.effects.reconcile,
  }
}

///|
/// A genuine conflict repair, planned by the control plane's own planner so the
/// snapshot the adapter persists is one the driver can actually resume.
fn promotion_harness_repair(
  snapshot : @workflow.PartWorkflowSnapshot,
) -> Result[@workflow.PartConflictRepairDecision, @types.ChoirError] {
  if snapshot.integration_conflicts.length() == 0 {
    return Err(
      @types.ChoirError::validation_error("conflict evidence is absent"),
    )
  }
  let conflict = snapshot.integration_conflicts[snapshot.integration_conflicts.length() -
    1]
  let contract : @control.TaskContractRevision = {
    ..snapshot.task_contract,
    id: @control.RevisionId("revision-store-repair"),
    revision: snapshot.task_contract.revision + 1,
    digest: workflow_store_digest_b,
    repair_conflict_id: Some(conflict.id),
    base_commit_oid: conflict.expected_goal_head_oid,
    base_tree_oid: conflict.expected_goal_head_tree_oid,
  }
  let take = fn(
    id : String,
    previous : @control.Take,
    purpose : @control.TakePurpose,
  ) -> @control.Take {
    {
      id: @control.TakeId(id),
      goal_id: previous.goal_id,
      purpose,
      ordinal: previous.ordinal + 1,
      fencing_epoch: None,
      lifecycle: @control.TakeLifecycle::TakePlanned,
    }
  }
  let implementation = take(
    "implementation-store-repair",
    snapshot.implementation_take,
    @control.TakePurpose::Implementation(snapshot.part.id, contract.id),
  )
  let verification = take(
    "verification-store-repair",
    snapshot.verification_take,
    @control.TakePurpose::PartVerification(
      snapshot.part.id,
      implementation.id,
      contract.verification_specs[0].digest,
    ),
  )
  let audit = take(
    "audit-store-repair",
    snapshot.audit_take,
    @control.TakePurpose::PartAudit(
      snapshot.part.id,
      implementation.id,
      contract.audit_policy_digest,
    ),
  )
  let sandbox = fn(
    role : String,
    repaired_take : @control.Take,
    previous : @control.SandboxLease,
  ) -> @control.SandboxLease {
    {
      ..previous,
      id: @control.SandboxLeaseId(role + "-sandbox-store-repair"),
      take_id: repaired_take.id,
      generation_id: @control.SandboxGenerationId(
        role + "-generation-store-repair",
      ),
      lifecycle: @control.SandboxLeaseLifecycle::SandboxLeasePlanned,
    }
  }
  let implementation_sandbox = sandbox(
    "implementation",
    implementation,
    snapshot.identities.implementation_sandbox,
  )
  let verification_sandbox = sandbox(
    "verification",
    verification,
    snapshot.identities.verification_sandbox,
  )
  let audit_sandbox = sandbox("audit", audit, snapshot.identities.audit_sandbox)
  let session = fn(
    role : String,
    repaired_take : @control.Take,
    lease : @control.SandboxLease,
    previous : @control.HarnessSession,
  ) -> @control.HarnessSession {
    {
      ..previous,
      id: @control.HarnessSessionId(role + "-session-store-repair"),
      take_id: repaired_take.id,
      sandbox_generation_id: lease.generation_id,
      provider_cursor: None,
      last_choir_sequence: @control.EventSequence(0L),
      open_tool_execution_ids: [],
      lifecycle: @control.HarnessSessionLifecycle::HarnessSessionPlanned,
      usage: None,
    }
  }
  @workflow.plan_part_conflict_repair(
    snapshot,
    contract,
    {
      implementation_take: implementation,
      implementation_sandbox,
      implementation_session: session(
        "implementation",
        implementation,
        implementation_sandbox,
        snapshot.identities.implementation_session,
      ),
      verification_take: verification,
      verification_sandbox,
      audit_take: audit,
      audit_sandbox,
      audit_session: session(
        "audit",
        audit,
        audit_sandbox,
        snapshot.identities.audit_session,
      ),
    },
    fn(_) { true },
  )
}

///|
/// The adapter configuration the Goal worker builds, with only the pieces a
/// promotion test varies left open.
fn promotion_harness_config(
  binding : @exec.GoalPartWorkflowBinding,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  dependencies : @workflow.PartWorkflowDriverDependencies,
  plan_conflict_repair : (@workflow.PartWorkflowSnapshot) -> Result[
    @workflow.PartConflictRepairDecision,
    @types.ChoirError,
  ],
  observed_deferral : Ref[Int64?],
) -> @exec.GoalPartWorkflowAdapterConfig {
  {
    bindings: [binding],
    repository_adapters: adapters,
    dependencies: fn(_, admission) {
      Ok({ ..dependencies, integration_admission: fn(_) { Ok(admission) } })
    },
    integration_input: promotion_harness_input,
    plan_conflict_repair,
    plan_audit_repair: fn(_) {
      Err(@types.ChoirError::validation_error("audit repair is not expected"))
    },
    plan_verification_repair: fn(_) {
      Err(
        @types.ChoirError::validation_error(
          "verification repair is not expected",
        ),
      )
    },
    plan_recovery_retry: fn(_) {
      Err(@types.ChoirError::validation_error("recovery is not expected"))
    },
    read_goal_head: () => Ok(promotion_harness_head),
    observe_provider_deferral: fn(instant) {
      observed_deferral.val = Some(instant)
    },
    release_provider_lease: fn(_) { Ok(()) },
  }
}

///|
/// Read back what the promotion pass left in the store.
fn promotion_harness_stored(
  repository : @workflow.PartWorkflowRepository,
  adapters : @workflow.PartWorkflowRepositoryAdapters,
  workflow_id : @control.WorkflowId,
) -> @workflow.PartWorkflowSnapshot raise {
  match @workflow.load_part_snapshot(repository, adapters, workflow_id) {
    Ok(Some(stored)) => stored.snapshot
    Ok(None) => fail("promotion left no snapshot")
    Err(error) => fail(error.message())
  }
}

///|
/// THE PROMOTION CONTRACT. An admitted promotion integrates the Part: the
/// adapter plans integration from the selection, drives it to a receipt, and
/// the record it hands back to the runner is the integrated one. Nothing is
/// deferred, and no conflict repair is reached.
async test "an admitted promotion integrates the Part and returns the integrated record" {
  let repository = workflow_repository("goal-adapter-promotion-integrated")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let waiting = promotion_harness_audited(repository, adapters, dependencies)
  let record : @workflow.GoalPartSchedulingRecord = {
    part: waiting.part,
    task_contract: waiting.task_contract,
  }
  let observed_deferral : Ref[Int64?] = @ref.new(None)
  let config = promotion_harness_config(
    { scheduling_record: record, initial_snapshot: waiting, repository },
    adapters,
    dependencies,
    fn(_) {
      Err(
        @types.ChoirError::validation_error("conflict repair is not expected"),
      )
    },
    observed_deferral,
  )
  let promoted = match
    (@exec.goal_part_workflow_adapters(config).promote_part)(
      record,
      promotion_harness_selection(record),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  // The runner replaces its record with this one and records the promotion
  // order from the lifecycle, so an integrated Part has to come back integrated.
  assert_true(
    promoted.part.lifecycle is @control.PartLifecycle::PartIntegrated(_),
  )
  assert_eq(promoted.task_contract, record.task_contract)
  let stored = promotion_harness_stored(
    repository,
    adapters,
    waiting.workflow_id,
  )
  assert_eq(stored.stage, @workflow.PartWorkflowStage::PartIntegrated)
  assert_true(stored.integration_receipt is Some(_))
  assert_eq(stored.integration_conflicts, [])
  assert_eq(observed_deferral.val, None)
  clean_workflow_repository(repository)
}

///|
/// A promotion that conflicts and is then refused by a capacity bound has to
/// name its wake instant.
///
/// The gate authorizes the promotion attempt, the promotion conflicts, and by
/// the time the conflict repair asks for authority the surface is full. The
/// outcome the pass returns describes the promotion, not the bound that refused
/// the repair, so if this pass drops the instant nothing else carries it and the
/// refusal degrades into polling.
async test "a promotion repair refused by a capacity bound still names its wake instant" {
  let repository = workflow_repository("goal-adapter-promotion-deferral")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let waiting = promotion_harness_audited(repository, adapters, dependencies)
  let conflicted = @ref.new(false)
  let bounded : @workflow.PartWorkflowDriverDependencies = {
    ..dependencies,
    effects: promotion_harness_conflicting_effects(
      dependencies, execute_count, conflicted,
    ),
    goal_authorizes_new_effects: fn() {
      if conflicted.val {
        Ok(
          @workflow.PartGoalAuthorization::PartGoalDeferredUntil(
            9_271L,
            @workflow.PartGoalDeferralReason::PartGoalProviderSurfaceAtCapacity,
          ),
        )
      } else {
        Ok(@workflow.PartGoalAuthorization::PartGoalAuthorized(None))
      }
    },
  }
  let record : @workflow.GoalPartSchedulingRecord = {
    part: waiting.part,
    task_contract: waiting.task_contract,
  }
  let observed_deferral : Ref[Int64?] = @ref.new(None)
  let config = promotion_harness_config(
    { scheduling_record: record, initial_snapshot: waiting, repository },
    adapters,
    bounded,
    promotion_harness_repair,
    observed_deferral,
  )
  let refused = match
    (@exec.goal_part_workflow_adapters(config).promote_part)(
      record,
      promotion_harness_selection(record),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(observed_deferral.val, Some(9_271L))
  // The other half: a refused repair is not written. The Part is still parked
  // on the conflict under its original contract, so the next tick re-plans the
  // repair instead of resuming a half-applied one.
  let stored = promotion_harness_stored(
    repository,
    adapters,
    waiting.workflow_id,
  )
  assert_eq(stored.task_contract, record.task_contract)
  assert_eq(stored.task_contract_history.length(), 1)
  assert_eq(stored.integration_conflicts.length(), 1)
  assert_true(
    stored.part.lifecycle
    is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartIntegrationConflict
    ),
  )
  let parked : @workflow.GoalPartSchedulingRecord = {
    part: stored.part,
    task_contract: stored.task_contract,
  }
  assert_eq(refused, parked)
  clean_workflow_repository(repository)
}

///|
/// A standing refusal is not a deferral. The Goal withdrew authority — over
/// budget, canceling, or no longer running — and nothing about that clears with
/// time, so the pass must report no instant at all. Reporting one would make the
/// daemon schedule a wake for a Goal that will still be refused when it fires.
async test "a promotion repair the Goal refuses outright reports no wake instant" {
  let repository = workflow_repository("goal-adapter-promotion-refusal")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let waiting = promotion_harness_audited(repository, adapters, dependencies)
  let conflicted = @ref.new(false)
  let withdrawn : @workflow.PartWorkflowDriverDependencies = {
    ..dependencies,
    effects: promotion_harness_conflicting_effects(
      dependencies, execute_count, conflicted,
    ),
    goal_authorizes_new_effects: fn() {
      if conflicted.val {
        Ok(@workflow.PartGoalAuthorization::PartGoalNotAuthorized)
      } else {
        Ok(@workflow.PartGoalAuthorization::PartGoalAuthorized(None))
      }
    },
  }
  let record : @workflow.GoalPartSchedulingRecord = {
    part: waiting.part,
    task_contract: waiting.task_contract,
  }
  let observed_deferral : Ref[Int64?] = @ref.new(None)
  let config = promotion_harness_config(
    { scheduling_record: record, initial_snapshot: waiting, repository },
    adapters,
    withdrawn,
    promotion_harness_repair,
    observed_deferral,
  )
  let refused = match
    (@exec.goal_part_workflow_adapters(config).promote_part)(
      record,
      promotion_harness_selection(record),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_eq(observed_deferral.val, None)
  let stored = promotion_harness_stored(
    repository,
    adapters,
    waiting.workflow_id,
  )
  assert_eq(stored.task_contract, record.task_contract)
  assert_eq(stored.task_contract_history.length(), 1)
  assert_true(
    stored.part.lifecycle
    is @control.PartLifecycle::PartBlocked(
      @control.PartBlockReason::PartIntegrationConflict
    ),
  )
  let parked : @workflow.GoalPartSchedulingRecord = {
    part: stored.part,
    task_contract: stored.task_contract,
  }
  assert_eq(refused, parked)
  clean_workflow_repository(repository)
}

///|
/// The same conflict under an authorizing Goal: the repair IS written and
/// re-armed. Without this, the two refusal tests above would pass against an
/// adapter that never persists a repair at all.
async test "an authorized promotion repair is persisted and re-armed under the revised contract" {
  let repository = workflow_repository("goal-adapter-promotion-repair")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let waiting = promotion_harness_audited(repository, adapters, dependencies)
  let conflicted = @ref.new(false)
  let authorized : @workflow.PartWorkflowDriverDependencies = {
    ..dependencies,
    effects: promotion_harness_conflicting_effects(
      dependencies, execute_count, conflicted,
    ),
  }
  let record : @workflow.GoalPartSchedulingRecord = {
    part: waiting.part,
    task_contract: waiting.task_contract,
  }
  let observed_deferral : Ref[Int64?] = @ref.new(None)
  let config = promotion_harness_config(
    { scheduling_record: record, initial_snapshot: waiting, repository },
    adapters,
    authorized,
    promotion_harness_repair,
    observed_deferral,
  )
  let repaired = match
    (@exec.goal_part_workflow_adapters(config).promote_part)(
      record,
      promotion_harness_selection(record),
    ) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  assert_true(conflicted.val)
  assert_eq(observed_deferral.val, None)
  // The repair is durable, not just returned: a restart resumes the revised
  // contract rather than re-planning the same conflicted promotion.
  let stored = promotion_harness_stored(
    repository,
    adapters,
    waiting.workflow_id,
  )
  assert_eq(
    stored.task_contract.id,
    @control.RevisionId("revision-store-repair"),
  )
  assert_eq(stored.task_contract.revision, record.task_contract.revision + 1)
  assert_eq(stored.task_contract_history.length(), 2)
  assert_eq(stored.integration_conflicts.length(), 1)
  // And the pass leaves the repair re-armed under the deferred admission the
  // adapter resumes with, so the runner sees a Part waiting to be promoted
  // again rather than one still parked on the conflict.
  assert_eq(repaired.task_contract, stored.task_contract)
  assert_eq(repaired.part, stored.part)
  assert_eq(stored.stage, @workflow.PartWorkflowStage::PartAudited)
  clean_workflow_repository(repository)
}

///|
/// PROMOTION RECOVERY. `resume_promotion` is the runner's path for a Part it
/// left mid-promotion: the integration effect was authorized and may have run,
/// so the pass must reconcile the durable witness rather than execute the
/// integration a second time.
async test "promotion recovery reconciles an authorized integration instead of re-running it" {
  let repository = workflow_repository("goal-adapter-promotion-recovery")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let interrupted : @workflow.PartWorkflowDriverDependencies = {
    ..dependencies,
    effects: {
      execute: (snapshot, intent) => {
        execute_count.val = execute_count.val + 1
        if intent.kind is @workflow.PartEffectKind::ApplyIntegration(_, _) {
          Err(@types.ChoirError::canceled("promotion lost after authorization"))
        } else {
          workflow_driver_observation(snapshot, intent)
        }
      },
      reconcile: dependencies.effects.reconcile,
    },
  }
  let waiting = promotion_harness_audited(repository, adapters, dependencies)
  let record : @workflow.GoalPartSchedulingRecord = {
    part: waiting.part,
    task_contract: waiting.task_contract,
  }
  let binding : @exec.GoalPartWorkflowBinding = {
    scheduling_record: record,
    initial_snapshot: waiting,
    repository,
  }
  let observed_deferral : Ref[Int64?] = @ref.new(None)
  let lost = promotion_harness_config(
    binding,
    adapters,
    interrupted,
    fn(_) {
      Err(
        @types.ChoirError::validation_error("conflict repair is not expected"),
      )
    },
    observed_deferral,
  )
  assert_true(
    (@exec.goal_part_workflow_adapters(lost).promote_part)(
      record,
      promotion_harness_selection(record),
    )
    is Err(_),
  )
  // The Part is now exactly where the runner's recovery path picks it up: the
  // integration effect is durably authorized and its outcome is unknown.
  let uncertain = promotion_harness_stored(
    repository,
    adapters,
    waiting.workflow_id,
  )
  guard uncertain.pending_effect
    is Some(
      {
        lifecycle: @workflow.PartEffectLifecycle::PartEffectMayHaveOccurred,
        kind: @workflow.PartEffectKind::ApplyIntegration(_, _),
        ..,
      }
    ) else {
    fail("the lost promotion was not durably authorized")
  }
  let recovering : @workflow.GoalPartSchedulingRecord = {
    part: uncertain.part,
    task_contract: uncertain.task_contract,
  }
  let executed_before_recovery = execute_count.val
  let recovered = match
    (@exec.goal_part_workflow_adapters({
      ..lost,
      bindings: [{ ..binding, scheduling_record: recovering }],
    }).resume_promotion)(recovering) {
    Ok(value) => value
    Err(error) => fail(error.message())
  }
  // Reconciled, not re-executed: the recovery pass ran no new effect and the
  // Part reached integration from the witness the lost dispatch left behind.
  assert_eq(execute_count.val, executed_before_recovery)
  assert_eq(reconcile_count.val, 1)
  assert_true(
    recovered.part.lifecycle is @control.PartLifecycle::PartIntegrated(_),
  )
  let stored = promotion_harness_stored(
    repository,
    adapters,
    waiting.workflow_id,
  )
  assert_eq(stored.stage, @workflow.PartWorkflowStage::PartIntegrated)
  assert_true(stored.integration_receipt is Some(_))
  assert_eq(observed_deferral.val, None)
  clean_workflow_repository(repository)
}

///|
/// Promotion recovery refuses a record that is not the one in the store.
///
/// The runner selects the record from its own in-memory list; if that list has
/// drifted from the durable snapshot, resuming would drive a Part the caller is
/// not describing. The pass reads the snapshot and refuses rather than
/// reconciling against a stale contract.
async test "promotion recovery refuses a record the store disagrees with" {
  let repository = workflow_repository("goal-adapter-promotion-stale")
  clean_workflow_repository(repository)
  let adapters = workflow_repository_adapters()
  let execute_count = @ref.new(0)
  let reconcile_count = @ref.new(0)
  let dependencies = workflow_driver_dependencies(
    execute_count,
    reconcile_count,
    fn(_) { None },
    workflow_driver_recover_observation,
  )
  let waiting = promotion_harness_audited(repository, adapters, dependencies)
  let stale : @workflow.GoalPartSchedulingRecord = {
    part: waiting.part,
    task_contract: {
      ..waiting.task_contract,
      revision: waiting.task_contract.revision + 1,
    },
  }
  let observed_deferral : Ref[Int64?] = @ref.new(None)
  let config = promotion_harness_config(
    { scheduling_record: stale, initial_snapshot: waiting, repository },
    adapters,
    dependencies,
    fn(_) {
      Err(
        @types.ChoirError::validation_error("conflict repair is not expected"),
      )
    },
    observed_deferral,
  )
  let executed_before_recovery = execute_count.val
  assert_true(
    (@exec.goal_part_workflow_adapters(config).resume_promotion)(stale)
    is Err(_),
  )
  assert_eq(execute_count.val, executed_before_recovery)
  assert_eq(reconcile_count.val, 0)
  clean_workflow_repository(repository)
}

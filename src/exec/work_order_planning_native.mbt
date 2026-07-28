///|
pub(all) struct NativeWorkOrderPlanningSnapshot {
  repository_digest : @control.Digest
  bead_digest : @control.Digest
  beads : Array[@command.BeadRecord]
} derive(Debug, Eq)

///|
pub(all) enum NativeWorkOrderPlannerRecovery {
  NativeWorkOrderPlannerRecovered(Bytes)
  NativeWorkOrderPlannerExactRetryAuthorized
  NativeWorkOrderPlannerRecoveryUncertain(@control.Digest)
} derive(Debug, Eq)

///|
pub(all) struct NativeWorkOrderBeadDeliveryReceipt {
  batch_digest : @control.Digest
  bead_snapshot_digest : @control.Digest
} derive(Debug, Eq)

///|
pub(all) enum NativeWorkOrderPlannerAdmission {
  NativeWorkOrderPlannerAdmitted
  NativeWorkOrderPlannerDeferredUntil(Int64)
} derive(Debug, Eq)

///|
pub(all) struct NativeWorkOrderPlanningAdapters {
  capture_snapshot : () -> Result[
    NativeWorkOrderPlanningSnapshot,
    @types.ChoirError,
  ]
  execute_planner : async (
    @workflow.WorkOrderRecord,
    @workflow.WorkOrderPlanningRound,
  ) -> Result[Bytes, @types.ChoirError]
  recover_planner : async (
    @workflow.WorkOrderRecord,
    @workflow.WorkOrderPlanningRound,
  ) -> Result[NativeWorkOrderPlannerRecovery, @types.ChoirError]
  authorize_planner : (
    @workflow.WorkOrderRecord,
    @workflow.WorkOrderPlanningRound,
  ) -> Result[NativeWorkOrderPlannerAdmission, @types.ChoirError]
  release_planner : (
    @workflow.WorkOrderRecord,
    @workflow.WorkOrderPlanningRound,
  ) -> Result[Unit, @types.ChoirError]
  deliver_beads : async (
    @workflow.WorkOrderPlanningRoundId,
    @command.BeadBatchProposal,
  ) -> Result[NativeWorkOrderBeadDeliveryReceipt, @types.ChoirError]
  now : () -> Int64
}

///|
pub(all) enum NativeWorkOrderPlanningTick {
  NativeWorkOrderPlanningIdle
  NativeWorkOrderPlanningAdvanced(@workflow.WorkOrderRecord)
} derive(Debug, Eq)

///|
fn native_work_order_planning_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("native WorkOrder planning: " + detail)
}

///|
async fn native_work_order_capture(
  project_dir : String,
  program : String,
  arguments : Array[String],
  capture : async (Command) -> (Int, String),
) -> Result[String, @types.ChoirError] {
  let (status, output) = capture({
    program,
    args: arguments,
    workdir: Some(project_dir),
  })
  if status == 0 {
    Ok(output.trim().to_owned())
  } else {
    Err(
      native_work_order_planning_error(
        program + " snapshot command failed with status " + status.to_string(),
      ),
    )
  }
}

///|
/// Capture the exact repository commit/tree and canonical Bead graph a round
/// is planned against. Later admission compares these digests after delivery.
pub async fn capture_native_work_order_planning_snapshot(
  project_dir : String,
  capture : async (Command) -> (Int, String),
) -> Result[NativeWorkOrderPlanningSnapshot, @types.ChoirError] {
  let root = match
    native_work_order_capture(
      project_dir,
      "git",
      ["rev-parse", "--show-toplevel"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let commit = match
    native_work_order_capture(
      project_dir,
      "git",
      ["rev-parse", "--verify", "HEAD^{commit}"],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let tree = match
    native_work_order_capture(
      project_dir,
      "git",
      ["show", "-s", "--format=%T", "--no-show-signature", commit],
      capture,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let beads = match native_conductor_bead_graph(project_dir, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    repository_digest: @storage.artifact_digest(
      @utf8.encode(
        "choir.work-order-repository-snapshot.v1\u{00}" +
        @workflow.repository_id(root).0 +
        "\u{00}" +
        commit +
        "\u{00}" +
        tree,
      ),
    ),
    bead_digest: @command.bead_graph_digest(beads),
    beads,
  })
}

///|
pub async fn deliver_native_work_order_beads(
  project_dir : String,
  _round_id : @workflow.WorkOrderPlanningRoundId,
  proposal : @command.BeadBatchProposal,
  capture : async (Command) -> (Int, String),
) -> Result[NativeWorkOrderBeadDeliveryReceipt, @types.ChoirError] {
  let applied = match apply_native_bead_batch(project_dir, proposal, capture) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok({
    batch_digest: applied.digest,
    bead_snapshot_digest: @command.bead_graph_digest(applied.records),
  })
}

///|
fn native_work_order_planner_lease_request(
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
  fencing_epoch : @control.FencingEpoch,
) -> @workflow.ProviderLeaseRequest {
  let goal_id = @control.GoalId("work-order:" + record.id.0)
  let part_id = @control.PartId("planning-round:" + round.id.0)
  {
    lease_id: @workflow.provider_lease_id(
      goal_id,
      part_id,
      round.planner_surface,
    ),
    take_id: @control.TakeId(round.effect_id.0),
    goal_id,
    fencing_epoch,
  }
}

///|
pub fn authorize_native_work_order_planner(
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
  capacity : @types.ProviderCapacityPolicy,
  fencing_epoch : @control.FencingEpoch,
  now : Int64,
) -> Result[NativeWorkOrderPlannerAdmission, @types.ChoirError] {
  match
    @workflow.acquire_provider_lease(
      repository,
      local_part_workflow_repository_adapters(),
      round.planner_surface,
      native_work_order_planner_lease_request(record, round, fencing_epoch),
      capacity,
      now,
    ) {
    Ok(@workflow.ProviderLeaseDecision::ProviderLeaseGranted(_, _)) =>
      Ok(NativeWorkOrderPlannerAdmission::NativeWorkOrderPlannerAdmitted)
    Ok(@workflow.ProviderLeaseDecision::ProviderLeaseDeferredUntil(instant)) =>
      Ok(
        NativeWorkOrderPlannerAdmission::NativeWorkOrderPlannerDeferredUntil(
          instant,
        ),
      )
    Err(error) => Err(error)
  }
}

///|
pub fn release_native_work_order_planner(
  repository : @workflow.PartWorkflowRepository,
  record : @workflow.WorkOrderRecord,
  round : @workflow.WorkOrderPlanningRound,
  fencing_epoch : @control.FencingEpoch,
) -> Result[Unit, @types.ChoirError] {
  let request = native_work_order_planner_lease_request(
    record, round, fencing_epoch,
  )
  match
    @workflow.release_provider_lease(
      repository,
      local_part_workflow_repository_adapters(),
      round.planner_surface,
      request.lease_id,
      fencing_epoch,
    ) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
fn persist_native_work_order_planning(
  repository : @workflow.PartWorkflowRepository,
  repository_adapters : @workflow.PartWorkflowRepositoryAdapters,
  stored : @workflow.StoredWorkOrderRecord,
  next : @workflow.WorkOrderRecord,
) -> Result[NativeWorkOrderPlanningTick, @types.ChoirError] {
  match
    @workflow.persist_work_order_transition(
      repository, repository_adapters, stored, next,
    ) {
    Ok(value) =>
      Ok(
        NativeWorkOrderPlanningTick::NativeWorkOrderPlanningAdvanced(
          value.record,
        ),
      )
    Err(error) => Err(error)
  }
}

///|
/// Advance one crash-safe WorkOrder planning boundary.
///
/// The phase is always persisted before the corresponding provider or tracker
/// effect. Recovery therefore reconciles the exact effect or batch identity;
/// it never infers success from an empty response and never asks a passive gate
/// to produce its own evidence.
pub async fn run_native_work_order_planning_tick(
  repository : @workflow.PartWorkflowRepository,
  repository_adapters : @workflow.PartWorkflowRepositoryAdapters,
  work_order_id : @workflow.WorkOrderId,
  adapters : NativeWorkOrderPlanningAdapters,
) -> Result[NativeWorkOrderPlanningTick, @types.ChoirError] {
  let stored = match
    @workflow.load_work_order_record(
      repository, repository_adapters, work_order_id,
    ) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(native_work_order_planning_error("WorkOrder disappeared"))
    Err(error) => return Err(error)
  }
  if stored.record.lifecycle != @workflow.WorkOrderLifecycle::WorkOrderActive {
    return Ok(NativeWorkOrderPlanningTick::NativeWorkOrderPlanningIdle)
  }
  match stored.record.planning_rounds.last() {
    None => {
      let snapshot = match (adapters.capture_snapshot)() {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let next = match
        @workflow.plan_work_order_round(
          stored.record,
          snapshot.repository_digest,
          snapshot.bead_digest,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      persist_native_work_order_planning(
        repository, repository_adapters, stored, next,
      )
    }
    Some(round) =>
      match round.phase {
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningIntentRecorded => {
          match (adapters.authorize_planner)(stored.record, round) {
            Ok(NativeWorkOrderPlannerAdmitted) => ()
            Ok(NativeWorkOrderPlannerDeferredUntil(_)) =>
              return Ok(
                NativeWorkOrderPlanningTick::NativeWorkOrderPlanningIdle,
              )
            Err(error) => return Err(error)
          }
          let next = match
            @workflow.dispatch_work_order_planning_round(
              stored.record,
              (adapters.now)(),
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
        }
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningDispatched => {
          let content = match (adapters.recover_planner)(stored.record, round) {
            Ok(NativeWorkOrderPlannerRecovered(value)) => value
            Ok(NativeWorkOrderPlannerExactRetryAuthorized) =>
              match (adapters.execute_planner)(stored.record, round) {
                Ok(value) => value
                Err(error) => {
                  let failure = @storage.artifact_digest(
                    @utf8.encode(error.message()),
                  )
                  let next = match
                    @workflow.record_work_order_planner_failure(
                      stored.record,
                      failure,
                    ) {
                    Ok(value) => value
                    Err(transition_error) => return Err(transition_error)
                  }
                  let persisted = persist_native_work_order_planning(
                    repository, repository_adapters, stored, next,
                  )
                  ignore((adapters.release_planner)(stored.record, round))
                  return persisted
                }
              }
            Ok(NativeWorkOrderPlannerRecoveryUncertain(digest)) => {
              let next = match
                @workflow.record_work_order_planner_failure(
                  stored.record,
                  digest,
                ) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
              let persisted = persist_native_work_order_planning(
                repository, repository_adapters, stored, next,
              )
              ignore((adapters.release_planner)(stored.record, round))
              return persisted
            }
            Err(error) => return Err(error)
          }
          if content.length() == 0 {
            let next = match
              @workflow.record_empty_work_order_planner_response(stored.record) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            let persisted = persist_native_work_order_planning(
              repository, repository_adapters, stored, next,
            )
            ignore((adapters.release_planner)(stored.record, round))
            return persisted
          }
          let digest = @storage.artifact_digest(content)
          let receipt = match
            (repository_adapters.artifacts.adopt)(repository.artifact_store, {
              content,
              expected_digest: digest,
              provenance: @storage.ArtifactProvenance::ArtifactWorkOrderRecord,
              retention: @storage.ArtifactRetention::ArtifactPermanent,
            }) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let snapshot = match (adapters.capture_snapshot)() {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let next = match
            @workflow.record_work_order_planning_proposal(
              stored.record,
              { artifact_id: receipt.artifact_id.0, digest: receipt.digest },
              content,
              snapshot.repository_digest,
              snapshot.bead_digest,
              snapshot.beads,
              (adapters.now)(),
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let persisted = persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
          ignore((adapters.release_planner)(stored.record, round))
          persisted
        }
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningProposalReceived => {
          let next = match
            @workflow.begin_work_order_bead_delivery(stored.record) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
        }
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivering => {
          guard round.proposal_artifact is Some(artifact) else {
            return Err(
              native_work_order_planning_error("proposal artifact is absent"),
            )
          }
          let content = match
            (repository_adapters.artifacts.read)(repository.artifact_store, {
              digest: artifact.digest,
              max_bytes: repository.max_snapshot_bytes,
            }) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let proposal = match
            @workflow.decode_work_order_planning_proposal(content) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let delivered = match
            (adapters.deliver_beads)(round.id, proposal.bead_mutations) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let next = match
            @workflow.complete_work_order_bead_delivery(
              stored.record,
              delivered.batch_digest,
              delivered.bead_snapshot_digest,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          persist_native_work_order_planning(
            repository, repository_adapters, stored, next,
          )
        }
        @workflow.WorkOrderPlanningPhase::WorkOrderPlanningBeadsDelivered
        | @workflow.WorkOrderPlanningPhase::WorkOrderPlanningGoalReady
        | @workflow.WorkOrderPlanningPhase::WorkOrderPlanningRoundTerminal =>
          Ok(NativeWorkOrderPlanningTick::NativeWorkOrderPlanningIdle)
      }
  }
}

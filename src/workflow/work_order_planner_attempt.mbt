///| Durable evidence for one provider planning effect.

///|
pub(all) struct WorkOrderPlannerAttemptId(String) derive (
  Debug,
  Eq,
  Compare,
  Hash,
  ToJson,
  FromJson,
)

///|
pub(all) enum WorkOrderPlannerAttemptLifecycle {
  WorkOrderPlannerAttemptPlanned
  WorkOrderPlannerAttemptIssued(Int64)
  WorkOrderPlannerAttemptCompleted(@control.ArtifactReference, Int64)
  WorkOrderPlannerAttemptUncertain(@control.Digest)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct WorkOrderPlannerAttemptRecord {
  id : WorkOrderPlannerAttemptId
  work_order_id : WorkOrderId
  round_id : WorkOrderPlanningRoundId
  effect_id : WorkOrderPlanningEffectId
  attempt_number : Int
  session_id : @control.HarnessSessionId
  surface : @control.ProviderSurfaceId
  instruction_digest : @control.Digest
  schema_digest : @control.Digest
  lifecycle : WorkOrderPlannerAttemptLifecycle
  durable_version : Int
  fencing_epoch : @control.FencingEpoch
} derive(Debug, Eq, ToJson, FromJson)

///|
fn work_order_planner_attempt_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("WorkOrder planner attempt: " + detail)
}

///|
fn work_order_planner_attempt_id_for(
  round_id : WorkOrderPlanningRoundId,
  surface : @control.ProviderSurfaceId,
  attempt_number : Int,
) -> WorkOrderPlannerAttemptId {
  WorkOrderPlannerAttemptId(
    "work-order-planner-attempt-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode(
          "choir.work-order-planner-attempt.v1\u{00}" +
          round_id.0 +
          "\u{00}" +
          surface.to_json().stringify(indent=0) +
          "\u{00}" +
          attempt_number.to_string(),
        ),
      ),
    ),
  )
}

///|
pub fn work_order_planner_attempt_id(
  round : WorkOrderPlanningRound,
) -> WorkOrderPlannerAttemptId {
  work_order_planner_attempt_id_for(
    round.id,
    round.planner_surface,
    round.provider_failure_count + 1,
  )
}

///|
pub fn work_order_planner_session_id(
  attempt_id : WorkOrderPlannerAttemptId,
) -> @control.HarnessSessionId {
  @control.HarnessSessionId(
    "work-order-planner-session-" +
    @storage.digest_text(
      @storage.artifact_digest(
        @utf8.encode("choir.work-order-planner-session.v1\u{00}" + attempt_id.0),
      ),
    ),
  )
}

///|
pub fn validate_work_order_planner_attempt(
  record : WorkOrderPlannerAttemptRecord,
  allow_unstored? : Bool = false,
) -> Result[Unit, @types.ChoirError] {
  if record.id !=
    work_order_planner_attempt_id_for(
      record.round_id,
      record.surface,
      record.attempt_number,
    ) ||
    record.session_id != work_order_planner_session_id(record.id) ||
    record.attempt_number <= 0 ||
    record.fencing_epoch.0 <= 0L ||
    record.durable_version < 0 ||
    (!allow_unstored && record.durable_version == 0) ||
    @storage.validate_digest(record.instruction_digest) is Err(_) ||
    @storage.validate_digest(record.schema_digest) is Err(_) {
    return Err(work_order_planner_attempt_error("identity is invalid"))
  }
  match record.lifecycle {
    WorkOrderPlannerAttemptPlanned => ()
    WorkOrderPlannerAttemptIssued(issued_at) =>
      if issued_at < 0L {
        return Err(work_order_planner_attempt_error("issue time is invalid"))
      }
    WorkOrderPlannerAttemptCompleted(artifact, completed_at) =>
      if completed_at < 0L ||
        @storage.validate_digest(artifact.digest) is Err(_) {
        return Err(
          work_order_planner_attempt_error("completion evidence is invalid"),
        )
      }
    WorkOrderPlannerAttemptUncertain(digest) =>
      if @storage.validate_digest(digest) is Err(_) {
        return Err(
          work_order_planner_attempt_error("uncertainty evidence is invalid"),
        )
      }
  }
  Ok(())
}

///|
pub fn plan_work_order_planner_attempt(
  work_order : WorkOrderRecord,
  round : WorkOrderPlanningRound,
  instruction_digest : @control.Digest,
  schema_digest : @control.Digest,
) -> Result[WorkOrderPlannerAttemptRecord, @types.ChoirError] {
  if round.work_order_id != work_order.id ||
    round.effect_id != work_order_planning_effect_id(round.id) ||
    round.phase != WorkOrderPlanningPhase::WorkOrderPlanningDispatched {
    return Err(
      work_order_planner_attempt_error("planning round is not dispatchable"),
    )
  }
  let id = work_order_planner_attempt_id(round)
  let record : WorkOrderPlannerAttemptRecord = {
    id,
    work_order_id: work_order.id,
    round_id: round.id,
    effect_id: round.effect_id,
    attempt_number: round.provider_failure_count + 1,
    session_id: work_order_planner_session_id(id),
    surface: round.planner_surface,
    instruction_digest,
    schema_digest,
    lifecycle: WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptPlanned,
    durable_version: 0,
    fencing_epoch: work_order.fencing_epoch,
  }
  match validate_work_order_planner_attempt(record, allow_unstored=true) {
    Ok(_) => Ok(record)
    Err(error) => Err(error)
  }
}

///|
pub fn issue_work_order_planner_attempt(
  record : WorkOrderPlannerAttemptRecord,
  issued_at : Int64,
) -> Result[WorkOrderPlannerAttemptRecord, @types.ChoirError] {
  if record.lifecycle !=
    WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptPlanned ||
    issued_at < 0L {
    return Err(work_order_planner_attempt_error("attempt is not issuable"))
  }
  Ok({
    ..record,
    lifecycle: WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptIssued(
      issued_at,
    ),
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn complete_work_order_planner_attempt(
  record : WorkOrderPlannerAttemptRecord,
  artifact : @control.ArtifactReference,
  completed_at : Int64,
) -> Result[WorkOrderPlannerAttemptRecord, @types.ChoirError] {
  match record.lifecycle {
    WorkOrderPlannerAttemptCompleted(existing, existing_at) =>
      if existing == artifact && existing_at == completed_at {
        return Ok(record)
      } else {
        return Err(
          work_order_planner_attempt_error("completion replay disagrees"),
        )
      }
    WorkOrderPlannerAttemptIssued(_) => ()
    _ => return Err(work_order_planner_attempt_error("attempt was not issued"))
  }
  if @storage.validate_digest(artifact.digest) is Err(_) || completed_at < 0L {
    return Err(
      work_order_planner_attempt_error("completion evidence is invalid"),
    )
  }
  Ok({
    ..record,
    lifecycle: WorkOrderPlannerAttemptLifecycle::WorkOrderPlannerAttemptCompleted(
      artifact, completed_at,
    ),
    durable_version: record.durable_version + 1,
  })
}

///|
pub fn work_order_planner_attempt_record_bytes(
  record : WorkOrderPlannerAttemptRecord,
) -> Bytes {
  @utf8.encode(record.to_json().stringify(indent=0))
}

///|
pub fn decode_work_order_planner_attempt_record(
  content : Bytes,
) -> Result[WorkOrderPlannerAttemptRecord, @types.ChoirError] {
  let json = @json.parse(@utf8.decode(content)) catch {
    _ => return Err(work_order_planner_attempt_error("record is not JSON"))
  }
  let record : WorkOrderPlannerAttemptRecord = @json.from_json(json) catch {
    _ => return Err(work_order_planner_attempt_error("record shape is invalid"))
  }
  match validate_work_order_planner_attempt(record) {
    Ok(_) => Ok(record)
    Err(error) => Err(error)
  }
}

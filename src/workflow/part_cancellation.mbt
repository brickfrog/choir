///|
fn cancellation_take_disposition_known(take : @control.Take) -> Bool {
  match take.lifecycle {
    @control.TakeLifecycle::TakePlanned
    | @control.TakeLifecycle::TakeTerminal(_) => true
    _ => false
  }
}

///|
fn cancellation_session_disposition_known(
  session : @control.HarnessSession,
) -> Bool {
  match session.lifecycle {
    @control.HarnessSessionLifecycle::HarnessSessionIngestionClosedCleanly(_)
    | @control.HarnessSessionLifecycle::HarnessSessionProtocolViolated
    | @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain => true
    _ => false
  }
}

///|
fn cancellation_effect_disposition_known(intent : PartEffectIntent) -> Bool {
  match intent.lifecycle {
    PartEffectReceipted
    | PartEffectUncertain
    | PartEffectAbandonedByCancellation => true
    _ => false
  }
}

///|
fn cancellation_effect_requires_reconciliation(
  intent : PartEffectIntent,
) -> Bool {
  intent.lifecycle == PartEffectMayHaveOccurred &&
  intent.kind is ApplyIntegration(_, _)
}

///|
fn cancellation_resource_disposition_is_known(
  snapshot : PartWorkflowSnapshot,
) -> Bool {
  cancellation_take_disposition_known(snapshot.implementation_take) &&
  cancellation_take_disposition_known(snapshot.verification_take) &&
  cancellation_take_disposition_known(snapshot.audit_take) &&
  snapshot.sandbox_leases.all(fn(lease) {
    lease.lifecycle != @control.SandboxLeaseLifecycle::SandboxLeaseActive
  }) &&
  snapshot.harness_sessions.all(cancellation_session_disposition_known)
}

///|
fn cancellation_non_effect_disposition_is_known(
  snapshot : PartWorkflowSnapshot,
) -> Bool {
  let part_known = match snapshot.part.lifecycle {
    @control.PartLifecycle::PartIntegrated(_)
    | @control.PartLifecycle::PartBlocked(_)
    | @control.PartLifecycle::PartCanceledNotRun => true
    _ => false
  }
  part_known && cancellation_resource_disposition_is_known(snapshot)
}

///|
pub fn part_cancellation_disposition_is_known(
  snapshot : PartWorkflowSnapshot,
) -> Bool {
  let effect_known = match snapshot.pending_effect {
    None => true
    Some(intent) =>
      !cancellation_effect_requires_reconciliation(intent) &&
      cancellation_effect_disposition_known(intent)
  }
  cancellation_non_effect_disposition_is_known(snapshot) && effect_known
}

///|
fn cancel_take(
  take : @control.Take,
  fence : @control.FencingEpoch,
) -> Result[@control.Take, @types.ChoirError] {
  match take.lifecycle {
    @control.TakeLifecycle::TakeLeased =>
      @control.transition_take(
        take,
        @control.TakeTransition::FinishTake(
          fence,
          @control.TakeTerminalDisposition::TakeCanceled,
        ),
      )
    @control.TakeLifecycle::TakeRunning
    | @control.TakeLifecycle::TakeResultRecorded(_) =>
      @control.transition_take(
        take,
        @control.TakeTransition::FinishTake(
          fence,
          @control.TakeTerminalDisposition::TakeInterrupted,
        ),
      )
    _ => Ok(take)
  }
}

///|
fn canceled_part(snapshot : PartWorkflowSnapshot) -> Bool {
  snapshot.stage == PartAccepted &&
  snapshot.pending_effect is None &&
  snapshot.sandbox_leases.length() == 0 &&
  snapshot.harness_sessions.length() == 0 &&
  snapshot.effect_receipts.length() == 0 &&
  snapshot.implementation_take.lifecycle == @control.TakeLifecycle::TakeLeased
}

///|
pub fn record_part_goal_cancellation(
  snapshot : PartWorkflowSnapshot,
) -> Result[PartWorkflowSnapshot, @types.ChoirError] {
  if part_cancellation_disposition_is_known(snapshot) {
    return Ok(snapshot)
  }
  let integration_must_reconcile = match snapshot.pending_effect {
    Some(intent) => cancellation_effect_requires_reconciliation(intent)
    None => false
  }
  if integration_must_reconcile &&
    cancellation_resource_disposition_is_known(snapshot) {
    return Ok(snapshot)
  }
  let clean_not_run = canceled_part(snapshot)
  let part = if integration_must_reconcile {
    snapshot.part
  } else if clean_not_run {
    match
      @control.transition_part(
        snapshot.part,
        @control.PartTransition::CancelPartNotRun,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    match snapshot.part.lifecycle {
      @control.PartLifecycle::PartIntegrated(_)
      | @control.PartLifecycle::PartBlocked(_)
      | @control.PartLifecycle::PartCanceledNotRun => snapshot.part
      _ =>
        match
          @control.transition_part(
            snapshot.part,
            @control.PartTransition::BlockPart(
              @control.PartBlockReason::PartRecoveryUncertain,
            ),
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
    }
  }
  let implementation_take = match
    cancel_take(snapshot.implementation_take, snapshot.fencing_epoch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let verification_take = match
    cancel_take(snapshot.verification_take, snapshot.fencing_epoch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let audit_take = match
    cancel_take(snapshot.audit_take, snapshot.fencing_epoch) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let leases = snapshot.sandbox_leases.map(fn(lease) {
    if lease.lifecycle == @control.SandboxLeaseLifecycle::SandboxLeaseActive {
      {
        ..lease,
        lifecycle: @control.SandboxLeaseLifecycle::SandboxLeaseUncertain,
      }
    } else {
      lease
    }
  })
  let sessions = snapshot.harness_sessions.map(fn(session) {
    if cancellation_session_disposition_known(session) {
      session
    } else {
      {
        ..session,
        lifecycle: @control.HarnessSessionLifecycle::HarnessSessionRecoveryUncertain,
      }
    }
  })
  let pending_effect = match snapshot.pending_effect {
    Some({ lifecycle: PartEffectPlanned, .. } as intent) =>
      Some({ ..intent, lifecycle: PartEffectAbandonedByCancellation })
    Some({ lifecycle: PartEffectMayHaveOccurred, .. } as intent) =>
      if cancellation_effect_requires_reconciliation(intent) {
        Some(intent)
      } else {
        Some({ ..intent, lifecycle: PartEffectUncertain })
      }
    other => other
  }
  let stage = if integration_must_reconcile {
    snapshot.stage
  } else if clean_not_run {
    PartCanceled
  } else {
    match part.lifecycle {
      @control.PartLifecycle::PartIntegrated(_) => PartIntegrated
      @control.PartLifecycle::PartBlocked(_) => PartBlocked
      @control.PartLifecycle::PartCanceledNotRun => PartCanceled
      _ => PartRecoveryUncertain
    }
  }
  Ok({
    ..snapshot,
    durable_version: snapshot.durable_version + 1,
    stage,
    part,
    implementation_take,
    verification_take,
    audit_take,
    sandbox_leases: leases,
    harness_sessions: sessions,
    pending_effect,
  })
}

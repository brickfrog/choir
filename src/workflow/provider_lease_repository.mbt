///| Durable storage for the provider-surface lease records.
///
/// Modeled on `goal_execution_repository.mbt`: the record's own
/// `durable_version` is the store version, and every write is a compare-and-set
/// against the version the reader observed. Here that is not a convenience —
/// it is the mechanism that stops oversubscription. `plan_provider_lease_*`
/// decides against the held set it was handed, and the compare-and-set is what
/// guarantees nothing else changed that set in between.

///|
fn provider_surface_lease_key(
  surface : @control.ProviderSurfaceId,
) -> @storage.StateRecordKey {
  @storage.StateRecordKey(
    durable_record_key_prefix(DurableProviderSurfaceLease) +
    provider_surface_lease_tag(surface),
  )
}

///|
fn provider_surface_lease_event_key(
  record : ProviderSurfaceLeaseRecord,
) -> @storage.SemanticEventKey {
  @storage.SemanticEventKey(
    "provider-lease:" +
    provider_surface_lease_tag(record.surface) +
    ":held:" +
    record.durable_version.to_string(),
  )
}

///|
pub(all) struct StoredProviderSurfaceLeaseRecord {
  state_record : @storage.StateRecord
  record : ProviderSurfaceLeaseRecord
} derive(Debug, Eq)

///|
fn load_provider_surface_lease_from_state(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  state_record : @storage.StateRecord,
) -> Result[StoredProviderSurfaceLeaseRecord, @types.ChoirError] {
  let content = match
    (adapters.artifacts.read)(repository.artifact_store, {
      digest: state_record.value_digest,
      max_bytes: repository.max_snapshot_bytes,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if @storage.artifact_digest(content) != state_record.value_digest {
    return Err(provider_lease_error("content disagrees with durable state"))
  }
  let record = match decode_provider_surface_lease_record(content) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if state_record.key != provider_surface_lease_key(record.surface) ||
    state_record.version != record.durable_version ||
    state_record.fencing_epoch != record.fencing_epoch {
    return Err(provider_lease_error("state identity is inconsistent"))
  }
  Ok({ state_record, record })
}

///|
/// Read one surface's held set. `None` means nothing was ever held on it.
pub fn load_provider_surface_lease_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  surface : @control.ProviderSurfaceId,
) -> Result[StoredProviderSurfaceLeaseRecord?, @types.ChoirError] {
  let state = match
    (adapters.state.read_state)(
      repository.state_store,
      provider_surface_lease_key(surface),
    ) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(error) => return Err(error)
  }
  match load_provider_surface_lease_from_state(repository, adapters, state) {
    Ok(value) => Ok(Some(value))
    Err(error) => Err(error)
  }
}

///|
/// Read every surface's held set. Used for the global ceiling, which is the one
/// bound that cannot be decided from a single record.
pub fn list_provider_surface_lease_records(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
) -> Result[Array[ProviderSurfaceLeaseRecord], @types.ChoirError] {
  let states = match
    (adapters.state.list_state)(
      repository.state_store,
      durable_record_key_prefix(DurableProviderSurfaceLease),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let records : Array[ProviderSurfaceLeaseRecord] = []
  for state in states {
    match load_provider_surface_lease_from_state(repository, adapters, state) {
      Ok(value) => records.push(value.record)
      Err(error) => return Err(error)
    }
  }
  Ok(records)
}

///|
/// Compare-and-set one surface's held set.
///
/// `expected_store_version` is `None` only for the first write of a surface's
/// record, which is what makes two workers creating it concurrently resolve to
/// one winner rather than two.
fn persist_provider_surface_lease_record(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  record : ProviderSurfaceLeaseRecord,
  expected_store_version : Int?,
) -> Result[@storage.StateTransactionOutcome, @types.ChoirError] {
  let expected_durable_version = match expected_store_version {
    None => 1
    Some(value) => value + 1
  }
  if record.durable_version != expected_durable_version {
    return Err(provider_lease_error("record durable version is inconsistent"))
  }
  let content = provider_surface_lease_record_bytes(record)
  if content.length() > repository.max_snapshot_bytes {
    return Err(provider_lease_error("record exceeds repository limit"))
  }
  let record_digest = @storage.artifact_digest(content)
  let adopted = match
    (adapters.artifacts.adopt)(repository.artifact_store, {
      content,
      expected_digest: record_digest,
      provenance: @storage.ArtifactProvenance::ArtifactProviderSurfaceLease,
      retention: @storage.ArtifactRetention::ArtifactPermanent,
    }) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if adopted.digest != record_digest || adopted.byte_length != content.length() {
    return Err(provider_lease_error("artifact receipt is false"))
  }
  (adapters.state.commit)(repository.state_store, {
    state: {
      key: provider_surface_lease_key(record.surface),
      expected_version: expected_store_version,
      next_version: expected_durable_version,
      fencing_epoch: record.fencing_epoch,
      schedule_class: @storage.StateRecordScheduleClass::StateRecordNotSchedulable,
      value_digest: record_digest,
    },
    outbox: {
      semantic_key: provider_surface_lease_event_key(record),
      payload_digest: record_digest,
      owner_goal_id: None,
    },
    fault_point: None,
  })
}

///|
/// Take one provider slot, or learn when to ask again.
///
/// The decision is `plan_provider_lease_acquisition`'s; this applies nothing of
/// its own. A lost compare-and-set is reported as a deferral rather than an
/// error: another worker changed the held set, so the answer this pass computed
/// is stale and the caller should come back.
pub fn acquire_provider_lease(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  surface : @control.ProviderSurfaceId,
  request : ProviderLeaseRequest,
  policy : @types.ProviderCapacityPolicy,
  now : Int64,
) -> Result[ProviderLeaseDecision, @types.ChoirError] {
  let stored = match
    load_provider_surface_lease_record(repository, adapters, surface) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (current, expected_store_version) = match stored {
    Some(value) => (value.record, Some(value.state_record.version))
    None =>
      (
        empty_provider_surface_lease_record(surface, request.fencing_epoch),
        None,
      )
  }
  let other_surfaces = match policy.global_execution_ceiling {
    None => []
    Some(_) =>
      match list_provider_surface_lease_records(repository, adapters) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
  }
  let decision = plan_provider_lease_acquisition(
    current,
    request,
    {
      surface: provider_surface_capacity(policy, surface),
      global: policy.global_execution_ceiling,
      other_surfaces,
      deferral: provider_lease_deferral_seconds(),
    },
    now,
  )
  let (next, lease) = match decision {
    ProviderLeaseDeferredUntil(_) => return Ok(decision)
    ProviderLeaseGranted(next, lease) => (next, lease)
  }
  if next == current && stored is Some(_) {
    return Ok(decision)
  }
  match
    persist_provider_surface_lease_record(
      repository, adapters, next, expected_store_version,
    ) {
    Ok(@storage.StateTransactionOutcome::StateTransactionCommitted)
    | Ok(@storage.StateTransactionOutcome::StateTransactionReplayed)
    | Ok(@storage.StateTransactionOutcome::StateTransactionCommittedAckLost) =>
      Ok(ProviderLeaseGranted(next, lease))
    // Another writer changed the surface record between the read and the
    // compare-and-set, so what this worker judged is stale. The same deferral a
    // full surface gets: come back and read the record again.
    Ok(@storage.StateTransactionOutcome::StateTransactionVersionConflict) =>
      Ok(ProviderLeaseDeferredUntil(now + provider_lease_deferral_seconds()))
    // A newer generation adopted this surface, so this worker has no authority
    // to take a slot on it and is not going to get one by asking again.
    Ok(@storage.StateTransactionOutcome::StateTransactionStaleFence) =>
      Err(provider_lease_error("a newer generation holds this surface"))
    Ok(_) => Err(provider_lease_error("lease transaction failed"))
    Err(error) => Err(error)
  }
}

///|
/// Give one provider slot back. Releasing a lease that is not held succeeds and
/// writes nothing.
pub fn release_provider_lease(
  repository : PartWorkflowRepository,
  adapters : PartWorkflowRepositoryAdapters,
  surface : @control.ProviderSurfaceId,
  lease_id : ProviderLeaseId,
  fencing_epoch : @control.FencingEpoch,
) -> Result[ProviderLeaseReleaseDecision, @types.ChoirError] {
  let stored = match
    load_provider_surface_lease_record(repository, adapters, surface) {
    Ok(Some(value)) => value
    Ok(None) => return Ok(ProviderLeaseAlreadyReleased)
    Err(error) => return Err(error)
  }
  let next = match
    plan_provider_lease_release(stored.record, lease_id, fencing_epoch) {
    ProviderLeaseAlreadyReleased => return Ok(ProviderLeaseAlreadyReleased)
    ProviderLeaseReleased(value) => value
  }
  match
    persist_provider_surface_lease_record(
      repository,
      adapters,
      next,
      Some(stored.state_record.version),
    ) {
    Ok(@storage.StateTransactionOutcome::StateTransactionCommitted)
    | Ok(@storage.StateTransactionOutcome::StateTransactionReplayed)
    | Ok(@storage.StateTransactionOutcome::StateTransactionCommittedAckLost) =>
      Ok(ProviderLeaseReleased(next))
    Ok(@storage.StateTransactionOutcome::StateTransactionVersionConflict) =>
      Err(provider_lease_error("release lost a state race"))
    Ok(@storage.StateTransactionOutcome::StateTransactionStaleFence) =>
      Err(provider_lease_error("a newer generation holds this surface"))
    Ok(_) => Err(provider_lease_error("release transaction failed"))
    Err(error) => Err(error)
  }
}
